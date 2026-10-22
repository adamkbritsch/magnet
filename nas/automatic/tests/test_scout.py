import datetime as dt

from automatic.scout import Scout
from fakes import FakeQBit, info_hash, make_torrent
from test_gate import GB, Harness

HOUR = 3600
DAY = 86400
T0 = 1_800_000_000.0


def iso(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).isoformat().replace("+00:00", "Z")


class ScoutTests(Harness):
    def setUp(self):
        super().setUp()
        self.now = [T0]
        self.scout = Scout(self.gate, self.sonarr, self.store, log=lambda m: None, clock=lambda: self.now[0])

    def tick(self, seconds):
        self.now[0] += seconds

    def grab(self, ep, at, score, h=None, title="x", verdict="approved"):
        if h is None:
            h = f"{ep:04d}{int(at) % 100000:06d}".ljust(40, "0")
        if verdict:
            self.store.decide(h, verdict, title)
        self.sn.history.append({"episodeId": ep, "date": iso(at), "customFormatScore": score,
                                "downloadId": h.upper(), "sourceTitle": title, "customFormats": [],
                                "data": {"downloadClient": "Seedbox qBittorrent (via Magnet)",
                                         "downloadClientName": "Seedbox qBittorrent (via Magnet)"}})

    # -- a copy as soon as possible ------------------------------------------------
    def test_aired_episode_is_searched_at_once_then_at_a_measured_pace(self):
        self.sn.calendar = [{"id": 11, "airDateUtc": iso(T0 - HOUR), "monitored": True, "hasFile": False}]
        self.scout.run_once()
        self.assertEqual(self.sn.searches(), [[11]])
        self.tick(10 * 60)
        self.scout.run_once()
        self.assertEqual(len(self.sn.searches()), 1, "not again within 20 minutes")
        self.tick(11 * 60)
        self.scout.run_once()
        self.assertEqual(len(self.sn.searches()), 2)
        self.tick(6 * HOUR)                      # aired 7 hours ago now: every two hours
        self.scout.run_once()
        self.tick(HOUR)
        self.scout.run_once()
        self.assertEqual(len(self.sn.searches()), 3)

    def test_a_grabbed_or_unaired_or_unfollowed_episode_is_not_chased(self):
        self.sn.calendar = [{"id": 1, "airDateUtc": iso(T0 + HOUR), "monitored": True, "hasFile": False},
                            {"id": 2, "airDateUtc": iso(T0 - HOUR), "monitored": False, "hasFile": False},
                            {"id": 3, "airDateUtc": iso(T0 - HOUR), "monitored": True, "hasFile": True},
                            {"id": 4, "airDateUtc": iso(T0 - HOUR), "monitored": True, "hasFile": False}]
        self.grab(4, T0 - 30 * 60, 1500)
        self.scout.run_once()
        self.assertNotIn([1], self.sn.searches())
        self.assertFalse(any(e in (1, 2, 3) for s in self.sn.searches() for e in s))

    # -- a week of looking for better ------------------------------------------------
    def test_upgrade_window(self):
        self.grab(5, T0, 3500, title="Show.S01E05.2160p.WEB-DL.HDR")
        self.tick(HOUR)
        self.scout.run_once()
        self.assertEqual(self.sn.searches(), [], "the first copy is minutes old")
        self.tick(6 * HOUR)
        self.scout.run_once()
        self.assertEqual(self.sn.searches(), [[5]])
        self.tick(HOUR)
        self.scout.run_once()
        self.assertEqual(len(self.sn.searches()), 1, "every six hours, not every pass")
        self.tick(7 * DAY)
        self.scout.run_once()
        self.assertEqual(self.sn.monitor, [], "the week is over, but no copy has finished: keep at it")
        self.sn.has_file.add(5)
        self.tick(7 * HOUR)
        self.scout.run_once()
        self.assertEqual(self.sn.monitor, [{"episodeIds": [5], "monitored": False}], "now it has one")
        n = len(self.sn.searches())
        self.tick(7 * HOUR)
        self.scout.run_once()
        self.assertEqual(len(self.sn.searches()), n, "nothing more after it settles")
        self.assertEqual(self.scout.status()["settled"], 1)

    # -- superseded copies -------------------------------------------------------------
    def _two_copies(self, better_done=True):
        self.login()
        a = make_torrent("Show.S01E05.2160p.WEB-DL.HDR", [("Show.S01E05.2160p.WEB-DL.HDR.mkv", 5 * GB)])
        b = make_torrent("Show.S01E05.2160p.WEB-DL.DV.HDR", [("Show.S01E05.2160p.WEB-DL.DV.HDR.mkv", 6 * GB)])
        self.add([a, b])
        ha, hb = info_hash(a), info_hash(b)
        self.qb.torrents[ha].update(progress=1.0, state="stalledUP")
        self.qb.torrents[hb].update(progress=1.0 if better_done else 0.4,
                                    state="stalledUP" if better_done else "downloading")
        self.grab(5, T0 - DAY, 3500, ha)
        self.grab(5, T0 - HOUR, 13500, hb)
        self.gate.poll()
        return ha, hb

    def test_a_finished_better_copy_retires_the_worse_one(self):
        ha, hb = self._two_copies()
        self.scout.run_once()
        self.assertNotIn(ha, self.qb.torrents)
        self.assertIn(hb, self.qb.torrents)
        self.assertEqual(self.store.decision(ha)["verdict"], "superseded")

    def test_not_before_the_better_copy_has_finished(self):
        ha, hb = self._two_copies(better_done=False)
        self.scout.run_once()
        self.assertIn(ha, self.qb.torrents)

    def test_not_while_it_is_being_copied_to_the_nas(self):
        ha, hb = self._two_copies()
        self.store.add_transfer(ha, "x", 1)
        self.scout.run_once()
        self.assertIn(ha, self.qb.torrents)

    def test_a_season_pack_stays_until_every_episode_has_better(self):
        self.login()
        pack = make_torrent("Show.S01", [(f"Show.S01E0{i}.mkv", 3 * GB) for i in (1, 2)])
        one = make_torrent("Show.S01E01.DV", [("Show.S01E01.DV.mkv", 6 * GB)])
        self.add([pack, one])
        hp, h1 = info_hash(pack), info_hash(one)
        for h in (hp, h1):
            self.qb.torrents[h].update(progress=1.0, state="stalledUP")
        self.grab(1, T0 - DAY, 3000, hp)
        self.grab(2, T0 - DAY, 3000, hp)
        self.grab(1, T0 - HOUR, 13000, h1)
        self.gate.poll()
        self.scout.run_once()
        self.assertIn(hp, self.qb.torrents, "episode 2 has nothing better yet")

    # -- stalls --------------------------------------------------------------------------
    def test_a_stalled_download_is_replaced(self):
        self.login()
        t = make_torrent("Show.S01E06", [("Show.S01E06.mkv", 3 * GB)])
        self.sn.grabs[info_hash(t).upper()] = 44
        self.add([t])
        h = info_hash(t)
        self.qb.torrents[h].update(progress=0.3, state="stalledDL")
        self.gate.poll()
        self.scout.run_once()
        self.tick(2 * HOUR)
        self.scout.run_once()
        self.assertIn(h, self.qb.torrents, "two hours is not yet stalled")
        self.tick(HOUR + 60)
        self.scout.run_once()
        self.assertNotIn(h, self.qb.torrents)
        self.assertEqual(self.store.decision(h)["verdict"], "stalled")
        self.gate.poll()
        self.assertEqual(self.sn.failed, [44], "Sonarr blocklists it and takes the next best")

    def test_progress_resets_the_clock(self):
        self.login()
        t = make_torrent("Show.S01E07", [("Show.S01E07.mkv", 3 * GB)])
        self.add([t])
        h = info_hash(t)
        self.qb.torrents[h].update(progress=0.1)
        self.gate.poll()
        for p in (0.2, 0.3, 0.4, 0.5):
            self.tick(2 * HOUR)
            self.qb.torrents[h]["progress"] = p
            self.gate.poll()
            self.scout.run_once()
        self.assertIn(h, self.qb.torrents)

    def test_checking_or_moving_is_never_a_stall(self):
        self.login()
        t = make_torrent("Show.S01E08", [("Show.S01E08.mkv", 3 * GB)])
        self.add([t])
        h = info_hash(t)
        for state in ("moving", "checkingResumeData", "allocating", "checkingDL"):
            self.qb.torrents[h].update(progress=0.6, state=state)
            self.gate.poll()
            self.scout.run_once()
            self.tick(4 * HOUR)
            self.scout.run_once()
            self.assertIn(h, self.qb.torrents, f"{state} for four hours is not a stall")
        # Back to downloading: the clock starts from here, not from before the move.
        self.qb.torrents[h].update(state="stalledDL")
        self.gate.poll()
        self.scout.run_once()
        self.tick(2 * HOUR)
        self.scout.run_once()
        self.assertIn(h, self.qb.torrents)

    def test_a_magnet_whose_file_list_never_comes(self):
        self.login()
        self.add(urls=["magnet:?xt=urn:btih:" + "d" * 40 + "&dn=Show.S01E08"])
        self.gate.poll()
        self.scout.run_once()
        self.tick(2 * HOUR + 60)
        self.gate.poll()
        self.scout.run_once()
        self.assertNotIn("d" * 40, self.qb.torrents)

    def test_sonarr_frozen_still_watches_stalls(self):
        self.sn.alive = False
        self.scout.run_once()
        self.assertEqual(self.sn.searches(), [])


