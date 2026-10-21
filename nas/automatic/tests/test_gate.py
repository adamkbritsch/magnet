import http.server
import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request

from automatic import gate as gatemod
from automatic.api import API, make_handler as api_handler
from automatic.gate import Gate, encode_form, make_handler
from automatic.qbit import AuthRejected, QBit
from automatic.sonarr import Sonarr
from automatic.store import Store
from fakes import FakeQBit, FakeSonarr, info_hash, make_torrent

GB = 1024 ** 3
MB = 1024 ** 2
CLEAN = make_torrent("Show.S01E05.2160p.WEB-DL.DV", [("Show.S01E05.2160p.WEB-DL.DV.mkv", 5 * GB),
                                                      ("Show.S01E05.nfo", 2000)])
DIRTY = make_torrent("Show.S01E06.2160p.WEB-DL", [("Show.S01E06.mkv", 3 * GB), ("Codec/Setup.exe", 2 * MB)])
MAGNET_H = "a" * 40


def magnet(h=MAGNET_H, dn="Show.S01E07"):
    return f"magnet:?xt=urn:btih:{h}&dn={dn}"


class Harness(unittest.TestCase):
    def setUp(self):
        self.qb = FakeQBit()
        self.sn = FakeSonarr()
        self.tmp = tempfile.mkdtemp()
        with open(os.path.join(self.tmp, "secrets.json"), "w") as f:
            json.dump({"qb_username": "admin", "qb_password": FakeQBit.PASSWORD}, f)
        self.store = Store(os.path.join(self.tmp, "c.db"))
        self.qbit = QBit(self.qb.url, os.path.join(self.tmp, "secrets.json"))
        self.sonarr = Sonarr(self.sn.url, "k")
        self.gate = Gate(self.qbit, self.sonarr, self.store, "tv-sonarr", "sonarr", "gatepass", 100 * GB, log=lambda m: None)
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.gate))
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"
        self.cookie = None

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.qb.close()
        self.sn.close()

    # Sonarr's side of the conversation
    def req(self, method, path, data=None, ctype=None, auth=True):
        r = urllib.request.Request(self.url + path, data=data, method=method)
        if ctype:
            r.add_header("Content-Type", ctype)
        if auth and self.cookie:
            r.add_header("Cookie", self.cookie)
        try:
            with urllib.request.urlopen(r, timeout=10) as resp:
                return resp.status, resp.read(), resp.headers
        except urllib.error.HTTPError as e:
            return e.code, e.read(), e.headers

    def login(self, password="gatepass"):
        status, body, headers = self.req("POST", "/api/v2/auth/login",
                                         urllib.parse.urlencode({"username": "sonarr", "password": password}).encode(),
                                         "application/x-www-form-urlencoded", auth=False)
        if body == b"Ok.":
            self.cookie = headers["Set-Cookie"].split(";")[0]
        return status, body

    def add(self, torrents=(), urls=()):
        fields = [{"name": "category", "filename": None, "content_type": None, "data": b"tv-sonarr"}]
        if urls:
            fields.append({"name": "urls", "filename": None, "content_type": None, "data": "\n".join(urls).encode()})
        for i, t in enumerate(torrents):
            fields.append({"name": "torrents", "filename": f"t{i}.torrent", "content_type": "application/x-bittorrent", "data": t})
        data, ctype = encode_form(fields)
        return self.req("POST", "/api/v2/torrents/add", data, ctype)


