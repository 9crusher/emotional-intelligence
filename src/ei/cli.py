"""`ei` CLI: inspect data, change settings and triggers, run one capture, print config."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

from ei import db, queries, triggers
from ei import settings as settings_mod

LAUNCHD_LABEL = "com.emotional-intelligence.daemon"


def cmd_status(_: argparse.Namespace) -> None:
    conn = db.connect()
    s = settings_mod.load(conn)
    snap = queries.current_observation(conn)
    count = conn.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
    print(f"db:           {db.default_db_path()}")
    print(f"paused:       {s.paused}   interval: {s.interval_s}s   model: {s.ollama_model}")
    print(f"observations: {count}")
    if snap:
        print(f"latest:       {queries.format_facts(snap.facts)} ({snap.age_s:.0f}s ago)")


def cmd_tail(args: argparse.Namespace) -> None:
    for r in reversed(queries.recent(db.connect(), args.n)):
        ts = datetime.fromtimestamp(r["ts"] / 1000).strftime("%H:%M:%S")
        note = f"  ({r['notes']})" if r["notes"] else ""
        print(f"{ts} {r['latency_ms'] or 0:>5}ms  {queries.format_facts(r['facts'])}{note}")


def cmd_settings(args: argparse.Namespace) -> None:
    conn = db.connect()
    if args.key is None:
        for k, v in settings_mod.as_dict(settings_mod.load(conn)).items():
            print(f"{k} = {v}")
    elif args.value is None:
        print(getattr(settings_mod.load(conn), args.key))
    else:
        settings_mod.set_value(conn, args.key, args.value)
        print(f"{args.key} = {getattr(settings_mod.load(conn), args.key)}")


def cmd_capture_once(args: argparse.Namespace) -> None:
    from ei.daemon import build_pipeline  # heavy imports only for this command

    conn = db.connect()
    s = settings_mod.load(conn)
    pipeline = build_pipeline(s, fake=args.fake)
    try:
        result = pipeline.tick(s)
    finally:
        pipeline.camera.close()
    if result.observation is None:
        print(f"not analyzed: {result.status}")
        return
    o = result.observation
    print(json.dumps({"facts": o.facts, "latency_ms": o.latency_ms, **o.payload}, indent=2))
    if args.save:
        db.insert_observation(conn, o)


def parse_duration(text: str) -> float:
    """'90' / '90s' / '10m' / '1.5h' -> seconds."""
    units = {"s": 1, "m": 60, "h": 3600}
    text = text.strip().lower()
    if text and text[-1] in units:
        return float(text[:-1]) * units[text[-1]]
    return float(text)


def format_duration(seconds: float) -> str:
    if seconds and seconds % 3600 == 0:
        return f"{seconds / 3600:g}h"
    if seconds and seconds % 60 == 0:
        return f"{seconds / 60:g}m"
    return f"{seconds:g}s"


def parse_conditions(specs: list[str]) -> dict[str, list[str]]:
    """['activity=eating_drinking', 'expression=frowning,yawning'] -> {key: [values]}."""
    out: dict[str, list[str]] = {}
    for spec in specs:
        key, sep, values = spec.partition("=")
        if not sep or not key or not values:
            raise SystemExit(f"bad condition {spec!r}; expected key=value[,value...]")
        out.setdefault(key.strip(), []).extend(v.strip() for v in values.split(","))
    return out


def cmd_triggers(args: argparse.Namespace) -> None:
    conn = db.connect()
    if args.action == "add":
        trigger_id = triggers.add(
            conn,
            triggers.Trigger(
                name=args.name,
                conditions=parse_conditions(args.when),
                kind="sustained" if args.for_ else "on_enter",
                for_s=parse_duration(args.for_) if args.for_ else 0.0,
                cooldown_s=parse_duration(args.cooldown),
                action=args.notify,
                message=args.message,
            ),
        )
        print(f"added trigger {trigger_id}")
    elif args.action in {"enable", "disable", "rm"}:
        ok = (
            triggers.remove(conn, args.id)
            if args.action == "rm"
            else triggers.set_enabled(conn, args.id, args.action == "enable")
        )
        print(f"{args.action}: trigger {args.id}" if ok else f"no trigger {args.id}")
    else:
        for t in triggers.load(conn):
            when = " ".join(f"{k}={','.join(v)}" for k, v in t.conditions.items())
            timing = f"for {format_duration(t.for_s)}" if t.kind == "sustained" else "on enter"
            state = "" if t.enabled else "  [disabled]"
            print(
                f"{t.id:>3}  {t.name}: when {when} ({timing}, cooldown "
                f"{format_duration(t.cooldown_s)}) -> {t.action}: {t.message!r}{state}"
            )


def cmd_events(args: argparse.Namespace) -> None:
    for r in reversed(triggers.recent_events(db.connect(), args.n)):
        ts = datetime.fromtimestamp(r["ts"] / 1000).strftime("%H:%M:%S")
        status = "delivered" if r["delivered_at"] else "pending"
        name = r["trigger_name"] or "(deleted trigger)"
        print(f"{ts}  {r['action']:<9} {status:<9}  {name}: {r['message']}")


def cmd_vocab(_: argparse.Namespace) -> None:
    """Allowed values per fact key, so UIs can offer pickers without copying the lists."""
    from typing import get_args

    from ei.analyzers.ollama_vlm import BehaviorObservation

    vocab: dict[str, list[str]] = {"present": ["true", "false"]}
    for name, f in BehaviorObservation.model_fields.items():
        args = get_args(f.annotation)
        if args and all(isinstance(a, str) for a in args):  # Literal[...]
            vocab[name] = [a for a in args if a != "unclear"]
    vocab["activity"] = [*vocab["activity"], "away"]  # recorded when no one is present
    print(json.dumps(vocab))


def cmd_hook_config(_: argparse.Namespace) -> None:
    exe = shutil.which("ei-hook") or str(Path(sys.executable).parent / "ei-hook")
    hook = {"hooks": [{"type": "command", "command": exe, "timeout": 5}]}
    print(
        json.dumps(
            {"hooks": {"PostToolUse": [{"matcher": "*", **hook}], "UserPromptSubmit": [hook]}},
            indent=2,
        )
    )


def cmd_launchd(_: argparse.Namespace) -> None:
    exe = shutil.which("ei-daemon") or str(Path(sys.executable).parent / "ei-daemon")
    log = Path.home() / "Library" / "Logs" / "emotional-intelligence.log"
    print(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key><array><string>{exe}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>{log}</string>
  <key>StandardErrorPath</key><string>{log}</string>
</dict>
</plist>""")


