# Appendix D — Further reading

> A topic → resource map: for each Part of this guide, the most relevant
> chapter(s) from the reference library plus 1–3 curated official-docs links.
> The book→chapter mapping mirrors the guide's internal citation map exactly;
> nothing here is invented. This guide is **standalone** — these are for going
> *deeper* on what a chapter already taught, not prerequisites.

This is a reference (no nine-section anatomy). Each chapter of the guide also
ends with its own specific citation + official URL; this appendix is the
consolidated, by-Part view.

## The library

Only these six books are cited anywhere in the guide:

| Short | Book |
|---|---|
| **L** | Lukša, *Kubernetes in Action*, 2nd Edition (Manning) |
| **P** | Poulton, *The Kubernetes Book* |
| **KP** | Ibryam & Huß, *Kubernetes Patterns*, 2nd Edition (O'Reilly) |
| **R** | Rosso, Lander, Brand & Harris, *Production Kubernetes* (O'Reilly) |
| **A** | *Argo CD Up & Running* (O'Reilly) |
| **D** | Davis, *Bootstrapping Microservices* (Manning) |

> A note on Lukša 2e: the MEAP "brief contents" ends at ch.17. Where the guide
> needs material beyond that (securing the API server / RBAC, securing Pods,
> GitOps, extending Kubernetes), the citation is at **topic granularity**
> ("Lukša 2e, securing-the-API-server material") and a sibling book
> (*Production Kubernetes* / *Kubernetes Patterns*) is the primary — exactly as
> recorded below.

---

## Part 00 — Foundations

Why Kubernetes, containers/images, architecture, control plane, node
components, the declarative API model, local cluster setup.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — Why Kubernetes](../00-foundations/01-why-kubernetes.md) | P ch.1; L ch.1 | KP ch.1 (Introduction) |
| [02 — Containers and images](../00-foundations/02-containers-and-images.md) | P ch.3; L ch.2 (Understanding containers) | KP ch.30 (Image Builder) |
| [03 — Architecture overview](../00-foundations/03-architecture-overview.md) | P ch.2; L ch.3 (Deploying your first application) | R ch.1 (A Path to Production) |
| [04 — Control plane deep dive](../00-foundations/04-control-plane-deep-dive.md) | L ch.3 + securing-the-API-server material; R ch.1 | official docs (below) |
| [05 — Node components](../00-foundations/05-node-components.md) | L ch.2, ch.3 | R ch.3 (Container Runtime) |
| [06 — The declarative API model](../00-foundations/06-declarative-api-model.md) | L ch.4 (Introducing Kubernetes API objects) | KP ch.3 (Declarative Deployment) |
| [07 — Local cluster setup](../00-foundations/07-local-cluster-setup.md) | P ch.3; L ch.3 | official docs (below) |

Official docs:
- Kubernetes components & architecture — <https://kubernetes.io/docs/concepts/overview/components/>
- Working with objects (spec/status, labels, selectors) — <https://kubernetes.io/docs/concepts/overview/working-with-objects/>
- Install tools; kind <https://kind.sigs.k8s.io/docs/user/quick-start/>, k3d <https://k3d.io/>, kubectl <https://kubernetes.io/docs/tasks/tools/>

---

## Part 01 — Core Workloads

Pods, health/lifecycle, resources/QoS, ReplicaSets/Deployments, StatefulSets,
DaemonSets, Jobs/CronJobs, deployment strategies.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — Pods](../01-core-workloads/01-pods.md) | L ch.5 (Running workloads in Pods) | KP ch.15/16/17/18 (Init/Sidecar/Adapter/Ambassador) |
| [02 — Health and lifecycle](../01-core-workloads/02-health-and-lifecycle.md) | L ch.6 (Managing the Pod lifecycle) | KP ch.4 (Health Probe), ch.5 (Managed Lifecycle) |
| [03 — Resources and QoS](../01-core-workloads/03-resources-and-qos.md) | L (resource-management material); official docs | KP ch.2 (Predictable Demands) |
| [04 — ReplicaSets and Deployments](../01-core-workloads/04-replicasets-and-deployments.md) | L ch.13 (ReplicaSets), ch.14 (Deployments) | KP ch.3 (Declarative Deployment) |
| [05 — StatefulSets](../01-core-workloads/05-statefulsets.md) | L ch.15 (Deploying stateful workloads with StatefulSets) | KP ch.12 (Stateful Service) |
| [06 — DaemonSets](../01-core-workloads/06-daemonsets.md) | L ch.16 (Deploying node agents and daemons with DaemonSets) | KP ch.9 (Daemon Service) |
| [07 — Jobs and CronJobs](../01-core-workloads/07-jobs-and-cronjobs.md) | L ch.17 (Running finite workloads with Jobs and CronJobs) | KP ch.7 (Batch Job), ch.8 (Periodic Job) |
| [08 — Deployment strategies](../01-core-workloads/08-deployment-strategies.md) | KP ch.3 (Declarative Deployment) | R ch.14 (Application Considerations); L ch.14 |

Official docs:
- Workloads overview — <https://kubernetes.io/docs/concepts/workloads/>
- Configure liveness/readiness/startup probes — <https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/>
- Resource management for Pods/Containers — <https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/>

---

## Part 02 — Networking

The networking model, Services, DNS/discovery, Ingress, Gateway API, network
policies.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — The networking model](../02-networking/01-networking-model.md) | R ch.5 (Pod Networking) | L ch.11; official docs (CNI) |
| [02 — Services](../02-networking/02-services.md) | L ch.11 (Exposing Pods with Services) | R ch.6 (Service Routing); KP ch.13 (Service Discovery) |
| [03 — DNS and service discovery](../02-networking/03-dns-and-discovery.md) | L ch.11 | KP ch.13 (Service Discovery); official docs (CoreDNS) |
| [04 — Ingress](../02-networking/04-ingress.md) | L ch.12 (Exposing Services with Ingress) | R ch.6 (Service Routing) |
| [05 — Gateway API](../02-networking/05-gateway-api.md) | official docs (Gateway API — primary) | R ch.6 (Service Routing) |
| [06 — Network policies](../02-networking/06-network-policies.md) | KP ch.24 (Network Segmentation) | R ch.5 (Pod Networking); L ch.11 |

Official docs:
- Services, Ingress & networking — <https://kubernetes.io/docs/concepts/services-networking/>
- Gateway API — <https://gateway-api.sigs.k8s.io/>
- Network Policies — <https://kubernetes.io/docs/concepts/services-networking/network-policies/>

---

## Part 03 — Config and Storage

ConfigMaps, Secrets, volumes, persistent storage, stateful data patterns.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — ConfigMaps](../03-config-and-storage/01-configmaps.md) | L ch.9 (Configuration via ConfigMaps, Secrets, and the Downward API) | KP ch.20 (Configuration Resource), ch.19 (EnvVar Configuration) |
| [02 — Secrets](../03-config-and-storage/02-secrets.md) | L ch.9 | R ch.7 (Secret Management); KP ch.25 (Secure Configuration) |
| [03 — Volumes](../03-config-and-storage/03-volumes.md) | L ch.7 (Attaching storage volumes to Pods) | KP ch.20 (Configuration Resource) |
| [04 — Persistent storage](../03-config-and-storage/04-persistent-storage.md) | L ch.8 (Persisting data in PersistentVolumes) | R ch.4 (Container Storage) |
| [05 — Stateful data patterns](../03-config-and-storage/05-stateful-data-patterns.md) | KP ch.12 (Stateful Service) | R ch.4 (Container Storage); R ch.16 (Platform Abstractions) |

