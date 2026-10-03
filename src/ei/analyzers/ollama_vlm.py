"""Describe observable behavior with a local vision-language model via Ollama.

The model reports what it sees — gaze, expression, head, posture, hands, activity —
using fixed vocabularies. It never judges emotion: interpretation is left to the agent,
which has the context (what you're working on, what just happened) to do it well.
"""

from __future__ import annotations

import ipaddress
import os
import time
from typing import Literal
from urllib.parse import urlparse

import ollama
from pydantic import BaseModel, Field

from ei.capture import Frame, downscale, encode_jpeg
from ei.db import Facts, Observation

ANALYZER_NAME = "behavior.vlm"


class BehaviorObservation(BaseModel):
    """Schema the model must fill. Passed to Ollama as `format=` for structured output.
    Field order matters: models fill fields in order, so `present` comes first. Every
    field offers "unclear" so the model is never forced to invent a detail."""

    present: bool = Field(description="Is a person actually visible in the frame?")
    activity: Literal[
        "working", "talking", "drinking", "eating", "on_phone", "stretching", "idle", "unclear",
    ]  # fmt: skip
    gaze: Literal["screen", "down", "away", "eyes_closed", "unclear"]
    expression: Literal[
        "neutral", "smiling", "laughing", "brow_furrowed", "frowning", "yawning",
        "lips_pressed", "mouth_open", "unclear",
    ]  # fmt: skip
    head: Literal["upright", "tilted", "resting_on_hand", "in_hands", "turned_away", "unclear"]
    posture: Literal["upright", "leaning_forward", "leaning_back", "slouched", "unclear"]
    hands: list[
        Literal[
            "keyboard", "mouse", "touching_face", "rubbing_eyes", "behind_head",
            "arms_crossed", "holding_object", "gesturing", "not_visible",
        ]
    ] = Field(description="Everything the hands are visibly doing")  # fmt: skip
    notes: str = Field(
        description="One short sentence for anything notable the fields above miss, else ''"
    )

    def to_facts(self) -> Facts:
        if not self.present:
            return {"present": ["false"], "activity": ["away"]}
        facts: Facts = {
            "present": ["true"],
            "activity": [self.activity],
            "gaze": [self.gaze],
            "expression": [self.expression],
            "head": [self.head],
            "posture": [self.posture],
            "hands": sorted(set(self.hands)) or ["not_visible"],
        }
        # "unclear" is the model abstaining; record nothing rather than a non-observation.
        return {k: v for k, v in facts.items() if v != ["unclear"]}


PROMPT = """Look at this webcam frame from a computer.
First decide whether a person is actually visible. If not, set present to false.

If a person is visible, describe only what you can directly see: their activity, where
they are looking, facial expression, head position, posture, and what their hands are
doing. Use "unclear" for anything you cannot see clearly; do not guess.

Report observable facts, not interpretations: say "brow_furrowed" or "smiling", never
an emotion, mood, or intent."""


def ensure_local_ollama_host() -> str:
    """Refuse to run against a non-loopback Ollama — frames must never leave the machine."""
    raw = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
    host = urlparse(raw if "://" in raw else f"http://{raw}").hostname or ""
    if host == "localhost":
        return raw
    try:
        if ipaddress.ip_address(host).is_loopback:
            return raw
    except ValueError:
        pass
    raise RuntimeError(f"OLLAMA_HOST={raw!r} is not loopback; refusing to send frames off-machine")


class OllamaVLMAnalyzer:
    name = ANALYZER_NAME

    def __init__(self, model: str, *, keep_alive: str = "10m", image_max_side: int = 512) -> None:
        self.model = model
        self.keep_alive = keep_alive
        self.image_max_side = image_max_side
        self._client = ollama.Client(host=ensure_local_ollama_host())

    def analyze(self, frame: Frame) -> Observation:
        image = encode_jpeg(downscale(frame, self.image_max_side))
        start = time.perf_counter()
        resp = self._client.chat(
            model=self.model,
            messages=[{"role": "user", "content": PROMPT, "images": [image]}],
            format=BehaviorObservation.model_json_schema(),
            options={"temperature": 0},
            keep_alive=self.keep_alive,
        )
        latency_ms = int((time.perf_counter() - start) * 1000)
        result = BehaviorObservation.model_validate_json(resp.message.content or "{}")
        return Observation(
            analyzer=self.name,
            facts=result.to_facts(),
            model=self.model,
            latency_ms=latency_ms,
            payload={"notes": result.notes.strip()} if result.notes.strip() else {},
        )
