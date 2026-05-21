# 01 — Cluster lifecycle

> Where a cluster *comes from* and how it *changes over time*: provisioning
> options (**kubeadm** — what it does and pointedly does not; **managed**
> EKS/GKE/AKS — the control plane is the provider's, you own the nodes;
> **kind/k3d** — local, this guide's; **Cluster API** — clusters as Kubernetes
> objects); the **control-plane-then-nodes upgrade flow** (`kubeadm upgrade plan/apply`;
> component order apiserver → controller-manager/scheduler →
> kubelet; `drain → upgrade kubelet → uncordon` per node; managed = node-pool
> surge upgrades); the **version-skew policy** (the API server is the
> reference; kubelet up to **n-3** behind, controller-manager/scheduler n-1,
> kubectl ±1 — *never* upgrade kubelet past the API server); **API
> deprecation/removal** and `apiVersion` migration (`kubectl convert`, the
> deprecated-API audit before every upgrade — `pluto`/`kubent`); node
> pools/groups, OS image/AMI, the etcd↔Kubernetes version coupling, and
> certificate rotation on upgrade — applied by version-checking and
> "upgrading" the Bookstore's kind cluster and proving the app still
> reconciles.

**Estimated time:** ~30 min read · ~90 min hands-on
**Prerequisites:** [Part 00 ch.04](../00-foundations/04-control-plane-deep-dive.md) — what apiserver / etcd / scheduler do; what an upgrade actually changes · [Part 00 ch.05](../00-foundations/05-node-components.md) — kubelet/kube-proxy on each node · [Part 00 ch.07](../00-foundations/07-local-cluster-setup.md) — the kind cluster you'll "upgrade"
**You'll know after this:** • compare kubeadm, managed (EKS/GKE/AKS), kind/k3d and Cluster API provisioning · • run a control-plane-then-nodes upgrade and respect the apiserver → controllers → kubelet order · • apply the version-skew policy (kubelet n-3, controllers n-1, kubectl ±1) safely · • audit deprecated APIs with pluto/kubent before every upgrade · • upgrade a kind cluster and prove the Bookstore reconciles afterwards

<!-- tags: day-2, foundations, drift, cloud -->

## Why this exists

Every chapter so far assumed *a cluster exists* and stayed at v-whatever. In
production a cluster is not a fixed thing: it was **provisioned** by something
(kubeadm, eksctl, Terraform, Cluster API), it runs a **specific Kubernetes
version**, and roughly every three months upstream ships a new minor that
**deprecates and eventually removes API versions** and that you are expected to
adopt before your current one leaves support (upstream supports the **latest
three minors**; managed providers add a few months but not forever). A cluster
you never upgrade is a cluster accumulating CVEs and drifting toward a forced,
high-risk jump.

Two failure modes make this a day-2 chapter rather than a footnote:

1. **The botched upgrade.** Upgrade the API server, the workloads keep running;
   upgrade a kubelet *past* the API server, or skip a minor, and you've
   violated the **version-skew policy** — components silently misbehave or
   refuse to start. Order and skew are not advice, they are correctness.
2. **The removed API.** `extensions/v1beta1 Ingress`, `policy/v1beta1
   PodDisruptionBudget`, `batch/v1beta1 CronJob` — each was deprecated for
   several releases, then **removed**. A manifest (or a Helm chart, or a
   GitOps repo — [Part 07 ch.04](../07-delivery/04-gitops-argocd.md)) pinned to
   a removed `apiVersion` stops applying the moment you upgrade. The fix is to
   **audit before, not debug after**.

This chapter is the operator's answer to "the cluster is software too": how it
is built, how it moves forward safely, and what to check before it does. The
reference is *Production Kubernetes* (Deployment Models); the upgrade and skew
rules are upstream policy and are quoted exactly.

## Mental model

**A cluster has a version, the API server owns it, and everything else trails
it within a bounded window.**

