# Appendix E — Learning paths

> Ordered ways through **this guide**. Every link is a real chapter in this
> repository; the guide is standalone, so these map *its* chapters — they do not
> assume any other notes. Four paths: a one-week **Fast track**, the full
> **Zero-to-production** arc, a **Security and DevSecOps** path, and a
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
| **00 Foundations** | [01](../00-foundations/01-why-kubernetes.md) · [02](../00-foundations/02-containers-and-images.md) · [03](../00-foundations/03-architecture-overview.md) · [04](../00-foundations/04-control-plane-deep-dive.md) · [05](../00-foundations/05-node-components.md) · [06](../00-foundations/06-declarative-api-model.md) · [07](../00-foundations/07-local-cluster-setup.md) · 00.08 <!-- link-later: 00.08 --> | 6–9 h | Containers → architecture → internals → the declarative model → a real cluster, before any workload |
| **01 Core Workloads** | [01](../01-core-workloads/01-pods.md) · [02](../01-core-workloads/02-health-and-lifecycle.md) · [03](../01-core-workloads/03-resources-and-qos.md) · [04](../01-core-workloads/04-replicasets-and-deployments.md) · [05](../01-core-workloads/05-statefulsets.md) · [06](../01-core-workloads/06-daemonsets.md) · [07](../01-core-workloads/07-jobs-and-cronjobs.md) · [08](../01-core-workloads/08-deployment-strategies.md) | 8–12 h | Pod → health → resources → controllers; stateful/daemon/batch; how to roll changes |
| **02 Networking** | [01](../02-networking/01-networking-model.md) · [02](../02-networking/02-services.md) · [03](../02-networking/03-dns-and-discovery.md) · [04](../02-networking/04-ingress.md) · [05](../02-networking/05-gateway-api.md) · [06](../02-networking/06-network-policies.md) | 6–9 h | Model → Services → DNS → edge (Ingress/Gateway) → segmentation |
| **03 Config & Storage** | [01](../03-config-and-storage/01-configmaps.md) · [02](../03-config-and-storage/02-secrets.md) · [03](../03-config-and-storage/03-volumes.md) · [04](../03-config-and-storage/04-persistent-storage.md) · [05](../03-config-and-storage/05-stateful-data-patterns.md) | 5–8 h | Config → secrets → volumes → PV/PVC → operating stateful data |
| **04 Scheduling** | [01](../04-scheduling/01-scheduler-and-nodes.md) · [02](../04-scheduling/02-affinity-taints-topology.md) · [03](../04-scheduling/03-priority-and-preemption.md) | 3–5 h | How placement is decided → steering it → priority/preemption |
| **05 Security** | 05.00 <!-- link-later: 05.00 --> · [01](../05-security/01-authn-authz-rbac.md) · [02](../05-security/02-pod-security.md) · [03](../05-security/03-supply-chain.md) · [04](../05-security/04-secrets-and-cluster-hardening.md) · 05.05 <!-- link-later: 05.05 --> · 05.06 <!-- link-later: 05.06 --> · 05.07 <!-- link-later: 05.07 --> · 05.08 <!-- link-later: 05.08 --> · 05.09 <!-- link-later: 05.09 --> · 05.10 <!-- link-later: 05.10 --> | 6–9 h (01–04) | Attacker view → identity/RBAC → pod hardening (PSA) → supply chain → secrets → runtime isolation → cluster hardening → admission → detection → vulnerability management → capstone |
| **06 Production Readiness** | [01](../06-production-readiness/01-observability-metrics.md) · [02](../06-production-readiness/02-logging.md) · [03](../06-production-readiness/03-tracing.md) · [04](../06-production-readiness/04-autoscaling.md) · [05](../06-production-readiness/05-reliability-and-disruptions.md) · [06](../06-production-readiness/06-capacity-and-cost.md) | 7–10 h | See it (metrics/logs/traces) → scale it → keep it reliable → afford it |
| **07 Delivery** | [01](../07-delivery/01-packaging-helm.md) · [02](../07-delivery/02-packaging-kustomize.md) · [03](../07-delivery/03-cicd-pipeline.md) · [04](../07-delivery/04-gitops-argocd.md) · [05](../07-delivery/05-progressive-delivery.md) | 7–10 h | Package (Helm/Kustomize) → CI/CD → GitOps → progressive delivery |
| **08 Day-2 Operations** | [01](../08-day-2-operations/01-cluster-lifecycle.md) · [02](../08-day-2-operations/02-backup-and-dr.md) · [03](../08-day-2-operations/03-troubleshooting-playbook.md) · [04](../08-day-2-operations/04-multi-tenancy-and-namespaces.md) · [05](../08-day-2-operations/05-operators-and-crds.md) | 6–9 h | Lifecycle/upgrades → backup/DR → troubleshooting → multi-tenancy → operators |
| **09 Capstone** | [01](../09-end-to-end-bookstore/01-bookstore-end-to-end.md) | 2–4 h | Compose every part: GitOps up, observed, autoscaled, hardened, DR-drilled |

