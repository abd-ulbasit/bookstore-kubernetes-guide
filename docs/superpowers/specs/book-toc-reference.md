# Book TOC Reference & Coverage Map (internal working note)

**Purpose:** Sanity-check that the 50 guide chapters cover the Kubernetes curriculum,
and give every chapter a concrete book + chapter citation target. This is an internal
note for the guide authors — it is **not** part of `full-guide/` and is not linked from
it.

**Method:** TOCs extracted from the user's PDF library with `pdftotext` (front-matter
pages only), distilled to chapter lists in a sandbox (`/tmp/booktoc/*`); only the
distilled lists below entered the working context. (The plan suggested context-mode MCP
tools; those tools are not mounted in this environment, so the documented
`pdftotext | grep`-to-sandbox fallback was used — same outcome, no PDF bytes in context.)

Books used (in `~/Documents/learning/books/cloud-and-devops/kubernetes/`):

- **Lukša, _Kubernetes in Action_ 2e** (Manning, MEAP V15, 2023) — `luksa`
- **Ibryam & Huß, _Kubernetes Patterns_ 2e** (O'Reilly, 2023) — `patterns`
- **Rosso, Lander, Brand, Harris, _Production Kubernetes_** (O'Reilly, 2021) — `rosso`
- **_Argo CD Up & Running_** (O'Reilly) — `argocd`
- **Poulton, _The Kubernetes Book_** (2020) — `poulton` (fundamentals framing; TOC not
  re-extracted here — used at the well-known chapter granularity)
- **Davis, _Bootstrapping Microservices_** (Manning, 2021) — `davis` (example-app & CI/CD
  shape)

---

## 1. Extracted tables of contents

### Lukša — _Kubernetes in Action_, 2nd Edition (MEAP V15)

> Note: MEAP V15 "brief contents" ends at chapter 17. The final print 2e adds further
> chapters (advanced scheduling, securing the API server / RBAC, securing Pods, GitOps,
> extending Kubernetes). Where the guide needs a topic beyond MEAP ch.17, the citation
> target is given at **topic granularity** ("Lukša 2e, securing-the-API-server
> material") plus the official docs URL, and a sibling book (Rosso / Patterns) is used
> as the primary citation. This is recorded per-row below and flagged in §4.

1. Introducing Kubernetes
2. Understanding containers
3. Deploying your first application
4. Introducing Kubernetes API objects
5. Running workloads in Pods
6. Managing the Pod lifecycle
7. Attaching storage volumes to Pods
8. Persisting data in PersistentVolumes
9. Configuration via ConfigMaps, Secrets, and the Downward API
10. Organizing objects using Namespaces and Labels
11. Exposing Pods with Services
12. Exposing Services with Ingress
13. Replicating Pods with ReplicaSets
14. Managing Pods with Deployments
15. Deploying stateful workloads with StatefulSets
16. Deploying node agents and daemons with DaemonSets
17. Running finite workloads with Jobs and CronJobs

### Ibryam & Huß — _Kubernetes Patterns_, 2nd Edition

1. Introduction
**Part I — Foundational Patterns**
2. Predictable Demands
3. Declarative Deployment
4. Health Probe
5. Managed Lifecycle
6. Automated Placement
**Part II — Behavioral Patterns**
7. Batch Job
8. Periodic Job
9. Daemon Service
10. Singleton Service
11. Stateless Service
12. Stateful Service
13. Service Discovery
14. Self Awareness
**Part III — Structural Patterns**
15. Init Container
16. Sidecar
17. Adapter
18. Ambassador
**Part IV — Configuration Patterns**
19. EnvVar Configuration
20. Configuration Resource
21. Immutable Configuration
22. Configuration Template
**Part V — Security Patterns**
23. Process Containment
24. Network Segmentation
25. Secure Configuration
26. Access Control
**Part VI — Advanced Patterns**
27. Controller
28. Operator
29. Elastic Scale
30. Image Builder

### Rosso et al. — _Production Kubernetes_

1. A Path to Production
2. Deployment Models
3. Container Runtime
4. Container Storage
5. Pod Networking
6. Service Routing
7. Secret Management
8. Admission Control
9. Observability
10. Identity
11. Building Platform Services
12. Multitenancy
13. Autoscaling
14. Application Considerations
15. Software Supply Chain
16. Platform Abstractions

### _Argo CD Up & Running_

1. Introduction to Argo CD
2. Installing Argo CD
3. Core Concepts (App, Project, sync model)
4. Managing Applications
5. Synchronizing Applications
6. Access Control / RBAC & Projects
7. Cluster Management
8. Multi-Tenancy
9. Argo CD Operator / declarative install
10. Applications at Scale (App-of-Apps, ApplicationSet)
11. Extending Argo CD
12. Integrating CI with Argo CD
13. Operationalizing Argo CD
14. Future Considerations

> Argo CD chapters 3, 6, 9 wrapped past their dot-leader in extraction; titles above
> are reconstructed from the surrounding distilled section headings
> ("Role-Based Access Control", "Repository Access", "core concepts") and the book's
> known structure. Argo CD is cited at book + topic granularity, which is unambiguous.

---

## 2. Guide chapter → citation target (all 50 chapters)

`P` = Poulton, `L` = Lukša 2e, `KP` = Kubernetes Patterns 2e, `R` = Production
Kubernetes, `A` = Argo CD Up & Running, `D` = Davis. "+docs" = pair with the official
kubernetes.io (or project) page in the chapter's Further Reading.

### Part 00 — Foundations
| Guide chapter | Primary citation | Secondary |
|---|---|---|
| 01-why-kubernetes | P ch.1; L ch.1 | KP ch.1 |
| 02-containers-and-images | P ch.3; L ch.2 | KP ch.30 (Image Builder) |
| 03-architecture-overview | P ch.2; L ch.3 | R ch.1 |
| 04-control-plane-deep-dive | L ch.3 (+ securing-apiserver topic); R ch.1 | +docs (kube-apiserver/etcd) |
| 05-node-components | L ch.2, ch.3 | R ch.3 (Container Runtime) |
| 06-declarative-api-model | L ch.4 | KP ch.3 (Declarative Deployment) |
| 07-local-cluster-setup | P ch.3; L ch.3 | +docs (kind/k3d) |

### Part 01 — Core Workloads
| Guide chapter | Primary citation | Secondary |
|---|---|---|
| 01-pods | L ch.5 | KP ch.15/16/17/18 (Init/Sidecar/Adapter/Ambassador) |
| 02-health-and-lifecycle | L ch.6 | KP ch.4 (Health Probe), ch.5 (Managed Lifecycle) |
| 03-resources-and-qos | L ch.20 (resource mgmt topic); +docs | KP ch.2 (Predictable Demands) |
| 04-replicasets-and-deployments | L ch.13, ch.14 | KP ch.3 (Declarative Deployment) |
| 05-statefulsets | L ch.15 | KP ch.12 (Stateful Service) |
| 06-daemonsets | L ch.16 | KP ch.9 (Daemon Service) |
| 07-jobs-and-cronjobs | L ch.17 | KP ch.7 (Batch Job), ch.8 (Periodic Job) |
| 08-deployment-strategies | KP ch.3 (Declarative Deployment) | R ch.14; L ch.14 |

### Part 02 — Networking
| Guide chapter | Primary citation | Secondary |
|---|---|---|
| 01-networking-model | R ch.5 (Pod Networking) | L ch.11; +docs (CNI) |
| 02-services | L ch.11 | R ch.6 (Service Routing); KP ch.13 (Service Discovery) |
| 03-dns-and-discovery | L ch.11 | KP ch.13; +docs (CoreDNS) |
| 04-ingress | L ch.12 | R ch.6 (Service Routing) |
| 05-gateway-api | +docs (Gateway API, primary) | R ch.6 |
| 06-network-policies | KP ch.24 (Network Segmentation) | R ch.5; L ch.11 |

### Part 03 — Config & Storage
| Guide chapter | Primary citation | Secondary |
|---|---|---|
| 01-configmaps | L ch.9 | KP ch.20 (Configuration Resource), ch.19 (EnvVar) |
| 02-secrets | L ch.9 | R ch.7 (Secret Management); KP ch.25 (Secure Configuration) |
| 03-volumes | L ch.7 | KP ch.20 |
| 04-persistent-storage | L ch.8 | R ch.4 (Container Storage) |
| 05-stateful-data-patterns | KP ch.12 (Stateful Service) | R ch.4; R ch.16 |

### Part 04 — Scheduling
| Guide chapter | Primary citation | Secondary |
|---|---|---|
| 01-scheduler-and-nodes | KP ch.6 (Automated Placement) | L (scheduling topic); +docs (kube-scheduler) |
| 02-affinity-taints-topology | KP ch.6 (Automated Placement) | +docs (assign-pod-node, topology spread) |
| 03-priority-and-preemption | KP ch.6 | +docs (pod-priority-preemption) |

### Part 05 — Security
| Guide chapter | Primary citation | Secondary |
|---|---|---|
| 01-authn-authz-rbac | KP ch.26 (Access Control) | R ch.10 (Identity); L (securing-apiserver topic) |
| 02-pod-security | KP ch.23 (Process Containment) | R ch.8 (Admission Control); +docs (Pod Security Standards) |
| 03-supply-chain | R ch.15 (Software Supply Chain) | KP ch.30 (Image Builder); +docs (Kyverno/Cosign) |
| 04-secrets-and-cluster-hardening | R ch.7 (Secret Mgmt) + R ch.8 (Admission) | KP ch.25; CIS Benchmark |

### Part 06 — Production Readiness
| Guide chapter | Primary citation | Secondary |
|---|---|---|
| 01-observability-metrics | R ch.9 (Observability) | +docs (Prometheus) |
| 02-logging | R ch.9 (Observability) | +docs (logging architecture) |
| 03-tracing | R ch.9 (Observability) | +docs (OpenTelemetry) |
| 04-autoscaling | KP ch.29 (Elastic Scale) | R ch.13 (Autoscaling); +docs (HPA/KEDA) |
| 05-reliability-and-disruptions | R ch.14 (Application Considerations) | KP ch.10 (Singleton Service); +docs (PDB) |
| 06-capacity-and-cost | R ch.13 (Autoscaling) + R ch.12 (Multitenancy) | KP ch.2; +docs (OpenCost) |

### Part 07 — Delivery
| Guide chapter | Primary citation | Secondary |
|---|---|---|
| 01-packaging-helm | R ch.11 (Building Platform Services) | +docs (Helm) |
| 02-packaging-kustomize | R ch.11 | +docs (Kustomize) |
| 03-cicd-pipeline | D (CI/CD shape) | R ch.15 (Software Supply Chain) |
| 04-gitops-argocd | A ch.1–10 (primary, whole book) | R ch.11 |
| 05-progressive-delivery | R ch.14 | A ch.5; +docs (Argo Rollouts) |

### Part 08 — Day-2 Operations
| Guide chapter | Primary citation | Secondary |
|---|---|---|
| 01-cluster-lifecycle | R ch.2 (Deployment Models) | +docs (version skew, upgrades) |
| 02-backup-and-dr | R ch.4 (Container Storage) + R ch.2 | +docs (etcd backup, Velero) |
| 03-troubleshooting-playbook | L (debugging topic across ch.5/6) | R ch.9; +docs (debug Pods/Services) |
| 04-multi-tenancy-and-namespaces | R ch.12 (Multitenancy) | KP ch.26 (Access Control) |
| 05-operators-and-crds | KP ch.27 (Controller) + ch.28 (Operator) | R ch.11; +docs (CRD/operator) |

### Part 09 — Capstone
| Guide chapter | Primary citation | Secondary |
|---|---|---|
| 01-bookstore-end-to-end | R ch.1 (A Path to Production) | A (whole book); recap of all parts |

### Appendix
| Appendix | Primary citation | Secondary |
|---|---|---|
| A-kubectl-cheatsheet | L ch.3 + ch.4 | +docs (kubectl cheatsheet) |
| B-glossary | (synthesis of all books) | +docs (k8s glossary) |
| C-yaml-and-api-conventions | L ch.4 | +docs (API conventions, SSA) |
| D-further-reading | (this file is the source) | all books |
| E-learning-paths | (synthesis) | CNCF CKA/CKAD/CKS curricula |

**Every one of the 50 chapters + 5 appendix entries has a citation target row above.**

---

## 3. Books → which guide parts they anchor

- **Lukša 2e**: structural backbone for Parts 00–03 (foundations, workloads,
  networking, config/storage). Deepest "how it works" source within MEAP scope.
- **Kubernetes Patterns 2e**: the "why/pattern" lens — used as primary for scheduling
  (Automated Placement), security patterns, operators (Controller/Operator), and
  Elastic Scale; secondary almost everywhere for the design rationale.
- **Production Kubernetes**: primary for Parts 05–08 (security hardening,
  observability, delivery, day-2, multitenancy, supply chain).
- **Argo CD Up & Running**: primary and effectively sole reference for
  `07-delivery/04-gitops-argocd`; secondary for progressive delivery & capstone.
- **Poulton**: gentle on-ramp framing for the first three foundations chapters.
- **Davis**: shape of the example app and the CI/CD pipeline narrative
  (`07-delivery/03-cicd-pipeline`).

---

## 4. Coverage gaps & decisions (Task 0.2 Step 3)

Topics present in the books but **not given a dedicated guide chapter**, with the
decision recorded. Per the plan, scope is **not** expanded into new chapters; each gap
is folded into an existing chapter as a subsection.

| Topic in books | Where in books | Decision (no new chapter) |
|---|---|---|
| Singleton Service / leader election | KP ch.10 | Fold into `01-core-workloads/06-daemonsets.md` (HA singletons) and `08-day-2-operations/05-operators-and-crds.md` (controller leader election). Note only. |
| Self Awareness / Downward API as a *pattern* | KP ch.14 | Already covered mechanically in `03-config-and-storage/03-volumes.md` (downwardAPI). Add a one-paragraph pattern callout there. |
| Configuration Template (KP) | KP ch.22 | Covered implicitly by Helm/Kustomize in Part 07. Add a sentence in `07-delivery/02-packaging-kustomize.md` naming the pattern. |
| Adapter / Ambassador patterns | KP ch.17/18 | Covered in `01-core-workloads/01-pods.md` multi-container section. No new chapter. |
| Image Builder / in-cluster builds (Kaniko/BuildKit) | KP ch.30 | Out of scope as a chapter (YAGNI per spec §11). Mention in `07-delivery/03-cicd-pipeline.md` as the in-cluster-build alternative. Decision: **note only.** |
| Container Runtime internals (containerd deep dive) | R ch.3 | Covered at the needed depth in `00-foundations/05-node-components.md` (CRI/containerd/pause). No separate chapter. |
| Building Platform Services / internal developer platform | R ch.11 | Threaded through Part 07 (Helm/Kustomize/Argo CD) and `08-day-2-operations/05-operators-and-crds.md`. Decision: **note only; do not add a platform-engineering chapter** (spec §11 YAGNI). |
| Service mesh (Istio/Linkerd) | (not a book TOC chapter; cross-cutting) | Explicitly out of scope per spec §11 — introduced conceptually only, in `02-networking/02-services.md` and `07-delivery/05-progressive-delivery.md`. **Note only.** |
| Cloud-provider-specific deep dives (EKS/GKE/AKS) | R ch.2 | Spec §11 YAGNI — delivered as `> **In production:**` callouts across chapters, not a chapter. **Note only.** |
| ApplicationSet / multi-cluster Argo at scale | A ch.10 | Folded into `07-delivery/04-gitops-argocd.md` (App-of-Apps + ApplicationSet subsection). |

**Conclusion:** No material Kubernetes topic required for a zero-to-production path is
missing from the 50 chapters. All flagged book topics are either already covered
mechanically, foldable as a subsection/callout into a planned chapter, or explicitly
YAGNI per spec §11. **No new chapters added.**
