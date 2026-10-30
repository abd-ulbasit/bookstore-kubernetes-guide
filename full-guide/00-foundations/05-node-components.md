# 05 — Node components

> Inside the hands: how the kubelet turns a PodSpec into running containers via
> the CRI and containerd, what the pause/sandbox container is for, what
> kube-proxy does, and the full sequence of a Pod starting on a node.

**Estimated time:** ~15 min read · (no hands-on)
**Prerequisites:** [Part 00 ch.03](03-architecture-overview.md) — control plane vs. node plane · [Part 00 ch.04](04-control-plane-deep-dive.md) — what the control plane decided
**You'll know after this:** • explain what the kubelet does step-by-step when a Pod is bound to a node · • describe the CRI boundary and how containerd executes containers · • understand the role of the pause/sandbox container and shared namespaces · • describe what kube-proxy programs (iptables / nftables / eBPF) · • name the kubelet API and the runtime socket as attack surfaces, and the control for each · • read the full sequence of a Pod starting on a node and locate failures within it

<!-- tags: foundations, node-plane, kubelet, cri, containerd, kube-proxy -->

## Why this exists

[Chapter 04](04-control-plane-deep-dive.md) showed the brain *deciding*. But a
decision ("run this Pod on Node N") is inert until something on Node N *makes
it real*. That something is the **node components** — and they are where the
beginner-visible failures live: `ContainerCreating` that never finishes,
`CrashLoopBackOff`, a probe killing a healthy app, "the Pod is Running but I
can't reach it". Every one of those is a node-component behavior. To debug Pods
([Part 08 ch.03](../08-day-2-operations/03-troubleshooting-playbook.md)) and to
understand health/lifecycle ([Part 01
ch.02](../01-core-workloads/02-health-and-lifecycle.md)) you must know what the
kubelet, CRI runtime, and kube-proxy actually do. This chapter completes the
breadth→depth arc of Part 00 on the *data-plane* side.

## Mental model

A worker node runs **one foreman and its specialist crews**. The **kubelet** is
the foreman: it watches the control plane for the work assigned to *this*
machine, and for each Pod it drives the crews to realize it and reports back
what's actually true. It does not lay bricks itself — it directs:

- the **container runtime** (containerd) to pull images and run containers,
- the **CNI plugin** to give the Pod a network identity,
- and reads from the **CSI** plugins for storage —

while **kube-proxy** runs alongside as a separate crew that programs the node's
networking so Service virtual IPs reach the right Pods. The foreman owns the
node's reality; the brain only ever *asked*.

## Threats and controls

The node components hold the most power in the cluster. The kubelet can run
any container on its node, and the container runtime can start a container
with any mount. Three threats follow. Each row names the control this chapter
teaches, and the body explains it.

| Threat | Control taught here | Deeper |
|---|---|---|
| A caller who reaches the kubelet API on port 10250 reads Pod specs and runs commands in containers | Anonymous auth off and Webhook authorization, so every caller is identified and checked. The Hands-on shows a refused anonymous request | Kubelet hardening in 05.06 <!-- link-later: 05.06 --> |
| A process that can write to the runtime socket starts a container with any mount, which is root on the node | The socket stays root-owned and out of Pods. The `restricted` level refuses the `hostPath` a Pod needs to reach it | [Pod security](../05-security/02-pod-security.md), and 05.02 |
| An unpatched runtime lets a container escape, as with runc CVE-2024-21626 | containerd and runc at releases that carry the fix, checked on every node | Node patching in 05.06 <!-- link-later: 05.06 --> |

## The node, in boxes

```
┌─────────────────────────── WORKER NODE (Linux host) ───────────────────────────┐
│                                                                                 │
│  kubelet  ── node agent: watches apiserver for Pods bound here;                 │
│     │        reconciles PodSpec → containers; runs probes; reports status       │
│     │ (CRI: gRPC)                                                               │
│     ▼                                                                           │
│  container runtime (containerd)  ── pulls images; runs/stops containers via runc│
│     │                                                                           │
│     ├── pause/sandbox container  ── holds the Pod's net+IPC namespaces (the     │
│     │                                "infra" container the app shares)          │
│     ├── app container(s)         ── your image(s), joined to the sandbox        │
│     └── (CNI plugin invoked)     ── gives the Pod its IP, wires veth → node     │
│                                                                                 │
│  kube-proxy  ── programs iptables/nftables (or eBPF via CNI) so Service VIPs    │
│                 load-balance to current healthy Pod IPs                         │
│                                                                                 │
│  cgroups + namespaces (Linux kernel)  ── the actual isolation & limits          │
│                                          (see ch.02)                            │
└─────────────────────────────────────────────────────────────────────────────────┘
        ▲ talks ONLY to the API server (never to etcd, never to the scheduler)
```

