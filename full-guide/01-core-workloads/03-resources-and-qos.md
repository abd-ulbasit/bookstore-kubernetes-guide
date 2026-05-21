# 03 — Resources and QoS

> `requests` vs `limits`; why CPU is compressible (throttled) and memory is
> incompressible (OOMKilled); the three QoS classes and the node eviction
> order; `LimitRange` and `ResourceQuota` — applied by giving every Bookstore
> service a resource footprint and introducing the `bookstore` namespace.

**Estimated time:** ~15 min read · ~30 min hands-on
**Prerequisites:** [Part 01 ch.01](01-pods.md) — the PodSpec where requests/limits live · [Part 00 ch.05](../00-foundations/05-node-components.md) — kubelet enforces them
**You'll know after this:** • distinguish `requests` (scheduling) from `limits` (enforcement) for CPU and memory · • explain why CPU is throttled and memory triggers OOMKill · • map a workload to its QoS class (Guaranteed/Burstable/BestEffort) and predict eviction order · • apply `LimitRange` defaults and `ResourceQuota` caps at the namespace level · • size every Bookstore service with appropriate requests and limits

<!-- tags: core-objects, resources, requests-limits, qos, limitrange, resourcequota -->

## Why this exists

So far the catalog Pod declares *no* resources. On a one-Pod laptop cluster that
is invisible; in production it is a time bomb. The scheduler
([Part 00 ch.04](../00-foundations/04-control-plane-deep-dive.md)) decides which
node a Pod fits on **using its declared requests** — a Pod with no requests is
treated as needing ~nothing and can be packed onto a node that then has no real
capacity for it. The kubelet enforces **limits** — a container with no memory
limit can consume the whole node and take its neighbors down with it. And when
a node runs out of memory, Kubernetes must choose *which* Pods to kill first;
that decision is driven entirely by the requests/limits you set (your **QoS
class**).

