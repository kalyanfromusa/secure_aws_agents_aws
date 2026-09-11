"""In-memory, TTL-bounded cache for chart PNGs produced in the sandbox.

Why this exists: the chart image must NOT travel through the LLM. run_python
returns only a short `chart_id`; the raw PNG lives here in the broker, and the
agent fetches it out-of-band via GET /chart/{id} (see server.py). Bytes in →
opaque id out → bytes back on a separate hop.

Bounded two ways so a long-running broker can't grow without limit:
  * TTL — an entry expires TTL_SECONDS after it was stored (a chart is only
    needed for the seconds between the tool returning and the UI rendering it).
  * max entries — the oldest entry is evicted once the cap is hit.

Single-process, single-replica broker (replicas: 1), so a plain dict + lock is
enough; there's no cross-pod sharing to worry about.
"""

import os
import secrets
import threading
from collections import OrderedDict

TTL_SECONDS = int(os.environ.get("CHART_CACHE_TTL", "300"))
MAX_ENTRIES = int(os.environ.get("CHART_CACHE_MAX", "64"))


class ChartCache:
    """Thread-safe TTL + LRU-ish cache of chart_id -> (png_bytes, expires_at).

    `now` is injected (a zero-arg callable returning a monotonic-ish float) so
    tests can drive expiry deterministically without sleeping. Defaults to
    time.monotonic in production.
    """

    def __init__(self, ttl_seconds=TTL_SECONDS, max_entries=MAX_ENTRIES, now=None):
        self._ttl = ttl_seconds
        self._max = max_entries
        if now is None:
            import time
            now = time.monotonic
        self._now = now
        self._lock = threading.Lock()
        self._store: "OrderedDict[str, tuple[bytes, float]]" = OrderedDict()

    def put(self, png: bytes) -> str:
        """Store PNG bytes, return a fresh opaque chart_id."""
        chart_id = "c_" + secrets.token_urlsafe(12)
        with self._lock:
            self._purge_expired_locked()
            while len(self._store) >= self._max:
                self._store.popitem(last=False)  # evict oldest
            self._store[chart_id] = (png, self._now() + self._ttl)
        return chart_id

    def get(self, chart_id: str) -> bytes | None:
        """Return the PNG bytes for chart_id, or None if unknown/expired."""
        with self._lock:
            entry = self._store.get(chart_id)
            if entry is None:
                return None
            png, expires_at = entry
            if self._now() >= expires_at:
                self._store.pop(chart_id, None)
                return None
            return png

    def _purge_expired_locked(self) -> None:
        now = self._now()
        expired = [k for k, (_, exp) in self._store.items() if now >= exp]
        for k in expired:
            self._store.pop(k, None)
