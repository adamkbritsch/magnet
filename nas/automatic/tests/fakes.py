"""In-process stand-ins for the seedbox qBittorrent and the NAS Sonarr."""

import hashlib
import http.server
import json
import threading
import urllib.parse

from automatic import bencode
from automatic.gate import magnet_hash, parse_form


def benc(v):
    if isinstance(v, int):
        return b"i%de" % v
    if isinstance(v, str):
        v = v.encode()
    if isinstance(v, bytes):
        return b"%d:%s" % (len(v), v)
    if isinstance(v, list):
        return b"l" + b"".join(benc(x) for x in v) + b"e"
    if isinstance(v, dict):
        items = sorted((k.encode() if isinstance(k, str) else k, x) for k, x in v.items())
        return b"d" + b"".join(benc(k) + benc(x) for k, x in items) + b"e"
    raise TypeError(type(v))


def make_torrent(name, files):
    """files: [(relative path, size)] -> raw .torrent bytes (multi-file, or single when one file named like name)."""
    if len(files) == 1 and files[0][0] == name:
        info = {"name": name, "length": files[0][1], "piece length": 262144, "pieces": b"\0" * 20}
    else:
        info = {"name": name, "piece length": 262144, "pieces": b"\0" * 20,
                "files": [{"length": s, "path": p.split("/")} for p, s in files]}
    return benc({"announce": "udp://tracker.invalid:80", "info": info})


def info_hash(raw):
    return bencode.torrent_info(raw)["hash"]


class _Server:
    def __init__(self, handler_cls):
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
        self.httpd.owner = self
        self.port = self.httpd.server_address[1]
        self.url = f"http://127.0.0.1:{self.port}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class FakeQBit(_Server):
    PASSWORD = "right"

    def __init__(self):
        self.torrents = {}
        self.calls = []        # (method, path, fields)
        self.logins = 0
        self.free = 500 * 1024 ** 3
        super().__init__(_QBHandler)

    def finish_metadata(self, h, files, name=None):
        t = self.torrents[h]
        t["files"] = [{"name": p, "size": s} for p, s in files]
        t["name"] = name or t["name"]
        t["content_path"] = "/downloads/tv-sonarr/" + t["name"]
        t["state"] = "stoppedDL" if t.get("stop_at_metadata") else "downloading"

    def actions(self, path):
        return [c for c in self.calls if c[1] == path]


class _QBHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, status, body=b"", ctype="text/plain", headers=()):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _go(self, method):
        q = self.server.owner
        path, _, query = self.path.partition("?")
        params = dict(urllib.parse.parse_qsl(query))
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        fields = parse_form(body, self.headers.get("Content-Type")) if body else []
        form = {f["name"]: f["data"].decode("utf-8", "replace") for f in fields if f["filename"] is None}
        q.calls.append((method, path, fields))
        if path == "/api/v2/auth/login":
            q.logins += 1
            if form.get("password") == q.PASSWORD:
                return self._send(204, headers=[("Set-Cookie", "QBT_SID_6885=sess; HttpOnly; path=/")])
            return self._send(200, b"Fails.")
        if "QBT_SID_6885=sess" not in (self.headers.get("Cookie") or ""):
            return self._send(403, b"Forbidden")
        if path == "/api/v2/app/webapiVersion":
            return self._send(200, b"2.11.4")
        if path == "/api/v2/sync/maindata":
            return self._send(200, json.dumps({"server_state": {"free_space_on_disk": q.free}}).encode(), "application/json")
        if path == "/api/v2/torrents/info":
            if "hashes" in params:
                wanted = set(params["hashes"].split("|"))
                rows = [dict(t, files=None) for t in q.torrents.values() if t["hash"] in wanted]
            else:
                rows = [dict(t, files=None) for t in q.torrents.values() if t["category"] == params.get("category")]
            return self._send(200, json.dumps(rows).encode(), "application/json")
        if path == "/api/v2/torrents/files":
            return self._send(200, json.dumps(q.torrents.get(params.get("hash"), {}).get("files", [])).encode(),
                              "application/json")
        if path == "/api/v2/torrents/add":
            stopped = form.get("stopped") == "true"
            for f in fields:
                if f["name"] == "torrents":
                    try:
                        info = bencode.torrent_info(f["data"])
                    except bencode.BencodeError:
                        return self._send(415, b"Fails.")     # what qBittorrent says to a bad file
                    q.torrents[info["hash"]] = {
                        "hash": info["hash"], "name": info["name"], "category": form.get("category", ""),
                        "state": "stoppedDL" if stopped else "downloading", "progress": 0.0, "added_on": 1,
                        "content_path": "/downloads/tv-sonarr/" + info["name"],
                        "files": [{"name": p, "size": s} for p, s in info["files"]]}
            for u in form.get("urls", "").splitlines():
                h = magnet_hash(u)
                q.torrents[h] = {"hash": h, "name": h, "category": form.get("category", ""), "state": "metaDL",
                                 "progress": 0.0, "added_on": 2, "files": [], "magnet_uri": u,
                                 "stop_at_metadata": form.get("stopCondition") == "MetadataReceived"}
            return self._send(200, b"Ok.")
        if path == "/api/v2/torrents/recheck":
            for h in form.get("hashes", "").split("|"):
                if h in q.torrents:
                    q.torrents[h]["state"] = "checkingDL"
            return self._send(200)
        if path in ("/api/v2/torrents/start", "/api/v2/torrents/stop", "/api/v2/torrents/delete"):
            for h in form.get("hashes", "").split("|"):
                if h not in q.torrents:
                    continue
                if path.endswith("delete"):
                    del q.torrents[h]
                else:
                    q.torrents[h]["state"] = "downloading" if path.endswith("start") else "stoppedDL"
            return self._send(200)
        if path.startswith("/api/v2/"):
            return self._send(200, b"{}", "application/json")
        return self._send(404)

    def do_GET(self):
        self._go("GET")

    def do_POST(self):
        self._go("POST")


