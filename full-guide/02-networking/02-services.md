# 02 — Services

> A Service is a **stable name + virtual IP** in front of a churning set of Pod
> IPs. The four types (ClusterIP/NodePort/LoadBalancer/ExternalName),
> Endpoints vs. EndpointSlices, how kube-proxy turns a ClusterIP into a real
> DNAT (iptables vs. nftables vs. eBPF), headless Services, session affinity,
> and `externalTrafficPolicy` — applied by wiring every Bookstore tier with
> ClusterIP Services.

**Estimated time:** ~15 min read · ~30 min hands-on
**Prerequisites:** [Part 02 ch.01](01-networking-model.md) — the IP-per-Pod fabric · [Part 01 ch.04](../01-core-workloads/04-replicasets-and-deployments.md) — the Pods Services front
**You'll know after this:** • choose between ClusterIP, NodePort, LoadBalancer, and ExternalName · • read EndpointSlices and explain how kube-proxy programs DNAT (iptables / nftables / eBPF) · • configure a headless Service for direct Pod IPs · • use `sessionAffinity` and `externalTrafficPolicy` correctly · • wire every Bookstore tier behind a stable ClusterIP

<!-- tags: networking, services, clusterip, endpointslices, kube-proxy -->

## Why this exists

[ch.01](01-networking-model.md) gave every Pod a routable IP on a flat
network. But Pod IPs are **ephemeral**: a rollout
([Part 01 ch.04](../01-core-workloads/04-replicasets-and-deployments.md))
replaces every `catalog` Pod with new ones on new IPs; the HPA
([Part 06 ch.04](../06-production-readiness/04-autoscaling.md)) adds and removes
them; a crash reschedules one elsewhere. If `storefront` hardcoded a `catalog`
Pod IP it would break on the next deploy — and there are *several* catalog
Pods; which one?

A **Service** is the answer to both problems at once: a **stable virtual IP and
DNS name** that **load-balances** across the *current set of Ready Pods*
selected by label. The set changes constantly; the Service's identity does not.
This is the [Service Discovery](#further-reading) pattern, and it is the layer
that finally makes the Bookstore a connected system: `storefront → catalog`,
`storefront → orders`, `catalog → postgres`, `orders → rabbitmq` all become
*stable names*, not moving targets.

## Mental model

A Service is **a stable front door with an always-current address book**.

- The **front door** is a `ClusterIP` — a virtual IP that never changes for the
  Service's lifetime, plus a DNS name ([ch.03](03-dns-and-discovery.md)).
  Clients only ever know the door.
- The **address book** is the set of **endpoints**: the IP:port of every Pod
  that (a) matches the Service's label `selector` and (b) is **Ready** (passes
  its readiness probe, [Part 01 ch.02](../01-core-workloads/02-health-and-lifecycle.md)).
  A controller keeps it continuously in sync as Pods come and go.
- **kube-proxy** ([Part 00 ch.05](../00-foundations/05-node-components.md)) is
  the doorman on every node: it programs the kernel so a packet *to the front
  door* is rewritten (**DNAT**) to *one of the current address-book entries*.
  It is **not** a proxy process in the data path for ClusterIP — it configures
  iptables/nftables/eBPF and the kernel does the forwarding.

So: you talk to a name that never moves; Kubernetes keeps the name pointing at
exactly the healthy Pods, and rewrites your packets to land on one. The Service
**is the decoupling** between "who I call" and "which Pod answers".

## Threats and controls

A Service is a route, so its threats are about where a route leads and who
may add to one. A Service is not an access control: it does not decide who
may connect. [ch.06](06-network-policies.md) does that, and the flat network
that lets any Pod reach any Service is named in
[ch.01](01-networking-model.md). The table covers what this chapter teaches
against the Service itself.

