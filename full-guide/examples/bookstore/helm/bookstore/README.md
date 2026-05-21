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
# From the guide repo root (full-guide/), with the 4 images kind-loaded:
helm install bookstore ./examples/bookstore/helm/bookstore \
  -n bookstore --create-namespace
helm status  bookstore -n bookstore
helm uninstall bookstore -n bookstore
```

A plain `helm install` works on a vanilla cluster: every CRD-backed extra is
behind a toggle that defaults **off** where the CRD is not built in.

## Install / upgrade / uninstall

```sh
helm install  bookstore ./examples/bookstore/helm/bookstore -n bookstore --create-namespace
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
| `<SVC>.replicaCount` / `.resources` | matches raw manifests | Per-service scale + tuned requests/limits |
| `<SVC>.{topologySpread,podAntiAffinity,nodeSelector,tolerations,affinity}` | the raw-manifests scheduling layer | Overridable scheduling |
| `securityProfiles.*` | exact per-image restricted SC | The restricted model (rarely override) |
| `priorityClasses.create` | `true` | The 3 cluster-scoped PriorityClasses (annotated `helm.sh/resource-policy: keep`) |
| `migrationJob.enabled` | `true` | DB migrate Job as a **post-install/post-upgrade hook** (after the StatefulSet) |
| `cleanupCronJob.enabled` | `true` | Nightly cleanup CronJob (a normal release object) |
| `ingress.enabled` | `true` | Ingress edge (built-in API) — **XOR** `gateway` |
| `gateway.enabled` | `false` | Gateway API edge (CRD) — **XOR** `ingress` |
| `networkPolicy.enabled` | `true` | All 10 NetworkPolicies (enforcement needs a policy CNI) |
| `hpa.enabled` | `true` | catalog HPA (built-in `autoscaling/v2`) |
| `pdb.enabled` | `true` | catalog/storefront/orders PDBs (built-in `policy/v1`) |
| `canary.enabled` | `false` | Manual canary variant — **XOR** `catalog` |
| `serviceMonitor.enabled` | `false` | CRD (Prometheus Operator) |
| `prometheusRule.enabled` | `false` | CRD (Prometheus Operator) |
| `keda.enabled` | `false` | CRDs (KEDA) |
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
| `keda.enabled` | KEDA CRDs + operator | `helm install keda kedacore/keda -n keda --create-namespace` |
| `gateway.enabled` | Gateway API CRDs + a controller | Gateway API CRDs + e.g. the ingress-nginx Gateway impl |
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

## Validate without a cluster

```sh
helm lint examples/bookstore/helm/bookstore
helm template bookstore examples/bookstore/helm/bookstore -n bookstore | kubectl apply --dry-run=client -f -
```
