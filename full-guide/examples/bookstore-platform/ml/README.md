# `ml/` — MLflow + Argo Workflows + KServe + Alibi-Detect + Argo Events

The v2 MLOps loop (ch.13.08). Five stations: train -> register -> serve ->
monitor -> retrain. v1 (Part 12) shipped the pieces; v2 wires the loop with
real components.

## Files

- `mlflow-application.yaml` — Argo CD Application that installs
  community-charts/mlflow (pinned) with CNPG-backed tracking + S3 artifact
  store. Replaces the v1 ConfigMap "registry stamp" with the real registry.
- `training-workflow.yaml` — `WorkflowTemplate` running the full
  train -> eval -> register -> promote-to-staging DAG. Pods land in
  `bookstore-platform-ml` (PSA restricted).
- `inferenceservice.yaml` — KServe `InferenceService` with traffic split
  between `production` and `staging` aliases. Storage URI resolves via
  MLflow Model Registry.
- `alibi-detect-drift.yaml` — Deployment running an Alibi-Detect KSDrift
  detector on a sliding window of predictions; publishes `ml.drift`
  events on threshold breach.
- `argo-events-drift-trigger.yaml` — `EventSource` + `Sensor` that
  watches `ml.drift` and submits the `recommender-train` Workflow on
  drift detection (p_value < 0.05).

## Apply order

```sh
# 1. Argo Workflows + Argo Events (pinned-Helm)
ARGO_WORKFLOWS_VERSION="0.42.0"
ARGO_EVENTS_VERSION="2.4.0"
helm install argo-workflows argo/argo-workflows --version "$ARGO_WORKFLOWS_VERSION" -n argo --create-namespace --wait
helm install argo-events argo/argo-events --version "$ARGO_EVENTS_VERSION" -n argo-events --create-namespace --wait

# 2. KServe + Knative + cert-manager (cross-ref Part 12 ch.06)

# 3. MLflow via Argo CD
kubectl apply -f examples/bookstore-platform/ml/mlflow-application.yaml

# 4. The pipeline + serving + drift + trigger
kubectl apply -f examples/bookstore-platform/ml/training-workflow.yaml
kubectl apply -f examples/bookstore-platform/ml/inferenceservice.yaml
kubectl apply -f examples/bookstore-platform/ml/alibi-detect-drift.yaml
kubectl apply -f examples/bookstore-platform/ml/argo-events-drift-trigger.yaml

# 5. Submit a manual training run
argo submit --from workflowtemplate/recommender-train -n bookstore-platform-ml

# 6. Confirm
kubectl -n bookstore-platform-ml get workflowtemplate,inferenceservice,deploy,eventsource,sensor
```

## Honest notes

- **community-charts/mlflow vs bitnami/mlflow.** Phase 13b ships
  community-charts/mlflow. The chapter walks the trade.
- **`mlflow://` storage URI.** KServe 0.12+ ships an MLflow storage
  initializer; older KServe versions need the v2-storage-initializer
  upgrade.
- **Promotion gate.** The Workflow auto-promotes to **Staging only**.
  Production promotion requires a human approval — see ch.13.08
  Production notes for the GitHub-PR-as-approval pattern.
- **Drift retrain loop runaway.** If the drift detector mis-fires the
  retrain loop can spiral. Production rate-limits the sensor (e.g.
  "no more than one retrain per 6 hours per feature").

## v1 vs v2 contrast

| Station | v1 (Part 12) | v2 (Part 13.08) |
|---------|--------------|-----------------|
| Train | `WorkflowTemplate` | same, extends with MLflow logging |
| Register | ConfigMap stamp | MLflow Model Registry version |
| Serve | KServe `pvc://` | KServe `mlflow://` with alias |
| Drift | (none) | Alibi-Detect KSDrift |
| Retrain | manual | Argo Events Sensor on drift |

## Cross-references

- Ch.13.08 — the chapter that authors this stack.
- Part 12 ch.06 / ch.07 / ch.08 — the prior-art each piece extends.
- `../kafka/` — provides `ml.predictions` (consumed by alibi-detect)
  and `ml.drift` (produced by alibi-detect, consumed by Argo Events).
- `../app/recommendations/` — the API wrapper that POSTs predictions
  to KServe and publishes them to `ml.predictions`.