class GateTests(Harness):
    def test_login_is_local_and_says_ok(self):
        self.assertEqual(self.login("wrong"), (200, b"Fails."))
        self.assertEqual(self.req("GET", "/api/v2/app/webapiVersion")[0], 403)
        self.assertEqual(self.login(), (200, b"Ok."))
        self.assertEqual(self.req("GET", "/api/v2/app/webapiVersion")[:2], (200, b"2.11.4"))
        self.assertEqual(self.qb.logins, 1, "the real login happens once, upstream, by the gate")

    def test_dirty_torrent_file_never_reaches_the_seedbox(self):
        self.login()
        self.sn.grabs[info_hash(DIRTY).upper()] = 77
        self.assertEqual(self.add([DIRTY])[:2], (200, b"Ok."))
        self.assertEqual(self.qb.actions("/api/v2/torrents/add"), [])
        self.assertEqual(self.store.decision(info_hash(DIRTY))["verdict"], "rejected")
        self.gate.poll()
        self.assertEqual(self.sn.failed, [77], "Sonarr was told, so it blocklists and searches again")
        self.gate.poll()
        self.assertEqual(self.sn.failed, [77], "told once")

    def test_clean_torrent_file_starts_once_qbittorrents_own_list_is_judged(self):
        self.login()
        self.add([CLEAN])
        t = self.qb.torrents[info_hash(CLEAN)]
        self.assertEqual(t["state"], "stoppedDL", "in stopped: this parser's reading is not the verdict")
        self.assertEqual(t["category"], "tv-sonarr")
        self.gate.poll()
        self.assertEqual(self.qb.torrents[info_hash(CLEAN)]["state"], "downloading")
        self.assertEqual(self.store.decision(info_hash(CLEAN))["verdict"], "approved")
        self.assertEqual(self.qb.actions("/api/v2/torrents/delete"), [])

    def test_a_list_qbittorrent_reads_differently_is_caught(self):
        # This parser saw a clean file; qBittorrent's own list has the payload.
        self.login()
        self.add([CLEAN])
        h = info_hash(CLEAN)
        self.qb.torrents[h]["files"].append({"name": "Show/Setup.exe", "size": 2 * MB})
        self.gate.poll()
        self.assertNotIn(h, self.qb.torrents)
        self.assertEqual(self.store.decision(h)["verdict"], "rejected")

    def test_mixed_add_keeps_the_clean_one(self):
        self.login()
        self.add([CLEAN, DIRTY])
        self.assertIn(info_hash(CLEAN), self.qb.torrents)
        self.assertNotIn(info_hash(DIRTY), self.qb.torrents)

    def test_magnet_is_held_until_its_file_list_is_read(self):
        self.login()
        self.add(urls=[magnet()])
        fields = {f["name"]: f["data"] for f in self.qb.actions("/api/v2/torrents/add")[0][2]}
        self.assertEqual(fields["stopCondition"], b"MetadataReceived")
        self.assertEqual(fields["category"], b"tv-sonarr")
        self.gate.poll()  # still fetching metadata: nothing to judge yet
        self.assertEqual(self.store.decision(MAGNET_H)["verdict"], "held")
        self.qb.finish_metadata(MAGNET_H, [("Show.S01E07.mkv", 3 * GB)], "Show.S01E07")
        self.assertEqual(self.qb.torrents[MAGNET_H]["state"], "stoppedDL")
        self.gate.poll()
        self.assertEqual(self.qb.torrents[MAGNET_H]["state"], "downloading")
        self.assertEqual(self.store.decision(MAGNET_H)["verdict"], "approved")

    def test_dirty_magnet_is_deleted_and_reported(self):
        self.login()
        self.sn.grabs[MAGNET_H.upper()] = 91
        self.add(urls=[magnet()])
        self.qb.finish_metadata(MAGNET_H, [("4F1C9A0E2B7D63A85C0E91F27D4B6A3E98C1D2F0.scr", int(0.9 * GB))])
        self.gate.poll()
        self.assertNotIn(MAGNET_H, self.qb.torrents)
        self.assertEqual(self.store.decision(MAGNET_H)["reason"], "contains an executable (.scr)")
        self.assertEqual(self.sn.failed, [91])

    def test_base32_magnet(self):
        self.assertEqual(gatemod.magnet_hash("magnet:?xt=urn:btih:MFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLB"), "61" * 20)

    def test_torrent_that_slipped_in_running_is_stopped_then_judged(self):
        # Added to the category behind the gate's back, already downloading.
        h = "b" * 40
        self.qb.torrents[h] = {"hash": h, "name": "x", "category": "tv-sonarr", "state": "downloading",
                               "progress": 0.1, "added_on": 3, "files": [{"name": "x/Setup.exe", "size": 2 * MB},
                                                                         {"name": "x/x.mkv", "size": GB}]}
        self.gate.poll()
        self.assertEqual([c[1] for c in self.qb.calls if "torrents/" in c[1] and c[1] != "/api/v2/torrents/info"
                          and c[1] != "/api/v2/torrents/files"], ["/api/v2/torrents/stop", "/api/v2/torrents/delete"])
        self.assertNotIn(h, self.qb.torrents)

    def test_sonarr_cannot_start_an_unapproved_torrent(self):
        self.login()
        self.add(urls=[magnet()])
        before = len(self.qb.actions("/api/v2/torrents/start"))
        self.req("POST", "/api/v2/torrents/start", urllib.parse.urlencode({"hashes": MAGNET_H}).encode(),
                 "application/x-www-form-urlencoded")
        self.assertEqual(len(self.qb.actions("/api/v2/torrents/start")), before)

    def test_actions_are_confined_to_the_category(self):
        self.login()
        other = "c" * 40
        self.qb.torrents[other] = {"hash": other, "name": "Magnet pick", "category": "", "state": "uploading",
                                   "progress": 1.0, "added_on": 1, "files": []}
        self.gate.poll()
        self.req("POST", "/api/v2/torrents/delete", urllib.parse.urlencode({"hashes": other, "deleteFiles": "true"}).encode(),
                 "application/x-www-form-urlencoded")
        self.assertIn(other, self.qb.torrents, "a torrent outside tv-sonarr is not the gate's to delete")

    def test_denied_endpoints(self):
        self.login()
        for path in ("/api/v2/app/setPreferences", "/api/v2/app/shutdown", "/api/v2/search/start", "/api/v2/rss/addFeed"):
            with self.subTest(path=path):
                self.assertEqual(self.req("POST", path, b"json={}", "application/x-www-form-urlencoded")[0], 403)

    def test_low_disk_holds_then_starts(self):
        self.login()
        self.qb.free = 20 * GB
        self.add([CLEAN])
        h = info_hash(CLEAN)
        self.gate.poll()
        self.assertEqual(self.qb.torrents[h]["state"], "stoppedDL")
        self.assertEqual(self.store.decision(h)["verdict"], "waiting")
        self.qb.free = 400 * GB
        self.gate.free_checked = 0
        self.gate.poll()
        self.assertEqual(self.qb.torrents[h]["state"], "downloading")

    def test_rejected_login_is_never_retried_by_itself(self):
        with open(os.path.join(self.tmp, "secrets.json"), "w") as f:
            json.dump({"qb_username": "admin", "qb_password": "stale"}, f)
        for _ in range(5):
            with self.assertRaises(AuthRejected):
                self.qbit.request("GET", "/api/v2/app/webapiVersion")
        self.assertEqual(self.qb.logins, 1, "one refusal, then silence: the NAS IP must not get banned")
        self.qbit.save_credentials("admin", FakeQBit.PASSWORD)
        self.assertEqual(self.qbit.request("GET", "/api/v2/app/webapiVersion")[0], 200)


