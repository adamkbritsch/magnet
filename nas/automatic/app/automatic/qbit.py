"""The seedbox's qBittorrent WebUI, from the NAS.

Two rules here are about not breaking things for other apps:

* A rejected login is never retried on its own. qBittorrent bans an IP after a few
  failures, and the IP it would ban is the NAS's public address -- the same one every
  other app reaching qBittorrent through the NAS uses, Magnet's own magnet handoff
  included. One bad password must not take those down too. A new login sent from
  Magnet's Settings clears the block.
* Redirects are never followed. A 307/308 keeps the method and the body, so
  following one would hand the login form to whatever host the Location names.
"""

import http.client
import http.cookies
import json
import os
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class UpstreamError(Exception):
    pass


class AuthRejected(UpstreamError):
    pass


class QBit:
    def __init__(self, base, secrets_path, timeout=30):
        self.base = base.rstrip("/")
        self.secrets_path = secrets_path
        self.timeout = timeout
        self._lock = threading.Lock()
        # One login at a time: two threads finding the session gone at once must not
        # each spend a refusal of the same bad password.
        self._login_lock = threading.Lock()
        self._cookie = None
        self._rejected = None  # (username, time) of the login qBittorrent refused
        self.last_error = ""
        self.api_version = None
        ctx = ssl.create_default_context()
        self._opener = urllib.request.build_opener(_NoRedirect(), urllib.request.HTTPSHandler(context=ctx))

    # -- credentials -------------------------------------------------------------
    def credentials(self):
        try:
            with open(self.secrets_path) as f:
                s = json.load(f)
            if s.get("qb_username") and s.get("qb_password"):
                return s["qb_username"], s["qb_password"]
        except (OSError, ValueError):
            pass
        u, p = os.environ.get("QB_USERNAME", ""), os.environ.get("QB_PASSWORD", "")
        return (u, p) if u and p else None

    def save_credentials(self, username, password):
        tmp = self.secrets_path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"qb_username": username, "qb_password": password}, f)
        os.replace(tmp, self.secrets_path)
        with self._lock:
            self._rejected = None

    @property
    def configured(self):
        return self.credentials() is not None

    @property
    def blocked(self):
        return self._rejected is not None

    # -- transport ---------------------------------------------------------------
    def _raw(self, method, path, params=None, data=None, content_type=None, cookie=None):
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, data=data, method=method)
        if content_type:
            req.add_header("Content-Type", content_type)
        if cookie:
            req.add_header("Cookie", cookie)
        try:
            with self._opener.open(req, timeout=self.timeout) as r:
                return r.status, dict(r.headers.items()), r.read(), r.headers.get_all("Set-Cookie") or []
        except urllib.error.HTTPError as e:
            try:
                body = e.read() if e.fp else b""
            except (OSError, http.client.HTTPException):
                body = b""
            return e.code, dict(e.headers.items()) if e.headers else {}, body, []
        except (urllib.error.URLError, OSError, http.client.HTTPException) as e:
            raise UpstreamError(f"seedbox unreachable: {getattr(e, 'reason', e)}") from None

    def login(self, username=None, password=None):
        """Log in and keep the session cookie. Raises AuthRejected on a refused login.

        An explicit username/password (a login being offered from Magnet) that is
        refused leaves the stored login and its session alone: a typo must not stop
        a login that still works."""
        with self._login_lock:
            explicit = username is not None
            if not explicit and self._cookie is not None:
                return True             # another thread logged in while this one waited
            return self._login(username, password, explicit)

    def _login(self, username, password, explicit):
        creds = (username, password) if explicit else self.credentials()
        if not creds:
            raise AuthRejected("no seedbox login configured")
        if self._rejected and self._rejected[0] == creds[0] and not explicit:
            raise AuthRejected("the seedbox refused this login; send it again from Magnet's Settings")
        body = urllib.parse.urlencode({"username": creds[0], "password": creds[1]}).encode()
        status, _, text, cookies = self._raw("POST", "/api/v2/auth/login", data=body,
                                             content_type="application/x-www-form-urlencoded")
        # qBittorrent 5.2 answers 204 with no body; older builds answer 200 "Ok.".
        # A refusal is 200 "Fails." -- or 403 once the IP is banned.
        session = None
        for c in cookies:
            jar = http.cookies.SimpleCookie()
            try:
                jar.load(c)
            except http.cookies.CookieError:
                continue
            for name, morsel in jar.items():
                if name.upper() == "SID" or name.upper().startswith("QBT_SID"):
                    session = f"{name}={morsel.value}"
        if status in (200, 204) and text.strip() != b"Fails." and session:
            with self._lock:
                self._cookie = session
                self._rejected = None
            self.last_error = ""
            return True
        why = "the seedbox refused the login" if status != 403 else "the seedbox has banned this IP for now"
        if explicit:
            raise AuthRejected(why)
        with self._lock:
            self._rejected = (creds[0], time.time())
            self._cookie = None
        self.last_error = why
        raise AuthRejected(why)

    def request(self, method, path, params=None, data=None, content_type=None):
        """Authenticated call. Returns (status, headers, body)."""
        for attempt in (0, 1):
            with self._lock:
                cookie = self._cookie
            if cookie is None:
                self.login()
                with self._lock:
                    cookie = self._cookie
            status, headers, body, _ = self._raw(method, path, params, data, content_type, cookie)
            if status == 403 and attempt == 0:
                with self._lock:
                    self._cookie = None
                continue
            return status, headers, body
        return status, headers, body

    # -- conveniences ------------------------------------------------------------
    def get_json(self, path, params=None):
        status, _, body = self.request("GET", path, params)
        if status != 200:
            raise UpstreamError(f"{path} answered {status}")
        try:
            return json.loads(body or b"null")
        except ValueError:
            raise UpstreamError(f"{path} did not answer with JSON") from None

    def post(self, path, fields):
        body = urllib.parse.urlencode(fields).encode()
        status, _, text = self.request("POST", path, data=body, content_type="application/x-www-form-urlencoded")
        if not 200 <= status < 300:
            raise UpstreamError(f"{path} answered {status}: {text[:120]!r}")
        return text

    def version(self):
        if self.api_version is None:
            status, _, body = self.request("GET", "/api/v2/app/webapiVersion")
            if status == 200:
                self.api_version = tuple(int(x) for x in body.decode().strip().split(".")[:3] if x.isdigit())
        return self.api_version or (2, 0, 0)

    def start(self, hashes):
        # WebAPI 2.11 (qBittorrent 5.0) renamed resume/pause to start/stop.
        self.post("/api/v2/torrents/start" if self.version() >= (2, 11) else "/api/v2/torrents/resume",
                  {"hashes": "|".join(hashes)})

    def stop(self, hashes):
        self.post("/api/v2/torrents/stop" if self.version() >= (2, 11) else "/api/v2/torrents/pause",
                  {"hashes": "|".join(hashes)})

    def delete(self, hashes):
        self.post("/api/v2/torrents/delete", {"hashes": "|".join(hashes), "deleteFiles": "true"})

    def torrents(self, category):
        return self.get_json("/api/v2/torrents/info", {"category": category})

    def files(self, h):
        return self.get_json("/api/v2/torrents/files", {"hash": h}) or []

    def free_space(self):
        state = self.get_json("/api/v2/sync/maindata", {"rid": 0}).get("server_state", {})
        return state.get("free_space_on_disk")
