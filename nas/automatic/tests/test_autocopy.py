import datetime as dt
import time

from automatic.api import API
from fakes import info_hash, make_torrent
from test_gate import CLEAN, GB, Harness

CLIENT = "Seedbox qBittorrent (via Magnet)"


def iso(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).isoformat().replace("+00:00", "Z")


class AutoCopy(Harness):
    def setUp(self):
        super().setUp()
        self.api = API(self.gate, self.sonarr, self.store, "tok", ("/downloads/", "/seedbox/downloads/"),
                       log=lambda m: None)

    def finished(self, raw, ep=5, score=3500):
        """A torrent Sonarr grabbed for `ep`, passed by the gate and finished on the seedbox."""
        self.login()
        self.add([raw])
        h = info_hash(raw)
        self.gate.poll()
        self.qb.torrents[h].update(progress=1.0, state="stoppedUP", amount_left=0)
        self.sn.history.append({"episodeId": ep, "seriesId": 9, "date": iso(time.time()), "customFormatScore": score,
                                "downloadId": h.upper(), "sourceTitle": "x", "customFormats": [],
                                "data": {"downloadClientName": CLIENT}})
        self.api._grabs = (0.0, {})
        self.gate.poll()
        return h

    def scans(self):
        return [c for c in self.sn.commands if c.get("name") == "DownloadedEpisodesScan"]

    def test_a_finished_episode_is_copied_by_itself_once(self):
        h = self.finished(CLEAN)
        self.assertEqual(self.api.copy_states()[h][0], "waiting")
        self.api.auto_transfer()
        self.assertEqual(len(self.scans()), 1)
        self.assertEqual(self.scans()[0]["downloadClientId"], h.upper())
        self.assertEqual(self.scans()[0]["importMode"], "Copy", "the seedbox keeps its copy")
        self.api.auto_transfer()
        self.assertEqual(len(self.scans()), 1, "already on its way")

    def test_on_the_nas_only_when_sonarr_imported_it(self):
        h = self.finished(CLEAN)
        self.api.auto_transfer()
        self.sn.imports[h.upper()] = [{"date": iso(time.time()), "data": {"importedPath": "/tv/Show/S01E05.mkv"}}]
        self.api.check_transfers()
        self.assertEqual(self.store.transfers()[0]["status"], "done")
        row = self.api.seedbox()["torrents"][0]
        self.assertTrue(row["onNAS"])
        self.assertEqual(row["copyStatus"], "done")

    def test_left_out_because_the_library_copy_is_as_good_is_kept_and_not_retried(self):
        h = self.finished(CLEAN, score=1525)
        self.sn.has_file.add(5)
        self.sn.episodes[5] = {"episodeFileId": 77}
        self.sn.files[77] = {"customFormatScore": 1475}    # Sonarr scores a file a little apart from its release
        self.api.auto_transfer()
        self.api.check_transfers()          # completed, but no import recorded
        self.assertEqual(self.store.transfers()[0]["status"], "skipped")
        row = self.api.seedbox()["torrents"][0]
        self.assertFalse(row["onNAS"])
        self.assertEqual(row["copyStatus"], "skipped")
        self.api.AUTO_RETRY_DELAYS = (0,) * 8
        self.api.auto_transfer()
        self.assertEqual(len(self.scans()), 1)

    def test_left_out_when_the_library_has_nothing_is_a_failure_and_tried_again(self):
        h = self.finished(CLEAN)
        self.api.auto_transfer()
        self.api.check_transfers()          # completed, nothing imported, no file in the library
        self.assertEqual(self.store.transfers()[0]["status"], "failed")
        self.assertEqual(self.api.copy_states()[h][0], "waiting")
        self.api.AUTO_RETRY_DELAYS = (0,) * 8
        self.api.auto_transfer()
        self.assertEqual(len(self.scans()), 2)

    def test_left_out_when_the_library_copy_is_worse_is_a_failure(self):
        h = self.finished(CLEAN, score=13500)
        self.sn.has_file.add(5)
        self.sn.episodes[5] = {"episodeFileId": 77}
        self.sn.files[77] = {"customFormatScore": 500}
        self.api.auto_transfer()
        self.api.check_transfers()
        self.assertEqual(self.store.transfers()[0]["status"], "failed", "the better copy must still arrive")

    def test_a_tba_title_says_why(self):
        h = self.finished(CLEAN)
        self.sn.episodes[5] = {"title": "TBA"}
        self.api.auto_transfer()
        self.api.check_transfers()
        self.assertIn("TBA", self.store.transfers()[0]["message"])

    def test_an_old_import_does_not_count(self):
        h = self.finished(CLEAN)
        self.sn.imports[h.upper()] = [{"date": iso(time.time() - 3600), "data": {"importedPath": "/tv/old.mkv"}}]
        self.api.auto_transfer()
        self.api.check_transfers()
        self.assertNotEqual(self.store.transfers()[0]["status"], "done")

    def test_only_what_sonarr_grabbed_and_the_rest_keeps_the_button(self):
        self.login()
        self.add([CLEAN])
        h = info_hash(CLEAN)
        self.gate.poll()
        self.qb.torrents[h].update(progress=1.0, state="stoppedUP", amount_left=0)
        self.gate.poll()
        self.api.auto_transfer()
        self.assertEqual(self.scans(), [])
        self.assertEqual(self.api.seedbox()["torrents"][0]["copyStatus"], None, "never 'Copying soon' forever")

    def test_not_before_it_has_finished(self):
        h = self.finished(CLEAN)
        self.qb.torrents[h].update(progress=0.5, state="downloading", amount_left=GB)
        self.gate.poll()
        self.api.auto_transfer()
        self.assertEqual(self.scans(), [])
        self.assertNotIn(h, self.api.copy_states())

    def test_the_best_copy_goes_and_the_one_it_beats_does_not(self):
        worse = self.finished(make_torrent("Show.S01E05.1080p", [("Show.S01E05.1080p.mkv", 2 * GB)]), score=500)
        better = self.finished(CLEAN, score=13500)
        self.api.auto_transfer()
        self.assertEqual([c["downloadClientId"] for c in self.scans()], [better.upper()])
        self.assertEqual(self.api.copy_states()[worse][0], "skipped", "the scout retires it; it is not 'waiting'")

    def test_of_two_copies_as_good_only_one_goes(self):
        a = self.finished(make_torrent("Show.S01E05.2160p.RAWR", [("Show.S01E05.2160p.RAWR.mkv", 5 * GB)]), score=13825)
        b = self.finished(make_torrent("Show.S01E05.2160p.FLUX", [("Show.S01E05.2160p.FLUX.mkv", 5 * GB)]), score=13825)
        self.api.auto_transfer()
        self.assertEqual(len(self.scans()), 1)
        first = self.scans()[0]["downloadClientId"].lower()
        other = b if first == a else a
        self.assertEqual(self.api.copy_states()[other][0], "skipped")
        self.sn.imports[first.upper()] = [{"date": iso(time.time()), "data": {"importedPath": "/tv/x.mkv"}}]
        self.api.check_transfers()
        self.api.auto_transfer()
        self.assertEqual(len(self.scans()), 1, "the second adds nothing")

    def test_one_import_per_episode_at_a_time(self):
        worse = self.finished(make_torrent("Show.S01E05.1080p", [("Show.S01E05.1080p.mkv", 2 * GB)]), score=500)
        self.api.auto_transfer()
        self.assertEqual(len(self.scans()), 1)
        better = self.finished(CLEAN, score=13500)
        self.api.auto_transfer()
        self.assertEqual(len(self.scans()), 1, "not while the 1080p is still being imported")
        self.sn.imports[worse.upper()] = [{"date": iso(time.time()), "data": {"importedPath": "/tv/x.mkv"}}]
        self.api.check_transfers()
        self.api.auto_transfer()
        self.assertEqual([c["downloadClientId"].lower() for c in self.scans()], [worse, better])

    def test_a_failure_is_retried_then_left_to_the_button(self):
        h = self.finished(CLEAN)
        self.qb.torrents[h]["content_path"] = "/elsewhere/Show.S01E05.mkv"   # cannot be mapped for Sonarr
        self.gate.poll()
        self.api.auto_transfer()
        self.assertEqual(self.store.transfers()[0]["status"], "failed")
        self.assertEqual(self.api.copy_states()[h][0], "waiting", "it will try again")
        self.api.auto_transfer()
        self.assertEqual(len(self.store.transfers()), 1, "not again at once")
        self.api.AUTO_RETRY_DELAYS = (0,) * 8
        for _ in range(15):
            self.api.auto_transfer()
        self.assertEqual(len(self.store.transfers()), 9, "the first try and eight more")
        self.assertEqual(self.api.copy_states()[h][0], "failed", "now it is the button's")

    def test_retries_are_spread_over_about_two_days(self):
        self.assertGreaterEqual(sum(API.AUTO_RETRY_DELAYS), 48 * 3600, "a TBA title is refused for two days")

    def test_switched_off(self):
        api = API(self.gate, self.sonarr, self.store, "tok", ("/downloads/", "/seedbox/downloads/"),
                  log=lambda m: None, auto_copy=False)
        h = self.finished(CLEAN)
        api.auto_transfer()
        self.assertEqual(self.scans(), [])
        self.assertEqual(api.copy_states()[h][0], None)
        self.assertFalse(api.seedbox()["autoCopy"])

    def test_sonarr_frozen_records_nothing(self):
        h = self.finished(CLEAN)
        self.sn.alive = False
        self.api.auto_transfer()
        self.assertEqual(self.store.transfers(), [])
        self.sn.alive = True
        self.api.auto_transfer()
        self.assertEqual(len(self.scans()), 1)

    def test_rows_are_named_from_the_grab_once_sonarr_drops_them_from_its_queue(self):
        h = self.finished(CLEAN)
        self.sn.episodes[5] = {"seriesId": 9, "seasonNumber": 1, "episodeNumber": 5, "title": "Firewall"}
        row = self.api.seedbox(titles={9: "Show"})["torrents"][0]
        self.assertEqual((row["series"], row["season"], row["episode"], row["episodeTitle"]),
                         ("Show", 1, 5, "Firewall"))

    def test_a_pack_is_named_by_its_season(self):
        self.login()
        pack = make_torrent("Show.S01", [(f"Show.S01E0{i}.mkv", 3 * GB) for i in (1, 2)])
        self.add([pack])
        h = info_hash(pack)
        for ep in (1, 2):
            self.sn.episodes[ep] = {"seriesId": 9, "seasonNumber": 1, "episodeNumber": ep, "title": f"E{ep}"}
            self.sn.history.append({"episodeId": ep, "date": iso(time.time()), "customFormatScore": 0,
                                    "downloadId": h.upper(), "data": {"downloadClientName": CLIENT}})
        self.gate.poll()
        row = self.api.seedbox(titles={9: "Show"})["torrents"][0]
        self.assertEqual((row["series"], row["season"], row["episode"]), ("Show", 1, None))
