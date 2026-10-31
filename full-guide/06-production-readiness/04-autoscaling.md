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

Scaling also has a security side. Whatever can drive the metric, or write the
autoscaler object, can drive your bill. A flood of requests or messages adds
Pods and nodes you pay for, and anyone who can edit an HPA can raise its
ceiling. The [threats and controls](#threats-and-controls) table names each
case and its control.

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

## Threats and controls

Autoscaling makes the bill follow whoever can move the metric or the scaler
object. The threats below are the ones specific to scaling. The controls are
the bounds and access rules around the scaler, not the HPA algorithm.

| Threat | Control | Goes deeper in |
|---|---|---|
| A traffic spike or a message flood scales the workload past what you can pay for (a cost attack) | `maxReplicas` on the HPA and `maxReplicaCount` on the ScaledObject, both inside the namespace ResourceQuota | [01.03](../01-core-workloads/03-resources-and-qos.md), [06.06](06-capacity-and-cost.md) |
| A subject that can edit an HPA or ScaledObject raises its bounds or retargets it | No workload ServiceAccount holds rights on autoscaling objects; only the team that owns the scaling writes them | [05.01](../05-security/01-authn-authz-rbac.md) |
| The metric source is forged or drifts, so someone else's number sets the replica count | Scale on a backlog that only trusted producers can write, and give the scaler a broker user that can read queue length and nothing else | [05.01](../05-security/01-authn-authz-rbac.md) |
| The external metrics API serves a value nobody checks, or goes down | The APIService that serves `external.metrics.k8s.io` is cluster-wide. Install it from a pinned chart, keep its RBAC narrow and monitor it. When it is down the HPA cannot read that metric and skips the scale-downs the others suggest | [06.01](01-observability-metrics.md) |
| The scaler's broker credential is readable by tenants | The credential sits in a Secret that a TriggerAuthentication names, never inline in the ScaledObject | [03.02](../03-config-and-storage/02-secrets.md) |
| Pending Pods grow the node pool without limit | The node autoscaler's own maximum, set by the platform, bounds the nodes that `maxReplicas` asks for | [10.06](../10-cloud-and-managed-kubernetes/06-node-autoscaling-cost-multicloud.md) |

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
 HPA           replicas      CPU / mem / custom /     catalog (CPU)
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
scaling payments-worker on RabbitMQ queue depth; (4) describe the load tests,
which this lab run did not reach.

The output blocks come from a lab cluster whose node has a different name, and
its namespaces had other names. The commands use the chapter's names.

### 0. Prerequisites (self-bootstrapping)

Bring up the cluster and the Bookstore as in
[ch.01 step 0](01-observability-metrics.md). Also apply the async backends:

```sh
kubectl apply -f examples/bookstore/raw-manifests/13-rabbitmq.yaml
kubectl rollout status deployment/rabbitmq -n bookstore
```

The HPA's CPU metric needs a resource metrics API, which metrics-server serves.
[ch.01 step 1](01-observability-metrics.md) installs it and shows that on a
kind node its kubelet certificate is refused, so a kind cluster built as this
guide builds it serves no resource metrics. On a managed cluster, whose
metrics-server serves, step 2 shows live CPU values. On the lab run for this
chapter the APIService was not registered at all, which has the same effect.
The checks below show that state:

```sh
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes
```

<!-- gate: output -->
```
Error from server (NotFound): apiservices.apiregistration.k8s.io "v1beta1.metrics.k8s.io" not found
# ...
error: Metrics API not available
```


### 1. Add the payments-worker Deployment

The worker has had source (`app/payments-worker/main.go`) since Part 00 but no
manifest — KEDA needs a real Deployment to scale. New files:

- A dedicated **`payments-worker-sa`** added to
  [`examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml`](../examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml)
  (`automountServiceAccountToken: false`, **no** Role/RoleBinding — the worker
  never calls the API; same posture as `orders-sa`).
- [`examples/bookstore/raw-manifests/19-payments-worker-deploy.yaml`](../examples/bookstore/raw-manifests/19-payments-worker-deploy.yaml)
  Its Deployment is complete: restricted security context like catalog's,
  `AMQP_URL` pointing at the rabbitmq Service, and a scheduling layer that
  matches the other workloads. Its decisions are in its header.

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
```

The `bookstore` namespace enforces `restricted`. The apply above printed no
PodSecurity warnings, and the rollout returned:

<!-- gate: output -->
```
Waiting for deployment "payments-worker" rollout to finish: 0 out of 1 new replicas have been updated...
Waiting for deployment "payments-worker" rollout to finish: 0 of 1 updated replicas are available...
deployment "payments-worker" successfully rolled out
```

The worker then logs that it is consuming the queue. Its log, read later in
the same run, shows that it reached the broker with the credentials in its
manifest:

<!-- gate: output -->
```
{"time":"2026-10-31T01:16:50.927332267Z","level":"INFO","msg":"payments-worker health server listening","addr":":8080"}
{"time":"2026-10-31T01:16:51.837100283Z","level":"INFO","msg":"consuming queue","queue":"orders"}
```

### 2. An HPA on catalog (CPU)

New file
[`examples/bookstore/raw-manifests/82-hpa-catalog.yaml`](../examples/bookstore/raw-manifests/82-hpa-catalog.yaml)
is a **built-in** `autoscaling/v2` object, so it dry-runs cleanly with no CRD.
It scales catalog on CPU utilization, the one metric metrics-server serves:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: catalog, namespace: bookstore }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: catalog }
  minReplicas: 2                    # user-facing: never below 2 (stay HA)
  maxReplicas: 6                    # bounded by the namespace ResourceQuota (00-)
  metrics:
    - type: Resource                # needs metrics-server (ch.01)
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - { type: Percent, value: 100, periodSeconds: 60 }   # at most 2x
        - { type: Pods,    value: 2,   periodSeconds: 60 }    # or +2 Pods
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300   # scale IN slowly (anti-thrash)
      policies: [{ type: Percent, value: 50, periodSeconds: 60 }]
```

> **Why the applied file has no req/s metric.** A Pods metric such as
> `http_requests_per_second` is served through `custom.metrics.k8s.io`, and
> only an adapter such as the Prometheus Adapter serves that API. Without one,
> the HPA reports `<unknown>` for that metric. The HPA also skips a scale-down
> when a metric cannot be fetched and the metrics it can fetch suggest one
> ([HPA algorithm details](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#algorithm-details)).
> A dead custom metric therefore blocks scale-in, and after a flood catalog
> would stay at its peak. The fragment below shows how the metric is added once
> an adapter serves it. It has no `kind:` and is not applied.

```yaml
# Fragment, not applied. Add under spec.metrics once the Prometheus Adapter
# serves custom.metrics.k8s.io for http_requests_per_second.
- type: Pods
  pods:
    metric:
      name: http_requests_per_second
    target:
      type: AverageValue
      averageValue: "50"
```

Apply the HPA to its target Deployment, then read it:

```sh
kubectl apply -f examples/bookstore/raw-manifests/10-catalog-deploy.yaml   # the target
kubectl apply -f examples/bookstore/raw-manifests/82-hpa-catalog.yaml
kubectl get hpa catalog -n bookstore
kubectl describe hpa catalog -n bookstore      # per-metric values + events
```

On a cluster whose metrics-server serves, TARGETS shows the live CPU value
against the 70% target. The lab cluster for this run served no resource
metrics, so the HPA shows the state it reached:

<!-- gate: output -->
```
NAME      REFERENCE            TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
catalog   Deployment/catalog   cpu: <unknown>/70%   2         6         3          0s
```

The describe output says why:

<!-- gate: output -->
```
Conditions:
  Type           Status  Reason                   Message
  ----           ------  ------                   -------
  AbleToScale    True    SucceededGetScale        the HPA controller was able to get the target's current scale
  ScalingActive  False   FailedGetResourceMetric  the HPA was unable to compute the replica count: failed to get cpu utilization: unable to get metrics for resource cpu: unable to fetch metrics from resource metrics API: the server could not find the requested resource (get pods.metrics.k8s.io)
```

<!-- gate: output -->
```
  Type     Reason                        Age   From                       Message
  ----     ------                        ----  ----                       -------
  Warning  FailedGetResourceMetric       10s   horizontal-pod-autoscaler  failed to get cpu utilization: unable to get metrics for resource cpu: unable to fetch metrics from resource metrics API: the server could not find the requested resource (get pods.metrics.k8s.io)
  Warning  FailedComputeMetricsReplicas  10s   horizontal-pod-autoscaler  invalid metrics (1 invalid out of 1), first error is: failed to get cpu resource metric value: failed to get cpu utilization: unable to get metrics for resource cpu: unable to fetch metrics from resource metrics API: the server could not find the requested resource (get pods.metrics.k8s.io)
```

`MAXPODS` is the ceiling that the threats table protects. This run never
reached it, because no metric reached the HPA. The ceiling does not need a
metric to show, though. The namespace ResourceQuota is the hard limit under
`maxReplicas`. Scale catalog past what the quota allows, and the ReplicaSet is
refused:

```sh
kubectl scale deployment/catalog -n bookstore --replicas=40
kubectl get events -n bookstore --field-selector reason=FailedCreate --sort-by=.lastTimestamp | tail -3
kubectl scale deployment/catalog -n bookstore --replicas=3
```

<!-- gate: output -->
```
24s         Warning   FailedCreate   replicaset/catalog-d994db675   Error creating: pods "catalog-d994db675-v7zqs" is forbidden: exceeded quota: bookstore-quota, requested: limits.cpu=250m, used: limits.cpu=3950m, limited: limits.cpu=4
24s         Warning   FailedCreate   replicaset/catalog-d994db675   Error creating: pods "catalog-d994db675-jt8vk" is forbidden: exceeded quota: bookstore-quota, requested: limits.cpu=250m, used: limits.cpu=3950m, limited: limits.cpu=4
22s         Warning   FailedCreate   replicaset/catalog-d994db675   (combined from similar events): Error creating: pods "catalog-d994db675-sdx6z" is forbidden: exceeded quota: bookstore-quota, requested: limits.cpu=250m, used: limits.cpu=3950m, limited: limits.cpu=4
```

The refusal names `bookstore-quota` and `limits.cpu`. The namespace had 3950m
of its 4 CPU limit in use when the next catalog Pod asked for 250m, so the Pod
never starts. The quota is the limit a flood runs into when the HPA's
`maxReplicas` is set too high.

The HPA's own access is the other half of that control. Each `can-i` asks
whether a subject may act. The last check is the positive control: the admin
identity may patch an HPA, so the `no` answers mean something.

```sh
kubectl auth can-i patch horizontalpodautoscalers -n bookstore --as=system:serviceaccount:bookstore:catalog-sa
kubectl auth can-i patch horizontalpodautoscalers -n bookstore --as=system:serviceaccount:bookstore:payments-worker-sa
kubectl auth can-i update deployments/scale -n bookstore --as=system:serviceaccount:bookstore:orders-sa
kubectl auth can-i patch horizontalpodautoscalers -n bookstore
```

The four answers, in order (catalog-sa, payments-worker-sa, orders-sa, then
the admin control):

<!-- gate: output -->
```
no
# ...
no
# ...
no
# ...
yes
```

None of the workload ServiceAccounts can raise a ceiling, and `orders-sa`
cannot write a replica count either. The admin answer is the control.

### 3. KEDA: scale payments-worker on RabbitMQ queue depth

Install KEDA into its own `keda` namespace, labelled `restricted` before the
install. The chart's three images are pinned by digest in a values file, with
the version kept in the tag beside each digest, as the baseline asks of
third-party images. The rendered Deployments set every field that `restricted`
checks: non-root, the `RuntimeDefault` seccomp profile, no privilege
escalation, a read-only root filesystem and all capabilities dropped. Install
with Helm, not a raw `releases/latest/download` URL, because that URL names a
version-pinned file that stops matching when KEDA ships a new tag.

Save this as `keda-values.yaml`:

```yaml
image:
  keda:
    tag: "2.21.0@sha256:81fe6547ce8d1cc29273f887b76507e9b853e5bc1f875ec23fe60061a38ed809"
  metricsApiServer:
    tag: "2.21.0@sha256:255375037fe592732eeb554743aae360c2da88cf0b9b1258d0a987ef885f0881"
  webhooks:
    tag: "2.21.0@sha256:e1969628cca6123e32eea13c47c75817091af2657fa68d9d0d58a8620d1b75b1"
```

Check that the render uses those digests:

```sh
helm template keda kedacore/keda --version 2.21.0 --namespace keda \
  -f keda-values.yaml --include-crds | grep -E 'image: .*ghcr.io/kedacore'
```

<!-- gate: output -->
```
          image: "ghcr.io/kedacore/keda:2.21.0@sha256:81fe6547ce8d1cc29273f887b76507e9b853e5bc1f875ec23fe60061a38ed809"
          image: "ghcr.io/kedacore/keda-metrics-apiserver:2.21.0@sha256:255375037fe592732eeb554743aae360c2da88cf0b9b1258d0a987ef885f0881"
          image: "ghcr.io/kedacore/keda-admission-webhooks:2.21.0@sha256:e1969628cca6123e32eea13c47c75817091af2657fa68d9d0d58a8620d1b75b1"
```

Before the install, dry-run the render in the labelled namespace. A server-side
dry run runs the PodSecurity admission check on each Deployment's pod template,
so the count of PodSecurity warnings should be zero:

```sh
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
kubectl create namespace keda
kubectl label namespace keda \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
helm template keda kedacore/keda --version 2.21.0 --namespace keda \
  -f keda-values.yaml --include-crds > keda-render.yaml
kubectl apply --server-side --dry-run=server -f keda-render.yaml 2>&1 | grep -c "server dry run"
kubectl apply --server-side --dry-run=server -f keda-render.yaml 2>&1 | grep -ci podsecurity
```

The first count is the number of objects the server accepts, and the second is
the number of PodSecurity warnings:

<!-- gate: output -->
```
29
# ...
0
```

A zero count means something only if the check can fail. As a control, dry-run
a Deployment whose container sets `privileged: true` in the same namespace. It
draws the warning:

<!-- gate: output -->
```
Warning: would violate PodSecurity "restricted:latest": privileged (container "app" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Install the chart with the same values file:

```sh
helm install keda kedacore/keda --version 2.21.0 \
  --namespace keda -f keda-values.yaml --wait
kubectl -n keda rollout status deployment/keda-operator
```

The scaler's broker credential is a user of its own. The `guest` user that the
other Pods share is not used. The new user may read the `orders` queue and
nothing else: its configure and write permissions match no resource. The
password comes from `openssl`, is never printed, and lives only in the Secret:

```sh
PW="$(openssl rand -hex 24)"
kubectl -n bookstore exec deploy/rabbitmq -- rabbitmqctl add_user keda-scaler "$PW"
kubectl -n bookstore exec deploy/rabbitmq -- rabbitmqctl set_permissions -p / keda-scaler '^$' '^$' '^orders$'
kubectl -n bookstore exec deploy/rabbitmq -- rabbitmqctl list_user_permissions keda-scaler --formatter json
kubectl -n bookstore create secret generic rabbitmq-conn \
  --from-literal=host="amqp://keda-scaler:$PW@rabbitmq.bookstore.svc.cluster.local:5672/"
unset PW
```

The broker's answer:

<!-- gate: output -->
```
[
{"vhost":"/","configure":"^$","write":"^$","read":"^orders$"}
]
```

Each permission is a regular expression, and `^orders$` matches exactly one
queue. Read on `orders` is the only grant. This lab run did not install KEDA
on the shared lab cluster, and the scaler itself was not run. The render, the
restricted dry run and the broker's grant above are the evidence in this
chapter. The install, the scale-out and the scale-to-zero are not run here.
Run them on a cluster you own, after the install above.

New file
[`examples/bookstore/raw-manifests/83-keda-scaledobject.yaml`](../examples/bookstore/raw-manifests/83-keda-scaledobject.yaml)
(a `TriggerAuthentication` and a `ScaledObject`, which names the Secret that
step 3 creates above). Core object:

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

> **KEDA wraps an HPA.** `83-` does **not** contain an HPA. KEDA's operator
creates one for the ScaledObject, with the live queue length as its external
metric, and that HPA runs the same `ceil(replicas × len/value)` formula as the
catalog HPA. The one thing a plain HPA cannot do, moving between 0 and 1, KEDA
does itself: it scales the Deployment to `minReplicaCount` once the trigger has
been inactive for `cooldownPeriod`, and back up when a message arrives.

> **CRD-backed objects.** `ScaledObject` and `TriggerAuthentication` are KEDA
CRDs (`keda.sh/v1alpha1`). Before KEDA is installed, a server dry run of `83-`
fails with `no matches for kind "ScaledObject" in version "keda.sh/v1alpha1"`,
as it did in the lab run. That is expected, not a defect, the same as the
Gateway API and Kyverno objects in earlier chapters. The `19-` Deployment and
the `82-` HPA are built-ins and dry-run cleanly.


### 4. Load tests: left for you to run

This lab run did not reach the scale-out. The HPA had no metric to read, and
KEDA was not installed, so neither the catalog HPA nor the queue scaler moved.
A second pass did not change that. It needed a metrics-server that serves, and
the ways to get one were closed. A kind cluster built with `serverTLSBootstrap`
(the route in [ch.01 step 1](01-observability-metrics.md)) was not started,
because the lab host's container engine did not answer an image listing within
three minutes. Installing the chart on the shared lab cluster would have
written a RoleBinding into `kube-system`, a namespace the run does not own, and
switching kubelet verification off is not something this guide teaches. So no
HPA ran under load here, and nothing below is a measured result.

Run the load yourself on a cluster whose metrics-server serves, once the KEDA
install in step 3 has rolled out. Use the curl load Job and the two
NetworkPolicies from [06.06 section
1](06-capacity-and-cost.md#1-measure-catalogs-real-usage). It already uses a
curl image pinned by digest and the restricted `securityContext`. One change
is needed. The Job runs 180 seconds, and the HPA needs longer to reach its
ceiling: the `scaleUp` policy above takes the larger of two more Pods or a
doubling every 60 seconds, after a 60 second stabilization window. From 2
replicas that is 4, then 6, so edit `+ 180` in the Job's loop to `+ 420`. Then
watch the HPA from a second shell:

```sh
kubectl get hpa catalog -n bookstore -w
```

The expectation follows from the manifest, not from a run. Each catalog Pod
requests 50m, so the 70% target is 35m of CPU per Pod, and the load has to keep
every Pod above that. Read the usage with `kubectl top pods -n bookstore`. If
TARGETS stays under 70%, the load is too light, so raise the Job's
`parallelism` before suspecting the HPA. Once TARGETS holds above the target,
REPLICAS should go 2, 4, 6 and stop at `MAXPODS` while the load lasts. It must
not pass 6 however high the metric reads, which is the property that bounds a
cost attack. If it does, check `maxReplicas` on the object you applied. After
the Job ends, the 300 second `scaleDown` stabilization holds the replicas for
five minutes before they fall.

Orders publishes to the queue only when `AMQP_URL` is set. `14-` leaves it
unset on purpose (its header explains), so the queue stays empty until that
changes. The orders log from the lab run shows the unset state:

<!-- gate: output -->
```
{"time":"2026-10-31T01:07:16.078833493Z","level":"INFO","msg":"AMQP_URL unset; order events will not be published"}
```

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
  in-place Pod resize is a separate feature, and these classic VPA modes
  still evict and recreate the Pod).
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
  A stock HPA could not reach or leave 0 for a long time. The beta
  `HPAScaleToZero` feature gate lets an HPA on an Object or
  External metric set `minReplicas: 0`, but something must still serve that
  metric. KEDA ships that adapter and owns the 0↔1 activation, which is its
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
> Bookstore does exactly this: catalog→HPA(CPU), payments-worker→KEDA
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
> any other dependency. If the metrics API is down, an HPA cannot read that
> metric. It still scales up on the metrics it can read, but it skips a
> scale-down those metrics suggest, so the count can stay high.

## Quick Reference

```sh
kubectl get hpa -n <NS> -w                         # TARGETS = cur/target per metric
kubectl describe hpa <H> -n <NS>                   # events: why it (didn't) scale
kubectl get scaledobject -n <NS>                   # KEDA objects
kubectl get hpa -n <NS> | grep keda-hpa-           # the HPA KEDA created
kubectl top pods -n <NS>                            # the metric source (metrics-server)
kubectl get deploy <D> -n <NS> -o jsonpath='{.spec.replicas}'   # current count
```

Checklist:

- [ ] HPA `desired = ceil(cur × curMetric/target)`; multi-metric → **max**
- [ ] `minReplicas ≥ 2` for user-facing; `behavior` scales down **slowly**
- [ ] HPA and VPA never on the **same** resource metric
- [ ] Queue/event consumers scaled by **backlog** via KEDA (scale-to-zero)
- [ ] `maxReplicas` bounded by the namespace ResourceQuota
- [ ] metrics-server (Resource) / adapter / KEDA metrics API installed & monitored
- [ ] A node autoscaler (Cluster Autoscaler / Karpenter) for the Pod growth
- [ ] No workload ServiceAccount can write HPAs or ScaledObjects

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

   An idle consumer at 3am uses ~0 CPU regardless of queue depth: HPA on CPU sees "low utilization" and could scale all the way down to `minReplicas: 1`, but cannot scale **to zero**, because CPU is only measured on running Pods. (The `HPAScaleToZero` feature gate is in beta and on by default, so an HPA on an Object or External metric may set `minReplicas: 0`; you would still need a metrics adapter to feed it the queue depth.) KEDA exposes the queue depth as an external metric *and* manages the HPA, including the scale-from-zero / scale-to-zero transitions (which an HPA on CPU cannot do). KEDA is the right tool for queue/event-driven work; HPA on CPU is the wrong scaler for the wrong signal.

   </details>

4. **Hands-on extension — make KEDA scale to zero. Apply a `ScaledObject` with `minReplicaCount: 0` for payments-worker on RabbitMQ. Drain the queue. Watch `kubectl get deploy payments-worker -w`. Now publish one message. Time how long it takes for the first replica to be Ready.**
   <details><summary>What you should see (expected, not measured in the lab run)</summary>

   After ~30s of idle, replicas drop to 0 — KEDA scales the Deployment to zero via the managed HPA. On the new message, KEDA detects the queue depth, scales to 1, and you watch a Pod transition Pending → ContainerCreating → Running → Ready, typically 10-30s. That delay is the **cold-start cost** of scale-to-zero; size your `pollingInterval` (default 30s) and `cooldownPeriod` against your SLO. For latency-sensitive paths, `minReplicaCount: 1` is the right trade.

   </details>

5. **HPA at maxReplicas=50, but the cluster only has nodes for 30 catalog pods. What happens when traffic spikes, and what other component must be in play?**
   <details><summary>Show answer</summary>

   HPA scales the *replica count* up to 50, but the scheduler can only place 30 — the other 20 stay `Pending` with `FailedScheduling: 0/X nodes available`. That's where the **node autoscaler** (Cluster Autoscaler or Karpenter) comes in: it watches Pending Pods and provisions more nodes. HPA scales Pods; Karpenter/CA scales nodes; you need both. Without a node autoscaler the HPA's `maxReplicas` is whatever the cluster's current capacity allows — and the cluster never grows on its own.

   </details>

6. **A compromised workload can update catalog's Deployment scale but cannot
   patch HorizontalPodAutoscalers. Why does that split matter for the bill?**
   <details><summary>Show answer</summary>

   The HPA holds `maxReplicas`, the ceiling. An attacker who can patch the HPA
   can raise that ceiling and let the bill follow the attack. Writing the scale
   subresource only sets the count until the HPA controller's next sync
   overwrites it, so the ceiling is the control that matters. The lab run
   checked the workload ServiceAccounts: each one got `no` for patching HPAs,
   and `orders-sa` got `no` for updating a Deployment's scale (see step 2).
   Keep both rights away from workloads, and let only the team that owns the
   scaling write autoscaling objects.

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
- Pod Security Standards, for the `restricted` fields the KEDA step
  checks: <https://kubernetes.io/docs/concepts/security/pod-security-standards/>.
