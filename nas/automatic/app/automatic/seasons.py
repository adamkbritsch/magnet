"""Season folders the way Plex reads them.

A new episode belongs in the folder Plex already files that season under, whatever
Sonarr would call it -- or, for a season the show does not have yet, in a folder named
the way its others are ("Season 3", or "Season 03" where the show pads). Sonarr knows
one pattern for every show, so after it imports an episode the file is moved to where
it belongs.

A season Plex can only find by its file names -- a release-named folder, "S03", the
episodes loose in the show's folder, or two folders for one season -- is renamed on
the way: that season's episodes (and their subtitles) move into its "Season N" folder,
and a folder left empty is removed. Extras folders, files Plex does not list, and an
episode sitting in a season folder with another number are never touched.

Every move is a rename on the same volume, written down before it happens, with an
undo script beside the service's data. Sonarr is rescanned so it knows where the files
are and keeps the release name each was scored by; Plex rescans the show, and an
episode that lost its watched mark or resume point gets it back.
"""

import datetime as dt
import hashlib
import json
import os
import re
import shlex
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from .sonarr import SonarrError

SEASON_DIR = re.compile(r"(?i)^(?:season\s*(\d+)|specials)$")
PADDED = re.compile(r"(?i)^season\s*0\d$")
# Plex's own extras folders, by whole name, and any folder that ends in "Extras". Whole
# names, because a release folder like "Interview.with.the.Vampire.S02..." is a season.
EXTRAS = re.compile(r"(?i)^(?:behind the scenes|deleted scenes?|featurettes?|interviews?|scenes|shorts?|trailers?"
                    r"|other|extras?|bonus(?: features)?|making of|confidential)$|(?:^|[\s._-])extras$")
# Plex's optimized copies live beside the episode they were made from; never moved.
PLEX_VERSIONS = "Plex Versions"
VIDEO = (".mkv", ".mp4", ".m4v", ".avi", ".ts", ".m2ts", ".mov", ".wmv", ".mpg", ".mpeg", ".webm")


def season_of_dir(name):
    """The season a folder name says, the way Plex reads it, or None."""
    m = SEASON_DIR.match(name.strip())
    if not m:
        return None
    return 0 if m.group(1) is None else int(m.group(1))


def standard_name(season, padded):
    if season == 0:
        return "Specials"
    return ("Season %02d" if padded else "Season %d") % season


class LibraryMap:
    """Each TV library folder three ways: on the NAS, here (the same path Sonarr uses),
    and for Plex. Written by deploy.sh from the two containers' own mounts, as
    "host>here>plex" entries separated by "|"."""

    def __init__(self, spec):
        self.roots = []
        for part in (spec or "").split("|"):
            bits = [b.rstrip("/") for b in part.split(">")]
            if len(bits) == 3 and all(bits):
                self.roots.append(tuple(bits))

    @staticmethod
    def _swap(path, pairs):
        for a, b in pairs:
            if path == a or path.startswith(a + "/"):
                return b + path[len(a):]
        return None

    def from_plex(self, path):
        return self._swap(path, [(p, h) for _, h, p in self.roots])

    def to_plex(self, path):
        return self._swap(path, [(h, p) for _, h, p in self.roots])

    def to_host(self, path):
        return self._swap(path, [(h, n) for n, h, _ in self.roots])

    def covers(self, path):
        return self.to_plex(path) is not None


