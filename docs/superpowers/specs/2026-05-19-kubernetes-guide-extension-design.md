# Design Spec: Kubernetes Guide Extension — Parts 10, 11, 12

**Date:** 2026-05-19
**Status:** Approved (design + scope + autonomous execution authorized by user)
**Author:** Claude (gap-analysis + brainstormed with user)
**Extends:** `docs/superpowers/specs/2026-05-19-kubernetes-comprehensive-guide-design.md` (the original 50-chapter guide, COMPLETE)

---

## 1. Why this extension

A rigorous gap analysis of the finished `full-guide/` (50 chapters + appendix) found three genuine gaps the user asked to close: **production-scale patterns**, **cloud / managed Kubernetes**, and **ML on Kubernetes (entirely absent)**. Production basics (observability, autoscaling, SLO/PDB, supply chain, progressive delivery, lifecycle/backup, RBAC/PodSecurity, Helm/Kustomize/GitOps, operators-as-consumer) are already DEEP and must NOT be re-added. This spec adds exactly the missing depth as **3 new Parts appended after Part 09**.

## 2. Hard rule: additive only

The 50 existing chapters and the canonical app artifacts (`examples/bookstore/{raw-manifests,helm,kustomize,argocd,operators,cluster,app}`) are **NOT modified**. Editing reviewed chapters would re-open regression risk to the established invariants for marginal gain. The ONLY existing files updated: `full-guide/README.md` (TOC: add Parts 10–12), `full-guide/appendix/B-glossary.md` (new terms), `full-guide/appendix/D-further-reading.md` (new refs). All new example code/manifests live in NEW additive paths (`examples/bookstore/ml/`, `examples/bookstore/operator/`, `examples/bookstore/cloud/`, `examples/bookstore/mesh/`, etc.). Small gaps the analysis flagged (JobSet, eBPF/Cilium, SPIFFE/SPIRE) are covered INSIDE the new Parts, never by editing old chapters.

## 3. Hard invariants every new chapter/manifest MUST preserve

(Carried forward from the original build — verified at the final consistency pass.)
- Existing canonical app unchanged: Helm default render **49** objects 0-CRD-miss; Kustomize overlays **dev 45 / staging 49 / prod 48** 0-CRD-miss; `helm lint` 0-failed; `DB_DSN` byte-identical across `raw-manifests/10`,`14`, the catalog Rollout, chapter inline blocks; no `cnpg`/`bookstore-db-rw` in `raw-manifests|helm|kustomize|argocd`; 4 app images `go vet` + `docker build` clean.
- ns `bookstore` is PSA `enforce: restricted`: every NEW pod that can land there (incl. ML/training/serving/operator/mesh/chaos/`kubectl run`/`kubectl debug`) is restricted-compliant (runAsNonRoot/non-root UID/allowPrivilegeEscalation:false/capabilities drop ALL/seccompProfile RuntimeDefault), OR runs in its own non-restricted namespace with a stated reason. GPU/mesh/operator system components install into their own namespaces.
- 9-section chapter anatomy (Title+summary, Why this exists, Mental model, Diagram(s), Hands-on with the Bookstore, How it works under the hood, Production notes with `> **In production:**`, Quick Reference, Further reading with book cite + official URL).
- Mermaid: valid header (`flowchart/graph/sequenceDiagram/stateDiagram-v2/classDiagram`; NO `timeline`), balanced fences, `<br/>` not literal `\n`, NO emoji in node labels.
- Self-bootstrapping hands-on; repo-root-relative paths; if catalog/orders are brought up, the standing bootstrap chain + `kubectl wait --for=condition=complete job/db-migrate` gate applies.
- Distroless app pods (catalog/orders/payments-worker) debugged via `kubectl debug --profile=restricted`, never `exec … sh`.
- Operator/add-on installs via **Helm with pinned chart versions** (or stable non-version-pinned manifest) — NEVER `kubectl apply -f .../releases/latest/download/<PINNED-FILE>.yaml`.
- CRD-backed manifests (KServe/Kueue/Volcano/Istio/Vault/ESO/Crossplane/Karmada/Chaos-Mesh/Argo-Workflows/Kubebuilder CRD/etc.) carry the documented intrinsic note: "client dry-run shows `no matches for kind` until the operator/CRDs are installed; schema-correct."
- NO machine-specific content (no usernames, `/Users/...`, `.colima`, "on this machine", real org/registry/email; generic labeled placeholders only).
- Honesty pattern: where a real GPU / cloud account / object store / secret manager is required, state it up-front as illustrative AND give a runnable CPU/local approximation where feasible (e.g. KServe sklearn CPU model, kind, local MinIO/Vault-dev) — the established precedent.
- Target Kubernetes **v1.30+**; current/correct commands & API versions; deprecated → version caveat.

