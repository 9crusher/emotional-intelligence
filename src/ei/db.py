"""SQLite connection, migrations, and the write path.

SQLite (WAL mode) is the contract between processes: the daemon is the single
writer; the MCP server and desktop app are readers. Stdlib only — this module is
imported by the MCP server, so it must stay cheap to import.

Data model: an `observation` is one analyzed moment; its `facts` are what was seen
(key/value pairs such as posture=slouched, hands=face). Only observable
behavior is stored — never inferred emotions.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

APP_NAME = "emotional-intelligence"


def default_db_path() -> Path:
    if env := os.environ.get("EI_DB"):
        return Path(env).expanduser()
    return Path.home() / "Library" / "Application Support" / APP_NAME / "ei.db"


# Append-only: never edit a migration that may have run on someone's machine.
MIGRATIONS: list[str] = [
    # 1: initial schema
    """
    CREATE TABLE observations (
        id          INTEGER PRIMARY KEY,
        ts          INTEGER NOT NULL,          -- unix ms
        analyzer    TEXT    NOT NULL,          -- 'emotion.vlm', 'posture', ...
        model       TEXT,
        latency_ms  INTEGER,
        valence     REAL,                      -- -1 (negative) .. 1 (positive)
        arousal     REAL,                      --  0 (calm)     .. 1 (activated)
        confidence  REAL,                      --  0 .. 1
        label       TEXT,                      -- 'focused', 'frustrated', ...
        payload     TEXT                       -- JSON: cues, notes, analyzer-specific
    );
    CREATE INDEX observations_analyzer_ts ON observations(analyzer, ts);
    CREATE INDEX observations_ts ON observations(ts);

    CREATE TABLE settings (
        key         TEXT PRIMARY KEY,
        value       TEXT NOT NULL,             -- JSON-encoded
        updated_at  INTEGER NOT NULL
    );
    """,
    # 2: observe behavior instead of judging emotion. Drops the emotion columns and
    # the emotion judgments already recorded with them.
    """
    DELETE FROM observations;
    ALTER TABLE observations DROP COLUMN valence;
    ALTER TABLE observations DROP COLUMN arousal;
    ALTER TABLE observations DROP COLUMN confidence;
    ALTER TABLE observations DROP COLUMN label;

    CREATE TABLE facts (
        observation_id  INTEGER NOT NULL REFERENCES observations(id) ON DELETE CASCADE,
        key             TEXT    NOT NULL,      -- 'posture', 'hands', 'gaze', ...
        value           TEXT    NOT NULL,      -- 'slouched', 'face', ...
        PRIMARY KEY (observation_id, key, value)
    ) WITHOUT ROWID;
    CREATE INDEX facts_key_value ON facts(key, value);
    """,
    # 3: triggers (rules the desktop app/CLI configure) and the events they fire.
    """
    CREATE TABLE triggers (
        id          INTEGER PRIMARY KEY,
        name        TEXT    NOT NULL,
        enabled     INTEGER NOT NULL DEFAULT 1,
        conditions  TEXT    NOT NULL,          -- JSON {key: [values]}; all keys must match
        kind        TEXT    NOT NULL CHECK (kind IN ('on_enter', 'sustained')),
        for_s       REAL    NOT NULL DEFAULT 0, -- sustained: how long conditions must hold
        cooldown_s  REAL    NOT NULL DEFAULT 0, -- minimum time between firings
        action      TEXT    NOT NULL CHECK (action IN ('agent', 'os_notify')),
        message     TEXT    NOT NULL,
        updated_at  INTEGER NOT NULL
    );

    CREATE TABLE events (
        id            INTEGER PRIMARY KEY,
        ts            INTEGER NOT NULL,
        trigger_id    INTEGER REFERENCES triggers(id) ON DELETE SET NULL,
        action        TEXT    NOT NULL,
        message       TEXT    NOT NULL,
        delivered_at  INTEGER                  -- NULL until a consumer claims it
    );
    CREATE INDEX events_pending ON events(action, ts) WHERE delivered_at IS NULL;
    CREATE INDEX events_ts ON events(ts);
    """,
    # 4: daemon heartbeat, so readers (desktop app) can tell the daemon is alive and
    # what its last tick did even when the gate skipped and nothing was written.
    """
    CREATE TABLE daemon_state (
        id            INTEGER PRIMARY KEY CHECK (id = 1),
        pid           INTEGER NOT NULL,
        started_at    INTEGER NOT NULL,        -- unix ms
        last_tick_ts  INTEGER,                 -- unix ms
        last_status   TEXT,                    -- TickResult.status
        last_error    TEXT
    );
    """,
    # 5: smaller vocabulary that small local models can tell apart reliably. Maps old
    # values onto their closest new one (NULL drops it); `head` folds into hands=face.
    """
    CREATE TEMP TABLE remap (key TEXT, old TEXT, new TEXT);
    INSERT INTO remap VALUES
        ('activity', 'talking', 'working'), ('activity', 'eating', 'eating_drinking'),
        ('activity', 'drinking', 'eating_drinking'), ('activity', 'stretching', 'idle'),
        ('gaze', 'down', 'away'), ('gaze', 'eyes_closed', 'away'),
        ('expression', 'laughing', 'smiling'), ('expression', 'brow_furrowed', 'frowning'),
        ('expression', 'lips_pressed', 'frowning'), ('expression', 'mouth_open', NULL),
        ('posture', 'leaning_forward', 'upright'), ('posture', 'leaning_back', 'slouched'),
        ('hands', 'keyboard', 'desk'), ('hands', 'mouse', 'desk'),
        ('hands', 'touching_face', 'face'), ('hands', 'rubbing_eyes', 'face'),
        ('hands', 'behind_head', NULL), ('hands', 'arms_crossed', NULL),
        ('hands', 'holding_object', NULL), ('hands', 'gesturing', NULL);

    INSERT OR IGNORE INTO facts (observation_id, key, value)
        SELECT observation_id, 'hands', 'face' FROM facts
        WHERE key = 'head' AND value IN ('in_hands', 'resting_on_hand');
    DELETE FROM facts WHERE key = 'head';
    INSERT OR IGNORE INTO facts (observation_id, key, value)
        SELECT f.observation_id, f.key, r.new FROM facts f
        JOIN remap r ON r.key = f.key AND r.old = f.value WHERE r.new IS NOT NULL;
    DELETE FROM facts WHERE EXISTS
        (SELECT 1 FROM remap r WHERE r.key = facts.key AND r.old = facts.value);
    -- hands is single-valued now; face wins over desk.
    DELETE FROM facts WHERE key = 'hands' AND value = 'desk' AND observation_id IN
        (SELECT observation_id FROM facts WHERE key = 'hands' AND value = 'face');

    -- Old values are unique across keys, so a quoted string replace is safe in the JSON.
    WITH RECURSIVE step(i, id, c) AS (
        SELECT 0, id, conditions FROM triggers
        UNION ALL
        SELECT s.i + 1, s.id, replace(s.c, '"' || r.old || '"', '"' || r.new || '"')
        FROM step s JOIN (SELECT row_number() OVER () - 1 AS i, old, new FROM remap
                          WHERE new IS NOT NULL) r ON r.i = s.i
    )
    UPDATE triggers SET conditions = (SELECT c FROM step WHERE step.id = triggers.id
                                      ORDER BY i DESC LIMIT 1);
    -- Merged values can repeat (brow_furrowed + frowning -> frowning twice).
    UPDATE triggers SET conditions = (
        SELECT json_group_object(k.key, json((SELECT json_group_array(DISTINCT v.value)
                                              FROM json_each(k.value) v)))
        FROM json_each(triggers.conditions) k);
    DROP TABLE remap;
    """,
]


def connect(path: Path | None = None, *, readonly: bool = False) -> sqlite3.Connection:
    """Open the database. Writers also create it and apply migrations."""
    path = path or default_db_path()
    if readonly:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, check_same_thread=False)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(path, check_same_thread=False)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=2000")
    conn.execute("PRAGMA foreign_keys=ON")
    if not readonly:
        migrate(conn)
    return conn


def migrate(conn: sqlite3.Connection) -> None:
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    for i, sql in enumerate(MIGRATIONS[version:], start=version + 1):
        # executescript runs outside the sqlite3 module's transaction handling, so the
        # script carries its own BEGIN/COMMIT to apply each migration atomically.
        conn.executescript(f"BEGIN;\n{sql}\nPRAGMA user_version={i};\nCOMMIT;")


def now_ms() -> int:
    return int(time.time() * 1000)


Facts = dict[str, list[str]]  # key -> values; the VLM reports one value per key


@dataclass(slots=True)
class Observation:
    analyzer: str
    facts: Facts
    ts: int = field(default_factory=now_ms)
    model: str | None = None
    latency_ms: int | None = None
    payload: dict[str, Any] = field(default_factory=dict)  # notes, gate reason, ...


def insert_observation(conn: sqlite3.Connection, obs: Observation) -> int:
    with conn:
        cur = conn.execute(
            """INSERT INTO observations (ts, analyzer, model, latency_ms, payload)
               VALUES (?, ?, ?, ?, ?)""",
            (
                obs.ts,
                obs.analyzer,
                obs.model,
                obs.latency_ms,
                json.dumps(obs.payload) if obs.payload else None,
            ),
        )
        obs_id = cur.lastrowid or 0
        conn.executemany(
            "INSERT OR IGNORE INTO facts (observation_id, key, value) VALUES (?, ?, ?)",
            [(obs_id, k, v) for k, values in obs.facts.items() for v in values],
        )
    return obs_id


def record_daemon_start(conn: sqlite3.Connection, pid: int) -> None:
    with conn:
        conn.execute(
            "INSERT OR REPLACE INTO daemon_state (id, pid, started_at) VALUES (1, ?, ?)",
            (pid, now_ms()),
        )


def record_tick(conn: sqlite3.Connection, status: str, error: str | None = None) -> None:
    with conn:
        conn.execute(
            """UPDATE daemon_state SET last_tick_ts = ?, last_status = ?, last_error = ?
               WHERE id = 1""",
            (now_ms(), status, error),
        )


def prune(conn: sqlite3.Connection, retention_days: int) -> int:
    """Delete observations (and, via cascade, their facts) and events older than the
    retention window. Returns the number of observations deleted."""
    cutoff = now_ms() - retention_days * 86_400_000
    with conn:
        cur = conn.execute("DELETE FROM observations WHERE ts < ?", (cutoff,))
        conn.execute("DELETE FROM events WHERE ts < ?", (cutoff,))
    return cur.rowcount
