# Bookstore ML, pipeline/ (Part 12 ch.07)

The worked example for **Part 12 ch.07, ML pipelines and workflows**: the
recommendations **train -> eval -> register -> promote** loop as an **Argo
Workflows `WorkflowTemplate`**, a **`CronWorkflow`** for nightly retraining,
and an **Argo Events `EventBus` + `EventSource` + `Sensor`** for event-driven
retraining.

This tree is additive. It reuses the **same images** as `../train/` and
`../serve/`, and it runs in the `bookstore-ml` PSA-`restricted` namespace
(created by ch.01), plus two controller namespaces (`argo`, `argo-events`)
that `namespaces.yaml` creates.

## Files

| File | Kind | Purpose |
|---|---|---|
| `namespaces.yaml` | `Namespace` x2 | `argo` and `argo-events`, labelled restricted before any chart installs |
| `argo-workflows-values.yaml` | chart values | `argo/argo-workflows` 2.0.15: seccomp on the controller, `-nonroot` executor, no workflow Role from the chart |
| `argo-events-values.yaml` | chart values | `argo/argo-events` 2.4.27: restricted securityContexts on the controller and webhook |
| `recommender-workflow.yaml` | `WorkflowTemplate` + ServiceAccounts + RBAC | the reusable train -> eval -> register -> promote DAG, one identity per step |
| `recommender-cronworkflow.yaml` | `CronWorkflow` | nightly retraining (`0 2 * * *` UTC) |
| `recommender-eventbus.yaml` | `EventBus` | the NATS JetStream bus the Sensor and EventSource share |
| `recommender-eventsource.yaml` | `EventSource` + ServiceAccount | webhook for "dataset ready", bearer token required |
| `recommender-eventsource-allow.yaml` | `NetworkPolicy` | admits the webhook port only from pods labelled `ml.bookstore/role: dataset-publisher` |
| `recommender-sensor.yaml` | `Sensor` + ServiceAccount + Role + RoleBinding | turns an accepted event into a `Workflow` in `bookstore-ml` |
| `recommender-dataset-curl.yaml` | `Pod` + ServiceAccount | one-shot test: a request without the token (refused), then with it |
| `register-cm-template.yaml` | `ConfigMap` | the shape of the registry stamp the `register` step writes |

## CRD-backed manifests in this tree

`WorkflowTemplate`, `CronWorkflow`, `EventBus`, `EventSource` and `Sensor` are
CRDs. A client dry-run without the operator installed prints
`no matches for kind "..."`. That is expected; the chapter walks the install.
The `Namespace`, ServiceAccount, Role and RoleBinding documents, the test Pod
and the ConfigMap dry-run without the operators.

## Install (pinned; own namespaces)

```sh
kubectl apply -f examples/bookstore/ml/pipeline/namespaces.yaml

helm repo add argo https://argoproj.github.io/argo-helm
helm install argo-workflows argo/argo-workflows --version 2.0.15 \
  -n argo -f examples/bookstore/ml/pipeline/argo-workflows-values.yaml --wait
helm install argo-events argo/argo-events --version 2.4.27 \
  -n argo-events -f examples/bookstore/ml/pipeline/argo-events-values.yaml --wait
```

The chart versions are pinned on purpose. Chart 2.0.15 packages Argo
Workflows v4.1.6, and chart 2.4.27 packages Argo Events v1.9.11. Bump them
together with the EventBus `version`, which must be one the Argo Events
chart lists. Never install from a `releases/latest` URL.

## Apply

