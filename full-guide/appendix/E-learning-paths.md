# Appendix E — Learning paths

> Ordered ways through **this guide**. Every link is a real chapter in this
> repository; the guide is standalone, so these map *its* chapters — they do not
> assume any other notes. Four paths: a one-week **Fast track**, the full
> **Zero-to-production** arc, an **Exam-oriented** mapping to CKAD/CKA/CKS, and a
> **Platform/SRE/ops** track. Each path lists ordered chapter links, a one-line
> "why this order", what it honestly **skips**, and ends at the same finish
> line: the
> [end-to-end Bookstore](../09-end-to-end-bookstore/01-bookstore-end-to-end.md)
> (the right finish for Parts 00 - 09; readers continuing into the
> **production-reality** material then cross into the
> [Bookstore Platform v2 grand capstone](../13-grand-capstone-bookstore-platform/12-day-2-runbook-on-call-dr-chaos.md)
> after Parts 10 - 12).

Reference material — no nine-section anatomy. Keep [Appendix A —
cheatsheet](A-kubectl-cheatsheet.md) and [Appendix B — glossary](B-glossary.md)
open while you work through any path.

---

## Path 1 — Fast track (~1 week): deploy & operate an app

The minimum coherent path to *deploy a real app and keep it running*. It
deliberately skips internals depth, scheduling theory, the full security/
delivery arc, and day-2 — you can deploy and debug, not yet harden or
GitOps-deliver.

| # | Chapter | Why here |
|---|---|---|
| 1 | [00-foundations/01 — Why Kubernetes](../00-foundations/01-why-kubernetes.md) | The problem it solves; declarative vs imperative |
| 2 | [00-foundations/03 — Architecture overview](../00-foundations/03-architecture-overview.md) | The parts you'll talk to (skip 04/05 deep dives for now) |
| 3 | [00-foundations/06 — The declarative API model](../00-foundations/06-declarative-api-model.md) | The one mental model everything else is a variation of |
| 4 | [00-foundations/07 — Local cluster setup](../00-foundations/07-local-cluster-setup.md) | A real local cluster + the everyday `kubectl` verbs |
| 5 | [01-core-workloads/01 — Pods](../01-core-workloads/01-pods.md) | The unit you actually run |
| 6 | [01-core-workloads/02 — Health and lifecycle](../01-core-workloads/02-health-and-lifecycle.md) | Probes — without these nothing is production-real |
| 7 | [01-core-workloads/04 — ReplicaSets and Deployments](../01-core-workloads/04-replicasets-and-deployments.md) | Self-healing, rolling updates, rollback |
| 8 | [02-networking/02 — Services](../02-networking/02-services.md) | Stable in-cluster endpoints |
| 9 | [02-networking/04 — Ingress](../02-networking/04-ingress.md) | Reach the app from outside |
| 10 | [03-config-and-storage/01 — ConfigMaps](../03-config-and-storage/01-configmaps.md) | Externalize config |
| 11 | [03-config-and-storage/02 — Secrets](../03-config-and-storage/02-secrets.md) | Credentials (and why base64 ≠ encryption) |
| 12 | [03-config-and-storage/04 — Persistent storage](../03-config-and-storage/04-persistent-storage.md) | The app's database needs durable storage |
| 13 | [08-day-2-operations/03 — Troubleshooting playbook](../08-day-2-operations/03-troubleshooting-playbook.md) | When it breaks: the method + `kubectl debug` |
| 14 | [09-end-to-end-bookstore/01 — Bookstore end-to-end](../09-end-to-end-bookstore/01-bookstore-end-to-end.md) | Stand the whole thing up (skim the GitOps/DR sections) |

**Why this order:** model → real cluster → run a workload → expose it →
configure it → persist data → debug it → see it whole. **Skips (be honest):**
control-plane/node internals, StatefulSets/DaemonSets/Jobs depth, scheduling,
the full security hardening, observability/autoscaling, Helm/Kustomize/GitOps,
and most of day-2 (troubleshooting is included; cluster
upgrades/backup-DR/multi-tenancy/operators are skipped). Do the full arc
(Path 2) before running anything you care about in production.

---

## Path 2 — Zero-to-production (the full arc)

Parts 00→09 in order. This is how the guide is meant to be read: the Bookstore
manifests are cumulative, each chapter adds one field/primitive to the *same*
app. Nothing is skipped. Time estimates assume the hands-on is actually run on a
local cluster.

