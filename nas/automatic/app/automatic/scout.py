"""Get a copy fast, then spend a week looking for a better one.

Sonarr's own RSS check finds most new episodes within minutes. The scout covers what
RSS misses and what Sonarr will not do by itself:

* As soon as an episode has aired and nothing has been grabbed, it asks Sonarr to
  search for it -- every 20 minutes for the first six hours, then every two hours.
* Once a copy is grabbed, the episode has a week to find a better one. A 4K or Dolby
  Vision release usually follows the first copy within hours, so the scout asks Sonarr
  to search again every 20 minutes for the first six hours, then every hour until two
  days have passed, then every six hours for the rest of the week. It reads the search
  results itself and takes a release only if it beats the best copy there already is
  -- downloading, finished, on its way into the library or in it -- by the profile's
  minimum upgrade (Dolby Vision first, every time). Sonarr cannot be left to judge
  that: a finished download drops out of its queue, so it would compare only with the
  library's file and take a second copy of what is already here. After the week the
  episode is unmonitored, so nothing changes it again.
* A download that stops moving -- no progress for three hours, or a magnet whose file
  list never arrives in two -- is dropped and marked failed, and Sonarr takes the next
  best release.
* When a better copy has finished downloading, the copy it beats is removed from the
  seedbox, and so is a copy no better than one already on the NAS. Only this
  category's torrents, and never one being copied to the NAS.
"""

import datetime as dt
import time
import traceback

from . import qbstate
from .sonarr import SonarrError

DAY = 86400


def _ts(iso):
    if not iso:
        return None
    try:
        return dt.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


