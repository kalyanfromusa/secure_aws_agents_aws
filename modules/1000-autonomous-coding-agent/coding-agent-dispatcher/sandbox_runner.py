"""Vend a kata-fc-coding microVM, inject creds + task, run Claude Code, terminate.

The dispatcher (server.py) calls run_coding_task(...) after minting a per-run token.
Creds + task are injected as files (out-of-band). The microVM holds no AWS creds
and its egress is locked to the AI gateway + Gitea. This process holds the
SandboxClaim RBAC.

The sandbox runtime's /execute runs `shlex.split(cmd)` + subprocess with NO shell
and NO env passthrough, so ALL environment setup (HOME, GITEA_TOKEN, model vars)
must live INSIDE run.sh — the command we send is just `bash /app/run.sh`.
"""

import logging
import os

ROUTER_URL = os.environ.get(
    "SANDBOX_ROUTER_URL",
    "http://sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080",
)
WARMPOOL = os.environ.get("SANDBOX_WARMPOOL", "kata-fc-coding-pool")
SANDBOX_NAMESPACE = os.environ.get("SANDBOX_NAMESPACE", "agent-sandbox")
RUN_TIMEOUT_SECONDS = int(os.environ.get("SANDBOX_RUN_TIMEOUT", "1500"))
READY_TIMEOUT_SECONDS = int(os.environ.get("SANDBOX_READY_TIMEOUT", "300"))
SHUTDOWN_AFTER_SECONDS = int(os.environ.get("SANDBOX_SHUTDOWN_AFTER", "1800"))

# In-cluster endpoints injected into the microVM.
GITEA_INTERNAL = os.environ.get("GITEA_INTERNAL_URL", "http://gitea-http.gitea.svc.cluster.local:3000")
MODEL_BASE_URL = os.environ.get("MODEL_BASE_URL", "http://ai-gateway.envoy-gateway-system.svc.cluster.local/anthropic")
MODEL_MAIN = os.environ.get("MODEL_MAIN", "claude-sonnet")
MODEL_SMALL = os.environ.get("MODEL_SMALL", "claude-haiku")

MAX_OUTPUT_BYTES = 64 * 1024


def cap_output(text: str | None) -> str:
    if not text:
        return ""
    data = text.encode("utf-8")
    if len(data) <= MAX_OUTPUT_BYTES:
        return text
    return data[:MAX_OUTPUT_BYTES].decode("utf-8", errors="ignore") + "...[truncated]"


# Compact, line-buffered renderer for Claude Code's stream-json output. run.sh
# pipes `claude -p ... --output-format stream-json --verbose` through this so
# the pod log (and the captured transcript) shows one short line per event as
# Claude works, instead of one opaque text blob at the end of the run. stdin is
# one JSON object per line; stdout is human-readable lines, flushed per line so
# `kubectl logs -f` renders them live.
STREAM_FILTER_PY = '''import json
import sys


def hint(tool_input):
    for key in ("file_path", "command", "pattern", "path", "url"):
        val = tool_input.get(key)
        if val:
            return str(val).replace("\\n", " ")[:120]
    return ""


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    kind = event.get("type")
    if kind == "system" and event.get("subtype") == "init":
        print("[claude] session start (model %s)" % event.get("model", "?"), flush=True)
    elif kind == "assistant":
        for block in event.get("message", {}).get("content", []) or []:
            if block.get("type") == "text" and block.get("text", "").strip():
                for text_line in block["text"].strip().splitlines():
                    print("[claude] %s" % text_line, flush=True)
            elif block.get("type") == "tool_use":
                print("[claude] tool %s: %s" % (block.get("name", "?"), hint(block.get("input") or {})), flush=True)
    elif kind == "result":
        print("[claude] done: %s (%s turns)" % (event.get("subtype", "?"), event.get("num_turns", "?")), flush=True)
'''


