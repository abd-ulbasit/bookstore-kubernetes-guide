# `clusters/` — the three-region local topology

The Bookstore Platform v2 runs as **three active-active regional clusters**.
In production those are EKS / GKE / AKS clusters in three real cloud regions;
locally we stand them up as three `kind` clusters and `argocd cluster add`
them to a single Argo CD instance running in the us-east cluster.

| File | Cluster | Role | apiServerPort |
|------|---------|------|---------------|
| `kind-us-east.yaml` | `bookstore-platform-us-east` | Writer (CNPG primary) | 36443 |
| `kind-eu-west.yaml` | `bookstore-platform-eu-west` | Reader (CNPG standby) | 36444 |
| `kind-ap-southeast.yaml` | `bookstore-platform-ap-southeast` | Reader (CNPG standby) | 36445 |
| `kind-3-region.sh` | (all three) | Idempotent spin-up | — |

Each cluster gets `topology.kubernetes.io/region`, `topology.kubernetes.io/zone`,
and `bookstore-platform.example.com/role` node labels (writer | reader) so
13.03 can run topology-aware pod placement and pin the CNPG primary to the
writer region.

## What kind cannot simulate

- Real cross-region latency (us-east -> eu-west is ~80 ms RTT on the
  Internet; localhost is sub-millisecond — so CNPG replication appears
  instantaneous on kind).
- Real DNS-based latency routing (we use `/etc/hosts` flips in the DR drill).
- Real sovereign data residency (a kind "region" is just a label; a real
  region is a legal/regulatory boundary).

Those gaps are documented in
[`13-grand-capstone-bookstore-platform/03-multi-region-active-active.md`](../../../13-grand-capstone-bookstore-platform/03-multi-region-active-active.md).

## Run

```sh
./examples/bookstore-platform/clusters/kind-3-region.sh
kubectl config get-contexts | grep bookstore-platform
```

Teardown:

```sh
kind delete cluster --name bookstore-platform-us-east
kind delete cluster --name bookstore-platform-eu-west
kind delete cluster --name bookstore-platform-ap-southeast
```
