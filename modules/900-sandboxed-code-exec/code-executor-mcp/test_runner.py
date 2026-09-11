from sandbox_runner import cap_output, read_chart, MAX_OUTPUT_BYTES, MAX_IMAGE_BYTES


def test_short_output_is_unchanged():
    assert cap_output("hello") == "hello"


def test_long_output_is_truncated_with_marker():
    big = "x" * (MAX_OUTPUT_BYTES + 500)
    out = cap_output(big)
    assert len(out.encode("utf-8")) <= MAX_OUTPUT_BYTES + 100  # marker slack
    assert out.endswith("...[truncated]")


def test_none_becomes_empty_string():
    assert cap_output(None) == ""


class _FakeFiles:
    """Stand-in for sandbox.files: canned exists()/read() for chart tests."""

    def __init__(self, present, data=b"", raise_on_read=False):
        self._present = present
        self._data = data
        self._raise = raise_on_read

    def exists(self, path, timeout=30):
        return self._present

    def read(self, path, timeout=60):
        if self._raise:
            raise RuntimeError("download boom")
        return self._data


class _FakeSandbox:
    def __init__(self, files):
        self.files = files


def test_read_chart_returns_bytes_when_present():
    sb = _FakeSandbox(_FakeFiles(present=True, data=b"\x89PNGdata"))
    assert read_chart(sb) == b"\x89PNGdata"


def test_read_chart_none_when_absent():
    sb = _FakeSandbox(_FakeFiles(present=False))
    assert read_chart(sb) is None


def test_read_chart_none_when_empty():
    sb = _FakeSandbox(_FakeFiles(present=True, data=b""))
    assert read_chart(sb) is None


def test_read_chart_none_when_oversized():
    sb = _FakeSandbox(_FakeFiles(present=True, data=b"x" * (MAX_IMAGE_BYTES + 1)))
    assert read_chart(sb) is None


def test_read_chart_never_raises_on_read_error():
    sb = _FakeSandbox(_FakeFiles(present=True, raise_on_read=True))
    assert read_chart(sb) is None
