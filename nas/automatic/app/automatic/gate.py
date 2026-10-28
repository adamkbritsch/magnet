"""A qBittorrent WebUI that Sonarr talks to, standing in front of the real one.

Sonarr's download client points here instead of at the seedbox. Every request is
passed through unchanged except `torrents/add`, which is where the ban is enforced
before a single byte of the release is downloaded:

* a .torrent file is read here, and a release that carries an executable is never
  sent to the seedbox at all;
* a magnet link is added with stopCondition=MetadataReceived, so qBittorrent fetches
  the file list and then stops on its own. The watcher reads the list and either
  starts the torrent or deletes it.

A rejected release is then marked failed in Sonarr, which blocklists it and searches
for another. Sonarr only ever sees "Ok.", so a rejection never puts the download
client into back-off.

The real qBittorrent login lives only in this process; Sonarr gets a separate local
login that is worthless anywhere else.
"""

import base64
import binascii
import hmac
import http.server
import json
import re
import secrets
import threading
import time
import traceback
import urllib.parse

from . import bencode, qbstate, rules
from .qbit import AuthRejected, UpstreamError
from .sonarr import SonarrError

# The only calls Sonarr makes, so the only calls that pass. Matched after the path is
# percent-decoded, because qBittorrent decodes it too: "torrents/delet%65" is delete.
READS = {"/api/v2/app/version", "/api/v2/app/webapiVersion", "/api/v2/app/preferences", "/api/v2/app/buildInfo",
         "/api/v2/torrents/info", "/api/v2/torrents/properties", "/api/v2/torrents/files",
         "/api/v2/torrents/trackers", "/api/v2/torrents/categories", "/api/v2/torrents/tags",
         "/api/v2/sync/maindata", "/api/v2/transfer/info"}
ACTIONS = {"/api/v2/torrents/delete", "/api/v2/torrents/setCategory", "/api/v2/torrents/createCategory",
           "/api/v2/torrents/topPrio", "/api/v2/torrents/bottomPrio",
           "/api/v2/torrents/setShareLimits", "/api/v2/torrents/setForceStart", "/api/v2/torrents/start",
           "/api/v2/torrents/resume", "/api/v2/torrents/stop", "/api/v2/torrents/pause",
           "/api/v2/torrents/addTags", "/api/v2/torrents/removeTags", "/api/v2/torrents/setSuperSeeding",
           "/api/v2/torrents/increasePrio", "/api/v2/torrents/decreasePrio"}
# Category calls name no torrent; every other action names its torrents in "hashes".
UNSCOPED = {"/api/v2/torrents/createCategory"}
STARTING = {"/api/v2/torrents/start", "/api/v2/torrents/resume", "/api/v2/torrents/setForceStart"}


def magnet_hash(uri):
    """Hex info hash from a magnet's btih, or None. Base32 hashes are converted."""
    m = re.search(r"xt=urn:btih:([A-Za-z0-9]+)", uri)
    if not m:
        return None
    h = m.group(1)
    if len(h) == 40 and all(c in "0123456789abcdefABCDEF" for c in h):
        return h.lower()
    if len(h) == 32:
        try:
            return binascii.hexlify(base64.b32decode(h.upper())).decode()
        except (binascii.Error, ValueError):
            return None
    return None


def parse_form(body, content_type):
    """Returns a list of fields: {"name", "filename", "content_type", "data"}."""
    content_type = content_type or ""
    if content_type.lower().startswith("multipart/form-data"):
        m = re.search(r'boundary="?([^";]+)"?', content_type)
        if not m:
            raise ValueError("multipart without a boundary")
        boundary = b"--" + m.group(1).encode()
        fields = []
        for chunk in body.split(boundary)[1:]:
            if chunk.startswith(b"--"):
                break
            if chunk.startswith(b"\r\n"):
                chunk = chunk[2:]
            head, _, data = chunk.partition(b"\r\n\r\n")
            if data.endswith(b"\r\n"):
                data = data[:-2]
            headers = {}
            for line in head.split(b"\r\n"):
                k, _, v = line.decode("utf-8", "replace").partition(":")
                headers[k.strip().lower()] = v.strip()
            disp = headers.get("content-disposition", "")
            name = re.search(r';\s*name="?([^";]*)"?', disp)
            filename = re.search(r';\s*filename="?([^";]*)"?', disp)
            fields.append({"name": name.group(1) if name else "", "filename": filename.group(1) if filename else None,
                           "content_type": headers.get("content-type"), "data": data})
        return fields
    pairs = urllib.parse.parse_qsl(body.decode("utf-8", "replace"), keep_blank_values=True)
    return [{"name": k, "filename": None, "content_type": None, "data": v.encode()} for k, v in pairs]


