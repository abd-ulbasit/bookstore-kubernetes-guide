# Bookstore ML — the "recommendations" thread (Part 12)

This tree is the worked example for **Part 12 — Kubernetes for Machine
Learning**. It is **additive**: it does not modify the Bookstore app
(`../app/`), the canonical manifests (`../raw-manifests/`, `../helm/`,
`../kustomize/`), or any earlier `examples/bookstore/*` tree. Everything here is
new and lives in its own PSA-`restricted` namespace.

## The use case

A **recommendations** model: item-to-item *"customers who bought X also bought
Y"*, derived from the Bookstore's own data.

- **Dataset** — the Bookstore's `catalog` and `orders` data (the real schema
  the app uses; see [`../app/catalog/main.go`](../app/catalog/main.go) and
  [`../app/orders/main.go`](../app/orders/main.go)). Synthetic and *generated,
  not shipped* — see [`dataset/README.md`](dataset/README.md).
- **Model** — item co-occurrence / item-kNN. For each pair of books, count how
  often they appear in orders "together" (per customer/basket proxy), normalise
  (cosine / Jaccard over the co-occurrence matrix), and keep the top-K
  neighbours per book. This is a classic, **tiny, deterministic** recommender
  computed with NumPy/scikit-learn-class libraries — *no deep learning, no GPU
  required*.
- **Why deliberately tiny** — so the entire **train → register → serve** path
  runs **CPU-only on kind**, with zero GPU. GPUs are introduced (Part 12 ch.02)
  and gang/queue scheduling (ch.03) using this same model as the *"now scale
  training up"* example — honestly marked: those steps need a real GPU node
  pool, and a CPU fallback that genuinely runs is always provided.

## The plan (the MLOps loop, mapped to this tree)

```
 data ──► prep/train ──► evaluate ──► register ──► serve ──► monitor ──► retrain
   │           │                                     │
   └ catalog   └ co-occurrence + top-K              └ tiny HTTP API: GET
     + orders     (NumPy; CPU; 2-worker "gang"        /recommend?book_id=…
     (synthetic)   demo in ch.03)                      → top-K book ids
```

| Dir | Phase | Status |
|---|---|---|
| `dataset/` | data shape (synthetic, generated) | **this phase (X3a)** — stub |
| `gpu/` | a restricted GPU training Pod (the scale-up path) | **this phase (X3a)** — ch.02 |
| `batch/` | Kueue queue/flavor + a JobSet "training" (CPU, gang) | **this phase (X3a)** — ch.03 |
| `train/` | the real CPU training Job + model artifact | X3b (forward-ref) |
| `serve/` | the recommendations serving Deployment/KServe | X3b (forward-ref) |
| `pipeline/` | the whole loop as a pipeline | X3c (forward-ref) |

## The namespace contract (read this before applying anything)

Everything here targets the **`bookstore-ml`** namespace, which is labelled
**PSA `enforce: restricted`** (plus `audit` + `warn`), exactly like the app's
`bookstore` namespace ([Part 05 ch.02](../../../05-security/02-pod-security.md)).

```sh
kubectl create namespace bookstore-ml
kubectl label namespace bookstore-ml \
  app.kubernetes.io/part-of=bookstore-ml \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest --overwrite
```

**Every Pod in this tree is restricted-compliant**: `runAsNonRoot: true`, a
non-root `runAsUser`, `allowPrivilegeEscalation: false`,
`capabilities.drop: ["ALL"]`, `seccompProfile.type: RuntimeDefault`, and only
`restricted`-allowed volume types (`emptyDir`, `configMap`, `secret`,
`persistentVolumeClaim`, `projected`, `downwardAPI`). This matters: many
GPU/ML/notebook base images default to **root** and would be **rejected** by
PSA — Part 12 ch.02 teaches the compliant `securityContext` that still works on
a CUDA image. ML pods are **not** exempt from Pod Security.

## CRD-backed manifests here

`gpu/` is a plain `Job` (built-in — dry-runs cleanly). `batch/` contains
**CRD-backed** objects (Kueue `ResourceFlavor`/`ClusterQueue`/`LocalQueue`,
JobSet `JobSet`). Each such file's header carries the documented
**CRD-intrinsic** note (identical precedent to the guide's
`raw-manifests/51-`, `70-`, `83-`, the `argocd/`, `operators/`, `chaos/` files):
a client dry-run prints `no matches for kind "…"` until the operator/CRDs are
installed; **the schema is correct**. Install Kueue/JobSet via **pinned Helm**
(own namespaces) as the chapter shows — never
`kubectl apply -f .../releases/latest/download/<FILE>.yaml`.

## Operators and accelerators install elsewhere

The NVIDIA GPU Operator, Kueue, JobSet controller, and Volcano install into
their **own system namespaces** via pinned Helm charts (or the project's
pinned, documented installer) — see Part 12 ch.02 (GPU Operator) and ch.03
(Kueue/JobSet). They are infrastructure, not part of this tree.
