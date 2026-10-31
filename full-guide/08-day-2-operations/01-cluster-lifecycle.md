# 01: Cluster lifecycle

> Where a cluster *comes from* and how it *changes over time*, treated as
> security work. Provisioning options: **kubeadm**, which runs a control plane
> you patch; **managed** EKS, GKE and AKS, where the provider runs the control
> plane and you own the node pools; **kind**, this guide's local cluster; and
> **Cluster API**, which describes clusters as Kubernetes objects. The support
> window and patch cadence decide when a version stops getting fixes. A CVE
> response is triage, patch, drain and verify. Release binaries are verified
> before they reach a node. The **version-skew policy** sets the order: the API
> server first, kubelets up to **n-3** behind and never ahead,
> controller-manager and scheduler at **n-1**, and kubectl within **±1**.
> Before every upgrade, the deprecated-API audit finds manifests that the target
> release no longer serves.

**Estimated time:** ~30 min read · ~90 min hands-on
**Lab tier:** A (kind, a multi-node kind cluster). Run this chapter's commands only against clusters you own.
**Prerequisites:** [Part 00 ch.04](../00-foundations/04-control-plane-deep-dive.md): what apiserver, etcd and the scheduler do, and what an upgrade actually changes · [Part 00 ch.05](../00-foundations/05-node-components.md): kubelet and kube-proxy on each node · [Part 00 ch.07](../00-foundations/07-local-cluster-setup.md): the kind cluster you'll "upgrade"
**You'll know after this:** • compare kubeadm, managed (EKS/GKE/AKS), kind/k3d and Cluster API provisioning · • read the support window and a CVE advisory, then choose the patch target · • run a control-plane-then-nodes upgrade and respect the apiserver → controllers → kubelet order · • apply the version-skew policy (kubelet n-3, controllers n-1, kubectl ±1) safely · • audit deprecated APIs with a server dry-run and pluto/kubent before every upgrade · • drain a node under a PodDisruptionBudget and watch the budget refuse an eviction · • verify a release binary before it reaches a node

<!-- tags: day-2, foundations, drift, cloud -->

## Why this exists

