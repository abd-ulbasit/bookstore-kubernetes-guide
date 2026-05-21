# Bookstore — Kustomize base + overlays + components

This tree packages the **same cumulative Bookstore** (Parts 00–06) that
[`../raw-manifests/`](../raw-manifests/) and [`../helm/bookstore/`](../helm/bookstore/)
deploy — as a Kustomize **base** plus **dev / staging / prod overlays** and
opt-in **components** for the CRD-backed / variant extras. The full teaching
walkthrough is [`07-delivery/02-packaging-kustomize.md`](../../../07-delivery/02-packaging-kustomize.md).

> Kustomize is built into `kubectl` — `kubectl kustomize <DIR>` renders,
> `kubectl apply -k <DIR>` renders **and** applies. A standalone `kustomize`
> binary also works (`kustomize build <DIR>`); mind version skew — the
> embedded Kustomize lags the standalone release. All commands below are run
> from the **guide repo root** (`full-guide/`).

## Layout

```
examples/bookstore/kustomize/
├── base/                         # the deployable app — renders the canonical 49-object set
│   ├── kustomization.yaml        # resources + namespace + labels: + images:
│   └── 00-…84-*.yaml             # 19 VENDORED byte-identical copies of the in-scope raw-manifests
├── overlays/
│   ├── dev/kustomization.yaml    # 1 replica, debug, no HPA/PDB, host bookstore.dev.local        → 45 objects
│   ├── staging/kustomization.yaml# 2 replicas, moderate, HPA/PDB on, bookstore.staging.example.com → 49 objects
│   └── prod/kustomization.yaml   # 4/3/3 replicas, tuned, registry images, demo Secret OFF        → 48 objects
└── components/                   # kind: Component — opt-in, each documents its CRD prereq
    ├── servicemonitor/           # + ServiceMonitor×2 + PrometheusRule   (Prometheus Operator CRDs)
    ├── keda/                     # + ScaledObject + TriggerAuth + Secret (KEDA CRDs)
    ├── gateway/                  # SWAPS Ingress → GatewayClass/Gateway/HTTPRoute (Gateway API CRDs)
    ├── kyverno/                  # + ClusterPolicy (Audit)               (Kyverno CRD; cluster-scoped)
    ├── snapshot/                 # + VolumeSnapshotClass + VolumeSnapshot (external-snapshotter CRDs)
    └── canary/                   # SWAPS catalog → catalog-stable + catalog-canary (NO CRD needed)
```

## Render / apply each environment

```sh
# Render (read what would be applied — the habit that keeps overlays honest)
kubectl kustomize examples/bookstore/kustomize/base
kubectl kustomize examples/bookstore/kustomize/overlays/dev

# Sanity-check against the API server without applying
kubectl kustomize examples/bookstore/kustomize/overlays/prod | kubectl apply --dry-run=client -f -

# Apply (self-bootstrapping prerequisites are in the chapter — fresh kind,
# `kind load` the four bookstore/*:dev images, THEN:)
kubectl apply -k examples/bookstore/kustomize/overlays/dev
kubectl get pods -n bookstore -w
```

`kubectl apply -k overlays/<ENV>` creates the `bookstore` namespace
(PSA-`restricted`-labelled), every object, and the db-migrate Job. There is
**no separate apply-order chain** — Kustomize emits one ordered stream
(namespace and cluster-scoped first). After any `kind delete && kind create`
you must re-`kind load` the four images and re-run `kubectl apply -k`.

## Design decisions (and why)

**Vendored copies, not `../../raw-manifests` references.** `base/` holds
byte-identical copies of the 19 in-scope raw manifests (verified with `cmp`).
They are *not* referenced as `resources: ../../raw-manifests/<F>.yaml` because
Kustomize's default **load restrictor** (`RootOnly`) refuses any `resources:`
path outside the kustomization root, and `kubectl apply -k` does **not**
expose `--load-restrictor`. Vendoring keeps the tree self-contained, makes
`kubectl apply -k` work with zero special flags, and keeps it consumable by
Argo CD / Flux (which also default to the restricted loader). The trade-off —
two copies that could drift — is mitigated by the chapter's equivalence check
(rendered base ≡ the Helm default 49-object set, `DB_DSN` byte-identical).

**Namespace stays `bookstore` across all envs.** `DB_DSN` /
`AMQP_URL` / the postgres headless-Service DNS / the NetworkPolicy
`namespaceSelectors` all hardcode `bookstore`. Renaming the namespace per env
would silently break those cross-resource references unless every one were
rewritten coherently — a much larger, error-prone change for no real benefit
in this guide. Environments are separated by overlay (and, in a real cluster,
by separate clusters or by RBAC), not by namespace string. The `namespace:`
transformer in `base/` does **not** stamp a namespace onto the cluster-scoped
PriorityClasses (verified) — they render namespace-free, as required.

