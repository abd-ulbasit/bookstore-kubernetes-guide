# `platform-base/` — the cluster-wide foundation

Cluster-scoped objects that every region applies before any tenant or
application workload lands. Applied by the root ApplicationSet
(`../argocd/applicationset-platform.yaml`) into each region.

| File | Kind(s) | Purpose |
|------|---------|---------|
| `00-namespaces.yaml` | `Namespace` × 3 | `bookstore-platform`, `bookstore-platform-system`, `bookstore-platform-ml`. All PSA `enforce: restricted`. |
| `01-rbac.yaml` | `ClusterRole` × 3 | `bookstore-platform-admin` (break-glass) · `bookstore-platform-operator` (platform team daily) · `bookstore-platform-tenant-admin` (bound per-tenant by the Composition). |
| `02-priorityclasses.yaml` | `PriorityClass` × 7 | Platform priority ladder (data > edge > critical > async > ml-serving > batch > ml-batch). |
| `03-kueue-clusterqueue.yaml` | `ClusterQueue`, `ResourceFlavor` | Cluster-wide Kueue fairness envelope for ML training (Part 12 ch.03 deepened in 13.08). |

## Per-tenant namespaces — NOT here

`bookstore-platform-<TENANT>` namespaces are created by the Crossplane
Composition in `../crossplane/composition-bookstoretenant.yaml`, not by this
directory. The split is deliberate: cluster-wide stays declarative + static;
per-tenant flows through the BookstoreTenant API (13.02) so tenant lifecycle
(create / update / delete) is one reconciliation loop, not a manual apply.

## Apply order

```sh
kubectl apply -f examples/bookstore-platform/platform-base/00-namespaces.yaml
kubectl apply -f examples/bookstore-platform/platform-base/01-rbac.yaml
kubectl apply -f examples/bookstore-platform/platform-base/02-priorityclasses.yaml
# 03-kueue-clusterqueue.yaml requires Kueue installed (Part 12 ch.03);
# CRD-intrinsic dry-run before install — expected and documented.
```

See [`../README.md`](../README.md) for the platform overview and
[`13-grand-capstone-bookstore-platform/01-bookstore-2-from-toy-to-platform.md`](../../../13-grand-capstone-bookstore-platform/01-bookstore-2-from-toy-to-platform.md)
for context.
