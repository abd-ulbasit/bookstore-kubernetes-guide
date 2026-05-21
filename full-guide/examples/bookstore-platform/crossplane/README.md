# `crossplane/` — tenant onboarding as a Composition

Three files that together turn "onboard a tenant" into a single
`kubectl apply`. Walk-through in
[`13-grand-capstone-bookstore-platform/02-tenancy-and-crossplane-onboarding.md`](../../../13-grand-capstone-bookstore-platform/02-tenancy-and-crossplane-onboarding.md).

| File | Kind | Purpose |
|------|------|---------|
| `xrd-bookstoretenant.yaml` | `CompositeResourceDefinition` (v2, `scope: Cluster`) | Declares the new `BookstoreTenant` API. |
| `composition-bookstoretenant.yaml` | `Composition` (Pipeline + function-patch-and-transform) | The recipe: ns + Quota + LimitRange + RoleBinding + NetworkPolicy + Kueue LocalQueue per tenant. |
| `sample-claim-acme-books.yaml` | `BookstoreTenant` | Example XR for the fictional "Acme Books" customer. |

## Why `scope: Cluster` (not the Part 11 ch.10 namespaced XR)

A namespaced XR cannot own a cluster-scoped Namespace via `ownerReferences`,
so deleting the XR leaks the per-tenant ns. Cluster scope plus an explicit
finalizer cleans up correctly. 13.02 explains the trade-off in detail and
contrasts with the Part 11 ch.10 `BookstoreEnvironment` choice.

## Install order

```sh
CROSSPLANE_CHART_VERSION="1.17.0"
FN_PT_VERSION="v0.8.2"

helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane \
  --version "$CROSSPLANE_CHART_VERSION" -n crossplane-system --create-namespace --wait

# provider-kubernetes (for in-cluster Object creation)
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata: { name: provider-kubernetes }
spec: { package: xpkg.crossplane.io/crossplane-contrib/provider-kubernetes:v0.13.0 }
EOF
kubectl wait --for=condition=Healthy provider/provider-kubernetes --timeout=300s

# function-patch-and-transform (Composition pipeline function)
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata: { name: function-patch-and-transform }
spec: { package: xpkg.crossplane.io/crossplane-contrib/function-patch-and-transform:${FN_PT_VERSION} }
EOF
kubectl wait --for=condition=Healthy function/function-patch-and-transform --timeout=180s

# Now the XRD + Composition + sample XR
kubectl apply -f examples/bookstore-platform/crossplane/xrd-bookstoretenant.yaml
kubectl wait --for=condition=Established \
  crd/bookstoretenants.platform.bookstore.example.com --timeout=120s
kubectl apply -f examples/bookstore-platform/crossplane/composition-bookstoretenant.yaml
kubectl apply -f examples/bookstore-platform/crossplane/sample-claim-acme-books.yaml

# Verify
kubectl get bookstoretenant
kubectl get ns,resourcequota,limitrange,networkpolicy,localqueue \
  -n bookstore-platform-acme-books
```

## CRD-intrinsic dry-runs

All three files dry-run with the documented `no matches for kind` error
before Crossplane and the XRD exist. That is expected and the same precedent
as every other CRD-backed manifest in the guide (operator/, argocd/,
multicluster/, raw-manifests/{51,70,83}-, etc.).