## 4. Bookstore threading

The new Parts continue the ONE-app pedagogy:
- **ML:** a "**recommendations**" model ("customers who bought X also bought Y") — trained from catalog/orders data, served via KServe, consumed by `catalog`/`storefront`. Code in NEW `examples/bookstore/ml/` (tiny real training script + model + `InferenceService` + pipeline; CPU-runnable sklearn-class model so the serving path works without GPUs; GPU chapters honest about needing real GPUs).
- **Advanced Production:** a real **Kubebuilder operator** for the Bookstore in NEW `examples/bookstore/operator/`. Fixed scope (no ambiguity): a namespaced `BookstoreTenant` CRD (`bookstore.example.com/v1alpha1`) whose controller reconciles a minimal restricted-compliant Bookstore slice (a Deployment + Service + ConfigMap) into a tenant namespace, with finalizers, status conditions, events, and a v1alpha1→v1beta1 conversion webhook. Deliberately self-contained — it does NOT depend on KServe/Part 12 (no forward-coupling). Also in Part 11: an admission webhook; service-mesh injection of the running Bookstore; Vault/ESO-sourced DB creds shown as the production replacement for the demo Secret (additive — canonical `16-db-credentials.yaml` untouched); chaos experiments target the running Bookstore.
- **Cloud:** the same Bookstore described deployed to managed EKS/GKE/AKS (provisioning, cloud identity for its SAs, cloud LB/storage) — honest that a cloud account is needed; commands accurate.

## 5. The three new Parts

### Part 10 — Cloud & Managed Kubernetes (`full-guide/10-cloud-and-managed-kubernetes/`, 6 chapters)
1. `01-managed-kubernetes-model.md` — EKS/GKE/AKS architecture; shared-responsibility (provider owns control plane/etcd, you own nodes/workloads); control-plane SLAs/versioning; managed vs self-managed; regions/AZs/zonal vs regional clusters.
2. `02-provisioning-and-iac.md` — eksctl/gcloud/az; Terraform; Cluster API; managed cluster & node-pool/group lifecycle & upgrades; reproducible cluster IaC; deploying the Bookstore onto a managed cluster (described, honest cloud-account note).
3. `03-cloud-identity.md` — IRSA (EKS), GKE Workload Identity, AKS Workload Identity, EKS Pod Identity; mapping K8s ServiceAccounts → cloud IAM roles; least-privilege; the Bookstore services getting cloud creds with NO static keys; trust/OIDC mechanics.
4. `04-cloud-networking-and-load-balancing.md` — VPC CNI & cloud CNIs, IP exhaustion/pod CIDRs, private clusters; AWS Load Balancer Controller (ALB/NLB), GKE/AKS LB & Ingress/Gateway; ExternalDNS; cloud NetworkPolicy enforcement; eBPF/Cilium on cloud (the flagged eBPF-depth gap lands here).
5. `05-cloud-storage-and-data.md` — cloud CSI (EBS/PD/Azure Disk, EFS/Filestore/Azure Files), StorageClasses & volume binding, snapshots, cross-AZ/regional & RWX tradeoffs; the Bookstore Postgres on cloud disk; cloud backup integration (ties to Part 08 ch.02).
6. `06-node-autoscaling-cost-multicloud.md` — Cluster Autoscaler vs **Karpenter** (deep, consolidation/spot) / GKE Autopilot / AKS; spot/preemptible strategy; cloud cost & FinOps dashboards/Reserved/Savings; multi-cloud/hybrid & portability; cloud production checklist.

