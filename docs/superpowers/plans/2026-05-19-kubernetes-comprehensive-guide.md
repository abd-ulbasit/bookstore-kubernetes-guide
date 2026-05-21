# Comprehensive Kubernetes Guide — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `full-guide/` — a standalone, zero-to-production Kubernetes guide of ~56 markdown docs across 10 parts, teaching every concept by progressively building one realistic "Bookstore" microservices app, with Mermaid+ASCII diagrams, locally-runnable examples, and citations into the user's book library.

**Architecture:** Progressive narrative (Approach A). Parts = directories, chapters = files, uniform chapter anatomy. One example app (`examples/bookstore/`) evolves cumulatively: every chapter's hands-on section advances the *same* app. Built in 9 ordered phases (Phase 0 scaffolding → Phase 8 capstone+consistency); each phase ends in a consistent, readable state. Authoritative per-chapter coverage is the spec at `docs/superpowers/specs/2026-05-19-kubernetes-comprehensive-guide-design.md` §6 — every task below restates its coverage so tasks are self-contained.

**Tech Stack:** Markdown; Mermaid code fences; Go 1.26 (catalog/orders/payments-worker — tiny single-binary services); nginx (storefront static); upstream Postgres/Redis/RabbitMQ images; Helm; Kustomize; Argo CD; kind/k3d for local; validation via `kubectl apply --dry-run=client` (v1.35.4 present), `docker build`, `go vet`, `python3 -c yaml.safe_load`.

**Context-mode note:** Book PDF TOC extraction MUST use context-mode MCP tools (`ctx_batch_execute` / `ctx_execute_file`), never raw Read/Bash on the PDFs (they are 5–17 MB and would flood context). All file authoring uses native Write/Edit.

---

## Conventions for every chapter file (apply in all authoring tasks)

Each chapter MUST contain, in order:

1. **Title + one-line summary**
2. **Why this exists** — the problem it solves (motivation before mechanism)
3. **Mental model** — one-paragraph intuition
4. **Diagram(s)** — Mermaid for flow/architecture/lifecycle; ASCII for inline structure (per-chapter diagram requirements listed in tasks)
5. **Hands-on with the Bookstore** — runnable, copy-pasteable, builds on the previous chapter; commands use `kind`/`k3d`
6. **How it works under the hood** — internals depth, not just usage
7. **Production notes** — HA, cloud (EKS/GKE/AKS) differences, pitfalls/anti-patterns, with `> **In production:**` callouts
8. **Quick Reference** — key `kubectl` commands + minimal manifest skeleton + short production checklist
9. **Further reading** — specific citation into the user's book library (book + chapter/topic) + official docs URL

