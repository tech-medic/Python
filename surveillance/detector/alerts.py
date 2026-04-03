"""Telegram alert sender."""

import logging
import time

import requests

log = logging.getLogger("alerts")


class TelegramAlerter:
    def __init__(
        self,
        token: str,
        chat_id: str,
        enabled: bool = False,
        cooldown: int = 30,
        include_snapshot: bool = True,
    ):
        self.token = token
        self.chat_id = chat_id
        self.enabled = enabled
        self.cooldown = cooldown
        self.include_snapshot = include_snapshot
        self._last_alert = 0
        self._api_base = f"https://api.telegram.org/bot{token}"

    def send_alert(self, cls_name: str, confidence: float, snapshot_path: str | None = None):
        if not self.enabled:
            return

        now = time.time()
        if now - self._last_alert < self.cooldown:
            return

        self._last_alert = now
        caption = f"🚨 *{cls_name.upper()}* detected (confidence: {confidence:.1%})"

        try:
            if self.include_snapshot and snapshot_path:
                with open(snapshot_path, "rb") as photo:
                    resp = requests.post(
                        f"{self._api_base}/sendPhoto",
                        data={"chat_id": self.chat_id, "caption": caption, "parse_mode": "Markdown"},
                        files={"photo": photo},
                        timeout=15,
                    )
            else:
                resp = requests.post(
                    f"{self._api_base}/sendMessage",
                    data={"chat_id": self.chat_id, "text": caption, "parse_mode": "Markdown"},
                    timeout=15,
                )
            if resp.ok:
                log.info("Telegram alert sent for %s", cls_name)
            else:
                log.warning("Telegram API error: %s", resp.text)
        except requests.RequestException as e:
            log.warning("Telegram alert failed: %s", e)