Every chapter so far assumed *a cluster exists* and stayed at v-whatever. In
production a cluster is not a fixed thing. Something provisioned it (kubeadm,
eksctl, Terraform, Cluster API), it runs a **specific Kubernetes version**, and
about three times a year upstream ships a new minor that **deprecates and
eventually removes API versions**. You are expected to adopt it before your
current minor leaves support. Upstream maintains the **latest three minor
releases** and gives each patch release approximately one year of support
([release policy](https://kubernetes.io/releases/)). Managed providers publish
their own end-of-support dates, which differ, so check them rather than assume
upstream's.

A cluster you never upgrade stops receiving fixes. Every CVE published after
its last patch is a finding you carry, and the forced jump to a supported minor,
when it finally comes, is the high-risk change you were avoiding. That is the
security case for upgrading on a cadence. Three failure modes make it a day-2
topic:

1. **The unpatched cluster.** A minor past its patch window, or a patch release
   nobody applied, leaves a published CVE live on the API server or on a node.
2. **The botched upgrade.** Upgrade the API server and the workloads keep
   running. Upgrade a kubelet *past* the API server, or skip a minor, and you
   have violated the **version-skew policy**: components silently misbehave or
   refuse to start. Order and skew are not advice. They are correctness.
3. **The removed API.** `policy/v1beta1 PodDisruptionBudget` was no longer
   served from v1.25, and so was `policy/v1beta1 PodSecurityPolicy`. A manifest,
   Helm chart or GitOps repo
   ([Part 07 ch.04](../07-delivery/04-gitops-argocd.md))
   pinned to a removed `apiVersion` stops applying the moment you upgrade. When
   the apply runs in a script that ignores its errors, or a chart skips the
   object because the API is absent, the policy object silently never lands.
   The fix is to **audit before, not debug after**.

This chapter is the operator's answer to "the cluster is software too": how it
is built, how it moves forward safely, how a fix reaches it, and what to check
before it does. The skew and deprecation rules are upstream policy. The text
paraphrases them and links the source.

## Mental model

**A cluster has a version, the API server owns it, and everything else trails
it within a bounded window.**

- **Provisioning is a spectrum of "who runs the control plane".** At one end
  **kubeadm** bootstraps a control plane *you* run: etcd, apiserver,
  controller-manager and scheduler as static Pods on nodes you own and patch.
  At the other end **managed** (EKS, GKE, AKS) hides the control plane. You
  never see an apiserver Pod, and you own only the **node pools**. kind and k3d
  collapse the whole thing into containers on one machine, for learning.
  **Cluster API** is the reflexive option: clusters described as Kubernetes
  objects, reconciled by a management cluster.
- **The API server is the version reference.** The **kube-apiserver** minor
  version is the number everything else is measured against. You upgrade it
  **first**.
- **Everything else trails within a fixed window (the skew policy).**
  controller-manager and scheduler may be **one minor behind** the apiserver.
  **kubelet may be up to three minors behind** (two for kubelets older than
  1.25). `kubectl` may be one minor older or newer. Nothing may run **ahead** of
  the apiserver, and an upgrade does not skip a minor. kubeadm's upgrade page
  states that skipping minor versions is unsupported.
- **Upgrade is control-plane-first, then nodes one at a time.** Bump the control
  plane in place (apiserver, then controller-manager and scheduler), then walk
  the nodes: **drain, upgrade kubelet and kube-proxy, uncordon**. The
  PodDisruptionBudgets
  ([Part 06 ch.05](../06-production-readiness/05-reliability-and-disruptions.md))
  keep the workload up through the rolling node replacement.
- **APIs have a lifecycle independent of the cluster's.** A version goes
  *stable, then deprecated (still served, with a warning), then removed*. The
  deprecation policy sets the minimum. A GA API may be deprecated but is not
  removed within its major version. A beta API is no longer served 9 months or
  3 minor releases after deprecation, whichever is longer. Upgrading is also the
  deadline for moving manifests off removed `apiVersion`s, which is why "what
  deprecated APIs am I still using?" is a pre-upgrade check.

The trap to hold onto: **the workloads do not tell you that the skew or the
removed API is wrong until it is too late.** Pods keep running across an
apiserver upgrade. The damage shows when a too-new kubelet will not register,
or when CI's next `kubectl apply` of a `policy/v1beta1` PDB returns `no matches
for kind`. Day-2 cluster work is disciplined *before* the change.

## Threats and controls

| Threat | Control this chapter teaches | Goes deeper |
|---|---|---|
| A published CVE stays live because nobody tracked the patch window of the running minor | Read the support window and the official CVE feed, then patch and verify (step 5) | Node and control-plane hardening: 05.06 <!-- link-later: 05.06 --> |
| A release binary is replaced, or is not the one the project published | Verify the signature before the binary runs (step 6) | Binary verification concepts: 05.06 <!-- link-later: 05.06 -->; image signing: [05.03](../05-security/03-supply-chain.md) |
| A skewed upgrade breaks a control component, so a patch becomes an outage | The apiserver-first order and the skew window (Mental model) | [Part 00 ch.04](../00-foundations/04-control-plane-deep-dive.md) for what each component does |
| A removed `apiVersion` silently drops a policy object, because the apply fails in a pipeline that ignores errors | A server dry run and the deprecated-API audit before the upgrade (step 3) | Operator-managed APIs: [11.02](../11-advanced-production-patterns/02-operator-development.md) |
| A drain evicts every replica of a workload at once | A PodDisruptionBudget that the eviction API enforces (step 4) | [Part 06 ch.05](../06-production-readiness/05-reliability-and-disruptions.md) |

## Diagrams

### Diagram A: rolling control-plane-then-nodes upgrade sequence (Mermaid)

The order a kubeadm-style minor upgrade follows. Managed providers automate the
same shape: the control plane, then a surge or rolling node-pool replacement.
This diagram is illustrative; it is not captured output.

```mermaid
sequenceDiagram
    participant Op as Operator
    participant CP as Control plane (CP node)
    participant N as Worker node (per node)
    participant W as Workload (PDB-guarded)

    Note over Op,CP: Pre-flight (BEFORE anything)
    Op->>CP: kubeadm upgrade plan (shows target, checks etcd/health)
    Op->>CP: deprecated-API audit (pluto/kubent): fix manifests FIRST

    Note over Op,CP: 1. Control plane, in place
    Op->>CP: kubeadm upgrade apply v1.NEXT
    CP->>CP: apiserver upgraded FIRST
    CP->>CP: then controller-manager + scheduler
    CP->>CP: then etcd if coupled; certs rotated
    Op->>CP: kubectl/kubelet on the CP node upgraded + restarted

    Note over Op,N: 2. Nodes, ONE at a time (skew now apiserver=NEW, kubelet=OLD: legal, n-3)
    loop For each worker node
        Op->>N: kubectl drain node --ignore-daemonsets --delete-emptydir-data
        N-->>W: evict Pods (eviction API HONORS the PDB; may block and retry)
        Op->>N: upgrade kubelet + kube-proxy, restart kubelet
        Op->>N: kubectl uncordon node
        W-->>N: scheduler places Pods back; node now on NEW version
    end

    Note over Op,N: Never: kubelet ahead of apiserver. Never: skip a minor.
```

### Diagram B: the version-skew window (ASCII)

```
 VERSION SKEW: the API server is the reference; others trail, never lead

   Suppose kube-apiserver = v1.37   (you ALWAYS upgrade this component first)

     component                       allowed window         note
     ───────────────────────────────────────────────────────────────────────
     kube-apiserver        v1.37     == reference            upgrade FIRST
     kube-controller-mgr   v1.36..37 apiserver, n-1          never ahead
     kube-scheduler        v1.36..37 apiserver, n-1          never ahead
     kubelet               v1.34..37 apiserver .. n-3        NEVER ahead
     kubectl (client)      v1.36..38 apiserver ±1            client only

   Legal mid-upgrade state (this is WHY control-plane-first works):
     apiserver = v1.37 (NEW)   kubelet on not-yet-done nodes = v1.36 (OLD)
       → kubelet is 1 behind  ≤ n-3  → LEGAL, app keeps running while you
         drain/upgrade nodes one by one.

   Illegal (forced, high-risk):
     apiserver v1.35 ──upgrade──▶ v1.37   (SKIPPED v1.36)        ✗ never skip
     kubelet v1.37 with apiserver v1.36   (kubelet AHEAD)        ✗ never lead

   Upgrade order, every time:
     [audit removed APIs] → apiserver → ctrl-mgr/sched → (etcd) →
       node: drain → kubelet/kube-proxy → uncordon  (repeat per node)
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).** This chapter
adds one small workload to the lab cluster: a namespace, a Deployment and a
PodDisruptionBudget for the drain step. Every manifest carries the
[baseline](../01-core-workloads/01-pods.md#baseline) in full.

> **Read this first: what runs here and what does not.** This lab runs against
> a kind cluster you own. A kind node is a container running a pinned Kubernetes
> node image, and the cluster's version is that image. kind has no
> `kubeadm upgrade` command, so a version change is a new cluster built from a
> newer image. Steps that would change a cluster's version are marked **not
> run**, and they are not part of the captured evidence. The steps that run are
> the ones an upgrade depends on: the version check, the deprecated-API audit, a
> drain that a PodDisruptionBudget refuses, and CVE triage. The kubeadm upgrade,
> the verified binary install and the kind version move are cited and labeled.

The captured output in this chapter came from a three-node kind cluster named
`lab` (context `kind-lab`, Kubernetes v1.37.0), not from a cluster
named `bookstore`. The namespace the commands name, `drain-demo`, was
`p08-01-drain` in that run. Node and pod names below come from that
cluster, with its name shortened to `lab`, and yours will differ.

### 1. See the cluster's version and node versions

The first day-2 question is always "what version is this, exactly?"

```sh
kubectl version
kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,UNSCHEDULABLE:.spec.unschedulable
```

`Server Version` is the kube-apiserver, the reference. `kubectl` must stay
within
one minor of it. The `KUBELET` column is each node's kubelet. During an upgrade
these legitimately differ from the apiserver, within the skew window.

<!-- gate: output -->
```
$ kubectl version
Client Version: v1.37.2
Kustomize Version: v5.8.1
Server Version: v1.37.0
```

<!-- gate: output -->
```
NAME                     KUBELET   RUNTIME              UNSCHEDULABLE
lab-control-plane   v1.37.0   containerd://2.3.4   <none>
lab-worker          v1.37.0   containerd://2.3.4   <none>
lab-worker2         v1.37.0   containerd://2.3.4   <none>
```

### 2. Write the drill's manifests

The drill needs a namespace, a workload and a PodDisruptionBudget. The
namespace is restricted and default-deny, as the baseline asks of every
namespace from [02.06](../02-networking/06-network-policies.md) on. The pause
container makes no network calls, so denying all traffic costs it nothing. The
workload carries the baseline: a dedicated
ServiceAccount that does not mount a token, the pod-level and container-level
hardening fields, and a writable `/tmp` from an `emptyDir`. The container is the
Kubernetes pause image, which holds a Pod's namespaces and runs nothing else.
Its upstream
[Dockerfile](https://github.com/kubernetes/kubernetes/blob/master/build/pause/Dockerfile)
declares `USER 65535:65535`, so `runAsUser` and `runAsGroup` are that UID and
GID. The drill tests scheduling and eviction, not an application.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: drain-demo
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: drain-demo
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
```

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: drain-demo
  namespace: drain-demo
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: drain-demo
  namespace: drain-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: drain-demo
  template:
    metadata:
      labels:
        app: drain-demo
    spec:
      serviceAccountName: drain-demo
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65535
        runAsGroup: 65535
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          # pause image; the digest is the one 00.03 pins
          image: registry.k8s.io/pause@sha256:7031c1b283388d2c2e09b57badb803c05ebed362dc88d84b480cc47f72a21097
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

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: drain-demo
  namespace: drain-demo
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: drain-demo
```

Save the three blocks as `namespace.yaml` (the namespace and its policy),
`workload.yaml` and `pdb.yaml`, then create the namespace and the policy:

```sh
kubectl apply -f namespace.yaml
```

<!-- gate: output -->
```
namespace/p08-01-drain created
networkpolicy.networking.k8s.io/default-deny-all created
```

### 3. Audit the APIs before the upgrade

**This is the step that runs before any minor upgrade.** Ask two questions:
what does the cluster serve, and do my manifests use an `apiVersion` that the
target release does not serve?

```sh
kubectl api-versions | grep -E '^(policy|flowcontrol)' | sort
```

<!-- gate: output -->
```
$ kubectl api-versions | grep -E '^(policy|flowcontrol)' | sort
flowcontrol.apiserver.k8s.io/v1
policy/v1
```

`policy/v1beta1` is absent, because this server no longer serves it. The
deprecation guide records that `policy/v1beta1` PodDisruptionBudget was no
longer served as of v1.25, and that `flowcontrol.apiserver.k8s.io/v1beta3` was
no longer served as of v1.32. Two removals, two releases, both invisible until a
manifest applies.

Now test a manifest under the removed group version. A server dry run asks the
API server to validate the object without storing it:

```sh
sed 's#policy/v1$#policy/v1beta1#' pdb.yaml > pdb-v1beta1.yaml
kubectl apply --dry-run=server -f pdb-v1beta1.yaml
kubectl apply --dry-run=server -f pdb.yaml
```

<!-- gate: output -->
```
$ kubectl apply --dry-run=server -f pdb-v1beta1.yaml
error: resource mapping not found for name: "drain-demo" namespace: "p08-01-drain" from "pdb-v1beta1.yaml": no matches for kind "PodDisruptionBudget" in version "policy/v1beta1"
ensure CRDs are installed first

$ kubectl apply --dry-run=server -f pdb.yaml
poddisruptionbudget.policy/drain-demo created (server dry run)
```

The first command is refused, loudly. The second passes, and nothing is created.
A pipeline that ignores apply errors, or a Helm chart that skips an object when
its API is absent, would report success while the PodDisruptionBudget never
lands. After any apply in such a pipeline, read the object back.

The Bookstore's own manifests use GA groups (`apps/v1`, `batch/v1`,
`networking.k8s.io/v1`, `policy/v1`, `autoscaling/v2`, `scheduling.k8s.io/v1`),
plus CRD groups such as `keda.sh`, `kyverno.io` and `monitoring.coreos.com`. Run
this to list the groups in use:

```sh
grep -rhoE '^apiVersion: .*' examples/bookstore/raw-manifests/ | sort -u
```

The audit judges the core groups. A CRD group is judged by its operator's
release notes, which this check does not read. Tools such as `pluto` (files and
charts on disk) and `kubent` (the live cluster) scan for soon-removed versions,
but they are separate project binaries, and this lab does not install them.

Apply the workload and the budget, then confirm the rollout:

```sh
kubectl apply -f workload.yaml
kubectl apply -f pdb.yaml
kubectl rollout status deployment/drain-demo -n drain-demo --timeout=180s
kubectl get pods -n drain-demo -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase
```

<!-- gate: output -->
```
serviceaccount/drain-demo created
deployment.apps/drain-demo created
# ...
poddisruptionbudget.policy/drain-demo created
# ...
Waiting for deployment "drain-demo" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "drain-demo" rollout to finish: 1 of 2 updated replicas are available...
deployment "drain-demo" successfully rolled out
```

<!-- gate: output -->
```
NAME                          NODE               PHASE
drain-demo-7549c4bbd6-5bq79   lab-worker    Running
drain-demo-7549c4bbd6-nn5qk   lab-worker2   Running
```

### 4. Drain a worker under a PodDisruptionBudget

Drain a worker that runs one of the drill's replicas. The listing above shows
which. `--pod-selector` limits the drain to this drill's Pods, so other
workloads on the node are left alone. Cordon first so that nothing new lands on
the node, then drain. Replace `<worker>` with the node name:

```sh
kubectl cordon <worker>
kubectl drain <worker> --ignore-daemonsets --delete-emptydir-data --pod-selector app=drain-demo --timeout=45s
```

<!-- gate: output -->
```
$ kubectl cordon lab-worker2
node/lab-worker2 cordoned

$ kubectl drain lab-worker2 --ignore-daemonsets --delete-emptydir-data --pod-selector app=drain-demo --timeout=45s
node/lab-worker2 already cordoned
evicting pod p08-01-drain/drain-demo-7549c4bbd6-nn5qk
error when evicting pods/"drain-demo-7549c4bbd6-nn5qk" -n "p08-01-drain" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
# ...
There are pending nodes to be drained:
 lab-worker2
error when evicting pods/"drain-demo-7549c4bbd6-nn5qk" -n "p08-01-drain": global timeout reached: 45s
```

The drain is refused, and it does not fail open. The worker runs one replica,
and the budget requires both, so evicting it would break the budget. The
eviction API says no, and
`kubectl` keeps retrying until the global timeout. That waiting is what a node
upgrade relies on: a drain holds back rather than taking every replica down at
once. The eviction retries are shown above, condensed with `# ...`.

The drill's budget cannot be satisfied as written. With `replicas: 2` and
`minAvailable: 2`, the budget allows no disruption at all, however much
capacity the cluster has, so adding a worker cannot unblock this drain. Two
changes can: lower `minAvailable`, or run three replicas so that one may be
evicted. Read the budget with `kubectl get pdb`, which shows how many
disruptions the cluster currently allows:

```sh
kubectl get pdb drain-demo -n drain-demo
```

<!-- gate: output -->
```
$ kubectl get pdb drain-demo -n p08-01-drain
NAME         MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
drain-demo   2               N/A               0                     52s
```

`ALLOWED DISRUPTIONS` is 0. Put the worker back in service, and confirm that
the nodes are schedulable again:

```sh
kubectl uncordon <worker>
kubectl get nodes -o custom-columns=NAME:.metadata.name,UNSCHEDULABLE:.spec.unschedulable
```

<!-- gate: output -->
```
$ kubectl uncordon lab-worker2
node/lab-worker2 uncordoned

$ kubectl get nodes -o custom-columns=NAME:.metadata.name,UNSCHEDULABLE:.spec.unschedulable
NAME                     UNSCHEDULABLE
lab-control-plane   <none>
lab-worker          <none>
lab-worker2         <none>
```

### 5. CVE response: triage, patch, drain, verify

A published CVE is an upgrade with a deadline. The procedure is the same
whether the fix is a patch release or a new minor.

1. **Triage.** Read the official CVE feed. It is published as
   [JSON and RSS](https://kubernetes.io/docs/reference/issues-security/official-cve-feed/),
   is maintained by the Kubernetes project, and lists each CVE with a summary
   and
   a link to its GitHub issue. The affected and fixed versions are in that
   advisory, not in the feed listing. Compare them with the `Server Version`
   from step 1. A fix in your minor is a patch. A fix only in a newer minor is
   an
   upgrade, and it goes through the upgrade order in this chapter.
2. **Patch the control plane first.** A kubelet must not be newer than the
   kube-apiserver it talks to, so the API server takes the fix before any node.
   On a kubeadm cluster this is the `kubeadm upgrade` path in step 7. On a
   managed cluster the provider patches the control plane, and you roll the node
   pools. On kind the patch is a new cluster from the patched node image, which
   the kind release notes pin by digest.
3. **Drain each node under its budget.** Use the drain from step 4 for each
   node. The eviction API refuses any eviction that breaks a
   PodDisruptionBudget,
   so the rollout waits instead of taking the workload down. A node with no
   budget and one replica is the case to fix first.
4. **Verify.** `kubectl version` shows the fixed `Server Version`, and
   `kubectl get nodes` shows every kubelet on a version that is allowed by the
   skew window. Where the advisory describes a check, run it against a cluster
   you own, and expect the issue to be gone.

Steps 2 and 3 change a cluster's version. They are **not run** in this lab,
because the lab cluster is shared and a version move is not something to run on
it. The triage comparison in step 1 is the part this chapter runs.

### 6. Verify the release binary before it runs (not run)

The upstream project signs release binaries. Each binary is published with a
signature (`.sig`) and a certificate (`.cert`) next to it, and
[the signed-artifacts page](https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/)
documents this check. Verify before the binary touches a node:

```sh
URL=https://dl.k8s.io/release/v1.37.0/bin/linux/amd64
BINARY=kubectl
FILES=("$BINARY" "$BINARY.sig" "$BINARY.cert")
for FILE in "${FILES[@]}"; do
  curl -sSfL --retry 3 --retry-delay 3 "$URL/$FILE" -o "$FILE"
done
cosign verify-blob "$BINARY" \
  --signature "$BINARY".sig \
  --certificate "$BINARY".cert \
  --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
  --certificate-oidc-issuer https://accounts.google.com
```

**Not run.** The step downloads a release binary, and `cosign` is not installed
on the machine that ran this lab. The identity and issuer are the values the
release page gives for binaries. Container images use a different signing
identity, documented on the same page. A failed verification is a stop, not a
retry: read the advisory and the release notes, and do not install the binary.

### 7. The kubeadm upgrade (narrated, not run)

On a self-managed kubeadm cluster, the minor upgrade runs in this order. The
upgrade page covers the steps for each minor, and it says that skipping minor
versions is unsupported.

```sh
# On the first control-plane node: upgrade kubeadm, then the control plane
apt-get install -y kubeadm=1.NEXT.0-*   # the package comes first
kubeadm upgrade plan                    # current -> target; checks etcd, health, certs
kubeadm certs check-expiration          # control-plane certificates and their dates
kubeadm upgrade apply v1.NEXT.0         # upgrades the control plane components
kubectl drain <CP-NODE> --ignore-daemonsets --delete-emptydir-data   # honors PDBs
#   on the node: upgrade kubelet and kubectl; systemctl restart kubelet
kubectl uncordon <CP-NODE>

# Then each worker node, one at a time
#   on the node: upgrade kubeadm; kubeadm upgrade node
kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data   # honors PDBs
#   on the node: upgrade kubelet; systemctl restart kubelet
kubectl uncordon <NODE>
kubectl get nodes -o wide            # the VERSION column converges node by node
```

**Not run.** A kind node has no `kubeadm upgrade` path, and these steps need
real control-plane nodes. The apiserver-first order in the comments is the
behavior this chapter depends on. The order that `kubeadm upgrade apply` uses
for the components, and how it renews certificates, are kubeadm's own behavior
that this chapter narrates and did not capture. Check them in the kubeadm
reference before you run the upgrade.

### 8. The kind version move (not run)

kind's version is its node image. A move is a new cluster from a newer image,
which is why the lab does not run it on a shared cluster. The kind release notes
list each node image by version and digest. These are the digests the notes list
for kind v0.33.0, and they match the kind cluster configuration this guide uses:

```sh
kind delete cluster --name bookstore 2>/dev/null || true
kind create cluster --name bookstore \
  --image kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
# ... load the images and apply the Bookstore chain, then:
kind delete cluster --name bookstore
kind create cluster --name bookstore \
  --image kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
kubectl version                      # Server Version: v1.37.0 on the new cluster
kubectl get nodes -o wide            # kubelet VERSION is the new minor
```

**Not run.** Run this on a cluster you can delete, and only after loading the
four Bookstore images and applying the Bookstore manifests, which carry the
baseline. The check that matters afterwards is the Bookstore reconciling with no
manifest change: every `Deployment` and `StatefulSet` ready, and every
namespace still enforcing `restricted`. The audit in step 3 is what makes that
expectation reasonable.

### Clean up

```sh
kubectl delete namespace drain-demo
```

<!-- gate: output -->
```
namespace "p08-01-drain" deleted
```

## How it works under the hood

- **kubeadm bootstraps; it does not run.** `kubeadm init` generates the PKI (a
  CA, plus apiserver, etcd and kubelet
  certificates), writes static Pod manifests
  for the apiserver, controller-manager, scheduler and etcd into
  `/etc/kubernetes/manifests/`, and stands up the cluster. The kubelet runs
  whatever is there ([Part 00 ch.05](../00-foundations/05-node-components.md)).
  kubeadm does not install a CNI, patch the operating system, or upgrade the
  cluster on its own. Those are yours.
- **Why control-plane-first is forced by the skew policy.** The policy lets a
  kubelet be up to three minors behind the apiserver and forbids it being ahead.
  Upgrade the apiserver first, and every old kubelet is now behind, which is
  allowed. The cluster keeps serving while you drain and upgrade the nodes at
  your pace. Upgrade a kubelet first, and it is momentarily ahead of the old
  apiserver, which the policy forbids. The new kubelet may also rely on fields
  the old apiserver does not serve. The order is the only sequence that never
  breaks the policy.
- **The skew windows.** The skew page allows a kubelet three minors behind the
  apiserver, and two for kubelets older than 1.25. controller-manager, scheduler
  and cloud-controller-manager may be one minor behind. kubectl is supported
  within one minor either way. In an HA cluster with mixed apiserver versions,
  the window narrows to the older apiserver, as the page's own examples show.
- **The deprecation policy.** A deprecated API is still served, but a request to
  it returns a `Warning` header, adds an audit annotation, and increments the
  `apiserver_requested_deprecated_apis` metric. Alert on that metric
  ([Part 06 ch.01](../06-production-readiness/01-observability-metrics.md)). The
  policy sets the minimum time before removal, as the Mental model describes.
  The `kubectl-convert` plugin rewrites a manifest to a newer group version
  offline. It ships separately from kubectl, so install it from the release page
  and verify it as step 6 shows. The
  objects already in etcd are converted to the storage version on read. Your
  source manifests, Helm charts and GitOps repo are not converted, and they stop
  applying the moment a version is removed.
- **Certificates and upgrades.** kubeadm issues control-plane client
  certificates with a one-year validity by default, and `kubeadm upgrade` renews
  them during the upgrade. `kubeadm certs check-expiration` shows what is left.
  A cluster that is never upgraded can have certificates expire, which is a
  classic kubeadm outage.
- **etcd is coupled to the Kubernetes version.** Each Kubernetes release is
  paired with an etcd version, and a control-plane upgrade can bump the bundled
  etcd. etcd has its own upgrade guide, which moves one minor at a time with
  quorum kept. On a managed cluster the provider runs etcd, and you cannot
  take an
  `etcdctl` snapshot of it ([ch.02](02-backup-and-dr.md)).
- **kind has no kubeadm upgrade, because a node is an image.** A kind node is a
  container built from a pinned `kindest/node` image. The kind release notes say
  to use the digest, so you get the image built for that release. A new version
  means a new cluster from a newer image. kind is a faithful runtime for this
  work, not a faithful lifecycle, which is why this chapter narrates the real
  kubeadm flow and marks the kind recreation as not run.
- **Cluster API: clusters as objects.** A management cluster runs controllers
  that reconcile `Cluster`, `MachineDeployment` and `KubeadmControlPlane`
  objects
  into workload clusters on an infrastructure provider. A version upgrade is a
  field change on those objects. The controllers then perform the rolling
  control-plane-then-nodes replacement, the same sequence as this chapter,
  expressed declaratively
  ([Part 00 ch.06](../00-foundations/06-declarative-api-model.md)
  and the controller pattern in [ch.05](05-operators-and-crds.md)).

## Production notes

> **In production: never skip a minor, never let kubelet lead, audit removed
> APIs before every upgrade.** Upgrade one minor at a time. The kubeadm upgrade
> page says skipping minor versions is unsupported. The API server moves first.
> Controller-manager and scheduler follow within one minor. Kubelets trail
> within
> the window and never lead. kubectl stays within one minor. Run `pluto` or
> `kubent`, and watch `apiserver_requested_deprecated_apis`, before every
> upgrade.
> Migrate manifests, charts and GitOps sources off any soon-removed `apiVersion`
> with `kubectl-convert`. The alternative is the post-upgrade failure, where
> CI's
> apply suddenly fails with `no matches for kind`.

> **In production: a patch is an upgrade with a deadline.** Upstream maintains
> the latest three minor releases and gives each patch release approximately one
> year of support ([release policy](https://kubernetes.io/releases/)). Subscribe
> to the official CVE feed and tie each advisory to the minors you run. A minor
> that is still served can already be outside its patch window, so check the
> window, not only the version.

> **In production: node drains must respect PodDisruptionBudgets, and you must
> have them.** Step 1 of every node upgrade is `kubectl drain`, which uses the
> eviction API and therefore honors PDBs ([Part 06
> ch.05](../06-production-readiness/05-reliability-and-disruptions.md)). The
> Bookstore ships `84-pdb.yaml`. Without a budget, a drain can take down every
> replica of a service at once. A budget caps how many replicas may be down at once.
> Replacements need room to run, and a budget with no spare replicas blocks
> every drain, so size the budget and the replica count together. Use
> `--ignore-daemonsets` (DaemonSet Pods are expected on every node) and budget
> time: a PDB-blocked drain correctly waits, and it does not fail.

> **In production: managed control planes remove half the work and add
> constraints.** EKS, GKE and AKS run, patch, back up and scale etcd and the
> control plane for you. They gate upgrades behind maintenance windows and their
> own end-of-support dates. Check those dates; they are not upstream's. You
> still
> own node-pool and image upgrades, the deprecated-API audit, PDBs, and add-on
> compatibility (CNI, CSI, CoreDNS). GKE release channels (rapid, regular,
> stable) can upgrade automatically. Opt in deliberately, and keep manifests on
> GA APIs so an automatic upgrade is safe.

> **In production: in-place vs blue-green clusters.** In-place
> (control-plane-then-nodes, this chapter) is the default, and it is safe with
> PDBs and GA APIs. **Blue-green at the cluster level**
> (stand up a new cluster on
> the new version, shift traffic, retire the old one) is the high-stakes escape
> hatch: a risky add-on or CNI change, or a very large jump. Because the
> Bookstore's entire desired state is in Git
> ([Part 07 ch.04](../07-delivery/04-gitops-argocd.md)), blue-green is "point a
> fresh Argo CD at the same repo on a new cluster". The declarative state
> rebuilds, but stateful data still needs its own restore, which is
> [ch.02](02-backup-and-dr.md).

> **In production: certificates rotate on upgrade, and a never-upgraded cluster
> can expire.** kubeadm control-plane client certificates default to one year,
> and `kubeadm upgrade` renews them. A cluster left un-upgraded past that
> boundary can hit expired apiserver or kubelet certificates. The apiserver
> stops
> starting, and nodes go `NotReady`. Monitor `kubeadm certs check-expiration`.
> Managed clusters handle this for you, which is one more reason cadence matters
> even when nothing changed.

> **In production: verify what you install.** Verify each release binary you put
> on a node, and each image you deploy, against its published signature before
> it
> runs. The check is in step 6, and the admission policy that enforces it for
> images is [05.03](../05-security/03-supply-chain.md).

## Quick Reference

```sh
# WHAT version is this? (apiserver = the reference; nodes = kubelet versions)
kubectl version                                    # Client (±1) and Server
kubectl get nodes -o wide                          # per-node kubelet VERSION

# BEFORE any upgrade: the deprecated-API audit (do this FIRST)
kubectl api-versions | sort                        # served group/versions now
sed 's#policy/v1$#policy/v1beta1#' pdb.yaml > probe.yaml
kubectl apply --dry-run=server -f probe.yaml       # a removed version is refused
# pluto detect-files -d <DIR> ; kubent             # project tools: files and live cluster
kubectl-convert -f old.yaml --output-version apps/v1   # migrate a manifest (plugin)

# CVE TRIAGE: compare the advisory's fixed versions with the Server Version above

# Self-managed (kubeadm) minor upgrade: control plane FIRST, then nodes
apt-get install -y kubeadm=1.NEXT.0-*             # upgrade kubeadm first
kubeadm upgrade plan
kubeadm certs check-expiration
kubeadm upgrade apply v1.NEXT.0                    # apiserver, then the rest
kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data
kubeadm upgrade node ; systemctl restart kubelet ; kubectl uncordon <NODE>

# Verify a release binary before it runs (cosign, from the release page)
cosign verify-blob kubectl --signature kubectl.sig --certificate kubectl.cert \
  --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
  --certificate-oidc-issuer https://accounts.google.com

# kind "version move": a new cluster from a newer pinned node image (not on a shared cluster)
kind create cluster --name bookstore \
  --image kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
```

Minimal skeleton: pin the node image. A kind cluster's Kubernetes version is its
node image, so a version change is a new cluster:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    # bump = new cluster, re-deploy (honest); pin the digest kind lists
    image: kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
```

Checklist:

- [ ] Know the **Server (apiserver)** version and every node's **kubelet**
      version; kubectl within **±1**
- [ ] The support window and the CVE feed checked for the minor you run;
      each advisory's fixed version recorded
- [ ] **Deprecated-API audit done BEFORE the upgrade** (`pluto`/`kubent`,
      `apiserver_requested_deprecated_apis`, a server dry run); manifests,
      charts and GitOps sources off removed `apiVersion`s (`kubectl-convert`)
- [ ] Upgrade **one minor at a time**; **apiserver first**, then
      controller-manager and scheduler (n-1), then kubelets
      (n-3, **never ahead**)
- [ ] Each release binary verified against its signature before it runs
- [ ] Per node: **drain (honors PDBs) → upgrade kubelet → uncordon**; PDBs
      ([Part 06 ch.05](../06-production-readiness/05-reliability-and-disruptions.md))
      sized so the app stays available
- [ ] etcd and certificates checked by the upgrade; `kubeadm certs
      check-expiration` run before the change
- [ ] Managed: upgrade within the **maintenance window** and the provider's
      end-of-support dates; node pools and add-ons (CNI/CSI/CoreDNS) compatible
- [ ] Bookstore re-deploys and reconciles on the new version with **no
      manifest change** (it uses GA APIs; the audit checks the core groups)

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **`kubectl version` shows Server v1.37, but `kubectl get nodes -o wide` shows one node still on kubelet v1.34. Is this safe, and what's the rule?**
   <details><summary>Show answer</summary>

   It is inside the window, but at its edge. The skew policy allows a kubelet **up to three minors behind** the API server, so v1.34 under v1.37 is allowed today. The next apiserver minor would put that kubelet outside the window, so upgrade that node before the next control-plane step. The rules: **never run a component ahead of the apiserver**, and **never skip a minor** on the way up. See the Mental model.

   </details>

2. **You start an upgrade and accidentally `apt install kubelet=1.37.2` on a worker *before* upgrading the v1.35 apiserver. The kubelet won't register; the node goes NotReady. Why?**
   <details><summary>Show answer</summary>

   You broke the rule "never run a component ahead of the apiserver". The skew policy says a kubelet must not be newer than the kube-apiserver it talks to. Recovery: downgrade the kubelet to a version at or below the apiserver, or upgrade the apiserver one minor at a time (v1.35, then v1.36, then v1.37). The order is correctness, not advice.

   </details>

3. **A new engineer wants to upgrade from v1.34 directly to v1.37 because "we're behind anyway." Talk them through why this is wrong and what the right path is.**
   <details><summary>Show answer</summary>

   kubeadm's upgrade page says skipping minor versions is unsupported. The path is v1.34 to v1.35 to v1.36 to v1.37, one step at a time. Skipping a minor carries deprecation and removal changes past several releases at once. For example, `flowcontrol.apiserver.k8s.io/v1beta3` stopped being served in v1.32, and a manifest that worked on v1.31 failed at that step. Run the deprecated-API audit at each step, and confirm the Bookstore reconciles after each one.

   </details>

4. **Hands-on extension: run the probe from step 3 on your cluster. What does the server dry run say for `policy/v1beta1`, and why does the same file pass under `policy/v1`?**
   <details><summary>What you should see</summary>

   The `policy/v1beta1` run is refused with `no matches for kind "PodDisruptionBudget" in version "policy/v1beta1"`, because that version is not served. The `policy/v1` run reports `created (server dry run)`, and creates nothing. The probe is the same check the pre-upgrade audit uses, and it is cheap enough to run before every upgrade. If your cluster is older than v1.25, the `policy/v1beta1` run may pass, and that is itself the finding.

   </details>

5. **A kubeadm cluster has been untouched for 14 months. The apiserver suddenly fails to start with `expired certificate`. What's the issue and the fix?**
   <details><summary>Show answer</summary>

   kubeadm control-plane client certificates default to **one-year validity**, and `kubeadm upgrade` renews them. A cluster left un-upgraded past that boundary has expired apiserver or kubelet certificates. The apiserver won't start, and kubelets go NotReady. Fix: renew the certificates (`kubeadm certs renew all`, then restart the static Pods and the kubelets), then run regular upgrades so renewal happens in a maintenance window. Check the dates with `kubeadm certs check-expiration` before they pass.

   </details>

6. **A CVE in kube-apiserver is fixed in a patch release of your minor. Your team patches the kubelets first, because the API server change feels riskier. Why is that the wrong order, and what is the right one?**
   <details><summary>Show answer</summary>

   Patching the kubelets first makes a kubelet newer than the apiserver it talks to, and the skew policy says a kubelet must not be newer than the kube-apiserver. The right order is the one a minor upgrade uses: the control plane takes the fix first, then each node is drained under its PodDisruptionBudget, patched, and uncordoned. The patch is safe to take because it is the same procedure, not a riskier one. Verify afterwards with `kubectl version` and `kubectl get nodes`.

   </details>

## Further reading

- **Rosso et al., _Production Kubernetes_, ch.2: Deployment Models** (how
  clusters are provisioned and operated: kubeadm vs managed vs Cluster API, the
  lifecycle and upgrade posture of a production cluster) and **ch.1: A Path to
  Production** (the operational maturity framing around versioning and upgrades).
- **Lukša, _Kubernetes in Action_ 2e, ch.3** (cluster components and how the
  control plane is composed, the structural basis for why the upgrade order is
  apiserver-first) and the material on securing and operating the API server.
- Official: the version-skew policy
  <https://kubernetes.io/releases/version-skew-policy/>, the release support
  policy <https://kubernetes.io/releases/>, the kubeadm upgrade task
  <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/>,
  the API deprecation policy
  <https://kubernetes.io/docs/reference/using-api/deprecation-policy/>, the
  deprecated API migration guide
  <https://kubernetes.io/docs/reference/using-api/deprecation-guide/>, the
  official CVE feed
  <https://kubernetes.io/docs/reference/issues-security/official-cve-feed/>, the
  signed-artifacts verification page
  <https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/>,
  and the kind v0.33.0 release notes with the node image digests
  <https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0>.
