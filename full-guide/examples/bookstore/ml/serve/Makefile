# Bookstore recommendations — SERVE image Makefile (Part 12 ch.06, X3b).
IMAGE ?= bookstore/recommender-serve:dev
TRAIN_IMAGE ?= bookstore/recommender-train:dev
PYTHON ?= python3
# Same named docker volume as ../train/Makefile so the local train -> serve
# loop is end-to-end (avoids the macOS bind-mount uid-65532 permission issue).
VOLUME ?= bookstore-model

.PHONY: build test compile run train-and-run clean help

help:
	@echo "Targets:"
	@echo "  compile        - python3 -m py_compile predictor.py"
	@echo "  build          - docker build -t $(IMAGE) ."
	@echo "  test           - compile + build"
	@echo "  train-and-run  - run the train image to produce model.joblib"
	@echo "                   (volume $(VOLUME)), then run the serve image"
	@echo "                   against it on :8080"
	@echo "  run            - run the serve image only (model must already"
	@echo "                   exist on volume $(VOLUME))"
	@echo "  clean          - remove the docker volume and the local image"

compile:
	$(PYTHON) -m py_compile predictor.py
	@echo "OK: predictor.py compiles"

build:
	docker build -t $(IMAGE) .

test: compile build

train-and-run:
	-docker volume create $(VOLUME) >/dev/null
	docker run --rm -v $(VOLUME):/workspace/model \
	  -e MODEL_DIR=/workspace/model $(TRAIN_IMAGE)
	docker run --rm -p 8080:8080 \
	  -v $(VOLUME):/workspace/model \
	  -e MODEL_DIR=/workspace/model $(IMAGE)

run:
	docker run --rm -p 8080:8080 \
	  -v $(VOLUME):/workspace/model \
	  -e MODEL_DIR=/workspace/model $(IMAGE)

clean:
	-docker volume rm $(VOLUME) >/dev/null 2>&1 || true
	-docker image rm $(IMAGE) >/dev/null 2>&1 || true
