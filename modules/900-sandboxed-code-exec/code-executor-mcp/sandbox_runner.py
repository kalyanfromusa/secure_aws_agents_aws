"""Vend a kata-fc microVM, run untrusted code against injected data, terminate.

Thin wrapper over the k8s-agent-sandbox SDK. The broker (server.py) calls
run_in_sandbox(...) with the already-fetched rows and the LLM's code. Data is
injected as a file (out-of-band), never through the LLM. The microVM is
air-gapped and holds no credentials; this process holds the SandboxClaim RBAC.
"""

import json
import logging
import os

from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxDirectConnectionConfig

# --- config from env (set in the broker Deployment) ---
ROUTER_URL = os.environ.get(
    "SANDBOX_ROUTER_URL",
    "http://sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080",
)
WARMPOOL = os.environ.get("SANDBOX_WARMPOOL", "kata-fc-python-pool")
SANDBOX_NAMESPACE = os.environ.get("SANDBOX_NAMESPACE", "agent-sandbox")
# Wall-clock for the code run (< the router's PROXY_TIMEOUT_SECONDS default 180).
RUN_TIMEOUT_SECONDS = int(os.environ.get("SANDBOX_RUN_TIMEOUT", "120"))
READY_TIMEOUT_SECONDS = int(os.environ.get("SANDBOX_READY_TIMEOUT", "180"))
# TTL backstop: the controller GCs the claim even if this process dies mid-run.
SHUTDOWN_AFTER_SECONDS = int(os.environ.get("SANDBOX_SHUTDOWN_AFTER", "300"))

MAX_OUTPUT_BYTES = 64 * 1024  # cap stdout/stderr returned to the agent

# Where LLM-written code is told to save a chart, and the max PNG we'll pull
# back. These bytes DON'T go through the LLM (the broker caches them and hands
# the agent only a short chart_id — see server.py), so the cap is just a sanity
# bound on the out-of-band transfer, not a token-cost guard. A tight matplotlib
# figure (small figsize, dpi ~100) is comfortably under this; anything larger is
# dropped (the numeric answer in stdout still stands).
CHART_FILENAME = "chart.png"
MAX_IMAGE_BYTES = 2 * 1024 * 1024


def cap_output(text: str | None) -> str:
    """Bound returned output so a runaway print can't flood the agent context."""
    if not text:
        return ""
    data = text.encode("utf-8")
    if len(data) <= MAX_OUTPUT_BYTES:
        return text
    return data[:MAX_OUTPUT_BYTES].decode("utf-8", errors="ignore") + "...[truncated]"


def read_chart(sandbox) -> bytes | None:
    """Return the sandbox's chart PNG as raw bytes, or None if there isn't one.

    Best-effort and never raises: a missing/oversized/unreadable chart just means
    "no image" — the code's stdout is the real answer. `sandbox.files.read` maps
    to the runtime's /download endpoint and returns bytes. The broker (server.py)
    caches these bytes and gives the agent a chart_id, so the raw image never
    passes through the LLM.
    """
    try:
        if not sandbox.files.exists(CHART_FILENAME, timeout=30):
            return None
        data = sandbox.files.read(CHART_FILENAME, timeout=60)
        if not data:
            return None
        if len(data) > MAX_IMAGE_BYTES:
            logging.warning(
                "chart.png is %d bytes (> %d cap); dropping the image",
                len(data), MAX_IMAGE_BYTES,
            )
            return None
        return data
    except Exception:  # a chart read must never fail the run
        logging.exception("reading chart.png from sandbox failed; continuing without image")
        return None


def run_in_sandbox(code: str, rows: list[dict]) -> dict:
    """Run `code` in a fresh air-gapped microVM with `rows` at /app/orders.json.

    Returns {"stdout", "stderr", "exit_code"} and, when the code saved a chart,
    "image_png" (raw PNG bytes). Always terminates the sandbox.
    """
    client = SandboxClient(
        connection_config=SandboxDirectConnectionConfig(api_url=ROUTER_URL, server_port=8888),
    )
    # No pod_labels: the controller rejects additionalPodMetadata labels without
    # a domain prefix ("must have a domain prefix ... to prevent opting into
    # unintended policy domains"). The label was only a cosmetic marker and
    # nothing selects the sandbox pod by it (the router NetworkPolicy targets the
    # broker's app=code-executor; the sandbox's own policy is managed by the
    # controller via its template-ref-hash label), so we simply omit it.
    sandbox = client.create_sandbox(
        warmpool=WARMPOOL,
        namespace=SANDBOX_NAMESPACE,
        sandbox_ready_timeout=READY_TIMEOUT_SECONDS,
        shutdown_after_seconds=SHUTDOWN_AFTER_SECONDS,
    )
    try:
        # Inject data + code as files under /app (the runtime's working dir).
        sandbox.files.write("orders.json", json.dumps(rows), timeout=60)
        sandbox.files.write("main.py", code, timeout=60)
        result = sandbox.commands.run("python3 main.py", timeout=RUN_TIMEOUT_SECONDS)
        out = {
            "stdout": cap_output(result.stdout),
            "stderr": cap_output(result.stderr),
            "exit_code": result.exit_code,
        }
        # If the code drew a chart to /app/chart.png, pull the raw bytes back
        # (out-of-band, via the runtime's /download). The broker caches them and
        # returns only a chart_id to the agent — the image never hits the LLM.
        image_png = read_chart(sandbox)
        if image_png:
            out["image_png"] = image_png
        return out
    finally:
        try:
            sandbox.terminate()
        except Exception:  # terminate is idempotent; never mask the real result
            logging.exception("sandbox terminate failed (TTL backstop will GC)")
