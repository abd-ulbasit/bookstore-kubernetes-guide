# Bookstore Helm chart

The **Bookstore** application (storefront, catalog, orders, payments-worker,
postgres, redis, rabbitmq) packaged as one idiomatic Helm 3 chart. It renders
the **same logical app** as `examples/bookstore/raw-manifests/` (the cumulative
Parts 00–06 manifests), minus the `01-`/`02-` bare-Pod teaching seeds and the
apiserver-level `examples/bookstore/cluster/` files. Every restricted
`securityContext`, the Part 04 scheduling layer, the byte-identical
catalog/orders `DB_DSN`, and the namespace Pod Security Admission `restricted`
labels are preserved exactly (see `templates/_helpers.tpl`).

This chart is taught in [Part 07 ch.01 — Packaging with
Helm](../../../../07-delivery/01-packaging-helm.md).

## TL;DR

```sh
# From the guide repo root (full-guide/), with the 4 images kind-loaded.
# Helm cannot install the chart's own Namespace object, so create the
# namespace first with the PSA labels (the chapter explains why).
kubectl create namespace bookstore
kubectl label namespace bookstore \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
helm install bookstore ./examples/bookstore/helm/bookstore \
  -n bookstore --set namespace.create=false
helm status  bookstore -n bookstore
helm uninstall bookstore -n bookstore
```

A plain `helm install` works on a vanilla cluster: every CRD-backed extra is
behind a toggle that defaults **off** where the CRD is not built in.

## Install / upgrade / uninstall

```sh
helm install  bookstore ./examples/bookstore/helm/bookstore -n bookstore --set namespace.create=false   # namespace pre-created and labelled
helm upgrade  bookstore ./examples/bookstore/helm/bookstore -n bookstore -f values-staging.yaml
helm rollback bookstore 1 -n bookstore
helm uninstall bookstore -n bookstore        # PriorityClasses are kept (resource-policy: keep)
```

Per-environment value files are provided: `values-dev.yaml`,
`values-staging.yaml`, `values-prod.yaml` (replica/resource/host/toggle
differences; prod disables the demo Secret).

## Values

The complete, documented default set is in
[`values.yaml`](values.yaml); a JSON Schema (`values.schema.json`) validates
the toggles and image blocks. Highlights:

| Key | Default | Effect |
|---|---|---|
| `namespace.create` / `namespace.psa` | `true` / `restricted` | Templates the ns with PSA `restricted` (+ audit/warn) + ResourceQuota + LimitRange |
| `<SVC>.image.{repository,tag,pullPolicy}` | `bookstore/<SVC>` `:dev` `IfNotPresent` | Per-service image |
| `<SVC>.image.digest` | set on redis, rabbitmq and postgres only | Pins a third-party image by digest; it takes precedence over `tag` |
| `<SVC>.replicaCount` / `.resources` | matches raw manifests | Per-service scale + tuned requests/limits |
| `<SVC>.{topologySpread,podAntiAffinity,nodeSelector,tolerations,affinity}` | the raw-manifests scheduling layer | Overridable scheduling |
| `securityProfiles.*` | exact per-image restricted SC | The restricted model (rarely override) |
| `priorityClasses.create` | `true` | The 3 cluster-scoped PriorityClasses (annotated `helm.sh/resource-policy: keep`) |
| `migrationJob.enabled` | `true` | DB migrate Job as a **post-install/post-upgrade hook** (after the StatefulSet) |
| `cleanupCronJob.enabled` | `true` | Nightly cleanup CronJob (a normal release object) |
| `ingress.enabled` | `true` | Ingress edge (built-in API) — **XOR** `gateway` |
| `ingress.traefikRewrite.enabled` | `false` | Traefik Middleware that strips `/api` (CRD) plus the annotation that attaches it; the services serve `/books` and `/orders` |
| `gateway.enabled` | `false` | Gateway API edge (CRD) — **XOR** `ingress` |
| `networkPolicy.enabled` | `true` | All 10 NetworkPolicies (enforcement needs a policy CNI) |
| `hpa.enabled` | `true` | catalog HPA (built-in `autoscaling/v2`) |
| `pdb.enabled` | `true` | catalog/storefront/orders PDBs (built-in `policy/v1`) |
| `canary.enabled` | `false` | Manual canary variant — **XOR** `catalog` |
| `serviceMonitor.enabled` | `false` | CRD (Prometheus Operator) |
| `prometheusRule.enabled` | `false` | CRD (Prometheus Operator) |
| `keda.enabled` | `false` | CRDs (KEDA); needs `keda.connectionSecretName` |
| `keda.connectionSecretName` | `""` | Name of an existing Secret (key `host`, the AMQP URL) that you create; the chart renders none, and the render fails if `keda.enabled` is set without it |
| `kyverno.enabled` | `false` | CRD (Kyverno) — Audit-only policy |
| `snapshot.enabled` | `false` | CRDs (external-snapshotter) + snapshot-capable CSI |

