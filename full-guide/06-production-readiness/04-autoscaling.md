# 04 — Autoscaling

> **HPA v2** in depth (metric types Resource/ContainerResource/Pods/Object/
> External, the `ceil(current·curMetric/targetMetric)` algorithm,
> stabilization/behavior/tolerance), **VPA** (recommender/updater/admission;
> modes; the HPA-conflict), **Cluster Autoscaler vs Karpenter** (node scaling),
> and **KEDA** (event-driven, wraps an HPA, scale-to-zero) — applied by adding
> the **payments-worker** Deployment, an HPA on catalog, and a KEDA
> ScaledObject scaling payments-worker on RabbitMQ queue depth.

**Estimated time:** ~30 min read · ~90 min hands-on
**Prerequisites:** [Part 01 ch.03](../01-core-workloads/03-resources-and-qos.md) — requests/limits feed HPA & VPA · [Part 06 ch.01](01-observability-metrics.md) — metrics-server and custom metrics are the HPA's input · [Part 04 ch.01](../04-scheduling/01-scheduler-and-nodes.md) — node scaling is *which* nodes the scheduler can use
**You'll know after this:** • derive HPA replica counts from `ceil(current·curMetric/targetMetric)` and tune behavior/stabilization · • choose between HPA, VPA, Cluster Autoscaler, Karpenter and KEDA for a workload · • avoid the HPA + VPA conflict and use VPA in recommender mode safely · • write a KEDA ScaledObject for RabbitMQ queue depth with scale-to-zero · • add payments-worker, an HPA on catalog and queue-driven scaling to the Bookstore

<!-- tags: autoscaling, observability, finops, day-2 -->

## Why this exists

The Bookstore has fixed replica counts: catalog 3, orders 2, payments-worker
soon. A fixed count is wrong **both ways**. Under a traffic spike (a sale),
3 catalog Pods saturate and latency/errors climb — the
[ch.01](01-observability-metrics.md) RED signals go red. At 3am with no
traffic, those same Pods sit idle burning cluster capacity you pay for
([ch.06](06-capacity-and-cost.md)). And the queue consumer is worse: when no
orders flow, a running payments-worker does nothing but cost money; when a
flood of orders hits, one consumer cannot drain the queue and payments lag.

