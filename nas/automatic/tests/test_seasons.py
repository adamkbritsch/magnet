import os
import subprocess
import tempfile
import unittest

from automatic.seasons import LibraryMap, Seasons, season_of_dir, standard_name
from automatic.sonarr import SonarrError
from automatic.store import Store

PLEX_ROOT = "/media/TV-Shows"


class StubSonarr:
    def __init__(self, show):
        self.series = {"id": 7, "path": show, "title": "Show", "tvdbId": 99}
        self.episodes = {}
        self.files = []
        self.after_rescan = None
        self.calls = []
        self.statuses = []          # what command/{id} answers, one per poll; then "completed"
        self.fail_post = 0          # POSTs to /command that fail before one gets through

    def get(self, path, **params):
        if path == "series/7":
            return self.series
        if path == "episode":
            return [self.episodes[i] for i in params["episodeIds"] if i in self.episodes]
        if path == "episodefile":
            return [dict(f) for f in self.files]
        if path.startswith("command/"):
            status = self.statuses.pop(0) if self.statuses else "completed"
            if status == "completed" and self.after_rescan:
                self.files, self.after_rescan = self.after_rescan(), None
            return {"id": 1, "status": status}
        raise AssertionError(path)

    def call(self, method, path, params=None, body=None, timeout=None):
        if path == "command" and self.fail_post:
            self.fail_post -= 1
            raise SonarrError("Sonarr is not answering")
        self.calls.append((method, path, body))
        if path == "command":
            return {"id": 1, "status": "queued"}
        return body

    def rescans(self):
        return [b for m, p, b in self.calls if p == "command" and b.get("name") == "RescanSeries"]

    def puts(self):
        return [b for m, p, b in self.calls if m == "PUT"]


class StubPlex:
    def __init__(self):
        self.eps = []
        self.refreshed, self.scrobbled, self.progressed = [], [], []

    def shows(self, tvdb):
        return [("4", "100")] if tvdb == 99 else []

    def episodes(self, key):
        return [dict(e) for e in self.eps]

    def refresh(self, section, path):
        self.refreshed.append((section, path))

    def scrobble(self, key):
        self.scrobbled.append(key)

    def progress(self, key, ms):
        self.progressed.append((key, ms))


