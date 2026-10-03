"""`ei-hook`: Claude Code hook that delivers pending `agent` trigger events into the
session as additional context.

Register it for PostToolUse (delivers while the agent is working, at its next step) and
UserPromptSubmit (delivers alongside your next prompt). `ei hook-config` prints the
settings snippet.

Runs on every agent tool call, so it must be fast and must never break the agent: stdlib
only, no db creation, and any failure exits 0 silently.
"""

from __future__ import annotations

import json
import sys

from ei import db, settings, triggers

PREFIX = "[emotional-intelligence trigger]"


def build_output(hook_event: str, events: list[triggers.Event], now_ms: int) -> str | None:
    if not events:
        return None
    lines = [f"{PREFIX} {e.message} ({(now_ms - e.ts) / 1000:.0f}s ago)" for e in events]
    return json.dumps(
        {"hookSpecificOutput": {"hookEventName": hook_event, "additionalContext": "\n".join(lines)}}
    )


def run(stdin: str) -> str | None:
    try:
        hook_event = json.loads(stdin).get("hook_event_name") or "PostToolUse"
    except (ValueError, AttributeError):
        hook_event = "PostToolUse"
    path = db.default_db_path()
    if not path.exists():
        return None  # daemon never ran; don't create a db from a hook
    conn = db.connect(path)
    try:
        ttl_s = settings.load(conn).agent_event_ttl_s
        return build_output(hook_event, triggers.claim_agent_events(conn, ttl_s), db.now_ms())
    finally:
        conn.close()


def main() -> None:
    try:
        out = run(sys.stdin.read())
    except Exception:
        return  # never break the agent's turn over a nudge
    if out:
        print(out)


if __name__ == "__main__":
    main()