def main() -> None:
    parser = argparse.ArgumentParser(prog="ei")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="show settings summary and latest observation").set_defaults(
        func=cmd_status
    )

    p = sub.add_parser("tail", help="show recent observations")
    p.add_argument("-n", type=int, default=20)
    p.set_defaults(func=cmd_tail)

    p = sub.add_parser("settings", help="list, get, or set a setting")
    p.add_argument("key", nargs="?")
    p.add_argument("value", nargs="?")
    p.set_defaults(func=cmd_settings)

    p = sub.add_parser("capture-once", help="run one capture/gate/analyze pass and print it")
    p.add_argument("--fake", action="store_true", help="fake camera + analyzer")
    p.add_argument("--save", action="store_true", help="also write the observation to the db")
    p.set_defaults(func=cmd_capture_once)

    sub.add_parser("launchd", help=f"print a LaunchAgent plist ({LAUNCHD_LABEL})").set_defaults(
        func=cmd_launchd
    )

    p = sub.add_parser("triggers", help="list, add, enable, disable, or remove triggers")
    tsub = p.add_subparsers(dest="action")
    p.set_defaults(func=cmd_triggers, action="list")
    tsub.add_parser("list")
    a = tsub.add_parser(
        "add",
        help="add a trigger",
        description="Fires when every --when condition matches the latest observation. "
        "Without --for it fires on entering that state; with --for, once the state has "
        "lasted that long.",
    )
    a.add_argument("name")
    a.add_argument("--when", action="append", required=True, metavar="KEY=VALUE[,VALUE]",
                   help="e.g. activity=eating_drinking (repeatable; all must match)")  # fmt: skip
    a.add_argument("--for", dest="for_", metavar="DURATION", help="e.g. 10m (sustained)")
    a.add_argument("--cooldown", default="0", metavar="DURATION", help="e.g. 30m")
    a.add_argument("--notify", choices=triggers.ACTIONS, default="agent",
                   help="agent: tell the agent via the Claude Code hook; os_notify: desktop "
                   "notification")  # fmt: skip
    a.add_argument("--message", required=True)
    for name in ("enable", "disable", "rm"):
        tsub.add_parser(name).add_argument("id", type=int)

    p = sub.add_parser("events", help="show recently fired trigger events")
    p.add_argument("-n", type=int, default=20)
    p.set_defaults(func=cmd_events)

    sub.add_parser("vocab", help="print allowed values per fact key as JSON").set_defaults(
        func=cmd_vocab
    )

    sub.add_parser(
        "hook-config", help="print the Claude Code settings snippet that registers ei-hook"
    ).set_defaults(func=cmd_hook_config)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
