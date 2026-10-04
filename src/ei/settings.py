"""Typed settings backed by the `settings` table.

The settings table is how the desktop app controls the daemon: it writes
rows here, and the daemon notices via `PRAGMA data_version` and reloads.
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import asdict, dataclass, fields, replace
from typing import Any

from ei.db import now_ms


@dataclass(frozen=True, slots=True)
class Settings:
    paused: bool = False
    interval_s: float = 30.0
    camera_index: int = 0
    # Opening the camera per capture flashes the light and costs ~0.5-1s;
    # keeping it open keeps the light on continuously.
    keep_camera_open: bool = False
    ollama_model: str = "qwen2.5vl:7b"
    # How long Ollama keeps the model in memory between calls. Should exceed
    # interval_s or every analysis pays a cold load.
    ollama_keep_alive: str = "10m"
    image_max_side: int = 512
    require_face: bool = True
    # Mean absolute pixel difference (0-255, on a downscaled grayscale frame)
    # below which a frame counts as "unchanged" and is skipped.
    change_threshold: float = 4.0
    # Re-analyze at least this often even if nothing changed (and re-record "away"
    # this often while no one is present).
    max_skip_s: float = 300.0
    retention_days: int = 30
    # Agent-bound trigger events older than this are dropped instead of delivered, so
    # starting an agent session doesn't replay a backlog of stale nudges.
    agent_event_ttl_s: float = 300.0
    # Unix ms of the latest "capture now" request (desktop app). The daemon runs an
    # immediate tick whenever this increases.
    capture_requested_at: int = 0

    @property
    def max_gap_s(self) -> float:
        """Longest an observation can legitimately stand before the next one is written.
        Gaps beyond this mean the daemon wasn't watching (paused, stopped, asleep)."""
        return self.max_skip_s + 2 * self.interval_s + 60


_FIELDS = {f.name: f for f in fields(Settings)}


def load(conn: sqlite3.Connection) -> Settings:
    overrides: dict[str, Any] = {}
    for row in conn.execute("SELECT key, value FROM settings"):
        if row["key"] in _FIELDS:
            overrides[row["key"]] = json.loads(row["value"])
    return replace(Settings(), **overrides)


def set_value(conn: sqlite3.Connection, key: str, value: Any) -> None:
    if key not in _FIELDS:
        raise KeyError(f"unknown setting {key!r}; known: {', '.join(_FIELDS)}")
    default = getattr(Settings(), key)
    value = coerce(value, type(default))
    with conn:
        conn.execute(
            """INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
               ON CONFLICT(key) DO UPDATE
               SET value = excluded.value, updated_at = excluded.updated_at""",
            (key, json.dumps(value), now_ms()),
        )


def coerce(value: Any, typ: type) -> Any:
    if isinstance(value, str) and typ is bool:
        if value.lower() in {"1", "true", "yes", "on"}:
            return True
        if value.lower() in {"0", "false", "no", "off"}:
            return False
        raise ValueError(f"not a boolean: {value!r}")
    return typ(value)


def as_dict(settings: Settings) -> dict[str, Any]:
    return asdict(settings)