### Mutually exclusive toggles (the chart fails the render if violated)

- `ingress.enabled` **XOR** `gateway.enabled` — both would bind the same
  hostname/paths via two data planes (`50-ingress.yaml` vs `51-gateway.yaml`).
- `catalog.enabled` **XOR** `canary.enabled` — both define `app: catalog` Pods
  and a `catalog` Service (`30-catalog-canary.yaml` lineage).

## CRD-backed toggles and their operator prerequisites

These default **off** so a plain install on a vanilla cluster succeeds. When
you turn one **on**, the templated object is schema-correct, but it needs the
CRD/operator below or the API server rejects it with `no matches for kind ...`
(the same intrinsic behaviour the raw manifests document for `80-`/`83-`/etc.):

| Toggle | Needs | Install |
|---|---|---|
| `serviceMonitor.enabled` / `prometheusRule.enabled` | Prometheus Operator CRDs | `helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace` |
| `keda.enabled` | KEDA CRDs + operator, and a Secret you create | Install KEDA from a pinned chart into a labelled namespace (Part 07 ch.01), then `kubectl create secret generic` the connection Secret and set `keda.connectionSecretName` |
| `ingress.traefikRewrite.enabled` | Traefik CRDs (`traefik.io/v1alpha1` Middleware) | The Traefik chart installs them (Part 02 ch.04 step 2) |
| `gateway.enabled` | Gateway API CRDs + a controller | Gateway API standard CRDs + Traefik with its Gateway provider (Part 02 ch.05 step 1 gives the install and the CRD version; `gateway.controllerName` defaults to `traefik.io/gateway-controller`; change it for another implementation) |
| `kyverno.enabled` | Kyverno | `helm install kyverno kyverno/kyverno -n kyverno --create-namespace` |
| `snapshot.enabled` | external-snapshotter CRDs + controller + a snapshot-capable CSI driver | (cloud disk CSI / csi-hostpath-driver) |

> The `release` label on the ServiceMonitor/PrometheusRule **must** match
> kube-prometheus-stack's `serviceMonitorSelector`/`ruleSelector`. The default
> (`kube-prometheus-stack`) matches the guide's Part 06 ch.01 install.

## The demo Secret

`dbCredentials.create=true` ships a literal Postgres password from
`values.yaml`. A Secret is base64, **not** encrypted. This is acceptable only
because the guide is a throwaway local lab. In production set
`dbCredentials.create=false` and provide a Secret named `db-credentials` via
External Secrets Operator / Sealed Secrets / Vault (this is what
`values-prod.yaml` does).

The KEDA scaler's AMQP URL holds a credential too, so the chart never renders
a Secret for it and holds no default. With `keda.enabled=true` you create a
Secret with the key `host` yourself and name it in `keda.connectionSecretName`;
the render fails with a message if you do not.

## Validate without a cluster

```sh
helm lint examples/bookstore/helm/bookstore
helm template bookstore examples/bookstore/helm/bookstore -n bookstore | kubectl apply --dry-run=client -f -
```