def _run_script(*, owner: str, repo: str, issue: int, branch: str, token: str) -> str:
    """Bash the sandbox executes. Self-contained: it exports its own HOME (the
    runtime runs as UID 1000 with no writable home otherwise), GITEA_TOKEN, and
    the model env, then clones, runs Claude Code, runs the repo's tests, and
    pushes + opens a PR (whose body carries the test summary) only if there is a
    commit to push.

    A GLOBAL gitignore is configured before the clone so build/test artifacts
    (__pycache__, *.pyc, .pytest_cache) are never staged by `git add -A`, even
    when the target repo ships no .gitignore — Claude/pytest create these during
    the run, and without this they leak into the PR diff.
    """
    host = GITEA_INTERNAL.split("://", 1)[1]  # gitea-http...:3000
    scheme = GITEA_INTERNAL.split("://", 1)[0]
    return f"""set -euo pipefail
# Mirror this script's stdout to PID 1's stdout (the runtime server), which IS
# the pod log — so `kubectl logs -f` on the sandbox shows the run live. tee's
# own stdout still flows back to the runtime's command capture, so the
# dispatcher's transcript (result.stdout) is unchanged by this.
exec > >(tee /proc/1/fd/1)
export HOME=/app
export GITEA_TOKEN="{token}"
export ANTHROPIC_BASE_URL="{MODEL_BASE_URL}"
export ANTHROPIC_API_KEY="not-needed"
export ANTHROPIC_MODEL="{MODEL_MAIN}"
export ANTHROPIC_SMALL_FAST_MODEL="{MODEL_SMALL}"
git config --global user.email "coding-agent-bot@example.com"
git config --global user.name "coding-agent-bot"
git config --global credential.helper store
printf '__pycache__/\\n*.py[cod]\\n.pytest_cache/\\n.venv/\\n' > "$HOME/.gitignore_global"
git config --global core.excludesFile "$HOME/.gitignore_global"
printf '{scheme}://coding-agent-bot:%s@{host}\\n' "$GITEA_TOKEN" > "$HOME/.git-credentials"
cd /app
git clone {scheme}://{host}/{owner}/{repo}.git repo
cd repo
git checkout -b {branch}
BASE_SHA=$(git rev-parse HEAD)
# Redirect stdin from /dev/null: current Claude Code (headless -p) treats an open,
# empty stdin as "input pending" and stalls ("no stdin data received"), doing no
# tool work. </dev/null makes it use the -p prompt argument and run to completion.
# stream-json + the renderer turns the session into one short line per event
# (assistant text, tool calls, result) so the mirrored pod log shows Claude
# working live instead of going dark for the whole run.
claude -p "$(cat /app/task.md)" --dangerously-skip-permissions \\
  --output-format stream-json --verbose </dev/null \\
  | python3 /app/stream_filter.py || true
# Commit anything Claude left uncommitted. Newer Claude Code commits its own work,
# so this is best-effort — the push gate below (branch advanced past BASE_SHA) is
# true whether Claude committed or we commit here, avoiding the trap where a
# Claude-made commit leaves `git commit` here with nothing to do.
git add -A
git commit -m "{branch}: automated change for issue #{issue}" || true
if [ "$(git rev-parse HEAD)" != "$BASE_SHA" ]; then
  git push -u origin {branch}
  # Run the repo's tests (deps are pre-baked in the image; the sandbox egress is
  # locked so `pip install` cannot reach PyPI). Capture the summary for the PR
  # body. Non-fatal: a failing/absent suite still opens the PR, flagged as such.
  set +e
  pytest -q > /app/pytest.txt 2>&1
  TEST_RC=$?
  set -e
  if [ "$TEST_RC" -eq 0 ]; then TEST_HDR="### ✅ Tests passed"
  elif [ "$TEST_RC" -eq 5 ]; then TEST_HDR="### ⚠️ No tests collected"
  else TEST_HDR="### ❌ Tests failed (pytest exit $TEST_RC)"; fi
  {{
    echo "Automated PR for issue #{issue}."
    echo
    echo "$TEST_HDR"
    echo
    echo '```'
    tail -n 30 /app/pytest.txt
    echo '```'
  }} > /app/prbody.md
  # Build the JSON body with Python so arbitrary pytest output is safely escaped.
  BODY=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' < /app/prbody.md)
  curl -sS -X POST "{GITEA_INTERNAL}/api/v1/repos/{owner}/{repo}/pulls" \
    -H "Authorization: token $GITEA_TOKEN" -H "content-type: application/json" \
    -d "{{\\"head\\":\\"{branch}\\",\\"base\\":\\"main\\",\\"title\\":\\"Fix issue #{issue}\\",\\"body\\":$BODY}}" || true
else
  echo "no changes to commit; skipping push and PR"
fi
"""


def _task_md(*, owner: str, repo: str, issue: int, branch: str, title: str, body: str) -> str:
    return f"""# Task (from issue #{issue}: {title})

{body}

## Instructions
- You are on a fresh branch `{branch}` inside the cloned repo at /app/repo.
- Implement the change described above. Keep it minimal and correct.
- Add or update unit tests covering your change, and run them to confirm they
  pass (`pytest` is available offline).
- Commit your work with a clear message.
- Do NOT push or open a PR yourself: the wrapper pushes the branch, runs the test
  suite, and opens the PR with the test summary in its description.
"""


def run_coding_task(*, owner: str, repo: str, issue: int, title: str, body: str, token: str) -> dict:
    """Clone the repo in a fresh coding microVM, run Claude Code, push a branch +
    PR. Returns {stdout, stderr, exit_code, branch}. Always terminates."""
    # Imported lazily so the pure script builders (_run_script/_task_md) are
    # unit-testable without the SDK installed.
    from k8s_agent_sandbox import SandboxClient
    from k8s_agent_sandbox.models import SandboxDirectConnectionConfig

    branch = f"agent/issue-{issue}"
    client = SandboxClient(
        connection_config=SandboxDirectConnectionConfig(api_url=ROUTER_URL, server_port=8888),
    )
    sandbox = client.create_sandbox(
        warmpool=WARMPOOL,
        namespace=SANDBOX_NAMESPACE,
        sandbox_ready_timeout=READY_TIMEOUT_SECONDS,
        shutdown_after_seconds=SHUTDOWN_AFTER_SECONDS,
    )
    try:
        sandbox.files.write("task.md", _task_md(owner=owner, repo=repo, issue=issue,
                                                branch=branch, title=title, body=body), timeout=60)
        sandbox.files.write("stream_filter.py", STREAM_FILTER_PY, timeout=60)
        sandbox.files.write("run.sh", _run_script(owner=owner, repo=repo, issue=issue,
                                                  branch=branch, token=token), timeout=60)
        # The runtime has no shell/env passthrough, so run.sh is self-contained
        # and the command is just `bash /app/run.sh` (splits cleanly under shlex).
        result = sandbox.commands.run("bash /app/run.sh", timeout=RUN_TIMEOUT_SECONDS)
        return {
            "stdout": cap_output(result.stdout),
            "stderr": cap_output(result.stderr),
            "exit_code": result.exit_code,
            "branch": branch,
        }
    finally:
        try:
            sandbox.terminate()
        except Exception:
            logging.exception("sandbox terminate failed (TTL backstop will GC)")