Official docs:
- ConfigMaps — <https://kubernetes.io/docs/concepts/configuration/configmap/> · Secrets — <https://kubernetes.io/docs/concepts/configuration/secret/>
- Storage (volumes, PV/PVC, StorageClass, CSI) — <https://kubernetes.io/docs/concepts/storage/>
- Volume snapshots — <https://kubernetes.io/docs/concepts/storage/volume-snapshots/>

---

## Part 04 — Scheduling

The scheduler & nodes, affinity/taints/topology, priority & preemption.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — The scheduler and nodes](../04-scheduling/01-scheduler-and-nodes.md) | KP ch.6 (Automated Placement) | L (scheduling material); official docs (kube-scheduler) |
| [02 — Affinity, taints, topology](../04-scheduling/02-affinity-taints-topology.md) | KP ch.6 (Automated Placement) | official docs (assign Pods to nodes, topology spread) |
| [03 — Priority and preemption](../04-scheduling/03-priority-and-preemption.md) | KP ch.6 (Automated Placement) | official docs (Pod priority & preemption) |

Official docs:
- Scheduling, preemption & eviction — <https://kubernetes.io/docs/concepts/scheduling-eviction/>
- Assigning Pods to nodes (affinity, taints/tolerations, topology spread) — <https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/>
- Pod priority & preemption — <https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/>

---

## Part 05 — Security

AuthN/AuthZ/RBAC, pod security, supply chain, secrets & cluster hardening.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — Authn, authz, RBAC](../05-security/01-authn-authz-rbac.md) | KP ch.26 (Access Control) | R ch.10 (Identity); L securing-the-API-server material |
| [02 — Pod security](../05-security/02-pod-security.md) | KP ch.23 (Process Containment) | R ch.8 (Admission Control); official docs (Pod Security Standards) |
| [03 — Supply chain](../05-security/03-supply-chain.md) | R ch.15 (Software Supply Chain) | KP ch.30 (Image Builder); official docs (Kyverno/Cosign) |
| [04 — Secrets and cluster hardening](../05-security/04-secrets-and-cluster-hardening.md) | R ch.7 (Secret Management) + R ch.8 (Admission Control) | KP ch.25 (Secure Configuration); CIS Kubernetes Benchmark |

Official docs:
- Authentication & authorization (RBAC) — <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>
- Pod Security Standards & Admission — <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- Cloud Native security & supply chain — <https://kubernetes.io/docs/concepts/security/> · Sigstore/Cosign <https://docs.sigstore.dev/> · Kyverno <https://kyverno.io/docs/>

---

## Part 06 — Production Readiness

Metrics, logging, tracing, autoscaling, reliability & disruptions, capacity &
cost.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — Observability: metrics](../06-production-readiness/01-observability-metrics.md) | R ch.9 (Observability) | official docs (Prometheus) |
| [02 — Logging](../06-production-readiness/02-logging.md) | R ch.9 (Observability) | official docs (logging architecture) |
| [03 — Tracing](../06-production-readiness/03-tracing.md) | R ch.9 (Observability) | official docs (OpenTelemetry) |
| [04 — Autoscaling](../06-production-readiness/04-autoscaling.md) | KP ch.29 (Elastic Scale) | R ch.13 (Autoscaling); official docs (HPA/KEDA) |
| [05 — Reliability and disruptions](../06-production-readiness/05-reliability-and-disruptions.md) | R ch.14 (Application Considerations) | KP ch.10 (Singleton Service); official docs (PDB) |
| [06 — Capacity and cost](../06-production-readiness/06-capacity-and-cost.md) | R ch.13 (Autoscaling) + R ch.12 (Multitenancy) | KP ch.2 (Predictable Demands); OpenCost docs |

Official docs:
- Metrics & the metrics-server — <https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/> · Prometheus <https://prometheus.io/docs/> · OpenTelemetry <https://opentelemetry.io/docs/>
- Logging architecture — <https://kubernetes.io/docs/concepts/cluster-administration/logging/>
- HPA — <https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/> · PodDisruptionBudget — <https://kubernetes.io/docs/concepts/workloads/pods/disruptions/> · KEDA <https://keda.sh/docs/>

---

## Part 07 — Delivery

Helm, Kustomize, CI/CD, GitOps with Argo CD, progressive delivery.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — Packaging with Helm](../07-delivery/01-packaging-helm.md) | R ch.11 (Building Platform Services) | official docs (Helm) |
| [02 — Packaging with Kustomize](../07-delivery/02-packaging-kustomize.md) | R ch.11 (Building Platform Services) | official docs (Kustomize) |
| [03 — CI/CD pipeline](../07-delivery/03-cicd-pipeline.md) | D (CI/CD pipeline shape) | R ch.15 (Software Supply Chain) |
| [04 — GitOps with Argo CD](../07-delivery/04-gitops-argocd.md) | A ch.1–10 (the whole book — primary) | R ch.11 (Building Platform Services) |
| [05 — Progressive delivery](../07-delivery/05-progressive-delivery.md) | R ch.14 (Application Considerations) | A ch.5 (Synchronizing Applications); official docs (Argo Rollouts) |

> *Argo CD Up & Running* chapter anchors: ch.1 Introduction · ch.2 Installing ·
> ch.3 Core Concepts (App/Project/sync) · ch.4 Managing Applications · ch.5
> Synchronizing Applications · ch.6 Access Control/RBAC & Projects · ch.9
> declarative install · ch.10 Applications at Scale (App-of-Apps,
> ApplicationSet) · ch.12 Integrating CI · ch.13 Operationalizing. The guide
> cites Argo CD at book + topic granularity, which is unambiguous.

Official docs:
- Helm — <https://helm.sh/docs/> (charts, hooks, best practices)
- Kustomize — <https://kubectl.docs.kubernetes.io/references/kustomize/> · <https://kustomize.io>
- Argo CD — <https://argo-cd.readthedocs.io/> · Argo Rollouts — <https://argo-rollouts.readthedocs.io/>

---

## Part 08 — Day-2 Operations

Cluster lifecycle, backup & DR, troubleshooting, multi-tenancy, operators &
CRDs.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — Cluster lifecycle](../08-day-2-operations/01-cluster-lifecycle.md) | R ch.2 (Deployment Models) | official docs (version skew, upgrades) |
| [02 — Backup and DR](../08-day-2-operations/02-backup-and-dr.md) | R ch.4 (Container Storage) + R ch.2 (Deployment Models) | official docs (etcd backup, Velero) |
| [03 — Troubleshooting playbook](../08-day-2-operations/03-troubleshooting-playbook.md) | **R ch.9 (Observability)** — co-primary, the operations/method perspective the chapter actually uses (observe→isolate→hypothesize→test→fix; alert→runbook) — with L (debugging material across ch.5/6/11) for Pod-status/Events/probes mechanics | official docs (debug Pods/Services) |
| [04 — Multi-tenancy and namespaces](../08-day-2-operations/04-multi-tenancy-and-namespaces.md) | R ch.12 (Multitenancy) | KP ch.26 (Access Control) |
| [05 — Operators and CRDs](../08-day-2-operations/05-operators-and-crds.md) | KP ch.27 (Controller) + ch.28 (Operator) | R ch.11 (Building Platform Services); official docs (CRD/operator) |