### Part 11 — Advanced Production Patterns (`full-guide/11-advanced-production-patterns/`, 10 chapters)
1. `01-admission-webhooks.md` — admission pipeline recap; build a real ValidatingAdmissionWebhook + MutatingAdmissionWebhook for the Bookstore; in-tree ValidatingAdmissionPolicy + CEL; TLS/cert mgmt, failurePolicy, sideEffects, ordering, matchConditions, testing & fail-safe.
2. `02-operator-development.md` — **Kubebuilder** hands-on: a real CRD+controller in `examples/bookstore/operator/`; reconcile loop (level-triggered/idempotent), owner refs, finalizers, status conditions/events, API versions & conversion webhooks, envtest, packaging (Helm/OLM); contrast with Part 08 ch.05 "using an operator".
3. `03-api-priority-and-fairness.md` — APF: FlowSchema/PriorityLevelConfiguration, request classification/queuing/fair-sharing, protecting the control plane from noisy tenants, APF metrics/observability, tuning.
4. `04-service-mesh.md` — why a mesh; Istio (ambient + sidecar) or Linkerd; mTLS/identity, traffic management (mesh-layer canary/mirroring) vs Gateway API, mesh observability (golden signals/tracing), cost/complexity; inject the Bookstore, mTLS between services; SPIFFE/SPIRE identity note (flagged gap lands here).
5. `05-secrets-at-scale.md` — External Secrets Operator + a backend (Vault and/or cloud SM); Vault (k8s auth, dynamic secrets, agent/sidecar injector, rotation); SOPS/Sealed-Secrets recap; the Bookstore DB creds sourced from a real secret manager as the production replacement for the demo Secret (additive; canonical untouched).
6. `06-multi-cluster-and-fleet.md` — why/when multi-cluster; topologies (per-env/region/tenant); Argo CD ApplicationSet across clusters; Karmada/Cluster API fleet; cross-cluster service discovery/networking (mesh multi-cluster, Submariner); failover/DR; the Bookstore across 2 clusters.
7. `07-chaos-engineering.md` — resilience-testing principles; Litmus / Chaos Mesh; steady-state hypotheses, blast radius, abort conditions; pod/node/network/IO/clock fault experiments against the Bookstore; game days; tie to SLOs/PDBs (Parts 06).
8. `08-ha-control-plane-and-etcd.md` — HA control-plane topology (stacked vs external etcd, LB), raft/quorum sizing, etcd maintenance (defrag, compaction, alarms, space quota), etcd disaster recovery beyond snapshot, control-plane node-loss recovery, component leader election.
9. `09-performance-and-scalability.md` — apiserver/etcd/kubelet/scheduler tuning; Kubernetes scalability thresholds & SLOs; pprof profiling; load/scale testing (kube-burner / clusterloader2); large-cluster considerations; the Bookstore under load.
10. `10-platform-engineering.md` — internal developer platforms; **Crossplane** (cloud infra as k8s APIs); **Backstage** (developer portal); golden paths / Score; self-service + the guardrail stack (RBAC/quota/policy/PSA from Parts 04–08) as a paved road for Bookstore teams.

### Part 12 — Kubernetes for Machine Learning (`full-guide/12-kubernetes-for-machine-learning/`, 8 chapters)
1. `01-why-ml-on-kubernetes.md` — ML workload taxonomy (interactive/notebooks, batch/training, tuning, batch inference, online serving, pipelines); why k8s for ML; the MLOps loop; what's different from stateless web (GPUs, gang scheduling, data gravity, long jobs, cost, reproducibility); introduce the Bookstore **recommendations** use case.
2. `02-gpus-and-accelerators.md` — device-plugin model, NVIDIA GPU Operator, requesting `nvidia.com/gpu`, MIG, time-slicing/MPS, GPU node pools/taints/labels, GPU-aware scheduling, DCGM/GPU monitoring; honest "needs real GPU nodes" + how to reason without one.
3. `03-batch-and-gang-scheduling.md` — Indexed Job → **JobSet** (the flagged gap); **Kueue** (ClusterQueue/LocalQueue, quotas, fair-share, preemption, suspend); **Volcano** (gang/PodGroup); why all-or-nothing matters for distributed training; multi-tenant GPU quota.
4. `04-distributed-training.md` — Kubeflow Training Operator (PyTorchJob/TFJob), **Ray/KubeRay** (RayJob/RayCluster), torchrun/Horovod patterns, checkpointing, data loading, elastic/fault-tolerant training; train the recommendations model on k8s (CPU-runnable small model; GPU notes honest).
5. `05-notebooks-and-interactive.md` — JupyterHub on k8s / Kubeflow Notebooks; per-user isolation/quota/GPU; the restricted-PSA reality for notebooks (must be hardened); data access & security; the dev→train→serve workflow.
6. `06-model-serving-and-inference.md` — **KServe** (InferenceService: predictor/transformer/explainer), Seldon, NVIDIA Triton; autoscaling inference (HPA/KEDA on RPS/latency, **scale-to-zero**), GPU sharing, model canary/A-B; serve the recommendations model to `catalog`/`storefront` (CPU sklearn-class model, runnable).
7. `07-ml-pipelines-and-workflows.md` — Argo Workflows / Kubeflow Pipelines; the train→evaluate→register→deploy DAG; data/feature reproducibility (volume snapshots, lineage), model registry; GitOps-for-models (ties to Part 07 delivery).
8. `08-ml-platform-cost-and-mlops.md` — GPU cost/FinOps (utilization, sharing, spot for training, scale-to-zero for serving), ML multi-tenancy & fairness (Kueue + quotas + RBAC), ML observability (training metrics, drift, serving SLOs), the **end-to-end MLOps capstone** for the Bookstore recommender (data→train→register→serve→monitor→retrain).