class TransferTests(Harness):
    def setUp(self):
        super().setUp()
        self.api = API(self.gate, self.sonarr, self.store, "tok", ("/downloads/", "/seedbox/downloads/"), log=lambda m: None)

    def test_bring_to_nas_copies_through_sonarr(self):
        self.login()
        self.add([CLEAN])
        h = info_hash(CLEAN)
        self.qb.torrents[h].update(progress=1.0, state="stoppedUP")
        self.gate.poll()
        out = self.api.transfer(h)
        cmd = self.sn.commands[-1]
        self.assertEqual(cmd["name"], "DownloadedEpisodesScan")
        self.assertEqual(cmd["importMode"], "Copy")
        self.assertEqual(cmd["path"], "/seedbox/downloads/tv-sonarr/Show.S01E05.2160p.WEB-DL.DV")
        self.assertEqual(cmd["downloadClientId"], h.upper())
        with self.assertRaises(ValueError):
            self.api.transfer(h)  # already on its way
        self.assertEqual(self.store.transfers()[0]["id"], out["id"])

    def test_unfinished_and_unapproved_are_refused(self):
        self.login()
        self.add([CLEAN])
        h = info_hash(CLEAN)
        self.gate.poll()
        with self.assertRaisesRegex(ValueError, "still downloading"):
            self.api.transfer(h)
        self.add(urls=[magnet()])
        self.gate.poll()
        with self.assertRaisesRegex(ValueError, "approved"):
            self.api.transfer(MAGNET_H)

    def test_last_door_check(self):
        self.login()
        self.add([CLEAN])
        h = info_hash(CLEAN)
        self.qb.torrents[h].update(progress=1.0, state="stalledUP")
        self.gate.poll()
        self.qb.torrents[h]["files"].append({"name": "Show/autorun.exe", "size": MB})
        with self.assertRaisesRegex(ValueError, "refused"):
            self.api.transfer(h)
        self.assertNotIn(h, self.qb.torrents)
        self.assertEqual(self.sn.commands, [])

    def test_api_needs_the_token(self):
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), api_handler(self.api))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{srv.server_address[1]}"
            with urllib.request.urlopen(url + "/healthz", timeout=5) as r:
                self.assertEqual(r.status, 200)
            with self.assertRaises(urllib.error.HTTPError) as e:
                urllib.request.urlopen(url + "/v1/overview", timeout=5)
            self.assertEqual(e.exception.code, 401)
            r = urllib.request.Request(url + "/v1/events", headers={"Authorization": "Bearer tok"})
            with urllib.request.urlopen(r, timeout=5) as resp:
                self.assertEqual(resp.status, 200)
        finally:
            srv.shutdown()
            srv.server_close()


