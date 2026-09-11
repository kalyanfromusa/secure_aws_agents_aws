# Sandbox runtime image (FastAPI server on :8888 exposing /execute + /upload).
# The agent-sandbox SDK's commands.run/files.write talk to this server inside
# each vended kata-fc microVM. Base image from the ECR public mirror (repo
# convention — avoids docker.io pulls).
FROM public.ecr.aws/docker/library/python:3.11-slim
WORKDIR /app
COPY requirements.txt .
# requirements.txt is hash-pinned (pip-compile --generate-hashes); pip enforces
# the hashes automatically. matplotlib renders charts headlessly, so force the
# non-interactive Agg backend — the microVM has no display server.
ENV MPLBACKEND=Agg
# The container runs as UID 1000 with no home directory, so matplotlib's default
# cache path resolves to /.config/matplotlib, which is root-owned. Without this
# it prints a permission-denied warning on every import; that goes to stderr,
# which the broker returns to the agent, so the noise lands in the model's
# context. /tmp is writable in the microVM.
ENV MPLCONFIGDIR=/tmp/matplotlib
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
RUN chown -R 1000:1000 /app
USER 1000
EXPOSE 8888
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8888", "--log-level", "info"]