Official docs:
- Cluster administration & upgrades, version skew — <https://kubernetes.io/docs/setup/release/version-skew-policy/>
- Backing up etcd — <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/> · Velero <https://velero.io/docs/>
- Debug running Pods (ephemeral containers / `kubectl debug`) — <https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/>
- Extend Kubernetes / CRDs & operators — <https://kubernetes.io/docs/concepts/extend-kubernetes/>

---

## Part 09 — Capstone

The whole system, end to end.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — Bookstore end-to-end](../09-end-to-end-bookstore/01-bookstore-end-to-end.md) | R ch.1 (A Path to Production) | A (whole book); a recap of all parts |

Official docs:
- Production environment checklist — <https://kubernetes.io/docs/setup/production-environment/>
- Configuration & cluster-administration best practices — <https://kubernetes.io/docs/concepts/configuration/overview/>

---

## Part 10 — Cloud & Managed Kubernetes

The shared-responsibility model, IaC for managed clusters, cloud identity for
workloads, cloud CNI / load balancing / storage, and node autoscaling /
cost / multi-cloud.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — The managed Kubernetes model](../10-cloud-and-managed-kubernetes/01-managed-kubernetes-model.md) | R ch.2 (Deployment Models) | KP ch.1; provider docs (below) |
| [02 — Provisioning and IaC](../10-cloud-and-managed-kubernetes/02-provisioning-and-iac.md) | R ch.2 (Deployment Models) | provider CLI docs; Terraform docs |
| [03 — Cloud identity for workloads](../10-cloud-and-managed-kubernetes/03-cloud-identity.md) | R ch.10 (Identity) | KP ch.26 (Access Control); provider pod-identity docs |
| [04 — Cloud networking and load balancing](../10-cloud-and-managed-kubernetes/04-cloud-networking-and-load-balancing.md) | R ch.5 (Pod Networking) + R ch.6 (Service Routing) | provider CNI docs; Cilium docs |
| [05 — Cloud storage and data](../10-cloud-and-managed-kubernetes/05-cloud-storage-and-data.md) | R ch.4 (Container Storage) | provider CSI docs |
| [06 — Node autoscaling, cost & multi-cloud](../10-cloud-and-managed-kubernetes/06-node-autoscaling-cost-multicloud.md) | R ch.13 (Autoscaling) + R ch.2 (Deployment Models) | KP ch.29 (Elastic Scale); Karpenter docs; OpenCost docs |

Official docs:
- EKS — <https://docs.aws.amazon.com/eks/> · GKE — <https://cloud.google.com/kubernetes-engine/docs> · AKS — <https://learn.microsoft.com/azure/aks/>
- IRSA — <https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html> · EKS Pod Identity — <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html> · GKE Workload Identity — <https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity> · Azure AD Workload Identity — <https://azure.github.io/azure-workload-identity/docs/>
- AWS VPC CNI — <https://github.com/aws/amazon-vpc-cni-k8s> · AWS Load Balancer Controller — <https://kubernetes-sigs.github.io/aws-load-balancer-controller/> · GKE Dataplane V2 — <https://cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2> · Azure CNI Overlay — <https://learn.microsoft.com/azure/aks/azure-cni-overlay>
- EBS CSI — <https://github.com/kubernetes-sigs/aws-ebs-csi-driver> · GCE PD CSI — <https://github.com/kubernetes-sigs/gcp-compute-persistent-disk-csi-driver> · Azure Disk CSI — <https://github.com/kubernetes-sigs/azuredisk-csi-driver>
- Karpenter — <https://karpenter.sh/docs/> · Cluster Autoscaler — <https://kubernetes.io/docs/concepts/cluster-administration/cluster-autoscaling/> · OpenCost — <https://www.opencost.io/docs/>
- Terraform — <https://developer.hashicorp.com/terraform/docs> · `eksctl` — <https://eksctl.io/> · Crossplane — <https://docs.crossplane.io/>

Standout articles:
- Karpenter consolidation deep-dive — <https://aws.amazon.com/blogs/containers/optimizing-your-kubernetes-compute-costs-with-karpenter-consolidation/>
- "Kubernetes Networking on AWS" (the canonical VPC-CNI / IP-density walkthrough) — <https://aws.amazon.com/blogs/containers/amazon-vpc-cni-increases-pods-per-node-limits/>
- Pod-identity for the three clouds, compared — <https://kubernetes.io/blog/2022/12/22/pod-security-admission-stable/> (PSA context) + the provider docs above.

---

## Part 11 — Advanced Production Patterns

Admission webhooks, operator development (build, not consume), APF, service
mesh, secrets at scale, multi-cluster fleets, chaos engineering, HA control
plane / etcd ops, performance & scalability, and platform engineering.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — Admission webhooks](../11-advanced-production-patterns/01-admission-webhooks.md) | R ch.8 (Admission Control) | KP ch.25 (Secure Configuration); official docs (webhooks, VAP) |
| [02 — Operator development](../11-advanced-production-patterns/02-operator-development.md) | KP ch.27 (Controller) + KP ch.28 (Operator) | R ch.11 (Building Platform Services); Kubebuilder Book |
| [03 — API Priority and Fairness](../11-advanced-production-patterns/03-api-priority-and-fairness.md) | official docs (APF) | R ch.1 (Path to Production) (control-plane context) |
| [04 — Service mesh](../11-advanced-production-patterns/04-service-mesh.md) | R ch.6 (Service Routing) + R ch.10 (Identity) | KP ch.13 (Service Discovery); Istio / Linkerd / SPIFFE docs |
| [05 — Secrets at scale](../11-advanced-production-patterns/05-secrets-at-scale.md) | R ch.7 (Secret Management) | KP ch.25 (Secure Configuration); ESO + Vault docs |
| [06 — Multi-cluster and fleet](../11-advanced-production-patterns/06-multi-cluster-and-fleet.md) | R ch.2 (Deployment Models) + R ch.12 (Multitenancy) | A ch.10 (Applications at Scale: App-of-Apps, ApplicationSet) |
| [07 — Chaos engineering](../11-advanced-production-patterns/07-chaos-engineering.md) | R ch.14 (Application Considerations) | KP ch.10 (Singleton Service); Chaos Mesh docs |
| [08 — HA control plane and etcd](../11-advanced-production-patterns/08-ha-control-plane-and-etcd.md) | R ch.2 (Deployment Models) | official docs (etcd, kubeadm HA) |
| [09 — Performance and scalability](../11-advanced-production-patterns/09-performance-and-scalability.md) | R ch.9 (Observability) | KP ch.6 (Automated Placement); Cilium / kube-proxy docs |
| [10 — Platform engineering](../11-advanced-production-patterns/10-platform-engineering.md) | R ch.11 (Building Platform Services) | KP ch.28 (Operator); Crossplane / Backstage docs |

