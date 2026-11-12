"""Bring a season to one format: the format of its biggest episodes.

A season can end up mixed. Most episodes come from one web release; one came from a
small re-encode that turned up first. Sonarr will not swap that one, because to its
scoring a copy of the same quality is no upgrade -- Magnet's own scoring may even rate
the re-encode higher. Matching a season is a request to swap it anyway: for each
episode whose file is not in the season's main format, a release in that format is
taken, checked at the gate like any download, and once it is finished it replaces the
library's file, whatever its score.

A format is what decides how an episode looks and how big it is: where it came from
(web, TV, Blu-ray), its resolution, its video codec, and HDR or Dolby Vision.

Only episodes the library has are matched. One without a file stays without: it may
have been deleted after watching, and matching must not bring it back.
"""

import datetime as dt
import re
import statistics
import threading
import time

from .sonarr import SonarrError

SOURCES = {"web": "WEB", "webrip": "WEB", "television": "HDTV", "televisionraw": "HDTV",
           "bluray": "Blu-ray", "blurayraw": "Blu-ray", "dvd": "DVD"}
_EDGE = r"(?<![a-z0-9])"
_END = r"(?![a-z0-9])"
CODECS = (("H.265", rf"{_EDGE}(?:[xh][ .]?265|hevc){_END}"),
          ("H.264", rf"{_EDGE}(?:[xh][ .]?264|avc){_END}"),
          ("AV1", rf"{_EDGE}av1{_END}"),
          ("XviD", rf"{_EDGE}(?:xvid|divx){_END}"),
          ("MPEG-2", rf"{_EDGE}mpeg-?2{_END}"),
          ("VC-1", rf"{_EDGE}vc-?1{_END}"))
DOLBY_VISION = re.compile(rf"(?<![a-z])(?:dv|dovi|dolby[ .]?vision)(?![a-z])", re.I)
HDR = re.compile(r"(?<![a-z])(?:hdr|hlg|pq)(?![a-z])|(?<![a-z])hdr10", re.I)
# What Sonarr says of a release that is fine except that the library already has a file
# it rates as good: exactly what matching overrides. Anything else (blocklisted, the
# wrong language, below the profile's minimum) still rules a release out.
SET_ASIDE = re.compile(r"^existing file", re.I)


def _ts(iso):
    if not iso:
        return None
    try:
        return dt.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def codec_of(text):
    t = (text or "").lower()
    return next((name for name, pattern in CODECS if re.search(pattern, t)), None)


def _range(text):
    if DOLBY_VISION.search(text or ""):
        return "Dolby Vision"
    return "HDR" if HDR.search(text or "") else "SDR"


def _source(quality):
    q = (quality or {}).get("quality") or {}
    if "remux" in (q.get("name") or "").lower():
        return "Remux"
    return SOURCES.get((q.get("source") or "").lower(), "Unknown")


def _resolution(quality):
    r = ((quality or {}).get("quality") or {}).get("resolution") or 0
    return f"{r}p" if r else None


def file_format(f):
    """The format of a library file, from what Sonarr read of the file itself, or --
    for a file it has not analysed -- its name and custom formats."""
    mi = f.get("mediaInfo") or {}
    names = " ".join(c.get("name", "") for c in f.get("customFormats") or [])
    seen = f"{mi.get('videoDynamicRangeType') or ''} {mi.get('videoDynamicRange') or ''}".strip()
    name = f.get("sceneName") or f.get("relativePath") or ""
    return {"source": _source(f.get("quality")), "resolution": _resolution(f.get("quality")),
            "codec": codec_of(mi.get("videoCodec")) or codec_of(name),
            "range": _range(seen) if mi else _range(f"{names} {name}")}


def release_format(r):
    names = " ".join(c.get("name", "") for c in r.get("customFormats") or [])
    return {"source": _source(r.get("quality")), "resolution": _resolution(r.get("quality")),
            "codec": codec_of(r.get("title")), "range": _range(f"{names} {r.get('title') or ''}")}


def label(fmt):
    words = [w for w in (fmt["source"], fmt["resolution"], fmt["codec"]) if w]
    return " ".join(words + ([fmt["range"]] if fmt["range"] != "SDR" else []))


def fits(have, want):
    """`have` is in the format `want`. What `want` does not know (a codec a file did not
    report) is not held against `have`; what `have` does not show is."""
    return all(want[k] is None or have[k] == want[k] for k in ("source", "resolution", "codec", "range"))


def choose(found, fmt):
    """The best release in the format `fmt` that is worth taking, or None: a torrent with
    seeders, not banned, refused by Sonarr for nothing but the library's file, and for
    the episode alone -- a season pack would bring every other episode with it."""
    good = []
    for r in found:
        if (r.get("protocol") or "torrent") != "torrent" or r.get("fullSeason"):
            continue
        if (r.get("customFormatScore") or 0) <= -10000 or (r.get("seeders") or 0) < 1:
            continue
        if not r.get("approved") and not all(SET_ASIDE.search(str(x)) for x in r.get("rejections") or ["?"]):
            continue
        if fits(release_format(r), fmt):
            good.append(r)
    return max(good, key=lambda r: (r.get("customFormatScore") or 0, r.get("seeders") or 0), default=None)


