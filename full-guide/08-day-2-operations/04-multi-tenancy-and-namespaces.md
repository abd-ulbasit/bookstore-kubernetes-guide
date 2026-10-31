# 04: Multi-tenancy and namespaces

> The namespace as the **primary tenancy boundary**, and the precise list of
> what it does **not** isolate: nodes, the kernel, cluster-scoped objects, and
> the API server itself. **Soft multi-tenancy** (trusted teams: namespace +
> RBAC + ResourceQuota + LimitRange + NetworkPolicy + PSA; the Bookstore
> namespace *already* demonstrates every one of these, and this chapter ties
> them together and extends to a *second* tenant) versus **hard
> multi-tenancy** (hostile tenants: + node isolation, separate control planes,
> vCluster/Capsule/HNC, or just separate clusters). The **namespace-as-env
> versus namespace-as-tenant** distinction (this guide uses Kustomize overlays
> for *envs* in one `bookstore` ns, and envs are not tenants), and how you'd
> extend to per-team namespaces under an AppProject-per-team; fairness
> (Quota/LimitRange/PriorityClass/preemption, [Part 04](../04-scheduling/03-priority-and-preemption.md)),
> noisy-neighbour, cost attribution ([Part 06
> ch.06](../06-production-readiness/06-capacity-and-cost.md)); and the
> HNC/vCluster/Capsule landscape at the right depth, applied with a worked
> `tenant-acme` namespace carrying its own full guardrail stack.

**Estimated time:** ~30 min read · ~60 min hands-on
**Lab tier:** A (kind). Run the hands-on only against a kind cluster you own.
**Prerequisites:** [Part 05 ch.01](../05-security/01-authn-authz-rbac.md) (RBAC at the namespace boundary) · [Part 06 ch.06](../06-production-readiness/06-capacity-and-cost.md) (ResourceQuota and cost attribution per tenant) · [Part 02 ch.06](../02-networking/06-network-policies.md) (NetworkPolicy is the only network tenancy primitive)
**You'll know after this:** • articulate exactly what a namespace does and does *not* isolate · • build a soft-multi-tenant stack with namespace + RBAC + Quota + LimitRange + NetworkPolicy + PSA · • choose between soft tenancy, hard tenancy and separate clusters by trust model · • distinguish namespace-as-env from namespace-as-tenant cleanly · • add a second tenant to the cluster with full guardrails alongside the Bookstore

<!-- tags: multi-tenancy, security, platform-engineering, day-2 -->

## Why this exists

The Bookstore has, since Part 01, lived in **one namespace** with a
**ResourceQuota + LimitRange** ([Part 01
ch.03](../01-core-workloads/03-resources-and-qos.md)), **RBAC + ServiceAccounts**
([Part 05 ch.01](../05-security/01-authn-authz-rbac.md)), **NetworkPolicies**
([Part 02 ch.06](../02-networking/06-network-policies.md)), and **PSA
`restricted`** ([Part 05 ch.02](../05-security/02-pod-security.md)). Each was
introduced for its own reason. **Together they are exactly the soft-multi-tenancy
control set.** The guide built a tenant-isolation stack without ever calling
it that. This chapter names it, and answers the question every multi-team
cluster eventually forces: *can two teams safely share this cluster, and how
hard is "safely"?*

Two misconceptions make this a required chapter, not an optional one:

1. **"A namespace isolates tenants."** A namespace scopes *names*, *RBAC*,
   *quota*, and (with NetworkPolicy/PSA) *network and pod-security*. It does
   **not** isolate the **kernel** (a container escape on a shared node crosses
   namespaces), the **nodes** (two tenants' Pods can co-tenant a node),
   **cluster-scoped objects** (CRDs, PriorityClasses, the API server, etcd), or
   **the control plane's QPS**. Soft multi-tenancy is "trusted teams, strong
   guardrails"; hostile tenants need *more* than a namespace.
2. **"Environments are tenants."** This guide deploys dev/staging/prod as
   **Kustomize overlays into one `bookstore` namespace** ([Part 07
   ch.02](../07-delivery/02-packaging-kustomize.md)). That is **environment**
   separation of **one** app, not **tenant** separation of **many**.
   Conflating them produces either over-isolated envs or dangerously
   under-isolated tenants. The distinction is structural and this chapter
   draws it.

The reference is *Production Kubernetes* (Multitenancy); the access-control
lens is *Kubernetes Patterns* ch.26.

## Mental model

**A namespace is a soft boundary made real only by the guardrail stack you
attach to it; "how hostile are the tenants?" decides whether soft is enough.**

- **The namespace isolates *names and policy attachment points*, nothing
  physical.** It gives you a scope for RBAC, a target for ResourceQuota/
  LimitRange, a selector for NetworkPolicy, and a label set for PSA. It does
  **not** give you a kernel boundary, a node boundary, or a control-plane
  boundary. Isolation is the *sum of the policies you attach*, not a property
  of the namespace itself.
- **Soft multi-tenancy = trusted teams + the full guardrail stack.** Per-tenant
  **namespace** (the scope) + **RBAC** (who can do what, *here*) +
  **ResourceQuota** (the tenant's total) + **LimitRange** (per-container
  bounds) + **NetworkPolicy** (default-deny + only-intended flows) + **PSA**
  (no privileged pods). The Bookstore namespace already runs **all six**. It
  is a *one-tenant* instance of exactly this pattern.
- **Hard multi-tenancy = you don't trust the tenants, so the namespace isn't
  enough.** Add **node isolation** (taints/affinity or separate node pools so
  tenants don't share a kernel), and/or **separate control planes** (vCluster,
  a virtual control plane per tenant; Capsule, a tenant operator; HNC,
  hierarchical namespaces), and/or the bluntest, strongest answer:
  **separate clusters**. The stronger the distrust, the further from "just a
  namespace" you go, up to "not even the same cluster".
- **Env is not tenant.** *Environments* (dev/staging/prod of the **same** app)
  are the **same owner**, isolated for lifecycle and blast radius. Kustomize
  overlays ([Part 07 ch.02](../07-delivery/02-packaging-kustomize.md)) into one
  ns are fine. *Tenants* (different **owners**) are isolated for *security and
  fairness*. They need **separate namespaces**, each with its **own** full
  guardrail stack, scoped by **an AppProject per team** ([Part 07
  ch.04](../07-delivery/04-gitops-argocd.md)).
- **Fairness is multi-layer.** Inside a namespace: **ResourceQuota** caps the
  total, **LimitRange** bounds each container, **PriorityClass/preemption**
  ([Part 04 ch.03](../04-scheduling/03-priority-and-preemption.md)) decide who
  wins under contention. *Above* the namespace: **API Priority & Fairness**
  ([11.03](../11-advanced-production-patterns/03-api-priority-and-fairness.md))
  protects the **apiserver/etcd** from one tenant's request flood. It is a
  noisy neighbour at the *control-plane* layer that quotas don't touch.

The trap to hold: **the namespace is a *trust* boundary, not a *security*
boundary in the kernel sense.** It is strong enough for teams in the same org
(soft); it is *not* a sandbox for code you don't trust. Knowing which regime
you're in is the entire decision, and it dictates everything from node pools
to whether you should be running one cluster at all.

## Threats and controls

Only threats specific to tenancy are listed. Each row names the control this
chapter teaches and where the topic goes deeper.

| Threat | Control taught here | Goes deeper in |
|---|---|---|
| A container escape on a shared node reaches another tenant | None inside a namespace. The chapter names the gap; node isolation and sandboxed runtimes close it | [04.02](../04-scheduling/02-affinity-taints-topology.md) for node isolation; sandboxed runtimes in chapter 05.05 <!-- link-later: 05.05 --> |
| A tenant raises its own quota, or takes cluster-wide power | A namespaced Role and RoleBinding, with no verbs on `resourcequotas` or `limitranges` | [05.01](../05-security/01-authn-authz-rbac.md) |
| A noisy tenant starves the others of CPU and memory | ResourceQuota caps the namespace total; LimitRange bounds each container | [01.03](../01-core-workloads/03-resources-and-qos.md); [04.03](../04-scheduling/03-priority-and-preemption.md) |
| A noisy tenant floods the API server | Not closed here: quota does not count API requests | [11.03](../11-advanced-production-patterns/03-api-priority-and-fairness.md) |
| A tenant reaches another tenant's Pods over the network | Default-deny NetworkPolicy, plus a same-namespace allow | [02.06](../02-networking/06-network-policies.md) |
| A tenant runs a privileged Pod, or uses exec to read a workload's mounts | PSA `restricted`; no `pods/exec` in the tenant Role | [05.02](../05-security/02-pod-security.md); debugging in [08.03](03-troubleshooting-playbook.md) |

## Diagrams

### Diagram A: soft vs hard tenancy, what each layer isolates (Mermaid)

```mermaid
flowchart TB
    subgraph soft["SOFT multi-tenancy (trusted teams): what a namespace + stack DOES isolate"]
      ns["Namespace<br/>(name scope)"]
      rbac["RBAC<br/>(who can act, HERE)"]
      qta["ResourceQuota + LimitRange<br/>(tenant total + per-container)"]
      np["NetworkPolicy<br/>(default-deny + intended flows)"]
      psa["PSA restricted<br/>(no privileged pods)"]
      ns --> rbac --> qta --> np --> psa
      psa -->|"= the Bookstore ns ALREADY"| ok["isolated: names, API actions,<br/>fair share, network, pod-security"]
    end

    subgraph notiso["What a namespace does NOT isolate (the soft limit)"]
      k["Kernel / node<br/>(container escape crosses ns;<br/>tenants co-tenant a node)"]
      cs["Cluster-scoped objects<br/>(CRDs, PriorityClass, API server, etcd)"]
      qps["Control-plane QPS<br/>(one tenant can flood the apiserver)"]
    end

    subgraph hard["HARD multi-tenancy (untrusted): ADD on top"]
      node["Node isolation<br/>(taints/affinity, separate pools)"]
      vc["Virtual/own control plane<br/>(vCluster / Capsule / HNC)"]
      apf["API Priority & Fairness<br/>(per-tenant apiserver fairness)"]
      sep["...or separate CLUSTERS<br/>(the strongest, bluntest boundary)"]
      node --> vc --> apf --> sep
    end

    notiso -->|"these gaps are WHY you need"| hard
```

### Diagram B: namespace-per-team layout with the guardrail stack (ASCII)

```
 ENV vs TENANT, and the per-tenant guardrail stack ─────────────────────────

  THIS GUIDE (env separation of ONE app, same owner):
    cluster
      └── ns: bookstore   ◄── dev/staging/prod = KUSTOMIZE OVERLAYS (P07 ch.02)
            stack: [Quota][LimitRange][RBAC][NetworkPolicy][PSA restricted]
          (envs are NOT tenants: same team, isolated for lifecycle only)

  REAL MULTI-TENANT (tenant separation of MANY owners, extend to this):
    cluster
      ├── ns: tenant-acme     team=acme    AppProject: acme   (P07 ch.04)
      │     [Quota acme][LimitRange][RBAC→acme-team][NetPol deny+dns][PSA]
      ├── ns: tenant-globex   team=globex  AppProject: globex
      │     [Quota globex][LimitRange][RBAC→globex-team][NetPol deny+dns][PSA]
      └── ns: tenant-…        …            …
            ▲ EACH tenant: its OWN full guardrail set + its OWN AppProject
            ▲ cross-tenant traffic: default-DENY (NetworkPolicy)
            ▲ cross-tenant API: scoped by per-team RBAC + AppProject
            ▲ STILL shared (the soft limit): nodes/kernel, etcd, the apiserver
              → if tenants are HOSTILE: + node pools / vCluster / SEPARATE
                clusters (the further right, the stronger the distrust)
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).** This
chapter adds [`examples/bookstore/operators/second-tenant.yaml`](../examples/bookstore/operators/second-tenant.yaml)
(a pod-free `tenant-acme` namespace + its full guardrail stack). It does
**not** modify the `bookstore` namespace or any canonical manifest. The
existing stack is *demonstrated*, and the second tenant is purely additive.

The output blocks in this section were captured on a lab cluster with a
different name, and its namespaces carried a lab prefix. So no block shows a
namespace name. The commands print the names you will use.

### 0. Prerequisites: fresh cluster + images + the Bookstore (self-bootstrapping)

```sh
kind delete cluster --name bookstore 2>/dev/null || true
kind create cluster --name bookstore
cd examples/bookstore/app
for s in catalog orders payments-worker storefront; do docker build -t bookstore/$s:dev ./$s; done
cd ../../..
for s in catalog orders payments-worker storefront; do kind load docker-image bookstore/$s:dev --name bookstore; done

kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
kubectl apply -f examples/bookstore/raw-manifests/15-catalog-config.yaml
kubectl apply -f examples/bookstore/raw-manifests/16-db-credentials.yaml
kubectl apply -f examples/bookstore/raw-manifests/35-priorityclasses.yaml
kubectl apply -f examples/bookstore/raw-manifests/12-redis.yaml
kubectl apply -f examples/bookstore/raw-manifests/13-rabbitmq.yaml
kubectl apply -f examples/bookstore/raw-manifests/20-postgres-statefulset.yaml
kubectl apply -f examples/bookstore/raw-manifests/40-services.yaml
kubectl apply -f examples/bookstore/raw-manifests/10-catalog-deploy.yaml
kubectl apply -f examples/bookstore/raw-manifests/11-storefront-deploy.yaml
kubectl apply -f examples/bookstore/raw-manifests/14-orders-deploy.yaml
kubectl apply -f examples/bookstore/raw-manifests/19-payments-worker-deploy.yaml
kubectl apply -f examples/bookstore/raw-manifests/21-db-migrate-job.yaml
kubectl apply -f examples/bookstore/raw-manifests/60-networkpolicy.yaml
# the migration Job must COMPLETE (creates the `books` schema) before catalog/
# orders become Ready; otherwise they CrashLoop and the wait below times out:
kubectl wait --for=condition=complete job/db-migrate -n bookstore --timeout=120s
kubectl wait --for=condition=available deploy --all -n bookstore --timeout=180s
```

> **Self-bootstrapping note.** After any `kind delete && kind create`
> re-`kind load` the four images and re-run this chain.

### 1. The Bookstore namespace IS a soft-multi-tenancy instance: see the stack

Every guardrail is already there. Multi-tenancy is just *recognising the
pattern* and *replicating it per tenant*:

```sh
# Fairness: the tenant's total and the per-container bounds (Part 01 ch.03).
kubectl get resourcequota,limitrange -n bookstore
#   bookstore-quota: requests.cpu 2 / memory 2Gi / pods 30 (the ns CAP)
#   bookstore-limits: per-Container default/min/max (per-workload)
```

<!-- gate: output -->
```
NAME                            REQUEST                                                 LIMIT                                   AGE
resourcequota/bookstore-quota   pods: 0/30, requests.cpu: 0/2, requests.memory: 0/2Gi   limits.cpu: 0/4, limits.memory: 0/4Gi   2s

NAME                          CREATED AT
limitrange/bookstore-limits   2026-10-31T04:16:43Z
```

```sh
# Identity: eight dedicated ServiceAccounts. Nothing runs as `default`.
kubectl get serviceaccounts -n bookstore
```

<!-- gate: output -->
```
NAME                 AGE
catalog-sa           2s
# ...
default              2s
```

The `default` row is the ServiceAccount every namespace gets. Every Bookstore
workload sets its own `serviceAccountName`, so none runs as `default`.

```sh
# Network: default-deny plus only the intended flows (Part 02 ch.06).
kubectl get networkpolicy -n bookstore
kubectl get networkpolicy default-deny-all -n bookstore -o jsonpath='{.spec.policyTypes}'; echo

# Pod security: the hard gate (Part 05 ch.02).
kubectl get ns bookstore -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'; echo
```

<!-- gate: output -->
```
NAME                           POD-SELECTOR                                 AGE
# ...
allow-dns-egress               <none>                                       1s
# ...
default-deny-all               <none>                                       1s
# ...
["Ingress","Egress"]
# ...
restricted
```

`restricted` is the label the Bookstore namespace carries as
`pod-security.kubernetes.io/enforce`. Admission refuses any privileged Pod in
that namespace.

That is the **complete soft-multi-tenancy control set**, already running for
one tenant. Multi-tenancy is making it *per tenant*.

### 2. Add a second tenant (the worked example, with its own full stack)

`second-tenant.yaml` is `tenant-acme` with **its own** Quota, LimitRange,
RBAC, NetworkPolicies, and PSA labels, independent of `bookstore`:

```sh
# It is pod-free: no Pod for PSA to judge, and no CRD to install first.
kubectl apply --dry-run=client -f examples/bookstore/operators/second-tenant.yaml

kubectl apply -f examples/bookstore/operators/second-tenant.yaml
kubectl get ns tenant-acme -o jsonpath='{.metadata.labels.tenant}'; echo
kubectl describe resourcequota,limitrange -n tenant-acme    # acme's OWN caps
```

<!-- gate: output -->
```
acme
```

### 3. Prove the isolation the stack actually gives (and its limits)

Each check prints `yes` or `no`. The answers came back in the order the
commands are listed here:

```sh
# (a) RBAC: acme's identity can deploy in its own namespace, not in bookstore.
#     The Role is NAMESPACED, so it does not cross.
kubectl auth can-i create deployments \
  --as=system:serviceaccount:tenant-acme:acme-deployer -n tenant-acme    # yes
kubectl auth can-i create deployments \
  --as=system:serviceaccount:tenant-acme:acme-deployer -n bookstore      # no

# (b) Tenants cannot mint their own quota: capacity is platform-managed (the
#     same stance as the Bookstore AppProject's blacklist, Part 07 ch.04).
kubectl auth can-i create resourcequota \
  --as=system:serviceaccount:tenant-acme:acme-deployer -n tenant-acme    # no

# (c) Tenants cannot rewrite their own network rules, and they cannot exec into
#     a Pod. Logs stay readable. The Role grants `get` on pods/log only.
kubectl auth can-i create networkpolicies \
  --as=system:serviceaccount:tenant-acme:acme-deployer -n tenant-acme    # no
kubectl auth can-i create pods --subresource=exec \
  --as=system:serviceaccount:tenant-acme:acme-deployer -n tenant-acme    # no
kubectl auth can-i get pods --subresource=log \
  --as=system:serviceaccount:tenant-acme:acme-deployer -n tenant-acme    # yes

# (d) Secrets in another namespace stay out of reach.
kubectl auth can-i get secrets \
  --as=system:serviceaccount:tenant-acme:acme-deployer -n bookstore      # no
```

<!-- gate: output -->
```
yes
# ...
no
# ...
no
# ...
no
# ...
no
# ...
yes
# ...
no
```

Quota isolation follows from the same rule: ResourceQuota is counted per
namespace, so tenant-acme exhausting its own total does not change
bookstore's. The [Kubernetes resource quota
page](https://kubernetes.io/docs/concepts/policy/resource-quotas/) states
this. The lab run did not exhaust a quota.

**Deliberate failure.** The next request asks for a privileged container. It
is refused, and the error names each rule the Pod breaks. The image is never
pulled, because admission refuses the request first:

```sh
kubectl run escape-probe -n tenant-acme --image=bookstore/catalog:dev \
  --restart=Never --privileged --dry-run=server
```

<!-- gate: output -->
```
Error from server (Forbidden): pods "escape-probe" is forbidden: violates PodSecurity "restricted:latest": privileged (container "escape-probe" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "escape-probe" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "escape-probe" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "escape-probe" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "escape-probe" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

**The soft limit.** The checks above cannot show these:

```sh
# (e) THE SOFT LIMIT: what the namespace does NOT isolate.
kubectl get nodes
#   Both bookstore and tenant-acme Pods can schedule onto the SAME node, so
#   they SHARE a kernel and node resources. CRDs, PriorityClasses and the
#   apiserver are cluster-scoped and SHARED. For HOSTILE tenants this is
#   insufficient: add node isolation (taints/pools, Part 04 ch.02), a virtual
#   control plane (vCluster), or SEPARATE CLUSTERS. See How it works.
```

The NetworkPolicy objects are in place, but whether a dropped packet is
dropped depends on a policy-enforcing CNI. kind's default CNI does not enforce
NetworkPolicy, so the lab checks the objects and not the traffic
([Part 02 ch.06](../02-networking/06-network-policies.md)).

### 4. How envs differ from tenants (the structural point, made concrete)

```sh
# This guide's dev/staging/prod are OVERLAYS of ONE app into ONE ns: SAME
# owner, isolated only for lifecycle (Part 07 ch.02).
kubectl kustomize examples/bookstore/kustomize/overlays/dev  | grep -m1 'namespace:'
kubectl kustomize examples/bookstore/kustomize/overlays/prod | grep -m1 'namespace:'
```

<!-- gate: output -->
```
  namespace: bookstore
# ...
  namespace: bookstore
```

Both overlays render into `bookstore`. Envs are not separate tenants.

A real TENANT (tenant-acme) is a SEPARATE namespace with its OWN guardrail
stack and (in production) its OWN AppProject scoping its repo and destinations
([Part 07 ch.04](../07-delivery/04-gitops-argocd.md)). Extending the Bookstore
to multi-tenant means repeating `second-tenant.yaml` per team and adding one
AppProject per team, not adding more overlays.

Clean up:

```sh
kubectl delete -f examples/bookstore/operators/second-tenant.yaml --ignore-not-found
kind delete cluster --name bookstore
```

## How it works under the hood

- **What a namespace actually is.** A namespace is a cluster-scoped object that
  creates a *scope* for **namespaced** resource names and a *target* for
  policy. The API server enforces that namespaced objects live in exactly one
  namespace. RBAC `Role`/`RoleBinding`, `ResourceQuota`, `LimitRange`, and
  `NetworkPolicy` are themselves namespaced and apply *only within* it. PSA
  reads the namespace's **labels** at admission. It is an *organisational and
  policy* construct. There is **no namespace boundary in the Linux kernel, the
  scheduler, or etcd**. That single fact is the whole soft/hard distinction.
- **The six guardrails and the layer each closes.** **RBAC** decides *who* may
  act, scoped here: a namespaced Role cannot grant cross-namespace power, as
  step 3 showed. **ResourceQuota**: admission rejects an object that would push
  the namespace's *aggregate* requests, limits or object counts over the cap,
  so one tenant can't consume the cluster. **LimitRange**: admission injects
  defaults and rejects per-container values outside [min, max], so one Pod
  can't request the whole quota ([upstream limit range
  page](https://kubernetes.io/docs/concepts/policy/limit-range/)).
  **NetworkPolicy**: the CNI drops traffic not explicitly allowed once a policy
  selects a Pod. Default-deny leads to only the intended flows, and *both ends*
  are needed under default-deny egress ([Part 02
  ch.06](../02-networking/06-network-policies.md)). **PSA** rejects Pods (and
  ephemeral containers) that violate the namespace's Pod Security Standard, so
  there is no privileged escape surface ([Part 05
  ch.02](../05-security/02-pod-security.md)). Together: name, authz, fairness,
  network and pod-security, all enforced at admission or by the CNI.
- **What the namespace does *not* isolate (the hard-tenancy gap, precisely).**
  (1) **Kernel and node.** Pods of different namespaces can be scheduled onto
  the same node and share one kernel, so a container escape is not bound to a
  namespace. The mitigations are sandboxed runtimes (gVisor, Kata) and node
  pools per tenant. (2) **Cluster-scoped objects.** CRDs, `PriorityClass` (the
  Bookstore's `35-`), `ClusterRole`, `StorageClass`, the API server, and etcd
  are all shared. A tenant with cluster-scoped RBAC affects everyone. (3)
  **Control-plane QPS.** One tenant hammering the API server degrades it for
  all. That is the job of **API Priority & Fairness** (`FlowSchema` and
  `PriorityLevelConfiguration`, [11.03](../11-advanced-production-patterns/03-api-priority-and-fairness.md)),
  not ResourceQuota. Soft tenancy accepts these shared surfaces because
  tenants are *trusted*. Hard tenancy must close them.
- **Choosing the regime by threat model.** The escalation ladder runs from
  node isolation (taints/affinity or dedicated node pools, so tenants don't
  share a kernel; [Part 04 ch.02](../04-scheduling/02-affinity-taints-topology.md))
  to sandboxed runtimes (gVisor, Kata; chapter 05.05
  <!-- link-later: 05.05 -->), then to a virtual control plane per tenant
  (vCluster, with its own API server and CRDs), and finally to separate
  clusters, the only complete boundary. Each step costs more to run; see
  [ch.01](01-cluster-lifecycle.md) for the fleet cost. Choose by threat model,
  not by Pod count.
- **vCluster, Capsule and HNC: what they actually do.** **vCluster** runs a
  *virtual* Kubernetes API server (with its own etcd or k3s) for the tenant
  inside a host namespace. The tenant gets what looks like a whole cluster,
  with its own CRDs, cluster-scoped objects and even namespaces, while the host
  schedules the real Pods. That is far stronger control-plane isolation than a
  namespace, short of a real cluster. **Capsule** is an operator that turns a
  `Tenant` CR into the enforced guardrail set (quota, RBAC, network, PSA)
  across a group of namespaces. It automates what `second-tenant.yaml` does by
  hand, at fleet scale. **HNC** (Hierarchical Namespace Controller) gives
  parent and child namespaces with **policy inheritance**, so a team's RBAC and
  quota cascade to its sub-teams' namespaces. None give a kernel boundary. For
  that you still need node isolation or separate clusters.
- **Env vs tenant is an ownership fact, not a size fact.** dev/staging/prod are
  the **same** owner's lifecycle stages. They are Kustomize overlays
  ([Part 07 ch.02](../07-delivery/02-packaging-kustomize.md)) into one ns,
  isolated for *blast radius*. Tenants are **different** owners: separate
  namespaces, separate guardrail stacks, and separate **AppProjects** ([Part 07
  ch.04](../07-delivery/04-gitops-argocd.md)) scoping each team's repos and
  destinations. The Bookstore is *single-tenant, multi-env*. The multi-tenant
  extension is *more tenants*, not *more overlays*. That structural difference
  drives RBAC, NetworkPolicy and GitOps layout.

## Production notes

> **In production: soft multi-tenancy is the default for trusted teams, and
> it's the stack you already run.** Per-team **namespace + RBAC +
> ResourceQuota + LimitRange + NetworkPolicy (default-deny) + PSA** is
> sufficient when tenants are teams in one org. Make it self-service and
> *consistent*. Use a **Capsule `Tenant`** (or an HNC hierarchy, or a templated
> `second-tenant.yaml` applied by GitOps) so every tenant gets the *identical*
> guardrail set with no per-tenant drift. Add **one AppProject per team**
> ([Part 07 ch.04](../07-delivery/04-gitops-argocd.md)) so a tenant can only
> deploy its own repo into its own namespace.

> **In production: protect the control plane, and watch it per tenant.**
> ResourceQuota, LimitRange and PriorityClass bound *compute*. They do nothing
> for a tenant flooding the **API server**, which is why API Priority &
> Fairness is in the body above. Pair it with per-tenant apiserver and etcd
> request-rate dashboards ([Part 06
> ch.01](../06-production-readiness/01-observability-metrics.md)).

> **In production: attribute cost per tenant, or the model fails financially.**
> Multi-tenancy without **cost attribution** is a subsidy and an argument
> waiting to happen. Label every namespace with the tenant
> (`second-tenant.yaml` sets `tenant: acme`) and run **OpenCost/Kubecost**
> ([Part 06 ch.06](../06-production-readiness/06-capacity-and-cost.md)) to
> split shared-cluster cost by namespace or label. Quotas then map to
> **budgets**, and the chargeback conversation runs on data, not opinion.

## Quick Reference

```sh
# Inspect a namespace's tenancy guardrail stack (the soft-tenancy control set)
kubectl describe resourcequota,limitrange -n <NS>             # fairness
kubectl get serviceaccounts,role,rolebinding -n <NS>          # authz scope
kubectl auth can-i --list --as=system:serviceaccount:<NS>:<SA> -n <NS>
kubectl get networkpolicy -n <NS>                             # default-deny?
kubectl get ns <NS> -o jsonpath='{.metadata.labels}'          # PSA labels

# Add a tenant: its OWN full stack, from the one file every tenant copies
kubectl apply --dry-run=client -f examples/bookstore/operators/second-tenant.yaml
kubectl apply -f examples/bookstore/operators/second-tenant.yaml

# Prove isolation (and its limit)
kubectl auth can-i create deployments \
  --as=system:serviceaccount:tenant-acme:acme-deployer -n bookstore   # no
kubectl get nodes      # SHARED kernel/nodes: the soft limit (hostile needs more)
```

The per-tenant shape is the one in `second-tenant.yaml`: a namespace with its
PSA labels, then a ResourceQuota, a LimitRange, a ServiceAccount, a namespaced
Role with its RoleBinding, and the default-deny NetworkPolicies. Copy the file
and rename the namespace. Do not hand-write a fresh stack per tenant.

Checklist:

- [ ] Recognise the namespace as a **soft** boundary: it isolates names, RBAC,
      quota, network and pod-security, **not** the kernel, the nodes,
      cluster-scoped objects or the apiserver
- [ ] Every tenant gets the **full stack** (ns + RBAC + ResourceQuota +
      LimitRange + NetworkPolicy default-deny + PSA), *consistently*
      (Capsule/HNC/GitOps templated, not hand-rolled per tenant)
- [ ] **Envs are not tenants**: dev/staging/prod are overlays of one app (same
      owner); tenants are separate namespaces with **one AppProject per team**
- [ ] Tenants **cannot mint their own quota or LimitRange** (capacity is
      platform-managed); RBAC is **namespaced**, not ClusterRole
- [ ] Hostile tenants need **node isolation, a sandboxed runtime, vCluster or
      separate clusters**; protect the apiserver with **API Priority & Fairness**
- [ ] **Cost attributed per tenant** (namespace label + OpenCost/Kubecost) so
      quota maps to budget ([Part 06 ch.06](../06-production-readiness/06-capacity-and-cost.md))
- [ ] `second-tenant.yaml` (pod-free) **dry-runs clean** with no CRD caveat and
      is **purely additive** (the `bookstore` ns is untouched)

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **The slogan "a namespace isolates tenants" is wrong in important ways. List four things a namespace does NOT isolate.**
   <details><summary>Show answer</summary>

   (1) The **kernel**: a container escape on a shared node crosses namespace boundaries. (2) The **nodes**: two tenants' Pods can co-tenant a node and compete for CPU and I/O. (3) **Cluster-scoped objects**: CRDs, PriorityClasses, ClusterRoles, the API server itself. (4) **API server QPS and control-plane resources**: a noisy tenant can saturate the apiserver. A namespace isolates *names*, *RBAC*, *quota*, and *policy attachment points*, and nothing physical. Soft tenancy is "trusted teams plus guardrails"; for hostile tenants you need more. See Mental model.

   </details>

2. **A team says "we're already multi-tenant: we have dev, staging, and prod namespaces." Explain why that's confusing two different things.**
   <details><summary>Show answer</summary>

   dev/staging/prod are **environments of one app** (same owner, same code, different config). They belong to **one tenant** and are correctly handled by Kustomize overlays of one base, or by Helm `values-<env>.yaml`. **Tenants** are *different owners*, such as team A's payments and team B's catalog. They need separate RBAC, quotas, NetworkPolicies, AppProjects and cost attribution. Conflating them produces either over-isolated envs (slow promotion) or dangerously under-isolated tenants (one team's bug evicts another's pods). The structural difference is "who owns this", not "what stage is this in".

   </details>

3. **You're told "make team Acme a tenant in our shared cluster." Walk through the six-element guardrail stack you'd apply.**
   <details><summary>Show answer</summary>

   (1) **Namespace** `tenant-acme` (the scope). (2) **RBAC**: a namespaced `Role` and `RoleBinding` for Acme's group, with no ClusterRoles. (3) **ResourceQuota**: Acme's *total* CPU, memory and pod budget. (4) **LimitRange**: per-container default, min and max, so a bad Pod can't claim the whole quota. (5) **NetworkPolicy default-deny**, plus only the intended Ingress and Egress rules. (6) **PSA `enforce: restricted`** on the namespace. In production, add one Argo AppProject per tenant and a cost label (`tenant: acme`) so OpenCost can charge back. The Bookstore namespace runs all six already. It is a one-tenant instance of this pattern.

   </details>

4. **Hands-on extension: verify cross-tenant isolation. Apply `second-tenant.yaml`. Then try `kubectl auth can-i create deployments --as=system:serviceaccount:tenant-acme:acme-deployer -n bookstore`. What does it return, and what command verifies the limit?**
   <details><summary>What you should see</summary>

   `no`. `acme-deployer` is bound only to a `Role` in `tenant-acme`, and Roles are namespaced, so no permissions leak to `bookstore`. Now verify the *limit* of namespace tenancy: `kubectl get nodes --as=system:serviceaccount:tenant-acme:acme-deployer` fails with Forbidden. The API refuses it, which is the namespace doing its job. But Acme's Pods still run on the **same nodes** as Bookstore's. The namespace stops API access. Only **node isolation** (taints and affinity, or separate pools) stops co-tenancy. That is the soft-to-hard tenancy line.

   </details>

5. **A tenant escalates: "we don't trust the other teams; they could break out of containers and access our data." When do you move from soft to hard multi-tenancy, and what does that actually look like?**
   <details><summary>Show answer</summary>

   When you can't trust tenants not to attempt a container escape, the soft stack isn't enough. Hard tenancy adds **node isolation** (per-tenant node pools via taints and tolerations, or labels), and/or a **sandboxed runtime** (gVisor or Kata Containers, which put a user-space or VM kernel between the container and the host), and/or a **virtual control plane per tenant** (vCluster, where each tenant gets its own API server), and/or, the bluntest and safest option, **separate clusters per tenant**. The trade is operational cost against blast radius. Each step up the ladder costs more to run and to operate.

   </details>

## Further reading

- **Rosso et al., _Production Kubernetes_, ch.12, Multitenancy** (the
  primary reference: soft vs hard tenancy, the guardrail stack, where
  namespaces stop and node/control-plane isolation begins, and the operational
  trade-offs of shared clusters).
- **Ibryam & Huß, _Kubernetes Patterns_ 2e, *Access Control* (ch.26)** for the
  RBAC and identity lens underpinning per-tenant authorization (the "who can
  do what, where" half of tenant isolation).
- Official: namespaces
  <https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/>,
  the multi-tenancy concept
  <https://kubernetes.io/docs/concepts/security/multi-tenancy/>, resource
  quotas <https://kubernetes.io/docs/concepts/policy/resource-quotas/>, limit
  ranges <https://kubernetes.io/docs/concepts/policy/limit-range/>, and RBAC
  <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>.
