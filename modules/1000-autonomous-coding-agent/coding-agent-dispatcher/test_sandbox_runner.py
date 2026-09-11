"""Tests for the pure script builders. These would have caught the no-shell /
no-env-passthrough bug: run.sh MUST be self-contained (export its own HOME +
GITEA_TOKEN) because the runtime's /execute runs shlex.split + subprocess with
no shell and no env passthrough, and the command sent is only `bash /app/run.sh`.
"""

import json
import subprocess
import sys

from sandbox_runner import STREAM_FILTER_PY, _run_script, _task_md


def test_run_script_is_self_contained():
    s = _run_script(owner="acme", repo="app", issue=5, branch="agent/issue-5", token="TKN123")
    # Env set INSIDE the script (no reliance on a shell env-prefix or passthrough).
    assert "export HOME=/app" in s
    assert 'export GITEA_TOKEN="TKN123"' in s
    assert 'export ANTHROPIC_BASE_URL=' in s
    assert 'export ANTHROPIC_MODEL="claude-sonnet"' in s


def test_run_script_clone_and_branch():
    s = _run_script(owner="acme", repo="app", issue=5, branch="agent/issue-5", token="T")
    assert "git clone http://gitea-http.gitea.svc.cluster.local:3000/acme/app.git repo" in s
    assert "git checkout -b agent/issue-5" in s


def test_run_script_credentials_and_push_guard():
    s = _run_script(owner="acme", repo="app", issue=5, branch="b", token="T")
    assert "credential.helper store" in s
    assert '"$HOME/.git-credentials"' in s
    # Push + PR only happen when the branch advanced past the base commit
    # (no stray empty branches).
    assert '"$(git rev-parse HEAD)" != "$BASE_SHA"' in s


def test_task_md_carries_issue_context():
    m = _task_md(owner="acme", repo="app", issue=9, branch="b", title="Add health", body="Return ok")
    assert "issue #9" in m
    assert "Add health" in m
    assert "Return ok" in m


def test_run_script_streams_to_pod_log():
    s = _run_script(owner="acme", repo="app", issue=5, branch="b", token="T")
    # Mirror the whole run to PID 1's stdout (= the pod log) so kubectl logs -f
    # shows it live, and render Claude's stream-json through the filter.
    assert "tee /proc/1/fd/1" in s
    assert "--output-format stream-json --verbose" in s
    assert "python3 /app/stream_filter.py" in s


def test_stream_filter_renders_events_and_survives_garbage():
    events = "\n".join([
        json.dumps({"type": "system", "subtype": "init", "model": "claude-sonnet"}),
        "not json at all",
        json.dumps({"type": "assistant", "message": {"content": [
            {"type": "text", "text": "Reading the repo."},
            {"type": "tool_use", "name": "Edit", "input": {"file_path": "/app/repo/app.py"}},
        ]}}),
        json.dumps({"type": "result", "subtype": "success", "num_turns": 7}),
    ])
    out = subprocess.run([sys.executable, "-c", STREAM_FILTER_PY],
                         input=events, capture_output=True, text=True, timeout=30)
    assert out.returncode == 0
    assert "[claude] session start (model claude-sonnet)" in out.stdout
    assert "[claude] Reading the repo." in out.stdout
    assert "[claude] tool Edit: /app/repo/app.py" in out.stdout
    assert "[claude] done: success (7 turns)" in out.stdout
