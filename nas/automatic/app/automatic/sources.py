"""Where the automatic side searches is decided by Magnet's list of sites.

Magnet sends its sites (each with every domain it knows for it, mirrors included).
Each site is matched to a public Prowlarr indexer definition whose URLs share a
domain with it, and only indexers that can search TV count. Those indexers carry
the `magnet-sites` tag, and Sonarr's application entry in Prowlarr carries the same
tag -- Prowlarr then syncs exactly those indexers to Sonarr and nothing else.

Tagging, not enabling or disabling, is deliberate: Radarr syncs from the same
Prowlarr with no tag, so it keeps every indexer it had. Removing a site from
Magnet only removes the tag; an indexer is never deleted from here.
"""

import http.client
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

TAG = "magnet-sites"

# Second-level labels under which registrations happen one level deeper
# (example.co.uk is a registration; co.uk is not). Enough for torrent sites; not a
# full public suffix list.
_TWO_LEVEL = {"co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go"}


def registrable(host):
    host = (host or "").lower().strip().rstrip(".")
    if host.startswith("www."):
        host = host[4:]
    parts = [p for p in host.split(".") if p]
    if len(parts) <= 2:
        return ".".join(parts)
    if parts[-2] in _TWO_LEVEL and len(parts[-1]) == 2:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


def host_of(url):
    try:
        return (urllib.parse.urlparse(url if "//" in url else "https://" + url).hostname or "").lower()
    except ValueError:
        return ""


class ProwlarrError(Exception):
    pass


def read_api_key(path):
    with open(path) as f:
        m = re.search(r"<ApiKey>([^<]+)</ApiKey>", f.read())
    if not m:
        raise ProwlarrError("no ApiKey in Prowlarr's config.xml")
    return m.group(1)


