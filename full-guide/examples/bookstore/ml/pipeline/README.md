 # Bookstore ML — pipeline/ (Part 12 ch.07)

The worked example for **Part 12 ch.07 — ML pipelines and workflows**:
the recommendations **train -> eval -> register -> promote** loop modelled
as an **Argo Workflows `WorkflowTemplate`** plus a **`CronWorkflow`** for
nightly retraining and an **Argo Events `EventSource` + `Sensor`** pair
for event-driven retraining.

This tree is **additive**: it does not modify the Bookstore app
(`../../app/`), the canonical manifests (`../../raw-manifests/`,
`../../helm/`, `../../kustomize/`), any earlier `examples/bookstore/*` tree,
or the earlier `examples/bookstore/ml/{dataset,gpu,batch,train,serve,notebook}/`
trees. Everything here is new, in the `bookstore-ml` PSA-`restricted`
namespace, and reuses the **same images** built by `../train/` and
`../serve/` — so the pipeline orchestrates a *real* loop end-to-end.

## Files

| File | Kind | Built-in? | Purpose |
|---|---|---|---|
| `recommender-workflow.yaml` | `WorkflowTemplate` + RBAC | mixed (built-in SA/Role/Binding + CRD) | the reusable train -> eval -> register -> promote DAG |
| `recommender-cronworkflow.yaml` | `CronWorkflow` | CRD | nightly retraining (`0 2 * * *` UTC) |
| `recommender-eventsource.yaml` | `EventSource` | CRD | webhook-triggered retraining (Argo Events) |
| `recommender-sensor.yaml` | `Sensor` + RBAC | mixed (CRD + SA/Role/Binding) | turns an event into a `Workflow` from the template |
| `register-cm-template.yaml` | `ConfigMap` | built-in | the *shape* of the registry stamp the `register` step writes at runtime |

## CRD-backed manifests in this tree

All Argo-Workflows / Argo-Events objects (`WorkflowTemplate`, `CronWorkflow`,
`EventSource`, `Sensor`) carry the documented **CRD-intrinsic** header note
— identical precedent to the guide's `raw-manifests/51-`, `70-`, `83-`, the
`argocd/`, `operators/`, `chaos/` files, and `ml/batch/`, `ml/serve/`,
`ml/train/`. A client dry-run without the operator installed prints
`no matches for kind "..."`; **the schema is correct**, and the chapter
walks the pinned-Helm install.

The built-in ConfigMap (`register-cm-template.yaml`) and the SA/Role/
RoleBinding triples inside `recommender-workflow.yaml` and
`recommender-sensor.yaml` dry-run **cleanly** anywhere.

## Install the operators (pinned; own namespaces)

```sh
# Argo Workflows (workflow controller + server + executor) into ns `argo`.
helm repo add argo https://argoproj.github.io/argo-helm
ARGO_WORKFLOWS_VERSION="0.42.0"   # bump deliberately; chart != app version.
helm install argo-workflows argo/argo-workflows \
  --version "$ARGO_WORKFLOWS_VERSION" \
  -n argo --create-namespace --wait

# Argo Events (controller + EventBus + EventSource/Sensor controllers).
ARGO_EVENTS_VERSION="2.4.7"
helm install argo-events argo/argo-events \
  --version "$ARGO_EVENTS_VERSION" \
  -n argo-events --create-namespace --wait

# Argo Events needs a default EventBus in the namespace where Sensors run.
kubectl apply -n argo-events -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata: { name: default }
spec:
  jetstream:
    # pinned NATS JetStream version (controller-managed image, not a Helm chart)
    # — bump together with the Argo Events chart version
    version: "2.10.11"
EOF
```

> Pinned `--version` flags only; **never** `releases/latest/download/<FILE>.yaml`.

## Apply

