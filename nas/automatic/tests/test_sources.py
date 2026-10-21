import http.server
import json
import os
import tempfile
import threading
import unittest
import urllib.parse

from automatic.sources import TAG, Prowlarr, SourceSync, plan, registrable
from automatic.store import Store

TV = {"categories": [{"id": 5000, "name": "TV", "subCategories": [{"id": 5040, "name": "TV/HD"}]}]}
MOVIES = {"categories": [{"id": 2000, "name": "Movies", "subCategories": [{"id": 2040}]}]}


def definition(name, urls, caps=TV, privacy="public", impl="Cardigann"):
    return {"name": name, "definitionName": name.lower(), "implementation": impl, "protocol": "torrent",
            "privacy": privacy, "indexerUrls": urls, "legacyUrls": [], "capabilities": caps,
            "fields": [{"name": "definitionFile", "value": name.lower()}, {"name": "baseUrl", "value": urls[0]}],
            "tags": [], "enable": False}


SCHEMA = [
    definition("EZTV", ["https://eztvx.to/", "https://eztv.wf/"]),
    definition("1337x", ["https://1337x.to/", "https://1337x.st/", "https://x1337x.ws/"]),
    definition("YTS", ["https://yts.mx/"], caps=MOVIES),
    definition("TorrentLeech", ["https://www.torrentleech.org/"], privacy="private"),
    definition("The Pirate Bay", ["https://thepiratebay.org/"]),
    definition("LimeTorrents", ["https://www.limetorrents.lol/", "https://limetorrents.info/"]),
]


class FakeProwlarr:
    def __init__(self):
        self.indexers = [dict(SCHEMA[4], id=1, enable=True, tags=[]),          # TPB: set up by hand, not a Magnet site
                         dict(SCHEMA[0], id=2, enable=True, tags=[1])]         # EZTV: already there, FlareSolverr tag
        self.tags = [{"id": 1, "label": "flaresolverr"}]
        self.apps = [{"id": 1, "name": "Sonarr", "implementation": "Sonarr", "tags": []},
                     {"id": 2, "name": "Radarr", "implementation": "Radarr", "tags": []}]
        self.commands = []
        self.alive = True
        fake = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _json(self, obj, status=200):
                b = json.dumps(obj).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def _body(self):
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n)) if n else None

            def do_GET(self):
                path = urllib.parse.urlparse(self.path).path.replace("/api/v1/", "")
                if not fake.alive:
                    return self._json({}, 503)
                table = {"indexer/schema": SCHEMA, "indexer": fake.indexers, "tag": fake.tags, "applications": fake.apps,
                         "indexerproxy": [{"id": 1, "implementation": "FlareSolverr", "tags": [1]}],
                         "system/status": {"version": "1"}}
                return self._json(table.get(path, []))

            def do_POST(self):
                path = urllib.parse.urlparse(self.path).path.replace("/api/v1/", "")
                body = self._body()
                if path == "tag":
                    t = {"id": len(fake.tags) + 1, "label": body["label"]}
                    fake.tags.append(t)
                    return self._json(t)
                if path == "indexer":
                    body["id"] = 100 + len(fake.indexers)
                    fake.indexers.append(body)
                    return self._json(body)
                if path == "command":
                    fake.commands.append(body["name"])
                return self._json({})

            def do_PUT(self):
                path = urllib.parse.urlparse(self.path).path.replace("/api/v1/", "")
                body = self._body()
                kind, _, ident = path.partition("/")
                rows = fake.indexers if kind == "indexer" else fake.apps
                for i, r in enumerate(rows):
                    if str(r["id"]) == ident:
                        rows[i] = body
                return self._json(body)

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def tag_id(self):
        return next(t["id"] for t in self.tags if t["label"] == TAG)

    def named(self, name):
        return next((i for i in self.indexers if i["name"] == name), None)

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


MAGNET_SITES = [
    {"name": "EZTV", "domains": ["eztvx.to"]},
    {"name": "1337x", "domains": ["1337x.st", "1337x.to"]},
    {"name": "YTS", "domains": ["yts.mx"]},
    {"name": "FitGirl", "domains": ["fitgirl-repacks.site"]},
    {"name": "Leech", "domains": ["torrentleech.org"]},
    {"name": "LimeTorrents", "domains": ["www.limetorrents.lol"]},
]


class Plan(unittest.TestCase):
    def test_registrable(self):
        self.assertEqual(registrable("www.1337x.to"), "1337x.to")
        self.assertEqual(registrable("a.b.example.com"), "example.com")
        self.assertEqual(registrable("site.co.uk"), "site.co.uk")
        self.assertEqual(registrable("audiobookbay.lu"), "audiobookbay.lu")

    def test_coverage(self):
        coverage, wanted = plan(MAGNET_SITES, SCHEMA, [])
        by = {r["site"]: r for r in coverage}
        self.assertEqual(by["EZTV"]["status"], "searching")
        self.assertEqual(by["1337x"]["status"], "searching")
        self.assertEqual(by["YTS"]["status"], "no-tv")
        self.assertEqual(by["FitGirl"]["status"], "unsupported")
        self.assertEqual(by["Leech"]["status"], "private")
        self.assertEqual(by["LimeTorrents"]["status"], "searching")
        self.assertEqual(len(wanted), 3)
        # 1337x is added at the mirror Magnet is using when Prowlarr knows it.
        defn, preferred, _ = wanted[("Cardigann", "1337x")]
        self.assertEqual(preferred, "https://1337x.to/")


