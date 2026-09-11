"""Unit tests for ChartCache — the broker's TTL/LRU chart-PNG store.

Time is injected so expiry is deterministic (no sleeping).
"""

from chart_cache import ChartCache


class FakeClock:
    """A controllable monotonic clock: t starts at 0, advance() moves it."""

    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


def test_put_returns_prefixed_id_and_get_roundtrips():
    c = ChartCache(ttl_seconds=100, max_entries=8, now=FakeClock())
    cid = c.put(b"\x89PNG-bytes")
    assert cid.startswith("c_")
    assert c.get(cid) == b"\x89PNG-bytes"


def test_ids_are_unique_per_put():
    c = ChartCache(now=FakeClock())
    ids = {c.put(b"x") for _ in range(50)}
    assert len(ids) == 50


def test_unknown_id_returns_none():
    c = ChartCache(now=FakeClock())
    assert c.get("c_does-not-exist") is None


def test_entry_expires_after_ttl():
    clock = FakeClock()
    c = ChartCache(ttl_seconds=60, max_entries=8, now=clock)
    cid = c.put(b"png")
    clock.advance(59)
    assert c.get(cid) == b"png"      # still inside the window
    clock.advance(1)                 # now at exactly ttl -> expired (>=)
    assert c.get(cid) is None


def test_max_entries_evicts_oldest():
    c = ChartCache(ttl_seconds=1000, max_entries=3, now=FakeClock())
    a, b, d = c.put(b"a"), c.put(b"b"), c.put(b"d")
    e = c.put(b"e")                  # over cap -> evict oldest (a)
    assert c.get(a) is None
    assert c.get(b) == b"b"
    assert c.get(d) == b"d"
    assert c.get(e) == b"e"


def test_expired_entries_are_purged_on_put():
    clock = FakeClock()
    c = ChartCache(ttl_seconds=10, max_entries=100, now=clock)
    old = c.put(b"old")
    clock.advance(11)
    c.put(b"new")                    # put() purges expired first
    assert c.get(old) is None