class SeasonFolders(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.lib = os.path.join(self.tmp, "tv1")
        self.show = os.path.join(self.lib, "Show (2020)")
        os.makedirs(self.show)
        self.store = Store(os.path.join(self.tmp, "c.db"))
        self.sonarr = StubSonarr(self.show)
        self.plex = StubPlex()
        self.now = [1_800_000_000.0]
        # host == here, so the undo script can be run against the temp library
        self.library = LibraryMap(f"{self.lib}>{self.lib}>{PLEX_ROOT}")
        self.seasons = Seasons(self.sonarr, self.plex, self.library, self.store, log=lambda m: None,
                               data_dir=self.tmp, clock=lambda: self.now[0])
        self.key = 0

    def file(self, rel, season=None, index=None, watched=False, offset=0, listed=True, data=b"x"):
        p = os.path.join(self.show, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
        if listed and season is not None:
            self.key += 1
            self.plex.eps.append({"key": str(self.key), "season": season, "index": index or self.key,
                                  "files": [PLEX_ROOT + "/Show (2020)/" + rel], "watched": watched, "offset": offset})
        return p

    def imported(self, rel, season, episode=1, eid=501):
        self.sonarr.episodes[eid] = {"id": eid, "seasonNumber": season, "episodeNumber": episode}
        return self.file(rel, listed=False)

    def place(self, path, eid=501):
        return self.seasons.place(7, path, [eid])

    def ls(self, rel=""):
        return sorted(os.listdir(os.path.join(self.show, rel)))

    # -- reading folder names the way Plex does --------------------------------------
    def test_folder_names(self):
        for name, n in (("Season 1", 1), ("Season 01", 1), ("season 12", 12), ("Specials", 0), ("Season1", 1),
                        ("S01", None), ("Show.S01.1080p", None), ("Season 1 1080p", None), ("Featurettes", None)):
            self.assertEqual(season_of_dir(name), n, name)
        self.assertEqual((standard_name(3, False), standard_name(3, True), standard_name(0, True)),
                         ("Season 3", "Season 03", "Specials"))

    # -- a new episode -------------------------------------------------------------
    def test_a_new_episode_goes_into_the_folder_plex_files_its_season_under(self):
        self.file("Season 1/Show - S01E01.mkv", 1, 1)
        new = self.imported("Season 01/Show - S01E02 - Two WEBDL-1080p.mkv", 1, 2)
        here = self.place(new)
        self.assertEqual(here, os.path.join(self.show, "Season 1", "Show - S01E02 - Two WEBDL-1080p.mkv"))
        self.assertEqual(self.ls(), ["Season 1"], "Sonarr's 'Season 01' is gone once empty")
        self.assertEqual(len(self.sonarr.rescans()), 1, "Sonarr is told where the file is now")
        self.assertEqual(self.plex.refreshed, [("4", PLEX_ROOT + "/Show (2020)")])

    def test_a_new_season_is_named_like_the_shows_others(self):
        self.file("Season 1/a.mkv", 1)
        self.file("Season 2/b.mkv", 2)
        new = self.imported("Season 03/Show - S03E01.mkv", 3)
        self.assertEqual(self.place(new), os.path.join(self.show, "Season 3", "Show - S03E01.mkv"))

    def test_a_show_that_pads_keeps_padding(self):
        self.file("Season 01/a.mkv", 1)
        new = self.imported("Season 02/Show - S02E01.mkv", 2)
        self.assertEqual(self.place(new), new, "already where it belongs")
        self.assertEqual(self.sonarr.rescans(), [], "nothing moved, nothing to tell")

    def test_a_folder_with_an_odd_name_plex_files_the_season_under_is_renamed(self):
        old = [self.file(f"S03/Show - S03E0{i}.mkv", 3, i) for i in (1, 2)]
        self.file("S03/Show - S03E01.en.srt", listed=False)
        self.file("S04/Show - S04E01.mkv", 4, 1)
        new = self.imported("Season 03/Show - S03E03.mkv", 3, 3)
        self.place(new)
        self.assertEqual(self.ls(), ["Season 3", "Season 4"], "S03 and S04 renamed; nothing left behind")
        self.assertEqual(self.ls("Season 3"), ["Show - S03E01.en.srt", "Show - S03E01.mkv",
                                               "Show - S03E02.mkv", "Show - S03E03.mkv"])
        events = [e["message"] for e in self.store.events(20)]
        self.assertTrue(any("S03 -> Season 3 (2 episode files)" in m for m in events), events)
        self.assertFalse(any(os.path.exists(p) for p in old))

    def test_loose_episodes_and_release_folders_move_and_leftovers_stay(self):
        self.file("Show.S01E01.mkv", 1, 1)
        self.file("Show.S02.1080p.WEB-DL-GRP/Show.S02E01.mkv", 2, 1)
        self.file("Show.S02.1080p.WEB-DL-GRP/GRP.nfo", listed=False)
        new = self.imported("Season 02/Show - S02E02.mkv", 2, 2)
        self.place(new)
        self.assertEqual(self.ls(), ["Season 1", "Season 2", "Show.S02.1080p.WEB-DL-GRP"])
        self.assertEqual(self.ls("Show.S02.1080p.WEB-DL-GRP"), ["GRP.nfo"], "not an episode: left where it was")
        self.assertEqual(self.ls("Season 2"), ["Show - S02E02.mkv", "Show.S02E01.mkv"])

    def test_extras_and_a_season_folder_with_another_number_are_left_alone(self):
        self.file("Featurettes/Making Of.mkv", 0)
        self.file("Season 4/Show - S03E09.mkv", 3, 9)       # Plex and the folder disagree
        new = self.imported("Season 03/Show - S03E10.mkv", 3, 10)
        self.place(new)
        self.assertTrue(os.path.exists(os.path.join(self.show, "Featurettes", "Making Of.mkv")))
        self.assertTrue(os.path.exists(os.path.join(self.show, "Season 4", "Show - S03E09.mkv")))
        self.assertEqual(self.ls("Season 3"), ["Show - S03E10.mkv"])

    def test_a_name_already_taken_is_not_overwritten(self):
        self.file("S01/Show - S01E01.mkv", 1, 1, data=b"old")
        self.file("Season 1/Show - S01E01.mkv", 1, 1, data=b"kept")
        new = self.imported("Season 01/Show - S01E02.mkv", 1, 2)
        self.place(new)
        with open(os.path.join(self.show, "Season 1", "Show - S01E01.mkv"), "rb") as f:
            self.assertEqual(f.read(), b"kept")
        self.assertTrue(os.path.exists(os.path.join(self.show, "S01", "Show - S01E01.mkv")))

    def test_a_show_on_the_skip_list_is_not_touched(self):
        self.seasons.skip = {"Show (2020)"}
        self.file("S01/a.mkv", 1)
        new = self.imported("Season 01/b.mkv", 1)
        self.assertEqual(self.place(new), new)
        self.assertEqual(self.ls(), ["S01", "Season 01"])

    def test_without_plex_it_goes_by_folder_names(self):
        self.seasons.plex = None
        self.file("Season 1/a.mkv", 1)
        self.file("S02/b.mkv", 2)
        new = self.imported("Season 01/c.mkv", 1)
        self.assertEqual(self.place(new), os.path.join(self.show, "Season 1", "c.mkv"))
        self.assertIn("S02", self.ls(), "which season S02 holds is Plex's to say")

    # -- undo, Sonarr and Plex -----------------------------------------------------------
    def test_every_move_can_be_undone(self):
        self.file("S01/Show - S01E01.mkv", 1, 1)
        self.file("S01/Show - S01E01.srt", listed=False)
        new = self.imported("Season 01/Show - S01E02.mkv", 1, 2)
        self.place(new)
        scripts = [f for f in os.listdir(self.tmp) if f.startswith("season-undo-")]
        self.assertEqual(len(scripts), 1)
        self.assertEqual(len(self.store.get("seasons.batches")), 1)
        subprocess.run(["sh", os.path.join(self.tmp, scripts[0])], check=True)
        self.assertTrue(os.path.exists(os.path.join(self.show, "S01", "Show - S01E01.mkv")))
        self.assertTrue(os.path.exists(os.path.join(self.show, "S01", "Show - S01E01.srt")))
        self.assertTrue(os.path.exists(new))

    def test_sonarr_keeps_the_release_name_each_file_was_scored_by(self):
        self.file("S01/Show - S01E01.mkv", 1, 1)
        new = self.imported("Season 01/Show - S01E02.mkv", 1, 2)
        self.sonarr.files = [
            {"id": 1, "relativePath": "S01/Show - S01E01.mkv", "sceneName": "Show.S01E01.2160p.DV-GRP",
             "releaseGroup": "GRP"},
            {"id": 2, "relativePath": "Season 01/Show - S01E02.mkv", "sceneName": "Show.S01E02.2160p.DV-GRP",
             "releaseGroup": "GRP"}]
        self.sonarr.after_rescan = lambda: [
            {"id": 3, "relativePath": "Season 1/Show - S01E01.mkv", "sceneName": None, "releaseGroup": None},
            {"id": 4, "relativePath": "Season 1/Show - S01E02.mkv", "sceneName": None, "releaseGroup": None}]
        self.place(new)
        self.assertEqual(sorted((b["id"], b["sceneName"], b["releaseGroup"]) for b in self.sonarr.puts()),
                         [(3, "Show.S01E01.2160p.DV-GRP", "GRP"), (4, "Show.S01E02.2160p.DV-GRP", "GRP")])

    def test_a_watched_mark_or_resume_point_plex_drops_is_put_back(self):
        self.file("S01/Show - S01E01.mkv", 1, 1, watched=True)
        self.file("S01/Show - S01E02.mkv", 1, 2, offset=600000)
        self.file("S01/Show - S01E03.mkv", 1, 3)
        new = self.imported("Season 01/Show - S01E04.mkv", 1, 4)
        self.place(new)
        self.now[0] += 3 * 60 + 1
        self.seasons.tick()
        self.assertEqual(self.plex.scrobbled, [], "not before Plex has found the files where they are now")
        for e in self.plex.eps:                  # Plex rescans and forgets, as it can when files move
            e.update(watched=False, offset=0, files=[f.replace("/S01/", "/Season 1/") for f in e["files"]])
        self.now[0] += 15 * 60
        self.seasons.tick()
        self.assertEqual(self.plex.scrobbled, ["1"])
        self.assertEqual(self.plex.progressed, [("2", 600000)])
        self.plex.eps[0]["watched"] = False      # you mark it unwatched afterwards: yours to keep
        self.now[0] += 60 * 60
        self.seasons.tick()
        self.assertEqual(self.plex.scrobbled, ["1"], "put back once, never again")

    # -- the queue -----------------------------------------------------------------------
    def test_queued_then_placed_and_the_show_is_busy_meanwhile(self):
        self.file("Season 1/a.mkv", 1)
        new = self.imported("Season 01/b.mkv", 1)
        self.seasons.queue(7, new, [501])
        self.seasons.queue(7, new, [501])
        self.assertEqual(self.seasons.busy(), {7})
        self.seasons.tick()
        self.assertEqual(self.seasons.busy(), set())
        self.assertTrue(os.path.exists(os.path.join(self.show, "Season 1", "b.mkv")))

    def test_a_failure_is_tried_again_then_dropped(self):
        new = self.imported("Season 01/b.mkv", 1)
        self.seasons.queue(7, new, [501])
        self.sonarr.get = lambda *a, **k: (_ for _ in ()).throw(OSError("Sonarr went away"))
        for _ in range(4):
            self.seasons.tick()
        self.assertEqual(self.seasons.busy(), {7})
        self.seasons.tick()
        self.assertEqual(self.seasons.busy(), set(), "five tries, then the show is not held up for good")


class AfterReview(SeasonFolders):
    """What the review of 2026-10-28 found, each kept from coming back."""

    def test_a_failure_after_the_moves_is_finished_on_the_next_try(self):
        self.file("S01/Show - S01E01.mkv", 1, 1, watched=True)
        new = self.imported("Season 01/Show - S01E02.mkv", 1, 2)
        self.sonarr.files = [{"id": 1, "relativePath": "S01/Show - S01E01.mkv", "sceneName": "Show.S01E01-GRP"}]
        self.sonarr.after_rescan = lambda: [{"id": 3, "relativePath": "Season 1/Show - S01E01.mkv", "sceneName": None}]
        self.sonarr.fail_post = 1                  # Sonarr freezes for a Plex stream, after the moves
        self.seasons.queue(7, new, [501])
        self.seasons.tick()
        self.assertEqual(self.ls(), ["Season 1"], "the files moved")
        self.assertEqual(self.seasons.busy(), {7}, "and the show is held until Sonarr knows")
        self.assertEqual(len(self.store.get("seasons.rewatch")), 1, "Plex was told without waiting on Sonarr")
        self.seasons.tick()
        self.assertEqual(len(self.sonarr.rescans()), 1)
        self.seasons.tick()
        self.assertEqual(self.seasons.busy(), set())
        self.assertEqual([(b["id"], b["sceneName"]) for b in self.sonarr.puts()], [(3, "Show.S01E01-GRP")])

    def test_a_long_rescan_is_waited_for_across_ticks(self):
        self.file("S01/Show - S01E01.mkv", 1, 1)
        new = self.imported("Season 01/Show - S01E02.mkv", 1, 2)
        self.sonarr.files = [{"id": 1, "relativePath": "S01/Show - S01E01.mkv", "sceneName": "Show.S01E01-GRP"}]
        self.sonarr.after_rescan = lambda: [{"id": 3, "relativePath": "Season 1/Show - S01E01.mkv", "sceneName": None}]
        self.sonarr.statuses = ["queued", "started", "started"]
        self.seasons.queue(7, new, [501])
        for _ in range(3):
            self.seasons.tick()
            self.assertEqual(self.seasons.busy(), {7})
            self.assertEqual(self.sonarr.puts(), [])
        self.seasons.tick()
        self.assertEqual(self.seasons.busy(), set())
        self.assertEqual(len(self.sonarr.puts()), 1)

    def test_a_rescan_that_never_finishes_is_let_go(self):
        new = self.imported("Season 01/b.mkv", 1)
        self.file("Season 1/a.mkv", 1)
        self.sonarr.statuses = ["started"] * 100
        self.seasons.queue(7, new, [501])
        self.seasons.tick()
        self.now[0] += self.seasons.RESCAN_GIVE_UP + 1
        self.seasons.tick()
        self.assertEqual(self.seasons.busy(), set())

    def test_a_newer_import_keeps_its_own_release_name(self):
        self.file("S01/Show - S01E01.mkv", 1, 1)
        new = self.imported("Season 01/Show - S01E02.mkv", 1, 2)
        self.sonarr.files = [{"id": 1, "relativePath": "S01/Show - S01E01.mkv", "sceneName": "Old-GRP"}]
        self.sonarr.after_rescan = lambda: [{"id": 9, "relativePath": "Season 1/Show - S01E01.mkv",
                                             "sceneName": "Upgrade-GRP"}]
        self.place(new)
        self.assertEqual(self.sonarr.puts(), [])

    def test_a_subtitle_never_moves_without_its_episode(self):
        self.file("S01/Show - S01E01.mkv", 1, 1, data=b"A")
        self.file("S01/Show - S01E01.en.srt", listed=False)
        self.file("Season 1/Show - S01E01.mkv", 1, 1, data=b"B")
        new = self.imported("Season 01/Show - S01E02.mkv", 1, 2)
        self.place(new)
        self.assertEqual(self.ls("S01"), ["Show - S01E01.en.srt", "Show - S01E01.mkv"], "both stay together")

    def test_a_subtitle_goes_with_the_episode_whose_name_it_carries(self):
        self.file("S01/Show.S01E01.720p.mkv", 1, 1)
        self.file("S01/Show.S01E01.720p.proper.mkv", 1, 1, listed=False)
        self.file("S01/Show.S01E01.720p.proper.en.srt", listed=False)
        self.file("S01/Show.S01E01.720p.en.srt", listed=False)
        new = self.imported("Season 01/Show - S01E02.mkv", 1, 2)
        self.place(new)
        self.assertEqual(self.ls("S01"), ["Show.S01E01.720p.proper.en.srt", "Show.S01E01.720p.proper.mkv"])
        self.assertIn("Show.S01E01.720p.en.srt", self.ls("Season 1"))

    def test_plex_optimized_versions_stay_put(self):
        self.file("Season 1/Show - S01E01.mkv", 1, 1)
        self.file("Season 1/Plex Versions/Optimized for TV/Show - S01E01.mp4", 1, 1)
        new = self.imported("Season 01/Show - S01E02.mkv", 1, 2)
        self.place(new)
        self.assertEqual(self.ls("Season 1/Plex Versions/Optimized for TV"), ["Show - S01E01.mp4"])

    def test_a_season_pack_follows_the_show_and_does_not_pull_its_folder_over(self):
        self.file("Season 1/a.mkv", 1)
        self.file("Season 2/b.mkv", 2)
        self.file("Season 3/Show - S03E00.mkv", 3, 0)
        pack = [self.imported(f"Season 03/Show - S03E0{i}.mkv", 3, i, eid=600 + i) for i in (1, 2, 3)]
        for i, p in enumerate(pack, 1):            # Plex has already listed them
            self.plex.eps.append({"key": f"p{i}", "season": 3, "index": i, "watched": False, "offset": 0,
                                  "files": [PLEX_ROOT + "/Show (2020)/Season 03/" + os.path.basename(p)]})
            self.seasons.queue(7, p, [600 + i])
        for _ in range(4):
            self.seasons.tick()
        self.assertEqual(self.ls(), ["Season 1", "Season 2", "Season 3"])
        self.assertEqual(len(self.ls("Season 3")), 4)

    def test_release_folders_named_like_extras_are_still_seasons(self):
        self.file("Interview.with.the.Vampire.S02.1080p.WEB-DL/Ep.S02E01.mkv", 2, 1)
        self.file("Book 1b - Extras/Animatic.mp4", 1, 15)
        self.file("Featurettes/Making Of.mkv", 0)
        new = self.imported("Season 02/Ep.S02E02.mkv", 2, 2)
        self.place(new)
        self.assertEqual(self.ls(), ["Book 1b - Extras", "Featurettes", "Season 2"])

    def test_moves_already_made_before_a_restart_are_not_made_twice(self):
        self.file("S01/Show - S01E01.mkv", 1, 1)
        new = self.imported("Season 01/Show - S01E02.mkv", 1, 2)
        job = {"series": 7, "path": new, "episodes": [501], "at": self.now[0]}
        self.assertTrue(self.seasons._plan_job(job))
        src, dst, _ = job["moves"][0]
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.rename(src, dst)                          # the container stopped right after this one
        self.seasons._move(job)
        self.assertIn([src, dst], job["done"])
        self.assertEqual(sorted(self.ls("Season 1")), ["Show - S01E01.mkv", "Show - S01E02.mkv"])


class Paths(unittest.TestCase):
    def test_the_three_names_of_a_path(self):
        m = LibraryMap("/srv/TV>/tv1>/media/TV|/mnt/disk3/TV>/tv3>/media/vol3/TV")
        self.assertEqual(m.from_plex("/media/vol3/TV/Show/Season 1/a.mkv"), "/tv3/Show/Season 1/a.mkv")
        self.assertEqual(m.to_plex("/tv1/Show"), "/media/TV/Show")
        self.assertEqual(m.to_host("/tv3/Show/x"), "/mnt/disk3/TV/Show/x")
        self.assertIsNone(m.from_plex("/media/vol3/3D-TV/Show/a.mkv"), "a folder Sonarr does not have")
        self.assertFalse(m.covers("/tv10/Show"))
        self.assertEqual(LibraryMap("").roots, [])
