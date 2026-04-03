"""AI Surveillance Camera — Detector Service.

Captures webcam feed, runs motion detection + YOLOv8 object detection,
saves clips/snapshots, publishes events to Redis, sends Telegram alerts.
"""

import json
import logging
import os
import signal
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import cv2
import numpy as np
import psycopg2
import psycopg2.extras
import redis
import yaml
from ultralytics import YOLO

from motion import MotionDetector
from recorder import ClipRecorder
from alerts import TelegramAlerter
from cleanup import StorageCleaner

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("detector")

HEALTH_FILE = "/tmp/detector_alive"


def load_config(path: str = "/app/config/config.yaml") -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def init_db(dsn: str):
    """Create detection_events table if it doesn't exist."""
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS detection_events (
                id SERIAL PRIMARY KEY,
                timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                object_class VARCHAR(64) NOT NULL,
                confidence REAL NOT NULL,
                bbox_x1 INT, bbox_y1 INT, bbox_x2 INT, bbox_y2 INT,
                snapshot_path TEXT,
                clip_path TEXT,
                metadata JSONB DEFAULT '{}'
            );
        """)
        cur.execute("""
            CREATE INDEX IF NOT EXISTS idx_events_ts ON detection_events (timestamp DESC);
        """)
        cur.execute("""
            CREATE INDEX IF NOT EXISTS idx_events_class ON detection_events (object_class);
        """)
    conn.close()
    log.info("Database initialized")


def insert_event(dsn: str, event: dict):
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO detection_events
               (timestamp, object_class, confidence,
                bbox_x1, bbox_y1, bbox_x2, bbox_y2,
                snapshot_path, clip_path, metadata)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
            (
                event["timestamp"],
                event["object_class"],
                event["confidence"],
                *event["bbox"],
                event.get("snapshot_path"),
                event.get("clip_path"),
                json.dumps(event.get("metadata", {})),
            ),
        )
    conn.close()


class CameraCapture:
    """Manages OpenCV webcam capture with reconnection logic."""

    def __init__(self, config: dict):
        self.device = config["camera"].get("device", "/dev/video0")
        self.width = config["camera"].get("width", 1280)
        self.height = config["camera"].get("height", 720)
        self.fps = config["camera"].get("fps", 15)
        self.reconnect_delay = config["camera"].get("reconnect_delay_sec", 5)
        self.max_attempts = config["camera"].get("max_reconnect_attempts", 0)
        self.cap = None

    def open(self) -> bool:
        attempt = 0
        while True:
            attempt += 1
            log.info("Opening camera %s (attempt %d)", self.device, attempt)
            self.cap = cv2.VideoCapture(self.device, cv2.CAP_V4L2)
            if self.cap.isOpened():
                self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.width)
                self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.height)
                self.cap.set(cv2.CAP_PROP_FPS, self.fps)
                log.info(
                    "Camera opened: %dx%d @ %d fps",
                    int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
                    int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
                    int(self.cap.get(cv2.CAP_PROP_FPS)),
                )
                return True

            log.warning("Camera not available, retrying in %ds...", self.reconnect_delay)
            if self.max_attempts and attempt >= self.max_attempts:
                log.error("Max reconnect attempts reached")
                return False
            time.sleep(self.reconnect_delay)

    def read(self):
        if self.cap is None:
            return False, None
        return self.cap.read()

    def release(self):
        if self.cap:
            self.cap.release()
            self.cap = None


class DetectorPipeline:
    """Main detection loop orchestrator."""

    def __init__(self, config: dict):
        self.config = config
        self.running = False

        self.dsn = os.environ["DATABASE_URL"]
        self.redis_url = os.environ["REDIS_URL"]
        self.rdb = redis.Redis.from_url(self.redis_url)

        self.camera = CameraCapture(config)
        self.motion = MotionDetector(config.get("motion", {}))

        model_name = config["detection"].get("model", "yolov8n.pt")
        self.model = YOLO(model_name)
        self.conf_threshold = config["detection"].get("confidence_threshold", 0.45)
        self.alert_classes = set(config["detection"].get("alert_classes", ["person"]))
        self.input_size = config["detection"].get("input_size", 640)

        self.recorder = ClipRecorder(config)

        tg_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
        tg_chat = os.environ.get("TELEGRAM_CHAT_ID", "")
        tg_conf = config.get("alerts", {}).get("telegram", {})
        self.alerter = TelegramAlerter(
            token=tg_token,
            chat_id=tg_chat,
            enabled=tg_conf.get("enabled", False) and bool(tg_token and tg_chat),
            cooldown=tg_conf.get("cooldown_sec", 30),
            include_snapshot=tg_conf.get("include_snapshot", True),
        )

        self.cleaner = StorageCleaner(config.get("storage", {}))

        # Shared frame for MJPEG streaming
        self.latest_frame = None
        self.frame_lock = threading.Lock()

        # Stats
        self.start_time = None
        self.frame_count = 0
        self.detection_count = 0

    def publish_frame(self, frame: np.ndarray):
        """Publish latest frame for web MJPEG stream."""
        quality = self.config.get("web", {}).get("stream_quality", 60)
        _, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, quality])
        data = buf.tobytes()
        with self.frame_lock:
            self.latest_frame = data
        try:
            self.rdb.set("surveillance:latest_frame", data, ex=5)
        except redis.RedisError:
            pass

    def publish_event(self, event: dict):
        """Publish detection event to Redis and store in DB."""
        payload = json.dumps(event, default=str)
        try:
            self.rdb.publish("surveillance:events", payload)
        except redis.RedisError as e:
            log.warning("Redis publish failed: %s", e)
        try:
            insert_event(self.dsn, event)
        except Exception as e:
            log.error("DB insert failed: %s", e)

    def publish_stats(self):
        elapsed = time.time() - self.start_time if self.start_time else 1
        stats = {
            "fps": round(self.frame_count / max(elapsed, 1), 1),
            "uptime_sec": int(elapsed),
            "frame_count": self.frame_count,
            "detection_count": self.detection_count,
        }
        try:
            self.rdb.set("surveillance:stats", json.dumps(stats), ex=10)
        except redis.RedisError:
            pass

    def process_detections(self, frame: np.ndarray, annotated: np.ndarray, results):
        """Handle YOLO detection results."""
        now = datetime.now(timezone.utc)
        ts_str = now.strftime("%Y%m%d_%H%M%S")

        for result in results:
            for box in result.boxes:
                cls_id = int(box.cls[0])
                cls_name = result.names[cls_id]
                conf = float(box.conf[0])

                if conf < self.conf_threshold:
                    continue
                if cls_name not in self.alert_classes:
                    continue

                x1, y1, x2, y2 = map(int, box.xyxy[0])
                self.detection_count += 1

                snapshot_path = None
                clip_path = None

                # Save snapshot
                snap_dir = self.config["storage"]["snapshots_dir"]
                snap_name = f"{ts_str}_{cls_name}_{self.detection_count}.jpg"
                snapshot_path = str(Path(snap_dir) / snap_name)
                quality = self.config["recording"].get("snapshot_quality", 85)
                cv2.imwrite(
                    snapshot_path, annotated,
                    [cv2.IMWRITE_JPEG_QUALITY, quality],
                )

                # Start clip recording
                clip_path = self.recorder.start_clip(frame, ts_str, cls_name)

                event = {
                    "timestamp": now.isoformat(),
                    "object_class": cls_name,
                    "confidence": round(conf, 3),
                    "bbox": [x1, y1, x2, y2],
                    "snapshot_path": snapshot_path,
                    "clip_path": clip_path,
                    "metadata": {},
                }

                self.publish_event(event)

                log.info(
                    "Detected %s (%.2f) at [%d,%d,%d,%d]",
                    cls_name, conf, x1, y1, x2, y2,
                )

                # Telegram alert
                self.alerter.send_alert(cls_name, conf, snapshot_path)

    def run(self):
        self.running = True
        self.start_time = time.time()

        if not self.camera.open():
            log.error("Failed to open camera, exiting")
            sys.exit(1)

        # Start storage cleaner in background
        self.cleaner.start()

        log.info("Detector pipeline started")
        touch_health()

        stats_interval = 5
        last_stats = 0

        try:
            while self.running:
                ret, frame = self.camera.read()
                if not ret or frame is None:
                    log.warning("Frame read failed, attempting reconnect...")
                    self.camera.release()
                    if not self.camera.open():
                        log.error("Reconnect failed, exiting")
                        break
                    continue

                self.frame_count += 1
                self.recorder.feed_frame(frame)

                # Always publish frame for streaming
                annotated = frame.copy()
                self.publish_frame(annotated)

                # Motion detection as pre-filter
                if self.config.get("motion", {}).get("enabled", True):
                    if not self.motion.detect(frame):
                        # Update health and stats periodically
                        if time.time() - last_stats > stats_interval:
                            touch_health()
                            self.publish_stats()
                            last_stats = time.time()
                        continue

                # Run YOLO detection
                results = self.model(
                    frame,
                    conf=self.conf_threshold,
                    imgsz=self.input_size,
                    verbose=False,
                )

                # Draw detections on frame
                annotated = results[0].plot()
                self.publish_frame(annotated)

                # Process results
                self.process_detections(frame, annotated, results)

                # Periodic health/stats
                if time.time() - last_stats > stats_interval:
                    touch_health()
                    self.publish_stats()
                    last_stats = time.time()

        except KeyboardInterrupt:
            log.info("Interrupted")
        finally:
            self.stop()

    def stop(self):
        self.running = False
        self.camera.release()
        self.recorder.stop()
        self.cleaner.stop()
        remove_health()
        log.info("Detector pipeline stopped")


def touch_health():
    Path(HEALTH_FILE).touch()


def remove_health():
    try:
        Path(HEALTH_FILE).unlink(missing_ok=True)
    except OSError:
        pass


def main():
    config = load_config()
    dsn = os.environ["DATABASE_URL"]

    log.info("Initializing database...")
    init_db(dsn)

    pipeline = DetectorPipeline(config)

    def handle_signal(signum, _frame):
        log.info("Received signal %d, shutting down...", signum)
        pipeline.stop()
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    pipeline.run()


if __name__ == "__main__":
    main()