## kubelet — PodSpec → containers

The kubelet is the per-node agent and the *only* component that runs your
containers. Its loop:

1. **Watch** the API server for Pods whose `spec.nodeName` is *this* node
   (assigned by the scheduler in [ch.04](04-control-plane-deep-dive.md)).
2. **Admit** the Pod locally (node resources fit, required volumes/devices
   available; eviction thresholds not exceeded).
3. **Reconcile to spec**: ensure the Pod sandbox exists, the right images are
   pulled, each container in the PodSpec is running with the right config
   (env, mounts, resources → cgroups, security context). Restart containers
   per `restartPolicy` with exponential backoff (the backoff you see as
   `CrashLoopBackOff`).
4. **Mount volumes** (via CSI) before starting containers that need them.
5. **Run probes** continuously:
   - **startup** probe — gates the others until the app has booted (protects
     slow starters from being liveness-killed too early);
   - **readiness** probe — controls whether the Pod receives traffic (its IP is
     in/out of Service EndpointSlices);
   - **liveness** probe — if it fails, the kubelet **kills and restarts** the
     container.
   (Probe semantics and tuning: [Part 01
   ch.02](../01-core-workloads/02-health-and-lifecycle.md).)
6. **Report status** back to the API server continuously: container states,
   Pod phase, conditions (Ready), and the node's own heartbeat (Node `Lease`)
   so the Node controller knows this node is alive.

Two internals worth naming:

- **PLEG (Pod Lifecycle Event Generator).** The kubelet doesn't busy-poll every
  container. PLEG periodically relists containers from the runtime, diffs
  against its cache, and emits lifecycle events that drive reconciliation. A
  slow/overloaded runtime shows up as "**PLEG is not healthy**" in node events —
  a classic node-pressure symptom.
- **The kubelet reconciles, like everything else.** It is level-triggered: it
  drives actual container state toward the PodSpec, re-asserting on every sync —
  the same loop as the controllers, just realized in Linux instead of in etcd.

### The kubelet API on port 10250

The kubelet serves its own HTTPS API on port 10250. People do not call it
directly. The API server calls it for `kubectl logs` and `kubectl exec`, and
its `/pods` endpoint lists the Pod specs bound to the node. A caller that
reaches the port and gets past its authentication can read those specs and
run commands in any container on the node. The port therefore has to refuse
every caller it cannot identify.

The kubelet's command-line flags default to the open choice: anonymous
requests are allowed, and authenticated requests are allowed without a check
([kubelet authentication and authorization](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/)).
The kubelet configuration file defaults to the closed choice: anonymous
authentication is off, and authorization is `Webhook`, which asks the API
server with a SubjectAccessReview whether each request may proceed. The
read-only port, 10255, defaults to `0`, which disables it
([KubeletConfiguration reference](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)).
Read each node's configuration rather than assume the closed choice. The
Hands-on does.

RBAC also reaches this API, through the API server, and that grant is easy to
over-give. `nodes/proxy` gives access to every kubelet endpoint. The upstream
page warns that `get` on it is not a read-only permission, because the
websocket endpoints that run commands in containers authorize under `get`.
Treat `nodes/proxy` as a permission to run commands on the node. RBAC is in
[05.01](../05-security/01-authn-authz-rbac.md).

## CRI and containerd

The kubelet does **not** know how to talk to containerd (or CRI-O, or any
specific runtime) natively. It speaks the **CRI (Container Runtime Interface)**
— a stable gRPC API with two services:

- **RuntimeService** — sandboxes and containers: `RunPodSandbox`,
  `CreateContainer`, `StartContainer`, `StopContainer`, `ExecSync`, status…
- **ImageService** — images: `PullImage`, `ImageStatus`, `RemoveImage`…

This indirection is why Kubernetes is runtime-agnostic and why the Docker
shim was removed in v1.24: any runtime implementing CRI works. The common
stack today:

```
kubelet ──CRI(gRPC)──► containerd ──► containerd CRI plugin ──► runc ──► clone()/namespaces/cgroups
                                  └──► snapshotter (overlayfs)  ──► image layers (see ch.02)
```