```sh
# 1) Prereq from earlier chapters — bookstore-ml namespace (ch.01) +
#    the recommender-model PVC + model.joblib (../train/, ch.04).
kubectl apply -f examples/bookstore/ml/train/recommender-train-job.yaml
kubectl wait --for=condition=complete job/recommender-train \
  -n bookstore-ml --timeout=300s
# (optional but expected for `promote`) the serving Deployment from ch.06:
kubectl apply -f examples/bookstore/ml/serve/recommender-deployment.yaml
kubectl apply -f examples/bookstore/ml/serve/recommender-service.yaml

# 2) The WorkflowTemplate + the per-namespace SA/Role/Binding.
kubectl apply -f examples/bookstore/ml/pipeline/recommender-workflow.yaml

# 3) Run the pipeline once (interactive; requires the `argo` CLI):
argo submit --from workflowtemplate/recommender-pipeline -n bookstore-ml
argo list -n bookstore-ml
argo logs -n bookstore-ml @latest
argo get  -n bookstore-ml @latest

# 4) Schedule nightly retraining (the CronWorkflow):
kubectl apply -f examples/bookstore/ml/pipeline/recommender-cronworkflow.yaml
kubectl get cronworkflow -n bookstore-ml

# 5) Event-driven retraining (the EventSource + Sensor, in `argo-events`):
kubectl apply -f examples/bookstore/ml/pipeline/recommender-eventsource.yaml
kubectl apply -f examples/bookstore/ml/pipeline/recommender-sensor.yaml
# Trigger it with a POST from inside the cluster (uses the EventSource Pod's
# Service, default port 12000):
kubectl run -n argo-events curl-once --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -X POST -H 'content-type: application/json' \
    -d '{"dataset_uri":"pvc://recommender-model/"}' \
    http://recommender-dataset-eventsource-svc:12000/recommender-dataset-ready
```

## What each step does (and what's the honest proxy)

| Step | Action | KIND-runnable proxy | Real prod shape |
|---|---|---|---|
| **train** | Runs `bookstore/recommender-train:dev` (`../train/Dockerfile`); writes `model.joblib` to PVC `recommender-model`. | Same Job, same image, same artifact as `../train/recommender-train-job.yaml`. | A Training Operator `PyTorchJob` / `RayJob` (`../train/recommender-pytorchjob.yaml`, `../train/recommender-rayjob.yaml`) on a GPU node pool. |
| **eval** | Loads `model.joblib`, computes average top-1 cosine similarity over all books, gates on `--min-score` (default `0.05`). | A `script` step in the SAME train image (sklearn + joblib already baked). Writes `metrics.json` to the PVC + emits `score` as an Argo output parameter. | A real offline metric (NDCG@k, MRR, AUC, …) computed against a held-out set, gated on a domain-relevant SLO. |
| **register** | Stamps `(model_uri, score, registered_at, workflow)` into a ConfigMap `recommender-model-registry-<WORKFLOW>`. | `kubectl create configmap` from inside the workflow Pod, namespace-scoped RBAC, illustrated by `register-cm-template.yaml`. | An **MLflow Model Registry** entry, a **KFP Model Registry** record, or an **OCI artifact** pushed to a registry — see Part 12 ch.07 + ch.08. |
| **promote** | Annotates the recommender Deployment + `rollout restart`s it so the serving Pod re-loads the new `model.joblib` from the PVC. | `kubectl annotate` + `kubectl rollout restart deploy/recommender`. | A **GitOps commit** (Part 07 ch.04) that bumps the `InferenceService` `storageUri` to a new versioned URI; **Argo CD** reconciles; **KServe** shifts traffic via `canaryTrafficPercent` (Part 12 ch.06). |

## How the pieces fit together with the rest of `ml/`

```
 ../dataset/   schema (synthetic)
        │
        ▼
 ../train/    image bookstore/recommender-train:dev  ─┐
        │    writes model.joblib to PVC              │
        ▼                                            │
   ★ pipeline/recommender-workflow.yaml ──> argo  ───┤  ← THIS DIR
   ★ pipeline/recommender-cronworkflow.yaml             │
   ★ pipeline/recommender-eventsource.yaml + sensor.yaml│
        │                                            │
        ▼                                            ▼
 ../serve/    image bookstore/recommender-serve:dev
              loads SAME model.joblib (Deployment OR KServe InferenceService)
```

## PSA, RBAC, and other invariants

- **PSA-`restricted`** on every workflow Pod — pod-level
  `securityContext` (runAsNonRoot, non-root UID 65532, seccomp RuntimeDefault)
  applied via the `WorkflowTemplate.spec.podSpecPatch`; container-level
  `securityContext` (allowPrivilegeEscalation:false, readOnlyRootFilesystem,
  drop ALL caps) on every step's container. The Argo Workflows *controller*
  lives in the operator's OWN namespace (`argo`); the workflow Pods live in
  `bookstore-ml`.
- **RBAC** scoped to one namespace: the `argo-workflow` SA can manage
  workflow Pods, ConfigMaps, and Deployments in `bookstore-ml` only — no
  cluster-wide rights, no secrets access.
- **No machine-specific paths / users** — image refs are
  `bookstore/recommender-train:dev` and `bookstore/recommender-serve:dev`
  (the same convention as `../train/` and `../serve/`); replace with a
  registry-pushed tag in prod.

## Honest "not built here"

See Part 12 ch.07/ch.08 for the deliberate scope boundaries (data versioning, feature stores, model explainability, drift detection, federated learning, multi-cluster training topologies, and the Kubeflow distribution itself).
