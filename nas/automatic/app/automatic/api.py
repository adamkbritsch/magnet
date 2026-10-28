"""The HTTP API behind Magnet's Automatic mode. Everything that mode shows comes from here.

Following a show monitors only episodes that have not aired yet: this is a machine
for NEW episodes, and a back catalogue appearing in an RSS feed must never turn into
a season of surprise downloads. Unfollowing only stops monitoring; nothing on disk
is ever touched from here.

An episode that passed the gate is copied to the NAS as soon as it finishes on the
seedbox. Sonarr does the copy (Copy, not Move, so the seedbox keeps its copy) and
names the file into the right show folder; a better copy found later replaces the
file, and one that is not better is left out. Bring to NAS is the same copy by hand,
for when the automatic one has given up.
"""

import datetime as dt
import hmac
import http.server
import json
import re
import threading
import time
import traceback
import urllib.parse
import urllib.request

from . import qbstate, rules
from .qbit import AuthRejected, UpstreamError
from .sonarr import SonarrError

VERSION = "1.0.0"
PROFILE_NAME = "Magnet"


def _norm(title):
    title = re.sub(r"\(\d{4}\)", "", title or "").lower()
    return re.sub(r"[^a-z0-9]+", "", title.replace("&", "and"))


def _ts(iso):
    try:
        return dt.datetime.fromisoformat((iso or "").replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _iso(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z") if ts and ts > 0 else None


class API:
    # How long the automatic copy waits after each failed try; after the last, the
    # episode is left to the Bring to NAS button. About two days in all, because
    # Sonarr refuses an episode still titled "TBA" for two days after it airs.
    AUTO_RETRY_DELAYS = (15 * 60, 30 * 60, 3600, 2 * 3600, 4 * 3600, 8 * 3600, 12 * 3600, 24 * 3600)

    def __init__(self, gate, sonarr, store, token, path_map, plex=None, watched_days=30, log=print, sources=None,
                 scout=None, auto_copy=True):
        self.auto_copy = auto_copy
        self._transfer_lock = threading.Lock()
        self._episodes = {}       # episode id -> (when, episode record), for naming seedbox rows
        self.sources = sources    # SourceSync, or None when Prowlarr is not configured
        self.scout = scout        # Scout, or None in tests
        self._grabs = (0.0, {})   # (when, hash -> grab records), cached briefly
        self.gate = gate
        self.qbit = gate.qbit
        self.sonarr = sonarr
        self.store = store
        self.token = token
        self.path_map = path_map  # (seedbox prefix, Sonarr prefix)
        self.plex = plex          # (url, token) or None
        self.watched_days = watched_days
        self.log = log
        self._lookups = {}
        self._login_attempts = []
        self._profile_id = None

    # -- Sonarr helpers ----------------------------------------------------------
    def profile_id(self):
        if self._profile_id is None:
            for p in self.sonarr.get("qualityprofile"):
                if p["name"] == PROFILE_NAME:
                    self._profile_id = p["id"]
        return self._profile_id

    def lookup(self, term):
        hit = self._lookups.get(term)
        if hit and time.time() - hit[0] < 3600:
            return hit[1]
        res = self.sonarr.get("series/lookup", term=term) or []
        self._lookups[term] = (time.time(), res)
        return res

    @staticmethod
    def _poster(series):
        for img in series.get("images", []):
            if img.get("coverType") == "poster":
                return img.get("remoteUrl") or img.get("url")
        return None

    def _show(self, s):
        return {"id": s.get("id"), "tvdbId": s.get("tvdbId"), "title": s.get("title"), "year": s.get("year"),
                "status": s.get("status"), "network": s.get("network"), "monitored": s.get("monitored", False),
                "nextAiring": s.get("nextAiring"), "previousAiring": s.get("previousAiring"),
                "poster": self._poster(s), "overview": (s.get("overview") or "")[:600],
                "path": s.get("path"), "magnetProfile": s.get("qualityProfileId") == self.profile_id()}

    # -- the views ---------------------------------------------------------------
    def overview(self):
        # stream-guard freezes Sonarr (docker pause) while Plex is streaming, and a
        # frozen container accepts connections and then never answers. Each part is
        # fetched on its own so the seedbox view still works while Sonarr is frozen.
        following, upcoming, sonarr_error, titles = [], [], "", {}
        try:
            if not self.sonarr.alive():
                raise SonarrError("Sonarr is not answering")
            series = self.sonarr.get("series")
            titles = {s.get("id"): s.get("title") for s in series}
            following = [self._show(s) for s in series if s.get("monitored") and s.get("status") != "ended"]
            following.sort(key=lambda s: (s["nextAiring"] is None, s["nextAiring"] or "", s["title"].lower()))
            now = dt.datetime.now(dt.timezone.utc)
            cal = self.sonarr.get("calendar", start=(now - dt.timedelta(days=3)).isoformat(),
                                  end=(now + dt.timedelta(days=28)).isoformat(), includeSeries="true")
            upcoming = [{"seriesId": e["seriesId"], "series": e.get("series", {}).get("title"),
                         "season": e.get("seasonNumber"), "episode": e.get("episodeNumber"), "title": e.get("title"),
                         "airDateUtc": e.get("airDateUtc"), "hasFile": e.get("hasFile", False),
                         "monitored": e.get("monitored", False)}
                        for e in cal if e.get("monitored")]
        except SonarrError as e:
            sonarr_error = str(e)
        health = self.health(sonarr_error or None)
        return {"version": VERSION, "following": following, "upcoming": upcoming,
                "seedbox": self.seedbox(sonarr_up=not sonarr_error, titles=titles), "blocked": self.blocked(),
                "transfers": self.store.transfers(30), "health": health,
                "sources": self.sources.status() if self.sources else None,
                "scout": self.scout.status() if self.scout else None}

    def seedbox(self, sonarr_up=True, titles=None):
        queue = {}
        try:
            if sonarr_up:
                q = self.sonarr.get("queue", pageSize=200, includeSeries="true", includeEpisode="true")
                for r in q.get("records", []):
                    if r.get("downloadId"):
                        queue[r["downloadId"].lower()] = r
        except SonarrError:
            pass
        grabs = self._grabs_by_hash() if sonarr_up else {}
        decisions = self.store.decisions()
        running = {t["hash"] for t in self.store.running_transfers()}
        done = {t["hash"] for t in self.store.transfers(500) if t["status"] == "done"}
        copies = self.copy_states(decisions, grabs if sonarr_up else None)
        # A finished download leaves Sonarr's queue, so its episode is named from the
        # grab instead -- otherwise the row shows only the torrent's own name.
        named = self._name_episodes(grabs, titles) if sonarr_up else {}
        out = []
        for h, t in sorted(self.gate.known.items(), key=lambda kv: -kv[1].get("added_on", 0)):
            d = decisions.get(h, {})
            r = queue.get(h, {})
            recs = grabs.get(h, [])
            ep = r.get("episode") or {}
            series_title = (r.get("series") or {}).get("title")
            if not ep and h in named:
                series_title, ep = named[h]
            score = max((g.get("customFormatScore") or 0) for g in recs) if recs else r.get("customFormatScore")
            formats = sorted({f["name"].removeprefix("Magnet: ") for g in recs for f in (g.get("customFormats") or [])}
                             | {f["name"].removeprefix("Magnet: ") for f in (r.get("customFormats") or [])})
            ends = self.scout.window_end({g["episodeId"] for g in recs if g.get("episodeId")}) if self.scout else None
            out.append({"hash": h, "name": t.get("name"), "state": t.get("state"), "progress": t.get("progress", 0),
                        "stateLabel": qbstate.label(t), "progressText": qbstate.progress_text(t),
                        "finished": qbstate.is_finished(t), "checking": qbstate.is_checking(t),
                        "size": t.get("size") or t.get("total_size"), "dlspeed": t.get("dlspeed", 0),
                        "eta": t.get("eta"), "addedOn": _iso(t.get("added_on")), "completedOn": _iso(t.get("completion_on")),
                        "verdict": d.get("verdict", "held"), "reason": d.get("reason", ""),
                        "series": series_title, "season": ep.get("seasonNumber"),
                        "episode": ep.get("episodeNumber"), "episodeTitle": ep.get("title"),
                        "transferring": h in running, "onNAS": h in done,
                        "copyStatus": copies.get(h, (None, ""))[0], "copyMessage": copies.get(h, (None, ""))[1],
                        "score": score, "formats": formats, "betterUntil": _iso(ends)})
        return {"torrents": out, "freeBytes": self.gate.free_bytes, "minFreeBytes": self.gate.min_free,
                "autoCopy": self.auto_copy}

    def _name_episodes(self, grabs, titles):
        """Torrent hash -> (series title, episode) for the torrents on the seedbox, from
        the episodes Sonarr grabbed them for. A pack names its season, not one episode."""
        wanted = {h: {g["episodeId"] for g in grabs.get(h, []) if g.get("episodeId")} for h in self.gate.known}
        now = time.time()
        missing = sorted({e for eps in wanted.values() for e in eps
                          if now - self._episodes.get(e, (0, None))[0] > 3600})
        try:
            for i in range(0, len(missing), 50):
                for e in self.sonarr.get("episode", episodeIds=missing[i:i + 50]) or []:
                    self._episodes[e["id"]] = (now, e)
        except SonarrError:
            pass
        out = {}
        for h, eps in wanted.items():
            found = [self._episodes[e][1] for e in eps if e in self._episodes]
            if not found:
                continue
            first = min(found, key=lambda e: (e.get("seasonNumber") or 0, e.get("episodeNumber") or 0))
            series = (titles or {}).get(first.get("seriesId"))
            if len(found) > 1:
                first = {"seasonNumber": first.get("seasonNumber")}
            out[h] = (series, first)
        return out

    def _grabs_by_hash(self):
        when, cached = self._grabs
        if time.time() - when < 60:
            return cached
        try:
            recs = self.sonarr.get("history", eventType=1, pageSize=500, sortKey="date", sortDirection="descending")
            recs = recs.get("records", []) if isinstance(recs, dict) else (recs or [])
        except SonarrError:
            return cached
        out = {}
        for g in recs:
            if g.get("downloadId"):
                out.setdefault(g["downloadId"].lower(), []).append(g)
        self._grabs = (time.time(), out)
        return out

    def blocked(self):
        return [{"hash": d["hash"], "name": d["name"], "reason": d["reason"], "files": json.loads(d["files"])[:12],
                 "at": _iso(d["updated"]), "blocklisted": bool(d["sonarr_marked"]),
                 "telling": not d["sonarr_marked"] and d["attempts"] < 60}
                for d in self.store.rejections(50)]

    def streaming(self):
        """Whether Plex is playing something now (stream-guard freezes Sonarr when it is)."""
        if not self.plex:
            return False
        url, token = self.plex
        try:
            req = urllib.request.Request(f"{url}/status/sessions?X-Plex-Token={token}", headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as r:
                return int(json.load(r)["MediaContainer"].get("size", 0)) > 0
        except Exception:
            return False

    def health(self, sonarr_error=None):
        if sonarr_error is None:
            sonarr_error = "" if self.sonarr.alive() else "Sonarr is not answering"
        streaming = self.streaming()
        if sonarr_error and streaming:
            sonarr_error = "Sonarr is paused while Plex is streaming; it catches up when the stream ends"
        return {"seedboxLogin": self.qbit.configured, "seedboxBlocked": self.qbit.blocked,
                "seedboxError": self.qbit.last_error or self.gate.last_error, "streaming": streaming,
                "lastPoll": _iso(self.gate.last_poll), "sonarr": not sonarr_error, "sonarrError": sonarr_error,
                "freeBytes": self.gate.free_bytes}

    def need_sonarr(self):
        """Fail fast, and say why, when Sonarr cannot answer -- usually because
        stream-guard has frozen it for a Plex stream. A frozen container accepts the
        connection and never replies, so without this every call waits out a timeout."""
        if not self.sonarr.alive():
            raise SonarrError("Sonarr is paused while Plex is streaming; try again when the stream ends"
                              if self.streaming() else "Sonarr is not answering")

    # -- following ---------------------------------------------------------------
    def search(self, term):
        self.need_sonarr()
        followed = {s["tvdbId"]: s for s in self.sonarr.get("series")}
        out = []
        for s in self.lookup(term)[:12]:
            mine = followed.get(s.get("tvdbId"))
            show = self._show(mine or s)
            show["inSonarr"] = mine is not None
            show["following"] = bool(mine and mine.get("monitored") and mine.get("status") != "ended")
            out.append(show)
        return out

    def follow(self, tvdb_id):
        self.need_sonarr()
        profile = self.profile_id()
        if profile is None:
            raise SonarrError(f"Sonarr has no '{PROFILE_NAME}' quality profile; run setup_sonarr.py")
        existing = next((s for s in self.sonarr.get("series") if s.get("tvdbId") == tvdb_id), None)
        if existing:
            existing.update(monitored=True, qualityProfileId=profile, monitorNewItems="all")
            self.sonarr.call("PUT", f"series/{existing['id']}", body=existing)
            self.sonarr.call("POST", "seasonpass", body={"series": [{"id": existing["id"], "monitored": True}],
                                                          "monitoringOptions": {"monitor": "future"}})
            self.store.event("follow", "", f"following {existing['title']} (new episodes only)")
            return self._show(self.sonarr.get(f"series/{existing['id']}"))
        found = self.lookup(f"tvdb:{tvdb_id}")
        if not found:
            raise SonarrError(f"no show with TVDB id {tvdb_id}")
        s = found[0]
        roots = self.sonarr.get("rootfolder")
        path = None
        want = _norm(s["title"])
        for root in roots:
            for folder in root.get("unmappedFolders", []):
                if _norm(folder["name"]) == want and (not s.get("year") or str(s["year"]) in folder["name"]
                                                      or "(" not in folder["name"]):
                    path = folder["path"]
        body = dict(s, qualityProfileId=profile, monitored=True, seasonFolder=True, monitorNewItems="all",
                    addOptions={"monitor": "future", "searchForMissingEpisodes": False,
                                "searchForCutoffUnmetEpisodes": False})
        if path:
            body["path"] = path
        else:
            body["rootFolderPath"] = max(roots, key=lambda r: r.get("freeSpace", 0))["path"]
        added = self.sonarr.call("POST", "series", body=body)
        self.store.event("follow", "", f"following {added['title']} (new episodes only) in {added['path']}")
        return self._show(added)

    def unfollow(self, series_id):
        self.need_sonarr()
        s = self.sonarr.get(f"series/{series_id}")
        s["monitored"] = False
        self.sonarr.call("PUT", f"series/{series_id}", body=s)
        self.store.event("unfollow", "", f"stopped following {s['title']}")
        return self._show(s)

    # -- suggestions -------------------------------------------------------------
    def suggestions(self, picks):
        """Shows to follow: ones picked by hand in Magnet, then ones being watched in Plex."""
        self.need_sonarr()
        series = self.sonarr.get("series")
        following = {s["tvdbId"] for s in series if s.get("monitored") and s.get("status") != "ended"}
        out, seen = [], set()

        def offer(show, why):
            tid = show.get("tvdbId")
            if not tid or tid in following or tid in seen or show.get("status") == "ended":
                return
            seen.add(tid)
            item = self._show(show)
            item["why"] = why
            out.append(item)

        for name in picks[:60]:
            try:
                p = self.sonarr.get("parse", title=name) or {}
            except SonarrError:
                continue
            if p.get("series"):
                offer(p["series"], f"you picked {name} in Magnet")
                continue
            title = (p.get("parsedEpisodeInfo") or {}).get("seriesTitle")
            if title and (p.get("parsedEpisodeInfo") or {}).get("seasonNumber") is not None:
                hits = self.lookup(title)
                if hits:
                    offer(hits[0], f"you picked {name} in Magnet")
        for tvdb, days in self.watching():
            hits = self.lookup(f"tvdb:{tvdb}")
            if hits:
                offer(hits[0], "watched today" if days == 0 else f"watched {days} day{'s' if days != 1 else ''} ago")
        return out

    def watching(self):
        if not self.plex:
            return []
        url, token = self.plex

        def get(path):
            req = urllib.request.Request(f"{url}{path}{'&' if '?' in path else '?'}X-Plex-Token={token}",
                                         headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=20) as r:
                return json.load(r)["MediaContainer"]
        try:
            sections = [d for d in get("/library/sections").get("Directory", []) if d.get("type") == "show"]
            now = time.time()
            out = []
            for sec in sections:
                for m in get(f"/library/sections/{sec['key']}/all?includeGuids=1").get("Metadata", []):
                    last = m.get("lastViewedAt")
                    if not last or now - last > self.watched_days * 86400:
                        continue
                    for g in m.get("Guid", []):
                        if g["id"].startswith("tvdb://"):
                            out.append((int(g["id"][7:]), int((now - last) // 86400)))
            out.sort(key=lambda x: x[1])
            return out
        except Exception as e:
            self.log(f"plex: {e}")
            return []

    # -- transfers ---------------------------------------------------------------
    def transfer(self, h):
        # By hand and by itself at the same moment must not start two copies.
        with self._transfer_lock:
            return self._transfer(h)

    def _transfer(self, h):
        h = h.lower()
        t = self.gate.known.get(h)
        if not t:
            raise ValueError("that torrent is not on the seedbox under the TV category")
        d = self.store.decision(h) or {}
        if d.get("verdict") != "approved":
            raise ValueError("only approved releases can be brought to the NAS")
        if qbstate.is_checking(t):
            raise ValueError("qBittorrent is still checking it")
        if not qbstate.is_finished(t):
            raise ValueError("still downloading")
        self.need_sonarr()
        if self.store.active_transfer(h):
            raise ValueError("already on its way")
        # The file list is checked again at the last door, not just the first.
        files = self.qbit.files(h)
        ok, reason, bad = rules.judge((f["name"], f.get("size", 0)) for f in files)
        if not ok:
            self.gate._reject(h, t["name"], reason, bad, d.get("source", ""))
            raise ValueError(f"refused: {reason}")
        content = t.get("content_path") or ""
        src, dst = self.path_map
        if not content.startswith(src):
            raise ValueError(f"cannot map {content!r} to a path Sonarr can see")
        cmd = self.sonarr.import_path(dst + content[len(src):], h)
        tid = self.store.add_transfer(h, t["name"], cmd["id"])
        self.store.event("transfer", h, f"{t['name']}: copying to the NAS")
        return {"id": tid, "commandId": cmd["id"]}

    def check_transfers(self):
        for tr in self.store.running_transfers():
            try:
                c = self.sonarr.command(tr["command_id"])
            except SonarrError:
                continue
            if c.get("status") == "completed":
                # "Completed" is the scan finishing, not the file arriving: Sonarr also
                # completes when it decides the file is not wanted. Only an import
                # recorded against this download counts as on the NAS.
                try:
                    imported = self._imported(tr["hash"], tr["created"])
                except SonarrError:
                    continue
                if imported:
                    self.store.update_transfer(tr["id"], "done", imported)
                    self.store.event("transferred", tr["hash"], f"{tr['name']}: on the NAS")
                    continue
                # Nothing arrived. Kept only when the library really has this episode at
                # least as good; anything else is a failure, and is tried again.
                try:
                    status, why = self._why_not_imported(tr["hash"])
                except SonarrError:
                    continue
                self.store.update_transfer(tr["id"], status, why)
                self.store.event("kept" if status == "skipped" else "transfer", tr["hash"], f"{tr['name']}: {why}")
            elif c.get("status") in ("failed", "aborted", "cancelled", "orphaned"):
                self.store.update_transfer(tr["id"], "failed",
                                           c.get("message") or c.get("exception") or c["status"])

    def _imported(self, h, since):
        """Where Sonarr put this download, if it imported it after `since`; else ''."""
        recs = self.sonarr.get("history", downloadId=h.upper(), eventType=3, pageSize=20,
                               sortKey="date", sortDirection="descending")
        recs = recs.get("records", []) if isinstance(recs, dict) else (recs or [])
        for r in recs:
            if (_ts(r.get("date")) or 0) >= since - 60:
                return (r.get("data") or {}).get("importedPath") or "imported"
        return ""

    def _why_not_imported(self, h):
        """After a scan that imported nothing: ("skipped", why) when every episode it is
        for already has a library file this copy does not beat by the profile's minimum
        upgrade -- Sonarr was right to leave it -- else ("failed", why)."""
        recs = self._grabs_by_hash().get(h, [])
        eps = sorted({r["episodeId"] for r in recs if r.get("episodeId")})
        if not eps:
            return "failed", "Sonarr finished without importing it"
        score = max((r.get("customFormatScore") or 0) for r in recs)
        need = self.sonarr.min_upgrade()
        episodes = self.sonarr.get("episode", episodeIds=eps) or []
        kept = len(episodes) == len(eps)
        for e in episodes:
            if not e.get("hasFile") or not e.get("episodeFileId"):
                kept = False
                break
            f = self.sonarr.get(f"episodefile/{e['episodeFileId']}") or {}
            if score >= (f.get("customFormatScore") or 0) + need:
                kept = False
                break
        if kept:
            return "skipped", "Sonarr kept the library's copy: this one is not better by enough to replace it"
        if any((e.get("title") or "").strip().upper() == "TBA" for e in episodes):
            return "failed", ("Sonarr will not import an episode still titled TBA until two days after it airs;"
                              " Magnet keeps trying")
        return "failed", "Sonarr finished without importing it"

    def copy_states(self, decisions=None, grabs=None):
        """Torrent hash -> (copy status, message) for each finished, approved torrent:
        waiting (the automatic copy will take it), running, done, skipped (the library's
        copy is as good), failed (the automatic copy has given up), or None (it never
        will take this one: Bring to NAS). The same rule auto_transfer acts on."""
        decisions = decisions if decisions is not None else self.store.decisions()
        grabs = grabs if grabs is not None else self._grabs_by_hash()
        latest, failures = {}, {}
        for tr in self.store.transfers(500):              # newest first
            latest.setdefault(tr["hash"], tr)
            if tr["status"] == "failed":
                failures[tr["hash"]] = failures.get(tr["hash"], 0) + 1
        finished = [h for h, t in self.gate.known.items()
                    if decisions.get(h, {}).get("verdict") == "approved" and qbstate.is_finished(t)]
        given_up = {h for h in finished if failures.get(h, 0) > len(self.AUTO_RETRY_DELAYS)}
        # Only what Sonarr grabbed has an episode to go to.
        cover = {}
        for h in finished:
            if grabs.get(h):
                cover[h] = (max((r.get("customFormatScore") or 0) for r in grabs[h]),
                            {r["episodeId"] for r in grabs[h] if r.get("episodeId")})

        settled = {h for h in cover if latest.get(h) and latest[h]["status"] in ("running", "done", "skipped")}

        def beaten(h):
            """Every episode in it has a better finished copy, or one as good that is in
            the library or on its way there (between two untouched equals, one goes)."""
            score, eps = cover[h]
            return bool(eps) and all(any(o != h and o not in given_up and e in oe
                                         and (s > score or (s == score and (o in settled or o < h)))
                                         for o, (s, oe) in cover.items()) for e in eps)
        out = {}
        for h in finished:
            tr = latest.get(h)
            message = tr["message"] if tr else ""
            if tr and tr["status"] in ("running", "done", "skipped"):
                out[h] = (tr["status"], message)
            elif tr and tr["status"] == "failed" and (h in given_up or not self.auto_copy):
                out[h] = ("failed", message)
            elif self.auto_copy and h in cover and beaten(h):
                out[h] = ("skipped", "A copy at least as good is in the library or on its way there")
            elif self.auto_copy and h in cover:
                out[h] = ("waiting", message)
            else:
                out[h] = (None, message)
        return out

    def auto_transfer(self):
        """Every finished episode the gate approved goes to its show folder by itself.

        Only torrents Sonarr grabbed, so each has an episode to go to; the best copy
        first; and not one whose episodes all have a better copy finished already --
        the scout removes that one from the seedbox instead."""
        if not self.auto_copy or not self.gate.last_poll or time.time() - self.gate.last_poll > 300:
            return
        if not self.sonarr.alive():
            return              # frozen while Plex streams; it catches up afterwards
        grabs = self._grabs_by_hash()
        states = self.copy_states(self.store.decisions(), grabs)
        latest, failures = {}, {}
        for tr in self.store.transfers(500):              # newest first
            latest.setdefault(tr["hash"], tr)
            if tr["status"] == "failed":
                failures[tr["hash"]] = failures.get(tr["hash"], 0) + 1
        now = time.time()
        # One import per episode at a time: Sonarr deletes the old file before copying
        # the new one, so two at once leave the episode without a file twice over.
        importing = {r.get("episodeId") for h, (status, _) in states.items() if status == "running"
                     for r in grabs.get(h, [])}
        waiting = [h for h, (status, _) in states.items() if status == "waiting"]
        for h in sorted(waiting, key=lambda h: -max((r.get("customFormatScore") or 0) for r in grabs[h])):
            eps = {r.get("episodeId") for r in grabs[h]}
            if eps & importing:
                continue
            tries = failures.get(h, 0)
            if tries and now - latest[h]["updated"] < self.AUTO_RETRY_DELAYS[min(tries, len(self.AUTO_RETRY_DELAYS)) - 1]:
                continue
            t = self.gate.known.get(h) or {}
            importing |= eps
            try:
                self.transfer(h)
            except ValueError as e:
                self.store.fail_transfer(h, t.get("name", h), str(e))
                self.store.event("transfer", h, f"{t.get('name', h)}: could not copy it to the NAS -- {e}")
            except (SonarrError, UpstreamError, AuthRejected):
                return          # nothing to record: Sonarr or the seedbox is not answering

    def watch_transfers(self, interval=10):
        while True:
            try:
                self.check_transfers()
                self.auto_transfer()
            except Exception as e:
                # A worker that dies silently leaves every transfer "on its way" forever.
                self.log(f"transfers: {type(e).__name__}: {e}")
            time.sleep(interval)

    # -- seedbox login -----------------------------------------------------------
    def seedbox_login(self, username, password):
        if not username.strip() or not password:
            raise ValueError("both a username and a password are needed")
        now = time.time()
        self._login_attempts = [t for t in self._login_attempts if now - t < 3600]
        if len(self._login_attempts) >= 3:
            raise ValueError("three tries in the last hour; waiting so the seedbox does not ban the NAS")
        self._login_attempts.append(now)
        self.qbit.login(username, password)
        self.qbit.save_credentials(username, password)
        self.store.event("login", "", "seedbox login saved")
        return {"ok": True}


def make_handler(api):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "magnet-automatic"

        def log_message(self, fmt, *args):
            pass

        def _json(self, status, obj):
            body = json.dumps(obj, default=str).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _authed(self):
            auth = self.headers.get("Authorization", "")
            return auth.startswith("Bearer ") and hmac.compare_digest(auth[7:].encode(), api.token.encode())

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            if n > 1024 * 1024:
                raise ValueError("request too large")
            return json.loads(self.rfile.read(n) or b"{}") if n else {}

        def _route(self, method):
            path, _, query = self.path.partition("?")
            q = dict(urllib.parse.parse_qsl(query))
            if path == "/healthz":
                return self._json(200, {"ok": True, "version": VERSION})
            if not self._authed():
                return self._json(401, {"error": "missing or wrong token"})
            try:
                if method == "GET" and path == "/v1/overview":
                    return self._json(200, api.overview())
                if method == "GET" and path == "/v1/search":
                    return self._json(200, api.search(q.get("term", "")))
                if method == "GET" and path == "/v1/events":
                    return self._json(200, api.store.events(int(q.get("limit", 200))))
                body = self._body() if method == "POST" else {}
                if method == "POST" and path == "/v1/follow":
                    return self._json(200, api.follow(int(body["tvdbId"])))
                if method == "POST" and path == "/v1/unfollow":
                    return self._json(200, api.unfollow(int(body["id"])))
                if method == "POST" and path == "/v1/suggestions":
                    return self._json(200, api.suggestions([str(t) for t in body.get("picks", [])]))
                if method == "POST" and path == "/v1/transfer":
                    return self._json(200, api.transfer(str(body["hash"])))
                if path == "/v1/sources":
                    if not api.sources:
                        return self._json(404, {"error": "Prowlarr is not configured on the NAS side"})
                    if method == "POST":
                        return self._json(200, api.sources.want(body.get("sites", [])))
                    return self._json(200, api.sources.status())
                if method == "POST" and path == "/v1/seedbox-login":
                    return self._json(200, api.seedbox_login(str(body["username"]), str(body["password"])))
                return self._json(404, {"error": "no such endpoint"})
            except (ValueError, KeyError) as e:
                return self._json(400, {"error": str(e)})
            except AuthRejected as e:
                return self._json(403, {"error": str(e)})
            except (SonarrError, UpstreamError) as e:
                return self._json(502, {"error": str(e)})
            except Exception as e:
                api.log("api: " + traceback.format_exc().strip().splitlines()[-1])
                return self._json(500, {"error": f"{type(e).__name__}: {e}"})

        def do_GET(self):
            self._route("GET")

        def do_POST(self):
            self._route("POST")

    return Handler