containerd manages images (pull, unpack layers via a snapshotter into an
overlay rootfs — exactly the layer model of
[ch.02](02-containers-and-images.md)) and lifecycle, then delegates the actual
OS-level container creation to a low-level runtime, **runc**, which performs the
`clone()`/namespace/cgroup syscalls. (`gVisor`/`runsc` or Kata can substitute
for `runc` when stronger isolation is required —
[Pod security](../05-security/02-pod-security.md).)

### The runtime socket is a root handle

The kubelet reaches containerd through the socket
`/run/containerd/containerd.sock`. Root owns it, and only root and its group
can open it. Whoever can write to it can ask containerd to start a container
with any mount, including the host's root filesystem. A process that does this
as root, or as group 0, is root on the node. The kubelet is trusted with the
socket. A Pod must never be handed it.

The control that matters is admission. The Baseline and Restricted levels both
forbid `hostPath`. Baseline lists it as forbidden. Restricted allows only the
volume types `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`,
`persistentVolumeClaim`, `projected` and `secret`
([Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)).
A Pod that asks for the socket is refused in a namespace labelled `restricted`,
and [01.01](../01-core-workloads/01-pods.md#baseline-namespace) sets that label
on the reader's namespaces. Container escape is covered in
[05.02](../05-security/02-pod-security.md).

### Keep the runtime patched

runc creates each container's namespaces and cgroups, so a flaw in runc is an
escape route. CVE-2024-21626 is one. A leaked internal file descriptor in runc
from v1.0.0-rc93 through 1.1.11 could leave a container process with its
working directory in the host's mount namespace, which gives the process the
host's filesystem. runc 1.1.12 has the fix
([advisory](https://github.com/opencontainers/runc/security/advisories/GHSA-xr7r-f8xq-vfvv)).
Even on managed clusters, the runtime on the worker nodes is yours to patch.
Runtime CVEs are a real escape vector, so see also the
[supply chain](../05-security/03-supply-chain.md) chapter. Node patching and
upgrades are in 05.06 <!-- link-later: 05.06 -->. The Hands-on checks the runc
version on this node.

### A stronger boundary: sandboxed runtimes

Containers share the host kernel, so a kernel flaw is reachable from every
container on the node. For Pods that run code you do not trust, select a
sandboxed runtime such as gVisor (`runsc`) or Kata Containers with a
RuntimeClass. The CRI seam makes that a per-Pod choice. The kernel controls
are in 05.05 <!-- link-later: 05.05 -->.

## The pause (sandbox) container

A Pod is a *group of containers sharing one network and IPC namespace and a
common lifecycle*. Linux has no native "pod" — Kubernetes builds it with an
extra, invisible container per Pod: the **pause** (a.k.a. **sandbox** or
"infra") container.

- It is the **first** container created for a Pod. It does essentially nothing:
  it runs a tiny program that just sleeps and reaps zombies.
- Its purpose is to **own the Pod's shared namespaces** (network, IPC; the Pod
  gets one IP — the pause container's). App containers are then created to
  **join** the pause container's namespaces rather than create their own.
- Because the namespaces belong to the long-lived pause container, an app
  container can **crash and be restarted without the Pod losing its IP or
  network setup** — the sandbox persists across container restarts. This is
  precisely why a `CrashLoopBackOff` Pod keeps the same IP, and why CNI is
  invoked once per Pod (at sandbox creation), not once per container.

The namespaces the pause container holds are the Pod's trust boundary. Every
container in the Pod shares its network and IPC namespaces, sidecars included.
[01.01](../01-core-workloads/01-pods.md#baseline) explains what that sharing
means for each baseline field, and this chapter does not repeat it.

You'll see it as a `pause`/`sandbox` entry in `crictl pods` even though it never
appears in your manifest — it's infrastructure the kubelet manages for you.

## kube-proxy — making Service IPs work

Pods are mortal and their IPs change; a **Service** is a stable virtual IP (and
DNS name) in front of a changing set of Pod IPs ([Part 02
ch.02](../02-networking/02-services.md)). **kube-proxy** is the per-node
component that makes that virtual IP actually route:

- It watches the API server for **Services** and their **EndpointSlices** (the
  current set of *ready* backing Pod IPs, kept fresh by the EndpointSlice
  controller from [ch.04](04-control-plane-deep-dive.md)).
- It programs the node's packet path so traffic to a Service's ClusterIP:port
  is DNAT-load-balanced across those ready Pod IPs, via **iptables** (the
  default in 1.37), **nftables** (the mode upstream names as the future
  default), or **IPVS**, which is deprecated since v1.35 and scheduled for
  removal in v1.43, or it's *replaced
  entirely* by a CNI's own dataplane (e.g. Cilium's eBPF kube-proxy
  replacement).

kube-proxy does **not** sit in the data path as a proxy process for normal
ClusterIP traffic — it *configures the kernel* to do the forwarding. (DNS-based
discovery itself is **CoreDNS**, a separate add-on Pod; kube-proxy handles the
virtual-IP plumbing.) Full model in [Part 02](../02-networking/02-services.md).

## Sequence: a Pod starting on a node

This stitches the node components together — it is what happens *after* the
scheduler binds your Pod (the tail end of the
[ch.03 lifecycle](03-architecture-overview.md#lifecycle-from-kubectl-apply-to-a-running-pod)),
and exactly what your `catalog` Pod does in
[ch.07](07-local-cluster-setup.md):

```mermaid
sequenceDiagram
    autonumber
    participant API as kube-apiserver
    participant KUB as kubelet (Node N)
    participant CRI as containerd (CRI)
    participant CNI as CNI plugin
    participant CSI as CSI driver

    API-->>KUB: watch: Pod bound to Node N (spec.nodeName=N)
    KUB->>KUB: admit Pod (resources/devices/eviction OK)
    KUB->>CSI: attach & mount required volumes
    CSI-->>KUB: volumes mounted on the node
    KUB->>CRI: RunPodSandbox  (create the pause/infra container)
    CRI->>CRI: start pause container → creates net+IPC namespaces
    CRI->>CNI: ADD: set up Pod network
    CNI-->>CRI: veth created, Pod IP assigned, routes programmed
    KUB->>CRI: PullImage (per imagePullPolicy, layers cached — ch.02)
    CRI-->>KUB: image present
    KUB->>CRI: CreateContainer + StartContainer (init, then app containers)
    CRI->>CRI: runc: clone() namespaces (join sandbox) + cgroups (limits)
    CRI-->>KUB: container(s) running
    KUB->>KUB: run startup→readiness→liveness probes
    KUB->>API: update Pod status (ContainerCreating→Running — Ready when readiness passes)
    Note over API: EndpointSlice controller adds the ready Pod IP →<br/>kube-proxy programs routing → traffic reaches the Pod
```

Read it as: **sandbox first (gets the IP), network second (CNI), images,
then containers join the sandbox, then probes gate readiness, then status is
reported and routing is wired.** Almost every "stuck Pod" maps to a specific
arrow here — image pull failing, CNI not assigning an IP, a volume not
mounting, readiness never passing.

## Hands-on with the Bookstore

No new manifest (the first is [ch.06](06-declarative-api-model.md)). But once
you have the `catalog` Pod running on kind in
[ch.07](07-local-cluster-setup.md), these commands *show the node components at
work* on it:

```sh
# Which node did the scheduler put it on? (the kubelet there now owns it)
kubectl get pod catalog -o wide

# The kubelet's view, narrated: sandbox create, image pull, container start, probes
kubectl describe pod catalog            # see the Events section, bottom

# kind nodes ARE containers; exec onto the node to see the runtime directly
docker exec -it bookstore-control-plane bash      # kind node container
crictl pods                              # note the catalog Pod AND its pause sandbox
crictl ps                                # the running app container(s)
crictl images                            # layers containerd pulled (ch.02)

# The node's own health/heartbeat the Node controller relies on
kubectl get node -o wide
kubectl -n kube-system get lease | grep -i node   # node heartbeat lease

# kube-proxy + the routing it programs for a Service (once you add one later)
kubectl -n kube-system get pods -l k8s-app=kube-proxy
kubectl get endpointslices                # the ready Pod IPs kube-proxy targets
```

Mapping back: the `catalog` image is small and static *by design*
([ch.02](02-containers-and-images.md)) so the **PullImage** step is fast; its
exec-form `ENTRYPOINT` means the kubelet's `SIGTERM` on Pod deletion reaches
the Go process and triggers graceful shutdown; its `/healthz` and `/readyz`
endpoints are exactly what the kubelet's **liveness/readiness** probes will
call once you add them in [Part 01](../01-core-workloads/02-health-and-lifecycle.md).

The rest of the Hands-on reads the node's security settings. Every check below
is read-only.

### Refused: an anonymous request to the kubelet

**Deliberate action.** This request should fail. It asks the kubelet for its
Pod list with no credentials, which is what a caller sends after finding port
10250 open. `-k` skips checking the kubelet's serving certificate. That is
harmless here, because the answer is a refusal. Never use `-k` in a script
that sends credentials.

```sh
docker exec bookstore-control-plane \
  curl -sk -w '\n%{http_code}\n' https://127.0.0.1:10250/pods
```

<!-- gate: output -->
```
Unauthorized
401
```

The kubelet refused the caller before it read anything. Its configuration on
the node shows why:

```sh
docker exec bookstore-control-plane sed -n '1,12p' /var/lib/kubelet/config.yaml
```

<!-- gate: output -->
```
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
  webhook:
```

`anonymous: enabled: false` refuses a caller that presents no credentials, and
`mode: Webhook` sends each authenticated caller to the API server for a
SubjectAccessReview. Check the same two settings on every node you run.

### The read-only port is closed

The read-only port, 10255, served Pod data without authentication when it was
enabled. Its default is `0`, which disables it. A `000` status means curl made
no connection, so nothing listens there:

```sh
docker exec bookstore-control-plane curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:10255/pods
```

<!-- gate: output -->
```
000
```

### The runtime socket and the versions behind it

The socket is the runtime's control channel. Only its owner, root, and root's
group can open it:

```sh
docker exec bookstore-control-plane ls -l /run/containerd/containerd.sock
```

<!-- gate: output -->
```
srw-rw---- 1 root root 0 Oct 30 14:28 /run/containerd/containerd.sock
```

A Pod in a namespace labelled `restricted` cannot mount this path, because the
level refuses `hostPath`. Next, the versions the node runs:

```sh
kubectl get node -o custom-columns=RUNTIME:.status.nodeInfo.containerRuntimeVersion,KUBELET:.status.nodeInfo.kubeletVersion
```

<!-- gate: output -->
```
RUNTIME              KUBELET
containerd://2.3.4   v1.37.0
```

```sh
docker exec bookstore-control-plane runc --version | head -n 1
```

<!-- gate: output -->
```
runc version 1.4.3
```

runc 1.4.3 is later than 1.1.12, the first release with the fix for
CVE-2024-21626, so this node includes that fix. Check each runtime component
against its own advisories, not only this one.

### Which sandbox a container belongs to

`crictl pods` and `crictl ps` show the pause sandbox and the containers that
belong to it. Each container's POD ID matches its sandbox's ID. The output
below is from kube-proxy, not the catalog app, and it claims only that match:

```sh
docker exec bookstore-control-plane crictl pods --name kube-proxy
docker exec bookstore-control-plane crictl ps --name kube-proxy
```

<!-- gate: output -->
```
POD ID              CREATED             STATE               NAME                NAMESPACE           ATTEMPT             RUNTIME
a47e149f809eb       8 hours ago         Ready               kube-proxy-pb9p9    kube-system         0                   (default)
```

<!-- gate: output -->
```
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID              POD                 NAMESPACE
b660e38fe6302       d6a28daf3e6b0       8 hours ago         Running             kube-proxy          0                   a47e149f809eb       kube-proxy-pb9p9    kube-system
```

The two outputs show the same POD ID, `a47e149f809eb`. They do not show which
namespaces the container uses. kube-proxy runs with host networking, so its
network namespace is the node's own, not the sandbox's. Sharing namespaces is
the pause container's job, described above, but this output does not show it.

## How it works under the hood

- **The kubelet is authoritative for the node, not the control plane.** The
  control plane records *intent*; the kubelet decides *how* to realize it on
  this specific kernel and reports back *fact*. The control plane never touches
  containers — it only ever reads/writes objects.
- **One sandbox per Pod, joined by all its containers.** This is the literal
  implementation of "containers in a Pod share a network namespace and
  localhost" — they share the pause container's namespaces. CNI runs **once
  per Pod** (at sandbox creation), which is why all containers in a Pod have
  the *same* IP and can reach each other on `localhost`.
- **CRI/CNI/CSI are deliberate seams.** Runtime (CRI), networking (CNI), and
  storage (CSI) are pluggable interfaces, not hardcoded — this is why the same
  PodSpec runs on kind, on EKS, or on bare metal with totally different
  plugins underneath. Portability is an architectural property of these seams.
- **kube-proxy programs the kernel; it is not a per-packet proxy** for
  ClusterIP traffic. The forwarding/NAT is done by iptables/nftables/eBPF in
  the data path; kube-proxy just keeps those rules in sync with
  EndpointSlices.

## Production notes

> **In production:** size and protect the kubelet's node. The kubelet enforces
> **eviction thresholds** (memory/disk/PID pressure) and will evict Pods to
> save the node — set sane resource **requests/limits** so the right Pods are
> protected ([resources & QoS](../01-core-workloads/03-resources-and-qos.md)).
> "Node NotReady" / "PLEG is not healthy" almost always means disk or memory
> pressure or a sick runtime.

> **In production:** choose the kube-proxy mode (or replacement) deliberately.
> The default in 1.37 is **iptables**, and upstream says a future version will
> change the default to **nftables**. Upstream advises an explicit mode, so an
> upgrade does not change the backend without warning. **IPVS** is deprecated
> since v1.35 and scheduled for removal in v1.43, so do not pick it for a new
> cluster. An **eBPF** dataplane (Cilium) can replace kube-proxy for
> performance and richer policy. This is a cluster-build decision
> ([Part 02 ch.01](../02-networking/01-networking-model.md)).

> **In production:** the **pause container image** must be reachable (it has
> its own registry source, often the cluster's configured sandbox image). In
> air-gapped/private environments, failing to mirror the pause image breaks
> *every* Pod with `RunPodSandbox` errors — a classic, baffling-until-you-know
> outage.

## Quick Reference

```sh
kubectl get pod <P> -o wide              # which node (→ which kubelet owns it)
kubectl describe pod <P>                  # kubelet Events: sandbox/pull/start/probe
kubectl get node -o wide                  # node status, runtime version, addresses
kubectl describe node <N>                 # capacity/allocatable, conditions, evictions
kubectl -n kube-system get pods -l k8s-app=kube-proxy   # kube-proxy DaemonSet
kubectl get endpointslices                # ready Pod IPs kube-proxy routes to
kubectl logs <P> --previous               # previous container (debug CrashLoopBackOff)
kubectl get node -o custom-columns=RUNTIME:.status.nodeInfo.containerRuntimeVersion   # runtime version per node

# On the node itself (e.g. `docker exec` into a kind node container):
crictl pods                               # Pods incl. the pause/sandbox container
crictl ps                                 # running containers (CRI view)
crictl images                             # images/layers containerd holds
journalctl -u kubelet                     # kubelet logs (systemd-managed nodes)
sed -n '1,12p' /var/lib/kubelet/config.yaml   # kubelet authn/authz: anonymous off, Webhook
runc --version | head -n 1                    # runc release, checked against its advisories
```

The node, minimally:

```
kubelet (watches apiserver → reconciles PodSpec, runs probes, reports status)
  └─CRI→ containerd → runc      : pause sandbox first, then app containers join it
        └─CNI: Pod gets its IP (once per Pod, at sandbox creation)
        └─CSI: volumes mounted before dependent containers start
kube-proxy (watches Services/EndpointSlices → programs iptables/nftables/eBPF)
```

Node checklist:

- [ ] Resource requests/limits set so kubelet eviction protects the right Pods
- [ ] Node OS + containerd patched (worker nodes are yours, even on managed)
- [ ] kube-proxy mode / CNI dataplane chosen for the cluster's scale
- [ ] Pause/sandbox image mirrored for air-gapped/private registries
- [ ] Probes defined (startup/readiness/liveness) so the kubelet gates correctly
- [ ] Sensitive workloads on a sandboxed RuntimeClass where required
- [ ] Kubelet anonymous auth off, `mode: Webhook`, and `readOnlyPort: 0`
- [ ] No Pod mounts the runtime socket, and `restricted` refuses `hostPath`
- [ ] runc and containerd at releases that carry their advisories' fixes
- [ ] `nodes/proxy` granted only where command execution on nodes is needed

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **Why does every Pod include a `pause`/`sandbox` container you never declared, and what would break if the kubelet skipped creating it?**
   <details><summary>Show answer</summary>

   The pause container owns the Pod's shared network and IPC namespaces — it gets the Pod IP and holds the namespaces so app containers can crash and restart without losing the IP or re-running CNI. Skipping it means each container would create its own network namespace, and the "Pod = group sharing localhost and one IP" abstraction would not exist (see §The pause container).

   </details>

2. **A node reports `PLEG is not healthy` and Pod statuses lag by minutes. What's PLEG, what's most likely wrong, and what's the first thing to check?**
   <details><summary>Show answer</summary>

   PLEG (Pod Lifecycle Event Generator) is the kubelet loop that relists containers from the runtime and emits lifecycle events. A slow or overloaded runtime — often caused by disk pressure, memory pressure, or a sick containerd — shows up as "PLEG is not healthy". First check: node disk and memory pressure (`kubectl describe node`), then containerd health (`journalctl -u containerd`, `crictl pods` latency) (see §kubelet — PodSpec → containers, PLEG callout).

   </details>

3. **You add a Service that selects `app=catalog` but traffic to its ClusterIP returns connection refused. The Pod itself is `Running 1/1`. Which node component is responsible for making the ClusterIP route, and what does it watch to know about new endpoints?**
   <details><summary>Show answer</summary>

   kube-proxy on each node programs iptables/nftables/eBPF rules from the EndpointSlices that the EndpointSlice controller maintains for each Service. If the Pod isn't yet in an EndpointSlice for the Service, kube-proxy has nothing to route to. Check `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` — if empty, the Service selector likely doesn't match the Pod's labels (see §kube-proxy — making Service IPs work).

   </details>

4. **A Pod is stuck `ContainerCreating` for several minutes with no obvious image-pull failure. Using only the node-side sequence diagram in this chapter, list three concrete arrows where it could be stuck and the symptom each produces.**
   <details><summary>Show answer</summary>

   (a) `CSI: attach & mount` — volume not attaching shows `FailedAttachVolume` / `FailedMount` events. (b) `CNI: ADD` — CNI couldn't assign an IP, events mention "failed to set up sandbox container" or "failed to allocate IP". (c) `PullImage` — registry reachability/auth, surfaces as `ErrImagePull` / `ImagePullBackOff`. `kubectl describe pod` events name the failing step (see §Sequence: a Pod starting on a node).

   </details>

5. **Hands-on extension: with a kind cluster running, `docker exec` into the node container and run `crictl pods` then `crictl ps`. Count the entries. Why are there more pods than running containers?**
   <details><summary>What you should see</summary>

   `crictl pods` lists every Pod sandbox (including the pause container per Pod); `crictl ps` lists only running app containers. Each app Pod contributes one sandbox + N app containers, so `pods` ≥ unique Pod count and `ps` ≥ sum of app containers per Pod. The discrepancy is exactly the invisible pause container per Pod (see §The pause container, §Hands-on with the Bookstore).

   </details>

6. **A teammate wants a monitoring agent to list the containers on its node by mounting `/run/containerd/containerd.sock` into its Pod. Name the threat, the control that refuses the mount, and what you would give the agent instead.**
   <details><summary>Show answer</summary>

   The socket is the runtime's control channel. A process that can write to it, as root or group 0, can start a privileged container with the host filesystem mounted, which is root on the node. The `restricted` Pod Security level refuses the `hostPath` volume the mount needs, because `hostPath` is not on its allowed volume list. Give the agent a ServiceAccount with a narrow RBAC role that reads the Pod and container status it needs from the API server, as [05.01](../05-security/01-authn-authz-rbac.md) teaches (see §The runtime socket is a root handle).

   </details>

## Further reading

- **Lukša, _Kubernetes in Action_ 2e, ch.2 & ch.3** — containers and the node
  agent: how the kubelet realizes Pods and the runtime/namespace mechanics.
- **Rosso et al., _Production Kubernetes_, ch.3 — "Container Runtime"** — CRI,
  containerd, and runtime concerns from an operator's perspective.
- Official:
  <https://kubernetes.io/docs/concepts/architecture/#node-components>
  (node components),
  <https://kubernetes.io/docs/concepts/architecture/cri/> (CRI), and
  <https://kubernetes.io/docs/reference/networking/virtual-ips/> (kube-proxy /
  Service virtual IPs).
- Kubernetes, [Kubelet authentication and authorization](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/).
- Kubernetes, [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/), for the `hostPath` rule and the Restricted volume list.
- runc, [GHSA-xr7r-f8xq-vfvv](https://github.com/opencontainers/runc/security/advisories/GHSA-xr7r-f8xq-vfvv), for CVE-2024-21626.
