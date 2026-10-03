"""Analyzer protocol. An analyzer turns one in-memory frame into one Observation.

New signals (posture, a dedicated expression classifier, ...) are new analyzers.
"""

from __future__ import annotations

from typing import Protocol

from ei.capture import Frame
from ei.db import Observation


class Analyzer(Protocol):
    name: str

    def analyze(self, frame: Frame) -> Observation: ...
