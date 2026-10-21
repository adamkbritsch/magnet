"""qBittorrent's torrent states, read the way its own interface reads them.

The WebUI's list shows one word per torrent -- Downloading, Stalled, Checking,
Stopped, Completed -- worked out from `state` plus `progress` and `amount_left`.
Everything here makes decisions from that same reading, so nothing acts on a torrent
that qBittorrent itself would not show as ready:

* finished   -- every byte is there and nothing is being checked: what "Completed" or
                "Seeding" means in the UI. Only a finished torrent can go to the NAS
                or retire an older copy.
* checking   -- qBittorrent is verifying or moving data. Never touched, never counted
                as stalled; the progress shown is the check's, not the download's.
* stopped    -- not running. One that still has data to fetch is the torrent that
                "pauses after the check if it needs more to download", and is resumed.
* troubled   -- errored or missing its files: rechecked and resumed, and replaced only
                if that does not bring it back.

State names are WebAPI 2.11 (qBittorrent 5); the 4.x spellings (pausedDL, pausedUP)
mean the same and are read the same.
"""

# state -> (what the UI shows, phase)
STATES = {
    "metaDL": ("Downloading metadata", "metadata"),
    "forcedMetaDL": ("[F] Downloading metadata", "metadata"),
    "allocating": ("Allocating", "checking"),
    "checkingDL": ("Checking", "checking"),
    "checkingUP": ("Checking", "checking"),
    "checkingResumeData": ("Checking resume data", "checking"),
    "moving": ("Moving", "checking"),
    "downloading": ("Downloading", "downloading"),
    "forcedDL": ("[F] Downloading", "downloading"),
    "stalledDL": ("Stalled", "stalled"),
    "queuedDL": ("Queued", "queued"),
    "stoppedDL": ("Stopped", "stopped"),
    "pausedDL": ("Stopped", "stopped"),
    "uploading": ("Seeding", "seeding"),
    "forcedUP": ("[F] Seeding", "seeding"),
    "stalledUP": ("Seeding", "seeding"),
    "queuedUP": ("Queued", "seeding"),
    "stoppedUP": ("Completed", "seeding"),
    "pausedUP": ("Completed", "seeding"),
    "error": ("Errored", "troubled"),
    "missingFiles": ("Missing Files", "troubled"),
    "unknown": ("Unknown", "troubled"),
}

CHECKING = {s for s, (_, p) in STATES.items() if p == "checking"}
STOPPED = {"stoppedDL", "pausedDL", "stoppedUP", "pausedUP"}


def phase(t):
    return STATES.get(t.get("state", "unknown"), ("Unknown", "troubled"))[1]


def label(t):
    """The word qBittorrent's own list would show."""
    return STATES.get(t.get("state", "unknown"), (t.get("state") or "Unknown", "troubled"))[0]


def left(t):
    if t.get("amount_left") is not None:
        return int(t["amount_left"])
    size = t.get("size") or t.get("total_size") or 0
    return int(round(size * (1 - float(t.get("progress") or 0))))


def is_checking(t):
    return t.get("state") in CHECKING


def is_finished(t):
    """Every byte is there and qBittorrent is not checking or moving it."""
    return phase(t) == "seeding" and left(t) == 0 and float(t.get("progress") or 0) >= 1


def has_metadata(t):
    return phase(t) != "metadata"


def needs_resume(t):
    """Stopped with data still to fetch: the pause that follows a check."""
    return t.get("state") in STOPPED and not is_finished(t) and has_metadata(t) and left(t) > 0


def is_troubled(t):
    return phase(t) == "troubled"


def progress_text(t):
    """What the progress column means right now."""
    p = int(round(float(t.get("progress") or 0) * 100))
    if is_checking(t):
        return f"Checking {p}%"
    if is_finished(t):
        return "Finished"
    return f"{p}%"