In short: requests/limits are how you state a workload's needs so the system
can place it safely, isolate it from noisy neighbors, and make principled
choices under pressure. This is the [Predictable Demands](#further-reading)
pattern — declare what you need rather than hope. It also forces the first
**multi-tenancy boundary**: a `Namespace` with a `ResourceQuota` and
`LimitRange`, which is where the Bookstore stops being one loose Pod and becomes
a bounded application.

## Mental model

Two numbers per resource, per container, with very different jobs:

- **`requests`** = *scheduling* and *guarantee*. "Reserve at least this much."
  The scheduler sums requests to decide if a Pod fits a node; the Pod is
  guaranteed this amount.
- **`limits`** = *enforcement ceiling*. "You may never exceed this." How a
  ceiling is enforced depends on whether the resource is **compressible**:
  - **CPU is compressible** → exceeding the CPU limit doesn't kill anything; the
    kernel **throttles** the container (it just runs slower). Annoying, not
    fatal.
  - **Memory is incompressible** → you can't "use memory more slowly". Exceed
    the memory limit and the kernel **OOM-kills** the container (`OOMKilled`,
    then restart per `restartPolicy`). Fatal.

From the gap between requests and limits, Kubernetes derives a **QoS class** per
Pod (`Guaranteed` > `Burstable` > `BestEffort`) that decides **eviction order**
when a node is under resource pressure: BestEffort dies first, then Burstable
exceeding its requests, Guaranteed last. So "set good requests/limits" really
means "choose how the system treats this workload when things go wrong".

## Diagrams

### QoS-class decision tree (Mermaid)

```mermaid
flowchart TD
    start([For a Pod, look at every container]) --> q1{Does EVERY container set<br/>BOTH cpu+memory<br/>requests AND limits?}
    q1 -- no --> q2{Does ANY container set<br/>any request OR limit?}
    q1 -- yes --> q3{For every container,<br/>requests == limits<br/>(cpu AND memory)?}
    q3 -- yes --> g[QoS = Guaranteed<br/>evicted LAST · most stable]
    q3 -- no --> b
    q2 -- yes --> b[QoS = Burstable<br/>evicted after BestEffort,<br/>esp. if above requests]
    q2 -- no --> be[QoS = BestEffort<br/>no requests/limits at all<br/>evicted FIRST · least stable]
```

### Node allocatable vs. requests vs. limits (ASCII)

```
Node capacity            = what the machine physically has
  − kube/system reserved = kubelet, runtime, OS daemons
  = Allocatable          = what Pods may actually be scheduled into
 ┌──────────────────────────────── Allocatable memory ───────────────────────────────┐
 │ catalog req │ orders req │ storefront req │  ... unreserved (free for scheduling)  │
 │■■■■■■■■■■■■■│■■■■■■■■■■■■│■■■■■■■■■■■■■■■■│                                       │
 └─────────────┴────────────┴────────────────┴───────────────────────────────────────┘
   scheduler admits a Pod only if Σ(requests on the node) + new request ≤ Allocatable
   (it sums REQUESTS, never limits — limits may oversubscribe the node deliberately)

   A single container's view:
     0 ───── request (guaranteed, used for scheduling) ───── limit (hard ceiling) ──►
                         │                                        │
            below req: always fine            above limit:  CPU → THROTTLED
            req..limit:  "burst", reclaimable                memory → OOMKilled
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).**

This chapter makes two cumulative changes:

1. **Introduce the `bookstore` Namespace** with a `ResourceQuota` and
   `LimitRange` — the application's resource boundary.
2. Give the catalog Pod **requests and limits** (and define footprints for the
   other services for when they arrive in later chapters).

### 1. Create the namespace, quota, and limit range

New file
[`examples/bookstore/raw-manifests/00-namespace.yaml`](../examples/bookstore/raw-manifests/00-namespace.yaml):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: bookstore
  labels:
    app.kubernetes.io/part-of: bookstore
---
apiVersion: v1
kind: ResourceQuota                 # caps TOTAL requests/limits in the namespace
metadata:
  name: bookstore-quota
  namespace: bookstore
spec:
  hard:
    requests.cpu: "2"               # sum of all container cpu requests ≤ 2 cores
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "30"
---
apiVersion: v1
kind: LimitRange                    # per-CONTAINER defaults + bounds
metadata:
  name: bookstore-limits
  namespace: bookstore
spec:
  limits:
    - type: Container
      default:                      # applied as `limits` if a container omits them
        cpu: 500m
        memory: 256Mi
      defaultRequest:               # applied as `requests` if omitted
        cpu: 100m
        memory: 128Mi
      max: { cpu: "2", memory: 1Gi }      # a container may not exceed these
      min: { cpu: 10m, memory: 16Mi }     # nor request less than these
```

`ResourceQuota` bounds the **namespace total**; `LimitRange` bounds **each
container** and supplies defaults so a container that forgets requests/limits
doesn't become `BestEffort` by accident. (Note: with a `requests.*`/`limits.*`
quota in force, the API server *requires* every container to have the
corresponding request/limit — the `LimitRange` defaults are what make that
ergonomic instead of a wall of rejections.)

```sh
# from the repo root (full-guide/)
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
kubectl describe resourcequota bookstore-quota -n bookstore
kubectl describe limitrange    bookstore-limits -n bookstore
```

