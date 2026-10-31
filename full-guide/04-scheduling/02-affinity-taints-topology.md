# 02 — Affinity, taints, and topology

> Steering placement: node affinity (`requiredDuringSchedulingIgnoredDuringExecution`
> vs `preferred…`, what *IgnoredDuringExecution* really means,
> `nodeAffinity` vs. the older `nodeSelector`); inter-pod affinity &
> anti-affinity (`topologyKey`, the scale/cost caveat, hard anti-affinity for
> HA); taints & tolerations (`NoSchedule`/`PreferNoSchedule`/`NoExecute`,
> `tolerationSeconds`, built-in taints); `topologySpreadConstraints`
> (`maxSkew`, `whenUnsatisfiable`, `minDomains` GA 1.30,
> `nodeAffinityPolicy`/`nodeTaintsPolicy`, `matchLabelKeys`) — applied by
> spreading the Bookstore for HA and pinning Postgres to a dedicated node.

**Estimated time:** ~30 min read · ~60 min hands-on
**Prerequisites:** [Part 04 ch.01](01-scheduler-and-nodes.md) — the scheduling pipeline you're influencing · [Part 01 ch.04](../01-core-workloads/04-replicasets-and-deployments.md) — replicas you're spreading
**You'll know after this:** • configure required vs. preferred node affinity and know what *IgnoredDuringExecution* really means · • use inter-pod (anti-)affinity with `topologyKey` for HA without exploding scheduling cost · • build a dedicated node pool from a taint, a toleration and required node affinity, and say which part of it the scheduler does not enforce · • design `topologySpreadConstraints` with the right `maxSkew` and `whenUnsatisfiable`, and say why spread is availability, not security · • pin Postgres to the dedicated pool and keep the stateless tiers off it

<!-- tags: scheduling, affinity, taints-tolerations, topology-spread, ha -->

## Why this exists

[ch.01](01-scheduler-and-nodes.md) showed *how* the scheduler picks a node. By
default it picks well, but it cannot read your intent. It does not know that:

- the three `catalog` replicas must land on **different nodes/zones**, so one
  machine or one zone failing does not take the whole catalog tier down;
- `postgres` should run on a **dedicated, isolated node** with fast disks and no
  noisy neighbours — and that *nothing else* should drift onto that node;
- a node reserved for the data tier must **repel** general workloads unless they
  explicitly opt in.