class Duplicates(Harness):
    def test_the_same_torrent_twice_is_not_sent_twice(self):
        self.login()
        t = make_torrent("Show.S01E09", [("Show.S01E09.mkv", 3 * GB)])
        self.add([t])
        self.assertEqual(self.add([t])[:2], (200, b"Ok."))
        self.assertEqual(len(self.qb.actions("/api/v2/torrents/add")), 1)


class ScoutScope(Harness):
    def setUp(self):
        super().setUp()
        self.now = [T0]
        self.scout = Scout(self.gate, self.sonarr, self.store, log=lambda m: None, clock=lambda: self.now[0])

    def tick(self, seconds):
        self.now[0] += seconds

    def test_grabs_from_another_client_are_not_the_scouts(self):
        # A month-old grab through the old rTorrent client: not opened, not closed.
        self.sn.history.append({"episodeId": 16011, "date": iso(T0 - 20 * DAY), "customFormatScore": 0,
                                "downloadId": "AB" * 20, "sourceTitle": "old", "customFormats": [],
                                "data": {"downloadClient": "rTorrent", "downloadClientName": "Seedbox ruTorrent"}})
        self.scout.run_once()
        self.assertEqual(self.sn.monitor, [])
        self.assertEqual(self.sn.searches(), [])


class LiveCopies(ScoutScope):
    def grab(self, ep, at, score, h, verdict):
        if verdict:
            self.store.decide(h, verdict, "x")
        self.sn.history.append({"episodeId": ep, "date": iso(at), "customFormatScore": score, "downloadId": h.upper(),
                                "sourceTitle": "x", "customFormats": [],
                                "data": {"downloadClientName": "Seedbox qBittorrent (via Magnet)"}})

    def test_a_refused_grab_is_not_a_copy(self):
        self.sn.calendar = [{"id": 21, "airDateUtc": iso(T0 - HOUR), "monitored": True, "hasFile": False}]
        self.grab(21, T0 - 50 * 60, 13000, "a" * 40, "rejected")
        self.scout.run_once()
        self.assertEqual(self.sn.searches(), [[21]], "still hunting at the first-copy pace")
        self.tick(21 * 60)
        self.scout.run_once()
        self.assertEqual(len(self.sn.searches()), 2)

    def test_every_due_episode_is_searched(self):
        self.sn.calendar = [{"id": 100 + i, "airDateUtc": iso(T0 - HOUR), "monitored": True, "hasFile": False}
                            for i in range(25)]
        self.scout.run_once()
        self.assertEqual(sorted(e for s in self.sn.searches() for e in s), list(range(100, 125)))
        self.assertTrue(all(len(s) <= 20 for s in self.sn.searches()))

    def test_search_times_survive_a_failure_later_in_the_pass(self):
        self.sn.calendar = [{"id": 31, "airDateUtc": iso(T0 - HOUR), "monitored": True, "hasFile": False}]
        def boom(*a, **k):
            raise RuntimeError("seedbox fell over")
        self.scout._stalls = boom
        self.gate.last_poll = __import__("time").time()
        with self.assertRaises(RuntimeError):
            self.scout.run_once()
        self.scout._stalls = lambda now: None
        self.tick(5 * 60)
        self.scout.run_once()
        self.assertEqual(len(self.sn.searches()), 1, "not searched again five minutes later")

    def test_a_torrent_the_gate_gave_up_on_is_replaced(self):
        self.login()
        t = make_torrent("Show.S01E11", [("Show.S01E11.mkv", 3 * GB)])
        self.add([t])
        h = info_hash(t)
        self.gate.poll()
        for _ in range(7):                      # it keeps stopping; the gate gives up
            self.qb.torrents[h].update(state="stoppedDL", progress=0.5, amount_left=GB)
            self.gate.poll()
        self.scout.run_once()
        self.tick(3 * HOUR + 60)
        self.gate.poll()
        self.qb.torrents[h].update(state="stoppedDL", progress=0.5, amount_left=GB)
        self.scout.run_once()
        self.assertNotIn(h, self.qb.torrents)