Autoscaling makes capacity **track demand**: more Pods when busy, fewer (or
**zero**) when idle, and more **nodes** when the Pods don't fit. This is the
[Elastic Scale](#further-reading) pattern. It has three independent layers
that must be understood separately: scale the **Pods** of a workload (HPA /
VPA / KEDA), and scale the **nodes** of the cluster (Cluster Autoscaler /
Karpenter). They compose; they do not substitute.

## Mental model

Four mechanisms, four jobs:

- **HorizontalPodAutoscaler (HPA)** — *more/fewer replicas* of a workload
  based on a metric. A control loop: observe a metric, compute a desired
  replica count, patch `.spec.replicas`. The default for stateless,
  request-serving services (catalog). GA at `autoscaling/v2`.
- **VerticalPodAutoscaler (VPA)** — *bigger/smaller requests* for a
  workload's containers based on observed usage. Right-sizes one Pod rather
  than adding Pods. An add-on (not built-in). Its **recommendation mode** is
  the sizing tool for [ch.06](06-capacity-and-cost.md).
- **KEDA** — *event-driven* horizontal scaling, including **to zero**, on
  external signals (queue length, stream lag, cron, …). KEDA does **not
  replace the HPA — it creates and drives one**, adding scale-from/to-zero
  and dozens of scalers. The right tool for the payments-worker (scale on
  RabbitMQ queue depth).
- **Cluster Autoscaler / Karpenter** — *more/fewer nodes*. When HPA/KEDA
  create Pods that don't fit, the cluster autoscaler adds nodes; when nodes
  are underused it removes them. **Cluster Autoscaler** grows fixed node
  groups; **Karpenter** provisions right-sized nodes just-in-time from
  instance-type flexibility.

The HPA algorithm — memorise it, it explains every behaviour:

```
desiredReplicas = ceil[ currentReplicas × (currentMetricValue / targetMetricValue) ]
```

evaluated **per metric**; with multiple metrics the HPA computes a desired
count for each and uses the **maximum** (never the sum — it scales for the
most-stressed dimension). A **tolerance** (default 10%) suppresses scaling
when the ratio is within ±10% of 1.0 (no thrashing around the target). KEDA's
managed HPA runs this *same* formula on the queue-length metric.

## Diagrams

### The HPA control loop (Mermaid)

```mermaid
flowchart TD
    ms["metrics source<br/>metrics-server (Resource)<br/>/ custom / external adapter"]
    hpa["HPA controller<br/>(every ~15s)"]
    calc["desired = ceil(current x<br/>curMetric / targetMetric)<br/>per metric -> take MAX"]
    tol{"within tolerance<br/>(±10%)?"}
    beh["apply behavior:<br/>stabilization window<br/>+ scale policies"]
    scale["patch Deployment<br/>.spec.replicas"]
    rs["ReplicaSet adds/removes<br/>Pods -> scheduler places"]

    ms --> hpa --> calc --> tol
    tol -- yes --> hpa
    tol -- no --> beh --> scale --> rs
    rs -. "new metric reading" .-> ms
```

### KEDA: RabbitMQ queue depth → ScaledObject → managed HPA → payments-worker (Mermaid)

```mermaid
flowchart LR
    ord["orders Pods<br/>publish to queue"]
    mq["RabbitMQ<br/>'orders' queue (depth N)"]
    keda["KEDA operator<br/>+ metrics adapter"]
    so["ScaledObject<br/>(83-): trigger rabbitmq<br/>value=20, min=0 max=10"]
    hpa["managed HPA<br/>(KEDA creates it)"]
    pw["payments-worker<br/>Deployment (19-)"]

    ord --> mq
    so --> keda
    keda -->|reads queue depth N| mq
    keda -->|feeds external metric| hpa
    hpa -->|"ceil(replicas x N/20)"| pw
    keda -->|"N==0 for cooldown -> scale to 0;<br/>N>=1 -> scale 0->1"| pw
    pw -->|consume, drain| mq
```

### Which autoscaler for what (ASCII)

```
 LAYER         SCALES        TRIGGER                  BOOKSTORE USE
 ─────────────────────────────────────────────────────────────────────────────
 HPA           replicas      CPU / mem / custom /     catalog (CPU + req/s)
                             external metric          orders (CPU) — optional
 VPA           requests      observed usage history   sizing tool, ch.06
                             (recommend | auto)       (recommend mode on catalog)
 KEDA          replicas      events: queue len,       payments-worker
               (incl. 0)     stream lag, cron, ...    (RabbitMQ queue depth)
 Cluster       nodes         unschedulable Pods /     conceptual (cloud);
  Autoscaler                 underused nodes          kind has fixed nodes
 Karpenter     nodes         unschedulable Pods ->    conceptual (AWS); JIT,
                             just-in-time right-size  instance-type flexible

 RULE: HPA and VPA must NOT both act on the SAME resource metric (they fight).
       HPA scales out; VPA(recommend) sizes; CA/Karpenter add nodes for them.
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).**

We will: (1) add the **payments-worker** Deployment (its first manifest); (2)
add an **HPA** on catalog; (3) install **KEDA** and add a **ScaledObject**
scaling payments-worker on RabbitMQ queue depth; (4) load-test both with a
restricted-compliant public-image generator.

### 0. Prerequisites (self-bootstrapping)

Bring up the cluster + Bookstore as in
[ch.01 step 0](01-observability-metrics.md) **including metrics-server**
(the HPA's CPU metric needs it). Also apply the async backends:

```sh
kubectl apply -f examples/bookstore/raw-manifests/13-rabbitmq.yaml
kubectl rollout status deployment/rabbitmq -n bookstore
# (metrics-server install: ch.01 step 1 — required for the HPA CPU metric.)
```

### 1. Add the payments-worker Deployment

The worker has had source (`app/payments-worker/main.go`) since Part 00 but no
manifest — KEDA needs a real Deployment to scale. New files:

- A dedicated **`payments-worker-sa`** added to
  [`examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml`](../examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml)
  (`automountServiceAccountToken: false`, **no** Role/RoleBinding — the worker
  never calls the API; same posture as `orders-sa`).
- [`examples/bookstore/raw-manifests/19-payments-worker-deploy.yaml`](../examples/bookstore/raw-manifests/19-payments-worker-deploy.yaml)
  — the Deployment. Shape (full restricted SC like catalog, `AMQP_URL` →
  rabbitmq Service, scheduling layer consistent with siblings):

```yaml
# (excerpt — condensed for the chapter; the authoritative full spec, incl.
#  probe tuning fields, is examples/bookstore/raw-manifests/19-payments-worker-deploy.yaml)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-worker
  namespace: bookstore
  labels: { app: payments-worker, component: worker, app.kubernetes.io/part-of: bookstore }
spec:
  replicas: 1                       # resting state; KEDA (83-) OWNS the count
  selector: { matchLabels: { app: payments-worker } }
  template:
    metadata:
      labels: { app: payments-worker, component: worker }
    spec:
      serviceAccountName: payments-worker-sa
      automountServiceAccountToken: false
      securityContext:              # PSA restricted (pod) — same as catalog 10-
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile: { type: RuntimeDefault }
      priorityClassName: bookstore-critical          # checkout path: above batch
      topologySpreadConstraints:                     # spread KEDA-scaled replicas
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway          # availability > strict spread
          labelSelector: { matchLabels: { app: payments-worker } }
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector: { matchLabels: { app: payments-worker } }
      containers:
        - name: payments-worker
          image: bookstore/payments-worker:dev
          imagePullPolicy: IfNotPresent
          securityContext:          # PSA restricted (container)
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          ports: [{ name: metrics, containerPort: 8080 }]   # /healthz + /metrics
          env:
            - { name: PORT, value: "8080" }
            - { name: LOG_LEVEL, value: "info" }
            - name: AMQP_URL                                # the async edge
              value: "amqp://guest:guest@rabbitmq.bookstore.svc.cluster.local:5672/"
          # Only /healthz exists (a consumer has no /readyz); ALL THREE probes
          # use it (full failureThreshold/timeout tuning is in the saved 19-).
          startupProbe:   { httpGet: { path: /healthz, port: metrics }, periodSeconds: 5, failureThreshold: 30 }
          livenessProbe:  { httpGet: { path: /healthz, port: metrics }, periodSeconds: 10 }
          readinessProbe: { httpGet: { path: /healthz, port: metrics }, periodSeconds: 5 }
          lifecycle: { preStop: { sleep: { seconds: 5 } } }  # native; distroless-safe
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 250m, memory: 128Mi }
          volumeMounts: [{ name: tmp, mountPath: /tmp }]     # RO-rootfs scratch
      volumes: [{ name: tmp, emptyDir: { sizeLimit: 32Mi } }]
      terminationGracePeriodSeconds: 30
