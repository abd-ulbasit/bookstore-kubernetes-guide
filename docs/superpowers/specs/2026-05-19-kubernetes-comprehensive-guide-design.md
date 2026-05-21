# Design Spec: Comprehensive Kubernetes Guide ("full-guide")

**Date:** 2026-05-19
**Status:** Approved (design), pending spec review
**Author:** Claude (brainstormed with user)

---

## 1. Overview

A new, standalone, comprehensive Kubernetes guide built as a **progressive learning
journey from zero to production**. It lives in a new `full-guide/` directory and is
**deliberately not linked** to the user's existing `.md` files in this directory
(those are advanced internals/operator/CKA-CKAD-CKS notes; this guide is separate and
self-contained).

The guide teaches Kubernetes by progressively building, deploying, scaling, securing,
observing, and operating **one realistic example application ("Bookstore")** across
the entire arc, so concepts compound instead of resetting per topic.

## 2. Goals & success criteria

A reader who works through this guide should be able to:

1. Explain *why* Kubernetes exists and how its architecture works (control plane,
   nodes, declarative reconciliation) — including accurate diagrams.
2. Deploy and connect a multi-service application using core workload, networking,
   config, and storage primitives.
3. Make an application production-ready: observability, autoscaling, reliability,
   security hardening.
4. Deliver it continuously via Helm/Kustomize + GitOps (Argo CD) with progressive
   delivery.
5. Operate it day-2: upgrades, backup/DR, troubleshooting, multi-tenancy, extension
   via operators.
6. Reproduce **every** hands-on step locally (kind/k3d) for free, and know how it
   differs in managed cloud (EKS/GKE/AKS).

**Definition of done:** every planned chapter file exists with the standard chapter
anatomy (below), every referenced manifest/code exists and is internally consistent
under `examples/bookstore/`, all diagrams render (Mermaid) or are clean ASCII, and the
capstone deploys the full Bookstore end-to-end referencing only artifacts in the guide.

## 3. Audience & depth

- **Scope:** Zero-to-production. Assumes no prior Kubernetes knowledge but goes deep
  (internals explained, not just "what to type").
- **Prerequisite:** comfort with the command line and basic Linux/HTTP concepts.
  Containers are taught from first principles in Part 00.

## 4. Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Scope & depth | Zero-to-production, self-contained, deep |
| Worked example | One app ("Bookstore") threaded throughout |
| Diagram format | **Both** — Mermaid for architecture/flow, ASCII for inline sketches |
| Hands-on environment | **Both** — locally runnable (kind/k3d) + explicit production/cloud notes |
| Structure | **Approach A: Progressive Journey** — narrative arc, parts=dirs, chapters=files, each chapter ends with a Quick Reference box; consolidated cheatsheet in appendix |
| Scope size | Full ~50-chapter version, built in ordered phases |
| Relationship to existing docs | Standalone, not cross-linked |

## 5. The example application — "Bookstore"

A small but realistic e-commerce microservices system. Minimal **real, runnable**
source + Dockerfiles live in `examples/bookstore/app/` (images must actually build).
Kept intentionally small so the focus stays on Kubernetes, not app code.