def summarize(episodes, files, target=None, orders=None, now=None):
    """One season, as matching sees it. `episodes`: Sonarr's records for the season;
    `files`: {file id: file}. Formats are grouped, biggest first by the median size of
    their files, and the target is the biggest -- or `target`, a group's label."""
    now = now if now is not None else time.time()
    orders = orders or {}
    groups, rows = {}, []
    for e in sorted(episodes, key=lambda e: e.get("episodeNumber") or 0):
        f = files.get(e.get("episodeFileId")) if e.get("hasFile") else None
        fmt = file_format(f) if f else None
        rows.append((e, f, fmt))
        if fmt:
            g = groups.setdefault(label(fmt), {"label": label(fmt), "format": fmt, "episodes": [], "sizes": []})
            g["episodes"].append(e.get("episodeNumber"))
            g["sizes"].append(f.get("size") or 0)
    ranked = sorted(({"label": g["label"], "format": g["format"], "episodes": g["episodes"],
                      "size": int(statistics.median(g["sizes"]))} for g in groups.values()),
                    key=lambda g: (-g["size"], -len(g["episodes"])))
    chosen = next((g for g in ranked if g["label"] == target), None) if target else None
    chosen = chosen or (ranked[0] if ranked else None)
    out = []
    for e, f, fmt in rows:
        if fmt:
            state = "match" if fits(fmt, chosen["format"]) else "off"
        elif (_ts(e.get("airDateUtc")) or float("inf")) <= now:
            state = "missing"
        else:
            state = "unaired"
        out.append({"id": e["id"], "episode": e.get("episodeNumber"), "format": label(fmt) if fmt else None,
                    "size": f.get("size") if f else None, "state": state, "matching": str(e["id"]) in orders})
    return {"target": chosen["label"] if chosen else None, "format": chosen["format"] if chosen else None,
            "groups": ranked, "episodes": out}