Official docs:
- Admission control — <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/> · Dynamic admission webhooks — <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/> · ValidatingAdmissionPolicy — <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/>
- Kubebuilder Book — <https://book.kubebuilder.io/> · controller-runtime — <https://pkg.go.dev/sigs.k8s.io/controller-runtime> · Operator SDK — <https://sdk.operatorframework.io/docs/>
- API Priority and Fairness — <https://kubernetes.io/docs/concepts/cluster-administration/flow-control/>
- Istio — <https://istio.io/latest/docs/> · Istio Ambient — <https://istio.io/latest/docs/ambient/> · Linkerd — <https://linkerd.io/2/overview/> · SPIFFE/SPIRE — <https://spiffe.io/docs/>
- External Secrets Operator — <https://external-secrets.io/latest/> · Vault on Kubernetes — <https://developer.hashicorp.com/vault/docs/platform/k8s> · CSI Secrets Store driver — <https://secrets-store-csi-driver.sigs.k8s.io/>
- Argo CD ApplicationSet — <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/> · Karmada — <https://karmada.io/docs/> · Cluster API — <https://cluster-api.sigs.k8s.io/>
- Chaos Mesh — <https://chaos-mesh.org/docs/> · Litmus — <https://docs.litmuschaos.io/> · Principles of Chaos Engineering — <https://principlesofchaos.org/>
- etcd operations — <https://etcd.io/docs/latest/op-guide/> · etcd backup/restore — <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/>
- Cilium — <https://docs.cilium.io/> · kube-proxy IPVS — <https://kubernetes.io/docs/reference/networking/virtual-ips/> · API server scalability — <https://kubernetes.io/docs/setup/best-practices/cluster-large/>
- Crossplane — <https://docs.crossplane.io/> · Backstage — <https://backstage.io/docs/overview/what-is-backstage> · Team Topologies — <https://teamtopologies.com/>

Standout articles:
- "The Operator Pattern" original CoreOS post — <https://kubernetes.io/docs/concepts/extend-kubernetes/operator/> (the official write-up)
- Istio ambient announcement / architecture overview — <https://istio.io/latest/blog/2022/introducing-ambient-mesh/>
- Manuel Pais on Internal Developer Platforms / Team Topologies — <https://teamtopologies.com/key-concepts-content/platform-as-a-product>
- "Principles of Chaos Engineering" — <https://principlesofchaos.org/>
- Kelsey Hightower, "Kubernetes The Hard Way" (for control-plane internals you can map onto HA) — <https://github.com/kelseyhightower/kubernetes-the-hard-way>

---

## Part 12 — Kubernetes for Machine Learning

ML workload taxonomy, GPUs and accelerators, batch / gang scheduling,
distributed training, notebooks, model serving (KServe), pipelines (Argo
Workflows / Kubeflow Pipelines), ML platform / cost / MLOps capstone.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — Why ML on Kubernetes](../12-kubernetes-for-machine-learning/01-why-ml-on-kubernetes.md) | KP ch.7 (Batch Job) + ch.29 (Elastic Scale) | R ch.11 (Building Platform Services); official docs (workloads) |
| [02 — GPUs and accelerators](../12-kubernetes-for-machine-learning/02-gpus-and-accelerators.md) | official docs (device plugins, scheduling GPUs) | NVIDIA GPU Operator docs; KP ch.6 (Automated Placement) |
| [03 — Batch and gang scheduling](../12-kubernetes-for-machine-learning/03-batch-and-gang-scheduling.md) | KP ch.7 (Batch Job) + KP ch.6 (Automated Placement) | Kueue docs; JobSet docs; Volcano docs |
| [04 — Distributed training](../12-kubernetes-for-machine-learning/04-distributed-training.md) | KP ch.7 (Batch Job) | Kubeflow Training Operator docs; KubeRay / Ray Train docs |
| [05 — Notebooks and interactive ML](../12-kubernetes-for-machine-learning/05-notebooks-and-interactive.md) | R ch.4 (Container Storage) (PVC-backed dev envs) | JupyterHub z2jh docs; Kubeflow Notebooks |
| [06 — Model serving and inference](../12-kubernetes-for-machine-learning/06-model-serving-and-inference.md) | R ch.14 (Application Considerations) + KP ch.29 (Elastic Scale) | KServe docs; Seldon Core docs; Triton docs |
| [07 — ML pipelines and workflows](../12-kubernetes-for-machine-learning/07-ml-pipelines-and-workflows.md) | A (workflow patterns from Argo) | Argo Workflows / Argo Events docs; Kubeflow Pipelines docs |
| [08 — ML platform, cost, and MLOps capstone](../12-kubernetes-for-machine-learning/08-ml-platform-cost-and-mlops.md) | R ch.11 (Building Platform Services) + R ch.12 (Multitenancy) | KP ch.28 (Operator); MLflow docs; OpenCost docs |

Official docs:
- Scheduling GPUs / device plugins — <https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/> · <https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/> · <https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/>
- NVIDIA GPU Operator — <https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/> · Node Feature Discovery — <https://kubernetes-sigs.github.io/node-feature-discovery/stable/get-started/> · DCGM Exporter — <https://github.com/NVIDIA/dcgm-exporter>
- Kueue — <https://kueue.sigs.k8s.io/docs/> · JobSet — <https://jobset.sigs.k8s.io/docs/> · Volcano — <https://volcano.sh/en/docs/>
- Kubeflow — <https://www.kubeflow.org/docs/> · Kubeflow Training Operator — <https://www.kubeflow.org/docs/components/training/> · Katib — <https://www.kubeflow.org/docs/components/katib/> · Kubeflow Notebooks — <https://www.kubeflow.org/docs/components/notebooks/> · Kubeflow Pipelines — <https://www.kubeflow.org/docs/components/pipelines/>
- Ray — <https://docs.ray.io/> · KubeRay — <https://docs.ray.io/en/latest/cluster/kubernetes/index.html>
- JupyterHub Zero-to-JupyterHub — <https://z2jh.jupyter.org/en/stable/> · KubeSpawner — <https://jupyterhub-kubespawner.readthedocs.io/>
- KServe — <https://kserve.github.io/website/> · Seldon Core — <https://docs.seldon.io/projects/seldon-core/en/latest/> · NVIDIA Triton — <https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/>
- Argo Workflows — <https://argo-workflows.readthedocs.io/> · Argo Events — <https://argoproj.github.io/argo-events/> · Tekton Pipelines — <https://tekton.dev/docs/pipelines/>
- MLflow — <https://mlflow.org/docs/latest/> · OpenCost — <https://www.opencost.io/docs/> · Alibi-Detect — <https://docs.seldon.io/projects/alibi-detect/en/stable/> · Evidently — <https://docs.evidentlyai.com/>

Standout articles:
- "MLOps: Continuous delivery and automation pipelines in machine learning" (Google Cloud — the L0/L1/L2 maturity model) — <https://cloud.google.com/architecture/mlops-continuous-delivery-and-automation-pipelines-in-machine-learning>
- KServe canary rollouts — <https://kserve.github.io/website/latest/modelserving/v1beta1/rollout/canary/>
- Kubeflow Pipelines artifact + metadata model — <https://www.kubeflow.org/docs/components/pipelines/concepts/metadata/>
- Argo Workflows artifacts (input / output, S3 / GCS / PVC) — <https://argo-workflows.readthedocs.io/en/latest/walk-through/artifacts/>
- NVIDIA, "Best Practices for GPU-accelerated Kubernetes" — <https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/overview.html>

---

## Part 13 — Grand Capstone: Bookstore Platform v2