- **Provisioning is a spectrum of "who runs the control plane".** At one end
  **kubeadm** bootstraps a control plane *you* run (etcd, apiserver,
  controller-manager, scheduler as static Pods on nodes you own and patch). At
  the other end **managed** (EKS/GKE/AKS) hides the control plane entirely —
  you never see an apiserver Pod, you only own **node pools**. kind/k3d
  collapse the whole thing into containers on one machine for learning.
  **Cluster API** is the reflexive option: clusters described as Kubernetes
  objects, reconciled by a management cluster.
- **The API server is the version reference.** Not "the cluster version" in the
  abstract — the **kube-apiserver** binary's minor version is the number
  everything else is measured against. You upgrade it **first**.
- **Everything else trails within a fixed window (the skew policy).**
  controller-manager/scheduler may be **one minor behind** the apiserver;
  **kubelet up to three minors behind** (n-3, since 1.28; was n-2); `kubectl`
  within **±1**. Crucially you **never** run a component *ahead* of the
  apiserver, and you **never skip a minor** on the way up (1.30 → 1.31 → 1.32,
  not 1.30 → 1.32).
- **Upgrade is control-plane-first, then nodes one at a time.** Bump the
  control plane in place (apiserver → controller-manager/scheduler), then walk
  the nodes: **drain → upgrade kubelet/kube-proxy → uncordon**, respecting
  PodDisruptionBudgets ([Part 06 ch.05](../06-production-readiness/05-reliability-and-disruptions.md))
  so the workload survives the rolling node replacement.
- **APIs have a lifecycle independent of the cluster's.** A version goes
  *stable → deprecated (still served, warned) → removed (gone)*. Upgrading the
  cluster is also a deadline for **migrating manifests off removed
  `apiVersion`s** — which is why "what deprecated APIs am I still using?" is a
  pre-upgrade check, not a post-upgrade incident.

The trap to hold onto: **the workloads don't tell you the skew or the removed
API is wrong until it's too late.** Pods keep running across an apiserver
upgrade; the damage shows when a *too-new kubelet* won't register, or when CI's
next `kubectl apply` of a `policy/v1beta1` PDB returns `no matches for kind`.
Day-2 cluster work is disciplined *before* the change.

## Diagrams

### Diagram A — rolling control-plane-then-nodes upgrade sequence (Mermaid)

The actual order a kubeadm-style minor upgrade follows; managed providers
automate the same shape (control plane, then a surge/rolling node-pool
replacement).

```mermaid
sequenceDiagram
    participant Op as Operator
    participant CP as Control plane (CP node)
    participant N as Worker node (per node)
    participant W as Workload (PDB-guarded)

    Note over Op,CP: Pre-flight (BEFORE anything)
    Op->>CP: kubeadm upgrade plan (shows target, checks etcd/health)
    Op->>CP: deprecated-API audit (pluto/kubent) — fix manifests FIRST

    Note over Op,CP: 1. Control plane, in place
    Op->>CP: kubeadm upgrade apply v1.NEXT
    CP->>CP: apiserver upgraded FIRST
    CP->>CP: then controller-manager + scheduler
    CP->>CP: then etcd if coupled; certs rotated
    Op->>CP: kubectl/kubelet on the CP node upgraded + restarted

    Note over Op,N: 2. Nodes, ONE at a time (skew now apiserver=NEW, kubelet=OLD — legal: n-3)
    loop For each worker node
        Op->>N: kubectl drain node --ignore-daemonsets --delete-emptydir-data
        N-->>W: evict Pods (eviction API HONORS the PDB → may block/retry)
        Op->>N: upgrade kubelet + kube-proxy, restart kubelet
        Op->>N: kubectl uncordon node
        W-->>N: scheduler places Pods back; node now on NEW version
    end

    Note over Op,N: Never: kubelet ahead of apiserver. Never: skip a minor.
```

### Diagram B — the version-skew window (ASCII)