| Threat | Control taught here | Goes deeper |
|---|---|---|
| The Service is reachable from outside the cluster because its type was changed without a decision | `ClusterIP` by default. A `NodePort` or `LoadBalancer` is an exposure decision, taken at the edge ([ch.04](04-ingress.md), [ch.05](05-gateway-api.md)) | [10.04](../10-cloud-and-managed-kubernetes/04-cloud-networking-and-load-balancing.md) |
| Whoever can create a Service with `spec.externalIPs` intercepts traffic to that IP (CVE-2020-8554, unfixed upstream) | No `externalIPs` field. [Upstream deprecated it in v1.36](https://kubernetes.io/blog/2026/05/14/kubernetes-v1-36-deprecation-and-removal-of-service-externalips/) | [05.07](../05-security/07-admission-control-and-policy-as-code.md) |
| A Pod that carries a selector's labels becomes an endpoint, whoever created it. A selector wider than one tier sends one tier's traffic to another tier's Pods | Narrow selectors that name the tier's own `app` label. RBAC decides who may create a Pod with those labels | [05.01](../05-security/01-authn-authz-rbac.md) |
| Write access to Endpoints or EndpointSlices lets a user send a Service's traffic to locations it could not reach otherwise (CVE-2021-25740, unfixed upstream) | No write access to Endpoints or EndpointSlices outside the controllers. [Upstream says](https://kubernetes.io/docs/concepts/services-networking/service/#services-without-selectors) endpoint IPs must not be loopback or link-local, and cannot be another Service's ClusterIP. Other addresses are allowed, so the write is the control point | [05.01](../05-security/01-authn-authz-rbac.md) |

The last two rows are RBAC questions. Who may create a Pod with a label, and
who may write an endpoint, decide whether a selector can be trusted. Both are
answered in [05.01](../05-security/01-authn-authz-rbac.md).

## Diagrams

### client → Service → kube-proxy DNAT → Pod (Mermaid)

```mermaid
flowchart LR
    cli["storefront Pod<br/>opens conn to<br/>catalog ClusterIP:80"]
    subgraph node["client's node (Linux kernel dataplane)"]
        kp["kube-proxy-programmed rules<br/>(iptables / nftables / eBPF)<br/>match dst = catalog ClusterIP:80"]
        ct["conntrack<br/>(remembers the chosen<br/>backend for this flow)"]
    end
    es["EndpointSlice: catalog<br/>Ready Pod IPs:<br/>10.244.2.9:8080<br/>10.244.1.4:8080<br/>10.244.3.6:8080"]
    p1["catalog Pod A<br/><I>(not chosen this flow)</i>"]
    p2["catalog Pod B"]
    p3["catalog Pod C<br/><I>(not chosen this flow)</i>"]

    cli -->|"dst: ClusterIP:80"| kp
    es -.->|"controller keeps rules in sync<br/>with READY endpoints"| kp
    kp -->|"DNAT: pick one endpoint<br/>(≈ even), rewrite dst"| ct
    ct -->|"rewritten: dst 10.244.1.4:8080"| p2
    p1 -.-|"endpoint, idle for this flow"| es
    p3 -.-|"endpoint, idle for this flow"| es
    note["No NAT box, no proxy hop: the NODE's kernel rewrites the packet.<br/>targetPort 8080 = the Pod's port; port 80 = the Service's port."]
    ct -.-> note
```

### Service types ladder (ASCII)

```
 reachability ladder — each type ADDS exposure on top of the previous
 ───────────────────────────────────────────────────────────────────────
 ExternalName  : DNS CNAME → external host   (NO proxy, NO selector)
                 e.g. db.bookstore.svc → my-rds.amazonaws.com

 ClusterIP     : stable virtual IP, IN-CLUSTER only            ◄ default
   └─ catalog / storefront / orders / redis / rabbitmq (Bookstore)

 NodePort      : ClusterIP  +  <NodeIP>:3xxxx on EVERY node
   └─ external reachable via any node IP (basic/manual exposure)

 LoadBalancer  : NodePort   +  a real external LB (cloud provisions it)
   └─ ClusterIP ⊂ NodePort ⊂ LoadBalancer  (superset adds, never replaces)

 headless (clusterIP: None): NO VIP at all → DNS returns the Pod IPs
   └─ used by the postgres StatefulSet (per-Pod stable DNS, ch.01 ch.03)
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).** Requires
the `bookstore` namespace and the catalog + storefront Deployments
([Part 01 ch.04](../01-core-workloads/04-replicasets-and-deployments.md)). This
chapter also adds the **orders** Deployment and minimal **redis** / **rabbitmq**
so every addressable tier has a real backend to put a Service in front of.

> **Scaffolding decision — redis & rabbitmq.** They are referenced in the
> Bookstore narrative but were not yet manifested. Part 02 needs them as
> concrete **Service/DNS/policy targets**, so this chapter adds deliberately
> minimal Deployments — `12-redis.yaml` (official `redis:7`) and
> `13-rabbitmq.yaml` (`rabbitmq:3.13-management`), no persistence/auth. They
> are **networking scaffolding only**; durable storage/config is
> [Part 03](../03-config-and-storage/01-configmaps.md), HA is
> [Part 03 ch.05](../03-config-and-storage/05-stateful-data-patterns.md). The
> Go services degrade gracefully with `REDIS_ADDR`/`AMQP_URL` unset (see
> [`app/catalog/main.go`](../examples/bookstore/app/catalog/main.go)), so this
> is wiring, not a hard dependency yet.

### 1. The backends these Services will select

New files (minimal, official images — pulled from the registry, **no
`kind load`**):
[`12-redis.yaml`](../examples/bookstore/raw-manifests/12-redis.yaml),
[`13-rabbitmq.yaml`](../examples/bookstore/raw-manifests/13-rabbitmq.yaml),
and the orders API
[`14-orders-deploy.yaml`](../examples/bookstore/raw-manifests/14-orders-deploy.yaml)
(same shape as `10-catalog-deploy.yaml`: probes from
[ch.02](../01-core-workloads/02-health-and-lifecycle.md), resources from
[ch.03](../01-core-workloads/03-resources-and-qos.md), native `preStop` sleep
because the image is distroless — no shell).

```sh
# from the repo root (full-guide/)
kubectl apply -f examples/bookstore/raw-manifests/12-redis.yaml
kubectl apply -f examples/bookstore/raw-manifests/13-rabbitmq.yaml
# orders (like catalog) carries DB_DSN, so it needs Postgres + the schema Job.
# These come from the earlier chapters' prerequisite chain; re-applying is harmless
# (idempotent) and keeps this chapter runnable on its own. orders' /readyz only
# goes Ready once the schema exists — gate on the migrate Job completing.
kubectl apply -f examples/bookstore/raw-manifests/16-db-credentials.yaml
kubectl apply -f examples/bookstore/raw-manifests/20-postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n bookstore
kubectl apply -f examples/bookstore/raw-manifests/21-db-migrate-job.yaml   # schema
kubectl wait --for=condition=complete job/db-migrate -n bookstore --timeout=120s
kubectl apply -f examples/bookstore/raw-manifests/14-orders-deploy.yaml   # needs bookstore/orders:dev loaded
kubectl get deploy -n bookstore
```

### 2. A ClusterIP Service per tier

New file
[`40-services.yaml`](../examples/bookstore/raw-manifests/40-services.yaml) —
five ClusterIP Services, one per app tier, and a headless Service for
`payments-worker`. The headless one has no endpoints in this chapter, because
that Deployment is not applied. Each `selector` is a **subset of the target
Deployment's pod-template labels** (`app: catalog` matches the
`10-catalog-deploy.yaml` pods, etc.). The inline catalog Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: catalog
  namespace: bookstore
  labels: { app: catalog, app.kubernetes.io/part-of: bookstore }
spec:
  type: ClusterIP            # default; in-cluster virtual IP only
  selector:
    app: catalog             # subset of 10-catalog-deploy pod labels
  ports:
    - name: http
      port: 80               # the STABLE Service port (catalog.bookstore:80)
      targetPort: http       # → the container's NAMED port (8080)
```

(`storefront`, `orders`, `redis`, `rabbitmq` follow the same pattern in the
file; `rabbitmq` additionally exposes `15672` for its management UI.)

> **Coexistence with the canary Service.** [Part 01
> ch.08](../01-core-workloads/08-deployment-strategies.md)'s
> `30-catalog-canary.yaml` *also* defines a Service named `catalog` in
> `bookstore` (the manual-canary teaching variant). This `40-services.yaml`
> defines the **canonical** `catalog` Service for the canonical
> `10-catalog-deploy.yaml`. They share the same name+namespace and **both
> select `app: catalog`**, so they are *compatible* (a whole-directory apply is
> last-write-wins on an identical object; the selector is the same either way).
> They pair with **mutually exclusive backends**: run *either* the canonical
> catalog (`10-` + `40-`) *or* the canary stack (`30-`), never both — exactly
> the lineage rule from ch.08. A whole-dir dry-run is valid in both cases.

```sh
# from the repo root (full-guide/)
kubectl apply -f examples/bookstore/raw-manifests/40-services.yaml
kubectl get svc -n bookstore
```

<!-- gate: output -->
```text
service/catalog created
service/storefront created
service/orders created
service/redis created
service/rabbitmq created
service/payments-worker created
```

<!-- gate: output -->
```text
NAME              TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)              AGE
catalog           ClusterIP   10.96.82.50     <none>        80/TCP               1s
orders            ClusterIP   10.96.43.23     <none>        80/TCP               0s
payments-worker   ClusterIP   None            <none>        8080/TCP             0s
postgres          ClusterIP   None            <none>        5432/TCP             68s
rabbitmq          ClusterIP   10.96.60.96     <none>        5672/TCP,15672/TCP   0s
redis             ClusterIP   10.96.243.123   <none>        6379/TCP             0s
storefront        ClusterIP   10.96.16.125    <none>        80/TCP               0s
```

`payments-worker` and `postgres` show `None`: both are headless, and
`payments-worker` has no endpoints in this chapter. The other five have a
virtual IP. The lab ran without `orders` and `rabbitmq`, which no step here
calls, so those two Services have no endpoints either.

Wait for catalog before you read its endpoints. With `15-catalog-config.yaml`
applied, catalog reads `REDIS_ADDR`, and its readiness check opens a
connection to `redis.bookstore.svc.cluster.local`, a name this file has just
created. The Pods therefore turn Ready only once the Services exist. In the
lab run they took about a minute after the Services appeared, and a wait placed
before this step timed out at 300 seconds with 0 of 3 Pods available.

```sh
kubectl rollout status deploy/catalog -n bookstore --timeout=300s
# The "address book": endpoints are the READY Pods the selector matched.
kubectl get endpointslices -n bookstore -l kubernetes.io/service-name=catalog -o wide
```

<!-- gate: output -->
```text
Waiting for deployment "catalog" rollout to finish: 0 of 3 updated replicas are available...
# ...
deployment "catalog" successfully rolled out
```

<!-- gate: output -->
```text
NAME            ADDRESSTYPE   PORTS   ENDPOINTS                             AGE
catalog-7864s   IPv4          8080    10.244.0.64,10.244.0.66,10.244.0.65   73s
```

One EndpointSlice holds the three Pod IPs, on the container port 8080 that the
Service's named `targetPort` resolves to. The `-o wide` view prints at most
three addresses and then `+ N more...`, so the scale steps below read the
slice with a `jsonpath` that prints every address and its `ready` flag.

Scale catalog up and watch the address book follow the Ready Pods:

```sh
kubectl scale deploy/catalog -n bookstore --replicas=4
kubectl rollout status deploy/catalog -n bookstore
kubectl get endpointslices -n bookstore -l kubernetes.io/service-name=catalog \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
```

<!-- gate: output -->
```text
10.244.0.64 ready=true
10.244.0.66 ready=true
10.244.0.65 ready=true
10.244.0.75 ready=true
```

Four Ready Pods, four addresses. Scale back down. The slice is read twice,
right away and after 35 seconds:

```sh
kubectl scale deploy/catalog -n bookstore --replicas=3
kubectl rollout status deploy/catalog -n bookstore
kubectl get endpointslices -n bookstore -l kubernetes.io/service-name=catalog \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
sleep 35
kubectl get endpointslices -n bookstore -l kubernetes.io/service-name=catalog \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
```

<!-- gate: output -->
```text
10.244.0.64 ready=true
10.244.0.66 ready=true
10.244.0.65 ready=true
10.244.0.75 ready=false
```

<!-- gate: output -->
```text
10.244.0.64 ready=true
10.244.0.66 ready=true
10.244.0.65 ready=true
```

Right after the scale-down the fourth address is still in the slice, marked
`ready=false`. That Pod is terminating: the catalog Deployment gives it a 5 s
`preStop` sleep and a 30 s grace period. An endpoint that is not Ready gets no
new connections from kube-proxy, and the slice drops it once the Pod is gone
([EndpointSlice conditions](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/#conditions)).
So the address book follows readiness, and a removed Pod stops receiving
traffic before it disappears.

### 3. The Service is a stable front door (prove the decoupling)

`catalog` is distroless, with no shell, so `kubectl exec` into it is not an
option. Call it from a client Pod instead. The client carries the baseline,
and its image is pinned by digest with the tag in a comment, as
[the baseline](../01-core-workloads/01-pods.md#baseline-image-digest) asks.
Its process is a `sleep`, and `kubectl exec` runs `curl` inside it. Save this
block as `client.yaml`. The ServiceAccount is the client's own, so the Pod
does not run as `default`. It mounts no token, because it makes no API calls.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: client
  namespace: bookstore
  labels:
    app.kubernetes.io/part-of: bookstore
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: bookstore
  labels:
    app: client                       # no Service selects this label
    app.kubernetes.io/part-of: bookstore
spec:
  serviceAccountName: client
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 100                    # curl_user, the UID the image declares
    runAsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: curlimages/curl@sha256:8addc281f0ea517409209f76832b6ddc2cabc3264feb1ebbec2a2521ffad24e4  # curlimages/curl:8.9.1
      command: ["sleep", "3600"]      # idle; kubectl exec runs curl in it
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

```sh
kubectl apply -f client.yaml
kubectl wait --for=condition=Ready pod/client -n bookstore --timeout=120s
kubectl get svc catalog -n bookstore -o jsonpath='{.spec.clusterIP}{"\n"}'
kubectl get pods -n bookstore -l app=catalog -o custom-columns=NAME:.metadata.name,IP:.status.podIP
kubectl exec -n bookstore client -- sh -c 'for i in 1 2 3 4 5 6; do curl -s http://catalog.bookstore.svc.cluster.local/books | head -c 60; echo; done'
kubectl exec -n bookstore client -- curl -s http://catalog.bookstore.svc.cluster.local/healthz
```

<!-- gate: output -->
```text
serviceaccount/client created
pod/client created
```

<!-- gate: output -->
```text
pod/client condition met
```

<!-- gate: output -->
```text
10.96.82.50
```

<!-- gate: output -->
```text
NAME                       IP
catalog-7c8b656664-crv7n   10.244.0.64
catalog-7c8b656664-l85wm   10.244.0.65
catalog-7c8b656664-rg88p   10.244.0.66
```

<!-- gate: output -->
```text
[]
[]
[]
[]
[]
[]
```

<!-- gate: output -->
```text
{"status":"ok"}
```

Each call answers from one of the Ready catalog Pods. kube-proxy picks the
Pod for each new connection, so the caller never names a Pod. The list is
empty because the migration creates the tables and adds no books. The six
identical lines do not show which Pod answered. The point is that the caller
used one name and one Service IP, `10.96.82.50`, while three Pods sat behind it.

Now roll catalog. Its Pod IPs change, and the Service IP does not. The loop
runs for a minute while the rollout replaces every catalog Pod, and it counts
the HTTP status of each call:

```sh
kubectl exec -n bookstore client -- sh -c 'for i in $(seq 1 60); do curl -s -o /dev/null -w "%{http_code}\n" http://catalog.bookstore.svc.cluster.local/healthz; sleep 1; done | sort | uniq -c' &
kubectl rollout restart deploy/catalog -n bookstore
kubectl rollout status deploy/catalog -n bookstore --timeout=240s
wait
kubectl get svc catalog -n bookstore -o jsonpath='{.spec.clusterIP}{"\n"}'
kubectl get pods -n bookstore -l app=catalog -o custom-columns=NAME:.metadata.name,IP:.status.podIP
kubectl get endpointslices -n bookstore -l kubernetes.io/service-name=catalog -o wide
kubectl exec -n bookstore client -- curl -s http://catalog.bookstore.svc.cluster.local/healthz
```

<!-- gate: output -->
```text
     60 200
```

All 60 calls answered `200` while every catalog Pod was replaced. The
Deployment's `maxUnavailable: 0` keeps the old Pods until the new ones are
Ready, and the `preStop` sleep gives the endpoint controller time to drop a
terminating Pod before it stops answering.

<!-- gate: output -->
```text
10.96.82.50
```

<!-- gate: output -->
```text
NAME                       IP
catalog-7cb8c65f6b-2kqj4   10.244.0.85
catalog-7cb8c65f6b-bv4ss   10.244.0.83
catalog-7cb8c65f6b-r6xhb   10.244.0.82
```

<!-- gate: output -->
```text
NAME            ADDRESSTYPE   PORTS   ENDPOINTS                             AGE
catalog-7864s   IPv4          8080    10.244.0.82,10.244.0.83,10.244.0.85   3m35s
```

<!-- gate: output -->
```text
{"status":"ok"}
```

Compare the two Pod lists. All three names and all three IPs changed, from
`10.244.0.64` to `.66` before the restart and `.82` to `.85` after. The Service
IP stayed `10.96.82.50`, the EndpointSlice kept its name and now lists the new
Pods, and the client's call by name never failed. The client is the proof that
a Service name is the stable thing to depend on, and a Pod IP is not.

The lab names differ from the commands above in one place: the namespace was
`p02-finish-svc`, so the DNS name in the commands read
`catalog.p02-finish-svc.svc.cluster.local` there.

### 4. Headless is different — recall postgres

The postgres StatefulSet's Service
([`20-postgres-statefulset.yaml`](../examples/bookstore/raw-manifests/20-postgres-statefulset.yaml))
is `clusterIP: None` (**headless**): no VIP, DNS returns the Pod IP(s) directly,
giving the per-ordinal names `postgres-0.postgres.bookstore.svc.cluster.local`
([Part 01 ch.05](../01-core-workloads/05-statefulsets.md)). catalog/storefront
want **one VIP that load-balances** (ClusterIP); postgres wants **stable
per-Pod identity** (headless). Same API object, opposite goals.

```sh
kubectl get svc postgres -n bookstore
kubectl get svc -n bookstore
```

<!-- gate: output -->
```text
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)    AGE
postgres   ClusterIP   None         <none>        5432/TCP   8m34s
```

`TYPE` still reads `ClusterIP`, but `CLUSTER-IP` is `None`. That pair is what
a headless Service looks like.

> **Lineage note.** `40-services.yaml` is the canonical Services layer for the
> Bookstore from here on. [ch.03](03-dns-and-discovery.md) shows how these
> names *resolve*; [ch.04](04-ingress.md) (`50-ingress.yaml`) /
> [ch.05](05-gateway-api.md) (`51-gateway.yaml`) put an **external** entrypoint
> in front of the `storefront`/`catalog`/`orders` Services;
> [ch.06](06-network-policies.md) (`60-networkpolicy.yaml`) restricts which Pod
> may reach which Service. The `postgres` headless Service stays in
> [`20-postgres-statefulset.yaml`](../examples/bookstore/raw-manifests/20-postgres-statefulset.yaml),
> from [Part 01 ch.05](../01-core-workloads/05-statefulsets.md), and is not
> duplicated here.

### 5. What the proxy runs, and what the field says

Check two things on the cluster you use. The kube-proxy config names its
mode, and the API describes `externalIPs`:

```sh
kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' | grep -n 'mode:'
kubectl explain service.spec.externalIPs
```

<!-- gate: output -->
```text
52:mode: iptables
```

This lab cluster sets `iptables` explicitly. Set the mode yourself on your own
clusters, as the [kube-proxy modes](#kube-proxy-modes-iptables-vs-nftables-vs-ebpf)
section below explains, so an upgrade cannot change it. The API's description
of the field follows. It says the IPs are "not managed by Kubernetes", which
is why the [threats table](#threats-and-controls) treats the field as a choice
you make by hand. It does not mention the deprecation. The
[upstream post of 2026-05-14](https://kubernetes.io/blog/2026/05/14/kubernetes-v1-36-deprecation-and-removal-of-service-externalips/)
records that.

<!-- gate: output -->
```text
KIND:       Service
VERSION:    v1

FIELD: externalIPs <[]string>

DESCRIPTION:
    externalIPs is a list of IP addresses for which nodes in the cluster will
    also accept traffic for this service.  These IPs are not managed by
    Kubernetes.  The user is responsible for ensuring that traffic arrives at a
    node with this IP.  A common example is external load-balancers that are not
    part of the Kubernetes system.
```

## How it works under the hood

### Endpoints vs. EndpointSlices (why slices)

When you create a Service with a `selector`, the **EndpointSlice controller**
([Part 00 ch.04](../00-foundations/04-control-plane-deep-dive.md)) watches Pods
matching it and maintains the backing address list. Historically this was a
single **Endpoints** object per Service — one object listing *every* endpoint.
At scale that object is huge and **every Pod change rewrites and re-pushes the
whole thing to every node's kube-proxy** — an O(N) churn storm.

**EndpointSlices** are the mechanism every current client should read. The
v1 `Endpoints` API has been deprecated since v1.33. The EndpointSlice
controller shards the list into slices of at most 100 endpoints by default.
A Pod change rewrites only its *slice*, dramatically less churn and watch
traffic. Slices also carry richer per-endpoint info (topology zone,
per-endpoint conditions `ready`/`serving`/`terminating`) that enables
**topology-aware routing**. The truth about where a Service sends traffic is
`kubectl get endpointslices -n <NS> -l kubernetes.io/service-name=<SVC>`.

### kube-proxy modes: iptables vs. nftables vs. eBPF

kube-proxy ([Part 00 ch.05](../00-foundations/05-node-components.md)) watches
Services + EndpointSlices and programs the node so the ClusterIP works. It is
**not in the data path** for ClusterIP — it writes kernel rules; the kernel
forwards:

- **iptables (default).** Per Service, a chain that **DNATs** the ClusterIP:port
  to a randomly chosen endpoint, with a probability rule per endpoint for
  rough even spread. **conntrack** then pins that flow to the chosen backend
  (so every packet of one connection goes to the same Pod). Simple, ubiquitous;
  rule evaluation is ~linear, so very large Services (tens of thousands of
  endpoints) get slower to *program* and match.
- **nftables.** The same DNAT-plus-conntrack model, written through nftables,
  the kernel's successor to the iptables API. It needs Linux kernel 5.13 or
  later. It processes endpoint changes faster than iptables and matches
  packets more efficiently at very large scale. `iptables` is still the
  default, and upstream plans to change it to `nftables`, so set `mode`
  explicitly in kube-proxy's config. An upgrade then cannot change the proxy
  under you.
- **IPVS (deprecated since v1.35).** Uses the kernel's L4 load balancer (hash
  tables) and was once *the* answer to iptables scaling, but it never covered
  every Service edge case. Upstream expects to disable it by default by v1.40
  and remove it by v1.43; move IPVS clusters to nftables.
- **eBPF (CNI replacement).** Cilium (or Calico eBPF) **replaces kube-proxy
  entirely**: an eBPF program does the Service load-balancing/DNAT in the
  kernel fast path — best performance and integrates with policy/observability.

The data path in all cases: client → dst=ClusterIP:port → kernel matches the
kube-proxy-programmed rule → **DNAT** to `endpointIP:targetPort` → conntrack
records the choice → reply is un-DNATed transparently. No extra hop.

### port vs. targetPort vs. nodePort

- **`port`** — the port the **Service** listens on (what clients use:
  `catalog.bookstore:80`).
- **`targetPort`** — the **Pod/container** port traffic is DNAT'd *to*. Best
  practice (used throughout the Bookstore): a **named** port (`targetPort: http`)
  so the container can change its number without editing the Service.
- **`nodePort`** — only for `type: NodePort`/`LoadBalancer`: a port in
  `30000–32767` opened on **every node** that forwards into the Service.

### Service types — what each adds

- **ClusterIP** (default) — virtual IP reachable **only inside** the cluster.
  All five Bookstore app Services. External access is the job of
  [ch.04](04-ingress.md)/[ch.05](05-gateway-api.md), *not* by switching type.
- **NodePort** — ClusterIP **plus** `<NodeIP>:<nodePort>` on every node.
  External, but raw (you manage node IPs/ports). The substrate Ingress sits on.
- **LoadBalancer** — NodePort **plus** the cloud provisions a **real external
  LB** (via the cloud-controller-manager,
  [Part 00 ch.03](../00-foundations/03-architecture-overview.md)) targeting the
  NodePort. On bare `kind` there is no cloud LB so it stays `<pending>` (use
  `port-forward`/NodePort, or MetalLB) — a key local-vs-cloud difference.
- **ExternalName** — **no selector, no proxy, no VIP**: DNS returns a **CNAME**
  to an external host. Used to give an out-of-cluster dependency (e.g. a
  managed RDS) a stable in-cluster name.
- **`spec.externalIPs`**: not a type. Any type can carry a list of IPs that
  the cluster may not own. Traffic that arrives for one of those IPs on the
  Service port is routed to the Service's endpoints. Upstream
  [deprecated the field in v1.36](https://kubernetes.io/blog/2026/05/14/kubernetes-v1-36-deprecation-and-removal-of-service-externalips/)
  and tells users to migrate away from it, toward an external load balancer
  controller or a Gateway API implementation. The reason is
  CVE-2020-8554: whoever can create a Service with the field can intercept
  traffic to the IP it names.

### Headless, sessionAffinity, externalTrafficPolicy

- **Headless (`clusterIP: None`)** — no VIP allocated; DNS for the Service
  returns the **Pod IPs** directly (and, with a StatefulSet, per-Pod names).
  For client-side LB / discovery / StatefulSets
  ([Part 01 ch.05](../01-core-workloads/05-statefulsets.md)).
- **`sessionAffinity: ClientIP`** — sticky by source IP (a `timeoutSeconds`
  bounds it) instead of per-connection spread. Coarse stickiness (clients
  behind one NAT pin together); real session affinity is usually L7
  ([ch.04](04-ingress.md)).
- **`externalTrafficPolicy`** (NodePort/LoadBalancer) — `Cluster` (default):
  external traffic may be **SNAT'd and hop** node→node to any endpoint
  (even spread, but **client source IP lost**). `Local`: only deliver to
  endpoints **on the receiving node** (no extra hop, **preserves client IP**,
  enables real LB health-checking) — but skews load if Pods aren't evenly
  spread. `internalTrafficPolicy` is the in-cluster analogue.

### What a Service is *not*

A Service is **not a service mesh**: no retries, mTLS, circuit-breaking,
per-request weighting, or L7 routing. It is L3/L4 stable-VIP load-balancing.
L7 concerns are Ingress/Gateway ([ch.04](04-ingress.md)/[ch.05](05-gateway-api.md))
or a mesh (explicitly out of scope for this guide — introduced conceptually
only here and in [Part 07 ch.05](../07-delivery/05-progressive-delivery.md)).

## Production notes

> **In production:** prefer **named `targetPort`s** (the Bookstore convention)
> so containers can change ports without editing every Service. Keep `port`
> stable — clients depend on it.

> **In production:** trustworthy **readiness probes are load-balancing
> correctness**, not just rollout safety
> ([Part 01 ch.02](../01-core-workloads/02-health-and-lifecycle.md)). An
> endpoint is in the Service set **iff Ready**. A lying readiness probe sends
> traffic to a Pod that can't serve; a missing one routes to Pods during
> startup. The probe *is* the in/out switch.

> **In production:** choose the kube-proxy mode for scale, and set it
> explicitly. **iptables** is fine for most clusters; at **thousands of
> Services/endpoints** move to **nftables** (kernel 5.13 or later) or an **eBPF**
> dataplane (Cilium) — iptables rule programming/matching becomes a
> measurable latency and control-plane cost. Don't choose **IPVS** for a new
> cluster: it has been deprecated since v1.35
> ([Part 00 ch.05](../00-foundations/05-node-components.md)).

> **In production:** `externalTrafficPolicy: Local` when you **need the real
> client IP** (audit, geo, rate-limit, WAF) or want the cloud LB to health-check
> only nodes with endpoints — but pair it with **even Pod spread**
> ([Part 04 ch.02](../04-scheduling/02-affinity-taints-topology.md)) or some
> nodes get all the traffic. `Cluster` spreads evenly but **SNATs away the
> client IP**.

> **In production (EKS/GKE/AKS):** `type: LoadBalancer` provisions (and
> **bills for**) one cloud LB **per Service** — don't expose many that way.
> Put one LB in front of an **Ingress/Gateway** controller and route many
> Services through it at L7 ([ch.04](04-ingress.md)/[ch.05](05-gateway-api.md)).
> Annotations select NLB vs ALB / internal vs internet-facing / health checks —
> provider-specific. Bare `kind` has **no** cloud LB (stays `<pending>`).

> **In production:** for in-cluster traffic, **topology-aware routing**
> (EndpointSlice hints: `spec.trafficDistribution: PreferSameZone`, or the
> older `service.kubernetes.io/topology-mode: Auto` annotation)
> and `internalTrafficPolicy: Local` keep traffic **in-zone** to cut cross-AZ
> latency and **cross-AZ data-transfer cost** — but validate it doesn't create
> hot spots when a zone is light on replicas.

## Quick Reference

```sh
kubectl get svc -n <NS>                                  # types + ClusterIPs
kubectl get endpointslices -n <NS> \
  -l kubernetes.io/service-name=<SVC> -o wide            # the real backends
kubectl describe svc <SVC> -n <NS>                       # selector, ports, endpoints
kubectl get svc <SVC> -n <NS> \
  -o jsonpath='{.spec.clusterIP}{"\n"}'                  # the stable VIP
# expose for a quick local test WITHOUT changing Service type (ch.04 alt):
kubectl port-forward -n <NS> svc/<SVC> 8080:80
# call a Service from the baseline client Pod of step 3 (never exec into a
# distroless app Pod):
kubectl exec -n <NS> client -- \
  curl -s http://<SVC>.<NS>.svc.cluster.local:<PORT>/<PATH>
kubectl -n kube-system get ds kube-proxy                 # kube-proxy (mode in its cm)
```

Minimal ClusterIP Service, for the catalog tier (change the name, namespace
and `app` label for another tier):

```yaml
apiVersion: v1
kind: Service
metadata: { name: catalog, namespace: bookstore, labels: { app: catalog } }
spec:
  type: ClusterIP                  # default; omittable
  selector: { app: catalog }       # subset of the target Pods' labels
  ports:
    - name: http
      port: 80                     # stable Service port (clients use this)
      targetPort: http             # container's named port (e.g. 8080)
```

For a headless Service, set `spec.clusterIP: None`. DNS then returns the Pod
IPs, which is what StatefulSets use.

Checklist:

- [ ] `selector` is a subset of the target workload's **pod-template** labels
- [ ] `targetPort` uses the container's **named** port (number can change)
- [ ] Readiness probe trustworthy (it gates endpoint membership)
- [ ] Type chosen deliberately (ClusterIP default; LB only via Ingress at edge)
- [ ] No `spec.externalIPs`
- [ ] Headless **iff** you need per-Pod DNS / client-side LB (StatefulSets)
- [ ] `externalTrafficPolicy: Local` only with even Pod spread; know the IP/SNAT trade-off
- [ ] kube-proxy mode (iptables/nftables/eBPF) fits the cluster's Service scale
- [ ] kube-proxy mode set explicitly, and not the deprecated IPVS

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **A teammate believes kube-proxy is "the load balancer" in the data path for ClusterIP traffic. Why is this wrong, and what's actually doing the forwarding?**
   <details><summary>Show answer</summary>

   kube-proxy is a *controller* that programs iptables/nftables/eBPF rules on each node based on Services and EndpointSlices; the **kernel** does the per-packet DNAT and forwarding. For a ClusterIP, no userspace proxy sits in the data path — a packet to `ClusterIP:port` hits the kernel rule, gets DNAT'd to a chosen endpoint IP:port, and conntrack pins the flow. This is why ClusterIP has near-zero per-hop overhead (see §Mental model and §kube-proxy modes).

   </details>

2. **You scale `catalog` from 3 to 10 replicas. Within ~1 second, traffic spreads across all 10. Walk through which controllers and components made this happen.**
   <details><summary>Show answer</summary>

   (1) Deployment controller creates 7 new Pods. (2) kubelet starts them; readiness probe passes (they're Ready). (3) EndpointSlice controller, watching Pods matching the Service's selector, adds the 7 new Pod IPs to the EndpointSlice(s). (4) Every node's kube-proxy is watching EndpointSlices, sees the updated set, and rewrites the iptables/nftables/eBPF rules. (5) The kernel's DNAT now includes the new endpoints, so load balances across all 10. The Service VIP never changed; the address book did (see §Mental model and §How it works under the hood, EndpointSlices).

   </details>

3. **A Service of type `LoadBalancer` stays `<pending>` on a kind cluster. On EKS, the same manifest provisions an LB but you find your team has 30 of them and a surprise cloud bill. Explain both observations.**
   <details><summary>Show answer</summary>

   `kind` has no cloud-controller-manager, so nothing watches Service type=LoadBalancer to allocate an LB, so it stays `<pending>` forever. On EKS, the cloud-controller-manager provisions a real cloud LB (NLB/ALB) per Service of type LoadBalancer. Each one is a separate billed resource, so 30 Services means 30 LBs. The pattern is one cloud LB for the cluster, fronting an Ingress/Gateway controller that L7-routes to many Services (see §Service types and §Production notes, EKS/GKE/AKS).

   </details>

4. **You set `externalTrafficPolicy: Local` on a NodePort Service to preserve client IPs, but your monitoring shows uneven traffic — some nodes get 5x more requests than others. What's happening and what's the fix?**
   <details><summary>Show answer</summary>

   `Local` only delivers traffic to endpoints *on the receiving node*, with no SNAT/hop. If Pods are unevenly spread across nodes (e.g., one node has 3 catalog Pods, another has 1), the cloud LB still distributes evenly across nodes, but the node with more Pods absorbs proportionally more traffic. Fix: pair `Local` with `topologySpreadConstraints` to spread Pods evenly across nodes (see §Headless, sessionAffinity, externalTrafficPolicy and §Production notes).

   </details>

5. **Hands-on extension: apply `40-services.yaml`, then `kubectl rollout restart deploy/catalog -n bookstore`. From an ephemeral debug Pod, `curl http://catalog.bookstore.svc.cluster.local/healthz` repeatedly during the rollout. What do you observe, and what does it prove?**
   <details><summary>What you should see</summary>

   Every call succeeds, even though every catalog Pod IP changes during the rollout. The Service VIP and DNS name are stable; the EndpointSlice controller continuously removes terminating Pods (failing readiness) and adds new Ready ones. kube-proxy keeps node rules in sync. This proves the decoupling: clients never need to know Pod IPs, and rollouts cause zero observable interruption *iff* readiness probes are honest about when a Pod can serve (see §3. The Service is a stable front door).

   </details>

6. **A teammate adds `externalIPs: [203.0.113.10]` to the `catalog` Service so
   the office network can reach it. What does the field do, what is the
   threat, and what should they use instead?**
   <details><summary>Show answer</summary>

   `spec.externalIPs` makes the cluster route traffic for that IP and port to
   the Service's endpoints, whether or not the cluster owns the address. Anyone
   who can create a Service with the field can intercept traffic to the IP it
   names (CVE-2020-8554, unfixed upstream). Upstream
   [deprecated the field in v1.36](https://kubernetes.io/blog/2026/05/14/kubernetes-v1-36-deprecation-and-removal-of-service-externalips/)
   and recommends an external load balancer controller or a Gateway API
   implementation. In this guide that is [ch.05](05-gateway-api.md), and the
   admission rule that refuses the field is
   [05.07](../05-security/07-admission-control-and-policy-as-code.md).

   </details>

## Further reading

- **Lukša, _Kubernetes in Action_ 2e, ch.11 — "Exposing Pods with Services"**
  — Service types, endpoints, kube-proxy, headless, sessionAffinity.
- **Rosso et al., _Production Kubernetes_, ch.6 — "Service Routing"** —
  kube-proxy dataplanes and routing at production scale; **Ibryam & Huß,
  _Kubernetes Patterns_ 2e, ch.13 — _Service Discovery_** — the pattern.
- Official: <https://kubernetes.io/docs/concepts/services-networking/service/>
  ("Service") and
  <https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/>
  ("EndpointSlices").
- CVE-2020-8554: <https://nvd.nist.gov/vuln/detail/CVE-2020-8554> and the
  upstream issue <https://github.com/kubernetes/kubernetes/issues/97076>.
- The Kubernetes project blog post of 2026-05-26 on unfixed CVEs, for the
  status of CVE-2020-8554 and CVE-2021-25740 and the RBAC mitigation:
  <https://kubernetes.io/blog/2026/05/26/reconciling-unfixed-kubernetes-cves/>.
- The Kubernetes project blog post of 2026-05-14 on the deprecation of
  `spec.externalIPs` in v1.36:
  <https://kubernetes.io/blog/2026/05/14/kubernetes-v1-36-deprecation-and-removal-of-service-externalips/>.
