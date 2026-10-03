from __future__ import annotations

from ei.capture import Frame
from ei.db import Facts, Observation

DEFAULT_FACTS: Facts = {
    "present": ["true"],
    "activity": ["working"],
    "gaze": ["screen"],
    "expression": ["neutral"],
    "head": ["upright"],
    "posture": ["upright"],
    "hands": ["keyboard"],
}


class FakeAnalyzer:
    """Deterministic analyzer for running the daemon without Ollama."""

    name = "behavior.vlm"

    def __init__(self, facts: Facts | None = None) -> None:
        self.facts = facts or DEFAULT_FACTS
        self.calls = 0

    def analyze(self, frame: Frame) -> Observation:
        self.calls += 1
        return Observation(
            analyzer=self.name,
            facts={k: list(v) for k, v in self.facts.items()},
            model="fake",
            latency_ms=0,
        )