The production e-commerce platform: tenancy + multi-region, Keycloak + IRSA +
mesh JWT, CDC-driven search, Kafka outbox payments, edge WAF + rate limiting,
the closed ML loop, three-pillar OTel observability, OpenCost FinOps,
Backstage as the developer portal, and the day-2 runbook / on-call / DR / chaos
discipline.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — Bookstore 2.0: from toy to platform](../13-grand-capstone-bookstore-platform/01-bookstore-2-from-toy-to-platform.md) | R ch.1 (A Path to Production) + R ch.11 (Building Platform Services) | KP ch.28 (Operator); Google SRE Book ch.1 (Introduction) |
| [02 — Tenancy and Crossplane onboarding](../13-grand-capstone-bookstore-platform/02-tenancy-and-crossplane-onboarding.md) | R ch.12 (Multitenancy) + R ch.11 (Building Platform Services) | KP ch.28 (Operator); Crossplane docs |
| [03 — Multi-region active-active](../13-grand-capstone-bookstore-platform/03-multi-region-active-active.md) | R ch.2 (Deployment Models) | A ch.10 (Applications at Scale); CloudNativePG docs; Google SRE Book ch.21 (Handling Overload) |
| [04 — Real auth: Keycloak OIDC + IRSA + Istio JWT](../13-grand-capstone-bookstore-platform/04-real-auth-keycloak-irsa-istio-jwt.md) | R ch.10 (Identity) | KP ch.26 (Access Control); Keycloak docs; Istio security docs |
| [05 — Search and product discovery](../13-grand-capstone-bookstore-platform/05-search-and-product-discovery.md) | KP ch.13 (Service Discovery) + KP ch.12 (Stateful Service) | Debezium docs; Strimzi docs; Meilisearch docs |
| [06 — Payments and event sourcing](../13-grand-capstone-bookstore-platform/06-payments-and-event-sourcing.md) | KP ch.12 (Stateful Service) + D (microservices event flow) | Strimzi docs; Debezium outbox-pattern article (below); Stripe webhooks docs |
| [07 — Edge: Istio Gateway + Coraza WAF + rate limiting](../13-grand-capstone-bookstore-platform/07-edge-gateway-waf-rate-limiting.md) | R ch.6 (Service Routing) + R ch.8 (Admission Control) (policy posture) | Istio Gateway API docs; Coraza docs; OWASP CRS docs |
| [08 — Real ML loop](../13-grand-capstone-bookstore-platform/08-real-ml-loop-training-registry-serving-drift.md) | R ch.14 (Application Considerations) (canary) + KP ch.29 (Elastic Scale) | KServe canary docs; MLflow Registry docs; Alibi-Detect docs |
| [09 — Observability: OTel + Tempo + Loki + Prometheus + Grafana](../13-grand-capstone-bookstore-platform/09-observability-otel-tempo-loki-prometheus-grafana.md) | R ch.9 (Observability) | Google SRE Book ch.6 (Monitoring Distributed Systems); OpenTelemetry / Tempo / Loki docs |
| [10 — Cost: OpenCost per-tenant FinOps](../13-grand-capstone-bookstore-platform/10-cost-opencost-per-tenant-finops.md) | R ch.12 (Multitenancy) + R ch.13 (Autoscaling) | KP ch.2 (Predictable Demands); OpenCost docs; FinOps Foundation framework |
| [11 — Backstage developer portal](../13-grand-capstone-bookstore-platform/11-backstage-developer-portal-idp.md) | R ch.11 (Building Platform Services) | KP ch.28 (Operator); Backstage docs; Team Topologies |
| [12 — Day-2: runbook + on-call + DR + chaos](../13-grand-capstone-bookstore-platform/12-day-2-runbook-on-call-dr-chaos.md) | Google SRE Book ch.11 (Being On-Call) + ch.14 (Managing Incidents) + ch.15 (Postmortem Culture) | R ch.14 (Application Considerations); Chaos Mesh docs |

Official docs:
- Keycloak — <https://www.keycloak.org/documentation> · Keycloak realms / clients — <https://www.keycloak.org/docs/latest/server_admin/> · Keycloak Operator (Kubernetes) — <https://www.keycloak.org/operator/installation>
- Crossplane — <https://docs.crossplane.io/> · Compositions / XRDs — <https://docs.crossplane.io/latest/concepts/compositions/> · Crossplane v2 (composition functions) — <https://docs.crossplane.io/latest/concepts/composition-functions/>
- CloudNativePG — <https://cloudnative-pg.io/docs/> · `ReplicaCluster` (cross-region) — <https://cloudnative-pg.io/documentation/current/replica_cluster/>
- Strimzi — <https://strimzi.io/docs/operators/latest/overview> · `KafkaConnect` / `KafkaConnector` — <https://strimzi.io/docs/operators/latest/configuring#assembly-deployment-configuration-kafka-connect-str>
- Debezium — <https://debezium.io/documentation/reference/stable/> · Postgres connector — <https://debezium.io/documentation/reference/stable/connectors/postgresql.html>
- Meilisearch — <https://www.meilisearch.com/docs> · Meilisearch on Kubernetes — <https://github.com/meilisearch/meilisearch-kubernetes>
- Istio Gateway API — <https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/> · `RequestAuthentication` / `AuthorizationPolicy` — <https://istio.io/latest/docs/tasks/security/authentication/authn-policy/> · <https://istio.io/latest/docs/tasks/security/authorization/>
- Coraza WAF — <https://coraza.io/docs/> · Istio + Coraza Wasm plugin — <https://github.com/corazawaf/coraza-proxy-wasm>
- OWASP Core Rule Set — <https://coreruleset.org/docs/> · OWASP ModSecurity CRS GitHub — <https://github.com/coreruleset/coreruleset>
- MLflow — <https://mlflow.org/docs/latest/> · Model Registry — <https://mlflow.org/docs/latest/model-registry.html>
- KServe — <https://kserve.github.io/website/> · KServe canary rollouts — <https://kserve.github.io/website/latest/modelserving/v1beta1/rollout/canary/>
- Alibi-Detect — <https://docs.seldon.io/projects/alibi-detect/en/stable/> · Evidently — <https://docs.evidentlyai.com/>
- OpenTelemetry — <https://opentelemetry.io/docs/> · OTel Collector — <https://opentelemetry.io/docs/collector/> · OTLP — <https://opentelemetry.io/docs/specs/otlp/>
- Grafana Tempo — <https://grafana.com/docs/tempo/latest/> · Grafana Loki — <https://grafana.com/docs/loki/latest/> · Grafana variables — <https://grafana.com/docs/grafana/latest/dashboards/variables/>
- Prometheus Alertmanager (inhibition / routing) — <https://prometheus.io/docs/alerting/latest/alertmanager/>
- OpenCost — <https://www.opencost.io/docs/> · OpenCost on Kubernetes — <https://www.opencost.io/docs/installation/install>
- FinOps Foundation framework — <https://www.finops.org/framework/> · FinOps Foundation maturity model — <https://www.finops.org/framework/maturity-model/>
- Backstage — <https://backstage.io/docs/overview/what-is-backstage> · Software Catalog — <https://backstage.io/docs/features/software-catalog/> · Scaffolder — <https://backstage.io/docs/features/software-templates/> · TechDocs — <https://backstage.io/docs/features/techdocs/techdocs-overview>
- Chaos Mesh — <https://chaos-mesh.org/docs/> · Litmus — <https://docs.litmuschaos.io/>
- Stripe sandbox + webhooks — <https://stripe.com/docs/webhooks> · webhook signature verification — <https://stripe.com/docs/webhooks/signatures>