class Plex:
    IDENT = "com.plexapp.plugins.library"

    def __init__(self, url, token, timeout=60):
        self.url = url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self._shows = (0.0, {})

    def _open(self, path):
        sep = "&" if "?" in path else "?"
        req = urllib.request.Request(f"{self.url}{path}{sep}X-Plex-Token={self.token}",
                                     headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            return r.read()

    def get(self, path):
        return json.loads(self._open(path) or b"{}").get("MediaContainer", {})

    def shows(self, tvdb):
        """[(section key, show rating key)] for a TVDB id. Cached; looked up again on a miss."""
        now = time.time()
        when, cached = self._shows
        if now - when > 3600 or (tvdb not in cached and now - when > 600):
            cached = {}
            for d in self.get("/library/sections").get("Directory", []):
                if d.get("type") != "show":
                    continue
                for m in self.get(f"/library/sections/{d['key']}/all?includeGuids=1").get("Metadata", []):
                    for g in m.get("Guid", []):
                        if g.get("id", "").startswith("tvdb://"):
                            cached.setdefault(int(g["id"][7:]), []).append((d["key"], m["ratingKey"]))
            self._shows = (now, cached)
        return cached.get(tvdb, [])

    def episodes(self, rating_key):
        out = []
        for e in self.get(f"/library/metadata/{rating_key}/allLeaves").get("Metadata", []):
            # An optimized version is a Media of its own, marked with a proxy type.
            files = [p.get("file", "") for m in e.get("Media", []) if not m.get("proxyType")
                     for p in m.get("Part", [])]
            out.append({"key": e.get("ratingKey"), "season": e.get("parentIndex"), "index": e.get("index"),
                        "files": [f for f in files if f], "watched": bool(e.get("viewCount")),
                        "offset": e.get("viewOffset") or 0})
        return out

    def refresh(self, section, path):
        self._open(f"/library/sections/{section}/refresh?path={urllib.parse.quote(path)}")

    def scrobble(self, key):
        self._open(f"/:/scrobble?key={key}&identifier={self.IDENT}")

    def progress(self, key, ms):
        self._open(f"/:/progress?key={key}&time={int(ms)}&identifier={self.IDENT}&state=stopped")


class Seasons:
    REWATCH_AFTER = (3 * 60, 15 * 60, 60 * 60)
    RESCAN_GIVE_UP = 3 * 3600        # Sonarr busy for longer than this: its own rescan will do
    TRIES = 5

    def __init__(self, sonarr, plex, library, store, log=print, skip=(), data_dir=None, clock=time.time):
        self.sonarr = sonarr
        self.plex = plex                # Plex, or None: then only folder names are read
        self.library = library
        self.store = store
        self.log = log
        self.skip = {s.strip() for s in skip if s.strip()}
        self.data_dir = data_dir
        self.now = clock
        self._lock = threading.Lock()

    def enabled(self):
        return bool(self.library.roots)

    # -- the queue ---------------------------------------------------------------
    # A job is written down at each step, so a retry or a restart carries on where it
    # stopped: planned (moves, release names and watched state saved before anything
    # moves), moved, then waiting for Sonarr's rescan to finish.
    def queue(self, series_id, path, episode_ids):
        with self._lock:
            q = self.store.get("seasons.queue", [])
            if not any(j["path"] == path for j in q):
                q.append({"series": series_id, "path": path, "episodes": list(episode_ids), "at": self.now()})
                self.store.put("seasons.queue", q)

    def _save(self, job):
        with self._lock:
            q = self.store.get("seasons.queue", [])
            q = [job if j["path"] == job["path"] else j for j in q]
            self.store.put("seasons.queue", q)

    def _drop(self, job):
        with self._lock:
            q = [j for j in self.store.get("seasons.queue", []) if j["path"] != job["path"]]
            self.store.put("seasons.queue", q)

    def busy(self):
        """Series with an episode still being put in its place, or a rescan still to be
        finished: no import for them meanwhile, or Sonarr would act on paths that are
        about to change."""
        return {j["series"] for j in self.store.get("seasons.queue", [])}

    def tick(self):
        # A Sonarr paused for a Plex stream is not a failure to count: wait for it.
        if self.store.get("seasons.queue", []) and not self.sonarr.alive():
            self._rewatch()
            return
        for job in list(self.store.get("seasons.queue", [])):
            try:
                if self._advance(job):
                    self._drop(job)
                else:
                    self._save(job)
            except (SonarrError, OSError, urllib.error.URLError, ValueError) as e:
                job["tries"] = job.get("tries", 0) + 1
                self.log(f"seasons: {os.path.basename(job['path'])}: {e}")
                # Files already moved: Sonarr must still hear of it, so such a job is let
                # go only after hours, never on a count of tries.
                moved = job.get("phase") in ("moved", "rescan")
                if moved and self.now() - job.get("moved_at", job["at"]) < self.RESCAN_GIVE_UP:
                    self._save(job)
                elif job["tries"] >= self.TRIES or moved:
                    self.store.event("season", "", f"{os.path.basename(job['path'])}: gave up putting it in its"
                                                   f" season folder ({e})")
                    self._drop(job)
                else:
                    self._save(job)
        self._rewatch()

    def run(self, interval=15):
        while True:
            try:
                self.tick()
            except Exception as e:
                self.log(f"seasons: {type(e).__name__}: {e}")
            time.sleep(interval)

    def place(self, series_id, path, episode_ids):
        """Everything for one episode at once (the queue does it a step at a time).
        Returns where the file is now."""
        job = {"series": series_id, "path": path, "episodes": list(episode_ids), "at": self.now()}
        while not self._advance(job):
            if job.get("phase") == "rescan":
                time.sleep(3)
        return job.get("now", path)

    def _advance(self, job):
        """One step. True when the job is finished."""
        phase = job.get("phase")
        if phase is None:
            if not self._plan_job(job):
                return True
            phase = "planned"
        if phase == "planned":
            self._move(job)
            phase = job["phase"]
        if phase == "moved":
            self._after_move(job)
            phase = job["phase"]
        if phase == "rescan":
            return self._rescan_done(job)
        return True

    # -- planning -------------------------------------------------------------------
    def _plan_job(self, job):
        series = self.sonarr.get(f"series/{job['series']}")
        show = (series.get("path") or "").rstrip("/")
        path = job["path"]
        if not show or os.path.basename(show) in self.skip or not self.library.covers(show):
            return False
        if not os.path.isdir(show) or not os.path.isfile(path):
            return False                # gone, or already moved by an earlier job's tidy
        eps = self.sonarr.get("episode", episodeIds=list(job["episodes"])) or []
        seasons = {e.get("seasonNumber") for e in eps if e.get("seasonNumber") is not None}
        if len(seasons) != 1:
            return False                # not one season's episode: leave Sonarr's choice
        listed, plex_show = self._plex_files(series, show)
        files = dict(listed)
        files[path] = (seasons.pop(), None)
        # Every file of this show still waiting its turn is as new as this one: its
        # folder is Sonarr's choice, not the show's.
        pending = {j["path"] for j in self.store.get("seasons.queue", [])
                   if j["series"] == job["series"] and j.get("phase") is None} | {path}
        moves, renamed = self._plan(show, files, pending)
        if not moves:
            return False
        job.update(phase="planned", show=show, title=series.get("title") or os.path.basename(show),
                   moves=moves, renamed=[[a, b, n] for (a, b), n in sorted(renamed.items())],
                   captured=self._capture(job["series"]), plex=list(plex_show) if plex_show else None,
                   snap=self._snapshot(plex_show, moves) if plex_show else {})
        self._record(show, job["title"], moves)
        self._save(job)
        return True

    def _plex_files(self, series, show):
        """Episode files Plex lists for this show under Sonarr's folder for it:
        {path: (season, episode index)}, and (section, rating key) of the show."""
        if not self.plex:
            return {}, None
        out, found = {}, None
        try:
            for section, key in self.plex.shows(series.get("tvdbId")):
                mine = {}
                for e in self.plex.episodes(key):
                    for f in e["files"]:
                        here = self.library.from_plex(f)
                        if here and here.startswith(show + "/"):
                            mine[here] = (e["season"], e["index"])
                if mine:
                    out.update(mine)
                    found = found or (section, key)
        except (urllib.error.URLError, OSError, ValueError) as e:
            self.log(f"seasons: Plex did not answer ({e}); going by folder names only")
            return {}, None
        return out, found

    def _plan(self, show, files, pending):
        """[[from, to, the episode it travels with]] and {(old folder, new folder): episode
        files}. `files` is {path: (season, index)}; `pending` are files just imported."""
        def where(p):
            return os.path.relpath(p, show).split(os.sep)[:-1]

        settled = [p for p in files if p not in pending]
        # A folder Sonarr just made says nothing about how the show names its seasons,
        # unless episodes already in the library are in it too.
        made = {where(p)[0] for p in pending if where(p)}
        dirs = [d for d in os.listdir(show) if os.path.isdir(os.path.join(show, d))
                and not (d in made and not any(where(p)[:1] == [d] for p in settled))]
        padded = any(PADDED.match(d) for d in dirs)
        proper = {}
        for d in dirs:
            n = season_of_dir(d)
            if n is not None:
                proper.setdefault(n, []).append(d)
        counts = {}
        for p in settled:
            n, d = files[p][0], where(p)
            if len(d) == 1 and season_of_dir(d[0]) == n:
                counts[(n, d[0])] = counts.get((n, d[0]), 0) + 1

        def target(n):
            names = proper.get(n)
            if names:
                return max(sorted(names), key=lambda d: counts.get((n, d), 0))
            return standard_name(n, padded)

        episodes, why = [], {}
        for p, (n, _) in sorted(files.items()):
            if n is None or not p.startswith(show + "/") or not os.path.isfile(p) or os.path.islink(p):
                continue
            d = where(p)
            if PLEX_VERSIONS in d or any(EXTRAS.search(x) for x in d):
                continue
            here = season_of_dir(d[0]) if len(d) == 1 else None
            if p not in pending and here is not None and here != n:
                continue        # a season folder with another number: Plex and the folder disagree
            dest = target(n)
            if d == [dest]:
                continue
            episodes.append([p, os.path.join(show, dest, os.path.basename(p))])
            why[p] = ("/".join(d), dest)
        # Two episodes to one name, or a name already taken: both stay where they are.
        taken = {}
        for _, d in episodes:
            taken[d] = taken.get(d, 0) + 1
        episodes = [[s, d] for s, d in episodes if taken[d] == 1 and not os.path.lexists(d)]
        moves = [[s, d, s] for s, d in episodes]
        # Subtitles and the like travel with their episode: the video in the same folder
        # whose name is the longest start of theirs. Nothing moves without its episode.
        going = {s: d for s, d in episodes}
        for folder in sorted({os.path.dirname(s) for s in going}):
            names = sorted(os.listdir(folder))
            videos = [x for x in names if x.lower().endswith(VIDEO)]
            for x in names:
                p = os.path.join(folder, x)
                if x.lower().endswith(VIDEO) or not os.path.isfile(p) or os.path.islink(p):
                    continue
                owners = [v for v in videos if x.startswith(os.path.splitext(v)[0] + ".")]
                if not owners:
                    continue
                owner = os.path.join(folder, max(owners, key=lambda v: len(os.path.splitext(v)[0])))
                if owner in going:
                    dst = os.path.join(os.path.dirname(going[owner]), x)
                    if not os.path.lexists(dst):
                        moves.append([p, dst, owner])
        renamed = {}
        for s, _ in episodes:
            renamed[why[s]] = renamed.get(why[s], 0) + 1
        return moves, renamed

    # -- moving ---------------------------------------------------------------------
    def _move(self, job):
        """The renames. Safe to repeat: a move already made is skipped, and a file whose
        episode did not move stays with it."""
        done, skipped = [], set()
        for src, dst, owner in job["moves"]:
            if owner in skipped:
                continue
            if os.path.lexists(dst) and not os.path.lexists(src):
                done.append([src, dst])         # made before a restart
                continue
            if os.path.lexists(dst) or not os.path.isfile(src):
                if src == owner:
                    skipped.add(owner)
                continue
            try:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                os.rename(src, dst)
            except OSError as e:
                # One that cannot move stays where it is, with its subtitles; the rest
                # go on, and Sonarr and Plex still hear of them.
                skipped.add(owner)
                self.store.event("season", "", f"{os.path.basename(src)}: could not move it ({e}); left where it is")
                continue
            done.append([src, dst])
        job.update(phase="moved", done=done, moved_at=self.now())
        self._save(job)

    def _after_move(self, job):
        show = job["show"]
        moved = dict(job["done"])
        job["now"] = moved.get(job["path"], job["path"])
        self._prune({os.path.dirname(s) for s in moved}, show)
        if moved:
            for old, new, n in job.get("renamed", []):
                self.store.event("season", "", f"{job['title']}: {old or 'the show folder'} -> {new}"
                                               f" ({n} episode file{'s' if n != 1 else ''})")
        if job["now"] != job["path"]:
            self.log(f"seasons: {job['title']}: {os.path.basename(job['path'])} ->"
                     f" {os.path.relpath(job['now'], show)}")
        # Plex first: it does not need Sonarr, and its watched marks must not wait on it.
        if job.get("plex") and moved:
            self._tell_plex(job["plex"], show, job.get("snap") or {}, moved)
        if not moved:
            job["phase"] = "done"
            return
        cmd = self.sonarr.call("POST", "command", body={"name": "RescanSeries", "seriesId": job["series"]})
        job.update(phase="rescan", command=(cmd or {}).get("id"), rescan_at=self.now())

    def _rescan_done(self, job):
        """Once Sonarr's rescan has finished, each moved file gets back the release name
        it was scored by. True when there is nothing more to wait for."""
        cmd = self.sonarr.get(f"command/{job['command']}") if job.get("command") else {"status": "completed"}
        status = (cmd or {}).get("status")
        if status in ("failed", "aborted", "cancelled", "orphaned"):
            again = self.sonarr.call("POST", "command", body={"name": "RescanSeries", "seriesId": job["series"]})
            job["command"] = (again or {}).get("id")
            job["tries"] = job.get("tries", 0) + 1
            return job["tries"] >= self.TRIES
        if status != "completed":
            if self.now() - job.get("rescan_at", self.now()) > self.RESCAN_GIVE_UP:
                self.log(f"seasons: {job['title']}: Sonarr's rescan has not finished; its own will catch up")
                return True
            return False
        captured = job.get("captured") or {}
        for f in self.sonarr.get("episodefile", seriesId=job["series"]) or []:
            was = captured.get(os.path.basename(f.get("relativePath") or ""))
            # Only a file that came back without one: a newer import keeps its own.
            if was and not f.get("sceneName"):
                f["sceneName"] = was["sceneName"]
                if not f.get("releaseGroup") and was.get("releaseGroup"):
                    f["releaseGroup"] = was["releaseGroup"]
                self.sonarr.call("PUT", f"episodefile/{f['id']}", body=f)
        return True

    def _prune(self, folders, show):
        for d in sorted(folders, key=len, reverse=True):
            while d.startswith(show + "/") and os.path.isdir(d) and not os.path.islink(d) and not os.listdir(d):
                os.rmdir(d)
                d = os.path.dirname(d)

    def _record(self, show, title, moves):
        """Written down before anything moves: the store keeps the batch, and an undo
        script with the NAS's own paths goes beside the service's data."""
        stamp = dt.datetime.fromtimestamp(self.now()).strftime("%Y%m%d-%H%M%S")
        batches = self.store.get("seasons.batches", [])
        batches.append({"at": self.now(), "show": title, "moves": [[s, d] for s, d, _ in moves]})
        self.store.put("seasons.batches", batches[-50:])
        if not self.data_dir:
            return
        lines = ["#!/bin/sh", f"# Magnet season folders, {title}, {stamp}: puts every file back (newest first)",
                 "set -u"]
        for src, dst, _ in reversed(moves):
            hs, hd = self.library.to_host(src) or src, self.library.to_host(dst) or dst
            lines.append(f"[ -e {shlex.quote(hd)} ] && mkdir -p {shlex.quote(os.path.dirname(hs))}"
                         f" && mv -n {shlex.quote(hd)} {shlex.quote(hs)}")
        tag = hashlib.sha1(show.encode()).hexdigest()[:6]
        script = os.path.join(self.data_dir, f"season-undo-{stamp}-{tag}.sh")
        with open(script, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(script, 0o755)

    # -- Sonarr ------------------------------------------------------------------
    def _capture(self, series_id):
        """Each episode file's release name, by file name: Sonarr scores a file by it,
        and loses it when the file turns up somewhere new."""
        out = {}
        for f in self.sonarr.get("episodefile", seriesId=series_id) or []:
            if f.get("sceneName"):
                out[os.path.basename(f.get("relativePath") or "")] = {
                    "sceneName": f["sceneName"], "releaseGroup": f.get("releaseGroup")}
        return out

    # -- Plex --------------------------------------------------------------------
    def _snapshot(self, plex_show, moves):
        """Watched marks and resume points of the episodes about to move, each with where
        Plex will find its file afterwards."""
        going = {s: d for s, d, _ in moves}
        out = {}
        for e in self.plex.episodes(plex_show[1]):
            dests = [self.library.to_plex(going[h]) for h in (self.library.from_plex(f) for f in e["files"])
                     if h in going]
            if dests and (e["watched"] or e["offset"]):
                out[f"{e['season']}.{e['index']}"] = [e["watched"], e["offset"], dests]
        return out

    def _tell_plex(self, plex_show, show, snapshot, moved):
        section, key = plex_show
        try:
            self.plex.refresh(section, self.library.to_plex(show))
        except (urllib.error.URLError, OSError) as e:
            self.log(f"seasons: Plex did not take the rescan ({e}); its own scan will find the files")
        if snapshot:
            jobs = self.store.get("seasons.rewatch", [])
            jobs.append({"key": key, "snap": snapshot, "due": [self.now() + d for d in self.REWATCH_AFTER]})
            self.store.put("seasons.rewatch", jobs)

    def _rewatch(self):
        """Puts back a watched mark or resume point Plex dropped when the file moved --
        once, and only after Plex has found the file where it is now; until then an
        episode is not judged, and afterwards anything changed is your own doing."""
        jobs = self.store.get("seasons.rewatch", [])
        if not jobs or not self.plex:
            return
        now, left = self.now(), []
        for job in jobs:
            if job["due"] and job["due"][0] <= now:
                try:
                    for e in self.plex.episodes(job["key"]):
                        k = f"{e['season']}.{e['index']}"
                        was = job["snap"].get(k)
                        if not was or not set(e["files"]) & set(was[2]):
                            continue
                        if was[0] and not e["watched"]:
                            self.plex.scrobble(e["key"])
                        elif was[1] and not e["watched"] and not e["offset"]:
                            self.plex.progress(e["key"], was[1])
                        del job["snap"][k]
                except (urllib.error.URLError, OSError, ValueError):
                    pass
                job["due"] = job["due"][1:]
            if job["due"] and job["snap"]:
                left.append(job)
        self.store.put("seasons.rewatch", left)
