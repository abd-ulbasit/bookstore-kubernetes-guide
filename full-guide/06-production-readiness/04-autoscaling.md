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
| metrics-server skips kubelet certificate checks (`--kubelet-insecure-tls`), so whatever answers at a node address sets the CPU the HPA sees | Keep verification on. Give each kubelet a serving certificate from the cluster CA (`serverTLSBootstrap`), and approve each request only after checking that the requestor is that node and the names are its own (step 0) | [06.01](01-observability-metrics.md) |
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

We will: (0) give the cluster a resource metrics API that still verifies its
kubelets; (1) add the **payments-worker** Deployment (its first manifest); (2)
add an **HPA** on catalog; (3) install **KEDA** and add a **ScaledObject**
scaling payments-worker on RabbitMQ queue depth; (4) start the load Job, which
this lab run had to stop early.

The output blocks come from two lab clusters whose nodes have other names than
yours. Step 1, step 3, the quota and access checks in step 2 and the orders log
in step 4 ran on a single-node cluster whose namespaces had other names. The
metrics API in step 0, the HPA readings in step 2 and the load Job in step 4
ran on a three-node cluster with the chapter's own namespace names. The
transcript's header lists both runs and what each did not do. The commands use
the chapter's names.

### 0. Prerequisites (self-bootstrapping)

Bring up the cluster and the Bookstore as in
[ch.01 step 0](01-observability-metrics.md). Also apply the async backends:

```sh
kubectl apply -f examples/bookstore/raw-manifests/13-rabbitmq.yaml
kubectl rollout status deployment/rabbitmq -n bookstore
```

**Catalog needs room for its replicas.** Catalog spreads its replicas over the
nodes with a hard rule: `topologySpreadConstraints` on
`kubernetes.io/hostname`, `maxSkew: 1`, `DoNotSchedule`. On a three-node kind
cluster the control-plane node carries a `NoSchedule` taint, but the default
`nodeTaintsPolicy: Ignore` still counts it as an empty domain
([04.02](../04-scheduling/02-affinity-taints-topology.md) explains the policy).
Each worker may then hold one replica, and the third waits:

```sh
kubectl get pods -n bookstore -l app=catalog -o wide
kubectl get events -n bookstore --field-selector reason=FailedScheduling
```

<!-- gate: output -->
```
NAME                       READY   STATUS    RESTARTS   AGE     IP             NODE               NOMINATED NODE   READINESS GATES
catalog-86d7dc55cc-6l268   1/1     Running   0          6m18s   10.244.2.112   demo-lab-worker2   <none>           <none>
catalog-86d7dc55cc-nd99d   1/1     Running   0          6m17s   10.244.1.80    demo-lab-worker    <none>           <none>
catalog-86d7dc55cc-ptvkj   0/1     Pending   0          6m17s   <none>         <none>             <none>           <none>
```

<!-- gate: output -->
```
LAST SEEN   TYPE      REASON             OBJECT                         MESSAGE
54s         Warning   FailedScheduling   pod/catalog-86d7dc55cc-ptvkj   0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match pod topology spread constraints. preemption: 0/3 nodes are available: 1 No preemption victims found for incoming pod, 1 Preemption is not helpful for scheduling, 1 node(s) didn't match pod topology spread constraints.
```

