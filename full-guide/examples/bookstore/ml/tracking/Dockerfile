# Bookstore, Part 12 ch.08: the MLflow tracker image.
#
# Built from a current Python slim base, pinned by digest, with every package
# pinned in requirements.txt. A builder stage installs the wheels into a venv.
# The runtime stage copies the venv in and removes pip, because nothing in a
# running tracker installs a package, and pip's vendored libraries would only
# add findings. It runs as UID 65532, which the Deployment sets as well.
#
# Python 3.14 and not the newer 3.15: MLflow 3.17.2 requires pyarrow below 26,
# and the pyarrow releases below 26 have no wheel for 3.15.
#
# Build (from the full-guide directory):
#   docker build -t bookstore/mlflow-auth:dev examples/bookstore/ml/tracking

# ---- Stage 1: builder (install the pinned wheels into /opt/venv) -----------
FROM python:3.14-slim@sha256:cd89c30eda26ee911a4611b18680086e0ea42e6f5f8cbe653d07fa7958c9cec8 AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# Wheels only: every pin has one, so the build needs no compiler.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --only-binary=:all: -r /tmp/requirements.txt \
 && pip uninstall --yes pip

# ---- Stage 2: runtime (slim, non-root, copies the venv in) -----------------
FROM python:3.14-slim@sha256:cd89c30eda26ee911a4611b18680086e0ea42e6f5f8cbe653d07fa7958c9cec8 AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}"

# The base image's own pip goes too. /usr/local/bin/python is named explicitly
# because PATH lists the venv first.
RUN groupadd --system --gid 65532 nonroot \
 && useradd  --system --uid 65532 --gid 65532 --no-create-home \
        --home-dir /tmp --shell /sbin/nologin nonroot \
 && /usr/local/bin/python -m pip uninstall --yes pip

COPY --from=builder /opt/venv /opt/venv

USER 65532:65532
EXPOSE 5000

# No ENTRYPOINT or CMD: the Deployment passes `mlflow server` and its options.