**Tech stack (fixed to remove ambiguity):** `catalog`, `orders`, and
`payments-worker` are tiny **Go** single-binary services (small, fast,
distroless-friendly images — also matches the user's Go background); `storefront`
is a static site served by nginx. Postgres/Redis/RabbitMQ use upstream official
images. Each Go service is a few hundred lines at most.

| Service | Type | Primary concepts it exercises |
|---|---|---|
| `storefront` | Stateless web UI (static/Node) | Deployment, horizontal scaling, Ingress, readiness |
| `catalog` | Stateless REST API | ConfigMap, probes, HPA, reads Postgres + Redis cache |
| `orders` | Stateless REST API | Secrets, NetworkPolicy, publishes events to RabbitMQ |
| `payments-worker` | Background queue consumer | Worker/Job pattern, KEDA event-driven scaling |
| `postgres` | Stateful database | StatefulSet, PVC, StorageClass, backup/DR, NetworkPolicy target |
| `redis` | Cache | Headless service, ephemeral vs persistent tradeoff |
| `rabbitmq` | Message queue | StatefulSet, async decoupling |

**Evolution narrative (the app grows with the reader):**

1. `catalog` as a single bare **Pod** (Part 01).
2. `catalog` + `storefront` as **Deployments**; **Services** wire them; storefront
   exposed.
3. Config & DB credentials externalized to **ConfigMap/Secret**.
4. **Postgres** added as a **StatefulSet** with persistent storage; schema applied by
   an init/migration **Job**.
5. `redis` cache and `rabbitmq` + `orders` + `payments-worker` added (async path).
6. **Ingress/Gateway** with TLS exposes storefront + APIs on real hostnames.
7. **Scheduling, autoscaling, observability, security** progressively applied.
8. **Packaged** (Helm + Kustomize overlays) and **delivered via Argo CD** with
   canary rollout.
9. **Capstone:** full system stood up from zero with GitOps, observed, autoscaled,
   hardened, with a DR runbook.

## 6. Directory & file structure

Root: `<REPO-ROOT>/full-guide/`

```
full-guide/
├── README.md                            # Map, prerequisites, conventions, Bookstore intro, how to use
│
├── 00-foundations/
│   ├── 01-why-kubernetes.md             # Bare metal→VM→container→orchestration; pets vs cattle; declarative vs imperative; what problems k8s solves / does NOT solve
│   ├── 02-containers-and-images.md       # Containers vs VMs; namespaces/cgroups; OCI images & layers; registries; building the Bookstore images
│   ├── 03-architecture-overview.md       # Big-picture cluster diagram; control plane vs data plane; component map; how a request becomes a running Pod (overview)
│   ├── 04-control-plane-deep-dive.md     # kube-apiserver, etcd, scheduler, controller-manager, cloud-controller-manager — responsibilities, HA, data flow
│   ├── 05-node-components.md             # kubelet, container runtime & CRI (containerd), kube-proxy, pause container; full pod-start sequence on a node
│   ├── 06-declarative-api-model.md       # Objects, GVK, spec/status, reconciliation concept, `kubectl apply` lifecycle, etcd as source of truth, optimistic concurrency
│   └── 07-local-cluster-setup.md         # Install kubectl, kind/k3d/minikube; create first cluster; contexts/kubeconfig; verify components; deploy first Bookstore Pod
│
├── 01-core-workloads/
│   ├── 01-pods.md                        # Pod anatomy & shared namespaces; lifecycle/phases; multi-container patterns (sidecar/init/ambassador/adapter); ephemeral containers
│   ├── 02-health-and-lifecycle.md        # liveness/readiness/startup probes; lifecycle hooks; graceful termination & SIGTERM; preStop
│   ├── 03-resources-and-qos.md           # requests/limits; CPU vs memory semantics; QoS classes; OOMKill; eviction; LimitRange & ResourceQuota
│   ├── 04-replicasets-and-deployments.md # ReplicaSet; Deployment; rolling update mechanics; rollback; revisionHistory; recreate vs rolling; storefront+catalog as Deployments
│   ├── 05-statefulsets.md                # Stable identity; ordered/parallel rollout; headless Service; volumeClaimTemplates; Postgres as StatefulSet
│   ├── 06-daemonsets.md                  # Node-level workloads; update strategy; use cases (logging/metrics/CNI agents)
│   ├── 07-jobs-and-cronjobs.md           # Run-to-completion; parallelism/completions; backoffLimit; CronJob schedules; Bookstore DB-migration Job + nightly cleanup CronJob
│   └── 08-deployment-strategies.md       # Recreate/rolling deep dive; blue-green; canary (concept); progressive delivery teaser
│
├── 02-networking/
│   ├── 01-networking-model.md            # The 4 networking problems; IP-per-Pod; flat network requirement; CNI overview & plugin landscape (Calico/Cilium/Flannel)
│   ├── 02-services.md                    # ClusterIP/NodePort/LoadBalancer/ExternalName; Endpoints/EndpointSlices; kube-proxy modes (iptables/IPVS/eBPF); session affinity
│   ├── 03-dns-and-discovery.md           # CoreDNS; Service/Pod DNS records; `ndots:5`; headless services; wiring Bookstore service discovery
│   ├── 04-ingress.md                     # Ingress resource & controllers (ingress-nginx); host/path routing; TLS; exposing storefront + APIs
│   ├── 05-gateway-api.md                 # Gateway API (Gateway/HTTPRoute/GatewayClass); why it supersedes Ingress; role separation; migration notes
│   └── 06-network-policies.md            # Default-deny; ingress/egress rules; isolating Postgres; namespace isolation; CNI support caveats
│
├── 03-config-and-storage/
│   ├── 01-configmaps.md                  # 3 consumption modes (env/envFrom/volume); immutable ConfigMaps; reload strategies; catalog config
│   ├── 02-secrets.md                     # Secret types; base64 ≠ encryption; encryption at rest; external secret stores (overview); DB credentials done right
│   ├── 03-volumes.md                     # emptyDir/hostPath/projected/downwardAPI; volume vs persistent volume; the volume taxonomy
│   ├── 04-persistent-storage.md          # PV/PVC lifecycle; StorageClass; dynamic provisioning; access modes; reclaim policy; volumeBindingMode; CSI; Postgres storage
│   └── 05-stateful-data-patterns.md      # Snapshots/clones; running databases on k8s — when to and when NOT to; operator teaser
│
├── 04-scheduling/
│   ├── 01-scheduler-and-nodes.md         # Scheduling cycle: filter→score→bind; nodeName/nodeSelector; node conditions; how Pending happens
│   ├── 02-affinity-taints-topology.md    # node/pod (anti-)affinity; taints & tolerations; topology spread constraints; placing Bookstore tiers for HA
│   └── 03-priority-and-preemption.md     # PriorityClass; preemption; eviction; cordon/drain; descheduler (overview)
│
├── 05-security/
│   ├── 01-authn-authz-rbac.md            # Request → authN → authZ → admission chain; users vs ServiceAccounts; RBAC (Role/ClusterRole/Bindings); least privilege for Bookstore
│   ├── 02-pod-security.md                # securityContext; runAsNonRoot; drop capabilities; readOnlyRootFilesystem; seccomp/AppArmor; Pod Security Admission (restricted)
│   ├── 03-supply-chain.md                # Image scanning (Trivy); signing (Cosign); admission policy (Kyverno/Gatekeeper); distroless; SBOM; pinning digests
│   └── 04-secrets-and-cluster-hardening.md # Encrypting secrets at rest; audit logging; CIS/kube-bench; network hardening recap; Bookstore threat model
│
├── 06-production-readiness/
│   ├── 01-observability-metrics.md       # metrics-server; Prometheus; instrumenting catalog; ServiceMonitor; Grafana; four golden signals / RED/USE
│   ├── 02-logging.md                     # Logging architecture; stdout discipline; node agents (Fluent Bit) → Loki/ELK; structured logging
│   ├── 03-tracing.md                     # Distributed tracing concepts; OpenTelemetry; tracing a Bookstore checkout request across services
│   ├── 04-autoscaling.md                 # HPA v2 (CPU/custom metrics); VPA; Cluster Autoscaler; KEDA (scale payments-worker on queue depth)
│   ├── 05-reliability-and-disruptions.md # PodDisruptionBudget; multi-replica + anti-affinity HA; graceful drain; SLO/error-budget thinking
│   └── 06-capacity-and-cost.md           # Right-sizing requests/limits revisited; namespace quotas; bin-packing; cost awareness & tools (overview)
│
├── 07-delivery/
│   ├── 01-packaging-helm.md              # Helm: charts, templates, values, releases, hooks; package Bookstore as a chart
│   ├── 02-packaging-kustomize.md         # Kustomize: bases & overlays; dev/staging/prod overlays of Bookstore; Helm vs Kustomize
│   ├── 03-cicd-pipeline.md               # build→test→scan→sign→push→deploy; tags vs digests; GitHub Actions example for Bookstore
│   ├── 04-gitops-argocd.md               # GitOps principles; Argo CD architecture; Application & App-of-Apps; sync/self-heal/drift; Bookstore from Git
│   └── 05-progressive-delivery.md        # Argo Rollouts/Flagger; automated canary with metric analysis on catalog/storefront
│
├── 08-day-2-operations/
│   ├── 01-cluster-lifecycle.md           # Provisioning (kubeadm vs managed EKS/GKE/AKS); upgrades; version skew policy; node pools/upgrades
│   ├── 02-backup-and-dr.md               # etcd snapshot/restore; Velero (cluster + PV backup); stateful data DR; Bookstore DR runbook
│   ├── 03-troubleshooting-playbook.md    # Systematic flow; Pending/CrashLoopBackOff/ImagePullBackOff/OOM/Evicted; DNS & network debug; events; ephemeral debug containers
│   ├── 04-multi-tenancy-and-namespaces.md# Namespace design; quotas/limits; RBAC tenancy; soft vs hard multi-tenancy; vCluster (overview)
│   └── 05-operators-and-crds.md          # Extending k8s: CRDs + custom controllers/operators (concept & lifecycle); build vs buy; Bookstore using a Postgres operator
│
├── 09-end-to-end-bookstore/
│   └── 01-bookstore-end-to-end.md        # Zero cluster → images → manifests → Helm/Kustomize → Argo CD → observability → autoscaling → security → DR. Ties every part together.
│
├── examples/
│   └── bookstore/
│       ├── app/                          # Minimal real source + Dockerfile per service (storefront, catalog, orders, payments-worker)
│       ├── raw-manifests/                # Plain YAML used by early/mid chapters (progressively layered)
│       ├── helm/bookstore/               # Helm chart used in Part 07
│       ├── kustomize/                    # base/ + overlays/{dev,staging,prod}
│       └── argocd/                       # Argo CD Application / App-of-Apps manifests
│
└── appendix/
    ├── A-kubectl-cheatsheet.md           # Imperative speed commands, jsonpath/-o templates, debugging one-liners, contexts
    ├── B-glossary.md                     # Every term used in the guide, defined concisely
    ├── C-yaml-and-api-conventions.md     # YAML gotchas; apiVersion/GVK; deprecated APIs; `kubectl explain`; field management/SSA
    ├── D-further-reading.md              # Topic → book/chapter map across the user's library + official docs links
    └── E-learning-paths.md               # Suggested orderings: fast track, exam-oriented (CKA/CKAD/CKS), platform/ops track
```

**File count:** 1 README + 50 chapter files (7+8+6+5+3+4+6+5+5+1) + 5 appendix
= 56 authored markdown docs, plus the `examples/bookstore/` source & manifest tree.

## 7. Chapter anatomy (standard template, every chapter)

1. **Why this exists** — the problem it solves (motivation before mechanism).
2. **Mental model** — the one-paragraph intuition.
3. **Diagram(s)** — Mermaid for flow/architecture/lifecycle; ASCII for quick inline.
4. **Hands-on with the Bookstore** — runnable, copy-pasteable, builds on prior chapter.
5. **How it works under the hood** — the internals (depth, not just usage).
6. **Production notes** — HA, cloud (EKS/GKE/AKS) differences, common pitfalls,
   anti-patterns.
7. **Quick Reference box** — key `kubectl` commands + minimal manifest skeleton +
   a short production checklist.
8. **Further reading** — specific citation into the user's book library + official
   docs (referenced, never copied).

## 8. Diagram inventory (minimum)

Mermaid: cluster architecture; API request → admission → etcd flow; reconciliation/
controller loop; Pod lifecycle state machine; scheduling cycle; Service + kube-proxy
DNAT path; CoreDNS resolution path; Ingress/Gateway traffic path; CNI packet path;
PV/PVC binding lifecycle; RBAC request authorization chain; HPA control loop; GitOps
sync loop; Bookstore architecture (shown evolving across parts). ASCII: namespace/
cgroup nesting, manifest field trees, directory layouts, quick topology sketches.

## 9. Reference book mapping

Books available in `~/Documents/learning/books/cloud-and-devops/kubernetes`:

- **Lukša, *Kubernetes in Action* 2e (Manning)** — primary structural reference for
  workloads/networking/config breadth & depth.
- **Poulton, *The Kubernetes Book*** — fundamentals framing.
- **Ibryam & Huß, *Kubernetes Patterns* 2e (O'Reilly)** — patterns chapters
  (workloads, multi-container, lifecycle, configuration).
- **Rosso et al., *Production Kubernetes* (O'Reilly)** — production-readiness,
  delivery, day-2.
- **Bilgin/*Argo CD Up & Running*** — GitOps chapter.
- **Davis, *Bootstrapping Microservices*** — example-app & CI/CD shape.

Method: extract the books' tables of contents (via context-mode tooling to avoid
context bloat) to **sanity-check curriculum coverage** and **cite** the right
chapter per topic. Book content is referenced/cited, never reproduced.

## 10. Build phasing (ordered)

Built and reviewable incrementally so it's useful as it grows:

1. **Phase 0:** `README.md`, `examples/bookstore/app/` skeletons + Dockerfiles,
   `appendix/B-glossary.md` seed.
2. **Phase 1:** Part 00 Foundations (7 files) + diagrams.
3. **Phase 2:** Part 01 Core Workloads (8 files) + `raw-manifests` for the app's
   early evolution.
4. **Phase 3:** Part 02 Networking + Part 03 Config/Storage (11 files).
5. **Phase 4:** Part 04 Scheduling + Part 05 Security (7 files).
6. **Phase 5:** Part 06 Production Readiness (6 files).
7. **Phase 6:** Part 07 Delivery (5 files) + Helm/Kustomize/Argo CD example trees.
8. **Phase 7:** Part 08 Day-2 Operations (5 files).
9. **Phase 8:** Part 09 Capstone + appendix completion + final consistency pass
   (cross-refs, the evolving Bookstore manifests reconcile end-to-end).

Each phase ends in a consistent, readable state.

## 11. Out of scope (YAGNI)

- Not cross-linked into the user's existing `.md` files.
- Not a parallel reference tree (reference value delivered via per-chapter Quick
  Reference boxes + appendix cheatsheet — Approach A, not C).
- No exhaustive cloud-provider-specific deep dives (covered as "production notes"
  callouts, not dedicated chapters).
- No deep service-mesh chapter (mesh introduced conceptually under networking/
  delivery; not a full Istio/Linkerd treatment) unless requested later.
- Example app code stays minimal — it is a vehicle for Kubernetes concepts, not a
  software-engineering tutorial.

## 12. Constraints / notes

- Working directory is **not a git repo**; design doc and guide are written to disk
  but not committed (no git available here).
- All hands-on steps must be reproducible on a local kind/k3d cluster with only
  open-source tooling.
- Markdown only; Mermaid code fences for rendered diagrams; fenced code blocks for
  YAML/shell.