```

> **Decisions (documented in the manifest header).** *No DB_DSN* — the worker
> never touches Postgres (contrast catalog/orders). *Only `/healthz`* — a
> queue consumer has no inbound traffic and no `/readyz`
> (`app/payments-worker/main.go`); both probes hit `/healthz`, which answers
> iff the process and its consume loop are alive. *`topologySpread`
> `ScheduleAnyway`* (not `DoNotSchedule` like catalog/storefront) — a
> KEDA-scaled replica must never be left `Pending` for spread; draining the
> queue wins. *`replicas: 1`* is just the resting state — **KEDA owns the
> count**; do not also hand-write an HPA for it (two controllers fighting
> `.spec.replicas`). *A headless metrics-only Service* was added to
> [`40-services.yaml`](../examples/bookstore/raw-manifests/40-services.yaml)
> (`clusterIP: None`) so the [ch.01](01-observability-metrics.md)
> ServiceMonitor can scrape `payments_processed_total` — the worker takes no
> request traffic, so there is nothing to load-balance.

[`60-networkpolicy.yaml`](../examples/bookstore/raw-manifests/60-networkpolicy.yaml)
was extended (both-ends, additive): rule 6's rabbitmq **ingress** now also
admits `app: payments-worker`, and a new rule 9 grants payments-worker
**egress** to rabbitmq:5672 (DNS egress is the pre-existing rule 2, which
already selects every Pod). All 8 prior policies are otherwise unchanged.

```sh
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
kubectl apply -f examples/bookstore/raw-manifests/19-payments-worker-deploy.yaml
kubectl apply -f examples/bookstore/raw-manifests/40-services.yaml
kubectl apply -f examples/bookstore/raw-manifests/60-networkpolicy.yaml   # if a policy CNI runs
kubectl rollout status deployment/payments-worker -n bookstore
# The bookstore ns is enforce:restricted — this Pod is admitted with ZERO
# PodSecurity warnings (proven by a server-side dry-run; same method Part 05
# ch.02 used for catalog/orders).
```

### 2. An HPA on catalog (CPU + a custom req/s metric)

New file
[`examples/bookstore/raw-manifests/82-hpa-catalog.yaml`](../examples/bookstore/raw-manifests/82-hpa-catalog.yaml)
— a **built-in** `autoscaling/v2` object (no CRD; dry-runs cleanly):

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: catalog, namespace: bookstore }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: catalog }
  minReplicas: 2                    # user-facing: never below 2 (stay HA)
  maxReplicas: 6                    # bounded by the namespace ResourceQuota (00-)
  metrics:
    - type: Resource               # needs metrics-server (ch.01)
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
    - type: Pods                   # ILLUSTRATIVE: needs the Prometheus Adapter
      pods:
        metric: { name: http_requests_per_second }
        target: { type: AverageValue, averageValue: "50" }
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - { type: Percent, value: 100, periodSeconds: 60 }   # at most 2x …
        - { type: Pods,    value: 2,   periodSeconds: 60 }    # … or +2 Pods
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300   # scale IN slowly (anti-thrash)
      policies: [{ type: Percent, value: 50, periodSeconds: 60 }]
```

