"""Camera capture. Frames are BGR numpy arrays held in memory only — never written to disk."""

from __future__ import annotations

from collections.abc import Iterable, Iterator
from typing import Protocol

import cv2
import numpy as np

Frame = np.ndarray


class Camera(Protocol):
    def grab(self) -> Frame | None: ...
    def close(self) -> None: ...


class OpenCVCamera:
    """Webcam via OpenCV. With keep_open=False the device is opened per grab, so the
    camera light only flashes during capture."""

    # Auto-exposure needs a few frames to settle after the device opens.
    WARMUP_FRAMES = 5

    def __init__(self, index: int = 0, *, keep_open: bool = False) -> None:
        self.index = index
        self.keep_open = keep_open
        self._cap: cv2.VideoCapture | None = None

    def _open(self) -> cv2.VideoCapture:
        cap = cv2.VideoCapture(self.index)
        if not cap.isOpened():
            raise RuntimeError(
                f"could not open camera {self.index}; on macOS, grant camera access to the "
                "process running ei (System Settings > Privacy & Security > Camera)"
            )
        for _ in range(self.WARMUP_FRAMES):
            cap.read()
        return cap

    def grab(self) -> Frame | None:
        if self._cap is None:
            self._cap = self._open()
        ok, frame = self._cap.read()
        if not self.keep_open:
            self.close()
        return frame if ok else None

    def close(self) -> None:
        if self._cap is not None:
            self._cap.release()
            self._cap = None


class FakeCamera:
    """Replays a fixed sequence of frames (cycling). For running without a webcam."""

    def __init__(self, frames: Iterable[Frame]) -> None:
        self._frames = list(frames)
        self._it: Iterator[Frame] = iter(())

    def grab(self) -> Frame | None:
        if not self._frames:
            return None
        try:
            return next(self._it)
        except StopIteration:
            self._it = iter(self._frames)
            return next(self._it)

    def close(self) -> None:
        pass


def downscale(frame: Frame, max_side: int) -> Frame:
    h, w = frame.shape[:2]
    scale = max_side / max(h, w)
    if scale >= 1:
        return frame
    return cv2.resize(frame, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)


def encode_jpeg(frame: Frame, quality: int = 85) -> bytes:
    ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, quality])
    if not ok:
        raise RuntimeError("JPEG encode failed")
    return buf.tobytes()
