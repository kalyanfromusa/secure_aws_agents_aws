"""HTTP wrapper so the Chainlit UI can POST queries to this agent.

The MCP server sits behind agentgateway, which authorizes each tool call by the
caller's Cognito persona. The UI forwards the user's Cognito access token as
`Authorization: Bearer`; we build a SESSION-SCOPED agent whose MCP client carries
that token, so tool calls run with the user's identity (see agent.py +
the persona-authz design). Each participant has their own pod, so this cache is
effectively single-user.
"""

import base64
import json
import os

import httpx
from fastapi import FastAPI, Header
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn

from agent import build_session_agent, langfuse

# The code-exec broker (module 900) caches chart PNGs and returns a short
# chart_id in the run_python result — the image never rides the LLM context.
# We fetch the bytes from the broker's /chart/{id} route (a plain HTTP endpoint
# NOT proxied by agentgateway, so we hit the broker Service directly) and
# re-stream them to the UI as a base64 `image` SSE event. Only labs that wire in
# the broker ever see a chart_id, so this is inert for every other lab.
CODE_EXEC_CHART_BASE_URL = os.environ.get(
    "CODE_EXEC_CHART_BASE_URL",
    "http://code-executor-mcp.default.svc.cluster.local:8080",
)


def _persona_from_token(access_token: str | None) -> str | None:
    """Extract the persona (first cognito:groups entry) from the Cognito access
    token, for Langfuse userId attribution. Best-effort: decode the JWT payload
    WITHOUT verifying the signature (agentgateway already verified it upstream;
    this is only for a trace label). Returns None if unavailable.
    """
    if not access_token:
        return None
    try:
        payload = access_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)  # pad to a multiple of 4
        claims = json.loads(base64.urlsafe_b64decode(payload))
        groups = claims.get("cognito:groups") or []
        return groups[0] if groups else claims.get("username")
    except Exception:
        return None


def sse_events_for(event: dict) -> list[str]:
    """Map one Strands stream_async event to zero-or-more SSE lines.

    Wire contract (shared with modules/ui/app.py — keep in sync):
      {"token": str}        answer text delta
      {"reasoning": str}    model thinking delta (only when the model emits it)
      {"tool_use": {"id", "name", "input"}}   input is ACCUMULATED-so-far
      {"tool_result": {"id", "status"}}       status only; payload stays in Langfuse

    Defensive by design: a malformed event returns [] rather than raising, so
    one odd event never kills the stream mid-answer.
    """
    try:
        if "data" in event:
            return [f"data: {json.dumps({'token': event['data']})}\n\n"]

        if event.get("reasoning") and event.get("reasoningText"):
            return [f"data: {json.dumps({'reasoning': event['reasoningText']})}\n\n"]

        if "current_tool_use" in event:
            tool = event["current_tool_use"]
            if not isinstance(tool, dict) or not tool.get("name"):
                return []
            tool_input = tool.get("input", "")
            if not isinstance(tool_input, str):
                tool_input = json.dumps(tool_input)
            payload = {"tool_use": {"id": tool.get("toolUseId", ""), "name": tool["name"], "input": tool_input}}
            return [f"data: {json.dumps(payload)}\n\n"]

        if "message" in event:
            msg = event["message"]
            if not isinstance(msg, dict) or msg.get("role") != "user":
                return []
            lines = []
            content = msg.get("content")
            if not isinstance(content, list):
                return []
            for block in content:
                result = block.get("toolResult") if isinstance(block, dict) else None
                if result:
                    payload = {"tool_result": {"id": result.get("toolUseId", ""), "status": result.get("status", "success")}}
                    lines.append(f"data: {json.dumps(payload)}\n\n")
            return lines

        return []
    except Exception:
        return []


def _chart_id_from_result(result: dict) -> str | None:
    """Pull a chart_id out of one toolResult's content, if present.

    run_python returns a dict, which FastMCP serializes into the toolResult
    content as EITHER a {"json": {...}} block (structured content) OR a
    {"text": "<json>"} block — so we check both shapes. Returns the first
    chart_id found, else None. Pure + defensive: never raises.
    """
    content = result.get("content")
    if not isinstance(content, list):
        return None
    for block in content:
        if not isinstance(block, dict):
            continue
        payload = block.get("json")
        if not isinstance(payload, dict):
            text = block.get("text")
            if isinstance(text, str):
                try:
                    parsed = json.loads(text)
                    payload = parsed if isinstance(parsed, dict) else None
                except (json.JSONDecodeError, TypeError):
                    payload = None
        if isinstance(payload, dict):
            cid = payload.get("chart_id")
            if isinstance(cid, str) and cid:
                return cid
    return None


def chart_ids_from_event(event: dict) -> list[str]:
    """Return chart_ids carried by a Strands stream event, in order.

    Mirrors the toolResult walk in sse_events_for. Kept separate (and pure) so
    generate() can fetch each chart's bytes out-of-band without a network call
    ever living inside the SSE mapper. Defensive: [] on any odd shape.
    """
    try:
        msg = event.get("message")
        if not isinstance(msg, dict) or msg.get("role") != "user":
            return []
        content = msg.get("content")
        if not isinstance(content, list):
            return []
        ids = []
        for block in content:
            result = block.get("toolResult") if isinstance(block, dict) else None
            if isinstance(result, dict):
                cid = _chart_id_from_result(result)
                if cid:
                    ids.append(cid)
        return ids
    except Exception:
        return []


