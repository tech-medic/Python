"""Video clip recorder with pre-event buffer."""

import logging
import threading
import time
from collections import deque
from pathlib import Path

import cv2

log = logging.getLogger("recorder")


class ClipRecorder:
    def __init__(self, config: dict):
        rec = config.get("recording", {})
        cam = config.get("camera", {})

        self.clip_duration = rec.get("clip_duration_sec", 10)
        self.pre_buffer_sec = rec.get("pre_buffer_sec", 2)
        self.clips_dir = Path(config.get("storage", {}).get("clips_dir", "/app/data/clips"))
        self.clips_dir.mkdir(parents=True, exist_ok=True)

        self.fps = cam.get("fps", 15)
        self.width = cam.get("width", 1280)
        self.height = cam.get("height", 720)

        buffer_size = int(self.fps * self.pre_buffer_sec)
        self._buffer = deque(maxlen=max(buffer_size, 1))
        self._lock = threading.Lock()
        self._recording = False

    def feed_frame(self, frame):
        """Add frame to the rolling pre-event buffer."""
        with self._lock:
            self._buffer.append(frame.copy())

    def start_clip(self, trigger_frame, ts_str: str, label: str) -> str | None:
        """Start recording a clip in a background thread. Returns clip path."""
        if self._recording:
            return None

        with self._lock:
            pre_frames = list(self._buffer)

        clip_name = f"{ts_str}_{label}.mp4"
        clip_path = str(self.clips_dir / clip_name)

        self._recording = True
        t = threading.Thread(
            target=self._record_clip,
            args=(pre_frames, clip_path),
            daemon=True,
        )
        t.start()
        return clip_path

    def _record_clip(self, pre_frames: list, clip_path: str):
        try:
            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            writer = cv2.VideoWriter(clip_path, fourcc, self.fps, (self.width, self.height))

            if not writer.isOpened():
                log.error("Failed to open video writer for %s", clip_path)
                return

            # Write pre-buffer frames
            for f in pre_frames:
                if f.shape[1] != self.width or f.shape[0] != self.height:
                    f = cv2.resize(f, (self.width, self.height))
                writer.write(f)

            # Record for clip_duration seconds
            total_frames = int(self.fps * self.clip_duration)
            written = len(pre_frames)
            deadline = time.time() + self.clip_duration

            while written < total_frames and time.time() < deadline:
                with self._lock:
                    if self._buffer:
                        frame = self._buffer[-1].copy()
                    else:
                        time.sleep(1 / max(self.fps, 1))
                        continue

                if frame.shape[1] != self.width or frame.shape[0] != self.height:
                    frame = cv2.resize(frame, (self.width, self.height))
                writer.write(frame)
                written += 1
                time.sleep(1 / max(self.fps, 1))

            writer.release()
            log.info("Clip saved: %s (%d frames)", clip_path, written)
        except Exception as e:
            log.error("Clip recording failed: %s", e)
        finally:
            self._recording = False

    def stop(self):
        self._recording = False
