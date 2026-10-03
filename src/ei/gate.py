"""Cheap pre-filter run on every frame so the expensive analyzer only sees frames worth
analyzing: a person is present, and something meaningfully changed (or it's been a while).

When no one is present the gate asks for an "away" record on leaving, then once per
`max_skip_s` while away, so time away is logged without ever running the model.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import cv2
import numpy as np

from ei.capture import Frame, downscale

_THUMB = (64, 48)


class PresenceDetector(Protocol):
    def has_face(self, frame: Frame) -> bool: ...


class YuNetPresence:
    """OpenCV's YuNet face detector (MIT, ~230KB ONNX, vendored in ei/models).

    Runs on a downscaled copy of the frame: a few ms per call on Apple Silicon.
    """

    MODEL = Path(__file__).parent / "models" / "face_detection_yunet_2023mar.onnx"
    DETECT_WIDTH = 320

    def __init__(self, score_threshold: float = 0.7) -> None:
        self._detector = cv2.FaceDetectorYN.create(
            str(self.MODEL), "", (self.DETECT_WIDTH, self.DETECT_WIDTH), score_threshold
        )

    def has_face(self, frame: Frame) -> bool:
        small = downscale(frame, self.DETECT_WIDTH)
        h, w = small.shape[:2]
        self._detector.setInputSize((w, h))
        _, faces = self._detector.detect(small)
        return faces is not None and len(faces) > 0


@dataclass(slots=True)
class Decision:
    analyze: bool
    # analyze=True:  'first' | 'returned' | 'changed' | 'stale'
    # analyze=False: 'away' (record absence) | 'no_face' | 'unchanged'
    reason: str
    diff: float | None = None


class Gate:
    def __init__(self, presence: PresenceDetector | None = None) -> None:
        self.presence = presence
        self._last_thumb: np.ndarray | None = None
        self._last_analyzed_s: float | None = None
        self._away = False

    def check(
        self,
        frame: Frame,
        now_s: float,
        *,
        require_face: bool,
        change_threshold: float,
        max_skip_s: float,
    ) -> Decision:
        if require_face and self.presence is not None and not self.presence.has_face(frame):
            heartbeat_due = (
                self._last_analyzed_s is None or now_s - self._last_analyzed_s >= max_skip_s
            )
            if not self._away or heartbeat_due:
                self._away = True
                self._last_thumb = None
                self._last_analyzed_s = now_s
                return Decision(False, "away")
            return Decision(False, "no_face")

        thumb = _thumbnail(frame)
        if self._away:
            self._away = False
            return self._accept(thumb, now_s, "returned", None)
        if self._last_thumb is None or self._last_analyzed_s is None:
            return self._accept(thumb, now_s, "first", None)

        diff = float(np.mean(cv2.absdiff(thumb, self._last_thumb)))
        if diff >= change_threshold:
            return self._accept(thumb, now_s, "changed", diff)
        if now_s - self._last_analyzed_s >= max_skip_s:
            return self._accept(thumb, now_s, "stale", diff)
        return Decision(False, "unchanged", diff)

    def _accept(self, thumb: np.ndarray, now_s: float, reason: str, diff: float | None) -> Decision:
        self._last_thumb = thumb
        self._last_analyzed_s = now_s
        return Decision(True, reason, diff)


def _thumbnail(frame: Frame) -> np.ndarray:
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
    return cv2.resize(gray, _THUMB, interpolation=cv2.INTER_AREA)