def encode_form(fields):
    boundary = "magnet" + secrets.token_hex(12)
    out = bytearray()
    for f in fields:
        out += f"--{boundary}\r\n".encode()
        disp = f'form-data; name="{f["name"]}"'
        if f.get("filename") is not None:
            disp += f'; filename="{f["filename"]}"'
        out += f"Content-Disposition: {disp}\r\n".encode()
        if f.get("content_type"):
            out += f"Content-Type: {f['content_type']}\r\n".encode()
        out += b"\r\n" + f["data"] + b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return bytes(out), f"multipart/form-data; boundary={boundary}"


class Gate:
    def __init__(self, qbit, sonarr, store, category, gate_user, gate_pass, min_free_bytes, log=print):
        self.qbit = qbit
        self.sonarr = sonarr
        self.store = store
        self.category = category
        self.gate_user = gate_user
        self.gate_pass = gate_pass
        self.min_free = min_free_bytes
        self.log = log
        self.sessions = set()
        self.free_bytes = None
        self.free_checked = 0.0
        self.known = {}          # hash -> last torrents/info row, from the watcher
        self.last_poll = 0.0
        self.last_error = ""
        self._sonarr_retry_at = 0.0
        self._resumes = {}       # hash -> times it was started again, for the last hour
        self._rechecked = {}     # hash -> when a recheck was last asked for
        self._lock = threading.Lock()

    # -- disk --------------------------------------------------------------------
    def space_ok(self):
        if time.time() - self.free_checked > 60:
            try:
                self.free_bytes = self.qbit.free_space()
                self.free_checked = time.time()
            except (UpstreamError, AuthRejected, ValueError):
                pass
        return self.free_bytes is None or self.free_bytes >= self.min_free

    # -- torrents/add ------------------------------------------------------------
    def add(self, body, content_type):
        """Returns (status, content_type, body) for Sonarr."""
        fields = parse_form(body, content_type)
        passthrough, urls, files = [], [], []
        for f in fields:
            if f["name"] == "torrents":
                files.append(f)
            elif f["name"] == "urls":
                urls.extend(u.strip() for u in f["data"].decode("utf-8", "replace").splitlines() if u.strip())
            elif f["name"] not in ("category", "stopCondition", "stopped", "paused"):
                passthrough.append(f)

        space = self.space_ok()
        approved, unreadable = [], []
        for f in files:
            try:
                info = bencode.torrent_info(f["data"])
            except bencode.BencodeError as e:
                # Not judged here, but not dropped either: it goes to qBittorrent
                # stopped, and the watcher judges the file list qBittorrent read from
                # it. Dropping it would leave Sonarr re-grabbing it on every RSS pass.
                self.store.event("unreadable", "", f"a .torrent the gate could not read ({e}); added stopped "
                                                   "so its file list can be checked")
                unreadable.append(f)
                continue
            ok, reason, bad = rules.judge(info["files"])
            if not ok:
                self.store.decide(info["hash"], "rejected", info["name"], reason, bad, "torrent-file", new_grab=True)
                self.log(f"rejected before download: {info['name']} -- {reason}")
                continue
            if self._present(info["hash"]) or self._imported(info["hash"]):
                continue
            # Passing here is a first fence, not the verdict: a crafted file can read one
            # way to this parser and another to libtorrent. It goes in stopped, and the
            # watcher judges the file list qBittorrent itself read before starting it.
            self.store.decide(info["hash"], "held", info["name"], "checking the file list", (), "torrent-file")
            approved.append(f)
        fresh = []
        for u in urls:
            h = magnet_hash(u) if u.lower().startswith("magnet:") else None
            if h and (self._present(h) or self._imported(h)):
                continue
            fresh.append(u)
            if h:
                dn = urllib.parse.parse_qs(urllib.parse.urlparse(u).query).get("dn", [""])[0]
                self.store.decide(h, "held", dn, "waiting for the file list", (), "magnet")
        urls = fresh

        def field(name, value):
            return {"name": name, "filename": None, "content_type": None, "data": value.encode()}

        common = passthrough + [field("category", self.category)]
        status, text = 200, b"Ok."
        if urls:
            # qBittorrent fetches the file list and then stops by itself; the watcher
            # reads the list before anything else is downloaded.
            status, text = self._forward_add(common + [field("urls", "\n".join(urls)),
                                                       field("stopCondition", "MetadataReceived"),
                                                       field("stopped", "false"), field("paused", "false")])
        if approved and status < 300:
            status, text = self._forward_add(common + approved + [field("stopped", "true"), field("paused", "true")])
        if unreadable and status < 300:
            # Whatever qBittorrent makes of it, Sonarr hears "Ok.": a refusal here would
            # put its whole download client into back-off over one bad file. If it is
            # refused, the grab is recorded as rejected under the hash it has, so Sonarr
            # blocklists it instead of re-grabbing it forever.
            for f in unreadable:
                code, _ = self._forward_add(common + [f, field("stopped", "true"), field("paused", "true")])
                if code >= 300:
                    h = bencode.lenient_hash(f["data"])
                    if h:
                        self.store.decide(h, "rejected", f.get("filename") or h, "qBittorrent could not read the "
                                          ".torrent either", (), "torrent-file", new_grab=True)
        return status, "text/plain; charset=UTF-8", text

    def _present(self, h):
        """Whether qBittorrent already has this torrent, in any category. Adding it again
        would answer with a failure, and a failure puts Sonarr's client into back-off."""
        try:
            return bool(self.qbit.get_json("/api/v2/torrents/info", {"hashes": h}))
        except (UpstreamError, ValueError):
            return False

    def _imported(self, h):
        """Already on the NAS -- and still there -- and removed from the seedbox: Sonarr
        grabbing it again is not a reason to download it again. If the library has lost
        the episode, it is downloaded like any other grab."""
        d = self.store.decision(h)
        if not d or d["verdict"] != "imported":
            return False
        try:
            recs = self.sonarr.get("history", downloadId=h.upper(), eventType=1, pageSize=50)
            recs = recs.get("records", recs) if isinstance(recs, dict) else (recs or [])
            eps = sorted({r["episodeId"] for r in recs if r.get("episodeId")})
            if not eps:
                return True
            return all(e.get("hasFile") for e in self.sonarr.get("episode", episodeIds=eps) or [])
        except SonarrError:
            return True

    def _forward_add(self, fields):
        data, ctype = encode_form(fields)
        status, _, text = self.qbit.request("POST", "/api/v2/torrents/add", data=data, content_type=ctype)
        return status, text

    # -- the watcher -------------------------------------------------------------
    def poll(self):
        """One pass over the category. Safe to call as often as you like."""
        torrents = self.qbit.torrents(self.category)
        self.known = {t["hash"].lower(): t for t in torrents}
        self.last_poll = time.time()
        decisions = self.store.decisions()
        space = self.space_ok()
        for h, t in self.known.items():
            d = decisions.get(h)
            verdict = d["verdict"] if d else None
            if verdict == "approved":
                self._keep_going(h, t, space)
                continue
            if verdict == "rejected":
                # Re-added by hand or by a retry: it is still banned, and Sonarr is told
                # again about this new grab of it.
                self._reject(h, t["name"], d["reason"], json.loads(d["files"]), d["source"], new_grab=True)
                continue
            if verdict == "waiting":
                if space:
                    self.qbit.start([h])
                    self.store.decide(h, "approved", t["name"])
                continue
            # held, or never seen: nothing starts until its file list has been read, and
            # nothing is judged while qBittorrent is still checking or moving it.
            state = t.get("state", "")
            if not qbstate.has_metadata(t) or qbstate.is_checking(t):
                if not d:
                    self.store.decide(h, "held", t["name"], "waiting for the file list", (), "found")
                continue
            files = self.qbit.files(h)
            if not files:
                # No file list yet (a magnet still queued, say). Stopping it now would
                # stop it ever getting one. A stopped one has lost its stop condition, so
                # starting it would download before it is judged: it is added again,
                # with the condition, instead.
                if not d:
                    self.store.decide(h, "held", t["name"], "waiting for the file list", (), "found")
                if state in qbstate.STOPPED and t.get("magnet_uri"):
                    self._readd_magnet(h, t)
                continue
            if state not in qbstate.STOPPED:
                self.qbit.stop([h])
            ok, reason, bad = rules.judge((f["name"], f.get("size", 0)) for f in files)
            if not ok:
                self._reject(h, t["name"], reason, bad, d["source"] if d else "found")
            elif not space:
                self.store.decide(h, "waiting", t["name"], "the seedbox is low on space")
            else:
                self.qbit.start([h])
                self.store.decide(h, "approved", t["name"])
        self._report_rejections()

    def _readd_magnet(self, h, t):
        self.qbit.post("/api/v2/torrents/delete", {"hashes": h, "deleteFiles": "false"})

        def field(name, value):
            return {"name": name, "filename": None, "content_type": None, "data": value.encode()}
        self._forward_add([field("category", self.category), field("urls", t["magnet_uri"]),
                           field("stopCondition", "MetadataReceived"), field("stopped", "false"),
                           field("paused", "false")])

    def gave_up(self, h):
        """Whether this torrent kept stopping and is no longer being restarted."""
        now = time.time()
        return len([x for x in self._resumes.get(h, []) if now - x < 3600]) >= 6

    def _keep_going(self, h, t, space):
        """An approved torrent runs until qBittorrent shows it finished.

        qBittorrent stops a torrent that was stopped when a check began, and leaves it
        stopped when the check finds data still missing -- the torrent that "pauses
        after the check". That one is started again. One that errored or lost its files
        is rechecked first; the check's outcome is acted on next pass.
        """
        if qbstate.is_checking(t) or qbstate.is_finished(t):
            return
        now = time.time()
        recent = [x for x in self._resumes.get(h, []) if now - x < 3600]
        self._resumes[h] = recent
        if qbstate.needs_resume(t):
            if not space:
                return                      # it waits for room, like any other start
            if len(recent) >= 6:
                # Something keeps stopping it. Starting it a seventh time in an hour is a
                # fight, not a fix; the scout replaces it if it never moves again.
                if len(recent) == 6:
                    self.store.event("stuck", h, f"{t.get('name', h)}: keeps stopping; no longer restarting it")
                    recent.append(now)
                return
            self.qbit.start([h])
            recent.append(now)
            pct = int(round(float(t.get("progress") or 0) * 100))
            self.store.event("resumed", h, f"{t.get('name', h)}: stopped at {pct}% with data still to fetch; started again")
        elif qbstate.is_troubled(t) and now - self._rechecked.get(h, 0) > 1800:
            self.qbit.post("/api/v2/torrents/recheck", {"hashes": h})
            self._rechecked[h] = now
            self.store.event("recheck", h, f"{t.get('name', h)}: {qbstate.label(t).lower()}; checking its files again")

    def _reject(self, h, name, reason, bad, source, new_grab=False):
        self.qbit.delete([h])
        self.store.decide(h, "rejected", name, reason, bad, source, new_grab=new_grab)
        self.log(f"rejected and deleted: {name} -- {reason}")

    def _report_rejections(self):
        # Sonarr is frozen whenever Plex streams (stream-guard), sometimes for hours.
        # Back off instead of timing out every pass, and only count an attempt when
        # Sonarr actually answered -- a two-hour film must not use up the retries.
        if time.time() < self._sonarr_retry_at:
            return
        for d in self.store.unmarked_rejections():
            try:
                grab = self.sonarr.grab_for(d["hash"])
                if grab:
                    self.sonarr.mark_failed(grab["id"])
                    self.store.set_marked(d["hash"], 1, d["attempts"] + 1)
                    self.store.event("blocklisted", d["hash"], f"{d['name']}: Sonarr blocklisted it and will look for another")
                else:
                    # Not a Sonarr grab (yet): its history row can lag the add by a moment.
                    self.store.set_marked(d["hash"], 0, d["attempts"] + 1)
            except Exception:
                self._sonarr_retry_at = time.time() + 60
                return

    def run(self, interval=5):
        while True:
            try:
                if self.qbit.configured and not self.qbit.blocked:
                    self.poll()
                    self.last_error = ""
            except AuthRejected as e:
                self.last_error = str(e)
            except Exception as e:
                self.last_error = f"{type(e).__name__}: {e}"
                self.log("watcher: " + traceback.format_exc().strip().splitlines()[-1])
            time.sleep(interval)

    # -- per-torrent scoping -----------------------------------------------------
    def scope_hashes(self, path, fields):
        """Confine a per-torrent action to this category; never start an unapproved torrent."""
        mine = set(self.known)
        decisions = self.store.decisions()
        out = []
        for f in fields:
            if f["name"] == "hashes":
                asked = f["data"].decode().split("|")
                if asked == ["all"]:
                    asked = sorted(mine)
                allowed = [h for h in asked if h.lower() in mine or h.lower() in decisions]
                if path in STARTING:
                    allowed = [h for h in allowed if decisions.get(h.lower(), {}).get("verdict") == "approved"]
                if not allowed:
                    return None
                f = dict(f, data="|".join(allowed).encode())
            out.append(f)
        return out

    # -- local login for Sonarr --------------------------------------------------
    def check_login(self, user, password):
        return (hmac.compare_digest(user.encode(), self.gate_user.encode())
                and hmac.compare_digest(password.encode(), self.gate_pass.encode()))