Those are placement *policies*, and Kubernetes expresses them with four
cooperating mechanisms: **node affinity** ("I want nodes *like this*"),
**inter-pod (anti-)affinity** ("near / away from *these other Pods*"), **taints
& tolerations** ("this node repels Pods unless they tolerate it"), and
**topology spread constraints** ("spread my replicas *evenly* across these
domains"). This is the heart of the [Automated Placement](#further-reading)
pattern, and it is what makes the Bookstore *highly available* instead of merely
*running*. We apply all four to real Bookstore manifests in this chapter.

Placement is also a security question, and the scheduler does not answer it.
A taint keeps other Pods off a node, but any author who can create a Pod, or
a workload that creates one, can write the matching toleration. A Pod that
sets `nodeName` skips the scheduler, and a `NoSchedule` taint did not stop it
in [ch.01](01-scheduler-and-nodes.md). Each case is covered below or there,
with the control that answers it.

## Mental model

Two of these mechanisms **attract**, two **repel** — and they combine:

- **Node affinity / `nodeSelector`** — *Pod → node label* matching. "Schedule
  me only on (or preferably on) nodes carrying these labels." Pure attraction
  toward node properties. `nodeSelector` is the old, simple, AND-only form;
  `nodeAffinity` is its superset (operators, `preferred` with weights, OR-ish
  expressions).
- **Inter-pod affinity / anti-affinity** — *Pod → other Pods*, evaluated within
  a **`topologyKey`** domain (a node label like `kubernetes.io/hostname` or
  `topology.kubernetes.io/zone`). Affinity = "co-locate with Pods like X in the
  same domain"; **anti**-affinity = "keep me out of any domain that already has
  Pods like X" — the HA spreading primitive.
- **Taints & tolerations** — the **node's** side. A *taint* on a node repels all
  Pods; only a Pod with a matching *toleration* may (still must be otherwise
  attracted to) land there. Taint = repel-by-default; toleration = "I'm allowed
  past this particular fence". A toleration lifts the taint's refusal
  and never attracts; pair it with affinity to pull the Pod in. It is not an
  authorization: the scheduler does not check who wrote it.
- **Topology spread constraints** — declare the **maximum imbalance**
  (`maxSkew`) of *my* Pods across a set of domains (`topologyKey`), and whether
  violating it is a hard error (`DoNotSchedule`) or just disfavoured
  (`ScheduleAnyway`). It is the precise, modern way to say "spread evenly",
  superseding the blunt hard-anti-affinity trick for most cases.

Rule of thumb the Bookstore uses: **spread the stateless tiers** (catalog,
storefront) across nodes/zones for HA; **isolate the sensitive workload**
(postgres, the data tier) on a **dedicated node pool**, with a taint, a
toleration and required node affinity together.

## Threats and controls

| Threat | Control taught here | Deeper |
|---|---|---|
| General Pods drift onto the dedicated pool | `NoSchedule` taint on the pool node | none |
| A sensitive Pod lands on a general node | required node affinity on the pool label, not preferred | none |
| Any author writes the toleration and lands on the pool | RBAC on who may create or update Pods and the workloads that carry a pod template (in the lab, `catalog-sa` may do neither); the taint itself is not a boundary | RBAC: [05.01](../05-security/01-authn-authz-rbac.md); restricting tolerations by admission: [05.07](../05-security/07-admission-control-and-policy-as-code.md) |
| A Pod sets `nodeName` and skips the scheduler's `NoSchedule` check | none in the scheduler. Ch.01 shows the bypass; the kubelet refuses only a Pod that does not tolerate a `NoExecute` taint | deny `nodeName` in sensitive namespaces, [Part 04 ch.01](01-scheduler-and-nodes.md#6-refuse-nodename-in-a-sensitive-namespace); admission [05.07](../05-security/07-admission-control-and-policy-as-code.md) |
| A node labels itself into the pool, or removes its own taint | NodeRestriction refuses both for a key under `node-restriction.kubernetes.io/` (tested in section 2). An unprefixed key stays open to a kubelet, so the pool key carries the prefix | none |
| Pods share a node, so they share its kernel | not solved by placement | [05.05](../05-security/05-kernel-isolation.md) |

Topology spread is availability, not security. It limits what one node or
zone failure takes down, and it does nothing against an author who can create
Pods. Scheduling is not a security boundary by itself: each row above is a
placement rule, or a check on who may write one.

## Diagrams

### Anti-affinity / spread placing replicas across nodes & zones (Mermaid)

```mermaid
flowchart TB
    subgraph zoneA["zone a"]
        n1["node-1"]
        n2["node-2"]
    end
    subgraph zoneB["zone b"]
        n3["node-3"]
        n4["node-4 (pool: tainted dedicated=database, labelled node-restriction pool=database)"]
    end

    c1["catalog replica 1"]
    c2["catalog replica 2"]
    c3["catalog replica 3"]
    pg["postgres-0<br/>tolerates the taint, requires the pool label"]
    x["general Pod<br/>(no toleration)"]

    c1 --> n1
    c2 --> n2
    c3 --> n3
    pg --> n4
    x -. repelled by NoSchedule taint .-x n4

    note["topologySpread maxSkew=1, ScheduleAnyway<br/>=> a preference: catalog spreads when it can;<br/>preferred anti-affinity adds a nudge"]
    note -. applies to .-> c1
    note -. applies to .-> c2
    note -. applies to .-> c3
```

### Taint / toleration match table & effects (ASCII)

```
A toleration matches a taint when key (+ value if operator=Equal) AND effect agree.

  Node taint                          Pod toleration                    Result
  ----------------------------------  --------------------------------  ----------------
  dedicated=database:NoSchedule       (none)                            NOT placed here
  dedicated=database:NoSchedule       key=dedicated Equal database      MAY be placed
                                        effect=NoSchedule                (if also attracted)
  dedicated=database:NoSchedule       operator=Exists key=dedicated     MAY be placed
  node.kubernetes.io/not-ready:       operator=Exists                   tolerates not-ready
    NoExecute                           effect=NoExecute                 forever
  node.kubernetes.io/not-ready:       (auto-added by default,           evicted after 300s
    NoExecute                           tolerationSeconds: 300)          if node stays bad

Effects (what the taint does):
  NoSchedule        new Pods without a matching toleration are NOT scheduled here
  PreferNoSchedule  scheduler AVOIDS this node, but will use it if nothing else fits
  NoExecute         as NoSchedule, AND already-running Pods lacking the toleration
                    are EVICTED (after tolerationSeconds, if set; immediately if not)
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).** This
chapter makes the Bookstore highly available and isolates its data tier. The
scheduling fields sit in existing manifests, `10-catalog-deploy.yaml`,
`11-storefront-deploy.yaml` and `20-postgres-statefulset.yaml`, as a clearly
marked *Part 04 scheduling layer*. **Every prior field
(ConfigMap/Secret/DSN/volumes/probes/preStop/labels/namespace) is preserved
unchanged; only placement fields are added.**

Those files are shared. The other chapters that apply the raw manifests run
them on a single-node kind cluster, and the Kustomize base and the Helm chart
carry the same fields, so they must run on one node. This chapter uses three
nodes and does not edit them. Where the three-node layout needs a different rule, you
patch the running object and read why, in sections 3 and 4.

### 1. A multi-node kind cluster (so spreading has somewhere to spread)

A default `kind create cluster` is **single-node**, and a spread over
`kubernetes.io/hostname` has only one domain there. This chapter uses the
three-node config from [ch.01](01-scheduler-and-nodes.md): one control plane
and two workers. It sits beside the Part 05 lab cluster config, as
`cluster-three-node.yaml`
([source](../examples/security-lab/kind/cluster-three-node.yaml)).
It is infrastructure, not a Bookstore manifest. It labels each worker with a
zone, `zone-a` and `zone-b`, by hand, because kind has no zones. It sets no
pool label and no taint: the pool is made by an administrator, in section 2.

```sh
# from the repo root (full-guide/)
kind delete cluster --name bookstore
kind create cluster --config examples/security-lab/kind/cluster-three-node.yaml
kubectl get nodes -L topology.kubernetes.io/zone
```

The config names the cluster `bookstore`, so its nodes are
`bookstore-control-plane`, `bookstore-worker` and `bookstore-worker2`. Pick one
worker as the **dedicated pool**. Below, `<POOL-WORKER>` stands for its name.
The output in this chapter came from a lab cluster whose nodes are named
`sf-sched-control-plane`, `sf-sched-worker` and `sf-sched-worker2`, with
`sf-sched-worker` as the pool node. Those names appear verbatim in the output.
The lab cluster was built from an earlier copy of the config without zone
labels, and no command here reads them.

**A recreated cluster is empty**: the namespace, config, secrets, and the
PriorityClasses from earlier chapters are gone. Re-establish the prerequisites
**in this order** before applying any workload. Each file is complete, and the
order matters: the namespace and ServiceAccounts come before the workloads that
name them.

```sh
# from the repo root (full-guide/)
# 1) namespace and quota (Part 01 ch.03), then the ServiceAccounts (Part 05 ch.01)
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
# 2) config and DB credentials the workloads consume (Part 03 ch.01/ch.02)
kubectl apply -f examples/bookstore/raw-manifests/15-catalog-config.yaml
kubectl apply -f examples/bookstore/raw-manifests/16-db-credentials.yaml
# 3) PriorityClasses: cluster-scoped, explained in Part 04 ch.03
kubectl apply -f examples/bookstore/raw-manifests/35-priorityclasses.yaml
# 4) Services and redis. catalog's /readyz pings redis (REDIS_ADDR in
#    catalog-config), so catalog is not Ready until redis answers.
kubectl apply -f examples/bookstore/raw-manifests/40-services.yaml
kubectl apply -f examples/bookstore/raw-manifests/12-redis.yaml
# 5) re-load the kind-built images. postgres is pinned by digest and pulled.
kind load docker-image bookstore/catalog:dev    --name bookstore
kind load docker-image bookstore/storefront:dev --name bookstore
```

### 2. The dedicated pool, and what a node cannot do to it

The pool is a label and a taint on one node, both set by an administrator. The
label sits under `node-restriction.kubernetes.io/`, the prefix the
NodeRestriction admission plugin protects. Upstream reserves it for
administrators, and kubelets may not set it
([admission controllers](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction)).
Before you build the pool, ask the API server to act as the kubelet of the pool
node. `--dry-run=server` runs admission without writing anything. Your node
names differ from the lab's, so replace the name in each command. Keep this
order. The plugin refuses a key only when its value would change
([`getModifiedLabels`](https://github.com/kubernetes/kubernetes/blob/v1.37.0/plugin/pkg/admission/noderestriction/admission.go)),
so once the label holds `database`, writing it again is no change and is not
refused.

This check is a deliberate failure. The node's own identity tries to put its
node in the pool, and the server refuses:

```sh
# Deliberate failure: the pool node's identity tries to label itself.
kubectl --as=system:node:<POOL-WORKER> --as-group=system:nodes \
  label node <POOL-WORKER> node-restriction.kubernetes.io/pool=database --dry-run=server
```

<!-- gate: output -->
```text
Error from server (Forbidden): nodes "sf-sched-worker" is forbidden: is not allowed to modify labels: node-restriction.kubernetes.io/pool
```

The protection reaches only the prefixes upstream names. The same identity may
set an unprefixed key, such as `dedicated`, on its own node:

```sh
kubectl --as=system:node:<POOL-WORKER> --as-group=system:nodes \
  label node <POOL-WORKER> dedicated=database --dry-run=server
```

<!-- gate: output -->
```text
node/sf-sched-worker labeled (server dry run)
```

That label would be accepted, so a pool selected by an unprefixed key could be
forged by anyone who holds a kubelet credential. This is why the pool key
carries the prefix. Now the administrator builds the pool:

```sh
kubectl label node <POOL-WORKER> node-restriction.kubernetes.io/pool=database
kubectl taint node <POOL-WORKER> dedicated=database:NoSchedule
kubectl get nodes -L node-restriction.kubernetes.io/pool
```

<!-- gate: output -->
```text
node/sf-sched-worker labeled
# ...
node/sf-sched-worker tainted
# ...
NAME                     STATUS   ROLES           AGE     VERSION   POOL
sf-sched-control-plane   Ready    control-plane   3h20m   v1.37.0
sf-sched-worker          Ready    <none>          3h20m   v1.37.0   database
sf-sched-worker2         Ready    <none>          3h20m   v1.37.0
```

With the pool in place, the node's identity cannot take the taint off, and it
cannot remove the label either. Both are deliberate failures:

```sh
# Deliberate failures: the pool node's identity tries to unmake its own pool.
kubectl --as=system:node:<POOL-WORKER> --as-group=system:nodes \
  taint node <POOL-WORKER> dedicated:NoSchedule- --dry-run=server
kubectl --as=system:node:<POOL-WORKER> --as-group=system:nodes \
  label node <POOL-WORKER> node-restriction.kubernetes.io/pool- --dry-run=server
```

<!-- gate: output -->
```text
Error from server (Forbidden): nodes "sf-sched-worker" is forbidden: node "sf-sched-worker" is not allowed to modify taints
# ...
Error from server (Forbidden): nodes "sf-sched-worker" is forbidden: is not allowed to modify labels: node-restriction.kubernetes.io/pool
```

A compromised kubelet therefore cannot put its node into the pool, take the
pool's taint off, or remove the pool label, and the affinity keyed on the
protected label stays true. Upstream says the same of taints: kubelets may not
update or remove them on their own Node. The refusals above also show that the
plugin is on in the lab cluster: kubeadm, which kind uses, enables it by
default. Section 3 makes postgres require the label.

### 3. Pin `postgres` to the dedicated pool (taint, toleration, required affinity)

The scheduling layer in
[`20-postgres-statefulset.yaml`](../examples/bookstore/raw-manifests/20-postgres-statefulset.yaml)
sits inside `spec.template.spec`, beside the existing envFrom-Secret, probes and
volumeClaimTemplates:

```yaml
    spec:
      priorityClassName: bookstore-data        # ch.03 (35-): highest tier
      tolerations:                             # lifts the taint's refusal
        - key: dedicated
          operator: Equal
          value: database
          effect: NoSchedule                   # must match the taint exactly
      affinity:
        nodeAffinity:                          # PREFERRED: a score only
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: dedicated
                    operator: In
                    values: ["database"]
      # ... existing terminationGracePeriodSeconds / containers UNCHANGED ...
```

The shipped file prefers the pool, and a dedicated pool requires it. Both are
right, for different clusters:

- **The shipped file prefers**, because it is shared. The other chapters, and
  the guide's own CI, apply the raw manifests on a single-node kind cluster, and
  the Kustomize base and the Helm chart carry the same fields. On one node no
  node has a pool label. A required rule there matches nothing, so postgres
  stays Pending, and the schema Job, catalog and every later chapter wait on
  it. A preferred rule only adds to a node's score. A node that does not match
  still takes the Pod, so the file runs anywhere.
- **A dedicated pool requires**, because a preferred rule is only a score. With
  a pool node and general nodes both available, nothing stops the scheduler
  putting the data tier on a general node when the other scores favour it. The
  key matters too. The shipped `dedicated` has no prefix, so a kubelet can set
  it on its own node (section 2). The pool you built carries the protected key.

On this cluster you therefore replace the preferred rule with a required one on
the protected label. The shipped file stays as it is, and you patch the
StatefulSet. The dedicated pool needs all three parts, and each answers a
different threat:

- The **taint** keeps general Pods off the pool. Catalog has no toleration, so
  the taint alone keeps it out.
- The **toleration** lifts the taint's refusal, so postgres may enter the pool.
  It is not an authorization: section 5 shows any Pod author writing one.
- The **required node affinity** keeps postgres on the pool. A preferred rule is
  only a score, so with one the data tier could land on a general node.

The order of the steps matters. kind's default StorageClass creates a volume on
the node where a Pod is first placed. A `postgres-0` that first started on the
general worker would keep its volume there, and a Pod that may run only on the
pool cannot use a volume that lives on another node. So create the StatefulSet
with no replicas, patch it, and scale it up, and the first Pod already carries
the required rule:

```sh
# from the repo root (full-guide/)
sed 's/^  replicas: 1 /  replicas: 0 /' \
  examples/bookstore/raw-manifests/20-postgres-statefulset.yaml \
  | kubectl apply -f -
kubectl patch statefulset postgres -n bookstore --type=json -p '[
  {"op": "replace",
   "path": "/spec/template/spec/affinity/nodeAffinity",
   "value": {"requiredDuringSchedulingIgnoredDuringExecution": {
     "nodeSelectorTerms": [{"matchExpressions": [
       {"key": "node-restriction.kubernetes.io/pool",
        "operator": "In", "values": ["database"]}]}]}}}]'
