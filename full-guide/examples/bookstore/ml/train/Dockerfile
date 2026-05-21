# Bookstore recommendations — TRAIN image (Part 12 ch.04, X3b).
#
# Multi-stage: a `builder` stage installs wheels into a venv; the final image
# is a small Python runtime that COPIES the venv in. Final image runs as a
# non-root UID (65532) — PSA-`restricted`-compliant out of the box, so the
# bookstore-ml namespace (PSA `enforce: restricted`) accepts it without a SCC
# patch. Many ML/CUDA base images default to root and would be REJECTED; this
# image is honest about that and bakes the non-root user.
#
# Build (from the repo root):
#   docker build -t bookstore/recommender-train:dev examples/bookstore/ml/train
#
# Run locally (use a named volume so uid 65532 inside the container can write
# to it; a host bind mount needs prior `chown 65532:65532` on macOS):
#   docker volume create bookstore-model
#   docker run --rm -v bookstore-model:/workspace/model \
#     -e MODEL_DIR=/workspace/model bookstore/recommender-train:dev

# ---- Stage 1: builder (install wheels into /opt/venv) --------------------
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Minimal build deps for any wheels without prebuilt arm64/x86_64 binaries.
# scipy/scikit-learn publish manylinux wheels for current versions so this is
# usually a no-op, but kept conservative.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

COPY requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip \
 && pip install -r /tmp/requirements.txt

# ---- Stage 2: runtime (slim, non-root, copies venv in) -------------------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" \
    MODEL_DIR="/workspace/model"

# Non-root user 65532 (matches the manifests in this tree and the
# X3a recommender-train-gpu / recommender-jobset specs).
RUN groupadd --system --gid 65532 nonroot \
 && useradd  --system --uid 65532 --gid 65532 --no-create-home \
        --home-dir /workspace --shell /sbin/nologin nonroot \
 && mkdir -p /workspace/model \
 && chown -R 65532:65532 /workspace

COPY --from=builder /opt/venv /opt/venv
WORKDIR /workspace
COPY --chown=65532:65532 train.py /workspace/train.py

USER 65532:65532

# Default entry: run the trainer. MODEL_DIR is the artifact destination
# (mount a PVC / volume here on Kubernetes; see recommender-train-job.yaml).
# No HEALTHCHECK: exit code of the training script is the signal for the Job controller.
ENTRYPOINT ["python", "/workspace/train.py"]
