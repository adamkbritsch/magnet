"""What a TV release may contain.

An episode torrent is video, subtitles and a few text or image extras. Anything
that can run is the signature of a fake: the trap that put OperaGX installers on
the Mac, and the `<hash>.scr` that Sonarr's old rTorrent path pulled onto the
seedbox under the tv-sonarr label. `.exe` is banned by name; the rest of the list
is the same thing with a different extension (`.scr` IS a Windows executable).

A release is rejected outright, never trimmed, because a torrent that carries a
payload alongside an episode is not a release worth keeping any part of.
"""

import os
import unicodedata

VIDEO = {"mkv", "mp4", "m4v", "avi", "ts", "m2ts", "mov", "wmv", "webm", "mpg", "mpeg"}

# Windows executables and script hosts, then the macOS and Unix equivalents.
EXECUTABLE = {
    "exe", "scr", "com", "pif", "bat", "cmd", "msi", "msp", "msix", "appx", "lnk", "cpl", "dll",
    "sys", "drv", "ocx", "vbs", "vbe", "js", "jse", "wsf", "wsh", "ps1", "psm1", "hta", "jar",
    "reg", "scf", "inf", "application", "gadget", "msc", "chm", "xll", "wsc", "sct", "ws", "appref-ms",
    "library-ms", "settingcontent-ms", "diagcab", "search-ms", "msu", "cab", "url",
    "webloc", "inetloc", "fileloc", "terminal", "tool", "workflow",
    # Disk images: Windows mounts them on a double-click and shows the payload inside.
    "iso", "img", "vhd", "vhdx",
    "app", "dmg", "pkg", "mpkg", "command", "sh", "apk",
}

# The smallest file that can plausibly be an episode. A 22-minute 480p web episode
# is well over this; samples and promo clips are under it.
MIN_VIDEO_BYTES = 50 * 1024 * 1024


def _clean(name):
    # Strip invisible format characters (U+202E right-to-left override is the
    # classic "Episode<RLO>vkm.exe" trick) and trailing dots and spaces, which
    # Windows ignores when it decides what a file is.
    name = "".join(ch for ch in name if unicodedata.category(ch) != "Cf")
    return name.strip().rstrip(". ").strip()


def extension(path):
    base = _clean(os.path.basename(path.replace("\\", "/")))
    # What follows the last dot, the way Windows reads it: ".exe", "..exe" and
    # "Setup.exe" are all executables.
    return base.rsplit(".", 1)[1].lower() if "." in base else ""


def _executable(path):
    if extension(path) in EXECUTABLE:
        return True
    # A bundle directory such as "Player.app/Contents/MacOS/Player".
    parts = [_clean(p).lower() for p in path.replace("\\", "/").split("/")[:-1]]
    return any(p.endswith((".app", ".pkg", ".mpkg")) for p in parts)


def judge(files):
    """files: iterable of (path, size). Returns (ok, reason, offending_paths)."""
    files = [(str(p), int(s)) for p, s in files]
    if not files:
        return False, "the torrent lists no files", []
    bad = [p for p, _ in files if _executable(p)]
    if bad:
        exts = sorted({"." + extension(p) if extension(p) in EXECUTABLE else "app bundle" for p in bad})
        return False, "contains an executable (" + ", ".join(exts) + ")", bad
    videos = [(p, s) for p, s in files if extension(p) in VIDEO and s >= MIN_VIDEO_BYTES]
    if not videos:
        return False, "no video file of episode size", [p for p, _ in files]
    largest = max(files, key=lambda f: f[1])
    if extension(largest[0]) not in VIDEO:
        return False, "the largest file is not a video (" + os.path.basename(largest[0]) + ")", [largest[0]]
    return True, "", []