## 6. Existing-file updates (the only permitted edits to shipped files)
- `full-guide/README.md`: extend the TOC with Parts 10–12 (exact new chapter paths) + note the appendix covers the new domains; keep all existing entries byte-stable.
- `full-guide/appendix/B-glossary.md`: add the new terms (GPU/MIG/MPS/time-slicing, device plugin, Kueue/Volcano/JobSet/gang scheduling, KServe/Seldon/Triton/InferenceService, Ray/KubeRay, Kubeflow, IRSA/Workload Identity/Pod Identity, Karpenter, Crossplane, Backstage, Vault/External Secrets Operator, admission webhook/ValidatingAdmissionPolicy/CEL, API Priority & Fairness/FlowSchema, Kubebuilder/controller-runtime/envtest, Cluster API/Karmada, Chaos Mesh/Litmus, eBPF/Cilium, SPIFFE/SPIRE, …) each with a link to the new chapter that defines it; keep existing entries stable; update the note.
- `full-guide/appendix/D-further-reading.md`: add Parts 10–12 rows (books from the library where applicable + official docs: cloud-provider, Istio/Linkerd, Vault/ESO, Crossplane/Backstage, KServe/Kubeflow/Ray/Kueue, Chaos Mesh, Karpenter) — no invented sources.

## 7. Build phasing (each sub-phase = subagent author → spec-compliance review → code-quality review → fix loop, then proceed)
- **Phase X1:** Part 10 Cloud (6 ch) — one or two sub-phases.
- **Phase X2:** Part 11 Advanced Production — split (e.g. X2a webhooks+operator-dev+APF; X2b mesh+secrets+multi-cluster+chaos; X2c HA-etcd+perf+platform-eng) to keep depth/quality.
- **Phase X3:** Part 12 ML — split (e.g. X3a why+GPUs+batch/gang; X3b training+notebooks+serving; X3c pipelines+platform/MLOps-capstone) + the `examples/bookstore/ml/` tree.
- **Phase X4:** README TOC + appendix B/D updates + the **final guide-wide consistency pass over the EXTENDED guide** (links, mermaid, anatomy 50+24, all-manifest dry-run incl. new additive manifests + CRD-intrinsic, and re-prove every ORIGINAL hard invariant unchanged: 49/45/49/48, DB_DSN byte-identical, no-cnpg-leak, go vet/docker 4/4, PSA-restricted, leak-clean).
Each sub-phase ends consistent; the extension never regresses the original guide.

## 8. Success criteria
~24 new chapters across 3 Parts, each with full anatomy + threaded Bookstore + accurate v1.30+ technical content + CRD-intrinsic discipline + honesty notes; new example trees build/validate; README+appendix updated; the original 50 chapters and canonical app provably unchanged (all original invariants re-proven); zero machine leaks; guide-wide links/mermaid/anatomy clean.

## 9. Out of scope (YAGNI)
- No editing/refactoring the 50 existing chapters (gaps covered in new Parts).
- No exhaustive per-cloud-provider command reference for every service (focus = the k8s-relevant integration points; honest illustrative depth).
- No full from-scratch ML framework tutorials (the ML is a vehicle for the k8s ML platform, like the Bookstore is for k8s).
- No Windows-nodes / edge-k3s deep Parts (note as further-reading pointers only — not requested; YAGNI).