kubectl get statefulset postgres -n bookstore \
  -o jsonpath='{.spec.template.spec.affinity.nodeAffinity}'
```

<!-- gate: output -->
```text
service/postgres created
statefulset.apps/postgres created
# ...
statefulset.apps/postgres patched
# ...
{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-restriction.kubernetes.io/pool","operator":"In","values":["database"]}]}]}}
```

The StatefulSet now carries only the required rule, and no Pod exists yet. Scale
it up and read where `postgres-0` and its volume land:

```sh
kubectl scale statefulset/postgres -n bookstore --replicas=1
kubectl rollout status statefulset/postgres -n bookstore
kubectl get pod postgres-0 -n bookstore \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase'
kubectl get pv -o custom-columns='CLAIM:.spec.claimRef.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]'
```

<!-- gate: output -->
```text
POD          NODE              PHASE
postgres-0   sf-sched-worker   Running
```

<!-- gate: output -->
```text
CLAIM             NODE
data-postgres-0   sf-sched-worker
```

`postgres-0` runs on the pool node, and so does its volume. Pool membership is a
required rule, so the replacement for a deleted postgres Pod can only land on a
node that carries the label. Required is the choice for the data tier: postgres
waits for its pool rather than running somewhere else. Section 6 shows that
wait, and the [Production notes](#production-notes) cover what it costs.

Catalog carries `DB_DSN` and its readiness pings Postgres, so apply the schema
Job and wait for it before the next section:

```sh
kubectl apply -f examples/bookstore/raw-manifests/21-db-migrate-job.yaml
kubectl wait --for=condition=complete job/db-migrate -n bookstore --timeout=300s
```

If the migration Job reports `DeadlineExceeded`, the image pull took longer than
its 120 s `activeDeadlineSeconds`. On the lab host the first postgres pull took
about four minutes, and the Job failed that way. Applying it again, once the
image was on the node, let it complete. On a slow registry, pull the image onto
the nodes before the Job runs.

### 4. Spread `catalog` & `storefront` across nodes (HA)

The scheduling layer in
[`10-catalog-deploy.yaml`](../examples/bookstore/raw-manifests/10-catalog-deploy.yaml)
sits inside `spec.template.spec`, alongside (not replacing) the existing
containers/volumes/probes:

```yaml
    spec:
      priorityClassName: bookstore-critical   # ch.03 (35-): user-facing tier
      topologySpreadConstraints:
        - maxSkew: 1                           # node replica counts differ by ≤1
          topologyKey: kubernetes.io/hostname  # one domain per node
          whenUnsatisfiable: DoNotSchedule     # HARD: a filter, not a score
          labelSelector:
            matchLabels: { app: catalog }      # count only catalog Pods
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:   # SOFT
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels: { app: catalog }
      # ... existing containers / volumes / probes / preStop UNCHANGED ...
```

`storefront`
([`11-storefront-deploy.yaml`](../examples/bookstore/raw-manifests/11-storefront-deploy.yaml))
gets the same shape with `app: storefront`. The spread is hard and the
anti-affinity is soft. A hard spread suits the single-node cluster the shared
files run on: there is one domain, the skew is always zero, and every replica
schedules. This chapter's layout is different, so apply both files and read
what the scheduler does. This is a deliberate failure: the shipped hard spread
meets a layout it cannot satisfy.

```sh
# from the repo root (full-guide/)
kubectl apply -f examples/bookstore/raw-manifests/10-catalog-deploy.yaml
kubectl apply -f examples/bookstore/raw-manifests/11-storefront-deploy.yaml
# Give the scheduler a few seconds, then read where the Pods landed.
kubectl get pods -n bookstore -l 'app in (catalog,storefront)' \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase'
kubectl get events -n bookstore --field-selector reason=FailedScheduling \
  -o custom-columns='OBJECT:.involvedObject.name,MESSAGE:.message'
```

<!-- gate: output -->
```text
POD                           NODE               PHASE
catalog-dcd68944f-9fpfv       <none>             Pending
catalog-dcd68944f-d9skm       sf-sched-worker2   Running
catalog-dcd68944f-xgrtx       <none>             Pending
storefront-79c588c766-2sxk9   <none>             Pending
storefront-79c588c766-hvrtg   sf-sched-worker2   Running
```

<!-- gate: output -->
```text
OBJECT                        MESSAGE
catalog-dcd68944f-9fpfv       0/3 nodes are available: 1 node(s) didn't match pod topology spread constraints, 2 node(s) had untolerated taint(s). preemption: 0/3 nodes are available: 1 node(s) didn't match pod topology spread constraints, 2 Preemption is not helpful for scheduling.
# ...
storefront-79c588c766-2sxk9   0/3 nodes are available: 1 node(s) didn't match pod topology spread constraints, 2 node(s) had untolerated taint(s). preemption: 0/3 nodes are available: 1 node(s) didn't match pod topology spread constraints, 2 Preemption is not helpful for scheduling.
```

One replica of each Deployment runs, and three Pods wait. The event, which the
other Pending catalog Pod repeats, names two reasons: the spread constraint, and
the untolerated taint on the two nodes that are not the general worker, which
are the control plane and the pool. The constraint refuses because those two
still count. `nodeTaintsPolicy` defaults to `Ignore`, so a node the Pod cannot
use stays in the domain count with zero catalog Pods. A second catalog replica
on the general worker would make its count 2 against 0 elsewhere, a skew of 2.
Setting `nodeTaintsPolicy: Honor` removes the two from the count. Then the
general worker is the only domain, the skew is always zero, and the constraint
passes without separating anything. On a layout with one general node, a
hostname spread is either blocked or empty.

On this layout the spread has to be a preference. Patch both Deployments to
`ScheduleAnyway`. The patch changes one field, and the rollout replaces the
Pending Pods:

```sh
for d in catalog storefront; do
  kubectl patch deployment $d -n bookstore --type=json -p '[{"op": "replace",
    "path": "/spec/template/spec/topologySpreadConstraints/0/whenUnsatisfiable",
    "value": "ScheduleAnyway"}]'