**Why this order:** it is the dependency order of the system itself — you cannot
secure or deliver a workload you cannot yet run, observe, or place. **Skips:**
nothing — this is the complete path. Total ≈ **56–85 hours** of focused,
hands-on study, not counting the link-later chapters, which are not timed yet
(less if you skip the under-the-hood and `In production:` sections; those are
the production-relevant parts, so don't skip them if you're going to
production).

---

## Path 3: Security and DevSecOps

For engineers who already run workloads and need to harden them, prove each
control works, and enforce it in the delivery pipeline. It assumes Parts 00
to 03. Read the baseline (row 2) before the rest: every manifest in the
chapters below carries it.

| # | Chapter | Why here |
|---|---|---|
| 1 | 00.08: Security foundations <!-- link-later: 00.08 --> | Threat model, trust boundaries and the exceptions process |
| 2 | [01-core-workloads/01: Pods, the baseline](../01-core-workloads/01-pods.md#baseline) | Every field of the baseline, explained once |
| 3 | [00-foundations/02: Containers and images](../00-foundations/02-containers-and-images.md) | What a base image adds to your attack surface |
| 4 | [02-networking/06: Network policies](../02-networking/06-network-policies.md) | Default deny, then explicit allows |
| 5 | 05.00: Attacker view <!-- link-later: 05.00 --> | How an attacker reaches a cluster, and the threats Part 05 answers |
| 6 | [05-security/01: Authn, authz, RBAC](../05-security/01-authn-authz-rbac.md) | Who may do what; least privilege for every identity |
| 7 | [05-security/02: Pod security](../05-security/02-pod-security.md) | The `restricted` level and the container escape paths it closes |
| 8 | [05-security/03: Supply chain](../05-security/03-supply-chain.md) | Pinned images and manifest scanning |
| 9 | [05-security/04: Secrets at rest and in use](../05-security/04-secrets-and-cluster-hardening.md) | Encryption at rest and KMS, the keys behind the secrets |
| 10 | 05.05: Seccomp, AppArmor, SELinux and RuntimeClass <!-- link-later: 05.05 --> | Runtime isolation beyond the pod spec |
| 11 | 05.06: Control plane and node hardening <!-- link-later: 05.06 --> | CIS benchmarks and kube-bench |
| 12 | 05.07: Admission control <!-- link-later: 05.07 --> | Policy as code at the API server |
| 13 | 05.08: Audit logs and detection <!-- link-later: 05.08 --> | Audit logs, Falco, Tetragon and incident response |
| 14 | 05.09: Vulnerability management <!-- link-later: 05.09 --> | Findings, triage and fixes |
| 15 | 05.10: Part 05 capstone <!-- link-later: 05.10 --> | The controls working together on one platform |
| 16 | [07-delivery/03: CI/CD pipeline](../07-delivery/03-cicd-pipeline.md) | The pipeline that runs each stage on every change |
| 17 | [08-day-2-operations/03: Troubleshooting playbook](../08-day-2-operations/03-troubleshooting-playbook.md) | Debugging without weakening the controls |
| 18 | [09-end-to-end-bookstore/01: Bookstore end-to-end](../09-end-to-end-bookstore/01-bookstore-end-to-end.md) | Section (h) verifies the posture of the whole platform |

**Why this order:** the threat model and the baseline come first, so every
control is judged against the same workload. Part 05 then runs from the
attacker's view through identity, pods, images and secrets to runtime,
cluster, admission and detection. The pipeline comes last because it runs
those checks on every change.

**Skips (be honest):** the cloud form of each control, such as managed
identity and cloud KMS. Read the production counterparts after this path:
[10.03 cloud identity](../10-cloud-and-managed-kubernetes/03-cloud-identity.md),
[14.13 runtime defense](../14-eks-in-production-a-to-z/13-runtime-defense-and-container-security.md)
and [15.05 production secrets](../15-day-to-day-production-ops/05-production-secrets-vault-eso.md).
Application-author depth (Jobs, probes, config ergonomics) is Path 1 or 2.

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
| 8 | [05-security/04: Secrets at rest and in use](../05-security/04-secrets-and-cluster-hardening.md) | Encryption at rest and KMS |
| 9 | 05.06: Control plane and node hardening <!-- link-later: 05.06 --> | CIS benchmarks on the nodes you run |
| 10 | 05.07: Admission control <!-- link-later: 05.07 --> | Policy as code, enforced for every team |
| 11 | 05.08: Audit logs and detection <!-- link-later: 05.08 --> | What the platform records and alerts on |
| 12 | [06-production-readiness/01 — Observability: metrics](../06-production-readiness/01-observability-metrics.md) | You cannot operate what you cannot see |
| 13 | [06-production-readiness/02 — Logging](../06-production-readiness/02-logging.md) | Centralized logs |
| 14 | [06-production-readiness/03 — Tracing](../06-production-readiness/03-tracing.md) | Cross-service latency/failure |
| 15 | [06-production-readiness/04 — Autoscaling](../06-production-readiness/04-autoscaling.md) | HPA/VPA/KEDA/Cluster Autoscaler |
| 16 | [06-production-readiness/05 — Reliability and disruptions](../06-production-readiness/05-reliability-and-disruptions.md) | PDBs, SLOs, disruption budgets |
| 17 | [06-production-readiness/06 — Capacity and cost](../06-production-readiness/06-capacity-and-cost.md) | Right-sizing, bin-packing, FinOps |
| 18 | [07-delivery/01 — Packaging with Helm](../07-delivery/01-packaging-helm.md) | The platform's release unit |
| 19 | [07-delivery/02 — Packaging with Kustomize](../07-delivery/02-packaging-kustomize.md) | Env overlays without a DSL |
| 20 | [07-delivery/03 — CI/CD pipeline](../07-delivery/03-cicd-pipeline.md) | Build→scan→push→deploy |
| 21 | [07-delivery/04 — GitOps with Argo CD](../07-delivery/04-gitops-argocd.md) | The cluster *is* the repo |
| 22 | [07-delivery/05 — Progressive delivery](../07-delivery/05-progressive-delivery.md) | Metric-gated rollouts |
| 23 | [08-day-2-operations/01 — Cluster lifecycle](../08-day-2-operations/01-cluster-lifecycle.md) | Upgrades, version skew, node maintenance |
| 24 | [08-day-2-operations/02 — Backup and DR](../08-day-2-operations/02-backup-and-dr.md) | etcd/PV backup, a rehearsed restore |
| 25 | [08-day-2-operations/03 — Troubleshooting playbook](../08-day-2-operations/03-troubleshooting-playbook.md) | The incident method + distroless debug |
| 26 | [08-day-2-operations/04 — Multi-tenancy and namespaces](../08-day-2-operations/04-multi-tenancy-and-namespaces.md) | Many teams, one cluster |
| 27 | [08-day-2-operations/05 — Operators and CRDs](../08-day-2-operations/05-operators-and-crds.md) | Automating stateful day-2 |
| 28 | [09-end-to-end-bookstore/01 — Bookstore end-to-end](../09-end-to-end-bookstore/01-bookstore-end-to-end.md) | The whole platform exercised: GitOps + observe + scale + harden + DR |

**Why this order:** internals → placement → security floor → observability →
scale/reliability/cost → delivery automation → day-2 → compose it all.
**Skips (be honest):** application-author depth (multi-container patterns,
Jobs/CronJobs detail, app config ergonomics) — that is Path 1; this track
assumes you can already write a workload and focuses on running fleets of them.

---

## Choosing a path

```text
 Just need to deploy something soon ............ Path 1 (Fast track)
 Learning Kubernetes properly, end to end ...... Path 2 (Zero-to-production) ← the default
 Securing workloads or delivery pipelines ...... Path 3 (Security and DevSecOps)
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
each Part, and the CNCF-landscape pointer).
