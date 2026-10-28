#!/usr/bin/env python3
"""Point Sonarr at Magnet's automatic side. Idempotent; snapshots everything it changes.

  python3 setup_sonarr.py --plan      show what would change, change nothing
  python3 setup_sonarr.py             apply
  python3 rollback_sonarr.py FILE     undo, from the snapshot this writes

What it sets up:

1. Custom formats (TRaSH Guides' regexes, vendored in formats/) and a "Magnet"
   quality profile that scores what makes a release good, in this order: Dolby
   Vision above everything else put together, then 2160p, then HDR, then who made
   the release (TRaSH's group tiers), then audio. 1080p and 2160p from every source
   share one quality tier, so it is the score that decides -- which is what makes
   Dolby Vision win every time. Known-bad releases (low-quality groups, upscales,
   retags, obfuscated names, AV1, foreign-only audio, disc images) are banned.
   Upgrades have no score ceiling: the scout's one-week window is what ends them.
2. A title-level ban on executables, as a first fence before the gate's file check.
3. Minimum sizes per minute, so a "2160p" that is 300 MB is never taken.
4. The download client: the seedbox qBittorrent, through Magnet's gate. Any
   rTorrent client stays configured but disabled, for rollback.
5. A remote path mapping so Sonarr can find the gate's downloads on the rclone mount.
6. New episodes only: every episode that has already aired is unmonitored, so RSS
   can never turn a back catalogue into a pile of downloads (monitoring every aired
   episode is how decade-old episodes and a 0.9 GB .scr arrived). Shows that are
   still airing and monitored move to the Magnet profile.
"""

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def dotenv(path=os.path.join(HERE, ".env")):
    out = {}
    try:
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


ENV = dotenv()
SONARR = os.environ.get("SONARR_URL", "http://127.0.0.1:8989")
CONFIG = os.environ.get("SONARR_CONFIG_FILE") or ENV.get("SONARR_CONFIG_FILE", "")
DATA = os.environ.get("AUTOMATIC_DATA") or ENV.get("AUTOMATIC_DATA", "")
SNAPSHOTS = os.path.join(DATA, "rollback")

PROFILE = "Magnet"
# Magnet's custom formats carry this prefix, so they can never overwrite formats of
# the same name that something else (another profile, a TRaSH sync tool) relies on.
PREFIX = "Magnet: "
CLIENT = "Seedbox qBittorrent (via Magnet)"
# The default Docker bridge gateway: the gate's port is published only there, so
# only containers (Sonarr) can reach it.
GATE_HOST, GATE_PORT = "172.17.0.1", 8791

FORMATS_DIR = os.path.join(HERE, "formats")
TRASH_RAW = "https://raw.githubusercontent.com/TRaSH-Guides/Guides/master/docs/json/sonarr/cf/"

