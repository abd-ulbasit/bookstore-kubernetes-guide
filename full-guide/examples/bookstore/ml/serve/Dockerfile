# Bookstore recommendations — SERVE image (Part 12 ch.06, X3b).
#
# Multi-stage: `builder` installs wheels into a venv; the final image is a
# small Python runtime that COPIES the venv in. Final image runs as non-root
# UID 65532 — PSA-`restricted`-compliant out of the box, so the `bookstore-ml`
# namespace accepts the Pod without a SCC patch.
#
# This image is BOTH the plain-Deployment predictor (recommender-deployment.yaml)
# AND the predictor container behind a KServe custom InferenceService
# (recommender-inferenceservice.yaml). The endpoint surface matches the v1
# prediction protocol used by KServe runtimes (predict + model meta + ready +
# healthz on :8080).
#
# Build (from the repo root):
#   docker build -t bookstore/recommender-serve:dev examples/bookstore/ml/serve
#
# Run locally (mount the named volume the train image wrote to):
#   docker run --rm -p 8080:8080 \
#     -v bookstore-model:/workspace/model \
#     -e MODEL_DIR=/workspace/model bookstore/recommender-serve:dev

# ---- Stage 1: builder ----------------------------------------------------
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

COPY requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip \
 && pip install -r /tmp/requirements.txt

# ---- Stage 2: runtime ----------------------------------------------------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" \
    MODEL_DIR="/workspace/model" \
    MODEL_NAME="recommender" \
    PORT="8080"

RUN groupadd --system --gid 65532 nonroot \
 && useradd  --system --uid 65532 --gid 65532 --no-create-home \
        --home-dir /workspace --shell /sbin/nologin nonroot \
 && mkdir -p /workspace/model \
 && chown -R 65532:65532 /workspace

COPY --from=builder /opt/venv /opt/venv
WORKDIR /workspace
COPY --chown=65532:65532 predictor.py /workspace/predictor.py

USER 65532:65532
EXPOSE 8080

# No HEALTHCHECK: the Kubernetes readinessProbe / livenessProbe on /ready and /healthz take this role in cluster.
# uvicorn directly so signals and logs land where Kubernetes expects.
ENTRYPOINT ["python", "-m", "uvicorn", "predictor:app", \
            "--host", "0.0.0.0", "--port", "8080"]