> **Honest about the second metric (as [ch.03](03-tracing.md) was about app
> instrumentation).** The **CPU** metric works with just metrics-server. The
> **Pods** custom metric (`http_requests_per_second`) requires the
> **Prometheus Adapter** to publish it through `custom.metrics.k8s.io` from
> the catalog metrics [ch.01](01-observability-metrics.md) already exports —
> without that adapter the HPA reports `<UNKNOWN>` for it and scales on CPU
> alone. The manifest header says so; it is included to show a real
> multi-metric HPA and the RED "Rate" signal as a scaling input.

```sh
kubectl apply -f examples/bookstore/raw-manifests/10-catalog-deploy.yaml   # the target
kubectl apply -f examples/bookstore/raw-manifests/82-hpa-catalog.yaml
kubectl get hpa catalog -n bookstore -w        # TARGETS shows current/target
kubectl describe hpa catalog -n bookstore      # per-metric values + events
```

### 3. KEDA: scale payments-worker on RabbitMQ queue depth

Install KEDA via its Helm chart into its **own** `keda` namespace (its own
namespace — not PSA-restricted; fine, exactly like the observability stacks in
[ch.01](01-observability-metrics.md)). Helm (not a raw
`releases/latest/download/<PINNED-FILE>.yaml` URL — that 404s the moment a
newer KEDA ships, since `latest/` resolves to the newest tag but the filename
is version-pinned) is the same install method this part uses for
metrics-server's add-on peers, kube-prometheus-stack, Loki, Alloy, Tempo and
the OTel Collector:

```sh
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda \
  --namespace keda --create-namespace --wait
kubectl -n keda rollout status deployment/keda-operator
```

New file
[`examples/bookstore/raw-manifests/83-keda-scaledobject.yaml`](../examples/bookstore/raw-manifests/83-keda-scaledobject.yaml)
(a Secret + `TriggerAuthentication` + `ScaledObject`). Core object:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: payments-worker, namespace: bookstore }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: payments-worker }
  pollingInterval: 15               # check queue depth every 15s
  cooldownPeriod: 60                # 60s idle before scaling to 0
  minReplicaCount: 0                # SCALE TO ZERO when the queue is empty
  maxReplicaCount: 10               # bounded by the namespace ResourceQuota (00-)
  triggers:
    - type: rabbitmq
      metadata:
        protocol: amqp              # read queue length over AMQP (5672)
        queueName: orders           # the queue orders publishes / worker consumes
        mode: QueueLength
        value: "20"                 # target msgs/replica -> desired=ceil(len/20)
        activationValue: "1"        # 0 -> 1 as soon as ≥1 message waits
      authenticationRef: { name: rabbitmq-trigger-auth }