**Cross-file rule:** chapters reference earlier chapters by relative path. Every Bookstore manifest a chapter introduces is saved under `examples/bookstore/` and is cumulatively consistent (a manifest added in chapter N must still be valid and coherent with chapter N+1's additions).

**Per-file validation (run in each phase's validation step):**
- Every fenced ```yaml block that is a full manifest → extract and `kubectl apply --dry-run=client -f -` must succeed (or `python3 -c "import yaml,sys;list(yaml.safe_load_all(sys.stdin))"` if it's a snippet, not a full object).
- Every ```mermaid fence → balanced fences, valid diagram header (`graph`, `flowchart`, `sequenceDiagram`, `stateDiagram-v2`, `classDiagram`).
- All relative markdown links resolve to an existing file.
- Go code under `examples/bookstore/app` → `go vet ./...` and `docker build` succeed.

---

## File Structure (locked)

```
full-guide/
├── README.md
├── 00-foundations/ 01-why-kubernetes · 02-containers-and-images · 03-architecture-overview ·
│     04-control-plane-deep-dive · 05-node-components · 06-declarative-api-model · 07-local-cluster-setup
├── 01-core-workloads/ 01-pods · 02-health-and-lifecycle · 03-resources-and-qos ·
│     04-replicasets-and-deployments · 05-statefulsets · 06-daemonsets · 07-jobs-and-cronjobs · 08-deployment-strategies
├── 02-networking/ 01-networking-model · 02-services · 03-dns-and-discovery · 04-ingress · 05-gateway-api · 06-network-policies
├── 03-config-and-storage/ 01-configmaps · 02-secrets · 03-volumes · 04-persistent-storage · 05-stateful-data-patterns
├── 04-scheduling/ 01-scheduler-and-nodes · 02-affinity-taints-topology · 03-priority-and-preemption
├── 05-security/ 01-authn-authz-rbac · 02-pod-security · 03-supply-chain · 04-secrets-and-cluster-hardening
├── 06-production-readiness/ 01-observability-metrics · 02-logging · 03-tracing · 04-autoscaling ·
│     05-reliability-and-disruptions · 06-capacity-and-cost
├── 07-delivery/ 01-packaging-helm · 02-packaging-kustomize · 03-cicd-pipeline · 04-gitops-argocd · 05-progressive-delivery
├── 08-day-2-operations/ 01-cluster-lifecycle · 02-backup-and-dr · 03-troubleshooting-playbook ·
│     04-multi-tenancy-and-namespaces · 05-operators-and-crds
├── 09-end-to-end-bookstore/ 01-bookstore-end-to-end
├── examples/bookstore/{app,raw-manifests,helm/bookstore,kustomize/{base,overlays/{dev,staging,prod}},argocd}
└── appendix/ A-kubectl-cheatsheet · B-glossary · C-yaml-and-api-conventions · D-further-reading · E-learning-paths
```

---

## Phase 0 — Scaffolding & shared assets

### Task 0.1: Directory tree + README

**Files:** Create `full-guide/` full directory tree (all part dirs, `examples/bookstore/**`, `appendix/`); Create `full-guide/README.md`.

- [ ] **Step 1:** Create directory tree with `mkdir -p` for every path in the File Structure block above.
- [ ] **Step 2:** Write `README.md`: what this guide is; who it's for (zero-to-production, no prior k8s assumed); the Bookstore app overview table (7 services from spec §5) + a Mermaid diagram of target architecture; how chapters are structured (the 9-section anatomy); prerequisites; how to run examples locally (kind/k3d install one-liners); the full table of contents linking every chapter; a note that it's standalone (not linked to the user's other docs); legend for `> **In production:**` callouts.
- [ ] **Step 3 (validate):** All TOC links resolve to paths that will exist (created as empty `.gitkeep`-style stubs is NOT allowed — instead the TOC links are validated at the Phase 8 consistency pass; for now assert directory tree exists via `ls -R full-guide | head`).
- [ ] **Step 4:** Mark task complete in TaskUpdate.

### Task 0.2: Book TOC extraction for coverage alignment

**Files:** Create `docs/superpowers/specs/book-toc-reference.md` (internal working note, not part of the guide).

- [ ] **Step 1:** Using **context-mode MCP** (`ctx_batch_execute` with `pdftotext`/`pdfinfo` or `ctx_execute_file` python with `pypdf`), extract the table of contents (chapter/section list only, first ~15 pages) for: Lukša *Kubernetes in Action 2e*, Ibryam/Huß *Kubernetes Patterns 2e*, Rosso *Production Kubernetes*, *Argo CD Up & Running*. Keep raw text in the context-mode sandbox; only the distilled TOC enters context.
- [ ] **Step 2:** Write `book-toc-reference.md`: per book, the chapter list and a mapping `guide chapter → book/chapter to cite`. Flag any major Kubernetes topic present in the books but missing from the spec's 50 chapters.
- [ ] **Step 3 (gap handling):** If a material gap is found, note it in the file and add a covering subsection to the most relevant existing chapter's task (do NOT silently expand scope into new chapters; record the decision in the file).
- [ ] **Step 4 (validate):** File exists; every one of the 50 chapters has a citation target row.

### Task 0.3: Bookstore example app source + Dockerfiles

**Files:** Create under `full-guide/examples/bookstore/app/`:
- `catalog/` (Go: `main.go`, `go.mod`, `Dockerfile`) — HTTP API: `GET /healthz`, `GET /readyz`, `GET /books` (reads Postgres, falls back to in-memory; caches in Redis if `REDIS_ADDR` set), `GET /metrics` (Prometheus). Config via env (`PORT`, `DB_DSN`, `REDIS_ADDR`, `LOG_LEVEL`).
- `orders/` (Go) — `POST /orders` (writes Postgres, publishes to RabbitMQ if `AMQP_URL` set), `GET /healthz|/readyz|/metrics`.
- `payments-worker/` (Go) — consumes RabbitMQ queue, logs processed payment, exposes `/healthz|/metrics`; no-queue mode logs idle.
- `storefront/` — static `index.html` + `nginx.conf` + `Dockerfile` (nginx:alpine) calling catalog/orders via JS fetch.
- `app/README.md` — how each builds, env vars, ports.

Constraints: each Go service ≤ ~300 lines, stdlib + minimal deps (`lib/pq` or `pgx`, `streadway/amqp` or `rabbitmq/amqp091-go`, `prometheus/client_golang`, `redis/go-redis`), multi-stage Dockerfile producing a distroless/`scratch` image, runs as non-root, listens on `:8080` (configurable).

- [ ] **Step 1:** Write `catalog` (main.go, go.mod, Dockerfile).
- [ ] **Step 2:** Write `orders`, `payments-worker`, `storefront`.
- [ ] **Step 3:** Write `app/README.md`.
- [ ] **Step 4 (validate):** For each Go service: `go vet ./...` passes; `docker build -t bookstore/<SVC>:dev .` succeeds. Storefront: `docker build` succeeds. Record image names — chapters reference these exact tags.
- [ ] **Step 5:** Commit-equivalent: TaskUpdate complete (no git here; "commit" steps mean checkpoint + TaskUpdate throughout this plan).

### Task 0.4: Seed glossary

**Files:** Create `full-guide/appendix/B-glossary.md`.

- [ ] **Step 1:** Seed with core terms (Pod, Node, Control Plane, kube-apiserver, etcd, kubelet, controller, reconciliation, Deployment, Service, Ingress, PVC, CRD, RBAC, namespace). Each: 1–3 sentence definition, link to the chapter that covers it. Marked "expanded in Phase 8".
- [ ] **Step 2 (validate):** Markdown renders; links target planned chapter paths.

**Phase 0 exit criteria:** tree exists; README written; app images build; glossary + TOC-reference seeded.

---

## Phase 1 — Part 00 Foundations (7 files)

### Task 1.1: `00-foundations/01-why-kubernetes.md`
- [ ] Coverage: bare metal → VMs → containers → orchestration; the problems k8s solves (scheduling, self-healing, scaling, service discovery, rollouts) and what it does NOT solve; pets vs cattle; imperative vs declarative; when NOT to use k8s.
- [ ] Diagrams: **Mermaid** evolution timeline (metal→VM→container→orchestrated); **ASCII** "desired vs actual state" loop sketch.
- [ ] Bookstore increment: introduce the app's 7 services conceptually + a Mermaid component diagram (no manifests yet).
- [ ] Citation: Poulton ch.1; Lukša ch.1. Validate per conventions.

### Task 1.2: `00-foundations/02-containers-and-images.md`
- [ ] Coverage: containers vs VMs; Linux namespaces & cgroups; OCI image spec, layers, content addressing; registries & pull flow; image tags vs digests; building minimal images (multi-stage, distroless).
- [ ] Diagrams: **Mermaid** image-layer/registry pull sequence; **ASCII** namespace/cgroup nesting.
- [ ] Bookstore increment: walk the actual `catalog` Dockerfile from Task 0.3; build & run it with plain `docker`.
- [ ] Citation: Poulton ch.3; Lukša ch.2. Validate (the Dockerfile referenced must be the real one).

### Task 1.3: `00-foundations/03-architecture-overview.md`
- [ ] Coverage: cluster big picture; control plane vs data plane; component map; the lifecycle of "apply a manifest → running Pod" at overview depth.
- [ ] Diagrams: **Mermaid** full cluster architecture (control plane components, nodes, kubelet, runtime, etcd); **Mermaid** sequence: `kubectl apply` → apiserver → etcd → scheduler → kubelet.
- [ ] Bookstore increment: none (conceptual) — forward-reference where each service will land.
- [ ] Citation: Poulton ch.2; Lukša ch.3. Validate.

### Task 1.4: `00-foundations/04-control-plane-deep-dive.md`
- [ ] Coverage: kube-apiserver (REST, validation, admission, the only etcd client); etcd (raft, consistency, the source of truth); scheduler (what it decides); controller-manager (control loops); cloud-controller-manager; control-plane HA topology.
- [ ] Diagrams: **Mermaid** API request pipeline (authN→authZ→mutating→validating→etcd); **Mermaid** HA control plane (stacked vs external etcd).
- [ ] Citation: Lukša ch.3/11; Rosso ch.1. Validate.

### Task 1.5: `00-foundations/05-node-components.md`
- [ ] Coverage: kubelet (PodSpec→containers, PLEG, probes); CRI & containerd; the pause/sandbox container; kube-proxy role; full sequence of a Pod starting on a node.
- [ ] Diagrams: **Mermaid** sequence kubelet↔CRI↔CNI for pod sandbox creation; **ASCII** node component box diagram.
- [ ] Citation: Lukša ch.2/3. Validate.

### Task 1.6: `00-foundations/06-declarative-api-model.md`
- [ ] Coverage: objects, GVK, `metadata/spec/status`, resourceVersion & optimistic concurrency, the reconciliation principle (level-triggered), `kubectl apply` 3-way merge / server-side apply intro, etcd as source of truth, labels/selectors/annotations.
- [ ] Diagrams: **Mermaid** reconcile loop (observe→diff→act); **ASCII** object anatomy tree.
- [ ] Bookstore increment: write the first real manifest — `catalog` as a Pod — to `examples/bookstore/raw-manifests/01-catalog-pod.yaml`; explain every field.
- [ ] Citation: Lukša ch.4; Ibryam "Predictable Demands"/"Declarative Deployment" intro. Validate (dry-run the pod manifest).

### Task 1.7: `00-foundations/07-local-cluster-setup.md`
- [ ] Coverage: install kubectl; kind vs k3d vs minikube; create a cluster; kubeconfig & contexts; verify control plane/nodes; `kubectl` basics (get/describe/logs/exec/apply); deploy the first Bookstore Pod from Task 1.6.
- [ ] Diagrams: **Mermaid** kind cluster = Docker containers as nodes; **ASCII** kubeconfig structure.
- [ ] Bookstore increment: run `01-catalog-pod.yaml` on a local kind cluster, port-forward, curl `/healthz`.
- [ ] Citation: Poulton ch.3 appendix; Lukša ch.3. Validate.

### Task 1.8: Phase 1 validation
- [ ] Run per-file validation (YAML dry-run, mermaid fences, links) for all 7 files + `01-catalog-pod.yaml`. Fix issues inline. TaskUpdate.

---

## Phase 2 — Part 01 Core Workloads (8 files) + early app manifests

### Task 2.1: `01-core-workloads/01-pods.md`
- [ ] Coverage: Pod = shared net/IPC/UTS namespace + volumes; phases & conditions; multi-container patterns (sidecar incl. native sidecar/init order, ambassador, adapter); init containers; ephemeral (debug) containers; why you rarely create bare Pods.
- [ ] Diagrams: **Mermaid** Pod lifecycle state machine; **ASCII** shared-namespace box.
- [ ] Bookstore increment: add a logging sidecar to `catalog` Pod → `raw-manifests/02-catalog-pod-sidecar.yaml`.
- [ ] Citation: Lukša ch.5; Ibryam "Sidecar/Init Container/Ambassador/Adapter". Validate.

### Task 2.2: `01-core-workloads/02-health-and-lifecycle.md`
- [ ] Coverage: liveness/readiness/startup probes (exec/http/tcp/grpc), parameters; `postStart`/`preStop` hooks; SIGTERM + `terminationGracePeriodSeconds`; graceful shutdown contract; readiness gating traffic.
- [ ] Diagrams: **Mermaid** sequence: probe failure → restart vs endpoint removal; **Mermaid** termination sequence.
- [ ] Bookstore increment: add probes + preStop to `catalog` using its `/healthz`,`/readyz`.
- [ ] Citation: Lukša ch.6; Ibryam "Health Probe". Validate.

### Task 2.3: `01-core-workloads/03-resources-and-qos.md`
- [ ] Coverage: requests vs limits; CPU (compressible, throttling) vs memory (incompressible, OOMKill) semantics; QoS classes (Guaranteed/Burstable/BestEffort); node eviction order; LimitRange & ResourceQuota.
- [ ] Diagrams: **Mermaid** QoS decision tree; **ASCII** node allocatable vs requests/limits bar.
- [ ] Bookstore increment: set requests/limits on all services; add a namespace `ResourceQuota` + `LimitRange`.
- [ ] Citation: Lukša ch.20; Ibryam "Predictable Demands". Validate.

### Task 2.4: `01-core-workloads/04-replicasets-and-deployments.md`
- [ ] Coverage: ReplicaSet & selectors; Deployment; rolling update mechanics (maxSurge/maxUnavailable, the surge math); `recreate`; revisionHistory; rollback; `kubectl rollout`; how Deployment owns ReplicaSets.
- [ ] Diagrams: **Mermaid** Deployment→RS→Pod ownership; **Mermaid** rolling-update timeline.
- [ ] Bookstore increment: convert `catalog` + add `storefront` as **Deployments** → `raw-manifests/10-catalog-deploy.yaml`, `11-storefront-deploy.yaml`.
- [ ] Citation: Lukša ch.13/14; Ibryam "Declarative Deployment". Validate.

### Task 2.5: `01-core-workloads/05-statefulsets.md`
- [ ] Coverage: stable network identity & ordinal; ordered vs parallel pod management; headless Service requirement; `volumeClaimTemplates`; scaling/update (`partition`); when StatefulSet vs Deployment.
- [ ] Diagrams: **Mermaid** StatefulSet ordinal + PVC-per-pod; **ASCII** `pod-0/1/2` stable DNS.
- [ ] Bookstore increment: add `postgres` as a StatefulSet → `raw-manifests/20-postgres-statefulset.yaml` + headless svc.
- [ ] Citation: Lukša ch.15; Ibryam "Stateful Service". Validate.

### Task 2.6: `01-core-workloads/06-daemonsets.md`
- [ ] Coverage: one-pod-per-node; node selection & tolerations for system pods; update strategy; use cases (CNI, logging, metrics, node-exporter).
- [ ] Diagrams: **Mermaid** DaemonSet scheduling across nodes; **ASCII** node→agent.
- [ ] Bookstore increment: none direct — forward-reference (logging agent appears in observability part).
- [ ] Citation: Lukša ch.16. Validate.

### Task 2.7: `01-core-workloads/07-jobs-and-cronjobs.md`
- [ ] Coverage: Job (completions, parallelism, backoffLimit, activeDeadline, indexed Jobs); CronJob (schedule, concurrencyPolicy, startingDeadline, history limits); run-to-completion vs long-running.
- [ ] Diagrams: **Mermaid** Job parallelism modes; **Mermaid** CronJob trigger timeline.
- [ ] Bookstore increment: DB-migration **Job** (`raw-manifests/21-db-migrate-job.yaml`) + nightly cleanup **CronJob** (`raw-manifests/22-cleanup-cronjob.yaml`).
- [ ] Citation: Lukša ch.17; Ibryam "Batch Job/Periodic Job". Validate.

### Task 2.8: `01-core-workloads/08-deployment-strategies.md`
- [ ] Coverage: recreate vs rolling deep dive; blue-green; canary (concept + manual via two Deployments + Service selector); progressive delivery teaser (forward-ref Part 07).
- [ ] Diagrams: **Mermaid** blue-green traffic switch; **Mermaid** canary weight ramp.
- [ ] Bookstore increment: manual canary of `catalog` (v1/v2 Deployments behind one Service).
- [ ] Citation: Ibryam "Declarative Deployment"; Rosso ch. on release. Validate.

### Task 2.9: Phase 2 validation
- [ ] Validate all 8 files + every `raw-manifests/*.yaml` with `kubectl apply --dry-run=client`; assert manifests are cumulatively coherent (labels/selectors/namespaces consistent across files). Fix inline. TaskUpdate.

---

## Phase 3 — Part 02 Networking (6) + Part 03 Config/Storage (5)

### Task 3.1: `02-networking/01-networking-model.md`
- [ ] Coverage: the 4 networking problems (container-container, pod-pod, pod-service, external-service); IP-per-Pod; flat-network requirement; CNI spec; plugin landscape (Calico/Cilium/Flannel) overlay vs BGP vs eBPF.
- [ ] Diagrams: **Mermaid** the 4 problems; **Mermaid** CNI plugin invocation by kubelet; **ASCII** overlay vs routed.
- [ ] Citation: Lukša ch.19; Rosso networking ch. Validate.

### Task 3.2: `02-networking/02-services.md`
- [ ] Coverage: ClusterIP/NodePort/LoadBalancer/ExternalName; Endpoints vs EndpointSlices; kube-proxy iptables vs IPVS vs eBPF (DNAT path); sessionAffinity; headless.
- [ ] Diagrams: **Mermaid** packet path client→Service→kube-proxy DNAT→Pod; **ASCII** service types ladder.
- [ ] Bookstore increment: ClusterIP Services for catalog/postgres/redis; storefront Service.
- [ ] Citation: Lukša ch.10; Ibryam "Service Discovery". Validate.

### Task 3.3: `02-networking/03-dns-and-discovery.md`
- [ ] Coverage: CoreDNS; A/SRV records for Services & headless Pods; search domains & `ndots:5` pitfall; DNS policy; cross-namespace FQDNs.
- [ ] Diagrams: **Mermaid** DNS resolution path pod→CoreDNS→answer; **ASCII** record naming scheme.
- [ ] Bookstore increment: wire services by DNS name (catalog→postgres `postgres.default.svc`).
- [ ] Citation: Lukša ch.10. Validate.

### Task 3.4: `02-networking/04-ingress.md`
- [ ] Coverage: Ingress resource; controllers (ingress-nginx); host/path rules; TLS termination & cert sources; default backend; install ingress-nginx on kind.
- [ ] Diagrams: **Mermaid** external request → Ingress controller → Service → Pod; **ASCII** host/path routing table.
- [ ] Bookstore increment: Ingress exposing storefront + `/api` → catalog/orders, with TLS (self-signed/local).
- [ ] Citation: Lukša ch.12; Rosso ingress ch. Validate.

### Task 3.5: `02-networking/05-gateway-api.md`
- [ ] Coverage: Gateway API resources (GatewayClass/Gateway/HTTPRoute/Reference Grant); role-oriented model; why it supersedes Ingress; Ingress→Gateway migration.
- [ ] Diagrams: **Mermaid** Gateway API object relationships; **ASCII** persona separation.
- [ ] Bookstore increment: equivalent of the Ingress expressed as Gateway + HTTPRoute (alternative manifest).
- [ ] Citation: official Gateway API docs; Rosso. Validate.

### Task 3.6: `02-networking/06-network-policies.md`
- [ ] Coverage: default-allow problem; NetworkPolicy ingress/egress; podSelector/namespaceSelector/ipBlock; default-deny pattern; CNI must support it; common policy recipes.
- [ ] Diagrams: **Mermaid** allowed vs denied flows after default-deny; **ASCII** policy matrix.
- [ ] Bookstore increment: default-deny in namespace; allow only catalog→postgres, orders→rabbitmq, ingress→storefront.
- [ ] Citation: Lukša ch.19; Rosso security ch. Validate.

### Task 3.7: `03-config-and-storage/01-configmaps.md`
- [ ] Coverage: 3 consumption modes (env, envFrom, volume); subPath; immutable ConfigMaps; live-update behavior & reload strategies; size limits.
- [ ] Diagrams: **Mermaid** ConfigMap→Pod injection modes; **ASCII** the three modes.
- [ ] Bookstore increment: externalize catalog config to a ConfigMap (LOG_LEVEL, feature flags).
- [ ] Citation: Lukša ch.9; Ibryam "Configuration Resource". Validate.

### Task 3.8: `03-config-and-storage/02-secrets.md`
- [ ] Coverage: Secret types; base64 ≠ encryption; encryption-at-rest (EncryptionConfiguration/KMS); RBAC on secrets; external secret stores (External Secrets Operator / Vault) overview; imagePullSecrets.
- [ ] Diagrams: **Mermaid** secret at rest path apiserver→(encrypt)→etcd; **ASCII** secret vs configmap.
- [ ] Bookstore increment: DB credentials as a Secret; mount into catalog/orders; reference an external-secrets pattern conceptually.
- [ ] Citation: Lukša ch.9; Rosso security ch. Validate.

### Task 3.9: `03-config-and-storage/03-volumes.md`
- [ ] Coverage: volume vs persistent volume; emptyDir (incl. memory), hostPath dangers, projected, downwardAPI, configMap/secret volumes; volume lifecycle tied to Pod.
- [ ] Diagrams: **Mermaid** volume taxonomy; **ASCII** pod↔volume mount.
- [ ] Bookstore increment: emptyDir scratch + downwardAPI (pod metadata) into catalog.
- [ ] Citation: Lukša ch.7. Validate.

### Task 3.10: `03-config-and-storage/04-persistent-storage.md`
- [ ] Coverage: PV/PVC lifecycle & binding; StorageClass & dynamic provisioning; access modes (RWO/ROX/RWX/RWOP); reclaim policy; `volumeBindingMode: WaitForFirstConsumer`; CSI architecture; expansion; snapshots.
- [ ] Diagrams: **Mermaid** PVC→(StorageClass)→PV bind lifecycle; **Mermaid** CSI components; **ASCII** access-mode matrix.
- [ ] Bookstore increment: Postgres PVC via StorageClass (local-path on kind); show data persists across pod restart.
- [ ] Citation: Lukša ch.7/8; Rosso storage ch. Validate.

### Task 3.11: `03-config-and-storage/05-stateful-data-patterns.md`
- [ ] Coverage: snapshots/clones; backup approaches; running databases on k8s — tradeoffs, when to use a managed DB vs operator; intro to operators (forward-ref Part 08).
- [ ] Diagrams: **Mermaid** decide: managed DB vs operator vs DIY StatefulSet.
- [ ] Bookstore increment: Postgres VolumeSnapshot example; note "in production, prefer CloudNativePG/managed RDS".
- [ ] Citation: Rosso; Ibryam "Stateful Service". Validate.

### Task 3.12: Phase 3 validation
- [ ] Validate all 11 files + new manifests; cumulative coherence check (the app now: storefront/catalog/orders Deployments, postgres/redis/rabbitmq, services, ingress, config/secrets, NetworkPolicy all consistent). Fix inline. TaskUpdate.

---

## Phase 4 — Part 04 Scheduling (3) + Part 05 Security (4)

### Task 4.1: `04-scheduling/01-scheduler-and-nodes.md`
- [ ] Coverage: scheduling cycle (filter/predicate → score/priority → bind); nodeName/nodeSelector; node conditions & allocatable; why Pods go Pending; scheduler extensibility (profiles/plugins overview).
- [ ] Diagrams: **Mermaid** scheduling pipeline; **ASCII** filter→score.
- [ ] Citation: Lukša ch.21. Validate.

### Task 4.2: `04-scheduling/02-affinity-taints-topology.md`
- [ ] Coverage: node affinity (required/preferred); pod (anti-)affinity & topologyKey; taints & tolerations (NoSchedule/PreferNoSchedule/NoExecute); topology spread constraints; combining for HA.
- [ ] Diagrams: **Mermaid** anti-affinity spreading replicas across nodes/zones; **ASCII** taint/toleration match.
- [ ] Bookstore increment: spread storefront/catalog across nodes/zones; taint a "db" node, tolerate on postgres.
- [ ] Citation: Lukša ch.21; Ibryam "Node/Pod Placement". Validate.

### Task 4.3: `04-scheduling/03-priority-and-preemption.md`
- [ ] Coverage: PriorityClass; preemption mechanics & victims; eviction vs preemption; cordon/drain; descheduler overview.
- [ ] Diagrams: **Mermaid** preemption decision; **ASCII** priority ladder.
- [ ] Bookstore increment: PriorityClass: postgres > catalog/orders > batch jobs.
- [ ] Citation: Lukša ch.21. Validate.

### Task 4.4: `05-security/01-authn-authz-rbac.md`
- [ ] Coverage: request pipeline authN (certs/tokens/OIDC) → authZ (RBAC) → admission; users vs Groups vs ServiceAccounts; Role/ClusterRole/RoleBinding/ClusterRoleBinding; verbs/resources/aggregation; least privilege; `kubectl auth can-i`.
- [ ] Diagrams: **Mermaid** request authZ chain; **ASCII** RBAC object matrix.
- [ ] Bookstore increment: dedicated ServiceAccount per service + minimal Role (e.g., catalog reads its ConfigMap only).
- [ ] Citation: Lukša ch.24; Rosso security ch. Validate.

### Task 4.5: `05-security/02-pod-security.md`
- [ ] Coverage: securityContext (runAsNonRoot/runAsUser/fsGroup); drop ALL capabilities; readOnlyRootFilesystem; allowPrivilegeEscalation; seccomp (RuntimeDefault); AppArmor; Pod Security Admission (privileged/baseline/restricted) by namespace label.
- [ ] Diagrams: **Mermaid** PSA enforcement at admission; **ASCII** hardening checklist.
- [ ] Bookstore increment: harden all services (non-root, drop caps, RO rootfs, seccomp); label namespace `restricted`.
- [ ] Citation: Lukša ch.24; Rosso security ch. Validate.

### Task 4.6: `05-security/03-supply-chain.md`
- [ ] Coverage: image scanning (Trivy); signing (Cosign) & verification; admission policy (Kyverno/Gatekeeper) — verify-images/disallow-latest; distroless/minimal base; SBOM; pin digests.
- [ ] Diagrams: **Mermaid** secure pipeline scan→sign→admit; **ASCII** trust chain.
- [ ] Bookstore increment: Trivy-scan the catalog image; a Kyverno policy requiring digests + non-root.
- [ ] Citation: Rosso security/supply-chain; official Kyverno docs. Validate.

### Task 4.7: `05-security/04-secrets-and-cluster-hardening.md`
- [ ] Coverage: encryption-at-rest config; audit logging (policy levels/stages); kube-bench/CIS; API server hardening flags; network hardening recap; a Bookstore threat model (STRIDE-lite) with mitigations mapped to prior chapters.
- [ ] Diagrams: **Mermaid** audit event flow; **ASCII** defense-in-depth layers.
- [ ] Citation: Rosso security ch.; CIS Benchmark. Validate.

### Task 4.8: Phase 4 validation
- [ ] Validate 7 files + manifests; ensure hardened pod specs still pass `--dry-run` and remain consistent with earlier manifests (update earlier raw-manifests if hardening changes them, keep cumulative coherence). Fix inline. TaskUpdate.

---

## Phase 5 — Part 06 Production Readiness (6 files)

### Task 5.1: `06-production-readiness/01-observability-metrics.md`
- [ ] Coverage: metrics-server vs Prometheus; Prometheus architecture (scrape/TSDB/PromQL); kube-state-metrics; ServiceMonitor (Prometheus Operator); instrumenting Go (the catalog `/metrics`); Grafana; four golden signals / RED / USE.
- [ ] Diagrams: **Mermaid** Prometheus scrape + Grafana; **ASCII** RED/USE table.
- [ ] Bookstore increment: deploy kube-prometheus-stack on kind; ServiceMonitor for catalog; sample PromQL + dashboard panels.
- [ ] Citation: Rosso observability ch.; Lukša ch.; official Prometheus docs. Validate.

### Task 5.2: `06-production-readiness/02-logging.md`
- [ ] Coverage: 12-factor stdout logging; node-level agents (Fluent Bit) → Loki/Elasticsearch; structured JSON logs; log levels; correlation IDs; pitfalls (sidecar vs node agent).
- [ ] Diagrams: **Mermaid** logs: container→stdout→agent→store; **ASCII** logging architectures.
- [ ] Bookstore increment: switch services to structured logs; deploy Loki+Promtail (or Fluent Bit) on kind; query a request.
- [ ] Citation: Rosso observability ch. Validate.

### Task 5.3: `06-production-readiness/03-tracing.md`
- [ ] Coverage: spans/traces/context propagation; OpenTelemetry SDK + Collector; sampling; exporters (Jaeger/Tempo); instrumenting an HTTP call chain.
- [ ] Diagrams: **Mermaid** trace across storefront→catalog→postgres; **ASCII** span tree.
- [ ] Bookstore increment: add OTel to catalog/orders; trace a checkout; view in Jaeger/Tempo.
- [ ] Citation: official OpenTelemetry docs; Rosso. Validate.

### Task 5.4: `06-production-readiness/04-autoscaling.md`
- [ ] Coverage: HPA v2 (CPU + custom/external metrics, stabilization, behavior); VPA modes; Cluster Autoscaler; KEDA (event-driven, ScaledObject); interaction pitfalls (HPA+VPA).
- [ ] Diagrams: **Mermaid** HPA control loop (metrics→desired replicas); **Mermaid** KEDA queue-length scaling.
- [ ] Bookstore increment: HPA on catalog (CPU + custom req/s); KEDA scaling payments-worker on RabbitMQ queue depth; load test to demonstrate.
- [ ] Citation: Lukša ch.20; Rosso scaling ch.; KEDA docs. Validate.

### Task 5.5: `06-production-readiness/05-reliability-and-disruptions.md`
- [ ] Coverage: PodDisruptionBudget (voluntary vs involuntary disruptions); multi-replica + anti-affinity HA; graceful node drain interaction with PDB; topology spread for zone failure; SLO/SLI & error budgets.
- [ ] Diagrams: **Mermaid** drain blocked by PDB; **ASCII** SLO/error-budget.
- [ ] Bookstore increment: PDBs for storefront/catalog/orders; demonstrate a node drain respecting PDB.
- [ ] Citation: Rosso reliability ch.; SRE workbook concepts. Validate.

### Task 5.6: `06-production-readiness/06-capacity-and-cost.md`
- [ ] Coverage: right-sizing from observed usage; requests vs limits revisited (CPU-limit throttling debate); namespace quotas as guardrails; bin-packing/utilization; cost visibility tools overview (Kubecost/OpenCost) — conceptual.
- [ ] Diagrams: **Mermaid** right-size feedback loop; **ASCII** utilization vs cost.
- [ ] Bookstore increment: derive right-sized requests for catalog from metrics gathered in Task 5.1.
- [ ] Citation: Rosso; OpenCost docs. Validate.

### Task 5.7: Phase 5 validation
- [ ] Validate 6 files + manifests; ensure observability/autoscaling manifests coherent with hardened specs. Fix inline. TaskUpdate.

---

## Phase 6 — Part 07 Delivery (5) + packaging trees

### Task 6.1: `07-delivery/01-packaging-helm.md` + `examples/bookstore/helm/bookstore/`
- [ ] Coverage: Helm concepts (chart/values/release/revision/hooks); templating, `_helpers.tpl`, `values.yaml` design, `helm lint/template/install/upgrade/rollback`; chart dependencies (subcharts for redis/rabbitmq); when Helm hurts.
- [ ] Build: a real `helm/bookstore` chart templating all Bookstore resources from the accumulated raw-manifests, with sane `values.yaml`.
- [ ] Diagrams: **Mermaid** Helm render→release pipeline; **ASCII** chart dir layout.
- [ ] Citation: Rosso delivery ch.; official Helm docs.
- [ ] Validate: `helm lint`, `helm template | kubectl apply --dry-run=client -f -`.

### Task 6.2: `07-delivery/02-packaging-kustomize.md` + `examples/bookstore/kustomize/`
- [ ] Coverage: Kustomize bases/overlays, patches (strategic/JSON6902), components, generators, `kubectl -k`; Helm vs Kustomize vs both.
- [ ] Build: `kustomize/base` + `overlays/{dev,staging,prod}` (replica counts, resources, image tags, ingress hosts differ per env).
- [ ] Diagrams: **Mermaid** base+overlay→rendered; **ASCII** overlay tree.
- [ ] Citation: Rosso delivery ch.; official Kustomize docs.
- [ ] Validate: `kubectl kustomize overlays/prod | kubectl apply --dry-run=client -f -`.

### Task 6.3: `07-delivery/03-cicd-pipeline.md`
- [ ] Coverage: pipeline stages build→test→scan(Trivy)→sign(Cosign)→push→update-manifests; tags vs digests; promotion across envs; a complete GitHub Actions workflow for Bookstore; image-update strategies (CI commits vs Argo Image Updater).
- [ ] Diagrams: **Mermaid** CI/CD stage flow; **ASCII** env promotion.
- [ ] Citation: Davis (CI/CD shape); Rosso. Validate (workflow YAML lints; manifests dry-run).

### Task 6.4: `07-delivery/04-gitops-argocd.md` + `examples/bookstore/argocd/`
- [ ] Coverage: GitOps principles (declarative, versioned, pulled, continuously reconciled); Argo CD architecture (repo-server/app-controller/api/redis); Application & App-of-Apps; sync waves/hooks; self-heal & drift detection; private repos/secrets.
- [ ] Build: Argo CD `Application` (or App-of-Apps) pointing at the kustomize overlays.
- [ ] Diagrams: **Mermaid** GitOps reconcile loop git→Argo→cluster; **Mermaid** App-of-Apps tree.
- [ ] Citation: *Argo CD Up & Running* (primary).
- [ ] Validate: Argo CD Application manifests dry-run; referenced kustomize path exists.

### Task 6.5: `07-delivery/05-progressive-delivery.md`
- [ ] Coverage: automated canary/blue-green via Argo Rollouts (or Flagger); analysis templates using Prometheus metrics (success rate/latency) as gates; auto-rollback.
- [ ] Build: convert catalog Deployment → Argo Rollout with a metric-gated canary.
- [ ] Diagrams: **Mermaid** canary ramp w/ analysis gate; **ASCII** rollout steps.
- [ ] Citation: Rosso release ch.; Argo Rollouts docs.
- [ ] Validate: Rollout manifest dry-run; AnalysisTemplate references real metric from Task 5.1.

### Task 6.6: Phase 6 validation
- [ ] Validate 5 files + helm/kustomize/argocd trees: `helm lint`, `kubectl kustomize` all overlays, all dry-run; assert the chart/overlays produce the same logical app as the raw-manifests. Fix inline. TaskUpdate.

---

## Phase 7 — Part 08 Day-2 Operations (5 files)

### Task 7.1: `08-day-2-operations/01-cluster-lifecycle.md`
- [ ] Coverage: provisioning options (kubeadm vs managed EKS/GKE/AKS vs kind/k3d); cluster & node upgrades; version skew policy (apiserver/kubelet/kubectl); node pools & surge upgrades; API deprecation handling.
- [ ] Diagrams: **Mermaid** rolling control-plane→node upgrade order; **ASCII** version-skew window.
- [ ] Citation: Rosso cluster ch.; official upgrade docs. Validate.

### Task 7.2: `08-day-2-operations/02-backup-and-dr.md`
- [ ] Coverage: etcd snapshot save/restore; what etcd backup does/doesn't cover; Velero (cluster resources + PV snapshots, schedules, restore); stateful data DR (Postgres); RPO/RTO; a Bookstore DR runbook.
- [ ] Diagrams: **Mermaid** Velero backup/restore flow; **ASCII** RPO/RTO timeline.
- [ ] Bookstore increment: Velero schedule for the namespace + a documented restore drill.
- [ ] Citation: Rosso ops ch.; Velero docs. Validate.

### Task 7.3: `08-day-2-operations/03-troubleshooting-playbook.md`
- [ ] Coverage: systematic flow (describe→events→logs→exec→ephemeral debug); decision trees for Pending, CrashLoopBackOff, ImagePullBackOff, OOMKilled, Evicted, Service-no-endpoints, DNS failures, NetworkPolicy block, PVC unbound; `kubectl debug`; node NotReady.
- [ ] Diagrams: **Mermaid** master troubleshooting decision tree; **ASCII** per-symptom quick table.
- [ ] Bookstore increment: deliberately break the app (bad image/probe/missing secret) and walk each diagnosis.
- [ ] Citation: Lukša troubleshooting ch.; Rosso. Validate.

### Task 7.4: `08-day-2-operations/04-multi-tenancy-and-namespaces.md`
- [ ] Coverage: namespace design; ResourceQuota/LimitRange guardrails; RBAC tenancy; soft vs hard multi-tenancy; NetworkPolicy isolation; vCluster/hierarchical namespaces overview.
- [ ] Diagrams: **Mermaid** soft vs hard tenancy; **ASCII** namespace-per-team layout.
- [ ] Bookstore increment: dev/staging/prod namespace isolation with quotas + RBAC.
- [ ] Citation: Rosso multi-tenancy ch. Validate.

### Task 7.5: `08-day-2-operations/05-operators-and-crds.md`
- [ ] Coverage: extending the API — CRDs; the controller/operator pattern (reconcile, level-triggered) at a conceptual level; Operator maturity/Lifecycle Manager; build vs buy; using an existing operator (CloudNativePG) for Postgres.
- [ ] Diagrams: **Mermaid** CRD + custom controller reconcile loop; **ASCII** operator capability levels.
- [ ] Bookstore increment: replace the DIY Postgres StatefulSet with a CloudNativePG `Cluster` CR (show the upgrade path & tradeoffs).
- [ ] Citation: Ibryam "Operator/Controller"; Rosso platform ch. Validate.

### Task 7.6: Phase 7 validation
- [ ] Validate 5 files + manifests; ensure the CloudNativePG alternative is presented as an option without breaking the StatefulSet narrative. Fix inline. TaskUpdate.

---

## Phase 8 — Capstone, appendix, final consistency

### Task 8.1: `09-end-to-end-bookstore/01-bookstore-end-to-end.md`
- [ ] Coverage: a single end-to-end walkthrough starting from nothing: create kind cluster → install ingress/Prometheus/Argo CD → point Argo CD at the repo → app syncs (kustomize prod overlay) → verify observability, autoscaling (load test), security posture (PSA/NetworkPolicy/Kyverno) → run a metric-gated canary → perform a backup + restore drill → teardown. Pure orchestration of artifacts already created in earlier phases (no new app behavior). Include an architecture **Mermaid** diagram of the final system and a checklist mapping each production concern → the chapter that covers it.
- [ ] Validate: every command references an artifact that exists; full manifest set dry-runs; all links resolve.

### Task 8.2: Appendix completion
- [ ] `appendix/A-kubectl-cheatsheet.md`: imperative speed commands, `-o jsonpath`/custom-columns, debugging one-liners, context/namespace switching, dry-run/diff, common generators.
- [ ] `appendix/B-glossary.md`: expand the Phase 0 seed to cover every term introduced across all 50 chapters; each links to its chapter.
- [ ] `appendix/C-yaml-and-api-conventions.md`: YAML pitfalls (anchors, booleans, indentation, multi-doc), apiVersion/GVK & deprecation, `kubectl explain`, server-side apply & field management, labels/annotations conventions.
- [ ] `appendix/D-further-reading.md`: topic → book/chapter map across the user's library (from Task 0.2) + curated official-docs links per part.
- [ ] `appendix/E-learning-paths.md`: ordered paths — fast track (1 week), exam-oriented (CKA/CKAD/CKS mapping to chapters), platform/ops track.
- [ ] Validate: links resolve; D-map covers all 10 parts.

### Task 8.3: Global consistency pass
- [ ] Build a link graph of all `full-guide/**/*.md`; every relative link resolves (fix any dangling).
- [ ] Extract every fenced ```yaml full-manifest across the whole guide + `examples/**`; run `kubectl apply --dry-run=client`; the cumulative Bookstore manifest set (raw-manifests, helm render, kustomize prod) must each be internally consistent (labels/selectors/namespaces/Service↔Deployment names match).
- [ ] Every ```mermaid fence parses (header valid, balanced).
- [ ] README TOC links every chapter; every chapter has the full 9-section anatomy (grep for the required headings).
- [ ] `go vet ./...` + `docker build` for all four app images still pass.
- [ ] Fix all issues inline. Final TaskUpdate.

---

## Self-Review (performed by plan author before execution)

**1. Spec coverage:** Spec §6 lists 50 chapters + README + 5 appendix. Mapping: README→0.1; 7 foundations→1.1–1.7; 8 workloads→2.1–2.8; 6 networking→3.1–3.6; 5 config/storage→3.7–3.11; 3 scheduling→4.1–4.3; 4 security→4.4–4.7; 6 prod-readiness→5.1–5.6; 5 delivery→6.1–6.5; 5 day-2→7.1–7.5; capstone→8.1; appendix A–E→8.2; examples app→0.3, packaging trees→6.1/6.2/6.4. All 56 docs + examples tree covered. Spec §5 evolution narrative steps map to the Bookstore increments across 1.6→8.1. Spec §8 diagram inventory: each listed diagram is assigned to a specific task (architecture→1.3; API pipeline→1.4; reconcile→1.6; pod lifecycle→2.1; scheduling→4.1; kube-proxy/DNS→3.2/3.3; ingress/gateway→3.4/3.5; CNI→3.1; PV/PVC→3.10; RBAC chain→4.4; HPA loop→5.4; GitOps loop→6.4; evolving Bookstore→1.1 then per part, final in 8.1). Spec §9 book mapping → Task 0.2 + per-chapter citations. No gaps.

**2. Placeholder scan:** No "TBD/TODO/handle edge cases". Each chapter task states concrete coverage bullets, specific diagram types/subjects, the exact Bookstore manifest path/increment, citation target, and a concrete validation command. Content prose is generated at execution against the fixed chapter anatomy + these bullets — not deferred or vague.

**3. Type/name consistency:** Service/manifest names are fixed and reused: services `storefront/catalog/orders/payments-worker/postgres/redis/rabbitmq`; image tags `bookstore/<SVC>:dev` (Task 0.3) referenced identically in 1.2, 2.x, helm/kustomize; raw-manifest filenames are explicit and only ever added/extended, never renamed; helm chart at `examples/bookstore/helm/bookstore`, kustomize at `examples/bookstore/kustomize/{base,overlays/{dev,staging,prod}}`, argocd at `examples/bookstore/argocd` — same paths in 6.1/6.2/6.4/8.1. Validation method (`kubectl apply --dry-run=client` v1.35.4, `helm lint`, `kubectl kustomize`, `go vet`, `docker build`) is consistent throughout.

No issues found requiring structural change. Plan ready for execution.
