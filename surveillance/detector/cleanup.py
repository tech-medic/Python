"""Automated storage cleanup for old clips and snapshots."""

import logging
import threading
import time
from pathlib import Path

log = logging.getLogger("cleanup")


class StorageCleaner:
    def __init__(self, config: dict):
        self.clips_dir = Path(config.get("clips_dir", "/app/data/clips"))
        self.snapshots_dir = Path(config.get("snapshots_dir", "/app/data/snapshots"))
        self.retention_days = config.get("retention_days", 7)
        self.interval_hours = config.get("cleanup_interval_hours", 6)
        self._thread = None
        self._running = False

    def start(self):
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        log.info(
            "Storage cleaner started (retention=%dd, interval=%dh)",
            self.retention_days, self.interval_hours,
        )

    def stop(self):
        self._running = False

    def _loop(self):
        while self._running:
            try:
                self._clean()
            except Exception as e:
                log.error("Cleanup error: %s", e)
            # Sleep in small increments so we can exit promptly
            for _ in range(int(self.interval_hours * 3600)):
                if not self._running:
                    return
                time.sleep(1)

    def _clean(self):
        cutoff = time.time() - (self.retention_days * 86400)
        removed = 0
        for d in (self.clips_dir, self.snapshots_dir):
            if not d.exists():
                continue
            for f in d.iterdir():
                if f.is_file() and f.stat().st_mtime < cutoff:
                    f.unlink()
                    removed += 1
        if removed:
            log.info("Cleaned up %d old files", removed)
