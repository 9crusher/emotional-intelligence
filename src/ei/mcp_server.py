"""Read-only MCP server (stdio). Agents spawn one per session.

Startup time is user-facing latency, so this module must not import cv2, numpy,
ollama, or anything from the daemon side.
It never has access to images: it only reads observed behavior from SQLite.
"""

from __future__ import annotations

import sqlite3
from functools import cache

from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations

from ei import db, queries
from ei import settings as settings_mod

mcp = MCPServer(
    "emotional-intelligence",
    instructions=(
        "Observed body language of the user, recorded locally from their webcam: activity, "
        "gaze, facial expression, posture, and hands. These are observations, "
        "not conclusions. Interpret them yourself, in light of what you and the user are "
        "doing (e.g. frowning after repeated test failures). Treat them as soft, "
        "noisy hints, and don't recite them back to the user unprompted."
    ),
)

READ_ONLY = ToolAnnotations(read_only_hint=True, open_world_hint=False)
NO_DATA = "No data yet: the ei daemon has not run on this machine."
MIN_SHARE = 0.05  # values observed less than this share of the time are omitted
NOTABLE_CHANGE = 0.15  # mention the previous window when a share moved at least this much


@cache
def _conn() -> sqlite3.Connection:
    return db.connect(readonly=True)


def _ago(seconds: float) -> str:
    if seconds < 90:
        return f"{seconds:.0f}s ago"
    if seconds < 5400:
        return f"{seconds / 60:.0f} min ago"
    return f"{seconds / 3600:.1f} h ago"


@mcp.tool(annotations=READ_ONLY)
def current_observation() -> str:
    """What the user is visibly doing right now: activity, gaze, expression, posture, hands."""
    try:
        snap = queries.current_observation(_conn())
    except sqlite3.OperationalError:
        return NO_DATA
    if snap is None:
        return "No observations yet."
    if snap.facts.get("present") == ["false"]:
        return f"User not at the computer (observed {_ago(snap.age_s)})."
    parts = [
        f"{k}: {', '.join(snap.facts[k])}"
        for k in queries.ordered_keys(snap.facts)
        if k != "present"
    ]
    text = f"Observed {_ago(snap.age_s)}. " + "; ".join(parts) + "."
    return text + (f" Note: {snap.notes}" if snap.notes else "")


@mcp.tool(annotations=READ_ONLY)
def recent_behavior(minutes: int = 15) -> str:
    """How the user's visible behavior has broken down over the last N minutes (share of
    time per posture, expression, etc.), with notable changes versus the N minutes before."""
    minutes = max(1, min(minutes, 24 * 60))
    try:
        conn = _conn()
        s = queries.behavior_summary(conn, minutes, max_gap_s=settings_mod.load(conn).max_gap_s)
    except sqlite3.OperationalError:
        return NO_DATA
    if s.observed_s == 0:
        return f"No observations in the last {minutes} min."

    observed = f"{s.observed_s / 60:.0f} min" if s.observed_s >= 90 else f"{s.observed_s:.0f}s"
    lines = [f"Last {minutes} min ({observed} observed):"]
    for key in queries.ordered_keys(s.shares):
        if key == "present":
            continue
        values = []
        for value, share in s.shares[key].items():
            if share < MIN_SHARE:
                continue
            prev = s.previous.get(key, {}).get(value, 0.0) if s.previous else None
            moved = prev is not None and abs(share - prev) >= NOTABLE_CHANGE
            values.append(f"{value} {share:.0%}" + (f" (prev {prev:.0%})" if moved else ""))
        if values:
            lines.append(f"- {key}: {', '.join(values)}")
    if s.notes:
        lines.append("Notes: " + " | ".join(s.notes))
    return "\n".join(lines)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
