# Part 16 — GKE in production, A to Z

The GCP counterpart to [Part 14 (EKS)](../14-eks-in-production-a-to-z/), which is 17 chapters
and 94,241 words.

## The rule for this Part, which is different from every other Part

> **No chapter in Part 16 is written before its lab has been run against a real cluster,
> and every command in it is pasted from a terminal that executed it.**

Parts 00 to 15 were researched and drafted, then reviewed. That produced a good artifact and it
produced one specific weakness: nothing in it was executed. Part 16 inverts the order. The lab
comes first, the chapter is the write-up, and anything that could not be run does not get
claimed.

Practically this means Part 16 grows one chapter per lab session and is **incomplete on purpose**
until the labs are done. A short Part that was executed is worth more than a long one that was
not, and the difference is checkable by anyone who reads the commands.

Each chapter carries a header stating what was run, when, on what cluster version, and what it
cost:

```
**Executed:** 2026-09-14 · GKE 1.34.x REGULAR · asia-south1-a · 2 x e2-standard-2 spot
**Session cost:** $X.XX over 2h14m (from the billing export, not an estimate)
**What did not work first time:**
```

That last line is the one that makes the Part worth reading.

## Infrastructure

[`examples/gke/terraform/`](../examples/gke/terraform/) — a zonal GKE Standard cluster, spot
nodes, Workload Identity on, `deletion_protection = false` so teardown actually works, and an
optional budget alert. `make up`, `make status`, `make down`.

**Applied, verified and destroyed on 2026-09-03** against GKE 1.35.7-gke.1027000 in `asia-south1-a`,
using `hashicorp/google v6.50.0` and Terraform 1.14.8. Nine of ten checks passed on the first run
and both failures were defects in this repo, now fixed. See
[`examples/gke/README.md`](../examples/gke/README.md) for what broke.

## Chapter plan, mapped to Part 14

Fourteen chapters mirror an EKS chapter. Four have no EKS counterpart because they are the parts
of GKE that are genuinely different, and those four are the ones worth the most in an interview,
because they are where "I know Kubernetes" stops being portable.

| # | Chapter | Part 14 counterpart | The GCP-specific thing |
|---|---|---|---|
| 01 | Terraform state on GCS | 01 | GCS backend, object versioning, state locking |
| 02 | Cluster lifecycle and release channels | 02 | RAPID/REGULAR/STABLE, maintenance windows, surge upgrades |
| 03 | **Autopilot vs Standard** | none | The scale-to-zero-when-idle behaviour, and what Autopilot forbids |
| 04 | **Workload Identity** | 03 (partly) | The IRSA equivalent, and why the node SA should stay bare |
| 05 | Storage: PD CSI and StorageClasses | 04 | pd-balanced vs pd-ssd, regional PD, volume expansion |
| 06 | Cloud Logging and Monitoring cost | 05 | Per-GiB ingestion, and why SYSTEM_COMPONENTS is the default here |
| 07 | Cost guardrails | 06 | Budgets alert but never cap. Spot preemption. The free-tier credit |
| 08 | Infrastructure CI/CD and drift | 07 | Same shape, GCS backend |
| 09 | Private clusters, Cloud NAT, egress | 08 | Private Google Access, and where egress actually bills |
| 10 | **Dataplane V2 (eBPF)** | 15 (Cilium on EKS) | GKE ships Cilium as the managed dataplane. Network policy logging |
| 11 | Arm nodes: Axion / T2A | 09 (Graviton) | Multi-arch images, taints and tolerations |
| 12 | GitOps bootstrap on a fresh cluster | 10 | Argo CD, same as EKS |
| 13 | Supply chain: Artifact Registry, Binary Authorization | 12 | Attestations, and the admission path |
| 14 | **Gateway API on GKE** | none (EKS uses Ingress) | GKE ships Gateway API natively. This is where Ingress is going |
| 15 | Backup for GKE vs Velero | 14 | The managed service against the portable tool |
| 16 | Security posture and runtime | 13 | Workload vulnerability scanning, the posture dashboard |
| 17 | Multi-cluster and DR | 11, 17 | Fleets, Multi Cluster Ingress, Config Sync |

**Chapters 03, 04, 10 and 14 first.** They carry the most interview weight and the least overlap
with what a single-node k3s already teaches.

## What this Part buys that the ThinkPad cannot

The k3s box is single-node. Everything below needs more than one node or a cloud control plane,
which is exactly the gap `18-kubernetes.md` names as unbuyable at home:

- Cordon, drain, and watch pods reschedule somewhere real
- A node genuinely disappearing (spot preemption, 30 seconds notice)
- Zone topology, anti-affinity that can actually be satisfied
- A managed control plane you do not own and cannot SSH into
- Cloud IAM meeting Kubernetes RBAC, which is where most real cluster access bugs live
- A bill, which is its own lesson
