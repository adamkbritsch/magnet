"""The gate's memory: what it decided about each torrent, and every transfer asked for."""

import json
import sqlite3
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS decisions (
    hash TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    verdict TEXT NOT NULL,            -- held | approved | rejected
    reason TEXT NOT NULL DEFAULT '',
    files TEXT NOT NULL DEFAULT '[]', -- offending paths for a rejection
    source TEXT NOT NULL DEFAULT '',  -- torrent-file | magnet | url | found
    sonarr_marked INTEGER NOT NULL DEFAULT 0,
    attempts INTEGER NOT NULL DEFAULT 0,
    created REAL NOT NULL,
    updated REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS transfers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hash TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL,             -- running | done | skipped | failed
    command_id INTEGER,
    message TEXT NOT NULL DEFAULT '',
    created REAL NOT NULL,
    updated REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS kv (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at REAL NOT NULL,
    kind TEXT NOT NULL,
    hash TEXT NOT NULL DEFAULT '',
    message TEXT NOT NULL
);
"""


class Store:
    def __init__(self, path):
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        with self._lock:
            self._db.executescript(SCHEMA)
            self._db.execute("PRAGMA journal_mode=WAL")

    def _rows(self, sql, args=()):
        with self._lock:
            return [dict(r) for r in self._db.execute(sql, args).fetchall()]

    def _exec(self, sql, args=()):
        with self._lock:
            cur = self._db.execute(sql, args)
            self._db.commit()
            return cur.lastrowid

    # -- decisions ---------------------------------------------------------------
    def decision(self, h):
        rows = self._rows("SELECT * FROM decisions WHERE hash=?", (h.lower(),))
        return rows[0] if rows else None

    def decide(self, h, verdict, name="", reason="", files=(), source="", new_grab=False):
        """new_grab: this is a fresh grab of the hash (Sonarr sent it again), so a
        refusal must be reported to Sonarr again even if an earlier one was."""
        now = time.time()
        h = h.lower()
        old = self.decision(h)
        if old:
            report_again = verdict in ("rejected", "stalled") and (new_grab or old["verdict"] != verdict)
            self._exec("UPDATE decisions SET verdict=?, name=COALESCE(NULLIF(?, ''), name), reason=?, files=?,"
                       " source=COALESCE(NULLIF(?, ''), source), updated=?"
                       + (", sonarr_marked=0, attempts=0" if report_again else "") + " WHERE hash=?",
                       (verdict, name, reason, json.dumps(list(files)), source, now, h))
        else:
            self._exec("INSERT INTO decisions (hash, name, verdict, reason, files, source, created, updated)"
                       " VALUES (?,?,?,?,?,?,?,?)", (h, name, verdict, reason, json.dumps(list(files)), source, now, now))
        if not old or old["verdict"] != verdict:
            self.event(verdict, h, f"{name or h}: {verdict}" + (f" -- {reason}" if reason else ""))

    def set_marked(self, h, marked, attempts):
        self._exec("UPDATE decisions SET sonarr_marked=?, attempts=?, updated=? WHERE hash=?",
                   (marked, attempts, time.time(), h.lower()))

    def rejections(self, limit=100):
        return self._rows("SELECT * FROM decisions WHERE verdict IN ('rejected', 'stalled')"
                          " ORDER BY updated DESC LIMIT ?", (limit,))

    def unmarked_rejections(self):
        # Refused and stalled releases are both reported to Sonarr as failed, so it
        # blocklists them and takes the next best.
        return self._rows("SELECT * FROM decisions WHERE verdict IN ('rejected', 'stalled')"
                          " AND sonarr_marked=0 AND attempts<60")

    def decisions(self):
        return {r["hash"]: r for r in self._rows("SELECT * FROM decisions")}

    # -- transfers ---------------------------------------------------------------
    def add_transfer(self, h, name, command_id):
        now = time.time()
        return self._exec("INSERT INTO transfers (hash, name, status, command_id, created, updated)"
                          " VALUES (?,?,?,?,?,?)", (h.lower(), name, "running", command_id, now, now))

    def fail_transfer(self, h, name, message):
        """A copy that could not even be started, recorded so it is not retried at once."""
        now = time.time()
        return self._exec("INSERT INTO transfers (hash, name, status, command_id, message, created, updated)"
                          " VALUES (?,?,?,?,?,?,?)", (h.lower(), name, "failed", None, message, now, now))

    def update_transfer(self, tid, status, message=""):
        self._exec("UPDATE transfers SET status=?, message=?, updated=? WHERE id=?", (status, message, time.time(), tid))

    def transfers(self, limit=100):
        return self._rows("SELECT * FROM transfers ORDER BY id DESC LIMIT ?", (limit,))

    def running_transfers(self):
        return self._rows("SELECT * FROM transfers WHERE status='running'")

    def active_transfer(self, h):
        rows = self._rows("SELECT * FROM transfers WHERE hash=? AND status='running'", (h.lower(),))
        return rows[0] if rows else None

    # -- small settings ----------------------------------------------------------
    def get(self, key, default=None):
        rows = self._rows("SELECT value FROM kv WHERE key=?", (key,))
        return json.loads(rows[0]["value"]) if rows else default

    def put(self, key, value):
        self._exec("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   (key, json.dumps(value)))

    # -- events ------------------------------------------------------------------
    def event(self, kind, h, message):
        self._exec("INSERT INTO events (at, kind, hash, message) VALUES (?,?,?,?)", (time.time(), kind, h, message))
        self._exec("DELETE FROM events WHERE id < (SELECT MAX(id) - 2000 FROM events)")

    def events(self, limit=200):
        return self._rows("SELECT * FROM events ORDER BY id DESC LIMIT ?", (limit,))