async def fetch_chart_event(chart_id: str) -> str | None:
    """Fetch a chart PNG from the broker and return it as an `image` SSE line.

    The bytes travel broker -> here -> UI, out-of-band from the LLM (which only
    ever saw the chart_id). Best-effort: on any error we just skip the image —
    the text answer already stands.
    """
    url = f"{CODE_EXEC_CHART_BASE_URL}/chart/{chart_id}"
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            b64 = base64.b64encode(resp.content).decode("ascii")
        payload = {"image": {"base64": b64, "mime": "image/png"}}
        return f"data: {json.dumps(payload)}\n\n"
    except Exception:
        print(f"[chart] fetch failed for {chart_id} at {url}", flush=True)
        return None


class ChatRequest(BaseModel):
    query: str
    session_id: str | None = None
    actor_id: str | None = None


app = FastAPI()

# Session-scoped agents keyed by session_id. Value: (agent, mcp_clients, token).
# The MCP clients (one per MCP_SERVER_URLS endpoint) are entered once per session
# (each lists tools once), not per request.
_sessions: dict[str, tuple] = {}


def _get_session_agent(session_id: str | None, access_token: str | None):
    """Return the agent for this session, (re)building if the token changed.

    Rebuild-on-token-change guards the (rare, single-user) case of a new login
    reusing a session id — the MCP client's bearer is fixed at connect, so a
    changed token needs a fresh client. The session_id + persona are passed as
    Langfuse trace attributes (see build_session_agent).
    """
    key = session_id or "default"
    existing = _sessions.get(key)
    if existing and existing[2] == access_token:
        return existing[0]
    if existing:
        # token changed → tear down the stale clients before rebuilding.
        for c in existing[1]:
            try:
                c.__exit__(None, None, None)
            except Exception:
                pass
    agent, mcp_clients = build_session_agent(
        access_token,
        session_id=session_id,
        user_id=_persona_from_token(access_token),
    )
    _sessions[key] = (agent, mcp_clients, access_token)
    return agent


@app.get("/healthz")
def healthz():
    return {"ok": True}


def _has_401(exc: BaseException) -> bool:
    """True if a 401 / expired-token failure appears anywhere in exc's chain.

    Strands wraps the underlying httpx 401 (agentgateway rejecting an expired
    Cognito token) in an MCPClientInitializationError around an ExceptionGroup,
    so the top-level message never mentions 401 — walk causes, contexts, and any
    ExceptionGroup members to find it.
    """
    seen: set[int] = set()
    stack: list[BaseException] = [exc]
    while stack:
        e = stack.pop()
        if id(e) in seen:
            continue
        seen.add(id(e))
        text = str(e)
        if "401" in text or "Unauthorized" in text or "ExpiredSignature" in text:
            return True
        resp = getattr(e, "response", None)
        if resp is not None and getattr(resp, "status_code", None) == 401:
            return True
        if e.__cause__:
            stack.append(e.__cause__)
        if e.__context__:
            stack.append(e.__context__)
        stack.extend(getattr(e, "exceptions", None) or [])
    return False


def _agent_init_error_message(exc: Exception) -> str:
    """User-facing text when the session agent can't connect its MCP tools."""
    if _has_401(exc):
        return (
            "Your session has expired, so I couldn't reach my tools. Please sign "
            "out and sign back in (a fresh browser window helps), then try again."
        )
    return "I couldn't reach my tools right now. Please try again in a moment."


@app.post("/chat")
async def chat(req: ChatRequest, authorization: str | None = Header(default=None)):
    # Extract the forwarded Cognito bearer (if any).
    access_token = None
    if authorization and authorization.lower().startswith("bearer "):
        access_token = authorization[7:]
    print(
        f"[chat] actor={req.actor_id} session={req.session_id} "
        f"token={'yes' if access_token else 'no'} query={req.query!r}",
        flush=True,
    )

    async def generate():
        # Build the session agent HERE, inside the stream, so a failure to
        # connect or authenticate to the MCP server (e.g. an expired Cognito
        # token → agentgateway 401) becomes a friendly message on a 200 stream,
        # rather than an unhandled exception that 500s /chat and leaves the UI
        # blank.
        try:
            agent = _get_session_agent(req.session_id, access_token)
        except Exception as exc:
            print(f"[chat] session agent init failed: {exc!r}", flush=True)
            yield f"data: {json.dumps({'token': _agent_init_error_message(exc)})}\n\n"
            yield "data: [DONE]\n\n"
            return
        async for event in agent.stream_async(req.query):
            for line in sse_events_for(event):
                yield line
            # A tool result may carry a chart_id (run_python). Fetch each chart's
            # PNG from the broker out-of-band and stream it as an `image` event,
            # right after its tool_result so it renders under that step.
            for chart_id in chart_ids_from_event(event):
                image_line = await fetch_chart_event(chart_id)
                if image_line:
                    yield image_line
        langfuse.flush()
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