done
kubectl rollout status deployment/catalog -n bookstore
kubectl rollout status deployment/storefront -n bookstore
kubectl get pods -n bookstore -l 'app in (catalog,storefront)' \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase'
```

<!-- gate: output -->
```text
deployment.apps/catalog patched
deployment.apps/storefront patched
# ...
deployment "catalog" successfully rolled out
# ...
deployment "storefront" successfully rolled out
```

The old catalog Pod can stay in the list for a few seconds while it terminates.
Run the last command again if you see a fourth catalog Pod:

<!-- gate: output -->
```text
POD                           NODE               PHASE
catalog-66c84f6fd6-mgrhd      sf-sched-worker2   Running
catalog-66c84f6fd6-ptzpw      sf-sched-worker2   Running
catalog-66c84f6fd6-rtd5z      sf-sched-worker2   Running
storefront-5c7b7bbc99-m29mh   sf-sched-worker2   Running
storefront-5c7b7bbc99-z2mfx   sf-sched-worker2   Running
```

All replicas sit on the general worker. None is on the pool node: the taint
keeps them off it, because neither Deployment has a toleration. `ScheduleAnyway`
makes the spread a score, and the `preferred` anti-affinity term is a score on
each node, so the scheduler places a replica it cannot spread rather than leave
it Pending. Make the spread hard again once the layout has several general
nodes, as the Production notes describe for zones.

### 5. A toleration is not an authorization

Any author who can create a Pod in the namespace, or a workload that creates
one, can write the toleration and the required affinity from section 3. This
Pod does exactly that, as a deliberate demonstration of the gap. It is
complete and carries the baseline. Its image is the pause image, pinned by
digest. On linux/amd64 its image config declares UID 65535, and the Pod runs as
that UID. It has its own ServiceAccount with no token mounted, as every
workload has.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pool-tenant-sa
  namespace: bookstore
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: pool-tenant
  namespace: bookstore
  labels:
    app: pool-tenant
spec:
  serviceAccountName: pool-tenant-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65535
    runAsGroup: 65535
    seccompProfile:
      type: RuntimeDefault
  tolerations:
    - key: dedicated
      operator: Equal
      value: database
      effect: NoSchedule
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-restriction.kubernetes.io/pool
                operator: In
                values: ["database"]
  containers:
    - name: app
      image: registry.k8s.io/pause@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a  # pause:3.10
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
          memory: 32Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

```sh
# Save the manifest as pool-tenant.yaml, then:
kubectl apply -f pool-tenant.yaml
kubectl wait --for=condition=Ready pod/pool-tenant -n bookstore --timeout=120s
kubectl get pod pool-tenant -n bookstore \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase'
```

<!-- gate: output -->
```text
POD           NODE              PHASE
pool-tenant   sf-sched-worker   Running
```

The scheduler placed the Pod on the pool node. It did not ask who wrote the
toleration, and it cannot tell an authorized author from anyone else. The
control sits in front of the scheduler: who may write a Pod, or a workload
whose controller writes one. A Deployment, StatefulSet, DaemonSet, Job or
CronJob carries a pod template, and its controller creates the Pods from it,
so the same toleration and affinity can arrive through any of them. The lab's
`catalog-sa` has no Role that grants `create` on Pods or on Deployments, and
both are refused:

```sh
kubectl auth can-i create pods -n bookstore --as=system:serviceaccount:bookstore:catalog-sa
kubectl auth can-i create deployments -n bookstore --as=system:serviceaccount:bookstore:catalog-sa
```

<!-- gate: output -->
```text
no
# ...
no
```

A subject granted `create` or `update` on any of those kinds in this namespace
could write the toleration, which is why RBAC on the workload kinds is the
first control, not RBAC on `pods` alone.
[Part 04 ch.03](03-priority-and-preemption.md) shows the same path for a
priority class: a tenant that may create Deployments but not Pods still gets
its Pods scheduled. [Authentication, authorization and
RBAC](../05-security/01-authn-authz-rbac.md) teaches the Role itself.
Restricting which tolerations a namespace may use is an admission policy, which
this chapter does not build:
[05.07](../05-security/07-admission-control-and-policy-as-code.md).

```sh
kubectl delete pod pool-tenant -n bookstore
```

A Pod can also skip the toleration by setting `spec.nodeName`. It is bound
before the scheduler runs, so no taint is checked. [Ch.01 step
5](01-scheduler-and-nodes.md#5-nodename-skips-the-schedulers-taint-check) runs
that case against a `NoSchedule` taint, and step 6 denies it with an admission
policy. The kubelet's own admission checks only `NoExecute` taints, and skips
static Pods
([source](https://github.com/kubernetes/kubernetes/blob/v1.37.0/pkg/kubelet/lifecycle/predicate.go)).
A `NoExecute` pool taint would therefore make the kubelet refuse a `nodeName`
Pod without a toleration, as ch.01 step 5d shows. It would also evict every
running Pod on the node that lacks one, the moment you applied it. This chapter
keeps `NoSchedule`, and the Production notes say when to choose the other.

### 6. Watch `IgnoredDuringExecution` actually mean what it says

Remove the pool label while postgres runs on the pool node. Postgres does not
move:

```sh
kubectl label node <POOL-WORKER> node-restriction.kubernetes.io/pool-
kubectl get pod postgres-0 -n bookstore \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase'
```

<!-- gate: output -->
```text
node/sf-sched-worker unlabeled
# ...
POD          NODE              PHASE
postgres-0   sf-sched-worker   Running
```

The rule gates scheduling only, never eviction. The label is the one
NodeRestriction protects, so a kubelet cannot put it back. Now see what the
required rule costs. Delete `postgres-0` while no node carries the label. The
StatefulSet creates a replacement, and the scheduler has nowhere to put it:

```sh
kubectl delete pod postgres-0 -n bookstore
# Give the scheduler a few seconds, then read the result.
kubectl get pod postgres-0 -n bookstore \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase'
kubectl get events -n bookstore \
  --field-selector reason=FailedScheduling,involvedObject.name=postgres-0 \
  -o custom-columns='OBJECT:.involvedObject.name,MESSAGE:.message'