class SeasonMatch:
    # An order not done in this long is given up: no release in the format arrived.
    ORDER_DAYS = 3
    # Releases tried per episode when the gate refuses one (a fake, say).
    TRIES = 3

    def __init__(self, sonarr, store, log=print, clock=time.time, paused=lambda: False, background=True):
        self.sonarr = sonarr
        self.store = store
        self.log = log
        self.now = clock
        self.paused = paused
        self.background = background      # tests run a match in the calling thread
        self._job = None
        self._lock = threading.Lock()
        self._orders_lock = threading.Lock()
        self._last_tick = 0.0

    # -- the orders --------------------------------------------------------------
    def orders(self):
        """{episode id (str): order} for the episodes being matched."""
        return self.store.get("match.orders", {})

    def _put(self, eid, order):
        with self._orders_lock:
            orders = self.orders()
            if order is None:
                orders.pop(str(eid), None)
            else:
                orders[str(eid)] = order
            self.store.put("match.orders", orders)

    def hashes(self, grabs):
        """{torrent hash: order, with its episode id} for the grabs a match took.
        `grabs`: hash -> Sonarr's grabbed records."""
        orders = self.orders()
        if not orders:
            return {}
        out = {}
        for h, recs in grabs.items():
            for r in recs:
                o = orders.get(str(r.get("episodeId")))
                if o and r.get("sourceTitle") == o["title"] and (_ts(r.get("date")) or 0) >= o["at"] - 300:
                    out[h] = dict(o, episodeId=r["episodeId"])
        return out

    # -- a season ----------------------------------------------------------------
    def plan(self, series_id, season, target=None):
        eps = [e for e in self.sonarr.get("episode", seriesId=series_id) or [] if e.get("seasonNumber") == season]
        files = {f["id"]: f for f in self.sonarr.get("episodefile", seriesId=series_id) or []}
        return summarize(eps, files, target, self.orders(), self.now())

    def start(self, series_id, season, target=None):
        """Match a season: every episode the library has that is not in the target
        format gets a release in it. Returns at once; the searches run behind."""
        if self.paused():
            raise ValueError("Automatic is paused; resume it first")
        with self._lock:
            if self._job and self._job.is_alive():
                raise ValueError("another season is being matched; try again when it is done")
            p = self.plan(series_id, season, target)
            if not p["target"]:
                raise ValueError("the library has no episode of this season to match")
            todo = [e for e in p["episodes"] if e["state"] == "off" and not e["matching"]]
            codes = ", ".join(f"E{e['episode']:02d}" for e in todo if e["episode"] is not None)
            if not todo:
                busy = any(e["matching"] for e in p["episodes"])
                return {"started": 0, "target": p["target"],
                        "message": "The rest are on their way" if busy
                        else f"Every episode in the library is already {p['target']}"}
            self.log(f"match: season {season} of series {series_id}: {codes} to {p['target']}")
            job = lambda: [self._take(series_id, season, p["format"], e["id"]) for e in todo]
            if self.background:
                self._job = threading.Thread(target=job, name="match", daemon=True)
                self._job.start()
            else:
                job()
        return {"started": len(todo), "target": p["target"],
                "message": f"Looking for {p['target']} copies of {codes}"}

    def _take(self, series_id, season, fmt, eid, tries=1):
        """Search one episode and take the best release in `fmt`. The order is saved
        before the grab: the gate may see the torrent before this returns."""
        name = label(fmt)
        try:
            found = self.sonarr.call("GET", "release", {"episodeId": eid}, timeout=180) or []
        except SonarrError as e:
            self.store.event("match", "", f"episode {eid}: could not search for a {name} copy -- {e}")
            return None
        pick = choose(found, fmt)
        if not pick:
            self.store.event("match", "", f"episode {eid}: no {name} release to take yet")
            return None
        order = {"series": series_id, "season": season, "format": fmt, "label": name,
                 "title": pick.get("title"), "at": self.now(), "tries": tries}
        self._put(eid, order)
        try:
            self.sonarr.call("POST", "release", body={"guid": pick["guid"], "indexerId": pick["indexerId"]},
                             timeout=60)
        except SonarrError as e:
            self._put(eid, None)
            self.store.event("match", "", f"episode {eid}: could not take {pick.get('title')} -- {e}")
            return None
        self.log(f"match: took {pick.get('title')} for episode {eid} ({name})")
        self.store.event("match", "", f"episode {eid}: taking {pick.get('title')} to match the season ({name})")
        return pick.get("title")

    # -- the copy ----------------------------------------------------------------
    def import_copy(self, path, order):
        """Have Sonarr put the ordered episode from `path` in the library in place of
        its file. A manual import: the scan the automatic copy uses would keep the
        library's file, which Sonarr rates as good."""
        items = self.sonarr.get("manualimport", folder=path, seriesId=order["series"],
                                filterExistingFiles="false") or []
        found = [it for it in items if order["episodeId"] in [e.get("id") for e in it.get("episodes") or []]
                 and not any("sample" in str(r).lower() for r in it.get("rejections") or [])]
        if not found:
            raise ValueError("Sonarr did not find the episode in it")
        it = max(found, key=lambda it: it.get("size") or 0)
        return self.sonarr.call("POST", "command", body={
            "name": "ManualImport", "importMode": "copy",
            "files": [{"path": it["path"], "seriesId": order["series"],
                       "episodeIds": [e["id"] for e in it.get("episodes") or []],
                       "quality": it.get("quality"), "languages": it.get("languages") or [],
                       "releaseGroup": it.get("releaseGroup"), "indexerFlags": it.get("indexerFlags") or 0,
                       "releaseType": it.get("releaseType") or "singleEpisode"}]})

    def arrived(self, order, since):
        """The library's file for the ordered episode, if it is now in the format and
        was put there after `since`; else None."""
        eps = self.sonarr.get("episode", episodeIds=[order["episodeId"]]) or []
        e = eps[0] if eps else {}
        if not e.get("hasFile") or not e.get("episodeFileId"):
            return None
        f = self.sonarr.get(f"episodefile/{e['episodeFileId']}") or {}
        if fits(file_format(f), order["format"]) and (_ts(f.get("dateAdded")) or 0) >= since - 120:
            return f
        return None

    def tick(self, grabs, decisions, running=()):
        """Once a minute: an order whose episode is now in the format is done; one whose
        release the gate refused takes the next best; one too old is given up."""
        if self.now() - self._last_tick < 60 or self.paused():
            return
        self._last_tick = self.now()
        orders = self.orders()
        if not orders:
            return
        mine = self.hashes(grabs)
        for key, o in orders.items():
            eid = int(key)
            hs = [h for h, oo in mine.items() if oo["episodeId"] == eid]
            if set(hs) & set(running):
                continue                    # its copy is being made: the transfer says how it went
            try:
                eps = self.sonarr.get("episode", episodeIds=[eid]) or []
                e = eps[0] if eps else {}
                f = self.sonarr.get(f"episodefile/{e['episodeFileId']}") if e.get("hasFile") and e.get("episodeFileId") else None
            except SonarrError:
                return
            if f and fits(file_format(f), o["format"]):
                self._put(eid, None)
                self.store.event("matched", "", f"episode {eid}: now {o['label']}, like the rest of its season")
                continue
            refused = bool(hs) and all(decisions.get(h, {}).get("verdict") in ("rejected", "stalled") for h in hs)
            if refused and o.get("tries", 1) < self.TRIES:
                self._put(eid, None)
                retry = lambda o=o, eid=eid: self._take(o["series"], o["season"], o["format"], eid, o.get("tries", 1) + 1)
                if self.background:
                    threading.Thread(target=retry, name="match", daemon=True).start()
                else:
                    retry()
            elif refused or self.now() - o["at"] > self.ORDER_DAYS * 86400:
                self._put(eid, None)
                self.store.event("match", "", f"episode {eid}: gave up matching it to {o['label']}"
                                              + (" -- every release tried was refused" if refused
                                                 else " -- no copy arrived in three days"))
