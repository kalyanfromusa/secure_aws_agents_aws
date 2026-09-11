# Coding sandbox runtime: the agent-sandbox SDK-contract server (:8888,
# /execute + /upload) PLUS git, Node, and the Claude Code CLI. The dispatcher's
# commands.run invokes `claude -p` in here; Claude Code reaches the model via
# ANTHROPIC_BASE_URL (the Envoy AI Gateway Anthropic route) and git over the
# in-cluster Gitea ClusterIP. Base from the ECR public mirror (no docker.io).
FROM public.ecr.aws/docker/library/python:3.11-slim
WORKDIR /app

# git + curl + Node + npm for the Claude Code CLI.
# Install nodejs AND npm straight from Debian's repos rather than adding the
# NodeSource apt repo. NodeSource's signing-key fetch is an external network
# call that flakes intermittently, and its setup script exits 0 even when the
# key import fails, so the build silently fell back to Debian's nodejs WITHOUT
# npm (a separate Debian package) and then died at `npm install -g` with
# "npm: not found" (exit 127) on whichever accounts hit the flake. The base is
# Debian trixie, which ships nodejs 20.x + npm. Claude Code prints an
# EBADENGINE warning (it prefers Node >= 22) but runs correctly on Node 20 -
# verified with `claude --version` on a native-arch build. curl stays: the
# coding run.sh uses it to open the PR via the Gitea API.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates nodejs npm && \
    npm install -g @anthropic-ai/claude-code && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
RUN chown -R 1000:1000 /app
# UID 1000 has no passwd home; point HOME at the writable workdir so git config,
# ~/.git-credentials, and Claude Code's ~/.claude/~/.config all work. The
# runtime's /execute passes no env, so the subprocess inherits this.
ENV HOME=/app
USER 1000
EXPOSE 8888
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8888", "--log-level", "info"]
