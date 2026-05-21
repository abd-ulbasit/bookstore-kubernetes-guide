# Bookstore ML — training (Part 12 ch.04)

This directory is the **training side** of the recommendations thread. It is
deliberately tiny and CPU-only so the entire `train -> joblib -> serve` loop
runs on a laptop kind cluster, and so X3a's gang/Kueue/JobSet/GPU artifacts
remain honest: they demonstrate *mechanics*, this directory builds the actual
artifact the serving side loads.

## Files

| File | What it is | Runs on kind? |
|---|---|---|
| `train.py` | the real CPU trainer (item-kNN / co-occurrence over the Bookstore schema) | yes (no cluster) |
| `requirements.txt` | pinned Python deps | — |
| `Dockerfile` | multi-stage slim Python image, non-root UID 65532 | yes (`docker build`) |
| `Makefile` | `compile` / `build` / `run` / `test` targets | yes |
| `recommender-train-job.yaml` | **built-in** `batch/v1` Job + PVC — produces `model.joblib` | **yes — the artifact path** |
| `recommender-pytorchjob.yaml` | Kubeflow Training Operator `PyTorchJob` (CRD-backed) | needs the Training Operator |
| `recommender-rayjob.yaml` | KubeRay `RayJob` (CRD-backed) | needs the KubeRay operator |

> All manifests target the `bookstore-ml` namespace (PSA `enforce: restricted`,
> see [`../README.md`](../README.md)). Every Pod is restricted-compliant. The
> three CRD-backed files each carry the **CRD-intrinsic** header note: a
> client dry-run prints `no matches for kind …` until the operator is
> installed — schema-correct, not a bug. Same precedent as
> `raw-manifests/51-`, `70-`, `83-`, `argocd/`, `operators/`, `chaos/`,
> `ml/batch/`.

## The model — what `train.py` actually does

The recommendations model is item-kNN / co-occurrence over the Bookstore's
own schema (`books(id,title,author,price)` + `orders(id,book_id,qty,created_at)`,
the schema in [`../../raw-manifests/21-db-migrate-job.yaml`](../../raw-manifests/21-db-migrate-job.yaml)).
A small synthetic dataset is generated deterministically from a seed
(`dataset/README.md` is the spec for this); orders are grouped into
pseudo-baskets via the documented basket proxy; the customer x book
interaction matrix is built; item-item cosine similarity (with scikit-learn)
gives the book x book similarity; the top-K neighbours per book are kept.
The artifact (`model.joblib`) is the top-K map plus a tiny title/author
index for nicer responses; the serving side (`../serve/predictor.py`) loads
it directly.

This is real ML — just deliberately small. The GPU scale-up shape is in
[`../gpu/recommender-train-gpu.yaml`](../gpu/recommender-train-gpu.yaml)
(ch.02); the gang/queue shape is in [`../batch/`](../batch/) (ch.03).

## Run it locally (no cluster)

```sh
# from this directory:
make compile      # python3 -m py_compile train.py
make build        # docker build -t bookstore/recommender-train:dev .
make run          # produces model.joblib on docker volume `bookstore-model`
                  # (named volume avoids the macOS bind-mount uid-65532 issue)
```

## Run it on kind

```sh
# from the repo root (full-guide/):
docker build -t bookstore/recommender-train:dev examples/bookstore/ml/train
kind load docker-image bookstore/recommender-train:dev   # if using kind

kubectl apply -f examples/bookstore/ml/train/recommender-train-job.yaml
kubectl wait --for=condition=complete job/recommender-train -n bookstore-ml --timeout=300s
kubectl logs -n bookstore-ml -l app.kubernetes.io/component=recommender-train --tail=50
```

The Job's PVC (`recommender-model`) is the artifact the [`../serve/`](../serve/)
side mounts.

## The CRD-backed paths (need their operators)

- **`recommender-pytorchjob.yaml`** — Kubeflow Training Operator
  (`kubeflow.org/v1 PyTorchJob`). Install the operator (own namespace,
  pinned) per Part 12 ch.04 Hands-on first. Kueue's PyTorchJob integration
  gates the whole job in via `runPolicy.suspend`.
- **`recommender-rayjob.yaml`** — KubeRay (`ray.io/v1 RayJob`). Install
  KubeRay (own namespace, pinned Helm) first. Kueue's RayJob integration
  gates the whole submission in via `spec.suspend`.

Both run the same `train.py` as a stand-in: the recommender is CPU-trivial
and there is no actual all-reduce here. The files exist to demonstrate the
**CRDshape, restricted SC, and Kueue admission** of each path; the file that
actually produces the artifact on kind is `recommender-train-job.yaml`.