class Sync(unittest.TestCase):
    def setUp(self):
        self.fake = FakeProwlarr()
        self.store = Store(os.path.join(tempfile.mkdtemp(), "s.db"))
        self.sync = SourceSync(Prowlarr(self.fake.url, "k"), self.store, log=lambda m: None)

    def tearDown(self):
        self.fake.close()

    def test_sites_decide_what_sonarr_searches(self):
        self.sync.sync(MAGNET_SITES)
        tag = self.fake.tag_id()
        self.assertIn(tag, self.fake.named("EZTV")["tags"], "an existing indexer is adopted")
        self.assertIn(1, self.fake.named("EZTV")["tags"], "and keeps its FlareSolverr tag")
        added = self.fake.named("1337x")
        self.assertTrue(added and added["enable"])
        self.assertEqual(sorted(added["tags"]), sorted([1, tag]), "new indexers get FlareSolverr and the Magnet tag")
        self.assertEqual(next(f["value"] for f in added["fields"] if f["name"] == "baseUrl"), "https://1337x.to/")
        self.assertNotIn(tag, self.fake.named("The Pirate Bay")["tags"], "not one of Magnet's sites")
        self.assertTrue(self.fake.named("The Pirate Bay")["enable"], "but never disabled: Radarr still uses it")
        self.assertIsNone(self.fake.named("YTS"), "movies-only sites are not added for TV")
        sonarr = next(a for a in self.fake.apps if a["name"] == "Sonarr")
        radarr = next(a for a in self.fake.apps if a["name"] == "Radarr")
        self.assertEqual(sonarr["tags"], [tag], "Sonarr now syncs only the tagged indexers")
        self.assertEqual(radarr["tags"], [], "Radarr is left alone")
        self.assertEqual(self.fake.commands, ["ApplicationIndexerSync"])

    def test_removing_a_site_only_removes_the_tag(self):
        self.sync.sync(MAGNET_SITES)
        tag = self.fake.tag_id()
        self.sync.sync([s for s in MAGNET_SITES if s["name"] != "EZTV"])
        ez = self.fake.named("EZTV")
        self.assertIsNotNone(ez, "never deleted")
        self.assertNotIn(tag, ez["tags"])
        self.assertIn(1, ez["tags"])

    def test_unchanged_list_does_not_resync(self):
        self.sync.sync(MAGNET_SITES)
        self.sync.sync(MAGNET_SITES)
        self.assertEqual(self.fake.commands, ["ApplicationIndexerSync"])

    def test_empty_list_is_refused(self):
        with self.assertRaises(ValueError):
            self.sync.want([])
        with self.assertRaises(ValueError):
            self.sync.want([{"name": "x", "domains": []}])

    def test_want_waits_for_a_sleeping_prowlarr(self):
        self.fake.alive = False
        status = self.sync.want(MAGNET_SITES)
        self.assertTrue(status["pending"])
        self.assertEqual(len(status["sites"]), 6)


if __name__ == "__main__":
    unittest.main()


class SafetyFixes(unittest.TestCase):
    def setUp(self):
        self.fake = FakeProwlarr()
        self.store = Store(os.path.join(tempfile.mkdtemp(), "s.db"))
        self.sync = SourceSync(Prowlarr(self.fake.url, "k"), self.store, log=lambda m: None)

    def tearDown(self):
        self.fake.close()

    def test_no_searchable_site_leaves_sonarr_with_every_indexer(self):
        cov = self.sync.sync([{"name": "FitGirl", "domains": ["fitgirl-repacks.site"]},
                              {"name": "YTS", "domains": ["yts.mx"]}])
        self.assertFalse(any(r["status"] == "searching" for r in cov))
        self.assertEqual(next(a for a in self.fake.apps if a["name"] == "Sonarr")["tags"], [])

    def test_a_later_unsearchable_list_lifts_the_restriction(self):
        self.sync.sync(MAGNET_SITES)
        self.sync.sync([{"name": "YTS", "domains": ["yts.mx"]}])
        self.assertEqual(next(a for a in self.fake.apps if a["name"] == "Sonarr")["tags"], [])

    def test_an_indexer_turned_off_by_hand_stays_off(self):
        self.fake.indexers[1]["enable"] = False           # EZTV
        cov = self.sync.sync(MAGNET_SITES)
        self.assertFalse(self.fake.named("EZTV")["enable"])
        self.assertEqual(next(r for r in cov if r["site"] == "EZTV")["status"], "disabled")

    def test_a_list_sent_during_a_sync_is_still_pending_afterwards(self):
        self.sync.want(MAGNET_SITES[:2])
        real_sync = self.sync.sync

        def slow(sites):
            self.sync.want(MAGNET_SITES)                  # arrives while the first is applied
            return real_sync(sites)
        self.sync.sync = slow
        self.sync.apply_pending()
        self.assertTrue(self.sync.status()["pending"])
        self.sync.sync = real_sync
        self.sync.apply_pending()
        self.assertFalse(self.sync.status()["pending"])

    def test_two_sonarrs_need_a_name(self):
        self.fake.apps.append({"id": 3, "name": "Sonarr 4K", "implementation": "Sonarr", "tags": []})
        with self.assertRaises(Exception):
            self.sync.sync(MAGNET_SITES)
        named = SourceSync(Prowlarr(self.fake.url, "k"), self.store, log=lambda m: None, sonarr_app="Sonarr")
        named.sync(MAGNET_SITES)
        self.assertEqual(next(a for a in self.fake.apps if a["name"] == "Sonarr 4K")["tags"], [])
