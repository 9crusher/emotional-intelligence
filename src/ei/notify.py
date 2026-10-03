"""OS notifications for `os_notify` triggers."""

from __future__ import annotations

import logging
import subprocess
import sys

log = logging.getLogger("ei.notify")

TITLE = "emotional-intelligence"


def _applescript_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def os_notify(message: str) -> None:
    """Fire-and-forget desktop notification. Never blocks the daemon loop, never raises."""
    if sys.platform != "darwin":
        log.warning("os_notify is only implemented on macOS; message: %s", message)
        return
    script = (
        f"display notification {_applescript_str(message)} with title {_applescript_str(TITLE)}"
    )
    try:
        subprocess.Popen(
            ["osascript", "-e", script],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        log.exception("os_notify failed")