# What makes a release good, as scores: Dolby Vision (10000) > 2160p (3000) > HDR
# (1000) > release group (<=900) > audio (<=300) > the small stuff. Dolby Vision and
# 2160p each outweigh everything below them put together; HDR does not quite (a top
# release group with the best audio reaches 1200). A ban sits so far below zero that no
# amount of the above can lift a release back over the minimum.
BAN = -100000
EXEC_NAME = "Banned: executable"
SCORES = {
    "DV Boost": 10000, "DV (w/o HDR fallback)": -200,          # DV wins; with an HDR10 fallback, slightly more
    "2160p": 3000, "1080p": 500,
    "HDR": 1000, "HDR10+ Boost": 100,
    "Remux Tier 01": 900, "Remux Tier 02": 850, "HD Bluray Tier 01": 800, "HD Bluray Tier 02": 750,
    "WEB Tier 01": 700, "WEB Tier 02": 650, "WEB Tier 03": 600, "WEB Scene": 600,
    "Hybrid": 100, "UHD Streaming Boost": 75, "HD Streaming Boost": 75,
    "TrueHD ATMOS": 300, "DTS X": 250, "DD+ ATMOS": 250, "ATMOS (undefined)": 220, "TrueHD": 200,
    "DTS-HD MA": 200, "FLAC": 150, "PCM": 150, "DTS-HD HRA": 120, "DD+": 100, "DTS-ES": 80, "DTS": 60, "DD": 40,
    "Repack/Proper": 5, "Repack2": 6, "Repack3": 7, "INTERNAL": 10,
    "No-RlsGroup": -500,                                        # a hint, not a ban: public trackers are untidy
    # TRaSH bans these, tuned for private trackers. On public ones they are most of
    # what arrives first: "[TGx]" / "[EZTVx.to]" suffixes (Retags) are the tracker's
    # tag, not a re-labelled release, and the low-quality encoders (LQ) are often the
    # first copy of an episode. So they lose to anything better, and are still a first
    # copy when they are all there is -- the week of looking replaces them.
    "Retags": -50, "LQ": -1000, "LQ (Release Title)": -1000,
    "BR-DISK": BAN, "Upscaled": BAN, "AV1": BAN, "x266": BAN, "Extras": BAN, "Bad Dual Groups": BAN,
    "Obfuscated": BAN,
    # Audio in a language the show was not made in (an Italian-only dub of an English
    # show). "Not English" would also ban every release of a Korean or Japanese show,
    # whose untagged releases Sonarr reads as the original language.
    "Language: Not Original": BAN,
    EXEC_NAME: BAN,
}
EXEC_FORMAT = {"name": EXEC_NAME, "includeCustomFormatWhenRenaming": False, "specifications": [{
    "name": EXEC_NAME, "implementation": "ReleaseTitleSpecification", "negate": False, "required": True,
    # Anchored to the end: ".Bat." is an episode title ("Cricket Bat"), not an extension.
    "fields": [{"name": "value", "value": r"\.(exe|scr|msi|bat|cmd|lnk|pif|vbs|ps1|hta|jar|dmg|pkg)$"}]}]}

# 720p is a fallback below everything else. 1080p and 2160p from every source share
# ONE tier, so Sonarr ranks them by score alone: otherwise a non-DV Blu-ray would
# outrank a DV web release on source before the score was ever looked at.
TIERS = [("HD 720p", ["HDTV-720p", "WEBRip-720p", "WEBDL-720p", "Bluray-720p"]),
         ("HD and UHD", ["HDTV-1080p", "WEBRip-1080p", "WEBDL-1080p", "Bluray-1080p", "Bluray-1080p Remux",
                         "HDTV-2160p", "WEBRip-2160p", "WEBDL-2160p", "Bluray-2160p", "Bluray-2160p Remux"])]
# Smallest believable size, MB per minute of runtime (2160p web ~ 2 Mbps floor).
MIN_MB_PER_MIN = {"WEBDL-2160p": 15, "WEBRip-2160p": 15, "HDTV-2160p": 15, "Bluray-2160p": 25,
                  "Bluray-2160p Remux": 50, "WEBDL-1080p": 6, "WEBRip-1080p": 6, "HDTV-1080p": 6,
                  "Bluray-1080p": 8, "Bluray-1080p Remux": 20}


def load_formats():
    """The vendored TRaSH formats that have a score, in the shape Sonarr's API takes."""
    out = [EXEC_FORMAT]
    for f in sorted(os.listdir(FORMATS_DIR)):
        if not f.endswith(".json"):
            continue
        d = json.load(open(os.path.join(FORMATS_DIR, f)))
        if d["name"] not in SCORES:
            continue
        specs = []
        for sp in d["specifications"]:
            fields = sp.get("fields", {})
            if isinstance(fields, dict):  # TRaSH writes {"value": x}; the API wants [{"name", "value"}]
                fields = [{"name": k, "value": v} for k, v in fields.items()]
            specs.append({"name": sp["name"], "implementation": sp["implementation"],
                          "negate": sp.get("negate", False), "required": sp.get("required", False), "fields": fields})
        out.append({"name": d["name"], "includeCustomFormatWhenRenaming": False, "specifications": specs})
    missing = set(SCORES) - {f["name"] for f in out}
    if missing:
        sys.exit(f"formats missing from {FORMATS_DIR}: {sorted(missing)}")
    return out


