# Bookstore Platform v2 — reference implementation

The worked reference for **Part 13 — Grand Capstone**. Sibling to (not a
fork of) [`../bookstore/`](../bookstore/), which remains the threadable v1
example for Parts 00 - 12. Both trees co-exist; chapters explicitly contrast
v1 vs v2 where the lesson asks for it.

## What lives here

```
examples/bookstore-platform/
  README.md                          ← you are here
  clusters/                          ← three-region kind topology (Part 13.01/.03)
  platform-base/                     ← cluster-wide platform stack (namespaces, RBAC, priority, Kueue)
  kustomize/                         ← base + per-region overlays (Part 13.01/.03)
    base/
    regions/{us-east,eu-west,ap-southeast}/
  helm/                              ← (Phase 13b) platform Helm umbrella chart
  argocd/                            ← root ApplicationSet + system Applications (Part 13.02/.03/.04)
  crossplane/                        ← BookstoreTenant XRD + Composition + sample claim (Part 13.02)
  auth/                              ← Keycloak realm + Istio RequestAuth + AuthZ + IRSA pattern (Part 13.04)
  app/                               ← (Phase 13b) v2 service source: search, payments-gateway, events, recommendations
  observability/                     ← (Phase 13c) OTel + Tempo + Loki + Prom + Grafana
  cost/                              ← (Phase 13c) OpenCost dashboards
  backstage/                         ← (Phase 13c) software catalog + scaffolder
  runbooks/                          ← (Phase 13c) day-2 runbooks + DR drill + chaos game-day
```

Phase 13a (this phase) populates `clusters/`, `platform-base/`, `kustomize/`,
`argocd/`, `crossplane/`, `auth/`. Phases 13b/c fill the rest.

## Why a second tree at all

The v1 Bookstore at `../bookstore/` has hard invariants the rest of the
guide depends on (Helm chart renders 49 objects; Kustomize overlays render
45 / 49 / 48; specific DB_DSN). Touching it to add multi-tenancy, multi-
region, OIDC, etc. would break those invariants and the chapter cross-refs
they anchor. The v2 platform is a separate worked reference so the v1 stays
exactly as Parts 00 - 09 left it, and the v2 can be much larger without
constraint. The README's Part 13 introduction reads them side-by-side.

## Kind-runnable path (Phase 13a)

```sh
# 1. Three regions
./examples/bookstore-platform/clusters/kind-3-region.sh

# 2. Platform-base into each (idempotent re-apply)
for ctx in \
  kind-bookstore-platform-us-east \
  kind-bookstore-platform-eu-west \
  kind-bookstore-platform-ap-southeast
do
  kubectl --context "$ctx" apply -f examples/bookstore-platform/platform-base/00-namespaces.yaml
  kubectl --context "$ctx" apply -f examples/bookstore-platform/platform-base/01-rbac.yaml
  kubectl --context "$ctx" apply -f examples/bookstore-platform/platform-base/02-priorityclasses.yaml
done

# 3. Confirm
kubectl --context kind-bookstore-platform-us-east \
  get ns -l app.kubernetes.io/part-of=bookstore-platform
```

After this, 13.02's hands-on installs Crossplane + applies the XRD +
Composition + sample BookstoreTenant; 13.04's hands-on installs Keycloak +
applies the Istio policies. CRD-backed manifests dry-run with the documented
`no matches for kind` until their CRDs install — same precedent as every
other example tree in the guide.

## What's intentionally NOT here

- Workload manifests for storefront / catalog / orders / payments-worker.
  Those start from the v1 tree at `../bookstore/` and get extended in
  Phase 13b (`app/` + new services + per-tenant Kustomize overlays).
- A production secret of any kind. Every secret in source is a labelled
  placeholder (`REPLACE-ME-VIA-ESO-NOT-IN-SOURCE`). Real wiring goes through
  ESO + Vault (Part 11 ch.05) or Sealed Secrets.
- A cloud-specific Terraform / IaC stack. The cloud-resource path in
  Crossplane (CNPG, S3, IRSA) is sketched and commented; real cluster +
  network provisioning is Part 10 territory.

## Cross-references

- [`../../README.md`](../../README.md) — the full guide TOC.
- [`../bookstore/`](../bookstore/) — the v1 Bookstore (every prior Part).
- [`../../13-grand-capstone-bookstore-platform/01-bookstore-2-from-toy-to-platform.md`](../../13-grand-capstone-bookstore-platform/01-bookstore-2-from-toy-to-platform.md) — the Part 13 introduction (v1 vs v2).
- [`../../11-advanced-production-patterns/02-operator-development.md`](../../11-advanced-production-patterns/02-operator-development.md) — the X2a `BookstoreTenant` operator. Contrast with 13.02 (operator vs Composition).
- [`../../11-advanced-production-patterns/10-platform-engineering.md`](../../11-advanced-production-patterns/10-platform-engineering.md) — the X2c platform engineering chapter. The Crossplane primitive 13.02 deepens.
- [`../../10-cloud-and-managed-kubernetes/03-cloud-identity.md`](../../10-cloud-and-managed-kubernetes/03-cloud-identity.md) — IRSA / Workload Identity. The cloud-side wiring 13.04 ties to.