```

<!-- gate: output -->
```text
POD          NODE     PHASE
postgres-0   <none>   Pending
# ...
OBJECT       MESSAGE
postgres-0   0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

The replacement stays Pending. The control plane refuses it on its taint, and
the pool node and the general worker both fail the required rule, because no
node carries the label. This is the price of a required rule: the data tier
waits for its pool rather than running somewhere else. It is also what a
single-node cluster would show, because no node there carries the label, and
it is why the shared file prefers (section 3).

Restore the label, because the required affinity needs it and the chapters
after this one assume the data tier sits on the pool. The scheduler places the
waiting Pod as soon as the label exists:

```sh
kubectl label node <POOL-WORKER> node-restriction.kubernetes.io/pool=database
kubectl wait --for=condition=Ready pod/postgres-0 -n bookstore --timeout=400s
kubectl get pod postgres-0 -n bookstore \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase'
kubectl get nodes -L node-restriction.kubernetes.io/pool
```

<!-- gate: output -->
```text
node/sf-sched-worker labeled
# ...
pod/postgres-0 condition met
# ...
POD          NODE              PHASE
postgres-0   sf-sched-worker   Running
# ...
NAME                     STATUS   ROLES           AGE     VERSION   POOL
sf-sched-control-plane   Ready    control-plane   3h25m   v1.37.0
sf-sched-worker          Ready    <none>          3h25m   v1.37.0   database
sf-sched-worker2         Ready    <none>          3h25m   v1.37.0
```

