"""Entry point: the gate for Sonarr, the API for Magnet, and their workers."""

import http.server
import os
import re
import sys
import threading

from .api import API, make_handler as api_handler
from .gate import Gate, make_handler as gate_handler
from .qbit import QBit
from .scout import Scout
from .sonarr import Sonarr, read_api_key
from .sources import Prowlarr, ProwlarrError, SourceSync, read_api_key as prowlarr_key
from .store import Store


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def env(name, default=None):
    v = os.environ.get(name, default)
    if v is None or v == "":
        sys.exit(f"{name} is not set")
    return v


def plex_access():
    prefs = os.environ.get("PLEX_PREFS")
    url = os.environ.get("PLEX_URL")
    if not prefs or not url:
        return None
    try:
        with open(prefs) as f:
            m = re.search(r'PlexOnlineToken="([^"]+)"', f.read())
        return (url.rstrip("/"), m.group(1)) if m else None
    except OSError:
        return None


def main():
    data = env("DATA_DIR", "/data")
    os.makedirs(data, exist_ok=True)
    store = Store(os.path.join(data, "automatic.db"))
    qbit = QBit(env("QB_URL"), os.path.join(data, "secrets.json"))
    # Short timeout: a Sonarr frozen by stream-guard must not stall the watcher.
    sonarr = Sonarr(env("SONARR_URL"), read_api_key(env("SONARR_CONFIG")), timeout=10)
    gate = Gate(qbit, sonarr, store, env("QB_CATEGORY", "tv-sonarr"), env("GATE_USER"), env("GATE_PASS"),
                int(float(env("MIN_FREE_GB", "100")) * 1024 ** 3), log)
    src, _, dst = env("PATH_MAP", "/downloads/=/seedbox/downloads/").partition("=")
    sources = None
    if os.environ.get("PROWLARR_URL") and os.environ.get("PROWLARR_CONFIG"):
        try:
            key = prowlarr_key(os.environ["PROWLARR_CONFIG"])
            sources = SourceSync(Prowlarr(os.environ["PROWLARR_URL"], key), store, log,
                                 sonarr_app=os.environ.get("PROWLARR_SONARR_APP", ""))
        except (OSError, ProwlarrError) as e:
            log(f"magnet-automatic: no Prowlarr ({e}); the site list will not decide sources")
    scout = Scout(gate, sonarr, store, log,
                  window_days=float(env("SCOUT_WINDOW_DAYS", "7")),
                  upgrade_every_hours=float(env("SCOUT_UPGRADE_EVERY_HOURS", "6")),
                  stall_hours=float(env("SCOUT_STALL_HOURS", "3")),
                  remove_superseded=env("SCOUT_REMOVE_SUPERSEDED", "true").lower() == "true",
                  first_copy_max_hours=float(env("SCOUT_FIRST_COPY_MAX_HOURS", "4")))
    api = API(gate, sonarr, store, env("API_TOKEN"), (src, dst), plex_access(),
              int(env("SUGGEST_WATCHED_DAYS", "30")), log, sources, scout,
              auto_copy=env("AUTO_COPY", "true").lower() == "true")

    threading.Thread(target=gate.run, name="watcher", daemon=True).start()
    threading.Thread(target=api.watch_transfers, name="transfers", daemon=True).start()
    if sources:
        threading.Thread(target=sources.run, name="sources", daemon=True).start()
    threading.Thread(target=scout.run, name="scout", daemon=True).start()
    gate_srv = http.server.ThreadingHTTPServer(("0.0.0.0", int(env("GATE_PORT", "8791"))), gate_handler(gate))
    api_srv = http.server.ThreadingHTTPServer(("0.0.0.0", int(env("API_PORT", "8790"))), api_handler(api))
    threading.Thread(target=gate_srv.serve_forever, name="gate", daemon=True).start()
    log(f"magnet-automatic: gate on :{gate_srv.server_address[1]}, API on :{api_srv.server_address[1]};"
        f" seedbox login {'present' if qbit.configured else 'NOT SET'}")
    api_srv.serve_forever()


if __name__ == "__main__":
    main()
