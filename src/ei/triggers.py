"""Triggers: rules over observed facts that fire events ("when I take a drink, tell my
agent"; "when I've slouched for 10 minutes, notify me").

Detection and delivery are separate. The daemon evaluates triggers and writes rows to
`events`; consumers deliver them: OS notifications are sent by the daemon right away,
agent events are claimed by the Claude Code hook (`ei-hook`) at the agent's next step.

Stdlib only — imported by the hook, which runs on every agent tool call.
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass, field
from typing import Literal

from ei.db import Facts, now_ms

Kind = Literal["on_enter", "sustained"]
Action = Literal["agent", "os_notify"]
KINDS: tuple[Kind, ...] = ("on_enter", "sustained")
ACTIONS: tuple[Action, ...] = ("agent", "os_notify")


@dataclass(frozen=True, slots=True)
class Trigger:
    name: str
    conditions: dict[str, list[str]]  # key -> accepted values; every key must match
    kind: Kind
    action: Action
    message: str
    for_s: float = 0.0
    cooldown_s: float = 0.0
    enabled: bool = True
    id: int | None = None

    def matches(self, facts: Facts) -> bool:
        return all(
            any(v in facts.get(key, ()) for v in accepted)
            for key, accepted in self.conditions.items()
        )


@dataclass(frozen=True, slots=True)
class Event:
    id: int
    ts: int
    trigger_id: int | None
    action: str
    message: str


# --- storage: shared by the CLI, the daemon, and (later) the desktop app ---------------


def add(conn: sqlite3.Connection, t: Trigger) -> int:
    if t.kind not in KINDS:
        raise ValueError(f"kind must be one of {KINDS}")
    if t.action not in ACTIONS:
        raise ValueError(f"action must be one of {ACTIONS}")
    if not t.conditions:
        raise ValueError("a trigger needs at least one condition")
    with conn:
        cur = conn.execute(
            """INSERT INTO triggers
               (name, enabled, conditions, kind, for_s, cooldown_s, action, message, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (t.name, int(t.enabled), json.dumps(t.conditions), t.kind, t.for_s, t.cooldown_s,
             t.action, t.message, now_ms()),
        )  # fmt: skip
    return cur.lastrowid or 0


def load(conn: sqlite3.Connection, *, enabled_only: bool = False) -> list[Trigger]:
    sql = "SELECT * FROM triggers" + (" WHERE enabled = 1" if enabled_only else "") + " ORDER BY id"
    return [
        Trigger(
            id=r["id"],
            name=r["name"],
            enabled=bool(r["enabled"]),
            conditions=json.loads(r["conditions"]),
            kind=r["kind"],
            for_s=r["for_s"],
            cooldown_s=r["cooldown_s"],
            action=r["action"],
            message=r["message"],
        )
        for r in conn.execute(sql)
    ]


def set_enabled(conn: sqlite3.Connection, trigger_id: int, enabled: bool) -> bool:
    with conn:
        cur = conn.execute(
            "UPDATE triggers SET enabled = ?, updated_at = ? WHERE id = ?",
            (int(enabled), now_ms(), trigger_id),
        )
    return cur.rowcount > 0


def remove(conn: sqlite3.Connection, trigger_id: int) -> bool:
    with conn:
        cur = conn.execute("DELETE FROM triggers WHERE id = ?", (trigger_id,))
    return cur.rowcount > 0


def record_event(conn: sqlite3.Connection, t: Trigger, ts: int, *, delivered: bool = False) -> int:
    with conn:
        cur = conn.execute(
            """INSERT INTO events (ts, trigger_id, action, message, delivered_at)
               VALUES (?, ?, ?, ?, ?)""",
            (ts, t.id, t.action, t.message, ts if delivered else None),
        )
    return cur.lastrowid or 0


def claim_agent_events(conn: sqlite3.Connection, ttl_s: float) -> list[Event]:
    """Atomically claim undelivered agent events younger than ttl_s. With several agent
    sessions open, whichever reaches its next step first gets each event exactly once.
    Expired events are marked delivered too, so they never pile up."""
    now = now_ms()
    with conn:
        rows = conn.execute(
            """UPDATE events SET delivered_at = ?
               WHERE action = 'agent' AND delivered_at IS NULL
               RETURNING id, ts, trigger_id, action, message""",
            (now,),
        ).fetchall()
    fresh = [Event(**dict(r)) for r in rows if now - r["ts"] <= ttl_s * 1000]
    return sorted(fresh, key=lambda e: e.ts)


def recent_events(conn: sqlite3.Connection, limit: int = 20) -> list[sqlite3.Row]:
    return conn.execute(
        """SELECT e.*, t.name AS trigger_name FROM events e
           LEFT JOIN triggers t ON t.id = e.trigger_id ORDER BY e.ts DESC LIMIT ?""",
        (limit,),
    ).fetchall()


# --- evaluation (daemon) -----------------------------------------------------------------


@dataclass(slots=True)
class _State:
    matching: bool = False
    since_ms: int | None = None  # when the current matching episode started
    fired_this_episode: bool = False
    last_fired_ms: int | None = None


@dataclass(slots=True)
class TriggerEngine:
    """Evaluates triggers against the current facts. Call `evaluate` on every daemon tick
    with the latest known facts — not only when a new observation is written — so that
    `sustained` triggers fire on time even while the gate skips unchanged frames.

    `max_gap_s`: if evaluations are further apart than this (daemon paused or asleep),
    episodes reset rather than counting unobserved time toward `sustained` durations.
    """

    max_gap_s: float
    triggers: list[Trigger] = field(default_factory=list)
    _state: dict[int, _State] = field(default_factory=dict)
    _last_eval_ms: int | None = None

    def set_triggers(self, triggers: list[Trigger]) -> None:
        """Swap in a reloaded trigger list, keeping episode state for unchanged triggers."""
        old = {t.id: t for t in self.triggers}
        self.triggers = [t for t in triggers if t.enabled and t.id is not None]
        self._state = {
            t.id: self._state[t.id]
            for t in self.triggers
            if t.id in self._state and old.get(t.id) == t and t.id is not None
        }

    def evaluate(self, facts: Facts, ts_ms: int) -> list[Trigger]:
        if self._last_eval_ms is not None and ts_ms - self._last_eval_ms > self.max_gap_s * 1000:
            self._state = {
                tid: _State(last_fired_ms=s.last_fired_ms) for tid, s in self._state.items()
            }
        self._last_eval_ms = ts_ms

        fired: list[Trigger] = []
        for t in self.triggers:
            assert t.id is not None
            st = self._state.setdefault(t.id, _State())
            was_matching = st.matching
            st.matching = t.matches(facts)
            if not st.matching:
                st.since_ms, st.fired_this_episode = None, False
                continue
            entering = not was_matching or st.since_ms is None
            if entering:
                st.since_ms, st.fired_this_episode = ts_ms, False
            if st.fired_this_episode:
                continue
            # on_enter fires only at the moment of entry; if a cooldown blocks it then,
            # it doesn't fire later in the same episode.
            if t.kind == "on_enter" and not entering:
                continue
            assert st.since_ms is not None
            if t.kind == "sustained" and ts_ms - st.since_ms < t.for_s * 1000:
                continue
            if st.last_fired_ms is not None and ts_ms - st.last_fired_ms < t.cooldown_s * 1000:
                continue
            st.fired_this_episode = True
            st.last_fired_ms = ts_ms
            fired.append(t)
        return fired