if __name__ == "__main__":
    unittest.main()


class ReviewFixes(Harness):
    def test_a_queued_magnet_is_not_stopped_before_it_has_a_file_list(self):
        self.login()
        self.add(urls=[magnet()])
        self.qb.torrents[MAGNET_H]["state"] = "queuedDL"
        self.gate.poll()
        self.assertEqual(self.qb.actions("/api/v2/torrents/stop"), [])

    def test_a_stopped_magnet_without_a_file_list_is_added_again_with_its_stop_condition(self):
        self.login()
        self.add(urls=[magnet()])
        self.qb.torrents[MAGNET_H]["state"] = "stoppedDL"
        self.gate.poll()
        self.assertEqual(self.qb.actions("/api/v2/torrents/start"), [], "a plain start would download unjudged")
        adds = self.qb.actions("/api/v2/torrents/add")
        self.assertEqual(len(adds), 2)
        fields = {f["name"]: f["data"] for f in adds[1][2]}
        self.assertEqual(fields["stopCondition"], b"MetadataReceived")
        self.assertEqual(self.qb.torrents[MAGNET_H]["state"], "metaDL")

    def test_an_unreadable_torrent_goes_in_stopped_and_is_judged_from_the_client(self):
        self.login()
        data, ctype = encode_form([
            {"name": "category", "filename": None, "content_type": None, "data": b"tv-sonarr"},
            {"name": "torrents", "filename": "x.torrent", "content_type": None, "data": b"d4:infoi1ee"}])
        self.assertEqual(self.req("POST", "/api/v2/torrents/add", data, ctype)[:2], (200, b"Ok."))
        fields = {f["name"]: f["data"] for f in self.qb.actions("/api/v2/torrents/add")[0][2] if f["filename"] is None}
        self.assertEqual(fields["stopped"], b"true")

    def test_a_torrent_file_goes_in_stopped_whatever_the_clients_default(self):
        self.login()
        self.add([CLEAN])
        fields = {f["name"]: f["data"] for f in self.qb.actions("/api/v2/torrents/add")[0][2] if f["filename"] is None}
        self.assertEqual(fields["stopped"], b"true")
        self.gate.poll()
        self.assertEqual(len(self.qb.actions("/api/v2/torrents/start")), 1)

    def test_percent_encoded_and_unknown_paths_are_refused(self):
        self.login()
        other = "e" * 40
        self.qb.torrents[other] = {"hash": other, "name": "x", "category": "", "state": "uploading",
                                   "progress": 1.0, "added_on": 1, "files": []}
        body = urllib.parse.urlencode({"hashes": "all", "deleteFiles": "true"}).encode()
        self.req("POST", "/api/v2/torrents/delet%65", body, "application/x-www-form-urlencoded")
        self.assertIn(other, self.qb.torrents, "decoded, it is delete -- and still scoped to the category")
        for path in ("/api/v2/app/setPref%65rences", "/api/v2/torrents/rename", "/api/v2/torrents/renameFile"):
            with self.subTest(path=path):
                self.assertEqual(self.req("POST", path, b"x=1", "application/x-www-form-urlencoded")[0], 403)
        self.assertEqual(self.req("GET", "/api/v2/torrents/start?hashes=all")[0], 403, "actions are POST only")

    def test_hashes_in_the_query_string_are_scoped_too(self):
        self.login()
        other = "f" * 40
        self.qb.torrents[other] = {"hash": other, "name": "x", "category": "", "state": "uploading",
                                   "progress": 1.0, "added_on": 1, "files": []}
        self.gate.poll()
        self.req("POST", "/api/v2/torrents/delete?hashes=" + other + "&deleteFiles=true", b"",
                 "application/x-www-form-urlencoded")
        self.assertIn(other, self.qb.torrents)

    def test_a_second_grab_of_a_banned_release_is_reported_again(self):
        self.login()
        h = MAGNET_H
        self.sn.grabs[h.upper()] = 91
        self.add(urls=[magnet()])
        self.qb.finish_metadata(h, [("x.scr", GB)])
        self.gate.poll()
        self.assertEqual(self.sn.failed, [91])
        self.sn.grabs[h.upper()] = 92        # Sonarr grabbed it again from another indexer
        self.add(urls=[magnet()])
        self.qb.finish_metadata(h, [("x.scr", GB)])
        self.gate.poll()
        self.gate.poll()
        self.assertEqual(self.sn.failed, [91, 92])

    def test_a_mistyped_login_does_not_stop_the_one_that_works(self):
        self.assertEqual(self.qbit.request("GET", "/api/v2/app/webapiVersion")[0], 200)
        with self.assertRaises(AuthRejected):
            self.qbit.login("admin", "typo")
        self.assertFalse(self.qbit.blocked)
        self.assertEqual(self.qbit.request("GET", "/api/v2/app/webapiVersion")[0], 200)