Standout articles:
- Google SRE Book — ch.11 "Being On-Call", ch.14 "Managing Incidents", ch.15 "Postmortem Culture: Learning from Failure" — <https://sre.google/sre-book/being-on-call/> · <https://sre.google/sre-book/managing-incidents/> · <https://sre.google/sre-book/postmortem-culture/>
- FinOps Foundation — the FinOps framework + maturity model — <https://www.finops.org/framework/>
- Spotify's Backstage adoption story — <https://backstage.spotify.com/blog/> (and the canonical "Spotify Engineering Culture" backstage posts at <https://engineering.atspotify.com/category/backstage/>)
- Debezium outbox-pattern canonical post — <https://debezium.io/blog/2019/02/19/reliable-microservices-data-exchange-with-the-outbox-pattern/>
- Google Cloud Architecture Center — multi-region active-active patterns — <https://cloud.google.com/architecture/disaster-recovery> · <https://cloud.google.com/architecture/multi-regional-active-active-design>
- Istio ambient + Coraza WAF — <https://istio.io/latest/blog/> (browse for the WAF + ambient announcements)

---

## Part 14 — EKS in Production: A-Z

Terraform state hygiene, EKS version lifecycle, add-on discipline, storage,
log cost, cost guardrails, infrastructure CI/CD + drift, VPC endpoints,
Graviton, GitOps bootstrap, multi-region cloud reality, supply chain in CI,
runtime defense, Velero, Cilium/eBPF, developer experience, and the cross-
region DR + AWS account baseline + 90-day production-readiness runbook
capstone.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — Production-grade Terraform state](../14-eks-in-production-a-to-z/01-terraform-state-in-production.md) | R ch.1 (A Path to Production); HashiCorp Terraform S3 backend docs (below) | KP ch.28 (Operator); the canonical "Terraform 1.10 `use_lockfile`" blog (below) |
| [02 — EKS cluster lifecycle](../14-eks-in-production-a-to-z/02-eks-cluster-lifecycle.md) | R ch.15 (Cluster Operations); AWS EKS Kubernetes Release Calendar (below) | L ch.3; KP ch.3 (Declarative Deployment) |
| [03 — EKS add-on management discipline](../14-eks-in-production-a-to-z/03-eks-addon-management.md) | R ch.5 (Pod Networking) + R ch.4 (Container Storage); AWS EKS Add-ons docs (below) | L ch.11; Karpenter-shaped material in R ch.13 (Autoscaling) |
| [04 — Storage classes & EBS in production](../14-eks-in-production-a-to-z/04-storage-classes-and-ebs.md) | R ch.4 (Container Storage); AWS EBS gp2 → gp3 migration blog (below) | L ch.8; KP ch.12 (Stateful Service) |
| [05 — Logging & metrics cost discipline](../14-eks-in-production-a-to-z/05-logging-and-metrics-cost.md) | R ch.9 (Observability); AWS CloudWatch pricing (below) | KP ch.2 (Predictable Demands) |
| [06 — Cost guardrails](../14-eks-in-production-a-to-z/06-cost-guardrails.md) | R ch.13 (Autoscaling); FinOps Foundation framework + AWS Budgets docs (below) | KP ch.2 (Predictable Demands); OpenCost docs |
| [07 — Infrastructure CI/CD + drift detection](../14-eks-in-production-a-to-z/07-infrastructure-cicd-and-drift.md) | R ch.1 (A Path to Production); GitHub Actions OIDC docs + Atlantis docs (below) | D (CI shape); driftctl docs |
| [08 — VPC endpoints & egress economics](../14-eks-in-production-a-to-z/08-vpc-endpoints-and-egress.md) | R ch.5 (Pod Networking); AWS VPC endpoints docs (below) | official AWS PrivateLink docs |
| [09 — ARM/Graviton on EKS](../14-eks-in-production-a-to-z/09-arm-graviton-on-eks.md) | R ch.13 (Autoscaling); AWS Graviton docs + Docker buildx multi-platform docs (below) | KP ch.2 (Predictable Demands) |
| [10 — GitOps bootstrap on a fresh EKS cluster](../14-eks-in-production-a-to-z/10-gitops-bootstrap-fresh-cluster.md) | A ch.10 (Applications at Scale); Argo CD App-of-Apps blog (below) | A ch.7 (Sync, Diff, Hooks, Waves) |
| [11 — Multi-region active-active: cloud reality](../14-eks-in-production-a-to-z/11-multi-region-active-active-cloud.md) | R ch.2 (Deployment Models); AWS Route 53 LBR + Global Accelerator + CloudNativePG `ReplicaCluster` docs (below) | Google SRE Book ch.21 (Handling Overload); Google Cloud multi-region active-active blog |
| [12 — Supply chain security in production](../14-eks-in-production-a-to-z/12-supply-chain-security.md) | R ch.8 (Admission Control); Sigstore + cosign + syft + SLSA framework docs (below) | KP ch.25 (Secure Configuration); AWS ECR enhanced scanning docs; Kyverno verifyImages docs |
| [13 — Runtime defense & container security](../14-eks-in-production-a-to-z/13-runtime-defense-and-container-security.md) | R ch.8 (Admission Control); Falco + Tetragon + AWS GuardDuty for EKS docs (below) | KP ch.26 (Access Control); Google SRE Book ch.20 (Load Balancing) (alert routing analogues) |
| [14 — Backup and restore with Velero](../14-eks-in-production-a-to-z/14-backup-and-restore-velero.md) | R ch.15 (Cluster Operations); Velero docs (below) | L ch.8 (Persistent Volumes); CloudNativePG backup docs |
| [15 — Cilium / eBPF on EKS](../14-eks-in-production-a-to-z/15-cilium-ebpf-on-eks.md) | R ch.5 (Pod Networking); Cilium + Hubble docs (below) | KP ch.24 (Network Segmentation); L ch.11 |
| [16 — Developer experience for Kubernetes teams](../14-eks-in-production-a-to-z/16-developer-experience-for-k8s-teams.md) | R ch.11 (Building Platform Services); Telepresence + Mirrord + Skaffold + Tilt + Devcontainer docs (below) | KP ch.30 (Image Builder); Spotify Backstage adoption case study (below) |
| [17 — Cross-region DR + AWS account baseline + 90-day production-readiness runbook](../14-eks-in-production-a-to-z/17-cross-region-dr-account-baseline-90-day-runbook.md) | Google SRE Book ch.32 "The Evolving SRE Engagement Model"; AWS Config conformance pack + IAM Access Analyzer docs (below) | R ch.1 (A Path to Production); R ch.15 (Cluster Operations) |