def make_handler(gate):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "magnet-gate"

        def log_message(self, fmt, *args):
            pass

        def _send(self, status, body=b"", ctype="text/plain; charset=UTF-8", headers=()):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in headers:
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            if n < 0 or n > 64 * 1024 * 1024:
                raise ValueError("bad request size")
            return self.rfile.read(n) if n else b""

        def _authed(self):
            auth = self.headers.get("Authorization", "")
            if auth.startswith("Bearer ") and hmac.compare_digest(auth[7:].encode(), gate.gate_pass.encode()):
                return True
            jar = self.headers.get("Cookie", "")
            return any(c.strip().startswith("SID=") and c.strip()[4:] in gate.sessions for c in jar.split(";"))

        def _handle(self, method):
            try:
                path, _, query = self.path.partition("?")
                # Nobody streams a body into memory before logging in.
                if path != "/api/v2/auth/login" and not self._authed():
                    return self._send(403, b"Forbidden")
                body = self._body() if method == "POST" else b""
                if path == "/api/v2/auth/login":
                    form = dict(urllib.parse.parse_qsl(body.decode("utf-8", "replace")))
                    if gate.check_login(form.get("username", ""), form.get("password", "")):
                        sid = secrets.token_urlsafe(24)
                        gate.sessions.add(sid)
                        return self._send(200, b"Ok.", headers=[("Set-Cookie", f"SID={sid}; HttpOnly; path=/")])
                    return self._send(200, b"Fails.")
                if path == "/api/v2/auth/logout":
                    return self._send(200)
                if not self._authed():
                    return self._send(403, b"Forbidden")
                path = urllib.parse.unquote(path)
                allowed = (path in READS and method == "GET") or \
                          (method == "POST" and (path in ACTIONS or path == "/api/v2/torrents/add"))
                if not allowed:
                    return self._send(403, b"Not through Magnet's gate")
                if not gate.qbit.configured:
                    return self._send(503, b"Magnet has not given the NAS the seedbox login yet")
                if method == "POST" and path == "/api/v2/torrents/add":
                    status, ctype, text = gate.add(body, self.headers.get("Content-Type"))
                    return self._send(status, text, ctype)
                if method == "POST" and path in ACTIONS:
                    ctype = self.headers.get("Content-Type", "")
                    # Query parameters are folded into the body, so "hashes" cannot ride
                    # in the query string past the scoping below.
                    fields = parse_form(body, ctype) if body else []
                    fields += [{"name": k, "filename": None, "content_type": None, "data": v.encode()}
                               for k, v in urllib.parse.parse_qsl(query, True)]
                    if path in UNSCOPED or path == "/api/v2/torrents/setCategory":
                        cat = next((f["data"].decode() for f in fields if f["name"] == "category"), "")
                        if cat not in (gate.category, ""):
                            return self._send(403, b"Only this client's own category")
                    if path not in UNSCOPED:
                        if not any(f["name"] == "hashes" for f in fields):
                            return self._send(400, b"hashes required")
                        fields = gate.scope_hashes(path, fields)
                        if fields is None:
                            return self._send(200)
                    body = urllib.parse.urlencode([(f["name"], f["data"].decode()) for f in fields]).encode()
                    status, headers, text = gate.qbit.request(method, path, None, body,
                                                              "application/x-www-form-urlencoded")
                else:
                    status, headers, text = gate.qbit.request(method, path, urllib.parse.parse_qsl(query, True) or None,
                                                              body or None, self.headers.get("Content-Type"))
                ctype = next((v for k, v in headers.items() if k.lower() == "content-type"), "text/plain; charset=UTF-8")
                return self._send(status, text, ctype)
            except AuthRejected as e:
                return self._send(503, str(e).encode())
            except UpstreamError as e:
                return self._send(502, str(e).encode())
            except Exception as e:
                gate.log("gate: " + traceback.format_exc().strip().splitlines()[-1])
                return self._send(500, f"{type(e).__name__}: {e}".encode())

        def do_GET(self):
            self._handle("GET")

        def do_POST(self):
            self._handle("POST")

    return Handler
