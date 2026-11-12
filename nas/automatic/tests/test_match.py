import datetime as dt
import time
import unittest

from automatic import match as m
from automatic.api import API
from automatic.match import SeasonMatch
from automatic.scout import Scout
from fakes import info_hash, make_torrent
from test_gate import GB, Harness

CLIENT = "Seedbox qBittorrent (via Magnet)"
WEB = {"quality": {"name": "WEBDL-1080p", "source": "web", "resolution": 1080}}
HDTV = {"quality": {"name": "HDTV-1080p", "source": "television", "resolution": 1080}}
CAKES = "Show S01E07 1080p WEB H264-CAKES"
SET_ASIDE = ["Existing file on disk has a equal or higher Custom Format score: 500"]


def iso(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).isoformat().replace("+00:00", "Z")


def web_file(size, at=0, score=450):
    return {"seriesId": 9, "quality": WEB, "size": size, "customFormatScore": score, "dateAdded": iso(at or 1),
            "mediaInfo": {"videoCodec": "h264", "videoDynamicRangeType": ""}, "path": "/tv/Show/Season 01/x.mkv",
            "relativePath": "Season 01/Show.S01E05.1080p.WEB.h264-ETHEL.mkv"}


def release(guid, title, quality=WEB, score=500, seeders=100, rejections=SET_ASIDE, **extra):
    return dict({"guid": guid, "indexerId": 1, "title": title, "quality": quality, "customFormatScore": score,
                 "seeders": seeders, "approved": not rejections, "rejections": rejections, "protocol": "torrent"},
                **extra)


class Formats(unittest.TestCase):
    def test_a_file_reads_by_what_sonarr_saw_in_it(self):
        f = {"quality": HDTV, "mediaInfo": {"videoCodec": "x265", "videoDynamicRangeType": ""}}
        self.assertEqual(m.label(m.file_format(f)), "HDTV 1080p H.265")
        f = {"quality": {"quality": {"name": "WEBDL-2160p", "source": "web", "resolution": 2160}},
             "mediaInfo": {"videoCodec": "x265", "videoDynamicRangeType": "DV HDR10"}}
        self.assertEqual(m.label(m.file_format(f)), "WEB 2160p H.265 Dolby Vision")

    def test_a_release_reads_by_its_title(self):
        def fmt(title, quality=WEB, cfs=()):
            return m.label(m.release_format({"title": title, "quality": quality,
                                             "customFormats": [{"name": n} for n in cfs]}))
        self.assertEqual(fmt(CAKES), "WEB 1080p H.264")
        self.assertEqual(fmt("Show S01E07 The Title 1080p AMZN WEB-DL DDP5 1 H 264-NTb"), "WEB 1080p H.264")
        self.assertEqual(fmt("Show.S01E07.1080p.x265-ELiTE", HDTV), "HDTV 1080p H.265")
        self.assertEqual(fmt("Show S01E07 2160p DSNP WEB-DL DDP5 1 Atmos DV HDR H 265-Kitsune",
                             {"quality": {"name": "WEBDL-2160p", "source": "web", "resolution": 2160}}),
                         "WEB 2160p H.265 Dolby Vision")
        self.assertEqual(fmt("Show S01E07 1080p WEB HEVC", cfs=["Magnet: HDR"]), "WEB 1080p H.265 HDR")

    def test_a_format_a_file_did_not_report_is_not_held_against_a_release(self):
        want = {"source": "WEB", "resolution": "1080p", "codec": None, "range": "SDR"}
        self.assertTrue(m.fits({"source": "WEB", "resolution": "1080p", "codec": "H.264", "range": "SDR"}, want))
        self.assertFalse(m.fits({"source": "HDTV", "resolution": "1080p", "codec": "H.264", "range": "SDR"}, want))

    def test_the_target_is_the_format_of_the_biggest_files(self):
        eps = [{"id": i, "episodeNumber": i, "hasFile": True, "episodeFileId": 100 + i} for i in (1, 2, 3)]
        eps.append({"id": 4, "episodeNumber": 4, "hasFile": False, "airDateUtc": iso(1)})
        files = {101: web_file(1.1 * GB), 102: web_file(1.2 * GB),
                 103: {"quality": HDTV, "size": 0.4 * GB, "mediaInfo": {"videoCodec": "x265"}}}
        out = m.summarize(eps, files)
        self.assertEqual(out["target"], "WEB 1080p H.264")
        self.assertEqual([g["label"] for g in out["groups"]], ["WEB 1080p H.264", "HDTV 1080p H.265"])
        self.assertEqual([e["state"] for e in out["episodes"]], ["match", "match", "off", "missing"])
        other = m.summarize(eps, files, target="HDTV 1080p H.265")
        self.assertEqual([e["state"] for e in other["episodes"]], ["off", "off", "match", "missing"])