Nothing moved while the label was gone. The running Pod stayed, and the
replacement waited for the label. That is the entire meaning of the verbose
name: node/pod **affinity** is enforced **only at schedule time**; once a Pod
is bound, later label changes are ignored for that Pod. (The only placement rule
that *does* act on running Pods is a **`NoExecute` taint**, which is why
`NoExecute` exists as a separate effect.)

## How it works under the hood

- **`nodeSelector` vs. `nodeAffinity` — what *IgnoredDuringExecution* means.**
  `nodeSelector` is a flat `map[string]string`: all key=value pairs must match
  (AND), exact equality only. It is **not deprecated** but is the minimal form.
  `nodeAffinity` is the expressive superset:
  `requiredDuringSchedulingIgnoredDuringExecution` (a hard filter — node *must*
  match `matchExpressions` with operators `In`/`NotIn`/`Exists`/`DoesNotExist`/
  `Gt`/`Lt`; multiple `nodeSelectorTerms` are OR'd) and
  `preferredDuringSchedulingIgnoredDuringExecution` (a weighted Score
  contribution, 1–100). The clumsy suffix decodes literally: **`…DuringScheduling`** = applied when the scheduler places the Pod;
  **`IgnoredDuringExecution`** = once running, changing node labels does **not**
  evict or move the Pod. (A hypothetical `RequiredDuringExecution` would evict
  on label change; it does not exist for affinity — only `NoExecute` taints have
  that running-Pod power.)
- **Inter-pod (anti-)affinity and the `topologyKey`.** The term is evaluated as:
  "consider the set of nodes sharing the same value of `topologyKey` as a
  candidate node; do/don't any of them run a Pod matching `labelSelector` (in
  the given `namespaces`/`namespaceSelector`)?"
  `topologyKey: kubernetes.io/hostname` ⇒ per-node; `topology.kubernetes.io/zone` ⇒ per-zone.
  **The scale caveat:** evaluating pod affinity/anti-affinity is roughly
  *O(Pods × nodes)* per scheduling attempt — the scheduler must, for the
  candidate Pod, check matching Pods across topology domains. **Required**
  (hard) pod *affinity* especially is expensive and is explicitly discouraged on
  large clusters in the docs; hard **anti**-affinity for spreading is the
  classic use but `topologySpreadConstraints` is the cheaper, more precise modern
  replacement for "spread evenly". Use pod anti-affinity for true HA *hard*
  separation ("never two replicas of this critical singleton-ish service on one
  node"), spread constraints for "balance across domains".
- **Taints & tolerations mechanics.** A taint is `key[=value]:effect` on
  `node.spec.taints`. A toleration matches if `key` matches **and** `effect`
  matches **and** (for `operator: Equal`) `value` matches — with two wildcards:
  `operator: Exists` matches **any value** for that key (and an *empty-key*
  `Exists` toleration tolerates **all** taints — a dangerous catch-all), and an
  **empty `effect`** in the toleration matches **all effects** for that key
  (`NoSchedule`+`PreferNoSchedule`+`NoExecute` at once) rather than one — also
  broader than usually intended. **`NoSchedule`** blocks scheduling of
  non-tolerating Pods (running Pods stay). **`PreferNoSchedule`** is a soft
  Score penalty, not a filter. **`NoExecute`** additionally **evicts**
  already-running non-tolerating Pods: immediately if the toleration is absent,
  or after `tolerationSeconds` if the Pod tolerates it with a finite duration.
  Kubernetes auto-adds built-in taints — `node.kubernetes.io/not-ready` and
  `node.kubernetes.io/unreachable` (`NoExecute`, by the node controller when a
  node goes bad), `node.kubernetes.io/unschedulable` (on `cordon`),
  `node.kubernetes.io/memory-pressure`/`disk-pressure`/`pid-pressure` (by the
  kubelet), and `node-role.kubernetes.io/control-plane:NoSchedule` (keeps
  general workloads off control-plane nodes). The default admission also injects
  a 300s `tolerationSeconds` for the not-ready/unreachable taints, which is why
  a Pod on a node that briefly goes NotReady is **not** evicted instantly — it
  has ~5 minutes for the node to recover.
- **`topologySpreadConstraints` semantics.** For each constraint the scheduler
  groups feasible nodes into **domains** by `topologyKey`, counts matching Pods
  (selected by `labelSelector`, optionally narrowed/widened by `matchLabelKeys`)
  per domain, and ensures `max(count) − min(count) ≤ maxSkew` *after* placing
  the new Pod. `whenUnsatisfiable: DoNotSchedule` makes the constraint a Filter
  (Pending if no domain keeps skew ≤ maxSkew); `ScheduleAnyway` makes it a Score
  signal only. Refinements: **`minDomains`** (GA in 1.30) forces the scheduler to
  treat the topology as having *at least* N domains — so 3 replicas don't all
  pack into the only 1 domain currently present; **`nodeAffinityPolicy`** /
  **`nodeTaintsPolicy`** (`Honor`|`Ignore`; beta since 1.26, GA in 1.33) decide
  whether nodes the Pod cannot use, by its own nodeAffinity or by taints, are
  left out of the domain count. The defaults are `Honor` for affinity and
  `Ignore` for taints. Under `Ignore` a pool node that the Pod cannot enter
  still counts as an empty domain, which is why the hard spread stalled in the
  lab (section 4); **`matchLabelKeys`** (beta since 1.27) adds pod-
  template-hash-like keys to the implicit selector so a *rolling update's* new
  and old ReplicaSet Pods are spread independently rather than fighting each
  other's counts. Kubernetes also applies **cluster-level default constraints**
  (`maxSkew: 3` over hostname and `maxSkew: 5` over zone, both
  `ScheduleAnyway`) to Pods that declare none, via the scheduler's
  `PodTopologySpread` plugin defaults: a gentle built-in spreading even when
  you specify nothing.
- **How they combine, in pipeline terms.** All of these are scheduler
  *plugins* from [ch.01](01-scheduler-and-nodes.md): `NodeAffinity`,
  `TaintToleration`, `InterPodAffinity`, `PodTopologySpread` each run at
  **Filter** (the hard/`required`/`NoSchedule`/`DoNotSchedule` parts) **and** at
  **Score** (the `preferred`/`PreferNoSchedule`/`ScheduleAnyway` parts). Hard
  constraints intersect (a node must pass *all* required predicates); soft ones
  are weighted and summed. So postgres' placement, with the required rule
  patched in (section 3), is: NodeAffinity's Filter keeps only the pool node,
  because the affinity is required; TaintToleration's Filter then admits that
  node, because postgres tolerates the taint; it lands there. With the shipped
  preferred rule, NodeAffinity only scores, and a node that does not match is
  still a candidate. Catalog's placement is: under `DoNotSchedule`, Filter
  drops nodes that would break `maxSkew`; under `ScheduleAnyway`, the
  constraint only scores.
  A Pod with `spec.nodeName` skips this pipeline altogether, and
  [ch.01](01-scheduler-and-nodes.md) shows a `NoSchedule` taint did not stop
  such a Pod on the lab node.

## Production notes

> **In production:** spread every replicated stateless service across **failure
> domains**, not just nodes. Use `topologySpreadConstraints` with
> `topologyKey: topology.kubernetes.io/zone` (cloud nodes get this label
> automatically; our kind config sets them by hand) so a whole-AZ outage cannot
> take a tier down. Pair `maxSkew: 1` with `minDomains` to stop all replicas
> packing into one zone when the cluster is small or scaling up.

> **In production:** prefer **`topologySpreadConstraints` over hard pod
> anti-affinity** for "spread evenly". Required pod affinity/anti-affinity is
> *O(Pods × nodes)* at schedule time and degrades scheduler throughput on large
> clusters; reserve hard anti-affinity for genuine "these two must never share a
> node" cases (e.g. a quorum's members). Keep anti-affinity `preferred` unless
> the separation is a correctness requirement.

> **In production:** `required` node affinity turns "no such pool node right
> now" into a Pending data tier. Keep the pool in a node group that
> cluster-autoscaler can grow, and alert on Pending Pods in the data namespace.
> Check the pool label on a real node after it joins. NodeRestriction stops a
> kubelet from setting that prefix itself, so the label has to come from an
> administrator or from the provider's node-pool configuration.

> **In production:** use **dedicated node pools + taints** for stateful or
> special-hardware workloads (databases, GPU jobs). Taint the pool
> `NoSchedule`, add the matching toleration **and** node affinity to only the
> intended workloads. On EKS/GKE/AKS, node pools/groups can be created
> pre-tainted/labelled and the **cluster-autoscaler** scales each pool
> independently — the dedicated DB pool grows without bloating the general pool.
> `NoSchedule` does not stop a Pod that sets `nodeName`. A `NoExecute` taint
> does, because the kubelet refuses a Pod that lacks the toleration, but it
> also evicts the running Pods that lack one. Choose it only for a pool you can
> drain first, and give the DaemonSets that must run there the toleration.

> **In production:** understand the **built-in `NoExecute` taints**. The node
> controller applies **`node.kubernetes.io/not-ready:NoExecute`** when a node's
> status goes `NotReady` (the kubelet reports unhealthy), and
> **`node.kubernetes.io/unreachable:NoExecute`** when the node stops sending
> heartbeats entirely (the controller cannot reach it). For *both*, Pods are
> evicted after their `tolerationSeconds` (default 300s, auto-injected by
> admission). Tuning that value lower speeds failover but risks evicting Pods
> during brief blips; the control-plane taint
> `node-role.kubernetes.io/control-plane:NoSchedule` is why your app Pods never
> land on control-plane nodes — don't blanket-tolerate it.

## Quick Reference

```sh
# Inspect node labels & taints (the inputs to all four mechanisms)
kubectl get nodes -L topology.kubernetes.io/zone,node-restriction.kubernetes.io/pool
kubectl describe node <NODE> | sed -n '/Taints:/,/Unschedulable/p'

# Pool taint and pool label (administrator; a kubelet cannot set the label)
kubectl taint nodes <NODE> dedicated=database:NoSchedule       # add
kubectl taint nodes <NODE> dedicated=database:NoSchedule-      # remove (trailing -)
kubectl label nodes <NODE> node-restriction.kubernetes.io/pool=database   # add
kubectl label nodes <NODE> node-restriction.kubernetes.io/pool-           # remove

# Verify spreading worked. A Pod has its NODE in spec.nodeName, but NOT its
# zone — zone is a NODE label. Get the Pod→node mapping, then the node→zone
# mapping, and read them together (or use `-o wide` for the NODE column):
kubectl get pods -n <NS> -l <SEL> -o wide          # NODE column should vary
kubectl get pods -n <NS> -l <SEL> \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName'
kubectl get nodes -L topology.kubernetes.io/zone   # NODE → ZONE (node label)
```

Dedicated pool (sensitive Pods need the toleration **and** required affinity):

```yaml
spec:
  tolerations:
    - { key: dedicated, operator: Equal, value: database, effect: NoSchedule }
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - { key: node-restriction.kubernetes.io/pool, operator: In, values: ["database"] }
```

Spread (a preference on a small layout; see the Production notes for zones):

```yaml
spec:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector: { matchLabels: { app: myapp } }
```

Checklist:

- [ ] Stateless replicated tiers have `topologySpreadConstraints` over zone
  (and/or host)
- [ ] Hard pod anti-affinity used only for true "must not co-locate" cases
- [ ] Pool nodes are **tainted**, and the pool label sits under
  `node-restriction.kubernetes.io/`, set by an administrator
- [ ] Sensitive Pods have the toleration **and** required node affinity to the
  pool
- [ ] A toleration is never treated as authorization: RBAC limits who may
  write Pods and the workload kinds that carry a pod template, and admission
  limits tolerations
  ([05.07](../05-security/07-admission-control-and-policy-as-code.md))
- [ ] Pods that set `spec.nodeName` are denied in sensitive namespaces ([Part
  04 ch.01](01-scheduler-and-nodes.md)); a `NoSchedule` pool taint does not
  stop them
- [ ] Relied on `IgnoredDuringExecution`: affinity gates scheduling, not
  eviction
- [ ] Did not blanket-tolerate built-in taints (`not-ready`, control-plane)

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **A teammate adds a toleration to a Pod for the `dedicated=database:NoSchedule` taint but the Pod is still scheduled on a random node — not the dedicated one. Why, and what's missing?**
   <details><summary>Show answer</summary>

   Tolerations lift the taint's refusal. They never attract a Pod to a node. Without `nodeAffinity` (or `nodeSelector`) pulling the Pod toward the pool, the scheduler treats the pool node as one of many feasible nodes and may pick any. The dedicated-pool recipe is **taint + toleration + required node affinity**, all three (see §3. Pin postgres to the dedicated pool).

   </details>

2. **You set `requiredDuringSchedulingIgnoredDuringExecution` node affinity on a Deployment, then later remove the matching label from the node. The running Pods stay there. Walk through the suffix's literal meaning.**
   <details><summary>Show answer</summary>

   `…DuringScheduling` = the rule is applied when the scheduler places the Pod. `IgnoredDuringExecution` = once running, label changes are ignored for that Pod; it is not evicted. The only mechanism that *does* evict running Pods on a node-side change is a `NoExecute` taint, which is why that effect exists separately. There is no `RequiredDuringExecution` for affinity (see §6. Watch IgnoredDuringExecution actually mean what it says).

   </details>

3. **You configure `topologySpreadConstraints` with `maxSkew: 1`, `topologyKey: topology.kubernetes.io/zone`, `whenUnsatisfiable: DoNotSchedule` for a 3-replica Deployment. The cluster has only 1 zone. What happens, and what field (GA in 1.30) helps?**
   <details><summary>Show answer</summary>

   All 3 replicas land in the 1 zone with skew=0 (only one domain, no spread possible) — the constraint is satisfied trivially. To force the scheduler to *assume* at least N domains (so spreading kicks in even before all zones have nodes), use `minDomains: 3` (GA in 1.30). With `minDomains` set and only one current zone, replica 2 and 3 stay `Pending` until two more zones exist (see §How it works under the hood, `topologySpreadConstraints` semantics).

   </details>

4. **A node briefly becomes `NotReady` because of a 30-second network blip. Why don't all the Pods on it get evicted immediately, and what controls the timing?**
   <details><summary>Show answer</summary>

   The node controller adds `node.kubernetes.io/not-ready:NoExecute` when status flips, but admission has auto-injected a 300s `tolerationSeconds` for that taint on every Pod by default. So Pods are evicted only after 5 minutes — long enough for a blip to resolve without thrashing workloads. You can tune `tolerationSeconds` lower for faster failover, but at the cost of evicting on brief flaps (see §How it works under the hood, built-in taints).

   </details>

5. **A teammate with `create` on Deployments in `bookstore`, and none on Pods,
   writes a Deployment whose pod template has the same toleration and required
   affinity as postgres. Its Pods land on the pool node. Which control would
   have stopped it, and why can neither the taint nor the affinity do that?**
   <details><summary>Show answer</summary>

   Neither the taint nor the affinity checks who wrote the Pod. The scheduler
   reads what the Pod says, and this Pod says the right things. The control sits
   before the scheduler: RBAC decides who may create or update Pods and the
   workload kinds whose controllers create them, so withholding `pods` alone is
   not enough (in §5 the lab's `catalog-sa` was refused on both `pods` and
   `deployments`), and an admission policy can reject tolerations for the pool
   key from namespaces that may not use the pool. That policy is
   [05.07](../05-security/07-admission-control-and-policy-as-code.md). A related
   case: a Pod that sets `nodeName` skips the scheduler and a `NoSchedule`
   taint, so the control is to deny `nodeName` in sensitive namespaces ([Part 04
   ch.01](01-scheduler-and-nodes.md)).

   </details>

## Further reading

- **Ibryam & Huß, _Kubernetes Patterns_ 2e — *Automated Placement* (ch.6)** —
  node/pod affinity, taints/tolerations, and topology-aware spreading as the
  declarative placement toolkit, with the trade-offs of hard vs. soft rules.
- **Lukša, _Kubernetes in Action_ 2e — advanced scheduling material** —
  affinity/anti-affinity and taints worked through on examples.
- Official:
  <https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/>,
  taints & tolerations
  <https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/>,
  and topology spread constraints
  <https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/>.
