# Bookstore ML — serving (Part 12 ch.06)

This directory is the **serving side** of the recommendations thread. It
loads the `model.joblib` produced by [`../train/`](../train/) (the CPU
recommender-train Job) and exposes it as an HTTP API over the `recommender`
endpoint.

## Files

| File | What it is | Runs on kind? |
|---|---|---|
| `predictor.py` | tiny FastAPI app: `/v1/models/recommender:predict` + `/recommend` + health | yes (no cluster) |
| `requirements.txt` | pinned Python deps (FastAPI/uvicorn + joblib + sklearn) | — |
| `Dockerfile` | multi-stage slim Python image, non-root UID 65532 | yes |
| `Makefile` | `compile` / `build` / `train-and-run` / `test` targets | yes |
| `recommender-deployment.yaml` | **built-in** Deployment of the predictor (PSA-restricted) | **yes — kind-runnable** |
| `recommender-service.yaml` | ClusterIP `Service` in front of the Deployment | yes |
| `recommender-inferenceservice.yaml` | KServe `InferenceService` (CRD-backed; scale-to-zero, canary) | needs KServe + Knative |

> All manifests target the `bookstore-ml` namespace (PSA `enforce: restricted`).
> `recommender-inferenceservice.yaml` carries the CRD-intrinsic header note:
> a client dry-run prints `no matches for kind …` until KServe is installed —
> schema-correct, not a bug (same precedent as the rest of the guide's CRD-backed manifests).

## The HTTP surface

| Method | Path | Body / Query | What it returns |
|---|---|---|---|
| `GET`  | `/healthz` | — | `{"status":"ok"}` |
| `GET`  | `/ready`   | — | `{"status":"ready"}` once the model is loaded |
| `GET`  | `/v1/models/recommender` | — | model metadata (kind/version/n_books/top_k) |
| `POST` | `/v1/models/recommender:predict` | `{"instances":[{"book_id":1,"k":3}]}` | top-K recommendations per instance |
| `GET`  | `/recommend?book_id=1&k=3` | — | friendly equivalent used by `catalog`/`storefront` |

The `:predict` envelope follows the v1 prediction protocol used by KServe's
built-in runtimes — the same image works behind an `InferenceService` and a
plain Deployment.

## Run it locally (no cluster)

```sh
# from this directory:
make compile           # python3 -m py_compile predictor.py
make build             # docker build -t bookstore/recommender-serve:dev .
# end-to-end: train -> joblib -> serve, just on docker
make train-and-run     # runs train image -> model.joblib on `bookstore-model`
                       # docker volume, then runs serve image on :8080
# proof: curl localhost:8080/v1/models/recommender:predict (same as kind step 4)
```

## Run it on kind (the kind-runnable path)

```sh
# from the repo root (full-guide/):
# 1) build + load images
docker build -t bookstore/recommender-train:dev examples/bookstore/ml/train
docker build -t bookstore/recommender-serve:dev examples/bookstore/ml/serve
kind load docker-image bookstore/recommender-train:dev
kind load docker-image bookstore/recommender-serve:dev
# 2) train: produces model.joblib on the recommender-model PVC
kubectl apply -f examples/bookstore/ml/train/recommender-train-job.yaml
kubectl wait --for=condition=complete job/recommender-train -n bookstore-ml --timeout=300s
# 3) serve: plain Deployment + Service consumes the same PVC
kubectl apply -f examples/bookstore/ml/serve/recommender-deployment.yaml
kubectl apply -f examples/bookstore/ml/serve/recommender-service.yaml
kubectl rollout status deploy/recommender -n bookstore-ml --timeout=120s
# 4) proof: port-forward and POST a predict — the final proof step
kubectl port-forward -n bookstore-ml svc/recommender 8080:8080 &
curl -s -X POST localhost:8080/v1/models/recommender:predict \
  -H 'content-type: application/json' \
  -d '{"instances":[{"book_id":1,"k":3}]}' | jq .
```

## The KServe path (needs the operator)

`recommender-inferenceservice.yaml` is the CRD-backed equivalent. **OPTION A**
(custom predictor) uses the same image under KServe's serverless wrapper —
request-driven autoscaling, scale-to-zero, InferenceService-level canary/A-B.
**OPTION B** (KServe's built-in sklearn ServingRuntime) is a commented stub
in the same file. Install KServe (+ Knative Serving + cert-manager) per
Part 12 ch.06 Hands-on before applying.

## Integration with the Bookstore app (`catalog` / `storefront`)

The recommender's in-cluster DNS is `recommender.bookstore-ml.svc.cluster.local:8080`. The chapter (`../../../12-kubernetes-for-machine-learning/06-model-serving-and-inference.md`) describes the `catalog`/`storefront` integration via `kubectl exec`/`curl`; this README does not mutate the canonical app.