class FakeSonarr(_Server):
    def __init__(self):
        self.grabs = {}       # downloadId (upper) -> history id
        self.failed = []
        self.commands = []
        self.calendar = []    # episodes as /calendar returns them
        self.history = []     # grabbed records as /history returns them
        self.monitor = []     # bodies PUT to /episode/monitor
        self.has_file = set() # episode ids with a file in the library
        self.unmonitored = set()
        self.imports = {}     # downloadId (upper) -> import records, as /history?eventType=3 returns them
        self.episodes = {}    # episode id -> extra fields /episode returns (seriesId, numbers, title, episodeFileId)
        self.files = {}       # episode file id -> /episodefile/{id}
        self.releases = {}    # episode id -> what an interactive search (/release) finds
        self.taken = []       # bodies POSTed to /release
        self.looked = []      # episode ids searched through /release
        self.profiles = [{"name": "Magnet", "minUpgradeFormatScore": 100}]
        self.alive = True
        super().__init__(_SonarrHandler)

    def searches(self):
        return [c["episodeIds"] for c in self.commands if c.get("name") == "EpisodeSearch"]


class _SonarrHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        s = self.server.owner
        path, _, query = self.path.partition("?")
        params = dict(urllib.parse.parse_qsl(query))
        if not s.alive:
            return self._json({}, 503)
        if path == "/api/v3/history":
            if "downloadId" in params and params.get("eventType") == "3":
                return self._json({"records": s.imports.get(params["downloadId"], [])})
            if "downloadId" in params:
                hid = s.grabs.get(params.get("downloadId", ""))
                return self._json({"records": [{"id": hid, "downloadId": params["downloadId"]}] if hid else []})
            return self._json({"records": s.history})
        if path == "/api/v3/calendar":
            return self._json(s.calendar)
        if path == "/api/v3/episode":
            ids = [int(v) for k, v in urllib.parse.parse_qsl(query) if k == "episodeIds"]
            return self._json([dict(s.episodes.get(i, {}), id=i, hasFile=i in s.has_file, monitored=i not in s.unmonitored)
                               for i in ids])
        if path == "/api/v3/release":
            s.looked.append(int(params.get("episodeId", 0)))
            return self._json(s.releases.get(int(params.get("episodeId", 0)), []))
        if path == "/api/v3/qualityprofile":
            return self._json(s.profiles)
        if path.startswith("/api/v3/episodefile/"):
            return self._json(s.files.get(int(path.rsplit("/", 1)[1]), {}))
        if path == "/api/v3/system/status":
            return self._json({"version": "4.0.19"})
        if path == "/api/v3/queue":
            return self._json({"records": []})
        if path.startswith("/api/v3/command/"):
            return self._json({"id": int(path.rsplit("/", 1)[1]), "status": "completed"})
        return self._json([])

    def do_PUT(self):
        s = self.server.owner
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}") if n else {}
        if self.path.startswith("/api/v3/episode/monitor"):
            s.monitor.append(body)
        return self._json({})

    def do_POST(self):
        s = self.server.owner
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}") if n else {}
        if self.path.startswith("/api/v3/history/failed/"):
            s.failed.append(int(self.path.rsplit("/", 1)[1]))
            return self._json({})
        if self.path == "/api/v3/release":
            s.taken.append(body)
            return self._json({})
        if self.path == "/api/v3/command":
            s.commands.append(body)
            return self._json({"id": len(s.commands), "status": "queued"})
        return self._json({})


def sha1_hex(b):
    return hashlib.sha1(b).hexdigest()
