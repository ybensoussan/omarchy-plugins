"""What you use: a frecency score per item, and the items themselves so the
home view can show recent ones without asking every source again.

~/.local/state/omarchy-launcher/history.json
"""

from __future__ import annotations

import json
import math
import os
import threading
import time

from .util import STATE

HALF_LIFE = 7 * 24 * 3600   # a use counts half as much a week later
KEEP = 400
PRIVATE = ("bitwarden:", "onepassword:", "clipboard:")


class History:
    def __init__(self, path=STATE / "history.json"):
        self.path = path
        self._lock = threading.Lock()
        self.entries: dict[str, dict] = {}
        self._load()

    def _load(self) -> None:
        try:
            with open(self.path, encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                # 1Password items never belong on disk (older versions wrote them).
                self.entries = {k: v for k, v in data.items()
                                if isinstance(v, dict) and not k.startswith(PRIVATE)}
        except (OSError, ValueError):
            self.entries = {}

    def _save(self) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = f"{self.path}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.entries, f, ensure_ascii=False)
        os.replace(tmp, self.path)

    def record(self, item: dict, query: str = "") -> None:
        """Count one use of an item; remember what it looked like."""
        if item["id"].startswith(PRIVATE):
            return
        now = time.time()
        with self._lock:
            e = self.entries.get(item["id"], {})
            e["score"] = self._decayed(e, now) + 1.0
            e["at"] = now
            # Private fields too, so a recent item can run again before its
            # source has listed it; long ones (a manual section) are left out.
            e["item"] = {k: v for k, v in item.items()
                         if k not in ("score", "section") and not (isinstance(v, str) and len(v) > 2000)}
            if query:
                # The search that found it, so typing it again ranks it first.
                qs = [q for q in e.get("queries", []) if q != query][:4]
                e["queries"] = [query] + qs
            self.entries[item["id"]] = e
            if len(self.entries) > KEEP:
                ranked = sorted(self.entries.items(), key=lambda kv: self._decayed(kv[1], now))
                for k, _ in ranked[: len(self.entries) - KEEP]:
                    del self.entries[k]
            self._save()

    @staticmethod
    def _decayed(e: dict, now: float) -> float:
        if not e:
            return 0.0
        age = max(0.0, now - float(e.get("at", now)))
        return float(e.get("score", 0)) * math.pow(0.5, age / HALF_LIFE)

    def boost(self, item_id: str, query: str = "") -> float:
        """Extra ranking points for an item: 0 for never used, up to ~250."""
        e = self.entries.get(item_id)
        if not e:
            return 0.0
        b = min(200.0, 60.0 * math.log1p(self._decayed(e, time.time())))
        if query and query in e.get("queries", []):
            b += 150.0
        return b

    def recent(self, limit: int = 8) -> list[dict]:
        now = time.time()
        ranked = sorted(self.entries.values(), key=lambda e: self._decayed(e, now), reverse=True)
        return [e["item"] for e in ranked[:limit] if isinstance(e.get("item"), dict)]

    def snapshot(self, item_id: str) -> dict | None:
        e = self.entries.get(item_id)
        return dict(e["item"]) if e and isinstance(e.get("item"), dict) else None

    def forget(self, item_id: str) -> None:
        with self._lock:
            if self.entries.pop(item_id, None) is not None:
                self._save()

    def clear(self) -> None:
        with self._lock:
            self.entries = {}
            self._save()
