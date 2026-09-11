"""Unit tests for server.py's SSE mapper + chart-fetch helpers.

Pure-dict logic where possible: no strands or live network. server.py does
`from agent import ...` (pulls in strands, not installed for unit tests), so we
stub `agent`. httpx IS installed; fetch_chart_event is tested with a monkey-
patched AsyncClient so no socket is opened.
"""

import sys
import types

# Stub the agent module server.py imports at load time.
sys.modules.setdefault(
    "agent",
    types.SimpleNamespace(build_session_agent=lambda *a, **k: (None, []), langfuse=None),
)

import asyncio
import json

import server
from server import sse_events_for, chart_ids_from_event, fetch_chart_event


def _parse(lines):
    out = []
    for line in lines:
        assert line.startswith("data: ") and line.endswith("\n\n")
        out.append(json.loads(line[len("data: "):]))
    return out


def run(coro):
    return asyncio.run(coro)


# --- sse_events_for: unchanged behavior still holds -------------------------

def test_text_delta_maps_to_token():
    assert _parse(sse_events_for({"data": "Hello"})) == [{"token": "Hello"}]


def test_tool_result_maps_to_status_event():
    event = {"message": {"role": "user", "content": [
        {"toolResult": {"toolUseId": "t1", "status": "success"}}
    ]}}
    assert _parse(sse_events_for(event)) == [{"tool_result": {"id": "t1", "status": "success"}}]


# --- chart_ids_from_event ---------------------------------------------------

def _tool_result_event(content):
    return {"message": {"role": "user", "content": [{"toolResult": {
        "toolUseId": "t1", "status": "success", "content": content,
    }}]}}


def test_chart_id_from_json_content_block():
    ev = _tool_result_event([{"json": {"stdout": "ok", "chart_id": "c_abc"}}])
    assert chart_ids_from_event(ev) == ["c_abc"]


def test_chart_id_from_text_json_content_block():
    ev = _tool_result_event([{"text": json.dumps({"stdout": "ok", "chart_id": "c_xyz"})}])
    assert chart_ids_from_event(ev) == ["c_xyz"]


def test_no_chart_id_returns_empty():
    ev = _tool_result_event([{"json": {"stdout": "ok", "row_count": 5}}])
    assert chart_ids_from_event(ev) == []


def test_chart_id_ignores_non_json_text():
    ev = _tool_result_event([{"text": "just some stdout, not json"}])
    assert chart_ids_from_event(ev) == []


def test_chart_id_non_tool_result_event_is_empty():
    assert chart_ids_from_event({"data": "hi"}) == []
    assert chart_ids_from_event({"message": {"role": "assistant", "content": []}}) == []


def test_chart_id_malformed_never_raises():
    assert chart_ids_from_event({"message": "nope"}) == []
    assert chart_ids_from_event({"message": {"role": "user", "content": "x"}}) == []


# --- fetch_chart_event ------------------------------------------------------

class _FakeResp:
    def __init__(self, content=b"", status=200):
        self.content = content
        self._status = status

    def raise_for_status(self):
        if self._status >= 400:
            raise RuntimeError(f"HTTP {self._status}")


class _FakeClient:
    def __init__(self, resp=None, raise_exc=None):
        self._resp = resp
        self._raise = raise_exc

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def get(self, url):
        if self._raise:
            raise self._raise
        return self._resp


def test_fetch_chart_event_emits_base64_image(monkeypatch):
    monkeypatch.setattr(server.httpx, "AsyncClient",
                        lambda *a, **k: _FakeClient(resp=_FakeResp(content=b"ABC")))
    line = run(fetch_chart_event("c_abc"))
    [payload] = _parse([line])
    # base64("ABC") == "QUJD"
    assert payload == {"image": {"base64": "QUJD", "mime": "image/png"}}


def test_fetch_chart_event_returns_none_on_http_error(monkeypatch):
    monkeypatch.setattr(server.httpx, "AsyncClient",
                        lambda *a, **k: _FakeClient(resp=_FakeResp(status=404)))
    assert run(fetch_chart_event("c_missing")) is None


def test_fetch_chart_event_returns_none_on_connect_error(monkeypatch):
    monkeypatch.setattr(server.httpx, "AsyncClient",
                        lambda *a, **k: _FakeClient(raise_exc=RuntimeError("boom")))
    assert run(fetch_chart_event("c_x")) is None