```

> **KEDA wraps an HPA — see it.** `83-` does **not** contain an HPA, yet:
>
> ```sh
> kubectl apply -f examples/bookstore/raw-manifests/83-keda-scaledobject.yaml
> kubectl get scaledobject,hpa -n bookstore
> #   NAME ... scaledobject.keda.sh/payments-worker
> #   NAME ... horizontalpodautoscaler.../keda-hpa-payments-worker   <-- KEDA made this
> ```
>
> KEDA's operator created a managed HPA whose external metric is the live
> "orders" queue length; that HPA runs the **same** `ceil(replicas × len/value)` formula as the catalog HPA. The piece a plain HPA cannot do —
> 0↔1 — is done by KEDA itself (it patches the Deployment to 0 after
> `cooldownPeriod` of `queue ≤ activationValue`, and back to 1 the instant a
> message arrives).

> **CRD-backed — expected dry-run note.** `ScaledObject`/`TriggerAuthentication`
> are KEDA CRDs (`keda.sh/v1alpha1`). Without KEDA installed,
> `kubectl apply --dry-run=client -f 83-...` prints
> `no matches for kind "ScaledObject" in version "keda.sh/v1alpha1"` —
> **expected, not a defect**, exactly like the Gateway API
> ([Part 02 ch.05](../02-networking/05-gateway-api.md)) and Kyverno
> ([Part 05 ch.03](../05-security/03-supply-chain.md)) objects, and like
> `80-`/`81-` from [ch.01](01-observability-metrics.md). The `19-`
> Deployment and the `82-` HPA are built-ins and **do** dry-run cleanly.

### 4. Load-test both (restricted-compliant generator)

Drive catalog with HTTP and orders to fill the queue, from **public-image**
load generators. PSA `restricted` is satisfied via `--overrides` (pinned
`rakyll/hey` / `curlimages/curl`, both run fine non-root — pinned tags, never
`:latest`, per this guide's image policy).

**First, the catalog HPA (works as-is):**

```sh
# Hammer catalog -> CPU/req-rate rises -> the catalog HPA scales out (watch §2).
kubectl run hey -n bookstore --rm -it --restart=Never \
  --image=ghcr.io/rakyll/hey:0.1.4 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"hey","image":"ghcr.io/rakyll/hey:0.1.4","args":["-z","2m","-c","50","http://catalog.bookstore.svc.cluster.local/books"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}}]}}'
```

**Then KEDA — but enable order publishing FIRST (read this before flooding).**
The canonical
[`14-orders-deploy.yaml`](../examples/bookstore/raw-manifests/14-orders-deploy.yaml)
leaves `AMQP_URL` **unset** (Part-02 networking scaffolding), so orders
*silently drops* events and **nothing ever enqueues** — the flood below would
do nothing to the queue and KEDA would never scale. Point orders at the same
rabbitmq Service the worker uses (this is a **demo-only** env override on the
live Deployment, not an edit to `14-`; revert it afterwards):

```sh
# DEMO-ONLY: make orders actually publish to the 'orders' queue.
kubectl set env deployment/orders -n bookstore \
  AMQP_URL="amqp://guest:guest@rabbitmq.bookstore.svc.cluster.local:5672/"
kubectl rollout status deployment/orders -n bookstore
# now: flood orders -> the 'orders' queue grows -> KEDA scales payments-worker
#      from 0/1 up toward maxReplicaCount; watch it drain then scale back to 0.
kubectl run flood -n bookstore --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"flood","image":"curlimages/curl:8.10.1","command":["sh","-c","for i in $(seq 1 500); do curl -s -o /dev/null -XPOST http://orders.bookstore.svc.cluster.local/orders -d \"{\\\"book_id\\\":1,\\\"qty\\\":1}\"; done; echo done"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}}]}}'

