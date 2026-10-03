"""Read-side queries shared by the MCP server, the CLI, and the future control API.

Pure functions over a sqlite3 connection. Stdlib only — imported by the MCP server.

Observations are not evenly spaced: the gate skips unchanged frames, so one observation
can stand for minutes of sitting still. Summaries are therefore time-weighted — each
observation holds until the next one, capped at `max_gap_s` so that gaps where the
daemon wasn't running count as unobserved rather than extending the last state.
"""

from __future__ import annotations

import json
import sqlite3
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any

from ei.db import Facts, now_ms

# Keys in display order. Unknown keys (from future analyzers) are listed after these.
KEY_ORDER = ["present", "activity", "gaze", "expression", "head", "posture", "hands"]


@dataclass(slots=True)
class Snapshot:
    ts: int
    age_s: float
    facts: Facts
    notes: str | None


@dataclass(slots=True)
class BehaviorSummary:
    minutes: int
    observed_s: float  # seconds of the window covered by observations
    # key -> value -> share of observed time, most common first
    shares: dict[str, dict[str, float]] = field(default_factory=dict)
    # same, for the preceding window of equal length (for "up from X%")
    previous: dict[str, dict[str, float]] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)  # most recent distinct notes


def current_observation(conn: sqlite3.Connection) -> Snapshot | None:
    row = conn.execute(
        "SELECT id, ts, payload FROM observations ORDER BY ts DESC LIMIT 1"
    ).fetchone()
    if row is None:
        return None
    return Snapshot(
        ts=row["ts"],
        age_s=(now_ms() - row["ts"]) / 1000,
        facts=_facts_for(conn, [row["id"]]).get(row["id"], {}),
        notes=_notes(row["payload"]),
    )


def behavior_summary(
    conn: sqlite3.Connection, minutes: int, *, max_gap_s: float, now: int | None = None
) -> BehaviorSummary:
    now = now_ms() if now is None else now
    window_ms = minutes * 60_000
    shares, observed_ms, notes = _time_shares(conn, now - window_ms, now, max_gap_s)
    previous, _, _ = _time_shares(conn, now - 2 * window_ms, now - window_ms, max_gap_s)
    return BehaviorSummary(
        minutes=minutes,
        observed_s=observed_ms / 1000,
        shares=shares,
        previous=previous,
        notes=notes,
    )


def recent(conn: sqlite3.Connection, limit: int = 20) -> list[dict[str, Any]]:
    """Most recent observations with their facts, newest first (CLI `tail`)."""
    rows = conn.execute(
        """SELECT id, ts, analyzer, model, latency_ms, payload FROM observations
           ORDER BY ts DESC LIMIT ?""",
        (limit,),
    ).fetchall()
    facts = _facts_for(conn, [r["id"] for r in rows])
    return [
        {**dict(r), "facts": facts.get(r["id"], {}), "notes": _notes(r["payload"])} for r in rows
    ]


def series(
    conn: sqlite3.Connection, key: str, since_ms: int, bucket_s: int = 300
) -> list[dict[str, Any]]:
    """Per-bucket observation counts of each value of one key, for charting (desktop app)."""
    bucket_ms = bucket_s * 1000
    rows = conn.execute(
        """SELECT (o.ts / ?) * ? AS bucket, f.value, COUNT(*) AS n
           FROM facts f JOIN observations o ON o.id = f.observation_id
           WHERE f.key = ? AND o.ts >= ?
           GROUP BY bucket, f.value ORDER BY bucket""",
        (bucket_ms, bucket_ms, key, since_ms),
    ).fetchall()
    return [dict(r) for r in rows]


def ordered_keys(keys: Any) -> list[str]:
    keys = list(keys)
    return [k for k in KEY_ORDER if k in keys] + sorted(k for k in keys if k not in KEY_ORDER)


def format_facts(facts: Facts) -> str:
    """Compact one-line rendering for logs and the CLI, e.g. 'gaze=screen hands=mouse,keyboard'."""
    if facts.get("present") == ["false"]:
        return "away"
    return " ".join(f"{k}={','.join(facts[k])}" for k in ordered_keys(facts) if k != "present")


def _time_shares(
    conn: sqlite3.Connection, start: int, end: int, max_gap_s: float
) -> tuple[dict[str, dict[str, float]], int, list[str]]:
    # Include the last observation before the window: its state carries into the window.
    rows = conn.execute(
        """SELECT id, ts, payload FROM observations WHERE ts >= ? AND ts < ?
           UNION ALL
           SELECT * FROM (SELECT id, ts, payload FROM observations WHERE ts < ?
                          ORDER BY ts DESC LIMIT 1)
           ORDER BY ts""",
        (start, end, start),
    ).fetchall()
    facts = _facts_for(conn, [r["id"] for r in rows])
    max_gap_ms = int(max_gap_s * 1000)

    weight: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    observed_ms = 0
    notes: list[str] = []
    for i, r in enumerate(rows):
        next_ts = rows[i + 1]["ts"] if i + 1 < len(rows) else end
        held_from = max(r["ts"], start)
        held_to = min(next_ts, r["ts"] + max_gap_ms, end)
        held = held_to - held_from
        if held <= 0:
            continue
        observed_ms += held
        for key, values in facts.get(r["id"], {}).items():
            for v in values:
                weight[key][v] += held
        if (note := _notes(r["payload"])) and note not in notes and r["ts"] >= start:
            notes.append(note)

    shares = {
        key: dict(sorted(((v, w / observed_ms) for v, w in vals.items()), key=lambda kv: -kv[1]))
        for key, vals in weight.items()
    }
    return shares, observed_ms, notes[-3:]


def _facts_for(conn: sqlite3.Connection, ids: list[int]) -> dict[int, Facts]:
    out: dict[int, Facts] = defaultdict(dict)
    if not ids:
        return out
    marks = ",".join("?" * len(ids))
    for r in conn.execute(
        f"SELECT observation_id, key, value FROM facts WHERE observation_id IN ({marks})", ids
    ):
        out[r["observation_id"]].setdefault(r["key"], []).append(r["value"])
    return out


def _notes(payload: str | None) -> str | None:
    if not payload:
        return None
    return json.loads(payload).get("notes") or None