def refresh_formats():
    for f in sorted(os.listdir(FORMATS_DIR)):
        if f.endswith(".json"):
            with urllib.request.urlopen(TRASH_RAW + f, timeout=30) as r:
                data = r.read()
            json.loads(data)
            with open(os.path.join(FORMATS_DIR, f), "wb") as out:
                out.write(data)
            print("refreshed", f)


def profile_items(template_items):
    quals = {}

    def walk(items):
        for it in items:
            if it.get("quality"):
                quals[it["quality"]["name"]] = it["quality"]
            walk(it.get("items", []))
    walk(template_items)
    grouped = {n for _, names in TIERS for n in names}
    items = [{"quality": q, "items": [], "allowed": False} for n, q in quals.items() if n not in grouped]
    for i, (name, names) in enumerate(TIERS):
        items.append({"id": 1100 + i, "name": name, "allowed": True,
                      "items": [{"quality": quals[n], "items": [], "allowed": True} for n in names]})
    return items


def key():
    if not CONFIG:
        sys.exit("set SONARR_CONFIG_FILE in .env (the host path of Sonarr's config.xml)")
    return re.search(r"<ApiKey>([^<]+)</ApiKey>", open(CONFIG).read()).group(1)


def call(method, path, body=None, fatal=True, **params):
    url = f"{SONARR}/api/v3/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method,
                                 headers={"X-Api-Key": KEY, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        detail = f"{method} {path}: {e.code} {e.read()[:400].decode('utf-8', 'replace')}"
        if fatal:
            sys.exit(detail)
        raise RuntimeError(detail) from None
    return json.loads(raw) if raw else None


def gate_password():
    if not ENV.get("GATE_PASS"):
        sys.exit("no GATE_PASS in .env; run deploy.sh first")
    return ENV["GATE_PASS"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", action="store_true", help="show the changes without making them")
    ap.add_argument("--refresh-formats", action="store_true", help="re-download the vendored TRaSH formats")
    args = ap.parse_args()
    if args.refresh_formats:
        refresh_formats()
        return
    plan = args.plan
    now = dt.datetime.now(dt.timezone.utc)
    if not plan and not DATA:
        # Never fall back to the checkout: the snapshot lists every show in the library.
        sys.exit("set AUTOMATIC_DATA in .env (where the service keeps its data); the snapshot is written there")

    def do(desc, fn):
        print(("would " if plan else "") + desc)
        return None if plan else fn()

    # -- snapshot first ----------------------------------------------------------
    series = call("GET", "series")
    episodes = {s["id"]: call("GET", "episode", seriesId=s["id"]) for s in series}
    clients = call("GET", "downloadclient")
    dlconfig = call("GET", "config/downloadclient")
    media = call("GET", "config/mediamanagement")
    snap = {"taken": now.isoformat(),
            "series": [{"id": s["id"], "title": s["title"], "monitored": s["monitored"],
                        "qualityProfileId": s["qualityProfileId"], "monitorNewItems": s.get("monitorNewItems")}
                       for s in series],
            # Every episode that existed, with its flag: rollback restores these and
            # leaves alone any episode added since.
            "episodes": {str(e["id"]): e["monitored"] for eps in episodes.values() for e in eps},
            "downloadClients": [{"id": d["id"], "name": d["name"], "enable": d["enable"]} for d in clients],
            "completedDownloadHandling": dlconfig.get("enableCompletedDownloadHandling"),
            "redownloadFailed": dlconfig.get("autoRedownloadFailed"),
            "propersAndRepacks": media.get("downloadPropersAndRepacks"),
            "qualityDefinitions": [{"id": q["id"], "minSize": q.get("minSize"), "maxSize": q.get("maxSize"),
                                    "preferredSize": q.get("preferredSize")} for q in call("GET", "qualitydefinition")]}

    # -- the gate first: nothing else changes unless Sonarr can reach it -------------
    gate = next((d for d in clients if d["name"] == CLIENT), None)
    if not gate:
        gate = next(c for c in call("GET", "downloadclient/schema") if c["implementation"] == "QBittorrent")
    values = {"host": GATE_HOST, "port": GATE_PORT, "useSsl": False, "urlBase": "", "username": "sonarr",
              "password": gate_password() if not plan else "(from .env)", "tvCategory": "tv-sonarr",
              "tvImportedCategory": "", "recentTvPriority": 0, "olderTvPriority": 0, "initialState": 0,
              "sequentialOrder": False, "firstAndLast": False, "contentLayout": 0}
    for f in gate["fields"]:
        if f["name"] in values:
            f["value"] = values[f["name"]]
    gate.update(name=CLIENT, enable=True, priority=1, removeCompletedDownloads=False, removeFailedDownloads=True,
                protocol="torrent")
    if not plan:
        try:
            call("POST", "downloadclient/test", gate, fatal=False)
        except RuntimeError as e:
            sys.exit(f"Sonarr cannot reach the gate yet, so nothing was changed: {e}\n"
                     "Give the NAS the seedbox sign-in from Magnet (Settings -> Automatic), then run this again.")
        os.makedirs(SNAPSHOTS, exist_ok=True)
        def private(p):
            return os.fdopen(os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w")
        path = os.path.join(SNAPSHOTS, f"sonarr-{now.strftime('%Y%m%d-%H%M%S')}.json")
        with private(path) as f:
            json.dump(snap, f)
        original = os.path.join(SNAPSHOTS, "sonarr-original.json")
        if not os.path.exists(original):
            # The state from before the very first run, never overwritten: a second
            # run's snapshot already holds the changed state.
            with private(original) as f:
                json.dump(snap, f)
        print(f"snapshot: {path}\nto undo everything: python3 rollback_sonarr.py {original}")

    # -- custom formats ----------------------------------------------------------
    existing = {c["name"]: c for c in call("GET", "customformat")}
    ids = {}
    for body in load_formats():
        name = body["name"]
        body = dict(body, name=PREFIX + name)
        if body["name"] in existing:
            body["id"] = existing[body["name"]]["id"]
            ids[name] = body["id"]
            do(f"update custom format {body['name']}", lambda b=body: call("PUT", f"customformat/{b['id']}", b))
        else:
            r = do(f"create custom format {body['name']}", lambda b=body: call("POST", "customformat", b))
            ids[name] = r["id"] if r else None

    # -- quality profile ---------------------------------------------------------
    profiles = call("GET", "qualityprofile")
    mine = next((p for p in profiles if p["name"] == PROFILE), None)
    # Any profile lists every quality; "Ultra-HD" is only the default's name, and
    # setups managed by sync tools often rename or remove it.
    template = mine or next((p for p in profiles if p["name"] == "Ultra-HD"), profiles[0] if profiles else None)
    if template is None:
        sys.exit("Sonarr has no quality profile at all to start from")
    prof = json.loads(json.dumps(mine or template))
    if not mine:
        prof.pop("id", None)
    prof["name"] = PROFILE
    prof["items"] = profile_items(template["items"])
    prof["cutoff"] = 1100 + len(TIERS) - 1
    prof["upgradeAllowed"] = True
    # Penalties (no release group, a low-quality encoder) may still be a first copy;
    # bans may not. An LQ 1080p release scores about -400, a ban below -90000.
    prof["minFormatScore"] = -1000
    # No ceiling: within the scout's week every real upgrade is taken.
    prof["cutoffFormatScore"] = 100000
    # A repack tag or a streaming-service bonus alone is not worth a second download.
    prof["minUpgradeFormatScore"] = 100
    if not plan:
        # Sonarr wants every custom format listed; anything not Magnet's scores 0 here.
        prof["formatItems"] = [{"format": c["id"], "name": c["name"],
                                "score": SCORES.get(c["name"][len(PREFIX):], 0) if c["name"].startswith(PREFIX) else 0}
                               for c in call("GET", "customformat")]
    if mine:
        do(f"update quality profile {PROFILE}", lambda: call("PUT", f"qualityprofile/{prof['id']}", prof))
        profile_id = mine["id"]
    else:
        r = do(f"create quality profile {PROFILE}", lambda: call("POST", "qualityprofile", prof))
        profile_id = r["id"] if r else None

    # -- sizes -------------------------------------------------------------------
    defs = call("GET", "qualitydefinition")
    changed = []
    for q in defs:
        floor = MIN_MB_PER_MIN.get(q["quality"]["name"])
        if floor is not None and (q.get("minSize") or 0) < floor:
            q["minSize"] = floor
            if q.get("preferredSize") is not None and q["preferredSize"] < floor:
                q["preferredSize"] = floor
            changed.append(q)
    if changed:
        do(f"raise minimum sizes for {', '.join(q['quality']['name'] for q in changed)}",
           lambda: call("PUT", "qualitydefinition/update", changed))

    # -- download clients ----------------------------------------------------------
    if gate.get("id"):
        do(f"update download client {CLIENT}", lambda: call("PUT", f"downloadclient/{gate['id']}", gate))
    else:
        do(f"add download client {CLIENT} -> {GATE_HOST}:{GATE_PORT}", lambda: call("POST", "downloadclient", gate))
    # Every other torrent client is turned off: one left on would get some of the
    # grabs, and those would reach the seedbox without the gate ever reading them.
    for d in clients:
        if d["name"] != CLIENT and d.get("protocol") == "torrent" and d["enable"]:
            d["enable"] = False
            do(f"disable download client {d['name']}", lambda d=d: call("PUT", f"downloadclient/{d['id']}", d))
    # Episodes reach the NAS only through Magnet's copy (by itself, or Bring to NAS),
    # which checks the files again first. With this on, Sonarr would import each one
    # the moment it finished, past that check.
    if dlconfig.get("enableCompletedDownloadHandling") or not dlconfig.get("autoRedownloadFailed"):
        dlconfig.update(enableCompletedDownloadHandling=False, autoRedownloadFailed=True)
        do("turn off Completed Download Handling (keep re-searching after a failure)",
           lambda: call("PUT", f"config/downloadclient/{dlconfig['id']}", dlconfig))
    if not plan and call("GET", "config/downloadclient").get("enableCompletedDownloadHandling") is not False:
        # If this Sonarr ignores the setting, it would import every episode the moment it
        # finished, past Magnet's copy and its file check. Say so instead of "done".
        sys.exit("Sonarr did not turn off Completed Download Handling; turn it off in Settings -> "
                 "Download Clients before using Automatic mode")

    # Sonarr ranks a REPACK above any score while this is "prefer and upgrade": a
    # 1080p repack would beat a Dolby Vision release, and the week would become a loop
    # of downloading and retiring it. The score decides; repacks still break ties.
    if media.get("downloadPropersAndRepacks") != "doNotPrefer":
        media["downloadPropersAndRepacks"] = "doNotPrefer"
        do("let the score decide over REPACK/PROPER (Propers and Repacks: Do not Prefer)",
           lambda: call("PUT", f"config/mediamanagement/{media['id']}", media))

    # -- path mapping ------------------------------------------------------------
    maps = call("GET", "remotepathmapping")
    if not any(m["host"] == GATE_HOST and m["remotePath"] == "/downloads/" for m in maps):
        do("map /downloads/ on the gate -> /seedbox/downloads/",
           lambda: call("POST", "remotepathmapping", {"host": GATE_HOST, "remotePath": "/downloads/",
                                                      "localPath": "/seedbox/downloads/"}))

    # -- new episodes only -------------------------------------------------------
    past = [e["id"] for eps in episodes.values() for e in eps
            if e["monitored"] and e.get("airDateUtc") and e["airDateUtc"] < now.isoformat().replace("+00:00", "Z")]
    print(f"{len(past)} already-aired episodes are monitored")
    for i in range(0, len(past), 500):
        chunk = past[i:i + 500]
        do(f"unmonitor {len(chunk)} aired episodes", lambda c=chunk: call("PUT", "episode/monitor",
                                                                          {"episodeIds": c, "monitored": False}))
    for s in series:
        if s["monitored"] and s.get("status") != "ended" and (s["qualityProfileId"] != profile_id or
                                                              s.get("monitorNewItems") != "all"):
            def move(s=s):
                full = call("GET", f"series/{s['id']}")
                full.update(qualityProfileId=profile_id, monitorNewItems="all")
                call("PUT", f"series/{s['id']}", full)
            do(f"follow {s['title']} with the {PROFILE} profile", move)
    print("done" if not plan else "(plan only; nothing changed)")


if __name__ == "__main__":
    KEY = key()
    main()