watch kubectl get hpa,scaledobject,deploy/payments-worker,deploy/catalog -n bookstore

# Revert the demo-only change (restore the canonical AMQP_URL-unset behaviour):
kubectl set env deployment/orders -n bookstore AMQP_URL-
kubectl rollout status deployment/orders -n bookstore
```

(`14-` is intentionally left unchanged on disk — `AMQP_URL` arrives there
permanently in [Part 07](../07-delivery/01-packaging-helm.md) when the broker
gets real credentials; this chapter only flips it at runtime to demonstrate
the scaler, then reverts.)

## How it works under the hood

- **The HPA loop.** The `horizontal-pod-autoscaler` controller (in
  kube-controller-manager) reconciles each HPA every
  `--horizontal-pod-autoscaler-sync-period` (~15s): it reads each metric
  (Resource/ContainerResource from `metrics.k8s.io`; Pods/Object from
  `custom.metrics.k8s.io`; External from `external.metrics.k8s.io`), computes
  `ceil(currentReplicas × curMetric/targetMetric)` **per metric**, takes the
  **max**, applies **tolerance** (skip if within ±10% of target) and
  **behavior** (stabilization window = the max desired over the trailing
  window for scale-down; scale policies bound the step), then patches
  `scale.spec.replicas`. The Deployment's ReplicaSet does the rest. It needs
  a metrics API server registered or the metric reads as `<UNKNOWN>`.
- **Metric types.** `Resource` = utilization vs the container **request** (so
  request size changes the effective target — interacts with VPA);
  `ContainerResource` (GA 1.30) targets a *named container's* resource
  (avoids a sidecar skewing the Pod average); `Pods` = a per-pod average of a
  custom metric; `Object` = a single metric off one object; `External` = a
  metric with no Kubernetes object (queue length) — the type KEDA feeds.
- **VPA internals.** Three components: the **recommender** consumes history
  (from metrics-server/Prometheus) and computes target/lowerBound/upperBound
  requests; the **updater** evicts Pods whose requests are out of bounds; the
  **admission** webhook rewrites requests on (re)creation. Modes: `Off`
  (recommend only — *the sizing tool*, [ch.06](06-capacity-and-cost.md)),
  `Initial` (set on create only), `Auto`/`Recreate` (evict to resize — note:
  in-place resize is maturing but VPA classically restarts the Pod).
- **Why HPA + VPA on the same metric conflict.** HPA scales replicas on, say,
  CPU utilization; VPA in `Auto` rewrites the CPU **request**. But
  utilization *is* usage ÷ request — VPA changing the request moves the very
  denominator the HPA divides by, so they chase each other (oscillation).
  Supported combinations: HPA on CPU/mem **with** VPA in `Off` (recommend) —
  or HPA on a *custom/external* metric (e.g. req/s, queue depth) **with** VPA
  on CPU/mem (different signals). The Multidimensional Pod Autoscaler (GKE)
  and in-place resize aim to make this safer; the conflict rule still holds
  by default — hence the explicit warning in `82-`'s header.
- **KEDA = activation + a managed HPA.** The KEDA operator watches
  `ScaledObject`s. For each it (a) creates an HPA with an **External** metric
  served by KEDA's own metrics adapter (the live trigger value, e.g. queue
  length) — so 1→N scaling is *ordinary HPA math*; and (b) handles
  **activation**: while the trigger is inactive (`≤ activationValue` for
  `cooldownPeriod`) KEDA scales the Deployment to `minReplicaCount` (which can
  be **0**) and removes the HPA's lower bound; the first event reactivates it.
  An HPA alone can never reach or leave 0 — that 0↔1 edge is exactly KEDA's
  added value, and why a queue consumer (idle most of the night) is its
  canonical use case.
- **Node autoscaling closes the loop.** HPA/KEDA create Pods; if no node has
  room they stay `Pending`. **Cluster Autoscaler** watches for
  unschedulable Pods and grows a node group (and scale down nodes whose Pods
  can be safely moved, respecting PDBs — [ch.05](05-reliability-and-disruptions.md)).
  **Karpenter** instead provisions a *right-sized* node per the pending Pods'
  exact requests/constraints from a broad instance-type set (faster, less
  waste, no pre-defined groups). Both react to the **scheduler's** verdict
  ([Part 04 ch.01](../04-scheduling/01-scheduler-and-nodes.md)) — they are the
  node tier under the Pod tier.

## Production notes

> **In production:** HPA for stateless request services, **KEDA for
> event/queue consumers**. Sizing a queue worker by CPU is a lagging,
> wrong proxy — scale it by the **backlog** (queue length / lag). The
> Bookstore does exactly this: catalog→HPA(CPU+req/s), payments-worker→KEDA
> (RabbitMQ depth) with scale-to-zero so an idle consumer costs nothing
> ([ch.06](06-capacity-and-cost.md)).

> **In production:** **never run HPA and VPA on the same resource metric.**
> Use VPA in **recommendation** mode to *set* good requests
> ([ch.06](06-capacity-and-cost.md)) and HPA to *scale out* on
> CPU/custom/external — different jobs, different signals. Letting both
> rewrite/divide CPU produces replica + request oscillation.

> **In production:** tune **`behavior`** deliberately. The most common HPA
> failure is scaling **in** too aggressively (a brief dip drops replicas,
> the next spike has none, latency craters). Scale up fast, scale **down
> slow** (a long `scaleDown.stabilizationWindowSeconds`, as in `82-`).
> Always set `minReplicas ≥ 2` for anything user-facing — HA, not just load.

> **In production:** pick the node autoscaler for the platform. **EKS**:
> Cluster Autoscaler on managed node groups, or **Karpenter** (AWS-native,
> JIT right-sized nodes, spot-friendly — [ch.06](06-capacity-and-cost.md)).
> **GKE**: cluster autoscaler / node auto-provisioning (and the MPA for the
> HPA+VPA case). **AKS**: cluster autoscaler. Pod autoscaling (HPA/KEDA/VPA)
> is portable; the **node** layer is provider-specific. Size `maxReplicas`
> against the namespace **ResourceQuota** (Part 01 ch.03 / [ch.06](06-capacity-and-cost.md))
> so scaling can't exhaust the cluster or the bill.

> **In production:** the custom/external metrics path is real
> infrastructure. An HPA on req/s or queue depth needs the **Prometheus
> Adapter** or **KEDA** registered as a metrics API server, monitored like
> any other dependency — if the metrics API is down the HPA freezes at its
> last replica count (it does **not** scale to zero or to max).

## Quick Reference

```sh
kubectl get hpa -n <NS> -w                         # TARGETS = cur/target per metric
kubectl describe hpa <H> -n <NS>                   # events: why it (didn't) scale
kubectl get scaledobject -n <NS>                   # KEDA objects
kubectl get hpa -n <NS> | grep keda-hpa-           # the HPA KEDA created
kubectl top pods -n <NS>                            # the metric source (metrics-server)
kubectl get deploy <D> -n <NS> -o jsonpath='{.spec.replicas}'   # current count
```

Minimal HPA + KEDA ScaledObject skeleton:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: <D> }
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
spec:
  scaleTargetRef: { name: <D> }
  minReplicaCount: 0            # KEDA-only: scale to zero
  maxReplicaCount: 10
  triggers:
    - type: rabbitmq
      metadata: { protocol: amqp, queueName: <q>, mode: QueueLength, value: "20" }
      authenticationRef: { name: <TRIGGERAUTH> }
```

