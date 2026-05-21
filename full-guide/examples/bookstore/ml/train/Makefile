# Bookstore recommendations — TRAIN image Makefile (Part 12 ch.04, X3b).
# Run from this directory (examples/bookstore/ml/train/), or use `make -C ...`.
IMAGE ?= bookstore/recommender-train:dev
PYTHON ?= python3
# A named docker volume avoids the macOS bind-mount permission issue: the
# non-root user (uid 65532) inside the container can't write to a host dir
# owned by root. The serve Makefile (../serve/Makefile) reads from the same
# volume so the local train -> serve loop is end-to-end.
VOLUME ?= bookstore-model

.PHONY: build test compile run clean help

help:
	@echo "Targets:"
	@echo "  compile  - python3 -m py_compile train.py (no deps required)"
	@echo "  build    - docker build -t $(IMAGE) ."
	@echo "  run      - docker run + write model.joblib to docker volume $(VOLUME)"
	@echo "  test     - compile + build (CI-friendly)"
	@echo "  clean    - remove the docker volume and the local image"

compile:
	$(PYTHON) -m py_compile train.py
	@echo "OK: train.py compiles"

build:
	docker build -t $(IMAGE) .

run:
	-docker volume create $(VOLUME) >/dev/null
	docker run --rm -v $(VOLUME):/workspace/model \
	  -e MODEL_DIR=/workspace/model $(IMAGE)

test: compile build

clean:
	-docker volume rm $(VOLUME) >/dev/null 2>&1 || true
	-docker image rm $(IMAGE) >/dev/null 2>&1 || true
