"""Motion detection pre-filter using frame differencing."""

import time

import cv2
import numpy as np


class MotionDetector:
    def __init__(self, config: dict):
        self.sensitivity = config.get("sensitivity", 25)
        self.min_area = config.get("min_area", 3000)
        self.blur_kernel = config.get("blur_kernel", 21)
        self.cooldown = config.get("cooldown_sec", 2)

        self._prev_gray = None
        self._last_trigger = 0

    def detect(self, frame: np.ndarray) -> bool:
        """Return True if motion is detected in the frame."""
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        gray = cv2.GaussianBlur(gray, (self.blur_kernel, self.blur_kernel), 0)

        if self._prev_gray is None:
            self._prev_gray = gray
            return False

        delta = cv2.absdiff(self._prev_gray, gray)
        self._prev_gray = gray

        thresh = cv2.threshold(delta, self.sensitivity, 255, cv2.THRESH_BINARY)[1]
        thresh = cv2.dilate(thresh, None, iterations=2)

        contours, _ = cv2.findContours(
            thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )

        motion = any(cv2.contourArea(c) >= self.min_area for c in contours)

        if motion:
            now = time.time()
            if now - self._last_trigger < self.cooldown:
                return False
            self._last_trigger = now
            return True

        return False