**`labels:` transformer, never `commonLabels`.** Additive metadata labels
(`app.kubernetes.io/managed-by: kustomize` in base,
`app.kubernetes.io/environment: <ENV>` per overlay) use the modern `labels:`
transformer with **`includeSelectors: false`** (and `includeTemplates:
false`). `commonLabels` injects labels into `spec.selector.matchLabels` and
Service selectors, which are **immutable** on Deployment/StatefulSet — an
overlay adding a label that way makes the first `kubectl apply` of an upgrade
**fail** with "field is immutable". With `includeSelectors:false` the
rendered `.spec.selector` is **byte-identical in base and every overlay**
(verified). This footgun is taught in detail in the chapter.

**Static demo Secret (no `secretGenerator`).** `16-db-credentials.yaml` is
kept as a static manifest so its **demo-only / base64-≠-encryption** warning
travels verbatim and the catalog/orders `DB_DSN` stays byte-identical. The
**prod** overlay `$patch: delete`s it entirely — in production a Secret of the
same name is supplied out of band by **External Secrets Operator / Sealed
Secrets / Vault** (the `secretKeyRef`/`envFrom` references resolve it at
runtime; the env-built DSN is unchanged). `configMapGenerator`/
`secretGenerator` (content-hash suffix → rollout-on-change) and
`generatorOptions.disableNameSuffixHash` are taught conceptually in the
chapter.

## Components and their CRD prerequisites

Each component is `kind: Component`. Enable it by adding to an overlay's
`components:` list — exactly the analog of a Helm value toggle. Base stays
vanilla-cluster-clean (zero `no matches for kind` on a plain cluster).

| Component | Adds / changes | Prerequisite (install first) |
|---|---|---|
| `servicemonitor` | + ServiceMonitor×2, PrometheusRule | Prometheus Operator CRDs — `helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace` |
| `keda` | + ScaledObject, TriggerAuthentication, `rabbitmq-conn` Secret | KEDA — `helm install keda kedacore/keda -n keda --create-namespace` |
| `gateway` | **SWAPS** Ingress → GatewayClass + Gateway + HTTPRoute | Gateway API CRDs + a controller (`kubectl apply -f .../gateway-api/releases/download/v1.1.0/standard-install.yaml`, then a controller) |
| `kyverno` | + `ClusterPolicy` (Audit-only; cluster-scoped) | Kyverno — `helm install kyverno kyverno/kyverno -n kyverno --create-namespace` |
| `snapshot` | + VolumeSnapshotClass + VolumeSnapshot | external-snapshotter CRDs + controller + a snapshot-capable CSI driver |
| `canary` | **SWAPS** `catalog` → `catalog-stable` + `catalog-canary` (and deletes the base catalog **HPA** so it is not orphaned) | none (built-in Deployments only) |

Enabling a CRD-backed component before its CRD is installed produces, on a
client dry-run, the **expected** `no matches for kind …` for that component's
objects only — every built-in object still validates. This is the identical
intrinsic behaviour of the raw manifests (`80-`/`83-`/…) and the Helm toggles.
Install the operator with **Helm / the official stable manifest** (never a
`releases/latest/download/<PINNED-FILE>.yaml` URL — it 404s when a new release
ships), then the same component applies cleanly.

Example overlay enabling components (note `gateway` swaps the Ingress; the
`canary` component removes the base catalog Deployment **and its HPA** itself,
so an overlay enabling `canary` must NOT also `$patch: delete` the HPA — two
patches deleting the same resource id is a kustomize error):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
components:
  - ../../components/servicemonitor
  - ../../components/keda
```

## Validation (run from the guide repo root)

```sh
# Renders, deterministically, with zero CRD errors in base:
kubectl kustomize examples/bookstore/kustomize/base | kubectl apply --dry-run=client -f -

# commonLabels must NOT be used (only taught in comments):
grep -rnE '^[[:space:]]*commonLabels[[:space:]]*:' examples/bookstore/kustomize/   # → no matches

# Selectors identical base vs every overlay (the commonLabels-immutability proof):
#   diff the .spec.selector of each Deployment/StatefulSet between
#   `kubectl kustomize base` and `kubectl kustomize overlays/<ENV>` — identical.

# Restricted-admission proof: server dry-run into a throwaway `restricted` ns
# (strip the Namespace + cluster-scoped kinds + the hardcoded namespace line).
```
