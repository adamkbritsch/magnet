import datetime as dt
import time

from automatic.api import API
from automatic.scout import Scout
from fakes import info_hash, make_torrent
from test_gate import CLEAN, GB, Harness

CLIENT = "Seedbox qBittorrent (via Magnet)"
T0 = 1_800_000_000.0


def iso(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).isoformat().replace("+00:00", "Z")


class Controls(Harness):
    def setUp(self):
        super().setUp()
        self.now = [T0]
        self.scout = Scout(self.gate, self.sonarr, self.store, log=lambda m: None, clock=lambda: self.now[0])
        self.api = API(self.gate, self.sonarr, self.store, "tok", ("/downloads/", "/seedbox/downloads/"),
                       log=lambda m: None, scout=self.scout)
        self.sn.series[9] = {"id": 9, "title": "Show", "tvdbId": 99, "qualityProfileId": 8, "monitored": True,
                             "status": "continuing", "path": "/tv/Show"}

    def grab(self, ep, h, score=500, at=None, formats=()):
        self.sn.history.append({"episodeId": ep, "seriesId": 9, "date": iso(at or time.time()),
                                "customFormatScore": score, "downloadId": h.upper(), "sourceTitle": "x",
                                "customFormats": [{"name": "Magnet: " + f} for f in formats],
                                "data": {"downloadClientName": CLIENT}})
        self.api._grabs = (0.0, {})

    # -- pause -----------------------------------------------------------------------
    def test_paused_nothing_new_starts_and_it_starts_on_resume(self):
        self.api.set_paused(True)
        self.login()
        self.add([CLEAN])
        h = info_hash(CLEAN)
        self.gate.poll()
        self.assertEqual(self.store.decision(h)["verdict"], "paused")
        self.assertEqual(self.qb.torrents[h]["state"], "stoppedDL", "judged, and left stopped")
        self.gate.poll()
        self.assertEqual(self.store.decision(h)["verdict"], "paused")
        self.api.set_paused(False)
        self.gate.poll()
        self.assertEqual(self.store.decision(h)["verdict"], "approved")
        self.assertEqual(self.qb.torrents[h]["state"], "downloading")

    def test_paused_a_bad_release_is_still_refused(self):
        self.api.set_paused(True)
        self.login()
        bad = make_torrent("Show.S01E05", [("Show.S01E05.exe", 3 * GB)])
        self.add([bad])
        self.gate.poll()
        self.assertEqual(self.store.decision(info_hash(bad))["verdict"], "rejected")

    def test_paused_the_scout_and_the_copy_stand_still(self):
        self.api.set_paused(True)
        self.sn.calendar = [{"id": 5, "seriesId": 9, "airDateUtc": iso(T0 - 3600), "monitored": True,
                             "hasFile": False}]
        self.scout.run_once()
        self.assertEqual(self.sn.searches(), [])
        self.login()
        self.add([CLEAN])
        h = info_hash(CLEAN)
        self.store.decide(h, "approved", "x")
        self.qb.torrents[h].update(progress=1.0, state="stoppedUP", amount_left=0)
        self.grab(5, h)
        self.gate.poll()
        self.api.auto_transfer()
        self.assertEqual([c for c in self.sn.commands if c.get("name") == "DownloadedEpisodesScan"], [])
        self.assertTrue(self.api.overview()["paused"])

    def test_pausing_is_recorded_once(self):
        self.api.set_paused(True)
        self.api.set_paused(True)
        self.api.set_paused(False)
        kinds = [e["kind"] for e in self.store.events(10)]
        self.assertEqual(kinds, ["resumed", "paused"])

    # -- search now ---------------------------------------------------------------------
    def test_search_now_with_no_copy_takes_the_best_release(self):
        self.sn.releases[5] = [{"guid": "a", "indexerId": 1, "approved": True, "customFormatScore": 500, "title": "A"},
                               {"guid": "b", "indexerId": 1, "approved": True, "customFormatScore": 1500, "title": "B"}]
        out = self.api.search_now(5)
        self.assertEqual(out["taken"], "B")
        self.assertEqual(self.sn.taken, [{"guid": "b", "indexerId": 1}])

    def test_search_now_with_a_copy_takes_only_better(self):
        self.store.decide("c" * 40, "approved", "x")
        self.grab(5, "c" * 40, score=1500)
        self.sn.releases[5] = [{"guid": "same", "indexerId": 1, "approved": True, "customFormatScore": 1550}]
        out = self.api.search_now(5)
        self.assertIsNone(out["taken"])
        self.assertIn("better", out["message"])

    def test_search_now_is_refused_while_paused(self):
        self.api.set_paused(True)
        with self.assertRaisesRegex(ValueError, "paused"):
            self.api.search_now(5)

    # -- quality levels -----------------------------------------------------------------
    def test_4k_level_makes_a_profile_that_takes_only_2160p(self):
        show = self.api.set_quality(9, "4k")
        made = next(p for p in self.sn.profiles if p["name"] == "Magnet 4K")
        self.assertEqual(self.sn.series[9]["qualityProfileId"], made["id"])
        self.assertFalse(next(i for i in made["items"] if i["name"] == "HD 720p")["allowed"])
        self.assertEqual(next(f for f in made["formatItems"] if f["name"] == "Magnet: 1080p")["score"], -100000)
        self.assertEqual(show["quality"], "4k")
        self.assertTrue(show["magnetProfile"])

    def test_dv_level_sets_a_minimum_score_and_a_level_is_made_once(self):
        self.api.set_quality(9, "dv")
        self.api.set_quality(9, "first")
        self.api.set_quality(9, "dv")
        made = [p for p in self.sn.profiles if p["name"] == "Magnet Dolby Vision"]
        self.assertEqual(len(made), 1)
        self.assertEqual(made[0]["minFormatScore"], 8000)
        self.assertEqual(self.sn.series[9]["qualityProfileId"], made[0]["id"])

    def test_an_unknown_level_is_refused(self):
        with self.assertRaises(ValueError):
            self.api.set_quality(9, "8k")

    # -- activity -----------------------------------------------------------------------
    def test_activity_names_the_episode_and_spots_an_upgrade(self):
        self.sn.episodes[5] = {"seriesId": 9, "seasonNumber": 1, "episodeNumber": 5, "title": "Firewall"}
        a, b = "a" * 40, "b" * 40
        self.grab(5, a, formats=["1080p"])
        self.grab(5, b, score=13800, formats=["2160p", "DV Boost"])
        self.store.event("transferred", a, "Show.S01E05.1080p: on the NAS")
        self.store.event("transferred", b, "Show.S01E05.2160p.DV: on the NAS")
        out = self.api.activity()
        first, second = out["events"][1], out["events"][0]
        self.assertEqual((second["series"], second["season"], second["episode"], second["episodeTitle"]),
                         ("Show", 1, 5, "Firewall"))
        self.assertFalse(first["upgrade"])
        self.assertTrue(second["upgrade"], "the second arrival of an episode is an upgrade")
        self.assertEqual(second["formats"], ["2160p", "DV Boost"])
        self.assertEqual(second["detail"], "on the NAS")

    def test_activity_since_returns_only_newer(self):
        self.store.event("follow", "", "following Show (new episodes only)")
        latest = self.api.activity()["latest"]
        self.store.event("paused", "", "Automatic paused")
        newer = self.api.activity(since=latest)["events"]
        self.assertEqual([e["kind"] for e in newer], ["paused"])

    def test_a_settled_event_is_tied_to_its_episode(self):
        self.sn.episodes[5] = {"seriesId": 9, "seasonNumber": 1, "episodeNumber": 5, "title": "Firewall"}
        self.grab(6, "d" * 40)                  # any grab, so Sonarr is consulted
        self.store.event("settled", "", "episode 5: kept X (score 500); no longer looking for better")
        e = self.api.activity()["events"][0]
        self.assertEqual((e["seriesId"], e["episode"]), (9, 5))

    def test_attention_lists_a_missing_seedbox_sign_in(self):
        self.api.qbit = type("Q", (), {"configured": False, "blocked": False, "last_error": ""})()
        self.assertEqual([a["key"] for a in self.api.attention()], ["seedbox-login"])

    # -- a show -------------------------------------------------------------------------
    def test_a_show_lists_its_seasons_with_what_the_library_holds(self):
        self.sn.episodes.update({
            5: {"seriesId": 9, "seasonNumber": 1, "episodeNumber": 5, "title": "Firewall", "episodeFileId": 55,
                "airDateUtc": iso(T0)},
            6: {"seriesId": 9, "seasonNumber": 1, "episodeNumber": 6, "title": "Deadlock"},
            1: {"seriesId": 9, "seasonNumber": 2, "episodeNumber": 1, "title": "Next"},
            0: {"seriesId": 9, "seasonNumber": 0, "episodeNumber": 1, "title": "Special"}})
        self.sn.has_file.add(5)
        self.sn.files[55] = {"seriesId": 9, "quality": {"quality": {"name": "WEBDL-2160p"}}, "customFormatScore": 15025,
                             "customFormats": [{"name": "Magnet: DV Boost"}, {"name": "Magnet: 2160p"}],
                             "size": 4 * GB, "relativePath": "Season 01/x.mkv"}
        out = self.api.show(9)
        self.assertEqual([s["season"] for s in out["seasons"]], [2, 1, 0], "newest first, specials last")
        ep5 = next(e for e in out["seasons"][1]["episodes"] if e["episode"] == 5)
        self.assertEqual(ep5["file"]["quality"], "WEBDL-2160p")
        self.assertEqual(ep5["file"]["formats"], ["2160p", "DV Boost"])
        self.assertFalse(next(e for e in out["seasons"][1]["episodes"] if e["episode"] == 6)["hasFile"])
        self.assertEqual(out["show"]["quality"], "first")
        self.assertEqual([l["id"] for l in out["levels"]], ["first", "4k", "dv"])
        self.assertEqual(out["profile"], "Magnet")
