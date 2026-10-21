#!/usr/bin/env python3
"""Undo setup_sonarr.py from the snapshot it wrote.

  python3 rollback_sonarr.py <AUTOMATIC_DATA>/rollback/sonarr-YYYYMMDD-HHMMSS.json

Restores which download clients are enabled, Completed Download Handling, the quality
size limits, every show's monitored flag, quality profile and new-season setting, and
the monitored flag of every episode that existed at the time (newer ones are left
alone). The custom formats,
the Magnet profile and the gate client are left in place, unused; delete them in
Sonarr if you want them gone. Use the snapshot the setup printed: sonarr-original.json
is the state from before the first run. Sonarr's own backup from the same morning is the
fallback for anything this does not cover.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

SONARR = os.environ.get("SONARR_URL", "http://127.0.0.1:8989")

def _config_path():
    if os.environ.get("SONARR_CONFIG_FILE"):
        return os.environ["SONARR_CONFIG_FILE"]
    env = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    for line in open(env):
        if line.startswith("SONARR_CONFIG_FILE="):
            return line.split("=", 1)[1].strip()
    sys.exit("set SONARR_CONFIG_FILE in .env")


KEY = re.search(r"<ApiKey>([^<]+)</ApiKey>", open(_config_path()).read()).group(1)


def call(method, path, body=None, **params):
    url = f"{SONARR}/api/v3/{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method,
                                 headers={"X-Api-Key": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def main(path):
    snap = json.load(open(path))
    # Download clients and import settings first: they matter most, and nothing
    # later in this script should be able to stop them being restored.
    enabled = {d["id"]: d["enable"] for d in snap["downloadClients"]}
    for d in call("GET", "downloadclient"):
        state = enabled.get(d["id"], False)
        if d["enable"] != state:
            d["enable"] = state
            call("PUT", f"downloadclient/{d['id']}", d)
            print(f"download client {d['name']}: {'enabled' if state else 'disabled'}")
    if snap.get("completedDownloadHandling") is not None:
        cfg = call("GET", "config/downloadclient")
        cfg["enableCompletedDownloadHandling"] = snap["completedDownloadHandling"]
        if snap.get("redownloadFailed") is not None:
            cfg["autoRedownloadFailed"] = snap["redownloadFailed"]
        call("PUT", f"config/downloadclient/{cfg['id']}", cfg)
        print(f"Completed Download Handling: {'on' if snap['completedDownloadHandling'] else 'off'}")
    if snap.get("propersAndRepacks"):
        media = call("GET", "config/mediamanagement")
        media["downloadPropersAndRepacks"] = snap["propersAndRepacks"]
        call("PUT", f"config/mediamanagement/{media['id']}", media)
        print(f"Propers and Repacks: {snap['propersAndRepacks']}")
    if snap.get("qualityDefinitions"):
        old = {q["id"]: q for q in snap["qualityDefinitions"]}
        defs = call("GET", "qualitydefinition")
        for q in defs:
            if q["id"] in old:
                q.update({k: old[q["id"]][k] for k in ("minSize", "maxSize", "preferredSize")})
        call("PUT", "qualitydefinition/update", defs)
        print("quality size limits restored")

    # Episodes: only the ones that existed when the snapshot was taken. Anything added
    # since (a new season, a show followed later) keeps whatever it has now.
    if "episodes" in snap:
        flags = {int(k): v for k, v in snap["episodes"].items()}
    else:  # snapshots from before per-episode flags were recorded
        flags = None
        want = set(snap["monitoredEpisodes"])
    for s in snap["series"]:
        try:
            eps = call("GET", "episode", seriesId=s["id"])
            full = call("GET", f"series/{s['id']}")
        except urllib.error.HTTPError as e:
            print(f"{s['title']}: skipped ({e.code}; deleted since?)")
            continue
        if flags is not None:
            on = [e["id"] for e in eps if flags.get(e["id"]) is True and not e["monitored"]]
            off = [e["id"] for e in eps if flags.get(e["id"]) is False and e["monitored"]]
        else:
            on = [e["id"] for e in eps if e["id"] in want and not e["monitored"]]
            off = []
        if on:
            call("PUT", "episode/monitor", {"episodeIds": on, "monitored": True})
        if off:
            call("PUT", "episode/monitor", {"episodeIds": off, "monitored": False})
        full.update(monitored=s["monitored"], qualityProfileId=s["qualityProfileId"])
        if s.get("monitorNewItems"):
            full["monitorNewItems"] = s["monitorNewItems"]
        call("PUT", f"series/{s['id']}", full)
        print(f"{s['title']}: +{len(on)} -{len(off)} episodes")
    print("rolled back")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