| Part | Chapters | Est. | Why this order |
|---|---|---|---|
| **00 Foundations** | [01](../00-foundations/01-why-kubernetes.md) · [02](../00-foundations/02-containers-and-images.md) · [03](../00-foundations/03-architecture-overview.md) · [04](../00-foundations/04-control-plane-deep-dive.md) · [05](../00-foundations/05-node-components.md) · [06](../00-foundations/06-declarative-api-model.md) · [07](../00-foundations/07-local-cluster-setup.md) | 6–9 h | Containers → architecture → internals → the declarative model → a real cluster, before any workload |
| **01 Core Workloads** | [01](../01-core-workloads/01-pods.md) · [02](../01-core-workloads/02-health-and-lifecycle.md) · [03](../01-core-workloads/03-resources-and-qos.md) · [04](../01-core-workloads/04-replicasets-and-deployments.md) · [05](../01-core-workloads/05-statefulsets.md) · [06](../01-core-workloads/06-daemonsets.md) · [07](../01-core-workloads/07-jobs-and-cronjobs.md) · [08](../01-core-workloads/08-deployment-strategies.md) | 8–12 h | Pod → health → resources → controllers; stateful/daemon/batch; how to roll changes |
| **02 Networking** | [01](../02-networking/01-networking-model.md) · [02](../02-networking/02-services.md) · [03](../02-networking/03-dns-and-discovery.md) · [04](../02-networking/04-ingress.md) · [05](../02-networking/05-gateway-api.md) · [06](../02-networking/06-network-policies.md) | 6–9 h | Model → Services → DNS → edge (Ingress/Gateway) → segmentation |
| **03 Config & Storage** | [01](../03-config-and-storage/01-configmaps.md) · [02](../03-config-and-storage/02-secrets.md) · [03](../03-config-and-storage/03-volumes.md) · [04](../03-config-and-storage/04-persistent-storage.md) · [05](../03-config-and-storage/05-stateful-data-patterns.md) | 5–8 h | Config → secrets → volumes → PV/PVC → operating stateful data |
| **04 Scheduling** | [01](../04-scheduling/01-scheduler-and-nodes.md) · [02](../04-scheduling/02-affinity-taints-topology.md) · [03](../04-scheduling/03-priority-and-preemption.md) | 3–5 h | How placement is decided → steering it → priority/preemption |
| **05 Security** | [01](../05-security/01-authn-authz-rbac.md) · [02](../05-security/02-pod-security.md) · [03](../05-security/03-supply-chain.md) · [04](../05-security/04-secrets-and-cluster-hardening.md) | 6–9 h | Identity/RBAC → pod hardening (PSA) → supply chain → secrets & cluster hardening |
| **06 Production Readiness** | [01](../06-production-readiness/01-observability-metrics.md) · [02](../06-production-readiness/02-logging.md) · [03](../06-production-readiness/03-tracing.md) · [04](../06-production-readiness/04-autoscaling.md) · [05](../06-production-readiness/05-reliability-and-disruptions.md) · [06](../06-production-readiness/06-capacity-and-cost.md) | 7–10 h | See it (metrics/logs/traces) → scale it → keep it reliable → afford it |
| **07 Delivery** | [01](../07-delivery/01-packaging-helm.md) · [02](../07-delivery/02-packaging-kustomize.md) · [03](../07-delivery/03-cicd-pipeline.md) · [04](../07-delivery/04-gitops-argocd.md) · [05](../07-delivery/05-progressive-delivery.md) | 7–10 h | Package (Helm/Kustomize) → CI/CD → GitOps → progressive delivery |
| **08 Day-2 Operations** | [01](../08-day-2-operations/01-cluster-lifecycle.md) · [02](../08-day-2-operations/02-backup-and-dr.md) · [03](../08-day-2-operations/03-troubleshooting-playbook.md) · [04](../08-day-2-operations/04-multi-tenancy-and-namespaces.md) · [05](../08-day-2-operations/05-operators-and-crds.md) | 6–9 h | Lifecycle/upgrades → backup/DR → troubleshooting → multi-tenancy → operators |
| **09 Capstone** | [01](../09-end-to-end-bookstore/01-bookstore-end-to-end.md) | 2–4 h | Compose every part: GitOps up, observed, autoscaled, hardened, DR-drilled |

