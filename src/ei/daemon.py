"""The daemon: the only process that touches the camera, the models, or the DB write path.

Loop: capture -> gate -> analyze -> write. Settings live in SQLite; the loop polls
`PRAGMA data_version` (which changes only when *another* connection commits) and
reloads, so changes from the CLI or desktop app apply within ~1s without a restart.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
import os
import signal
import sqlite3
import time
from collections.abc import Callable
from dataclasses import dataclass

import numpy as np

from ei import db, queries, triggers
from ei import settings as settings_mod
from ei.analyzers.base import Analyzer
from ei.capture import Camera, FakeCamera, OpenCVCamera
from ei.gate import Gate, YuNetPresence
from ei.notify import os_notify
from ei.settings import Settings

log = logging.getLogger("ei.daemon")

POLL_S = 1.0
PRUNE_EVERY_S = 3600.0


@dataclass(slots=True)
class TickResult:
    status: str  # 'analyzed' | 'away' | 'no_frame' | gate skip reason ('no_face', 'unchanged')
    observation: db.Observation | None = None


class Pipeline:
    def __init__(self, camera: Camera, gate: Gate, analyzer: Analyzer) -> None:
        self.camera = camera
        self.gate = gate
        self.analyzer = analyzer

    def tick(self, s: Settings, now_s: float | None = None) -> TickResult:
        """One capture/gate/analyze pass. Blocking — the daemon runs it in a thread.
        The frame goes out of scope when this returns; it is never persisted."""
        frame = self.camera.grab()
        if frame is None:
            return TickResult("no_frame")
        decision = self.gate.check(
            frame,
            time.monotonic() if now_s is None else now_s,
            require_face=s.require_face,
            change_threshold=s.change_threshold,
            max_skip_s=s.max_skip_s,
        )
        if decision.reason == "away":
            away = db.Observation(
                analyzer=self.analyzer.name,
                facts={"present": ["false"], "activity": ["away"]},
                payload={"gate": "away"},
            )
            return TickResult("away", away)
        if not decision.analyze:
            return TickResult(decision.reason)
        obs = self.analyzer.analyze(frame)
        obs.payload.setdefault("gate", decision.reason)
        return TickResult("analyzed", obs)


def build_pipeline(s: Settings, *, fake: bool) -> Pipeline:
    if fake:
        from ei.analyzers.fake import FakeAnalyzer

        return Pipeline(FakeCamera(_noise_frames()), Gate(presence=None), FakeAnalyzer())

    from ei.analyzers.ollama_vlm import OllamaVLMAnalyzer

    return Pipeline(
        OpenCVCamera(s.camera_index, keep_open=s.keep_camera_open),
        Gate(presence=YuNetPresence()),
        OllamaVLMAnalyzer(
            s.ollama_model, keep_alive=s.ollama_keep_alive, image_max_side=s.image_max_side
        ),
    )


def _noise_frames(n: int = 4) -> list[np.ndarray]:
    rng = np.random.default_rng(0)
    return [rng.integers(0, 255, (480, 640, 3), dtype=np.uint8) for _ in range(n)]


# Settings whose change requires rebuilding the camera/analyzer.
_REBUILD_KEYS = (
    "camera_index",
    "keep_camera_open",
    "ollama_model",
    "ollama_keep_alive",
    "image_max_side",
)


class Daemon:
    def __init__(
        self,
        conn: sqlite3.Connection,
        *,
        fake: bool = False,
        notifier: Callable[[str], None] = os_notify,
    ) -> None:
        self.conn = conn
        self.fake = fake
        self.notifier = notifier
        self.settings = settings_mod.load(conn)
        self.pipeline = build_pipeline(self.settings, fake=fake)
        self.engine = triggers.TriggerEngine(max_gap_s=self.settings.max_gap_s)
        self.engine.set_triggers(triggers.load(conn, enabled_only=True))
        # Latest known facts. Persist across ticks the gate skips as unchanged, so
        # sustained triggers keep counting while nothing new is being written.
        self.facts: db.Facts | None = None
        self._data_version = self._read_data_version()
        self._stop = asyncio.Event()
        # Set by the desktop app so its child daemon never outlives it (e.g. on a crash).
        self._parent_pid = os.getppid() if os.environ.get("EI_EXIT_WITH_PARENT") else None

    def stop(self) -> None:
        self._stop.set()

    async def run(self) -> None:
        log.info("daemon started (db=%s, fake=%s)", db.default_db_path(), self.fake)
        db.record_daemon_start(self.conn, os.getpid())
        last_tick = float("-inf")
        last_prune = float("-inf")
        capture_seen = self.settings.capture_requested_at
        while not self._stop.is_set():
            if self._parent_pid is not None and os.getppid() != self._parent_pid:
                log.info("parent process exited; stopping")
                break
            self._maybe_reload()
            now = time.monotonic()
            requested = self.settings.capture_requested_at > capture_seen
            capture_seen = self.settings.capture_requested_at
            due = not self.settings.paused and now - last_tick >= self.settings.interval_s
            if requested or due:
                last_tick = now
                await self._tick()
            if now - last_prune >= PRUNE_EVERY_S:
                last_prune = now
                if n := db.prune(self.conn, self.settings.retention_days):
                    log.info("pruned %d old observations", n)
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(self._stop.wait(), timeout=POLL_S)
        self.pipeline.camera.close()
        log.info("daemon stopped")

    async def _tick(self) -> None:
        try:
            result = await asyncio.to_thread(self.pipeline.tick, self.settings)
        except Exception as e:
            log.exception("tick failed")
            db.record_tick(self.conn, "error", f"{type(e).__name__}: {e}")
            return
        db.record_tick(self.conn, result.status)
        if result.observation is not None:
            db.insert_observation(self.conn, result.observation)
            o = result.observation
            self.facts = o.facts
            log.info("%s (%sms)", queries.format_facts(o.facts), o.latency_ms or 0)
        else:
            log.debug("skipped: %s", result.status)
        if result.status != "no_frame" and self.facts is not None:
            self._fire(self.engine.evaluate(self.facts, db.now_ms()))

    def _fire(self, fired: list[triggers.Trigger]) -> None:
        for t in fired:
            now = db.now_ms()
            if t.action == "os_notify":
                self.notifier(t.message)
                triggers.record_event(self.conn, t, now, delivered=True)
            else:
                triggers.record_event(self.conn, t, now)
            log.info("trigger fired: %s -> %s", t.name, t.action)

    def _read_data_version(self) -> int:
        return self.conn.execute("PRAGMA data_version").fetchone()[0]

    def _maybe_reload(self) -> None:
        version = self._read_data_version()
        if version == self._data_version:
            return
        self._data_version = version
        # Some other connection committed: settings and/or triggers may have changed.
        self.engine.set_triggers(triggers.load(self.conn, enabled_only=True))
        new = settings_mod.load(self.conn)
        if new == self.settings:
            return
        self.engine.max_gap_s = new.max_gap_s
        log.info("settings changed; reloading")
        if any(getattr(new, k) != getattr(self.settings, k) for k in _REBUILD_KEYS):
            self.pipeline.camera.close()
            self.pipeline = build_pipeline(new, fake=self.fake)
        self.settings = new


def main() -> None:
    parser = argparse.ArgumentParser(prog="ei-daemon", description=__doc__)
    parser.add_argument("--fake", action="store_true", help="fake camera + analyzer (no Ollama)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    asyncio.run(_amain(args.fake))


async def _amain(fake: bool) -> None:
    daemon = Daemon(db.connect(), fake=fake)
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, daemon.stop)
    await daemon.run()


if __name__ == "__main__":
    main()
