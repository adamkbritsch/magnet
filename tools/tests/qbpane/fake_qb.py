"""A stand-in for qBittorrent's WebUI, enough to drive the pane's sign-in script.

Each path prefix is a different server:
  /m52/  qBittorrent 5.2: a good sign-in is 204 with an empty body
  /m51/  qBittorrent 5.1: a good sign-in is 200 "Ok."
  /liar/ answers 204 but never sets a cookie (a sign-in that did not take)
  /ban/  refuses every sign-in with 403, as after too many failures
  /redir/ redirects the sign-in to another origin
The good password is "pw" for user "admin". Prints its port, then serves forever.
"""
import http.server
import os
import sys
import urllib.parse

MODES = ("m52", "m51", "liar", "ban", "redir")


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _mode(self):
        part = self.path.split("/")[1] if self.path.count("/") > 1 else ""
        return part if part in MODES else None

    def _send(self, code, body=b"", headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        mode = self._mode()
        if mode and self.path.endswith("/api/v2/app/version"):
            ok = f"QBT_SID_{mode}=good" in (self.headers.get("Cookie") or "")
            return self._send(200, b"v5.2.3") if ok else self._send(403, b"Forbidden")
        self._send(200, b"<!doctype html><title>qB</title><p>login</p>",
                   [("Content-Type", "text/html")])

    def do_POST(self):
        mode = self._mode()
        length = int(self.headers.get("Content-Length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(length).decode())
        good = form.get("username") == ["admin"] and form.get("password") == ["pw"]
        cookie = ("Set-Cookie", f"QBT_SID_{mode}=good; Path=/{mode}/")
        if mode == "ban":
            return self._send(403, b"Forbidden")
        if mode == "redir":
            return self._send(307, b"", [("Location", "http://localhost:9/steal")])
        if not good:
            return self._send(200, b"Fails.")
        if mode == "m52":
            return self._send(204, b"", [cookie])
        if mode == "m51":
            return self._send(200, b"Ok.", [cookie])
        if mode == "liar":
            return self._send(204, b"")
        self._send(404)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
# sys.stdout.close() leaves descriptor 1 open (closefd=False), and the test reads to
# end-of-file: the descriptor itself has to go.
os.close(1)
server.serve_forever()
