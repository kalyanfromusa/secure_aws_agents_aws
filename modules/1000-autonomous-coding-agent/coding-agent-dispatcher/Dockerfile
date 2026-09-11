# Coding-agent dispatcher. Long-running FastAPI service: receives Gitea webhooks,
# vends kata-fc-coding microVMs via the agent-sandbox SDK, drives Claude Code,
# and talks to the Gitea API. Base from the ECR public mirror (no docker.io).
FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY webhook.py gitea_client.py sandbox_runner.py server.py .
EXPOSE 8080
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080", "--log-level", "info"]