class QBittorrentStates(Harness):
    """The torrent as qBittorrent's own list would show it decides what happens."""

    def _approved(self, **state):
        self.login()
        self.add([CLEAN])
        h = info_hash(CLEAN)
        self.gate.poll()
        self.qb.torrents[h].update(**state)
        starts = len(self.qb.actions("/api/v2/torrents/start"))
        self.gate.poll()
        return h, len(self.qb.actions("/api/v2/torrents/start")) - starts

    def test_paused_after_a_check_with_data_left_is_started_again(self):
        h, started = self._approved(state="stoppedDL", progress=0.62, amount_left=2 * GB)
        self.assertEqual(started, 1)
        self.assertEqual(self.qb.torrents[h]["state"], "downloading")
        self.assertIn("started again", self.store.events(5)[0]["message"])

    def test_a_finished_one_is_left_stopped(self):
        _, started = self._approved(state="stoppedUP", progress=1.0, amount_left=0)
        self.assertEqual(started, 0)

    def test_a_check_in_progress_is_left_alone(self):
        _, started = self._approved(state="checkingDL", progress=0.30, amount_left=3 * GB)
        self.assertEqual(started, 0)
        self.assertEqual(self.qb.actions("/api/v2/torrents/stop"), [])

    def test_no_room_means_it_waits(self):
        self.qb.free = 400 * GB
        h, _ = self._approved(state="downloading", progress=0.1)
        self.qb.free = 5 * GB
        self.gate.free_checked = 0
        self.qb.torrents[h].update(state="stoppedDL", progress=0.5, amount_left=2 * GB)
        before = len(self.qb.actions("/api/v2/torrents/start"))
        self.gate.poll()
        self.assertEqual(len(self.qb.actions("/api/v2/torrents/start")), before)

    def test_it_stops_fighting_after_six_restarts_in_an_hour(self):
        self.login()
        self.add([CLEAN])
        h = info_hash(CLEAN)
        self.gate.poll()
        approved_start = len(self.qb.actions("/api/v2/torrents/start"))
        for _ in range(9):
            self.qb.torrents[h].update(state="stoppedDL", progress=0.5, amount_left=GB)
            self.gate.poll()
        self.assertEqual(len(self.qb.actions("/api/v2/torrents/start")) - approved_start, 6)
        self.assertTrue(any(e["kind"] == "stuck" for e in self.store.events(20)))

    def test_errored_or_missing_files_are_rechecked(self):
        _, _ = self._approved(state="missingFiles", progress=0.4)
        self.assertEqual(len(self.qb.actions("/api/v2/torrents/recheck")), 1)

    def test_not_judged_while_checking(self):
        self.login()
        self.add(urls=[magnet()])
        self.qb.finish_metadata(MAGNET_H, [("Show.S01E07.mkv", 3 * GB)])
        self.qb.torrents[MAGNET_H]["state"] = "checkingDL"
        self.gate.poll()
        self.assertEqual(self.store.decision(MAGNET_H)["verdict"], "held")

    def test_bring_to_nas_waits_for_the_check_and_the_finish(self):
        api = API(self.gate, self.sonarr, self.store, "tok", ("/downloads/", "/seedbox/downloads/"), log=lambda m: None)
        self.login()
        self.add([CLEAN])
        h = info_hash(CLEAN)
        self.gate.poll()
        self.qb.torrents[h].update(state="checkingUP", progress=0.99)
        self.gate.poll()
        with self.assertRaisesRegex(ValueError, "checking"):
            api.transfer(h)
        self.qb.torrents[h].update(state="stoppedDL", progress=0.97, amount_left=100 * MB)
        self.gate.poll()       # resumes it
        with self.assertRaisesRegex(ValueError, "still downloading"):
            api.transfer(h)
        self.qb.torrents[h].update(state="stalledUP", progress=1.0, amount_left=0)
        self.gate.poll()
        api.transfer(h)
        self.assertEqual(self.sn.commands[-1]["name"], "DownloadedEpisodesScan")


class SecondReviewFixes(Harness):
    def test_an_empty_username_is_refused_and_the_working_login_kept(self):
        api = API(self.gate, self.sonarr, self.store, "tok", ("/downloads/", "/seedbox/downloads/"), log=lambda m: None)
        with self.assertRaises(ValueError):
            api.seedbox_login("", "x")
        self.assertTrue(self.qbit.configured)

    def test_nothing_is_read_before_logging_in(self):
        status, _, _ = self.req("POST", "/api/v2/torrents/add", b"x" * 1000, "application/x-www-form-urlencoded", auth=False)
        self.assertEqual(status, 403)

    def test_another_apps_category_cannot_be_touched(self):
        self.login()
        for path, body in (("/api/v2/torrents/editCategory", "category=radarr&savePath=/x"),
                           ("/api/v2/torrents/createCategory", "category=radarr&savePath=/x")):
            with self.subTest(path=path):
                self.assertEqual(self.req("POST", path, body.encode(), "application/x-www-form-urlencoded")[0], 403)
        self.assertEqual(self.req("POST", "/api/v2/torrents/createCategory", b"category=tv-sonarr",
                                  "application/x-www-form-urlencoded")[0], 200)