> **Namespace migration (read this once).** From here on the Bookstore lives in
> the **`bookstore`** namespace. The Part 00 / ch.01 / ch.02 single Pod files
> (`01-catalog-pod.yaml`, `02-catalog-pod-sidecar.yaml`) intentionally have **no
> namespace** — they were teaching the object model in `default`. They are
> **kept as-is** (they are frozen teaching snapshots; don't edit them). Starting
> with [ch.04](04-replicasets-and-deployments.md) the catalog/storefront
> manifests are **born in `bookstore`** as Deployments. So the lineage is:
> *bare Pod (default) → Pod+sidecar+probes (default) → **Deployment in
> `bookstore`** with all those settings carried forward*. Nothing is deleted;
> each file shows one step.

### 2. Add requests and limits to the catalog container

The increment this chapter adds to the catalog container (the namespaced form
lands in ch.04's Deployment; here we show the block and reason about QoS):

```yaml
    - name: catalog
      image: bookstore/catalog:dev
      # ... ports / env / probes from ch.02 ...
      resources:
        requests:                   # scheduler reserves this; guaranteed
          cpu: 50m                  # 0.05 core: the Go API is light at rest
          memory: 64Mi
        limits:                     # hard ceiling
          cpu: 250m                 # may burst to 0.25 core, then THROTTLED
          memory: 128Mi             # exceed → OOMKilled (incompressible)
```

This makes the catalog Pod **Burstable** (requests set, limits set, but
`requests != limits`). To make it **Guaranteed** instead you would set
`requests == limits` for both cpu and memory — maximum stability, zero burst
headroom, lowest packing density. The Bookstore deliberately uses Burstable for
stateless APIs (cheap, can absorb spikes) and we will make **Postgres**
([ch.05](05-statefulsets.md)) closer to Guaranteed (stateful, must not be
evicted casually).

### 3. Observe QoS and quota accounting

```sh
# Once the Deployment in ch.04 is applied into the namespace:
kubectl get pod -n bookstore -l app=catalog \
  -o jsonpath='{.items[0].status.qosClass}{"\n"}'        # Burstable
kubectl describe resourcequota bookstore-quota -n bookstore
#   Used vs Hard: requests.cpu / requests.memory climb as Pods are admitted;
#   a Pod that would push the total over Hard is REJECTED at admission time.
```

You can also *see* the kernel enforcement model: a container that allocates past
its **memory** limit shows `reason: OOMKilled` in
`kubectl describe pod`; one that exceeds its **CPU** limit never gets killed —
it just accrues CPU throttling (visible in metrics in
[Part 06 ch.01](../06-production-readiness/01-observability-metrics.md)).

## How it works under the hood

- **`requests` drive scheduling; `limits` drive cgroups.** The scheduler's
  `NodeResourcesFit` predicate admits a Pod only if `Σ requests` on the node
  (plus the new Pod's) ≤ the node's **Allocatable** (capacity minus
  kube/system reserved). It **never sums limits** — limits may intentionally
  oversubscribe a node. The kubelet then writes the container's `limits` into
  its **cgroup** (`cpu.max` / `memory.max` on cgroup v2): the *kernel*, not
  Kubernetes, enforces them at runtime.
- **CPU = CFS bandwidth throttling.** A CPU limit becomes a CFS quota/period.
  Exceed it within a period and the kernel **deschedules** the container until
  the next period — pure slowdown, no kill. CPU `requests` become cgroup CPU
  **shares** (relative weight) so under contention each container gets at least
  its proportional share. This is why CPU is "compressible".
- **Memory = hard cgroup cap → OOM killer.** A memory limit is a hard cgroup
  bound. The kernel cannot make a process "use less memory gradually", so on
  breach the cgroup OOM killer terminates the process; the kubelet records
  `OOMKilled` and restarts per `restartPolicy`. "Incompressible".
- **QoS is computed, not declared.** The kubelet derives the class from the
  request/limit pattern: **Guaranteed** (every container has cpu+mem and
  request==limit), **Burstable** (at least one request/limit, not all equal),
  **BestEffort** (none at all). Under **node memory pressure** the kubelet
  evicts in order: BestEffort first → then Burstable Pods *most over their
  requests* (ranked by usage above request) → Guaranteed last (and even then
  only if it must). The kernel OOM score is also skewed by QoS, so even raw OOM
  kills prefer lower-QoS containers.
- **`LimitRange` is a mutating + validating admission step.** When a Pod is
  created in the namespace, the LimitRange admission plugin **injects**
  `default`/`defaultRequest` for any missing field and **rejects** Pods
  violating `min`/`max`. **`ResourceQuota`** is a validating admission step that
  rejects creation if it would push the namespace's tracked totals over `hard`
  (and requires the relevant request/limit to be set so it can be counted).
  Both run in the API server admission pipeline from
  [Part 00 ch.04](../00-foundations/04-control-plane-deep-dive.md).

## Production notes

> **In production:** **always set memory `requests` and `limits`** on every
> container, and set memory `request == limit` for anything you cannot tolerate
> being OOM-killed under contention. An unbounded-memory container is the single
> most common cause of a node-wide cascading failure (it OOMs neighbors, not
> just itself).

> **In production:** be cautious with **CPU limits**. CPU `requests` guarantee a
> share; tight CPU *limits* cause CFS throttling that shows up as mysterious
> p99 latency even when average CPU looks low. A common pattern is: set CPU
> `requests` accurately, set memory `requests==limits`, and set the CPU `limit`
> generously or omit it (rely on requests + autoscaling). Measure throttling
> before tightening.

> **In production:** never run important workloads as **BestEffort**. They are
> the first thing killed under pressure and the scheduler assumes they need
> nothing, so it overpacks their node. BestEffort is acceptable only for truly
> sacrificial batch work.

> **In production:** put a **`ResourceQuota` + `LimitRange` on every tenant
> namespace** ([Part 08 ch.04](../08-day-2-operations/04-multi-tenancy-and-namespaces.md)).
> Quota prevents one team exhausting the cluster; LimitRange guarantees no
> container is accidentally BestEffort or absurdly large. On EKS/GKE/AKS this
> also bounds **cost**, since cluster-autoscaler provisions nodes to satisfy
> requests — sloppy requests directly inflate the bill
> ([Part 06 ch.06](../06-production-readiness/06-capacity-and-cost.md)).

> **In production:** right-size from real data, don't guess. The
> **VerticalPodAutoscaler** in recommendation mode and historical metrics give
> requests grounded in actual usage
> ([Part 06 ch.04](../06-production-readiness/04-autoscaling.md)). Over-requesting
> wastes money; under-requesting causes evictions and throttling.

## Quick Reference

```sh
kubectl get pod <P> -o jsonpath='{.status.qosClass}'        # Guaranteed/Burstable/BestEffort
kubectl describe node <NODE> | sed -n '/Allocated resources/,/Events/p'
kubectl describe resourcequota -n <NS>                       # Used vs Hard
kubectl describe limitrange   -n <NS>                        # defaults + min/max
kubectl top pod  -n <NS>                                     # live usage (needs metrics-server)
kubectl get pod <P> -o jsonpath='{.status.containerStatuses[*].lastState}'  # OOMKilled?
```

Minimal resources block + namespace governance:

```yaml
# per container
resources:
  requests: { cpu: 50m,  memory: 64Mi }   # scheduling + guarantee
  limits:   { cpu: 250m, memory: 128Mi }  # ceiling (cpu→throttle, mem→OOMKill)
---
apiVersion: v1
kind: ResourceQuota
metadata: { name: q, namespace: <NS> }
spec: { hard: { requests.cpu: "2", requests.memory: 2Gi, limits.cpu: "4", limits.memory: 4Gi } }
---
apiVersion: v1
kind: LimitRange
metadata: { name: lr, namespace: <NS> }
spec:
  limits:
    - type: Container
      default:        { cpu: 500m, memory: 256Mi }
      defaultRequest: { cpu: 100m, memory: 128Mi }
```

Checklist:

- [ ] Every container sets memory `requests` **and** `limits`
- [ ] CPU `requests` set accurately; CPU `limits` deliberate (throttling-aware)
- [ ] Intended QoS chosen (Guaranteed for must-not-evict, Burstable for APIs)
- [ ] No accidental BestEffort for anything that matters
- [ ] Tenant namespace has a `ResourceQuota` and a `LimitRange`
- [ ] Requests derived from measured usage, not guessed

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **Why does the scheduler sum `requests` to admit a Pod onto a node, but never `limits`? What property of CPU vs. memory makes this design correct?**
   <details><summary>Show answer</summary>

   `requests` are guarantees the scheduler must respect (the workload was promised that much); `limits` are ceilings the kernel enforces and may legitimately be oversubscribed because most workloads burst rarely. CPU is compressible (throttled, not killed) so oversubscription is graceful; memory's hard limit triggers OOM on breach. Summing limits would massively under-pack nodes for no benefit (see §How it works under the hood, "requests drive scheduling; limits drive cgroups").

   </details>

2. **You see a service with healthy average CPU at 40% suddenly developing p99 latency spikes. Memory is fine. What's the prime suspect, and where do you look?**
   <details><summary>Show answer</summary>

   CPU CFS throttling: the CPU `limit` is being hit in short bursts, so the kernel deschedules the container until the next period — average looks low while p99 craters. Check `container_cpu_cfs_throttled_seconds_total` / `_periods_total` (Prometheus). The common fix is to widen or remove the CPU limit (keep CPU `requests` accurate for scheduling) — see §Production notes, "be cautious with CPU limits".

   </details>

3. **A teammate sets `requests: { memory: 256Mi }` and `limits: { memory: 256Mi }` on a critical Pod "for stability". What QoS class does that produce, and what's the trade-off compared with `requests: 128Mi, limits: 256Mi`?**
   <details><summary>Show answer</summary>

   `requests == limits` for both cpu and memory produces **Guaranteed** QoS — evicted last under node pressure, maximum stability. The trade-off is lower packing density: the scheduler reserves the full 256Mi (rather than 128Mi), so fewer Pods fit per node and you pay for unused headroom. Burstable (128/256) is cheaper but evicted sooner if it goes above its 128Mi request (see §QoS-class decision tree and §How it works under the hood).

   </details>

4. **A namespace has a `ResourceQuota` with `requests.cpu: "2"` but no `LimitRange`. A teammate's Pod with no resource requests is rejected. Why, and how does adding a `LimitRange` fix it without weakening the cap?**
   <details><summary>Show answer</summary>

   When a `requests.cpu` quota exists, the API server requires every container to *have* a CPU request (otherwise the quota can't count it). A Pod missing requests is rejected at admission. A `LimitRange` with `defaultRequest.cpu` injects sensible defaults at admission so the Pod gets a request without forcing every author to set one — the quota still caps the namespace total (see §1. Create the namespace, quota, and limit range).

   </details>

5. **Hands-on extension: in the `bookstore` namespace, deploy a Pod that requests 1.5Gi memory when the quota is 2Gi `requests.memory` and 1Gi container `max`. What's rejected and what is the error message you should expect?**
   <details><summary>What you should see</summary>

   The Pod is rejected at admission with `forbidden: maximum memory usage per Container is 1Gi, but request is 1536Mi` — the `LimitRange` `max` is enforced *before* the quota even gets to count it. If you instead requested 800Mi but the namespace already had 1.5Gi reserved (cumulative), the quota would reject with `exceeded quota: bookstore-quota, requested: requests.memory=800Mi, used: requests.memory=1.5Gi, limited: requests.memory=2Gi`. Both are admission-time, before any Pod exists (see §How it works under the hood, "LimitRange is mutating + validating admission").

   </details>

## Further reading

- **Lukša, _Kubernetes in Action_ 2e, ch.20 — resource management** (requests/
  limits, QoS, eviction) — paired with the official resource-management docs.
- **Ibryam & Huß, _Kubernetes Patterns_ 2e — *Predictable Demands* (ch.2)** —
  why declaring explicit resource needs is foundational to scheduling, density,
  and reliability.
- Official:
  <https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/>
  and
  <https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/>
  (QoS) and
  <https://kubernetes.io/docs/concepts/policy/resource-quotas/>.