This matters here because `maxReplicas` only caps what the HPA asks for. The
scheduler decides what is placed, and on a cloud cluster a node autoscaler
answers a Pod left `Pending` by adding a node (see the
[threats](#threats-and-controls)).
The lab fixed it on the cluster object and left the shipped file alone. The
patch adds `nodeTaintsPolicy: Honor`, which leaves out a node the Pod's
tolerations do not cover when it counts domains. A single-node cluster does
not need it:

```sh
kubectl patch deployment catalog -n bookstore --type json \
  -p '[{"op":"add","path":"/spec/template/spec/topologySpreadConstraints/0/nodeTaintsPolicy","value":"Honor"}]'
kubectl rollout status deployment/catalog -n bookstore
kubectl get pods -n bookstore -l app=catalog -o wide
```

<!-- gate: output -->
```
deployment.apps/catalog patched
# ...
deployment "catalog" successfully rolled out
# ...
NAME                       READY   STATUS        RESTARTS   AGE    IP             NODE               NOMINATED NODE   READINESS GATES
catalog-74995c78bb-9csnp   1/1     Running       0          7s     10.244.1.82    demo-lab-worker    <none>           <none>
catalog-74995c78bb-rnjch   1/1     Running       0          26s    10.244.2.113   demo-lab-worker2   <none>           <none>
catalog-74995c78bb-zpbgk   1/1     Running       0          44s    10.244.1.81    demo-lab-worker    <none>           <none>
catalog-86d7dc55cc-6l268   1/1     Terminating   0          7m3s   10.244.2.112   demo-lab-worker2   <none>           <none>
```

**A resource metrics API that checks the kubelets.** The HPA's CPU metric
needs a resource metrics API, which metrics-server serves.
[ch.01 step 1](01-observability-metrics.md) installs it and shows that on a
kind node the kubelet's certificate is refused, so the API stays down. This
run took that install through to a working API with verification left on.
First the state before it:

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

Install the chart as ch.01 step 1 does, at its pinned version 3.14.0 in a
namespace of its own labelled `restricted`. The Pod runs but never becomes
ready, and the APIService has no endpoint behind it:

```sh
kubectl -n metrics-server get pods
kubectl get apiservice v1beta1.metrics.k8s.io
```

<!-- gate: output -->
```
NAME                             READY   STATUS    RESTARTS   AGE
metrics-server-c4994bc54-qlnvr   0/1     Running   0          43s
# ...
NAME                     SERVICE                         AVAILABLE                  AGE
v1beta1.metrics.k8s.io   metrics-server/metrics-server   False (MissingEndpoints)   43s
```

The Pod's log says why. Each node's kubelet answered with a certificate that
lists no IP address, and metrics-server refused it:

```sh
kubectl -n metrics-server logs deploy/metrics-server | grep 'Failed to scrape' | head -3
```

<!-- gate: output -->
```
E1031 12:48:31.000213       1 scraper.go:149] "Failed to scrape node" err="Get \"https://172.18.0.4:10250/metrics/resource\": tls: failed to verify certificate: x509: cannot validate certificate for 172.18.0.4 because it doesn't contain any IP SANs" node="demo-lab-worker"
E1031 12:48:31.000755       1 scraper.go:149] "Failed to scrape node" err="Get \"https://172.18.0.5:10250/metrics/resource\": tls: failed to verify certificate: x509: cannot validate certificate for 172.18.0.5 because it doesn't contain any IP SANs" node="demo-lab-worker2"
E1031 12:48:31.007548       1 scraper.go:149] "Failed to scrape node" err="Get \"https://172.18.0.3:10250/metrics/resource\": tls: failed to verify certificate: x509: cannot validate certificate for 172.18.0.3 because it doesn't contain any IP SANs" node="demo-lab-control-plane"
```

The refusal is the control working, and the fix keeps it. Each kubelet asks
the cluster CA for a serving certificate that lists its own name and
addresses, instead of signing one for itself. The kubelet configuration field
is `serverTLSBootstrap: true`. On a new kind cluster, set it in the kind
config under `kubeadmConfigPatches` with `kind: KubeletConfiguration`. This
cluster was already running, so the loop below appends the line to each node's
kubelet file (a kind node is a container named like the node), keeps the
original as `config.yaml.orig` and restarts the kubelet. Every node then files
a request that waits for approval:

```sh
for n in $(kubectl get nodes -o name | sed 's|node/||'); do
  docker exec "$n" sh -c 'cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.orig && echo "serverTLSBootstrap: true" >> /var/lib/kubelet/config.yaml && systemctl restart kubelet && grep serverTLSBootstrap /var/lib/kubelet/config.yaml'
done
kubectl get csr
```

<!-- gate: output -->
```
serverTLSBootstrap: true
serverTLSBootstrap: true
serverTLSBootstrap: true
# ...
NAME        AGE   SIGNERNAME                      REQUESTOR                            REQUESTEDDURATION   CONDITION
csr-5wktd   2s    kubernetes.io/kubelet-serving   system:node:demo-lab-worker          <none>              Pending
csr-bjx5p   1s    kubernetes.io/kubelet-serving   system:node:demo-lab-worker2         <none>              Pending
csr-jg8hl   3s    kubernetes.io/kubelet-serving   system:node:demo-lab-control-plane   <none>              Pending
```

The controller manager does not approve this signer's requests on its own
([CSR signers](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/#kubernetes-signers)),
and a blanket approval would hand a certificate for a node's address to
whoever could file a request. Check each one first: the requestor must be the
node it names, and the names and addresses inside the request must be that
node's own. The loop prints both for every request, and the approval follows:

```sh
for c in $(kubectl get csr -o name); do
  u=$(kubectl get "$c" -o jsonpath='{.spec.username}')
  s=$(kubectl get "$c" -o jsonpath='{.spec.request}' | base64 -d | openssl req -noout -text | grep -A1 'Alternative Name' | tail -1 | sed 's/^ *//')
  echo "${c#*/} $u $s"
done
kubectl certificate approve $(kubectl get csr -o name)
```

<!-- gate: output -->
```
csr-5wktd system:node:demo-lab-worker DNS:demo-lab-worker, IP Address:172.18.0.4
csr-bjx5p system:node:demo-lab-worker2 DNS:demo-lab-worker2, IP Address:172.18.0.5
csr-jg8hl system:node:demo-lab-control-plane DNS:demo-lab-control-plane, IP Address:172.18.0.3
# ...
certificatesigningrequest.certificates.k8s.io/csr-5wktd approved
certificatesigningrequest.certificates.k8s.io/csr-bjx5p approved
certificatesigningrequest.certificates.k8s.io/csr-jg8hl approved
```

Now the same metrics-server, unchanged, can verify the kubelets. It becomes
ready, the APIService turns available, and `kubectl top` answers:

```sh
kubectl -n metrics-server rollout status deployment/metrics-server --timeout=300s
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes
```

<!-- gate: output -->
```
deployment "metrics-server" successfully rolled out
# ...
NAME                     SERVICE                         AVAILABLE   AGE
v1beta1.metrics.k8s.io   metrics-server/metrics-server   True        82s
# ...
NAME                     CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
demo-lab-control-plane   139m         3%       1139Mi          15%         
demo-lab-worker          37m          0%       239Mi           3%          
demo-lab-worker2         23m          0%       272Mi           3%          
```

Last, confirm that the fix did not switch verification off. The container
arguments are the chart's defaults, and none of them is an insecure flag:

```sh
kubectl -n metrics-server get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'
kubectl -n metrics-server get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -c insecure
```

<!-- gate: output -->
```
["--secure-port=10250","--cert-dir=/tmp","--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname","--kubelet-use-node-status-port","--metric-resolution=15s"]
# ...
0
```

> **The shortcut this run did not take.** Many guides end the story at the
> refusal with `--kubelet-insecure-tls` on metrics-server. That flag is for a
> throwaway lab only. It turns off the check that the kubelet answering is the
> kubelet the cluster knows, so anything that can answer at a node's address
> can feed metrics-server numbers, and the numbers set the replica counts and
> so the bill. Production must not use it. The
> [metrics-server FAQ](https://github.com/kubernetes-sigs/metrics-server/blob/master/FAQ.md)
> names the flag and the secure setup. The count of `0` above is the check to
> run on any cluster you inherit.

The change stays on the cluster until you undo it. The lab put each original
kubelet file back, restarted the kubelets, deleted the three requests and
uninstalled metrics-server when it finished.


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

With the metrics API serving, TARGETS shows the live CPU against the 70%
target. Idle catalog Pods use about 1m each, which is 2% of the 50m request:

<!-- gate: output -->
```
NAME      REFERENCE            TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
catalog   Deployment/catalog   cpu: 2%/70%   2         6         3          0s
```

The describe output says the metric is read and the count is inside the
bounds:

<!-- gate: output -->
```
Conditions:
  Type            Status  Reason               Message
  ----            ------  ------               -------
  AbleToScale     True    ScaleDownStabilized  recent recommendations were higher than current one, applying the highest recent recommendation
  ScalingActive   True    ValidMetricFound     the HPA was able to successfully calculate a replica count from cpu resource utilization (percentage of request)
  ScalingLimited  False   DesiredWithinRange   the desired count is within the acceptable range
```

`ScalingActive True` means the HPA can read the metric. `ScalingLimited` is
the condition to watch for the ceiling: it reads `False` while the desired
count sits inside `minReplicas` and `maxReplicas`, and it changes to `True`
when the bounds clip the answer.

Catalog starts at 3 replicas, because `10-catalog-deploy.yaml` says so, and
the floor is 2. The `scaleDown` window of 300 seconds makes the HPA wait
before it takes the third one away. This loop samples the HPA and the Pods'
CPU every 30 seconds for six minutes, with no load:

```sh
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt 360 ]; do
  echo "t=+$(( $(date +%s) - start ))s"
  kubectl get hpa catalog -n bookstore --no-headers
  kubectl top pods -n bookstore -l app=catalog --no-headers
  sleep 30
done
```

The last three samples show the window ending. The Pods stay at 1m (the
shipped target is far above that), and the HPA gives up the third replica
only after five minutes:

<!-- gate: output -->
```
t=+275s
catalog   Deployment/catalog   cpu: 2%/70%   2     6     3     4m36s
catalog-74995c78bb-9csnp   1m    3Mi   
catalog-74995c78bb-rnjch   1m    3Mi   
catalog-74995c78bb-zpbgk   1m    3Mi   
t=+306s
catalog   Deployment/catalog   cpu: 2%/70%   2     6     3     5m7s
catalog-74995c78bb-9csnp   1m    2Mi   
catalog-74995c78bb-rnjch   1m    3Mi   
t=+336s
catalog   Deployment/catalog   cpu: 2%/70%   2     6     2     5m37s
catalog-74995c78bb-9csnp   1m    3Mi   
catalog-74995c78bb-rnjch   1m    3Mi   
```

`MAXPODS` is the ceiling that the threats table protects. This run never
reached it, because the load that would push CPU past the target had to be
stopped early (step 4). The ceiling does not need a metric to show, though.
The namespace ResourceQuota is the hard limit under `maxReplicas`. The
quota demonstration below was recorded earlier, with the HPA applied but
unable to read a metric. A working HPA owns the replica count, so delete it
(`kubectl delete hpa catalog -n bookstore`) before you scale by hand, and
apply it again afterwards. Scale catalog past what the quota allows, and the
ReplicaSet is refused:

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


### 4. The load Job: what ran, and what did not

The load comes from the Job and the two NetworkPolicies in [06.06 section
1](06-capacity-and-cost.md#1-measure-catalogs-real-usage), which use a curl
image pinned by digest and the restricted `securityContext`. Save its two YAML
blocks as `load-allow.yaml` and `load-catalog.yaml`. One change is needed. The
Job runs 180 seconds, and the HPA needs longer to reach its ceiling: the
`scaleUp` policy above takes the larger of two more Pods or a doubling every
60 seconds, after a 60 second stabilization window. From 2 replicas that is 4,
then 6, so edit `+ 180` to `+ 420` in the Job's loop and check the line:

```sh
grep -n 'end=' load-catalog.yaml
kubectl apply -f load-allow.yaml
kubectl apply -f load-catalog.yaml
```

<!-- gate: output -->
```
29:              end=$(( $(date +%s) + 420 ))
# ...
serviceaccount/load-generator-sa created
networkpolicy.networking.k8s.io/allow-load-generator-egress created
networkpolicy.networking.k8s.io/allow-load-generator-to-catalog created
# ...
job.batch/load-catalog created
```

Watch the HPA and the Pods' CPU from the same shell, every 20 seconds, with the
loop from step 2 (change the pause to 20 and drop the `-l app=catalog` filter
so the load Pod shows). This is the lab's first two minutes at the shipped
70% target. Each catalog Pod requests 50m, so the target is 35m of CPU per
Pod:

<!-- gate: output -->
```
t=+0s
catalog   Deployment/catalog   cpu: 2%/70%   2     6     2     6m42s
catalog-74995c78bb-9csnp   1m    3Mi     
catalog-74995c78bb-rnjch   1m    3Mi     
postgres-0                 30m   104Mi   
redis-574bb544f-b7tvt      4m    3Mi     
t=+20s
catalog   Deployment/catalog   cpu: 6%/70%   2     6     2     7m3s
catalog-74995c78bb-9csnp   3m    4Mi     
catalog-74995c78bb-rnjch   3m    7Mi     
load-catalog-shx7j         86m   1Mi     
postgres-0                 39m   111Mi   
redis-574bb544f-b7tvt      5m    3Mi     
t=+41s
catalog   Deployment/catalog   cpu: 24%/70%   2     6     2     7m23s
catalog-74995c78bb-9csnp   14m    8Mi     
catalog-74995c78bb-rnjch   10m    8Mi     
load-catalog-shx7j         434m   11Mi    
postgres-0                 44m    111Mi   
redis-574bb544f-b7tvt      8m     3Mi     
```

At 41 seconds each catalog Pod used 10m to 14m, which is 24% of its request
and under the 70% target, so the HPA correctly held at 2 replicas. The
generator cost more than the service under test: the load Pod used 434m and
Postgres 44m. In the 75 seconds recorded, this load stayed under the shipped
target, so at that target it had not added a replica.

**The run stopped here.** About 75 seconds in, the sampling pass that should
have taken 20 seconds took two minutes (the AGE column jumps from 7m23s to
9m19s), and `kubectl top` answered that the metrics API was not available:

<!-- gate: output -->
```
t=+75s
catalog   Deployment/catalog   cpu: 21%/70%   2     6     2     9m19s
error: Metrics API not available
```

The host's load average had risen to about 30 on four cores, and the control
plane's controller manager and scheduler restarted. Both already showed
dozens of restarts before the run (38 and 40 in about ten hours), so one more
each is no proof that the Job caused it. It came while the host was saturated,
and the lab's rule for that is to stop. The Job was deleted and everything the
run had installed was removed. The restart counts about two minutes later:

<!-- gate: output -->
```
NAME                                             READY   STATUS    RESTARTS        AGE
# ...
kube-controller-manager-demo-lab-control-plane   1/1     Running   39 (111s ago)   10h
# ...
kube-scheduler-demo-lab-control-plane            1/1     Running   41 (89s ago)    10h
```

**Not run.** The scale-out to 4 and then 6 replicas, the hold at `MAXPODS`,
the `ScalingLimited` condition changing to `True` and the scale-in after the
Job all stayed unmeasured, and no number in this chapter claims them. Run
them on a cluster you own, with room for the load. The shipped bounds stay as
they are. Only the CPU target changes, because the Job above reached about
24% of the request. Lowering the target to 5% gives 2.5m per Pod, and the
formula would ask for `ceil(2 x 24/5)`, which is 10 replicas from that reading.
The ceiling of 6 is then what stops it, and that stop is the property that
bounds a cost attack. This is the expectation from the manifest and the
reading above, not a measurement:

```sh
kubectl patch hpa catalog -n bookstore --type json \
  -p '[{"op":"replace","path":"/spec/metrics/0/resource/target/averageUtilization","value":5}]'
kubectl get hpa catalog -n bookstore -w
kubectl describe hpa catalog -n bookstore | sed -n '/^Conditions:/,$p'
```

Expect REPLICAS to climb to 6 and stay there while the Job runs, however high
CPU reads, with `ScalingLimited` at `True` and the reason `TooManyReplicas`. If
it passes 6, check `maxReplicas` on the object you applied. After the Job ends,
the 300 second `scaleDown` window holds the replicas for five minutes before
they fall. If your host struggles as this one did, lower the Job's concurrency
before the target: the `seq 10` in its loop sets how many requests run at once.

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

> **In production:** a hard spread rule decides how many replicas the
> scheduler can place, whatever `maxReplicas` says. Catalog's `DoNotSchedule`
> rule left its third replica `Pending` on a three-node cluster whose
> control-plane node was tainted (step 0). Set `nodeTaintsPolicy: Honor` when
> tainted nodes should not count as domains. A Pod left `Pending` is also what
> a node autoscaler answers by adding a node, so check that the replicas you
> allow are replicas you can place and pay for.

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
kubectl get csr                                     # kubelet-serving: check, then approve
kubectl get deploy <D> -n <NS> -o jsonpath='{.spec.replicas}'   # current count
```

Checklist:

- [ ] HPA `desired = ceil(cur × curMetric/target)`; multi-metric → **max**
- [ ] `minReplicas ≥ 2` for user-facing; `behavior` scales down **slowly**
- [ ] HPA and VPA never on the **same** resource metric
- [ ] Queue/event consumers scaled by **backlog** via KEDA (scale-to-zero)
- [ ] `maxReplicas` bounded by the namespace ResourceQuota
- [ ] metrics-server (Resource) / adapter / KEDA metrics API installed & monitored
- [ ] metrics-server verifies the kubelets: serving certificates approved
  after a check, never `--kubelet-insecure-tls`
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

7. **On a kind cluster `kubectl top` answers `Metrics API not available`, and
   the metrics-server log says a kubelet certificate "doesn't contain any IP
   SANs". A colleague adds `--kubelet-insecure-tls`. What does the flag
   change, and what do you do instead?**
   <details><summary>Show answer</summary>

   The flag stops metrics-server from verifying the certificate of any
   kubelet it scrapes. The CPU numbers the HPA divides by then come from
   whatever answers at a node's address, and those numbers set the replica
   count and the bill. It is a flag for a throwaway lab. Instead, set
   `serverTLSBootstrap: true` in the kubelet configuration, check each
   pending `kubernetes.io/kubelet-serving` request (requestor is the node,
   names and addresses are the node's own) and approve it, then confirm that
   the container arguments hold no insecure flag. Step 0 shows each command
   and the `0` from the final `grep -c insecure`.

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
- Kubelet serving certificates and how requests are approved:
  <https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/>
  and the CSR signers,
  <https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/#kubernetes-signers>.
  Setting a kubelet field from the kind config:
  <https://kind.sigs.k8s.io/docs/user/configuration/#kubeadm-config-patches>.
  metrics-server and the kubelet certificate check:
  <https://github.com/kubernetes-sigs/metrics-server/blob/master/FAQ.md>.
- Topology spread and the taints policy:
  [04.02](../04-scheduling/02-affinity-taints-topology.md).