```
 VERSION SKEW — the API server is the reference; others trail, never lead ────

   Suppose kube-apiserver = v1.32   (you ALWAYS upgrade this component first)

     component                       allowed window         note
     ───────────────────────────────────────────────────────────────────────
     kube-apiserver        v1.32     == reference            upgrade FIRST
     kube-controller-mgr   v1.31..32 apiserver, n-1          never ahead
     kube-scheduler        v1.31..32 apiserver, n-1          never ahead
     kubelet               v1.29..32 apiserver .. n-3        NEVER ahead;
                                                             n-3 since v1.28
     kube-proxy            v1.29..32 tracks kubelet/node      per node
     kubectl (client)      v1.31..33 apiserver ±1            client only

   Legal mid-upgrade state (this is WHY control-plane-first works):
     apiserver = v1.32 (NEW)   kubelet on not-yet-done nodes = v1.31 (OLD)
       → kubelet is 1 behind  ≤ n-3  → LEGAL, app keeps running while you
         drain/upgrade nodes one by one.

   Illegal (forced, high-risk):
     apiserver v1.30 ──upgrade──▶ v1.32   (SKIPPED v1.31)        ✗ never skip
     kubelet v1.33 with apiserver v1.32   (kubelet AHEAD)        ✗ never lead

   Upgrade order, every time:
     [audit removed APIs] → apiserver → ctrl-mgr/sched → (etcd) →
       node: drain → kubelet/kube-proxy → uncordon  (repeat per node)
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).** This
chapter adds **no** manifests — it operates on the *cluster* the Bookstore runs
on. Everything is self-bootstrapping and reverts to a clean known-good app.

> **The honest kind-upgrade story (read this first).** kind is **not**
> kubeadm-with-an-upgrade-button. A kind "node" is a container running a
> *pinned* Kubernetes node image; kind has **no in-place `kubeadm upgrade`
> workflow** and the project's guidance is explicit: to change a kind cluster's
> Kubernetes version you **create a new cluster at a newer node image**
> (`kind create cluster --image kindest/node:vX.Y.Z`) and re-deploy. So this
> Hands-on is honest in two halves: (a) the **conceptual kubeadm/managed
> upgrade** (the `kubeadm upgrade plan/apply` + drain flow you run on a
> real self-managed or managed cluster — narrated, not faked on kind), and (b)
> a **fully runnable kind "version move"** (recreate at a pinned newer node
> image, re-bootstrap, prove the Bookstore still reconciles) plus the
> **pre-upgrade deprecated-API audit**, which *is* runnable verbatim on kind.
> This is the same established honesty as the GitOps local-vs-remote and
> Velero local-object-store notes — the mechanics are real, only kind's lack of
> a kubeadm upgrade path is substituted, and that substitution is the point.

### 0. Prerequisites — fresh cluster + the four images (self-bootstrapping)

Identical self-bootstrap to every prior chapter. The four `bookstore/*:dev`
images are `kind load`ed; `postgres:16`/`redis:7`/`rabbitmq:3.13-management`
pull from the registry.

```sh
kind delete cluster --name bookstore 2>/dev/null || true
kind create cluster --name bookstore          # pins SOME default node image
kubectl cluster-info

cd examples/bookstore/app
for s in catalog orders payments-worker storefront; do docker build -t bookstore/$s:dev ./$s; done
cd ../../..
for s in catalog orders payments-worker storefront; do kind load docker-image bookstore/$s:dev --name bookstore; done
```

> **Self-bootstrapping note.** After any `kind delete && kind create` you must
> re-`kind load` the four images and re-run the prereq → workload apply chain
> below — a fresh cluster has neither the images nor the app. The chain (used
> by every Part 08 chapter) is: `00-namespace` → `05-serviceaccounts-rbac` →
> `15-/16-` config+secret → `35-priorityclasses` → the workloads.

### 1. See the cluster's version and node versions

The first day-2 question is always "what version is this, exactly?"

```sh
kubectl version                              # Client (kubectl) AND Server (apiserver)
# Client Version: v1.3x.y     ← kubectl; must be within ±1 of the server
# Server Version: v1.3x.y     ← the kube-apiserver — THE reference version

kubectl get nodes -o wide
# the VERSION column is each node's KUBELET version. On a multi-node cluster
# mid-upgrade these legitimately differ from the apiserver (within n-3).

kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"  kubelet="}{.status.nodeInfo.kubeletVersion}{"  containerd="}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}'
```

Bootstrap the Bookstore on this version so there is something to prove
compatible after the move:

```sh
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
# the migration Job must COMPLETE (creates the `books` schema) before
# catalog/orders can become Ready — wait for it BEFORE the deploy wait:
kubectl wait --for=condition=complete job/db-migrate -n bookstore --timeout=120s
kubectl wait --for=condition=available deploy --all -n bookstore --timeout=180s
kubectl get pods -n bookstore
```

### 2. The pre-upgrade deprecated-API audit (runnable verbatim on kind)

**This is the single most important pre-upgrade step** and it runs anywhere.
Before any minor upgrade you must know: *do any of my live objects, or any
manifest in Git, use an `apiVersion` that the target release removes?*

```sh
# (a) what API versions does THIS cluster even serve? Removed kinds are absent.
kubectl api-resources --sort-by=name | head -40
kubectl api-versions | sort                  # every group/version served NOW

# (b) the deprecation warning channel — the apiserver itself warns you.
# Apply anything on a deprecated version and kubectl prints a Warning: line;
# those warnings are also emitted to the audit log and the
# apiserver_requested_deprecated_apis metric (alert on it — Part 06 ch.01).

# (c) the real tooling (conceptual here — installs are project binaries, not
# part of this guide's image set, so narrated like kubent/pluto elsewhere):
#   pluto detect-files -d examples/bookstore/   # scans manifests/charts on disk
#   pluto detect-helm --target-versions k8s=v1.NEXT
#   kubent                                      # "kube-no-trouble": scans the
#                                               #   LIVE cluster for soon-removed
#                                               #   apiVersions and names them
```

The Bookstore is deliberately clean here — every manifest already uses GA
groups (`apps/v1`, `batch/v1`, `networking.k8s.io/v1`, `policy/v1`,
`autoscaling/v2`), exactly so an upgrade is a non-event. Prove it:

```sh
grep -rhoE '^apiVersion: .*' examples/bookstore/raw-manifests/ | sort -u
# apps/v1, batch/v1, networking.k8s.io/v1, policy/v1, v1, autoscaling/v2,
# scheduling.k8s.io/v1 (+ the documented CRD groups: snapshot.storage.k8s.io,
# gateway.networking.k8s.io, kyverno.io, monitoring.coreos.com, keda.sh).
# NONE of these are deprecated/removed — the app crosses minors untouched.
# (If a future you finds a v1beta1 here, `kubectl convert -f old.yaml
#  --output-version <GROUP>/v1` rewrites it to the GA version.)
```

### 3. The conceptual kubeadm / managed upgrade (narrated — not faked on kind)

On a **self-managed kubeadm** cluster the minor upgrade is, in order:

```sh
# --- On the control-plane node ---
kubeadm upgrade plan                 # shows current → target, checks etcd +
                                     #   component health + the cert state
kubeadm upgrade apply v1.NEXT.0      # upgrades the CONTROL PLANE in this order:
#   kube-apiserver  → kube-controller-manager → kube-scheduler
#   (+ etcd if the target couples a new etcd; certs auto-rotated by kubeadm)
# then upgrade the kubelet+kubectl ON the control-plane node and restart it:
apt-get install -y kubelet=1.NEXT.0-* kubectl=1.NEXT.0-* && systemctl restart kubelet

# --- Then EACH worker node, ONE at a time (apiserver=NEW, kubelet=OLD: legal) ---
kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data   # honors PDBs
#   ssh <NODE>: kubeadm upgrade node ; apt install kubelet=1.NEXT.0-* ;
#               systemctl restart kubelet
kubectl uncordon <NODE>              # node returns on the new version
kubectl get nodes -o wide            # VERSION column converges node by node
```

On **managed** (EKS/GKE/AKS) you do **not** run `kubeadm` — the control plane
is the provider's: you click/`eksctl`/`gcloud`/`az` to upgrade the **control
plane**, then upgrade each **node pool** (a *surge* or *rolling* replacement —
new-version nodes are added, old ones cordoned/drained/deleted, PDBs honored).
You never touch an apiserver binary; you do still own the **deprecated-API
audit** (step 2) because removed APIs break *your* manifests regardless of who
runs the control plane.

> The `kubeadm upgrade apply` / drain flow above is **not run on kind** (kind
> has no kubeadm upgrade path — see the honesty note). It is the exact sequence
> on a real self-managed cluster and is shown so the order and the skew window
> are concrete, not abstract.

### 4. The runnable kind "version move" + prove the app still reconciles

kind's real "upgrade" is recreate-at-a-newer-node-image. This **is** runnable:

```sh
# Pick a NEWER pinned kind node image (kind publishes kindest/node:vX.Y.Z per
# release — see github.com/kubernetes-sigs/kind/releases for the exact tags
# your kind binary supports; choose the next minor up from step 1's Server).
kind delete cluster --name bookstore
kind create cluster --name bookstore --image kindest/node:v1.NEXT.0
kubectl version                              # Server Version: now v1.NEXT.x
kubectl get nodes -o wide                    # kubelet VERSION = the new minor

# Re-bootstrap (fresh cluster — re-load images, re-apply the chain from step 0/1)
cd examples/bookstore/app
for s in catalog orders payments-worker storefront; do docker build -t bookstore/$s:dev ./$s; done
cd ../../..
for s in catalog orders payments-worker storefront; do kind load docker-image bookstore/$s:dev --name bookstore; done
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
# … the same prereq → workload chain as step 1 …
kubectl wait --for=condition=available deploy --all -n bookstore --timeout=180s

# PROOF the app is compatible on the new version (no manifest change needed):
kubectl get pods -n bookstore                # all Running/Ready on the new minor
kubectl get deploy,statefulset,svc,netpol,pdb,hpa -n bookstore
kubectl get ns bookstore -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep pod-security
#   pod-security.kubernetes.io/enforce:restricted still enforced on the new
#   minor — PSA is GA since v1.25 and stable across these upgrades, and every
#   Bookstore workload is restricted-shaped, so it admits cleanly post-move.
```

Because the Bookstore uses only GA `apiVersion`s, the "upgrade" is a pure
version move: same manifests, new control plane, app reconciles unchanged —
exactly the property the step-2 audit guarantees. Clean up:

```sh
kind delete cluster --name bookstore
```

## How it works under the hood

- **kubeadm bootstraps; it does not run.** `kubeadm init` generates the PKI
  (CA + apiserver/etcd/kubelet certs), writes static-Pod manifests for
  apiserver/controller-manager/scheduler/etcd into
  `/etc/kubernetes/manifests/` (the kubelet runs whatever is there —
  [Part 00 ch.05](../00-foundations/05-node-components.md)), and stands up the
  cluster. It pointedly does **not** install a CNI, manage day-2 OS patching,
  or auto-upgrade — those are yours. `kubeadm upgrade apply` swaps the
  static-Pod images in the **mandated order** (apiserver first so the version
  reference moves first; then controller-manager/scheduler; then it can
  coordinate an etcd bump) and **renews control-plane certs** as part of the
  apply (one-year client certs are silently rotated on upgrade — a cluster that
  is *never* upgraded can have its certs **expire**, a classic kubeadm
  outage).
- **Why control-plane-first is forced by the skew policy.** The policy permits
  kubelet ≤ n-3 *behind* the apiserver and **forbids it ahead**. Upgrade the
  apiserver first and every old-version kubelet is now "behind" — legal,
  cluster keeps serving — so you can drain/upgrade nodes at leisure. Upgrade a
  kubelet first and it would momentarily be *ahead* of the old apiserver —
  illegal, and the new kubelet may use fields/endpoints the old apiserver
  doesn't have. The order is not stylistic; it is the only sequence that never
  violates skew.
- **n-2 → n-3 kubelet skew (1.28).** Before v1.28 kubelet could be at most 2
  minors behind the apiserver; from v1.28 the supported window widened to **3**
  (eases fleet upgrades — you can finish the control plane and take longer to
  roll a large node fleet). controller-manager/scheduler remain **n-1**;
  `kubectl` remains **±1** (a too-new or too-old kubectl can fail to encode
  requests for the server).
- **API lifecycle & the deprecation policy.** A `v1beta1` is supported for a
  fixed number of releases after a GA `v1` ships, then **removed**; the
  apiserver emits a `Warning:` header and increments
  `apiserver_requested_deprecated_apis` for every request on a deprecated
  version (alertable — [Part 06 ch.01](../06-production-readiness/01-observability-metrics.md)).
  `kubectl convert` rewrites a manifest from an old group/version to the
  current one offline; `pluto` scans **files/charts on disk** and `kubent`
  scans the **live cluster** for soon-removed versions. This is why the audit
  is *before*: the objects already in etcd are auto-converted to the storage
  version on read, but **your source manifests / Helm charts / GitOps repo**
  pinned to a removed version stop applying the instant it's gone.
- **etcd is coupled to the Kubernetes version.** Each Kubernetes minor declares
  a supported etcd version (all 3.x for modern Kubernetes); `kubeadm upgrade`
  may bump the bundled etcd as part of the control-plane step. etcd has its
  **own** upgrade rules (one minor at a time, quorum maintained — never lose
  more than (n-1)/2 members at once); on managed clusters etcd is the
  provider's and you neither see nor upgrade it (which is also why you can't
  `etcdctl snapshot` a managed cluster — [ch.02](02-backup-and-dr.md)).
- **kind has no kubeadm-upgrade because a node is an image.** A kind "node" is
  a container from a *pinned* `kindest/node:vX.Y.Z` image (a pre-baked
  kubeadm-initialised node at that exact version). There is no supported path
  to bump that image in place; the project's documented model is recreate at a
  newer node image. This is *why* the Hands-on splits into "narrate the real
  kubeadm flow" + "run the kind recreate" — kind is a faithful *runtime*, not a
  faithful *lifecycle*.
- **Cluster API (CAPI): clusters as objects.** A *management* cluster runs
  controllers reconciling `Cluster`/`MachineDeployment`/`KubeadmControlPlane`
  CRDs into real *workload* clusters on an infrastructure provider. A version
  upgrade becomes a **declarative field change** (bump the
  `KubeadmControlPlane.spec.version`, then the `MachineDeployment` version) and
  the controllers perform the rolling control-plane-then-nodes replacement for
  you — the same sequence as this chapter, expressed as the declarative model
  ([Part 00 ch.06](../00-foundations/06-declarative-api-model.md)) and the
  controller pattern ([ch.05](05-operators-and-crds.md)).

## Production notes

> **In production: never skip a minor, never let kubelet lead, audit removed
> APIs before every upgrade.** Upgrade strictly **one minor at a time**
> (1.30→1.31→1.32). The API server moves **first**; controller-manager/
> scheduler within n-1; kubelet trails within n-3 and **never ahead**;
> `kubectl` within ±1. Run `pluto`/`kubent` (and watch
> `apiserver_requested_deprecated_apis`) **before** every upgrade and migrate
> manifests/charts/GitOps off any soon-removed `apiVersion` with `kubectl convert` —
> the post-upgrade alternative is "CI's apply suddenly fails with
> `no matches for kind`".

> **In production: node drains must respect PodDisruptionBudgets, and you must
> have them.** Step 1 of every node upgrade is `kubectl drain`, which uses the
> **eviction API** and therefore **honors PDBs** ([Part 06
> ch.05](../06-production-readiness/05-reliability-and-disruptions.md)). The
> Bookstore ships `84-pdb.yaml`; without a PDB a node drain can take down every
> replica of a service at once. Size PDBs and node-pool surge so an upgrade is
> a rolling, always-available replacement. Use `--ignore-daemonsets` (DaemonSet
> Pods are expected per-node) and budget time: a PDB-blocked drain *correctly*
> waits, it does not fail.

> **In production: managed control planes remove half the work and add
> constraints.** EKS/GKE/AKS run, patch, back up, and scale etcd + the
> control-plane for you, and gate upgrades behind **maintenance windows** and a
> **supported-version window** (typically ~14 months of patches per minor,
> shorter than you think — plan the upgrade cadence, don't drift onto an
> end-of-support minor). You still own: node-pool/AMI image upgrades, the
> deprecated-API audit, PDBs, and add-on (CNI/CSI/CoreDNS) version compatibility
> with the new control plane. GKE *release channels* (rapid/regular/stable)
> auto-upgrade — opt in deliberately and keep manifests on GA APIs so an
> auto-upgrade is safe.

> **In production: in-place vs blue-green clusters.** In-place
> (control-plane-then-nodes, this chapter) is the default and is safe with
> PDBs + GA APIs. **Blue-green at the cluster level** — stand up a new cluster
> on the new version, shift traffic, retire the old — is the high-stakes-change
> escape hatch (a risky add-on or CNI change, a very large jump). Because the
> Bookstore's entire desired state is in Git
> ([Part 07 ch.04](../07-delivery/04-gitops-argocd.md)), blue-green is "point a
> fresh Argo CD at the same repo on a new cluster" — the *declarative* state
> rebuilds; **stateful data still needs its own restore**, which is precisely
> [ch.02](02-backup-and-dr.md).

> **In production: certificates rotate on upgrade — a never-upgraded cluster
> can expire.** kubeadm control-plane client certs default to **one year** and
> are renewed by `kubeadm upgrade`/`kubeadm certs renew`. A cluster left
> un-upgraded past a year can hit expired apiserver/kubelet certs (apiserver
> won't start, nodes go `NotReady`). Monitor `kubeadm certs check-expiration`;
> managed clusters handle this for you (another reason cadence matters even
> when "nothing changed").

## Quick Reference

```sh
# WHAT version is this? (apiserver = the reference; nodes = kubelet versions)
kubectl version                                   # Client (±1) and Server
kubectl get nodes -o wide                          # per-node kubelet VERSION

# BEFORE any upgrade — the deprecated-API audit (do this FIRST)
kubectl api-versions | sort                        # served group/versions now
# pluto detect-files -d <DIR> ; pluto detect-helm  # scan manifests/charts
# kubent                                            # scan the LIVE cluster
kubectl convert -f old.yaml --output-version apps/v1   # migrate a manifest

# Self-managed (kubeadm) minor upgrade — control plane FIRST, then nodes
kubeadm upgrade plan
kubeadm upgrade apply v1.NEXT.0                     # apiserver→cm/sched→(etcd)
kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data   # honors PDB
kubeadm upgrade node ; systemctl restart kubelet ; kubectl uncordon <NODE>

# kind "version move" (no kubeadm upgrade path — recreate at a newer image)
kind create cluster --name bookstore --image kindest/node:v1.NEXT.0
```

Minimal skeleton — pin the node image (kind) / declare the version (Cluster API):

```yaml
# kind: the cluster's K8s version IS the node image tag (no in-place upgrade)
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    image: kindest/node:v1.30.0      # bump = new cluster, re-deploy (honest)
---
# Cluster API: an upgrade is a declarative version bump (controllers roll it)
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
spec: { version: v1.31.0 }            # change → rolling control-plane upgrade
```

Checklist:

- [ ] Know the **Server (apiserver)** version and every node's **kubelet**
      version; kubectl within **±1**
- [ ] **Deprecated-API audit done BEFORE the upgrade** (`pluto`/`kubent`,
      `apiserver_requested_deprecated_apis`); manifests/charts/GitOps off
      removed `apiVersion`s (`kubectl convert`)
- [ ] Upgrade **one minor at a time**; **apiserver first**, then
      controller-manager/scheduler (n-1), then kubelet (n-3, **never ahead**)
- [ ] Per node: **drain (honors PDBs) → upgrade kubelet → uncordon**; PDBs
      ([Part 06 ch.05](../06-production-readiness/05-reliability-and-disruptions.md))
      sized so the app stays available
- [ ] etcd version compatible with the target minor (or provider-managed);
      control-plane **certs renewed** by the upgrade
- [ ] Managed: upgrade within the **maintenance window** + **supported-version
      window**; node pools/AMI upgraded; add-ons (CNI/CSI/CoreDNS) compatible
- [ ] Bookstore re-deploys/reconciles on the new version with **no manifest
      change** (it uses only GA APIs — verified by the audit)

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **`kubectl version` shows Server v1.31, but `kubectl get nodes -o wide` shows one node still on kubelet v1.27. Is this safe, and what's the rule?**
   <details><summary>Show answer</summary>

   Marginal — the **version-skew policy** allows kubelet **up to n-3** behind the API server (since 1.28). So v1.31 apiserver with v1.27 kubelet is exactly at the boundary; v1.27 still works but you must upgrade that node before the next minor (or the skew becomes n-4 and violates policy). The hard rule: **never run a component ahead of the apiserver**, and **never skip a minor** on the way up. See §Mental model.

   </details>

2. **You start an upgrade and accidentally `apt install kubelet=1.32.0` on a worker *before* upgrading the v1.30 apiserver. The kubelet won't register; the node goes NotReady. Why?**
   <details><summary>Show answer</summary>

   You violated the rule "never run a component ahead of the apiserver". A v1.32 kubelet speaks API features the v1.30 apiserver doesn't understand; the kubelet's heartbeat/registration fails or behaves unpredictably. Recovery: downgrade the kubelet back to ≤ v1.30 (or upgrade the apiserver to v1.32 first). The upgrade order — **apiserver → controllers → kubelet** — is correctness, not advice.

   </details>

3. **A new engineer wants to upgrade from v1.28 directly to v1.31 because "we're behind anyway." Talk them through why this is wrong and what the right path is.**
   <details><summary>Show answer</summary>

   Kubernetes only supports skew of **one minor at a time** in upgrades: v1.28 → v1.29 → v1.30 → v1.31, applying one step, validating, and proceeding. Skipping minors risks crossing API deprecation/removal boundaries silently (e.g. a v1.29 → v1.30 step removes APIs that worked in v1.29), and the kubelet's allowed skew breaks. Each step's deprecated-API audit (pluto/kubent) runs separately. The right path is one minor at a time, validated by the Bookstore reconciling after each step.

   </details>

4. **Hands-on extension — find a deprecated API. Install `pluto` and run `pluto detect-files -d examples/bookstore/raw-manifests/` against the manifests. What does it report, and what would the same scan show if you'd written manifests using `policy/v1beta1` PodDisruptionBudget?**
   <details><summary>What you should see</summary>

   On the current Bookstore: `pluto` reports zero deprecated APIs — every manifest uses GA versions (`apps/v1`, `policy/v1`, `networking.k8s.io/v1`). If you'd written `policy/v1beta1 PodDisruptionBudget`, pluto would flag it: `policy/v1beta1 PodDisruptionBudget DEPRECATED removed in v1.25`. The "before-upgrade audit" is exactly this scan, run against both raw manifests, Helm charts (`pluto detect-helm`) and live cluster (`kubent`). Catch the removed APIs **before** the upgrade, not during.

   </details>

5. **A kubeadm cluster has been untouched for 14 months. The apiserver suddenly fails to start with `expired certificate`. What's the issue and the fix?**
   <details><summary>Show answer</summary>

   kubeadm-generated control-plane client certs default to **1-year validity**, renewed automatically by `kubeadm upgrade`. A cluster left un-upgraded past that boundary hits expired apiserver / kubelet client certificates → apiserver won't start, kubelets go NotReady. Fix: `kubeadm certs renew all` (manual rotation), restart static pods, restart kubelets — or, better, run **regular upgrades** so renewal happens during the maintenance window. Cadence matters even when "nothing changed", and managed clusters handle this for you (another reason to consider managed for ops bandwidth).

   </details>

## Further reading

- **Rosso et al., _Production Kubernetes_, ch.2 — Deployment Models** (how
  clusters are provisioned and operated: kubeadm vs managed vs Cluster API,
  the lifecycle and upgrade posture of a production cluster) and **ch.1 — A
  Path to Production** (the operational maturity framing around versioning and
  upgrades).
- **Lukša, _Kubernetes in Action_ 2e, ch.3** (cluster components and how the
  control plane is composed — the structural basis for *why* the upgrade order
  is apiserver-first) and the *securing/operating the API server* material.
- Official: the version-skew policy
  <https://kubernetes.io/releases/version-skew-policy/>, the kubeadm upgrade
  task
  <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/>,
  the API deprecation policy
  <https://kubernetes.io/docs/reference/using-api/deprecation-policy/>, and
  kind's "Kubernetes version" guidance
  <https://kind.sigs.k8s.io/docs/user/quick-start/#creating-a-cluster>.