Official docs:
- HashiCorp Terraform S3 backend (state + `use_lockfile`) — <https://developer.hashicorp.com/terraform/language/settings/backends/s3>
- AWS EKS Kubernetes Release Calendar — <https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html> · EKS standard + extended support — <https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-extended.html>
- AWS EKS Add-ons — <https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html> · `resolve_conflicts_on_update` / `_on_create` reference — <https://docs.aws.amazon.com/eks/latest/APIReference/API_UpdateAddon.html>
- AWS EBS gp2 → gp3 migration — <https://aws.amazon.com/blogs/storage/migrate-your-amazon-ebs-volumes-from-gp2-to-gp3-and-save-up-to-20-on-costs/> · gp3 docs — <https://docs.aws.amazon.com/ebs/latest/userguide/general-purpose.html#gp3-ebs-volume-type>
- AWS CloudWatch pricing — <https://aws.amazon.com/cloudwatch/pricing/> · CloudWatch Logs retention — <https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/SettingLogRetention.html>
- AWS Budgets — <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html> · Budgets actions — <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html>
- FinOps Foundation framework — <https://www.finops.org/framework/> · FinOps maturity model — <https://www.finops.org/framework/maturity-model/>
- infracost — <https://www.infracost.io/docs/> · infracost GitHub Action — <https://github.com/infracost/actions>
- GitHub Actions OIDC for AWS — <https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services> · `aws-actions/configure-aws-credentials` — <https://github.com/aws-actions/configure-aws-credentials>
- Atlantis (Terraform CI) — <https://www.runatlantis.io/docs/> · Atlantis on GitHub — <https://github.com/runatlantis/atlantis>
- driftctl — <https://docs.driftctl.com/> · driftctl on GitHub — <https://github.com/snyk/driftctl>
- AWS VPC endpoints — <https://docs.aws.amazon.com/vpc/latest/privatelink/concepts.html> · Gateway vs Interface endpoints — <https://docs.aws.amazon.com/vpc/latest/privatelink/vpce-gateway.html> · Interface endpoint pricing — <https://aws.amazon.com/privatelink/pricing/>
- AWS Graviton (arm64 EC2) — <https://aws.amazon.com/ec2/graviton/> · Graviton Ready software — <https://aws.amazon.com/ec2/graviton/getting-started/>
- Docker buildx multi-platform — <https://docs.docker.com/build/building/multi-platform/> · `docker buildx --platform` reference — <https://docs.docker.com/reference/cli/docker/buildx/build/>
- Argo CD App-of-Apps pattern — <https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/> · App-of-Apps canonical blog — <https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/>
- AWS Route 53 latency-based routing — <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy.html#routing-policy-latency> · AWS Global Accelerator — <https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html>
- CloudNativePG cross-region `ReplicaCluster` — <https://cloudnative-pg.io/documentation/current/replica_cluster/>
- Sigstore — <https://docs.sigstore.dev/> · cosign — <https://docs.sigstore.dev/cosign/overview/> · cosign keyless — <https://docs.sigstore.dev/cosign/signing/overview/>
- syft (SBOM) — <https://github.com/anchore/syft> · grype (CVE scanner) — <https://github.com/anchore/grype>
- SLSA framework — <https://slsa.dev/spec/v1.0/> · SLSA build levels — <https://slsa.dev/spec/v1.0/levels>
- AWS ECR scanning (basic + enhanced) — <https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning.html> · enhanced scanning with Inspector — <https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning-enhanced.html>
- Kyverno `verifyImages` — <https://kyverno.io/docs/writing-policies/verify-images/> · Kyverno policy library — <https://kyverno.io/policies/>
- Falco — <https://falco.org/docs/> · Falco modern eBPF driver — <https://falco.org/docs/setup/driver/modern-ebpf/>
- Tetragon — <https://tetragon.io/docs/overview/> · Tetragon `TracingPolicy` CRD — <https://tetragon.io/docs/concepts/tracing-policy/>
- AWS GuardDuty for EKS (Audit + Runtime) — <https://docs.aws.amazon.com/guardduty/latest/ug/kubernetes-protection.html> · Runtime Monitoring — <https://docs.aws.amazon.com/guardduty/latest/ug/runtime-monitoring.html>
- Velero — <https://velero.io/docs/main/> · Velero on AWS (BSL + VSL + Kopia) — <https://velero.io/docs/main/csi/> · Velero schedule — <https://velero.io/docs/main/api-types/schedule/>
- Cilium — <https://docs.cilium.io/en/stable/> · Cilium on EKS — <https://docs.cilium.io/en/stable/installation/k8s-install-aws-eks/> · Hubble observability — <https://docs.cilium.io/en/stable/observability/hubble/>
- Telepresence — <https://www.telepresence.io/docs/latest/quick-start/> · personal intercepts — <https://www.telepresence.io/docs/latest/concepts/intercepts/>
- Mirrord — <https://mirrord.dev/docs/overview/introduction/> · Mirrord mirror + steal modes — <https://mirrord.dev/docs/reference/configuration/#feature-network-incoming>
- Skaffold — <https://skaffold.dev/docs/> · Skaffold sync mode — <https://skaffold.dev/docs/filesync/>
- Tilt — <https://docs.tilt.dev/> · Tiltfile reference — <https://docs.tilt.dev/api.html>
- Devcontainer spec — <https://containers.dev/> · `devcontainer.json` reference — <https://containers.dev/implementors/json_reference/>
- AWS Config conformance packs — <https://docs.aws.amazon.com/config/latest/developerguide/conformance-packs.html>
- IAM Access Analyzer — <https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html>

Standout articles:
- Google SRE Book — ch.32 "The Evolving SRE Engagement Model" — <https://sre.google/sre-book/evolving-sre-engagement-model/>
- "Terraform 1.10: native S3 state locking with `use_lockfile`" — HashiCorp release notes — <https://github.com/hashicorp/terraform/releases/tag/v1.10.0> · S3 backend doc note — <https://developer.hashicorp.com/terraform/language/settings/backends/s3#s3-bucket-permissions>
- Spotify's Backstage adoption story (developer-experience case study) — <https://backstage.spotify.com/blog/> · <https://engineering.atspotify.com/category/backstage/>
- "From kubectl to Atlantis: GitOps for Terraform" — Atlantis blog — <https://www.runatlantis.io/blog/>
- "Cilium on EKS in production" — Isovalent blog — <https://isovalent.com/blog/>

---

## Part 15 — Day-to-Day Production Operations

The application-side production loop: PR-to-production lifecycle, application
CI/CD, image signing + provenance, multi-environment promotion, production
Vault + ESO secrets, progressive delivery, rollback layer matrix, feature
flags + dark launches, hotfix + breakglass, incident response + on-call,
day-to-day ops cadence, and the first-90-days capstone for a team taking over
production.

| Guide chapter | Primary | Secondary |
|---|---|---|
| [01 — The PR-to-production lifecycle](../15-day-to-day-production-ops/01-pr-to-production-lifecycle.md) | D (microservices delivery shape); R ch.1 (A Path to Production) | A ch.10 (Applications at Scale); Google SRE Book ch.7 (The Evolution of Automation) |
| [02 — Application CI/CD pipelines](../15-day-to-day-production-ops/02-application-cicd-pipelines.md) | D (CI/CD shape); GitHub Actions OIDC docs (below) | R ch.1 (A Path to Production); Atlantis docs |
| [03 — Image signing and provenance in CI](../15-day-to-day-production-ops/03-image-signing-and-provenance.md) | R ch.8 (Admission Control); Sigstore + cosign docs + SLSA framework (below) | KP ch.25 (Secure Configuration); Kyverno verifyImages docs |
| [04 — Multi-environment promotion](../15-day-to-day-production-ops/04-multi-environment-promotion.md) | A ch.7 (Sync, Diff, Hooks, Waves) + A ch.8 (Apps + ApplicationSets); Argo CD `ApplicationSet` docs (below) | R ch.1 (A Path to Production) |
| [05 — Production secrets: Vault + ESO + rotation](../15-day-to-day-production-ops/05-production-secrets-vault-eso.md) | R ch.7 (Secret Management); HashiCorp Vault + External Secrets Operator docs (below) | KP ch.25 (Secure Configuration); KP ch.20 (Configuration Resource) |
| [06 — Progressive delivery in production](../15-day-to-day-production-ops/06-progressive-delivery-in-production.md) | A ch.10 (Applications at Scale); Argo Rollouts `AnalysisTemplate` + canary docs (below) | R ch.14 (Application Considerations); Google SRE Book ch.27 (Reliable Product Launches at Scale) |
| [07 — Rollback playbook](../15-day-to-day-production-ops/07-rollback-playbook.md) | R ch.15 (Cluster Operations); Velero restore + Postgres PITR (CNPG) + AWS S3 versioning docs (below) | KP ch.3 (Declarative Deployment); A ch.7 (Sync, Diff, Hooks, Waves) |
| [08 — Feature flags and dark launches](../15-day-to-day-production-ops/08-feature-flags-and-dark-launches.md) | R ch.14 (Application Considerations); OpenFeature + Flagsmith / LaunchDarkly / Unleash docs (below) | D (microservices feature toggle shape); Charity Majors "test in production" canon (below) |
| [09 — Hotfix workflow and breakglass](../15-day-to-day-production-ops/09-hotfix-workflow-and-breakglass.md) | Google SRE Book ch.14 (Managing Incidents); AWS CloudTrail + IAM breakglass docs (below) | R ch.15 (Cluster Operations); R ch.7 (Secret Management) (post-incident rotation) |
| [10 — Incident response & on-call](../15-day-to-day-production-ops/10-incident-response-and-on-call.md) | Google SRE Book ch.11 (Being On-Call) + ch.14 (Managing Incidents) + ch.15 (Postmortem Culture); PagerDuty + Incident.io / FireHydrant / Rootly docs (below) | Camille Fournier, *The Manager's Path* (on-call as a team practice) (below) |
| [11 — Day-to-day production operations](../15-day-to-day-production-ops/11-day-to-day-production-ops.md) | Google SRE Book ch.16 (Tracking Outages) + ch.17 (Testing for Reliability); AWS Well-Architected Operational Excellence pillar (below) | KP ch.2 (Predictable Demands); R ch.13 (Autoscaling) |
| [12 — Capstone: the first 90 days running production](../15-day-to-day-production-ops/12-capstone-first-90-days.md) | Google SRE Book ch.1 (Introduction) + ch.32 (The Evolving SRE Engagement Model); Camille Fournier, *The Manager's Path* (below) | R ch.1 (A Path to Production) |

