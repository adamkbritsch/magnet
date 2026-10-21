import hashlib
import unittest

from automatic import bencode, rules
from fakes import benc, make_torrent

GB = 1024 ** 3
MB = 1024 ** 2


class Rules(unittest.TestCase):
    def ok(self, files):
        ok, reason, _ = rules.judge(files)
        self.assertTrue(ok, reason)

    def bad(self, files, words):
        ok, reason, offending = rules.judge(files)
        self.assertFalse(ok)
        self.assertIn(words, reason)
        return offending

    def test_clean_episode(self):
        self.ok([("Show.S01E01.2160p.WEB-DL.DV.mkv", 6 * GB)])

    def test_episode_with_subs_and_extras(self):
        self.ok([("Show.S01E01/Show.S01E01.mkv", 2 * GB), ("Show.S01E01/Subs/English.srt", 80_000),
                 ("Show.S01E01/Show.nfo", 3_000), ("Show.S01E01/poster.jpg", 200_000),
                 ("Show.S01E01/RARBG.txt", 120)])

    def test_season_pack(self):
        self.ok([(f"Show.S02/Show.S02E{i:02}.mkv", 4 * GB) for i in range(1, 9)])

    def test_exe_beside_the_episode(self):
        off = self.bad([("Show.S01E01.mkv", 2 * GB), ("Codec/Setup.exe", 3 * MB)], ".exe")
        self.assertEqual(off, ["Codec/Setup.exe"])

    def test_the_scr_the_seedbox_actually_got(self):
        # The file rTorrent's tv-sonarr label really held: one 0.9 GB screensaver.
        self.bad([("4F1C9A0E2B7D63A85C0E91F27D4B6A3E98C1D2F0.scr", int(0.9 * GB))], ".scr")

    def test_double_extension(self):
        self.bad([("Show.S01E01.1080p.mkv.exe", 2 * GB)], ".exe")

    def test_right_to_left_override(self):
        # Displays as "Show.S01E01exe.mkv" in a file browser.
        self.bad([("Show.S01E01‮vkm.exe", 2 * GB)], ".exe")

    def test_windows_ignores_trailing_dots_and_spaces(self):
        self.bad([("Show.S01E01.mkv", 2 * GB), ("Player.exe. ", 2 * MB)], ".exe")

    def test_uppercase(self):
        self.bad([("Show.S01E01.mkv", 2 * GB), ("PLAY.EXE", 2 * MB)], ".exe")

    def test_other_executables(self):
        for ext in ("msi", "lnk", "bat", "cmd", "ps1", "vbs", "com", "jar", "dmg", "pkg"):
            with self.subTest(ext=ext):
                self.bad([("Show.S01E01.mkv", 2 * GB), (f"extra.{ext}", 2 * MB)], f".{ext}")

    def test_app_bundle(self):
        self.bad([("Show.S01E01.mkv", 2 * GB), ("Player.app/Contents/MacOS/Player", 5 * MB)], "app bundle")

    def test_no_video(self):
        self.bad([("Show.S01E01.zip", 2 * GB), ("password.txt", 40)], "no video")

    def test_sample_only(self):
        self.bad([("Show.S01E01.sample.mkv", 12 * MB)], "no video")

    def test_sample_plus_big_archive(self):
        self.bad([("sample.mkv", 60 * MB), ("Show.S01E01.rar", 2 * GB)], "largest file is not a video")

    def test_empty(self):
        self.bad([], "no files")

    def test_names_that_only_look_dangerous(self):
        # "com" and "exe" as words inside a title are fine; only the extension counts.
        self.ok([("www.TorrentSite.com - Show.S01E01.Executive.Order.mkv", 2 * GB)])