class Prowlarr:
    def __init__(self, base, api_key, timeout=30):
        self.base = base.rstrip("/")
        self.key = api_key
        self.timeout = timeout

    def call(self, method, path, body=None, timeout=None, **params):
        url = f"{self.base}/api/v1/{path.lstrip('/')}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method,
                                     headers={"X-Api-Key": self.key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            detail = e.read()[:300].decode("utf-8", "replace") if e.fp else ""
            raise ProwlarrError(f"{method} {path}: {e.code} {detail}") from None
        except (urllib.error.URLError, OSError, http.client.HTTPException) as e:
            raise ProwlarrError(f"Prowlarr unreachable: {getattr(e, 'reason', e)}") from None
        try:
            return json.loads(raw) if raw else None
        except ValueError:
            raise ProwlarrError(f"{method} {path}: not JSON") from None

    def alive(self):
        try:
            self.call("GET", "system/status", timeout=3)
            return True
        except ProwlarrError:
            return False


def _tv(defn):
    for c in (defn.get("capabilities") or {}).get("categories", []) or []:
        ids = [c.get("id", 0)] + [s.get("id", 0) for s in c.get("subCategories", []) or []]
        if any(5000 <= i < 6000 for i in ids):
            return True
    return False


def _domains(defn):
    urls = list(defn.get("indexerUrls") or []) + list(defn.get("legacyUrls") or [])
    return {registrable(host_of(u)) for u in urls if host_of(u)}


def _key(defn):
    return (defn.get("implementation"), defn.get("definitionName") or defn.get("name"))


def plan(sites, schema, indexers):
    """Decide, without touching anything, what each site becomes.

    Returns (coverage, wanted) where coverage is one row per site for the app and
    wanted maps a definition key to (definition, preferred base URL or None, site).
    """
    by_domain = {}
    for d in schema:
        if d.get("protocol") not in (None, "torrent"):
            continue
        for dom in _domains(d):
            by_domain.setdefault(dom, []).append(d)
    existing = {_key(i): i for i in indexers}
    coverage, wanted = [], {}
    for site in sites:
        hosts = [h.lower() for h in site.get("domains", []) if h]
        doms = {registrable(h) for h in hosts}
        found = []
        for dom in doms:
            found.extend(by_domain.get(dom, []))
        row = {"site": site.get("name") or (hosts[0] if hosts else "?"), "domains": sorted(doms)}
        if not found:
            coverage.append(dict(row, status="unsupported", detail="Prowlarr has no indexer for this site"))
            continue
        public = [d for d in found if d.get("privacy", "public") == "public"]
        tv = [d for d in public if _tv(d)]
        if not tv:
            why = "needs an account" if not public else "this site has no TV to search"
            coverage.append(dict(row, status="no-tv" if public else "private", detail=why,
                                 indexer=(public or found)[0].get("name")))
            continue
        # Prefer a definition that is already set up, then the first match.
        tv.sort(key=lambda d: (_key(d) not in existing, d.get("name", "")))
        d = tv[0]
        preferred = None
        for u in d.get("indexerUrls") or []:
            if host_of(u) in hosts:
                preferred = u
                break
        wanted[_key(d)] = (d, preferred, row["site"])
        coverage.append(dict(row, status="searching", indexer=d.get("name"),
                             detail="already in Prowlarr" if _key(d) in existing else "added to Prowlarr"))
    return coverage, wanted


class SourceSync:
    """Keeps Prowlarr matching the last site list Magnet sent, whenever Prowlarr is awake."""

    def __init__(self, prowlarr, store, log=print, sonarr_app=""):
        self.prowlarr = prowlarr
        self.store = store
        self.log = log
        # Which of Prowlarr's applications is the Sonarr behind the gate. Empty means
        # "the only Sonarr there is"; with several, it has to be named.
        self.sonarr_app = sonarr_app
        self._wake = threading.Event()
        # A list stored by an earlier version (a "dirty" flag, no version counter)
        # still counts as waiting to be applied.
        if self.store.get("sources.dirty"):
            self.store.put("sources.version", (self.store.get("sources.applied", 0) or 0) + 1)
            self.store.put("sources.dirty", False)

    # -- what Magnet asked for ---------------------------------------------------
    def want(self, sites):
        clean = []
        for s in sites:
            doms = sorted({str(d).lower().strip() for d in s.get("domains", []) if str(d).strip()})
            if doms:
                clean.append({"name": str(s.get("name") or doms[0])[:80], "domains": doms[:40]})
        if not clean:
            # An empty list would leave Sonarr with nothing to search; it is never
            # what anyone means, so it is refused rather than applied.
            raise ValueError("no sites with a domain were sent")
        self.store.put("sources.wanted", clean)
        # A version, not just a flag: a list sent while an older one is being applied
        # must still count as not yet applied afterwards.
        self.store.put("sources.version", (self.store.get("sources.version", 0) or 0) + 1)
        self._wake.set()
        return self.status()

    def status(self):
        return {"sites": self.store.get("sources.wanted", []), "coverage": self.store.get("sources.coverage", []),
                "appliedAt": self.store.get("sources.appliedAt"),
                "pending": (self.store.get("sources.version", 0) or 0) != (self.store.get("sources.applied", 0) or 0),
                "error": self.store.get("sources.error", "")}

    def apply_pending(self, force=False):
        """One attempt. Returns True when something was applied."""
        version = self.store.get("sources.version", 0) or 0
        wanted = self.store.get("sources.wanted")
        if not wanted or (not force and version == (self.store.get("sources.applied", 0) or 0)):
            return False
        if not self.prowlarr.alive():
            self.store.put("sources.error", "Prowlarr is not answering (paused while Plex streams?); will apply when it is")
            return False
        coverage = self.sync(wanted)
        self.store.put("sources.coverage", coverage)
        self.store.put("sources.appliedAt", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        self.store.put("sources.applied", version)
        if not any(r["status"] == "searching" for r in coverage):
            self.store.put("sources.error", "None of these sites can be searched for TV, so Sonarr keeps every "
                                            "indexer it had until one can.")
        else:
            self.store.put("sources.error", "")
        return True

    def run(self, every=6 * 3600):
        """Apply when asked, and re-apply every few hours so drift in Prowlarr is undone."""
        last = 0.0
        while True:
            self._wake.wait(timeout=60)
            self._wake.clear()
            try:
                if self.apply_pending(force=time.time() - last > every):
                    last = time.time()
            except Exception as e:
                self.store.put("sources.error", f"{type(e).__name__}: {e}"[:300])
                self.log(f"sources: {type(e).__name__}: {e}")

    def _tag_id(self, create=True):
        for t in self.prowlarr.call("GET", "tag"):
            if t["label"] == TAG:
                return t["id"]
        if not create:
            return None
        return self.prowlarr.call("POST", "tag", {"label": TAG})["id"]

    def _flaresolverr_tags(self):
        """Tags that route an indexer through FlareSolverr when Cloudflare challenges it."""
        tags = []
        for p in self.prowlarr.call("GET", "indexerproxy"):
            if p.get("implementation") == "FlareSolverr":
                tags.extend(p.get("tags", []))
        return tags

    def _sonarr_app(self, apps):
        sonarrs = [a for a in apps if a.get("implementation") == "Sonarr"]
        if self.sonarr_app:
            named = [a for a in sonarrs if a.get("name") == self.sonarr_app]
            if not named:
                raise ProwlarrError(f"Prowlarr has no Sonarr application named {self.sonarr_app!r}")
            return named[0]
        if len(sonarrs) != 1:
            raise ProwlarrError(f"Prowlarr has {len(sonarrs)} Sonarr applications; set PROWLARR_SONARR_APP "
                                "to the one behind the gate")
        return sonarrs[0]

    def sync(self, sites):
        """Apply Magnet's sites to Prowlarr. Returns the coverage report."""
        schema = self.prowlarr.call("GET", "indexer/schema", timeout=120)
        indexers = self.prowlarr.call("GET", "indexer")
        app = self._sonarr_app(self.prowlarr.call("GET", "applications"))
        coverage, wanted = plan(sites, schema, indexers)
        tag = self._tag_id()
        fs_tags = self._flaresolverr_tags()
        existing = {_key(i): i for i in indexers}
        changed = 0

        for key, (defn, preferred, site) in wanted.items():
            ix = existing.get(key)
            if ix:
                if not ix.get("enable"):
                    # Turned off in Prowlarr by someone: that stays their decision.
                    for row in coverage:
                        if row.get("indexer") == defn.get("name") and row["status"] == "searching":
                            row.update(status="disabled", detail="turned off in Prowlarr")
                if tag not in ix.get("tags", []):
                    ix["tags"] = sorted(set(ix.get("tags", [])) | {tag})
                    self.prowlarr.call("PUT", f"indexer/{ix['id']}", ix, forceSave="true")
                    changed += 1
                continue
            new = dict(defn)
            new.pop("id", None)
            new.update(enable=True, priority=25, appProfileId=new.get("appProfileId") or 1,
                       tags=sorted(set(fs_tags) | {tag}))
            if preferred:
                for f in new.get("fields", []):
                    if f.get("name") == "baseUrl":
                        f["value"] = preferred
            try:
                self.prowlarr.call("POST", "indexer", new, timeout=120, forceSave="true")
                changed += 1
                self.log(f"sources: added {defn.get('name')} for {site}")
            except ProwlarrError as e:
                for row in coverage:
                    if row.get("indexer") == defn.get("name") and row["status"] == "searching":
                        row.update(status="failed", detail=str(e)[:200])

        keep = set(wanted)
        for key, ix in existing.items():
            if tag in ix.get("tags", []) and key not in keep:
                ix["tags"] = [t for t in ix["tags"] if t != tag]
                self.prowlarr.call("PUT", f"indexer/{ix['id']}", ix, forceSave="true")
                changed += 1
                self.log(f"sources: {ix.get('name')} is no longer one of Magnet's sites")

        # Restrict Sonarr to the tagged indexers only when at least one site actually
        # gives it something to search. Restricting it to nothing would leave it with
        # no indexers at all; then it keeps every indexer it had instead.
        searchable = any(r["status"] == "searching" for r in coverage)
        tagged = tag in app.get("tags", [])
        if searchable and not tagged:
            app["tags"] = sorted(set(app.get("tags", [])) | {tag})
        elif not searchable and tagged:
            app["tags"] = [t for t in app.get("tags", []) if t != tag]
        if searchable != tagged:
            self.prowlarr.call("PUT", f"applications/{app['id']}", app, forceSave="true")
            changed += 1
        if changed:
            self.prowlarr.call("POST", "command", {"name": "ApplicationIndexerSync"})
        return coverage
