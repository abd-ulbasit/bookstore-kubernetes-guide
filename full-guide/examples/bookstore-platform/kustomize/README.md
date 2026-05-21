# `kustomize/` — base + per-region overlays

The ApplicationSet Cluster generator (`../argocd/applicationset-platform.yaml`)
points each region's cluster at the matching overlay below.

```
kustomize/
  base/                          ← platform-base resources + common labels
  regions/
    us-east/                     ← + region=us-east, role=writer
    eu-west/                     ← + region=eu-west, role=reader
    ap-southeast/                ← + region=ap-southeast, role=reader
```

## Render

```sh
kubectl kustomize examples/bookstore-platform/kustomize/base
kubectl kustomize examples/bookstore-platform/kustomize/regions/us-east
kubectl kustomize examples/bookstore-platform/kustomize/regions/eu-west
kubectl kustomize examples/bookstore-platform/kustomize/regions/ap-southeast
```

## Why three identical-shaped overlays

The overlays look almost identical and that is the point: every region runs
the SAME platform stack, with only labels + annotations distinguishing them.
The DIFFERENCE between writer and reader is enforced by:

- Pod placement (CNPG primary nodeSelector pins to
  `bookstore-platform.example.com/role: writer`) — that resource lands in a
  later phase, not in Phase 13a.
- DNS routing (the writer hostname is the platform's apex; readers serve
  region-local traffic) — handled by the edge in 13.07 (Phase 13b).

Keep the overlays small; let the workloads do their own region-awareness via
labels they read at runtime.