```sh
# 1) Prereqs from earlier chapters: bookstore-ml (ch.01), the recommender-model
#    PVC and model.joblib (../train/, ch.04).
kubectl apply -f examples/bookstore/ml/train/recommender-train-job.yaml
kubectl wait --for=condition=complete job/recommender-train \
  -n bookstore-ml --timeout=300s
# (optional, but promote needs it) the serving Deployment from ch.06:
kubectl apply -f examples/bookstore/ml/serve/recommender-deployment.yaml
kubectl apply -f examples/bookstore/ml/serve/recommender-service.yaml

# 2) The WorkflowTemplate, its ServiceAccounts, Roles and RoleBindings.
kubectl apply -f examples/bookstore/ml/pipeline/recommender-workflow.yaml

# 3) Run it once. The argo CLI is v4.1.6 to match the controller.
argo submit --from workflowtemplate/recommender-pipeline -n bookstore-ml
argo logs -n bookstore-ml @latest

# 4) Nightly retraining:
kubectl apply -f examples/bookstore/ml/pipeline/recommender-cronworkflow.yaml

# 5) Event-driven retraining:
kubectl apply -f examples/bookstore/ml/pipeline/recommender-eventbus.yaml
kubectl -n argo-events create secret generic recommender-dataset-token \
  --from-literal=token="$(openssl rand -hex 32)"
kubectl apply -f examples/bookstore/ml/pipeline/recommender-eventsource.yaml
kubectl apply -f examples/bookstore/ml/pipeline/recommender-eventsource-allow.yaml
kubectl apply -f examples/bookstore/ml/pipeline/recommender-sensor.yaml
kubectl apply -f examples/bookstore/ml/pipeline/recommender-dataset-curl.yaml
kubectl logs pod/recommender-dataset-curl -n argo-events
kubectl delete pod/recommender-dataset-curl -n argo-events
```

## What each step does (and the honest proxy)

| Step | Identity | Action | KIND-runnable proxy | Real prod shape |
|---|---|---|---|---|
| **train** | `argo-workflow` (no API token) | Runs `bookstore/recommender-train:dev` (`../train/Dockerfile`) and writes `model.joblib` to the PVC. | The same Job and image as `../train/recommender-train-job.yaml`. | A Training Operator `PyTorchJob` or `RayJob` on a GPU node pool (`../train/`). |
| **eval** | `argo-workflow` (no API token) | Reads `model.joblib` read-only, computes average top-1 cosine similarity, gates on `min-score`. Emits `score` and `model-sha256`. | A `script` step in the train image. Metrics go to `/tmp`. | A real offline metric (NDCG@k, MRR, AUC) on a held-out set, with a domain SLO. |
| **register** | `recommender-register` (ConfigMap create, get, patch) | Stamps URI, score, model SHA-256, time, workflow, dataset and image into ConfigMap `recommender-model-registry-<WORKFLOW>`. | `kubectl create configmap` from inside the Pod. `register-cm-template.yaml` shows the shape. | An **MLflow Model Registry** entry, a **KFP Model Registry** record, or an **OCI artifact** (Part 12 ch.08). |
| **promote** | `recommender-promote` (get, list, watch, patch on `recommender` only) | Annotates the Deployment and restarts it so the serving Pod re-reads the model. Fails if the Deployment is missing. | `kubectl annotate` and `kubectl rollout restart deploy/recommender`. | A **GitOps commit** (Part 07 ch.04) that bumps the `InferenceService` `storageUri`; Argo CD reconciles; KServe shifts traffic (Part 12 ch.06). |

## Invariants

- **PSA-`restricted`** on every workflow Pod, the wait sidecar included. The
  pod-level settings come from `WorkflowTemplate.spec.podSpecPatch`; the
  wait sidecar's come from the chart's `executor` values.
- **One identity per step.** `automountServiceAccountToken: false` on the
  template keeps tokens off the step containers; each API-calling step names
  its own ServiceAccount, and every step identity is bound to the executor
  Role for `workflowtaskresults` only.
- **The webhook requires a bearer token** (`authSecret`) and a NetworkPolicy
  admits only the publisher label. TLS is a production addition (see the
  chapter's production notes).
- **No machine-specific paths or users.** Image references are
  `bookstore/recommender-train:dev` (the same convention as `../train/`),
  `cgr.dev/chainguard/kubectl` pinned by digest, and `curlimages/curl` pinned
  by digest. The chapter says which tags are guide-built.

## Honest "not built here"

Part 12 ch.07 and ch.08 cover the deliberate scope limits: data versioning,
feature stores, model explainability, drift detection, federated learning,
multi-cluster training topologies, and the Kubeflow distribution itself.