**Why this order:** it is the dependency order of the system itself — you cannot
secure or deliver a workload you cannot yet run, observe, or place. **Skips:**
nothing — this is the complete path. Total ≈ **55–85 hours** of focused,
hands-on study (less if you skip the under-the-hood and `In production:`
sections; those are the production-relevant parts, so don't skip them if you're
going to production).

---

## Path 3 — Exam-oriented (CKAD / CKA / CKS)

This guide is **not an exam cram** — it teaches the *why* and goes deeper than
the exams in places (internals, GitOps, operators) and lighter in others (raw
cluster install/etcd ops, exam-specific muscle memory). The maps below show
**which guide chapters cover which exam domain**, honestly flagged
`[deeper]` / `[lighter]` / `[≈]` vs the exam's depth. The official curricula
are the authority for exact, current domain weights:
<https://github.com/cncf/curriculum>. Drill speed with [Appendix A's CKAD speed
tips](A-kubectl-cheatsheet.md#ckad-speed-tips).

> Methodology: each exam domain is mapped to the guide chapter(s) that cover its
> objectives. `[deeper]` = the guide goes well beyond exam depth; `[lighter]` =
> the guide covers the concept but the exam demands more hands-on speed or a
> topic the guide treats as note-only (e.g. raw `kubeadm` install, etcd
> backup/restore by hand); `[≈]` = roughly exam-aligned. Not overclaimed:
> chapters are mapped only where they genuinely cover the objective.

### CKAD — Certified Kubernetes Application Developer

Focus: building, deploying, configuring, and observing applications.

| CKAD domain (approx.) | Guide chapters | Depth vs exam |
|---|---|---|
| Application design & build (multi-container, init/sidecar, Jobs/CronJobs, volumes) | [01-core-workloads/01](../01-core-workloads/01-pods.md), [07](../01-core-workloads/07-jobs-and-cronjobs.md); [03-config-and-storage/03](../03-config-and-storage/03-volumes.md) | `[≈]` |
| Application deployment (Deployments, rolling updates/rollback, Helm, blue-green/canary) | [01-core-workloads/04](../01-core-workloads/04-replicasets-and-deployments.md), [08](../01-core-workloads/08-deployment-strategies.md); [07-delivery/01](../07-delivery/01-packaging-helm.md), [02](../07-delivery/02-packaging-kustomize.md) | `[deeper]` (Helm/Kustomize/GitOps beyond exam) |
| Application observability & maintenance (probes, logs, `kubectl debug`, deprecated APIs) | [01-core-workloads/02](../01-core-workloads/02-health-and-lifecycle.md); [06-production-readiness/02](../06-production-readiness/02-logging.md); [08-day-2-operations/03](../08-day-2-operations/03-troubleshooting-playbook.md); [appendix C](C-yaml-and-api-conventions.md) | `[≈]` |
| Application environment, config & security (ConfigMaps/Secrets, SA, resources, securityContext) | [03-config-and-storage/01](../03-config-and-storage/01-configmaps.md), [02](../03-config-and-storage/02-secrets.md); [01-core-workloads/03](../01-core-workloads/03-resources-and-qos.md); [05-security/01](../05-security/01-authn-authz-rbac.md), [02](../05-security/02-pod-security.md) | `[≈]` |
| Services & networking (Services, NetworkPolicy basics) | [02-networking/02](../02-networking/02-services.md), [03](../02-networking/03-dns-and-discovery.md), [04](../02-networking/04-ingress.md), [06](../02-networking/06-network-policies.md) | `[≈]` |

CKAD-targeted order: Path 1 chapters 1–12, then
[01-core-workloads/03](../01-core-workloads/03-resources-and-qos.md) ·
[07](../01-core-workloads/07-jobs-and-cronjobs.md) ·
[08](../01-core-workloads/08-deployment-strategies.md) ·
[03-config-and-storage/03](../03-config-and-storage/03-volumes.md) ·
[05-security/01](../05-security/01-authn-authz-rbac.md) ·
[02](../05-security/02-pod-security.md) ·
[02-networking/06](../02-networking/06-network-policies.md) →
[capstone](../09-end-to-end-bookstore/01-bookstore-end-to-end.md). **Exam reality the guide
under-drills:** raw command speed under time pressure — practice the
imperative→manifest workflow in [Appendix A §2](A-kubectl-cheatsheet.md).

### CKA — Certified Kubernetes Administrator

Focus: operating and administering a cluster.

| CKA domain (approx.) | Guide chapters | Depth vs exam |
|---|---|---|
| Cluster architecture, installation & configuration (control plane, kubeadm, RBAC, upgrades) | [00-foundations/03](../00-foundations/03-architecture-overview.md), [04](../00-foundations/04-control-plane-deep-dive.md), [05](../00-foundations/05-node-components.md); [05-security/01](../05-security/01-authn-authz-rbac.md); [08-day-2-operations/01](../08-day-2-operations/01-cluster-lifecycle.md) | `[lighter]` — `kubeadm init`/`kubeadm upgrade` and manual certificate/kubeconfig management are covered conceptually + as `In production:`; the exam wants them performed from scratch (rehearse on a kind/kubeadm cluster) |
| Workloads & scheduling (Deployments, scaling, scheduling, affinity/taints) | [01-core-workloads/04](../01-core-workloads/04-replicasets-and-deployments.md); [04-scheduling/01](../04-scheduling/01-scheduler-and-nodes.md), [02](../04-scheduling/02-affinity-taints-topology.md), [03](../04-scheduling/03-priority-and-preemption.md); [06-production-readiness/04](../06-production-readiness/04-autoscaling.md) | `[deeper]` |
| Services & networking (Services, Ingress, Gateway, CoreDNS, NetworkPolicy, CNI) | [02-networking/01](../02-networking/01-networking-model.md), [02](../02-networking/02-services.md), [03](../02-networking/03-dns-and-discovery.md), [04](../02-networking/04-ingress.md), [05](../02-networking/05-gateway-api.md), [06](../02-networking/06-network-policies.md) | `[≈]`/`[deeper]` |
| Storage (StorageClass, PV/PVC, access modes, reclaim) | [03-config-and-storage/03](../03-config-and-storage/03-volumes.md), [04](../03-config-and-storage/04-persistent-storage.md), [05](../03-config-and-storage/05-stateful-data-patterns.md) | `[≈]` |
| Troubleshooting (cluster/node/app, logs, events, networking) | [08-day-2-operations/03](../08-day-2-operations/03-troubleshooting-playbook.md); [06-production-readiness/01](../06-production-readiness/01-observability-metrics.md), [02](../06-production-readiness/02-logging.md) | `[≈]` |
| Cluster maintenance & backup (etcd backup/restore, drain/cordon, version skew) | [08-day-2-operations/01](../08-day-2-operations/01-cluster-lifecycle.md), [02](../08-day-2-operations/02-backup-and-dr.md) | `[lighter]` on bare-hand `etcdctl snapshot restore` (covered, but exam wants it fast & manual) |

CKA-targeted order: Part 00 (all) → [01-core-workloads/04](../01-core-workloads/04-replicasets-and-deployments.md) → Part 02 (all) → Part 03 (all) → Part 04 (all) → [05-security/01](../05-security/01-authn-authz-rbac.md) → Part 08 [01](../08-day-2-operations/01-cluster-lifecycle.md)/[02](../08-day-2-operations/02-backup-and-dr.md)/[03](../08-day-2-operations/03-troubleshooting-playbook.md) → [capstone](../09-end-to-end-bookstore/01-bookstore-end-to-end.md). **Exam reality the guide under-drills:** hand-running `kubeadm` upgrades and `etcdctl` snapshot save/restore on a vanilla cluster — rehearse those against a kind cluster using the official docs linked in [Appendix D Part 08](D-further-reading.md#part-08-day-2-operations).

### CKS — Certified Kubernetes Security Specialist

Focus: securing a cluster and its workloads (CKA is a prerequisite).

| CKS domain (approx.) | Guide chapters | Depth vs exam |
|---|---|---|
| Cluster setup (NetworkPolicy, CIS benchmark, ingress TLS, restricting metadata/dashboard) | [02-networking/06](../02-networking/06-network-policies.md); [02-networking/04](../02-networking/04-ingress.md); [05-security/04](../05-security/04-secrets-and-cluster-hardening.md) | `[≈]` |
| Cluster hardening (RBAC least privilege, restrict API access, upgrade discipline) | [05-security/01](../05-security/01-authn-authz-rbac.md); [05-security/04](../05-security/04-secrets-and-cluster-hardening.md); [08-day-2-operations/01](../08-day-2-operations/01-cluster-lifecycle.md) | `[deeper]` (RBAC treated end-to-end) |
| System hardening (least-privilege OS, seccomp/AppArmor, reduce attack surface) | [05-security/02](../05-security/02-pod-security.md); [00-foundations/02](../00-foundations/02-containers-and-images.md) (distroless) | `[≈]` |
| Minimize microservice vulnerabilities (PSA, securityContext, secrets, mTLS concept, sandboxing) | [05-security/02](../05-security/02-pod-security.md); [03-config-and-storage/02](../03-config-and-storage/02-secrets.md); [05-security/04](../05-security/04-secrets-and-cluster-hardening.md) | `[≈]` |
| Supply chain security (image footprint, signing, scanning, SBOM, admission/Kyverno) | [05-security/03](../05-security/03-supply-chain.md); [00-foundations/02](../00-foundations/02-containers-and-images.md); [07-delivery/03](../07-delivery/03-cicd-pipeline.md) | `[deeper]` |
| Monitoring, logging & runtime security (audit logs, behavioral analytics, threat detection) | [05-security/04](../05-security/04-secrets-and-cluster-hardening.md) (audit logging) + [06-production-readiness/02](../06-production-readiness/02-logging.md) | `[lighter]` — metrics ([06/01]) and tracing ([06/03]) are **not** CKS-tested; focus on **audit logs** ([05-security/04](../05-security/04-secrets-and-cluster-hardening.md)) + the official-curriculum Falco/runtime supplement (note-only in this guide) |

CKS-targeted order (do CKA first): Part 05 (all, in order) →
[02-networking/06](../02-networking/06-network-policies.md) →
[00-foundations/02](../00-foundations/02-containers-and-images.md) →
[07-delivery/03](../07-delivery/03-cicd-pipeline.md) →
[06-production-readiness/01](../06-production-readiness/01-observability-metrics.md)/[02](../06-production-readiness/02-logging.md) →
[capstone](../09-end-to-end-bookstore/01-bookstore-end-to-end.md) §(h) "Verify security
posture". **Exam reality the guide under-drills:** a runtime-security sensor
(e.g. Falco) and `gVisor`/`kata` sandboxing hands-on — the guide explains the
threat model and PSA/`securityContext` thoroughly but treats runtime IDS as
note-only; supplement from the official CKS curriculum.

---

## Path 4 — Platform / SRE / Ops track (Parts 04–08 emphasis)

For engineers who already run apps and need the *operate-at-scale* skills:
scheduling, security posture, observability, delivery automation, and day-2.
Assumes Parts 00–03 fluency (skim them; do not skip
[00-foundations/06](../00-foundations/06-declarative-api-model.md) — SSA/GitOps
hangs off it).

| # | Chapter | Why here |
|---|---|---|
| 1 | [00-foundations/04 — Control plane deep dive](../00-foundations/04-control-plane-deep-dive.md) | You operate these components; know them cold |
| 2 | [00-foundations/05 — Node components](../00-foundations/05-node-components.md) | kubelet/CRI/CNI — where node incidents live |
| 3 | [04-scheduling/01 — Scheduler and nodes](../04-scheduling/01-scheduler-and-nodes.md) | Placement is a platform lever |
| 4 | [04-scheduling/02 — Affinity, taints, topology](../04-scheduling/02-affinity-taints-topology.md) | Spread, isolation, node pools |
| 5 | [04-scheduling/03 — Priority and preemption](../04-scheduling/03-priority-and-preemption.md) | Capacity contention policy |
| 6 | [05-security/01 — Authn, authz, RBAC](../05-security/01-authn-authz-rbac.md) | Least-privilege is platform table stakes |
| 7 | [05-security/02 — Pod security](../05-security/02-pod-security.md) | PSA `restricted` as the cluster floor |
| 8 | [05-security/04 — Secrets and cluster hardening](../05-security/04-secrets-and-cluster-hardening.md) | Encryption, audit, hardening |
| 9 | [06-production-readiness/01 — Observability: metrics](../06-production-readiness/01-observability-metrics.md) | You cannot operate what you cannot see |
| 10 | [06-production-readiness/02 — Logging](../06-production-readiness/02-logging.md) | Centralized logs |
| 11 | [06-production-readiness/03 — Tracing](../06-production-readiness/03-tracing.md) | Cross-service latency/failure |
| 12 | [06-production-readiness/04 — Autoscaling](../06-production-readiness/04-autoscaling.md) | HPA/VPA/KEDA/Cluster Autoscaler |
| 13 | [06-production-readiness/05 — Reliability and disruptions](../06-production-readiness/05-reliability-and-disruptions.md) | PDBs, SLOs, disruption budgets |
| 14 | [06-production-readiness/06 — Capacity and cost](../06-production-readiness/06-capacity-and-cost.md) | Right-sizing, bin-packing, FinOps |
| 15 | [07-delivery/01 — Packaging with Helm](../07-delivery/01-packaging-helm.md) | The platform's release unit |
| 16 | [07-delivery/02 — Packaging with Kustomize](../07-delivery/02-packaging-kustomize.md) | Env overlays without a DSL |
| 17 | [07-delivery/03 — CI/CD pipeline](../07-delivery/03-cicd-pipeline.md) | Build→scan→push→deploy |
| 18 | [07-delivery/04 — GitOps with Argo CD](../07-delivery/04-gitops-argocd.md) | The cluster *is* the repo |
| 19 | [07-delivery/05 — Progressive delivery](../07-delivery/05-progressive-delivery.md) | Metric-gated rollouts |
| 20 | [08-day-2-operations/01 — Cluster lifecycle](../08-day-2-operations/01-cluster-lifecycle.md) | Upgrades, version skew, node maintenance |
| 21 | [08-day-2-operations/02 — Backup and DR](../08-day-2-operations/02-backup-and-dr.md) | etcd/PV backup, a rehearsed restore |
| 22 | [08-day-2-operations/03 — Troubleshooting playbook](../08-day-2-operations/03-troubleshooting-playbook.md) | The incident method + distroless debug |
| 23 | [08-day-2-operations/04 — Multi-tenancy and namespaces](../08-day-2-operations/04-multi-tenancy-and-namespaces.md) | Many teams, one cluster |
| 24 | [08-day-2-operations/05 — Operators and CRDs](../08-day-2-operations/05-operators-and-crds.md) | Automating stateful day-2 |
| 25 | [09-end-to-end-bookstore/01 — Bookstore end-to-end](../09-end-to-end-bookstore/01-bookstore-end-to-end.md) | The whole platform exercised: GitOps + observe + scale + harden + DR |

**Why this order:** internals → placement → security floor → observability →
scale/reliability/cost → delivery automation → day-2 → compose it all.
**Skips (be honest):** application-author depth (multi-container patterns,
Jobs/CronJobs detail, app config ergonomics) — that is Path 1 / CKAD; this track
assumes you can already write a workload and focuses on running fleets of them.

---

## Choosing a path

```text
 Just need to deploy something soon ............ Path 1 (Fast track)
 Learning Kubernetes properly, end to end ...... Path 2 (Zero-to-production) ← the default
 Sitting CKAD ................................. Path 3 → CKAD map
 Sitting CKA .................................. Path 3 → CKA map
 Sitting CKS (after CKA) ...................... Path 3 → CKS map
 Platform/SRE building & operating clusters ... Path 4 (Platform/SRE/ops)
```

Every path finishes at the **[end-to-end Bookstore](../09-end-to-end-bookstore/01-bookstore-end-to-end.md)** —
the Bookstore stood up from zero with GitOps, observed, autoscaled, hardened,
and DR-drilled. If you can do that end-to-end and explain *why* each step is
there, the path worked. Readers who then take **Parts 10 - 12** (cloud /
advanced production / ML) close on the **[Bookstore Platform v2 grand
capstone](../13-grand-capstone-bookstore-platform/12-day-2-runbook-on-call-dr-chaos.md)** —
the production reality: N tenants across three regions with the day-2 runbook,
on-call playbook, DR drill, and chaos game-day that turn the platform's
capabilities into a working system.

---

See also: [Appendix A — kubectl cheatsheet](A-kubectl-cheatsheet.md) ·
[Appendix B — Glossary](B-glossary.md) ·
[Appendix C — YAML & API conventions](C-yaml-and-api-conventions.md) ·
[Appendix D — Further reading](D-further-reading.md) (the book chapters behind
each Part, and the CNCF-landscape pointer). Exam curricula (authoritative,
current): <https://github.com/cncf/curriculum>.