Checklist:

- [ ] HPA `desired = ceil(cur × curMetric/target)`; multi-metric → **max**
- [ ] `minReplicas ≥ 2` for user-facing; `behavior` scales down **slowly**
- [ ] HPA and VPA never on the **same** resource metric
- [ ] Queue/event consumers scaled by **backlog** via KEDA (scale-to-zero)
- [ ] `maxReplicas` bounded by the namespace ResourceQuota
- [ ] metrics-server (Resource) / adapter / KEDA metrics API installed & monitored
- [ ] A node autoscaler (Cluster Autoscaler / Karpenter) for the Pod growth

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **Catalog is running 4 replicas, CPU utilization averages 80% across them. The HPA target is 70%. Without doing any math, will it scale up or down, and to what? Now do the math.**
   <details><summary>Show answer</summary>

   Scale **up**. `desired = ceil(4 × 80/70) = ceil(4.57) = 5`. The 10% tolerance check: is `|80/70 - 1| = 0.143` > 0.10? Yes — scaling proceeds. Memorising `ceil(currentReplicas × currentMetric / targetMetric)` lets you predict every HPA decision; HPA describe events that don't match this formula mean a different metric (multi-metric → max wins) or stabilization is suppressing the change.

   </details>

2. **An engineer adds VPA in `Auto` mode and HPA on CPU to the same Deployment. A week later replica counts oscillate wildly and pods are constantly evicted. What's happening?**
   <details><summary>Show answer</summary>

   The HPA-VPA conflict on the **same** resource metric (CPU): VPA right-sizes the requests, which moves the HPA's *target* utilization, which changes the HPA's desired replicas, which changes per-replica load, which changes VPA's recommendation. They fight. Solution: either run VPA in **`Off` (recommender)** mode and let humans approve resizes, *or* HPA on a *different* metric (RPS, queue depth) so VPA owns CPU sizing and HPA owns scale-out. See §Mental model / VPA-conflict.

   </details>