class Bencode(unittest.TestCase):
    def test_single_file(self):
        raw = make_torrent("Show.S01E01.mkv", [("Show.S01E01.mkv", 5 * GB)])
        info = bencode.torrent_info(raw)
        self.assertEqual(info["name"], "Show.S01E01.mkv")
        self.assertEqual(info["files"], [("Show.S01E01.mkv", 5 * GB)])

    def test_multi_file_paths_and_hash(self):
        raw = make_torrent("Show.S01E01", [("Show.S01E01.mkv", 2 * GB), ("Codec/Setup.exe", 3 * MB)])
        info = bencode.torrent_info(raw)
        self.assertEqual(info["files"], [("Show.S01E01/Show.S01E01.mkv", 2 * GB), ("Show.S01E01/Codec/Setup.exe", 3 * MB)])
        start = raw.index(b"4:info") + 6
        self.assertEqual(info["hash"], hashlib.sha1(raw[start:-1]).hexdigest())

    def test_hash_uses_original_bytes_even_when_not_canonical(self):
        # Keys out of order: a re-encode would sort them and hash something else.
        info_raw = b"d6:lengthi10e4:name5:a.mkv12:piece lengthi16e6:pieces20:" + b"\0" * 20 + b"e"
        noncanon = b"d4:info" + info_raw.replace(b"6:lengthi10e4:name5:a.mkv", b"4:name5:a.mkv6:lengthi10e") + b"e"
        start = noncanon.index(b"4:info") + 6
        self.assertEqual(bencode.torrent_info(noncanon)["hash"], hashlib.sha1(noncanon[start:-1]).hexdigest())

    def test_v2_file_tree(self):
        tree = {"Show.S01E01.mkv": {"": {"length": 3 * GB, "pieces root": b"\0" * 32}},
                "bonus": {"Setup.exe": {"": {"length": 1 * MB, "pieces root": b"\0" * 32}}}}
        raw = benc({"info": {"name": "Show.S01E01", "meta version": 2, "piece length": 16384, "file tree": tree}})
        files = bencode.torrent_info(raw)["files"]
        self.assertIn(("Show.S01E01/bonus/Setup.exe", 1 * MB), files)
        self.assertFalse(rules.judge(files)[0])

    def test_garbage(self):
        for raw in (b"", b"<html>", b"d4:infoi1ee", b"d4:info5:abce", b"l" * 100):
            with self.subTest(raw=raw[:10]):
                with self.assertRaises(bencode.BencodeError):
                    bencode.torrent_info(raw)


if __name__ == "__main__":
    unittest.main()


class Hardening(unittest.TestCase):
    def test_a_file_named_only_dot_exe(self):
        self.assertFalse(rules.judge([("Show.S01E01.mkv", 2 * GB), ("Show/.exe", 2 * MB)])[0])

    def test_disk_images_and_launchers(self):
        for name in ("Codec.iso", "Player.img", "Setup.vhdx", "Console.msc", "Help.chm"):
            with self.subTest(name=name):
                self.assertFalse(rules.judge([("Show.S01E01.mkv", 2 * GB), (name, 5 * MB)])[0])

    def test_a_repeated_key_is_refused(self):
        # libtorrent reads the first "files", Python's dict would keep the last.
        info = (b"d5:filesld6:lengthi1048576e4:pathl9:Setup.exeeee"
                b"5:filesld6:lengthi3221225472e4:pathl15:Show.S01E01.mkveee"
                b"4:name4:Show12:piece lengthi16e6:pieces20:" + b"\0" * 20 + b"e")
        with self.assertRaises(bencode.BencodeError):
            bencode.torrent_info(b"d4:info" + info + b"e")

    def test_odd_shapes_raise_bencode_errors_only(self):
        for raw in (b"d4:infod5:filesl1:xeee", b"d4:infod5:filesli1eeee", b"d4:infod4:name1x:ee"):
            with self.subTest(raw=raw):
                with self.assertRaises(bencode.BencodeError):
                    bencode.torrent_info(raw)


class SecondReview(unittest.TestCase):
    def test_leading_dots_and_shortcuts(self):
        for name in ("Show/..exe", "Show/...scr", "Show/Watch Online.url", "Show/codec.cab", "Show/x.webloc"):
            with self.subTest(name=name):
                self.assertFalse(rules.judge([("Show/Show.S01E05.mkv", 3 * GB), (name, 2 * MB)])[0])

    def test_path_utf8_only_when_it_is_a_real_list(self):
        # libtorrent ignores an empty path.utf-8 and reads path: so must the gate.
        raw = benc({"info": {"name": "Show.S01E05", "piece length": 16384, "pieces": b"\0" * 20,
                             "files": [{"length": 3 * GB, "path": ["Show.S01E05.mkv"]},
                                       {"length": 2 * MB, "path.utf-8": [], "path": ["Setup.exe"]}]}})
        self.assertIn(("Show.S01E05/Setup.exe", 2 * MB), bencode.torrent_info(raw)["files"])

    def test_a_file_tree_counts_only_in_a_v2_torrent(self):
        tree = {"Show.S01E05.mkv": {"": {"length": 3 * GB}}}
        raw = benc({"info": {"name": "Show.S01E05.scr", "length": 900 * MB, "piece length": 16384,
                             "pieces": b"\0" * 20, "file tree": tree}})
        self.assertEqual(bencode.torrent_info(raw)["files"], [("Show.S01E05.scr", 900 * MB)])

    def test_the_hash_of_a_file_the_strict_reader_refused(self):
        info = b"d6:lengthi1e4:name1:a4:name1:b12:piece lengthi16e6:pieces20:" + b"\0" * 20 + b"e"
        raw = b"d4:info" + info + b"e"
        with self.assertRaises(bencode.BencodeError):
            bencode.torrent_info(raw)
        self.assertEqual(bencode.lenient_hash(raw), hashlib.sha1(info).hexdigest())