Official docs:
- HashiCorp Vault — <https://developer.hashicorp.com/vault/docs> · Vault Kubernetes auth method — <https://developer.hashicorp.com/vault/docs/auth/kubernetes> · Vault dynamic database secrets — <https://developer.hashicorp.com/vault/docs/secrets/databases>
- External Secrets Operator — <https://external-secrets.io/latest/> · `ClusterSecretStore` / `SecretStore` — <https://external-secrets.io/latest/api/clustersecretstore/> · `ExternalSecret` CRD — <https://external-secrets.io/latest/api/externalsecret/>
- Argo CD `ApplicationSet` — <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/> · Cluster generator — <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/>
- Argo Rollouts — <https://argoproj.github.io/argo-rollouts/> · `AnalysisTemplate` — <https://argoproj.github.io/argo-rollouts/features/analysis/> · canary strategy — <https://argoproj.github.io/argo-rollouts/features/canary/> · blue-green strategy — <https://argoproj.github.io/argo-rollouts/features/bluegreen/>
- OpenFeature — <https://openfeature.dev/docs/reference/intro> · OpenFeature spec — <https://openfeature.dev/specification/>
- Flagsmith — <https://docs.flagsmith.com/> · LaunchDarkly — <https://docs.launchdarkly.com/> · Unleash — <https://docs.getunleash.io/>
- PagerDuty (Alertmanager integration) — <https://support.pagerduty.com/main/docs/services-integrations> · PagerDuty Events API — <https://developer.pagerduty.com/docs/events-api-v2/overview/>
- Incident.io — <https://incident.io/docs> · FireHydrant — <https://docs.firehydrant.com/> · Rootly — <https://rootly.com/docs>
- Atlassian Statuspage — <https://support.atlassian.com/statuspage/> · Statuspage incident communication — <https://www.atlassian.com/incident-management/handbook/incident-communication>
- Velero restore — <https://velero.io/docs/main/restore-reference/> · selective restore — <https://velero.io/docs/main/resource-filtering/>
- Postgres point-in-time recovery (CloudNativePG) — <https://cloudnative-pg.io/documentation/current/recovery/> · backup config — <https://cloudnative-pg.io/documentation/current/backup/>
- AWS S3 versioning — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html> · S3 Batch Operations restore — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/batch-ops.html>
- AWS CloudTrail (audit-log immutability) — <https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-integrity-validation.html> · CloudTrail log file integrity validation — <https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-integrity-validation-enabling.html>
- AWS Well-Architected Framework — Operational Excellence pillar — <https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html>
- Prometheus Alertmanager inhibition + routing — <https://prometheus.io/docs/alerting/latest/alertmanager/#inhibition>

Standout articles:
- Google SRE Book — ch.11 "Being On-Call", ch.14 "Managing Incidents", ch.15 "Postmortem Culture: Learning from Failure" — <https://sre.google/sre-book/being-on-call/> · <https://sre.google/sre-book/managing-incidents/> · <https://sre.google/sre-book/postmortem-culture/>
- Charity Majors — "Test in production" canon — <https://charity.wtf/2017/07/03/test-in-production-yo/> · "I test in prod" — <https://increment.com/testing/i-test-in-production/>
- Camille Fournier, *The Manager's Path* (O'Reilly) — the canonical reference on on-call as a team practice, tech-lead transitions, and incident postmortem culture — <https://www.oreilly.com/library/view/the-managers-path/9781491973882/>
- "Build, deploy, run: a Charity Majors framework for production excellence" — <https://charity.wtf/category/production/>
- "The 24-hour postmortem" — Incident.io — <https://incident.io/blog/post-mortems-and-learning>

---

## How to go deeper (a path through the library)

1. **Get the model first.** Read **Lukša 2e ch.1–9** alongside Parts 00–03 of
   this guide — it is the deepest "how it works" within MEAP scope and tracks
   the guide's foundations/workloads/config arc almost chapter-for-chapter.
   *Poulton* is the gentler on-ramp if Part 00 feels fast.
2. **Add the "why" lens.** Read **Kubernetes Patterns 2e** by *pattern* as each
   one appears (Health Probe → Part 01 ch.02; Automated Placement → Part 04;
   Process Containment / Access Control → Part 05; Controller/Operator → Part 08
   ch.05). It explains the design rationale the guide applies.
3. **Go to production.** Read **Production Kubernetes** for Parts 05–08 —
   security hardening, observability, delivery, day-2, multitenancy, supply
   chain. It is the guide's primary source for the production arc.
4. **Delivery & GitOps.** Read **Argo CD Up & Running** end-to-end for Part 07
   ch.04 (it is effectively the sole reference there) and *Bootstrapping
   Microservices* for the CI/CD pipeline shape (Part 07 ch.03).
5. **Then breadth — the CNCF landscape.** The cloud-native ecosystem is far
   wider than this guide (service mesh, eBPF, policy, cost, FinOps, platform
   engineering). Use the **CNCF Cloud Native Landscape**
   (<https://landscape.cncf.io/>) and the CNCF site
   (<https://www.cncf.io/>) to see where each tool the guide uses
   (Prometheus, OpenTelemetry, Argo, Helm, Kustomize, Kyverno, KEDA, Cilium,
   CloudNativePG, …) sits, and what graduated/incubating alternatives exist.
6. **Certify (optional).** [Appendix E — Learning paths](E-learning-paths.md)
   maps this guide's chapters to the **CKAD / CKA / CKS** exam domains and gives
   ordered study tracks.

---

See also: [Appendix E — Learning paths](E-learning-paths.md) for ordered study
routes through the guide, and each chapter's own "Further reading" section for
the precise per-chapter citation and official URL.