3. **Payments-worker reads from a RabbitMQ queue. At 3am the queue is empty. Why is HPA on CPU the wrong scaler, and what does KEDA do differently?**
   <details><summary>Show answer</summary>

   An idle consumer at 3am uses ~0 CPU regardless of queue depth — HPA on CPU sees "low utilization" and could scale all the way down to `minReplicas: 1`, but cannot scale **to zero** (HPA's minimum is 1). KEDA exposes the queue depth as an external metric *and* manages the HPA, including the scale-from-zero / scale-to-zero transitions (which HPA alone cannot do). KEDA is the right tool for queue/event-driven work; HPA on CPU is the wrong scaler for the wrong signal.

   </details>

4. **Hands-on extension — make KEDA scale to zero. Apply a `ScaledObject` with `minReplicaCount: 0` for payments-worker on RabbitMQ. Drain the queue. Watch `kubectl get deploy payments-worker -w`. Now publish one message. Time how long it takes for the first replica to be Ready.**
   <details><summary>What you should see</summary>

   After ~30s of idle, replicas drop to 0 — KEDA scales the Deployment to zero via the managed HPA. On the new message, KEDA detects the queue depth, scales to 1, and you watch a Pod transition Pending → ContainerCreating → Running → Ready, typically 10-30s. That delay is the **cold-start cost** of scale-to-zero; size your `pollingInterval` (default 30s) and `cooldownPeriod` against your SLO. For latency-sensitive paths, `minReplicaCount: 1` is the right trade.

   </details>

5. **HPA at maxReplicas=50, but the cluster only has nodes for 30 catalog pods. What happens when traffic spikes, and what other component must be in play?**
   <details><summary>Show answer</summary>

   HPA scales the *replica count* up to 50, but the scheduler can only place 30 — the other 20 stay `Pending` with `FailedScheduling: 0/X nodes available`. That's where the **node autoscaler** (Cluster Autoscaler or Karpenter) comes in: it watches Pending Pods and provisions more nodes. HPA scales Pods; Karpenter/CA scales nodes; you need both. Without a node autoscaler the HPA's `maxReplicas` is whatever the cluster's current capacity allows — and the cluster never grows on its own.

   </details>

## Further reading

- **Ibryam & Huß, _Kubernetes Patterns_ 2e — *Elastic Scale* (ch.29)** (HPA/
  VPA/cluster autoscaling as one elasticity pattern; horizontal vs vertical
  trade-offs).
- **Rosso et al., _Production Kubernetes_, ch.13 — Autoscaling** (HPA/VPA/
  cluster autoscaler in a production platform, metrics pipelines, pitfalls).
- Official:
  <https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/>
  (and the HPA algorithm:
  <https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#algorithm-details>),
  and KEDA: <https://keda.sh/docs/latest/concepts/scaling-deployments/>.