class Scout:
    def __init__(self, gate, sonarr, store, log=print, window_days=7, upgrade_every_hours=6,
                 stall_hours=3, metadata_hours=2, remove_superseded=True, clock=time.time,
                 client_name="Seedbox qBittorrent (via Magnet)", first_copy_max_hours=4):
        self.gate = gate
        self.qbit = gate.qbit
        self.sonarr = sonarr
        self.store = store
        self.log = log
        self.window = window_days * DAY
        self.upgrade_every = upgrade_every_hours * 3600
        self.stall = stall_hours * 3600
        self.metadata = metadata_hours * 3600
        self.remove_superseded = remove_superseded
        # A first copy has to arrive in reasonable time; one that will take longer is
        # traded for the next best. Upgrades during the week may take as long as they like.
        self.first_copy_max = first_copy_max_hours * 3600
        self.now = clock
        # Only grabs made through the gate are the scout's. Grabs from before -- another
        # download client, another setup -- are history, not its business: it once
        # closed the "week" of month-old grabs and unmonitored their episodes.
        self.client_name = client_name
        # Series whose files the season-folder worker is moving: Sonarr can briefly report
        # no file for them, which is not the same as the file being gone.
        self.placing = lambda: set()
        self._home = {}
        self.last_run = 0.0
        self.last_error = ""

    # How often to look for better, by the age of the first copy: (younger than, every).
    # Past the last step it is `upgrade_every`.
    UPGRADE_PACE = ((6 * 3600, 20 * 60), (2 * DAY, 3600))

    def upgrade_interval(self, age):
        for within, every in self.UPGRADE_PACE:
            if age < within:
                return min(every, self.upgrade_every)
        return self.upgrade_every

    # -- what Sonarr knows -------------------------------------------------------
    def grabs(self):
        """Recent grabs: episode -> [records], and download hash -> [records]."""
        recs = self.sonarr.get("history", eventType=1, pageSize=1000, sortKey="date", sortDirection="descending")
        recs = recs.get("records", []) if isinstance(recs, dict) else (recs or [])
        by_ep, by_hash = {}, {}
        for r in recs:
            data = r.get("data") or {}
            if self.client_name not in (data.get("downloadClientName"), data.get("downloadClient")):
                continue
            if r.get("episodeId"):
                by_ep.setdefault(r["episodeId"], []).append(r)
            if r.get("downloadId"):
                by_hash.setdefault(r["downloadId"].lower(), []).append(r)
        return by_ep, by_hash

    # -- the pass ----------------------------------------------------------------
    def run_once(self):
        now = self.now()
        self._state = self.store.get("scout.episodes", {})
        # Only act on the seedbox from a fresh look at it: a snapshot from before an
        # outage would make every download look stalled.
        fresh = self.gate.last_poll and time.time() - self.gate.last_poll < 300     # the gate polls in real time
        if self.sonarr.alive():
            by_ep, by_hash = self.grabs()
            self._home = self._still_home(by_ep)
            live = self._live(by_ep, now)
            self._first_copies(live, now)
            self._upgrades(by_ep, live, now)
            if fresh:
                self._superseded(by_hash)
                self._slow_first_copies(by_hash, live, now)
        if fresh:
            self._stalls(now)
        self.store.put("scout.episodes", self._state)
        self.last_run = now

    def _still_home(self, by_ep):
        """{episode: score of the library's file} for episodes whose copy went from the
        seedbox to the NAS and that still have a file. Such a copy is the one to beat only
        as far as the library still holds it: an episode whose file was deleted has no
        copy, and one whose file was replaced by a worse one has only that."""
        decisions = self.store.decisions()
        imported = {}
        for eid, recs in by_ep.items():
            for r in recs:
                if decisions.get((r.get("downloadId") or "").lower(), {}).get("verdict") == "imported":
                    imported[eid] = r.get("seriesId")
        if not imported:
            return {}
        placing = self.placing()
        try:
            home = self.sonarr.library_scores(imported)
        except SonarrError:
            return {e: float("inf") for e in imported}     # cannot tell: assume nothing was lost
        # Files being moved between season folders can briefly read as gone.
        home.update({e: float("inf") for e, series in imported.items() if series in placing})
        return home

    def _worth(self, r, eid):
        """A grab's score as a copy there is: an imported one counts only as far as the
        library's file for its episode."""
        score = r.get("customFormatScore") or 0
        d = self.store.decision((r.get("downloadId") or "").lower())
        if d and d["verdict"] == "imported":
            have = self._home.get(eid, float("-inf"))
            # Sonarr scores a file a little apart from its release: only a real margin counts.
            return have if have + self.sonarr.min_upgrade() <= score else score
        return score

    def _imported_away(self, r, eid):
        """A grab that reached the NAS and was removed from the seedbox, but whose episode
        is no longer in the library."""
        d = self.store.decision((r.get("downloadId") or "").lower())
        return bool(d) and d["verdict"] == "imported" and eid not in self._home

    def _live(self, by_ep, now):
        """Episode -> its grabs that are still a copy: not refused, stalled or retired.

        A grab the gate refused is not a copy, so it must not stop the hunt for one."""
        decisions = self.store.decisions()
        out = {}
        for eid, recs in by_ep.items():
            keep = []
            for r in recs:
                h = (r.get("downloadId") or "").lower()
                d = decisions.get(h)
                if d and d["verdict"] in ("rejected", "stalled", "superseded"):
                    continue
                young = now - (_ts(r.get("date")) or 0) < 600     # the gate may not have seen it yet
                # "imported": on the NAS and gone from the seedbox, and still the copy to beat.
                if (d and d["verdict"] in ("approved", "waiting", "held", "imported")) or h in self.gate.known or young:
                    keep.append(r)
            if keep:
                out[eid] = keep
        return out

    def _search(self, episode_ids, why):
        """Every due episode is searched, twenty to a command, and the time of each
        search is saved at once -- a failure later in the pass must not make the next
        pass search them all again."""
        for i in range(0, len(episode_ids), 20):
            chunk = episode_ids[i:i + 20]
            self.sonarr.call("POST", "command", body={"name": "EpisodeSearch", "episodeIds": chunk})
            for eid in chunk:
                s = self._state.setdefault(str(eid), {})
                s["lastSearch"] = self.now()
                s["searches"] = s.get("searches", 0) + 1
            self.store.put("scout.episodes", self._state)
            self.log(f"scout: searching {len(chunk)} episode(s) -- {why}")

    def _first_copies(self, live, now):
        start = dt.datetime.fromtimestamp(now - 2 * DAY, dt.timezone.utc).isoformat()
        end = dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat()
        aired = self.sonarr.get("calendar", start=start, end=end, unmonitored="false") or []
        due = []
        for ep in aired:
            eid, air = ep.get("id"), _ts(ep.get("airDateUtc"))
            if not eid or not air or air > now or not ep.get("monitored") or ep.get("hasFile") or eid in live:
                continue
            s = self._state.get(str(eid), {})
            every = 20 * 60 if now - air < 6 * 3600 else 2 * 3600
            if now - s.get("lastSearch", 0) >= every:
                due.append(eid)
        self._search(due, "aired, no copy yet")

    def _upgrades(self, by_ep, live, now):
        due, closing = [], []
        for eid, recs in live.items():
            first = min((_ts(r.get("date")) or now) for r in recs)
            if now - first > self.window + 30 * DAY:
                continue                        # long settled; not ours to touch
            s = self._state.setdefault(str(eid), {})
            s["first"] = min(s.get("first", first), first)
            # A copy the library has lost is no copy at all: nothing to beat.
            present = [r for r in recs if not self._imported_away(r, eid)]
            best = max(present, key=lambda r: self._worth(r, eid)) if present else {}
            s["best"] = self._worth(best, eid) if present else 0
            s["bestTitle"] = best.get("sourceTitle", "")
            s["hasCopy"] = bool(present)
            if s.get("closed"):
                continue
            if now - s["first"] >= self.window:
                closing.append(eid)
            elif now - s.get("lastSearch", s["first"]) >= self.upgrade_interval(now - s["first"]):
                due.append(eid)
        if due:
            # An unfollowed show is not upgraded: these searches count as asked for by
            # hand, which skips Sonarr's own monitored check.
            try:
                watched = {e["id"] for e in self.sonarr.get("episode", episodeIds=due) or [] if e.get("monitored")}
            except SonarrError:
                watched = set()
            due = [e for e in due if e in watched]
        for eid in due:
            s = self._state[str(eid)]
            # No copy left at all (the library lost it): any release Sonarr approves will do.
            self._grab_better(eid, s.get("best", 0) if s.get("hasCopy", True) else None)
        if closing:
            self._close(closing, live)

    def _grab_better(self, eid, best):
        """Search, and take a release only if it beats `best` by the profile's minimum
        upgrade -- what Sonarr itself would demand of a copy in the library. With `best`
        None there is no copy to beat, and the best release Sonarr approves is taken."""
        s = self._state.setdefault(str(eid), {})
        s["lastSearch"] = self.now()
        s["searches"] = s.get("searches", 0) + 1
        self.store.put("scout.episodes", self._state)
        try:
            found = self.sonarr.call("GET", "release", {"episodeId": eid}, timeout=180) or []
            need = float("-inf") if best is None else best + self.sonarr.min_upgrade()
        except SonarrError as e:
            self.log(f"scout: could not search for a better copy of episode {eid}: {e}")
            return
        better = [r for r in found if r.get("approved") and (r.get("customFormatScore") or 0) >= need]
        if not better:
            return
        pick = max(better, key=lambda r: (r.get("customFormatScore") or 0, r.get("seeders") or 0))
        try:
            self.sonarr.call("POST", "release", body={"guid": pick["guid"], "indexerId": pick["indexerId"]},
                             timeout=60)
        except SonarrError as e:
            self.log(f"scout: could not take {pick.get('title')}: {e}")
            return
        self.log(f"scout: took {pick.get('title')} (score {pick.get('customFormatScore')}) for episode {eid}"
                 + (" -- the library has no copy of it" if best is None else f" -- better than the copy there is (score {best})"))

    def _close(self, closing, live):
        """The week is over. Only an episode that really has a copy -- finished on the
        seedbox, or a file in the library -- is left alone from now on; one that does
        not keeps being searched."""
        done = []
        has_file = {}
        try:
            for e in self.sonarr.get("episode", episodeIds=closing) or []:
                has_file[e["id"]] = e.get("hasFile", False)
        except SonarrError:
            return
        for eid in closing:
            hashes = {(r.get("downloadId") or "").lower() for r in live.get(eid, [])}
            decisions = self.store.decisions()
            # A copy that reached the NAS counts, even if the library no longer has it:
            # a file deleted after watching is not a reason to keep searching.
            finished = any((h in self.gate.known and qbstate.is_finished(self.gate.known[h]))
                           or decisions.get(h, {}).get("verdict") == "imported" for h in hashes)
            if finished or has_file.get(eid):
                done.append(eid)
            else:
                s = self._state[str(eid)]
                if self.now() - s.get("lastSearch", 0) >= self.upgrade_every:
                    self._search([eid], "the week is up but no copy has finished yet")
        if not done:
            return
        self.sonarr.call("PUT", "episode/monitor", body={"episodeIds": done, "monitored": False})
        for eid in done:
            s = self._state[str(eid)]
            s["closed"] = True
            self.store.event("settled", "", f"episode {eid}: kept {s.get('bestTitle') or 'the copy it has'}"
                                            f" (score {s.get('best', 0)}); no longer looking for better")
        self.store.put("scout.episodes", self._state)

    def _superseded(self, by_hash):
        if not self.remove_superseded:
            return
        decisions = self.store.decisions()
        running = {t["hash"] for t in self.store.running_transfers()}
        landed = {}                             # hash -> when its copy reached the NAS
        for t in self.store.transfers(500):
            if t["status"] == "done":
                landed[t["hash"]] = max(landed.get(t["hash"], 0), t["updated"])
        mine = {h: t for h, t in self.gate.known.items() if decisions.get(h, {}).get("verdict") == "approved"}
        # A copy already on the NAS has left the seedbox, but it is still the one to beat.
        imported = {h for h, d in decisions.items() if d["verdict"] == "imported" and by_hash.get(h)
                    and all(r.get("episodeId") in self._home for r in by_hash.get(h, []))}
        cover = {}                              # hash -> (score, episode ids)
        for h in set(mine) | imported:
            recs = by_hash.get(h, [])
            if recs:
                score = max(r.get("customFormatScore") or 0 for r in recs)
                if h in imported:       # only as good as what the library still holds
                    score = min(self._worth(r, r["episodeId"]) for r in recs)
                cover[h] = (score, {r["episodeId"] for r in recs})
        # Finished the way qBittorrent shows it: every byte, and no check running.
        complete = {h for h, t in mine.items() if qbstate.is_finished(t)} | (imported & set(cover))
        for h, (score, eps) in cover.items():
            if h not in mine or h in running or not eps:
                continue
            # Beaten by a better finished copy -- or equalled by one that reached the NAS
            # after it, which is the copy the library now holds.
            beaten = all(any(o != h and o in complete and e in oe
                             and (s > score or (s == score and landed.get(o, -1) > landed.get(h, -1)))
                             for o, (s, oe) in cover.items())
                         for e in eps)
            if beaten:
                name = mine[h].get("name", h)
                try:
                    self.qbit.delete([h])
                except Exception as e:
                    self.log(f"scout: could not remove {name}: {e}")
                    continue
                self.store.decide(h, "superseded", name, "a better copy finished downloading")
                self.log(f"scout: removed {name} -- superseded by a better copy")

    def _slow_first_copies(self, by_hash, live, now):
        """An episode's only copy that will take hours yet is swapped for the next best."""
        seen = self.store.get("scout.seen", {})
        decisions = self.store.decisions()
        for h, t in self.gate.known.items():
            seen.setdefault(h, now)
        seen = {h: ts for h, ts in seen.items() if h in self.gate.known}
        self.store.put("scout.seen", seen)
        for h, t in self.gate.known.items():
            if decisions.get(h, {}).get("verdict") != "approved" or qbstate.is_finished(t):
                continue
            if qbstate.phase(t) not in ("downloading", "stalled") or now - seen.get(h, now) < 30 * 60:
                continue
            eta = t.get("eta") or 0
            if 0 < eta < self.first_copy_max:
                continue
            eps = {r["episodeId"] for r in by_hash.get(h, []) if r.get("episodeId")}
            if not eps:
                continue
            others = {(r.get("downloadId") or "").lower() for e in eps for r in live.get(e, [])} - {h}
            if any(o in self.gate.known and qbstate.is_finished(self.gate.known[o]) for o in others):
                continue                    # not the first copy: an upgrade may take its time
            # Nor when an earlier copy is still on its way: this one is the upgrade the
            # search found meanwhile (the first days are searched every 20 minutes), and
            # an upgrade may take its time too. If that earlier copy fails, this becomes
            # the first copy and is judged as one.
            mine = min((_ts(r.get("date")) or now) for r in by_hash.get(h, []))
            if any((r.get("downloadId") or "").lower() != h and (_ts(r.get("date")) or now) < mine
                   and not self._imported_away(r, e)
                   for e in eps for r in live.get(e, [])):
                continue
            try:
                if any(e.get("hasFile") for e in self.sonarr.get("episode", episodeIds=sorted(eps)) or []):
                    continue
                self.qbit.delete([h])
            except Exception as e:
                self.log(f"scout: could not replace a slow first copy: {e}")
                continue
            hours = "never" if eta <= 0 or eta >= 8640000 else f"in {eta / 3600:.0f} hours"
            self.store.decide(h, "stalled", t.get("name", h),
                              f"too slow for a first copy (would finish {hours}); Sonarr will take the next best")

    def _stalls(self, now):
        """A download stalls when its PROGRESS stops moving. State changes do not count:
        a torrent restarted six times an hour, or rechecked every half hour, changes
        state constantly and still goes nowhere."""
        if not self.qbit.configured or self.qbit.blocked:
            return
        seen = self.store.get("scout.progress", {})
        decisions = self.store.decisions()
        live = {}
        for h, t in self.gate.known.items():
            verdict = decisions.get(h, {}).get("verdict")
            p = round(float(t.get("progress") or 0), 4)
            if qbstate.is_finished(t) or verdict not in ("approved", "held"):
                continue
            # Checking, moving, allocating: qBittorrent's own work, which can hold one
            # progress figure for a long time on a big file. Never a stall, and the
            # clock starts again when it is done.
            if qbstate.is_checking(t):
                live[h] = {"p": p, "since": now}
                continue
            last = seen.get(h)
            if not last or last["p"] != p:
                live[h] = {"p": p, "since": now}
                continue
            live[h] = last
            waiting_for_list = not qbstate.has_metadata(t)
            limit = self.metadata if waiting_for_list else self.stall
            # Queued is waiting its turn. Stopped is the gate's to restart -- unless the
            # gate has given up on it, and then it is as stuck as it looks.
            exempt = t.get("state") == "queuedDL" or (t.get("state") in qbstate.STOPPED and not self.gate.gave_up(h))
            if now - last["since"] >= limit and not exempt:
                why = ("its file list never arrived" if waiting_for_list
                       else f"no progress for {int(limit // 3600)} hours")
                try:
                    self.qbit.delete([h])
                except Exception as e:
                    self.log(f"scout: could not drop {t.get('name', h)}: {e}")
                    continue
                self.store.decide(h, "stalled", t.get("name", h), f"{why}; Sonarr will take the next best release")
                live.pop(h, None)
        self.store.put("scout.progress", live)

    def run(self, interval=300):
        while True:
            try:
                self.run_once()
                self.last_error = ""
            except SonarrError as e:
                self.last_error = str(e)
            except Exception as e:
                self.last_error = f"{type(e).__name__}: {e}"
                self.log("scout: " + traceback.format_exc().strip().splitlines()[-1])
            time.sleep(interval)

    def status(self):
        state = self.store.get("scout.episodes", {})
        now = self.now()
        open_ = [s for s in state.values() if s.get("first") and not s.get("closed")]
        next_close = min((s["first"] + self.window for s in open_), default=None)

        def iso(t):
            return dt.datetime.fromtimestamp(t, dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        return {"lastRun": iso(self.last_run) if self.last_run else None,
                "lookingForBetter": len(open_), "settled": sum(1 for s in state.values() if s.get("closed")),
                "windowDays": int(self.window // DAY), "error": self.last_error,
                "nextClose": iso(next_close) if next_close else None}

    def window_end(self, episode_ids):
        """When the look-for-better week ends for these episodes, or None if it already has."""
        state = self.store.get("scout.episodes", {})
        ends = [state[str(e)]["first"] + self.window for e in episode_ids
                if str(e) in state and state[str(e)].get("first") and not state[str(e)].get("closed")]
        return max(ends) if ends else None