class Matching(Harness):
    def setUp(self):
        super().setUp()
        self.now = [time.time()]
        self.match = SeasonMatch(self.sonarr, self.store, log=lambda m: None, clock=lambda: self.now[0],
                                 paused=lambda: self.store.get("paused", False), background=False)
        self.api = API(self.gate, self.sonarr, self.store, "tok", ("/downloads/", "/seedbox/downloads/"),
                       log=lambda m: None, match=self.match)
        self.sn.series[9] = {"id": 9, "title": "Show", "qualityProfileId": 8, "monitored": True}
        for i in (5, 6, 7):
            self.sn.episodes[i] = {"seriesId": 9, "seasonNumber": 1, "episodeNumber": i, "title": f"Ep {i}",
                                   "episodeFileId": 70 + i, "airDateUtc": iso(1)}
            self.sn.has_file.add(i)
        self.sn.files[75] = web_file(1.1 * GB)
        self.sn.files[76] = web_file(1.15 * GB)
        # The odd one out: smaller, and to Magnet's scoring better than the others.
        self.sn.files[77] = {"seriesId": 9, "quality": HDTV, "size": 0.4 * GB, "customFormatScore": 500,
                             "mediaInfo": {"videoCodec": "x265"}, "dateAdded": iso(1),
                             "relativePath": "Season 01/Show.S01E07.1080p.x265-ELiTE.mkv"}
        self.sn.releases[7] = [
            release("cakes", CAKES, seeders=1000),
            release("fake", "Show S01E07 The Title 1080p WEB H264-FLUX", score=1200, rejections=["Release is blocklisted"]),
            release("small", "Show.S01E07.1080p.x265-ELiTE", HDTV, score=500, seeders=900),
            release("pack", "Show S01 1080p WEB H264-CAKES", score=600, fullSeason=True),
            release("dead", "Show S01E07 1080p WEB H264-TRB", score=700, seeders=0),
            release("banned", "Show S01E07 1080p WEB H264-XX", score=-100000),
        ]

    def grabbed(self, title=CAKES, raw=None, score=450):
        """Sonarr grabbed the release the match took; the gate passed it and it finished."""
        raw = raw or make_torrent("Show.S01E07.1080p.WEB.H264-CAKES", [("Show.S01E07.1080p.WEB.H264-CAKES.mkv", GB)])
        self.login()
        self.add([raw])
        h = info_hash(raw)
        self.sn.history.append({"episodeId": 7, "seriesId": 9, "date": iso(time.time()), "customFormatScore": score,
                                "downloadId": h.upper(), "sourceTitle": title, "customFormats": [],
                                "data": {"downloadClientName": CLIENT}})
        self.api._grabs = (0.0, {})
        self.gate.poll()
        self.qb.torrents[h].update(progress=1.0, state="stoppedUP", amount_left=0)
        self.gate.poll()
        folder = "/seedbox/downloads/tv-sonarr/" + self.qb.torrents[h]["name"]
        self.sn.manual[folder] = [
            {"path": folder + "/Sample/sample.mkv", "series": {"id": 9}, "episodes": [{"id": 7}], "size": 1000,
             "rejections": [{"reason": "Sample", "type": "permanent"}]},
            {"path": folder + "/Show.S01E07.1080p.WEB.H264-CAKES.mkv", "series": {"id": 9}, "episodes": [{"id": 7}], "size": GB,
             "quality": WEB, "languages": [{"id": 1, "name": "English"}], "releaseGroup": "CAKES",
             "rejections": SET_ASIDE}]
        return h

    def old_copy_in_the_library(self):
        """The small copy came through Magnet too: on the NAS and gone from the seedbox."""
        old = "e" * 40
        self.store.decide(old, "imported", "Show.S01E07.1080p.x265-ELiTE")
        self.sn.history.append({"episodeId": 7, "seriesId": 9, "date": iso(time.time() - 86400),
                                "customFormatScore": 500, "downloadId": old.upper(),
                                "sourceTitle": "Show.S01E07.1080p.x265-ELiTE", "customFormats": [],
                                "data": {"downloadClientName": CLIENT}})
        self.api._grabs = (0.0, {})

    def commands(self, name):
        return [c for c in self.sn.commands if c.get("name") == name]

    # -- taking a release ---------------------------------------------------------
    def test_the_odd_episode_gets_the_seasons_format_whatever_its_score(self):
        out = self.api.season_match(9, 1)
        self.assertEqual((out["started"], out["target"]), (1, "WEB 1080p H.264"))
        self.assertEqual(self.sn.taken, [{"guid": "cakes", "indexerId": 1}],
                         "not the fake, the other format, the pack, the dead one or the banned one")
        self.assertEqual(self.sn.looked, [7], "only the episode not in the format is searched")
        self.assertEqual(self.match.orders()["7"]["label"], "WEB 1080p H.264")

    def test_a_season_already_in_one_format_is_left_alone(self):
        self.sn.files[77] = web_file(1.0 * GB)
        out = self.api.season_match(9, 1)
        self.assertEqual(out["started"], 0)
        self.assertEqual(self.sn.taken, [])

    def test_an_episode_without_a_file_is_not_brought_back(self):
        self.sn.has_file.discard(7)
        self.assertEqual(self.api.season_match(9, 1)["started"], 0)
        self.assertEqual(self.sn.looked, [])

    def test_with_no_release_in_the_format_nothing_is_taken_and_it_says_so(self):
        self.sn.releases[7] = [release("small", "Show.S01E07.1080p.x265-ELiTE", HDTV)]
        self.api.season_match(9, 1)
        self.assertEqual(self.sn.taken, [])
        self.assertEqual(self.match.orders(), {})
        self.assertIn("no WEB 1080p H.264 release", self.store.events(5)[0]["message"])

    def test_an_episode_on_its_way_is_not_taken_twice(self):
        self.api.season_match(9, 1)
        self.assertEqual(self.api.season_match(9, 1)["started"], 0)
        self.assertEqual(len(self.sn.taken), 1)

    def test_refused_while_paused(self):
        self.api.set_paused(True)
        with self.assertRaisesRegex(ValueError, "paused"):
            self.api.season_match(9, 1)

    # -- the copy ----------------------------------------------------------------
    def test_without_the_match_the_copy_would_be_left_out(self):
        self.old_copy_in_the_library()
        h = self.grabbed()
        self.assertEqual(self.api.copy_states()[h][0], "skipped", "the library's copy scores higher")

    def test_a_match_copy_replaces_the_file_by_a_manual_import(self):
        self.old_copy_in_the_library()
        self.api.season_match(9, 1)
        h = self.grabbed()
        self.assertEqual(self.api.copy_states()[h][0], "waiting")
        self.api.auto_transfer()
        self.assertEqual(self.commands("DownloadedEpisodesScan"), [])
        (cmd,) = self.commands("ManualImport")
        self.assertEqual(cmd["importMode"], "copy", "the seedbox keeps seeding")
        (f,) = cmd["files"]
        self.assertTrue(f["path"].endswith("CAKES.mkv"), "the episode, not its sample")
        self.assertEqual((f["seriesId"], f["episodeIds"], f["quality"]), (9, [7], WEB))

    def test_done_once_the_library_file_is_the_new_one(self):
        self.api.season_match(9, 1)
        h = self.grabbed()
        self.api.auto_transfer()
        self.api.check_transfers()
        self.assertEqual(self.store.transfers()[0]["status"], "failed", "the old file is still there")
        self.store.add_transfer(h, "again", 99)
        self.sn.files[77] = web_file(GB, at=time.time())
        self.api.check_transfers()
        self.assertEqual(self.store.transfers()[0]["status"], "done")
        self.assertIn("in place of the old file", self.store.events(5)[0]["message"])

    def scout_pass(self, told):
        self.old_copy_in_the_library()
        scout = Scout(self.gate, self.sonarr, self.store, log=lambda m: None)
        if told:
            scout.matching = self.match.hashes
        self.api.season_match(9, 1)
        h = self.grabbed()
        by_ep, by_hash = scout.grabs()
        scout._home = scout._still_home(by_ep)
        scout._superseded(by_hash)
        return self.store.decision(h)["verdict"]

    def test_left_to_itself_the_scout_would_remove_the_copy_as_beaten(self):
        self.assertEqual(self.scout_pass(told=False), "superseded")

    def test_a_download_with_only_a_sample_of_the_episode_is_not_imported(self):
        self.api.season_match(9, 1)
        h = self.grabbed()
        folder = next(iter(self.sn.manual))
        self.sn.manual[folder] = self.sn.manual[folder][:1]
        self.api.auto_transfer()
        self.assertEqual(self.commands("ManualImport"), [])
        self.assertIn("did not find the episode", self.store.transfers()[0]["message"])

    def test_sonarr_refusing_to_read_the_download_is_a_failed_copy_not_a_silent_retry(self):
        self.api.season_match(9, 1)
        self.grabbed()
        folder = next(iter(self.sn.manual))
        self.sn.manual[folder] = {"message": "boom"}       # the fake answers 200 with a dict
        orig = self.match.sonarr.get

        def broken(path, **params):
            if path == "manualimport":
                from automatic.sonarr import SonarrError
                raise SonarrError("GET manualimport: 500 File doesn't exist")
            return orig(path, **params)
        self.match.sonarr.get = broken
        self.api.auto_transfer()
        self.assertEqual(self.store.transfers()[0]["status"], "failed")
        self.assertIn("could not read the download", self.store.transfers()[0]["message"])

    def test_a_download_of_another_show_is_not_imported_for_it(self):
        self.api.season_match(9, 1)
        self.grabbed()
        folder = next(iter(self.sn.manual))
        for it in self.sn.manual[folder]:
            it["series"] = {"id": 99}
        self.api.auto_transfer()
        self.assertEqual(self.commands("ManualImport"), [])

    def test_a_file_already_there_before_the_copy_is_not_taken_for_it(self):
        self.api.season_match(9, 1)
        self.grabbed()
        self.api.auto_transfer()
        self.sn.files[77] = web_file(GB, at=time.time() - 3600)
        self.api.check_transfers()
        self.assertEqual(self.store.transfers()[0]["status"], "failed")

    def test_the_scout_leaves_a_match_copy_alone(self):
        self.assertEqual(self.scout_pass(told=True), "approved")

    # -- the orders ----------------------------------------------------------------
    def test_an_order_is_done_once_the_episode_is_in_the_format(self):
        self.api.season_match(9, 1)
        self.sn.files[77] = web_file(GB, at=time.time())
        self.match.tick({}, {})
        self.assertEqual(self.match.orders(), {})
        self.assertEqual(self.store.events(1)[0]["kind"], "matched")

    def test_a_release_the_gate_refused_is_followed_by_the_next_best(self):
        self.api.season_match(9, 1)
        h = self.grabbed()
        self.store.decide(h, "rejected", "x", "contains an executable")
        self.sn.releases[7] = [release("ntb", "Show S01E07 1080p AMZN WEB-DL H 264-NTb", score=450)]
        self.match.tick(self.api._grabs_by_hash(), self.store.decisions())
        self.assertEqual(self.sn.taken[-1], {"guid": "ntb", "indexerId": 1})
        self.assertEqual(self.match.orders()["7"]["tries"], 2)

    def test_an_order_with_no_copy_in_three_days_is_given_up(self):
        self.api.season_match(9, 1)
        self.now[0] += 4 * 86400
        self.match.tick({}, {})
        self.assertEqual(self.match.orders(), {})
        self.assertIn("gave up", self.store.events(1)[0]["message"])

    # -- the show page --------------------------------------------------------------
    def test_a_show_lists_each_seasons_formats(self):
        self.sn.files[76]["customFormats"] = []
        out = self.api.show(9)
        season = out["seasons"][0]
        self.assertEqual(season["match"]["target"], "WEB 1080p H.264")
        self.assertEqual([g["episodes"] for g in season["match"]["groups"]], [[5, 6], [7]])
        ep7 = next(e for e in season["episodes"] if e["episode"] == 7)
        self.assertEqual((ep7["format"], ep7["formatState"], ep7["matching"]), ("HDTV 1080p H.265", "off", False))
