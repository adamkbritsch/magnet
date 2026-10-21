"""Sonarr v4 on the NAS: the calendar, the search, and the library."""

import http.client
import json
import re
import urllib.error
import urllib.parse
import urllib.request


class SonarrError(Exception):
    pass


def read_api_key(config_xml_path):
    with open(config_xml_path) as f:
        m = re.search(r"<ApiKey>([^<]+)</ApiKey>", f.read())
    if not m:
        raise SonarrError("no ApiKey in Sonarr's config.xml")
    return m.group(1)


class Sonarr:
    def __init__(self, base, api_key, timeout=60):
        self.base = base.rstrip("/")
        self.key = api_key
        self.timeout = timeout

    def call(self, method, path, params=None, body=None, timeout=None):
        url = f"{self.base}/api/v3/{path.lstrip('/')}"
        if params:
            url += "?" + urllib.parse.urlencode(params, doseq=True)
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={"X-Api-Key": self.key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            detail = e.read()[:300].decode("utf-8", "replace") if e.fp else ""
            raise SonarrError(f"{method} {path}: {e.code} {detail}") from None
        except (urllib.error.URLError, OSError, http.client.HTTPException) as e:
            raise SonarrError(f"Sonarr unreachable: {getattr(e, 'reason', e)}") from None
        try:
            return json.loads(raw) if raw else None
        except ValueError:
            raise SonarrError(f"{method} {path}: not JSON") from None

    def get(self, path, **params):
        return self.call("GET", path, params or None)

    def alive(self):
        """A fast probe. A container frozen by stream-guard accepts the connection and never answers."""
        try:
            self.call("GET", "system/status", timeout=3)
            return True
        except SonarrError:
            return False

    # -- the gate's needs --------------------------------------------------------
    def grab_for(self, download_id):
        """The 'grabbed' history record for a torrent hash, newest first, or None."""
        recs = self.get("history", downloadId=download_id.upper(), eventType=1, pageSize=10,
                        sortKey="date", sortDirection="descending")
        recs = recs.get("records", recs) if isinstance(recs, dict) else recs
        return recs[0] if recs else None

    def mark_failed(self, history_id):
        # Blocklists the release and, with "Redownload Failed" on, searches again.
        self.call("POST", f"history/failed/{history_id}")

    def import_path(self, path, download_id):
        return self.call("POST", "command", body={
            "name": "DownloadedEpisodesScan", "path": path,
            "downloadClientId": download_id.upper(), "importMode": "Copy"})

    def command(self, command_id):
        return self.get(f"command/{command_id}")
