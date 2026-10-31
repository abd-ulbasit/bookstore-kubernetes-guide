# 02: Pod security and container escape

> What a compromised container can do to the node, shown on a kind cluster: a
> `privileged` Pod, a `hostPID` Pod, a `hostPath` mount of the node's root, a
> mounted runtime socket, and a write into a neighbour's root filesystem. Then
> what closes each one: the
> [baseline](../01-core-workloads/01-pods.md#baseline) on the Pod, and
> **Pod Security Admission** (PSA) on the namespace, at the `restricted` level.
> The lab also tries a user namespace Pod, which did not start on this cluster,
> and the chapter says so.

**Estimated time:** ~40 min read · ~60 min lab (scripted)
**Prerequisites:** [Part 05 ch.01](01-authn-authz-rbac.md): RBAC controls who
can ask the API; this chapter controls what a running Pod can do to the
kernel · [Part 01 ch.01](../01-core-workloads/01-pods.md#baseline): the
baseline, field by field ·
[Part 00 ch.02](../00-foundations/02-containers-and-images.md): capabilities,
namespaces and cgroups

**You'll know after this:**

- show what a Pod reaches on the node through each escape, and name the field
  that closes it
- tell the `baseline` and `restricted` standards apart, field by field
- label a namespace `enforce`, `audit` and `warn` at a standard and a version
- keep a workload that needs privilege in its own namespace, with a recorded
  exception
- explain why PodSecurityPolicy is gone and what replaced it

<!-- tags: security, psa-restricted, container-escape, core-objects, day-2 -->

## Why this exists

[ch.01](01-authn-authz-rbac.md) decided who can ask the API server for what.
This chapter starts after a Pod is running and asks what the process inside a
container can do to the node. A container is a process with namespaces and
cgroups, sharing the node's kernel. Unless the spec says otherwise, it runs as
root, can gain privileges, holds a default set of Linux capabilities, can make
any system call the kernel allows, and writes to its root filesystem. RBAC does
not touch any of that. A catalog process compromised through an application
bug starts with all of it, and a `hostPath`, `hostPID` or `privileged` field in
its spec hands it the node.

Two controls answer this. `securityContext` is how a workload drops those
privileges, and the baseline sets them. Pod Security Admission is the admission
check that refuses a Pod that has not dropped them. 01.01 explains each field
against the threat it answers, so this chapter does not repeat those
explanations. It shows the threats landing, and then the controls stopping
them.

## Mental model

Two halves work together:

- **`securityContext` is the privilege a Pod gives up.** Pod-level fields
  (`runAsNonRoot`, `runAsUser`, `seccompProfile`) and container-level fields
  (`allowPrivilegeEscalation`, `capabilities`, `readOnlyRootFilesystem`,
  `privileged`) sit side by side. A container-level field overrides the
  pod-level one for the same setting.
- **PSA is the floor the namespace enforces.** You label a namespace with one
  of three standards (`privileged`, `baseline` or `restricted`) and one of
  three modes (`enforce`, `audit` or `warn`). You write no rules. Each standard
  is a fixed, versioned list.

The two standards are different lists, not one list with a few extra fields.
`baseline` forbids the known escalations and nothing more. `restricted` forbids
the same escalations and also requires the hardened fields. The table shows
which is which:

| Rule | `baseline` | `restricted` |
|---|---|---|
| `privileged: true` | refused | refused |
| `hostPID`, `hostIPC`, `hostNetwork` | refused | refused |
| `hostPath` volumes | refused | refused; only the listed volume types are allowed |
| capabilities added beyond the runtime's default set | refused | refused; only `NET_BIND_SERVICE` may be added, and `drop: ["ALL"]` is required |
| `seccompProfile` set to `Unconfined` | refused | refused; `RuntimeDefault` or `Localhost` is required |
| `runAsNonRoot: true` | not required | required |
| `allowPrivilegeEscalation: false` | not required | required |
| `readOnlyRootFilesystem: true` | not required | not required |

Neither standard requires `readOnlyRootFilesystem`. The guide's baseline sets
it anyway, but a Pod that meets `restricted` can still write to its root
filesystem, and the lab shows that case below.

The two halves must agree. A namespace that enforces `restricted` admits only
Pods that meet it. A namespace with no Pod Security labels admits every Pod,
including the ones this chapter attacks. The lab uses both kinds of namespace.

## Threats and controls

Every threat here is a way a running container reaches the node, or another
container on it. The lab lands each one on a kind cluster, then closes it. For
the two rows about privilege escalation and syscalls it reads the control and
does not exploit anything: it prints `NoNewPrivs` and `Seccomp` on the hardened
Pod, as [01.01](../01-core-workloads/01-pods.md#debug-containers) does.

| Threat | Control this chapter teaches | Where it goes deeper |
|---|---|---|
| Root in the container is UID 0 on the node, and reads files the node's root owns | `runAsNonRoot` with a non-zero `runAsUser`; `hostPath` refused | [user namespaces](https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/); [05.05](05-kernel-isolation.md) |
| A privileged container holds every capability | no `privileged`; `capabilities.drop: ["ALL"]` | [capabilities(7)](https://man7.org/linux/man-pages/man7/capabilities.7.html) |
| `hostPID` shows and signals the node's processes, and with privilege it enters them | no host namespaces | [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline) |
| A `hostPath` mount reads the node's files, including a root-only key | no `hostPath` | [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted); [05.07](07-admission-control-and-policy-as-code.md) for rules beyond the standards |
| A mounted runtime socket starts, stops and inspects every container on the node | no socket mount, which `restricted` refuses as `hostPath` | [05.07](07-admission-control-and-policy-as-code.md) |
| A neighbour Pod with host access writes into another Pod's root filesystem through `/proc` | no privileged Pod with `hostPID` in any namespace; RBAC over who can create Pods | [ch.01](01-authn-authz-rbac.md) |
| An attacker writes a binary into a running container | `readOnlyRootFilesystem: true` for system paths, `emptyDir` for writes | `/tmp` stays writable and executable, so this field does not end the threat; see the hardened victim section |
| A setuid binary or file capability gains privilege | `allowPrivilegeEscalation: false`, read as `NoNewPrivs` | [no_new_privs](https://docs.kernel.org/userspace-api/no_new_privs.html) |
| A rare syscall reaches the kernel | `seccompProfile: RuntimeDefault`, read as `Seccomp` | [05.05](05-kernel-isolation.md) |
| A Pod with none of the above is admitted at all | Pod Security labels on the namespace | [PSA](https://kubernetes.io/docs/concepts/security/pod-security-admission/) |

## Lab: attack, harden, re-attack

### Lab header

- **Tier A.** A kind cluster on a Linux host. The node runs Kubernetes v1.37.0
  with containerd 2.3.4 and runc 1.4.3, on Debian 13 with kernel 7.0.0.
  `kubectl` is v1.37.2. This lab has not been run on macOS.
- **Script and transcript.**
  [`labs/05-02.sh`](../examples/security-lab/labs/05-02.sh) runs every command
  below and deletes the namespaces it creates. Its recorded output is
  [`evidence/05-02.txt`](../examples/security-lab/evidence/05-02.txt). Run it
  only against a kind cluster you own. The script refuses any kubectl context
  that is not `kind-*`.
- **Namespaces.** Five, all named `p05-02-*`. `p05-02-attack` enforces
  `privileged`, because the attacks need it. It holds marked, insecure Pods
  only, and the script deletes it at the end. `p05-02-baseline` enforces
  `baseline` and warns on `restricted`. `p05-02-restricted` enforces, audits
  and warns on `restricted`. `p05-02-bookstore` carries the same three labels
  at `restricted`, for the Bookstore check. `p05-02-unlabelled` has no Pod
  Security labels, as a control.
- **What did not work the first time.** A new namespace has no `default`
  ServiceAccount for a moment, and the API server refuses Pods in it until the
  controller creates one. The first run failed that way, so the script now
  waits for each namespace's ServiceAccount before it creates a Pod. Earlier
  runs also timed out on rabbitmq. Its broker raised a memory alarm during boot
  under the 512Mi limit the manifest first had, and port 5672 stayed closed past
  the rollout wait. The manifest now sets a 1Gi limit and a startup probe, and
  the final run reached Ready ([the Bookstore](#the-bookstore-under-restricted),
  below). The user namespace Pod never started
  ([User namespaces](#user-namespaces), below).
- **Audit is labelled, not shown.** `p05-02-restricted` carries an `audit`
  label, but the lab captures no audit output. The API server's command line
  has no audit flag, so no audit policy is set on this cluster, and the
  script's first check counts that as `0`.
- **Cluster-scoped objects.** The script applies the Bookstore's
  PriorityClasses, which the postgres StatefulSet needs. On a cluster that
  already has them, that apply can reconfigure them to match the file. The
  script leaves them in place, because another lab or the reader may use them.
  Delete them with `kubectl delete priorityclass` when you no longer need them.
- **Cluster name.** The captured output is from a lab cluster named `sf-pilot`,
  so its node is `sf-pilot-control-plane`. A kind cluster you create has its own
  name, and the node name in your output will differ.

The versions come first, so that each claim in this header has a captured
source:

```sh
kubectl version
kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,OS:.status.nodeInfo.osImage
```

<!-- gate: output -->

```
Client Version: v1.37.2
Kustomize Version: v5.8.1
Server Version: v1.37.0
# ...
NAME                     KUBELET   KERNEL             RUNTIME              OS
sf-pilot-control-plane   v1.37.0   7.0.0-38-generic   containerd://2.3.4   Debian GNU/Linux 13 (trixie)
```

Save each manifest below as `<name>.yaml` in one working directory, and run the
commands from there. The lab creates the five namespaces first:

```sh
kubectl create namespace p05-02-attack
kubectl label namespace p05-02-attack pod-security.kubernetes.io/enforce=privileged
kubectl create namespace p05-02-baseline
kubectl label namespace p05-02-baseline pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=latest pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/warn-version=latest
kubectl create namespace p05-02-restricted
kubectl label namespace p05-02-restricted pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/audit-version=latest pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/warn-version=latest
kubectl create namespace p05-02-bookstore
kubectl label namespace p05-02-bookstore pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/audit-version=latest pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/warn-version=latest
kubectl create namespace p05-02-unlabelled
```

The attacks run from the smallest field to the largest, so that each Pod shows
what a single field allows.

### Privileged, without a host namespace

First, a default Pod, as a control. It sets no `securityContext`, so it runs as
root with the runtime's defaults. It is in the attack namespace, which admits
it.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a default Pod, root with a writable root filesystem and no securityContext. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: victim
  namespace: p05-02-attack
spec:
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "1800"]
```

Next, the same runtime with `privileged: true`. It has no `hostPID`, so it
should see only its own processes.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a privileged container with no host namespace. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-privileged
  namespace: p05-02-attack
spec:
  containers:
    - name: esc
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
```

```sh
kubectl apply -f escape-privileged.yaml
kubectl wait --for=condition=Ready pod/escape-privileged -n p05-02-attack --timeout=120s
kubectl exec -n p05-02-attack escape-privileged -- awk '/^Cap(Eff|Bnd)/ {print $1, $2}' /proc/self/status
kubectl exec -n p05-02-attack escape-privileged -- sh -c 'ps -o pid,args | head -5'
kubectl exec -n p05-02-attack escape-privileged -- sh -c 'echo devices in privileged: $(ls /dev | wc -l)'
kubectl exec -n p05-02-attack victim -- sh -c 'echo devices in default: $(ls /dev | wc -l)'
```

<!-- gate: output -->

```
pod/escape-privileged created
# ...
pod/escape-privileged condition met
# ...
CapEff: 000001ffffffffff
CapBnd: 000001ffffffffff
# ...
PID   COMMAND
    1 sleep 3600
   20 sh -c ps -o pid,args | head -5
   27 ps -o pid,args
   28 head -5
# ...
devices in privileged: 229
# ...
devices in default: 16
```

Bits 0 to 40 are set in both sets, so the Pod holds the full capability set,
bounding set included. The set includes `CAP_SYS_ADMIN`, which mounts
filesystems, and `CAP_SYS_MODULE`, which loads kernel modules
([capabilities(7)](https://man7.org/linux/man-pages/man7/capabilities.7.html)).
The privileged Pod sees 229 device entries against the default Pod's 16: it
sees the kind node's device nodes. The lab mounts none of them. On a kind node
those devices belong to the machine that runs kind, and this lab does not touch
that machine.

`ps` shows only the Pod's own process table. Without `hostPID`, `sleep` is PID 1
and the victim is invisible to it. Privilege alone does not reach the node's
processes. The next attack adds that.

### hostPID, without privilege

`hostPID: true` puts the Pod in the node container's process table, and nothing
more:

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: hostPID shares the node's process table with the Pod, and the container keeps the runtime's default capabilities. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-hostpid
  namespace: p05-02-attack
spec:
  hostPID: true
  containers:
    - name: esc
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "3600"]
```

```sh
kubectl apply -f escape-hostpid.yaml
kubectl wait --for=condition=Ready pod/escape-hostpid -n p05-02-attack --timeout=120s
kubectl exec -n p05-02-attack escape-hostpid -- sh -c 'ps -o pid,comm' | grep -E '^ *[0-9]+ (kubelet|containerd)$' | sed 's/^ *//'
kubectl exec -n p05-02-attack escape-hostpid -- sh -c '
K=$(pidof kubelet)
kill -0 "$K" && echo "kill -0 kubelet: allowed"
tr "\0" " " < "/proc/$K/cmdline" | cut -c1-40'
kubectl exec -n p05-02-attack escape-hostpid -- nsenter -t 1 -m -- cat /etc/hostname
```

<!-- gate: output -->

```
pod/escape-hostpid created
# ...
pod/escape-hostpid condition met
# ...
137 containerd
748 kubelet
# ...
kill -0 kubelet: allowed
/usr/bin/kubelet --bootstrap-kubeconfig=
# ...
nsenter: can't open '/proc/1/ns/mnt': Permission denied
command terminated with exit code 1
```

The node's `containerd` and `kubelet` are in the Pod's view. `kill -0` sends no
signal, but it makes the permission check a real signal would make
([kill(2)](https://man7.org/linux/man-pages/man2/kill.2.html)), and the check
passed. The kubelet's command line is readable, so any secret a process took as
an argument is visible from this container. That makes `hostPID` an information
leak on its own.

The last command is the deliberate failure. `nsenter` needs to open the node's
mount namespace through `/proc/1/ns/mnt`, and this Pod is not privileged, so the
open is denied. `hostPID` gives visibility. Privilege gives entry, and the next
attack has both.

### hostPath: the node's root, and its CA key

`hostPath: /` mounts the node's filesystem into the Pod. The Pod below drops
every capability and runs as root. It is the simplest form of the attack:

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a hostPath mount of the node root, read as root with no capabilities. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-hostpath
  namespace: p05-02-attack
spec:
  containers:
    - name: esc
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: nodefs
          mountPath: /host
          readOnly: true
  volumes:
    - name: nodefs
      hostPath:
        path: /
        type: Directory
```

The reads below print the Pod's user, its capability set, the node's hostname,
the key's owner and mode, and the first ten bytes of the cluster CA key, which
are the PEM armour. No key material reaches the transcript:

```sh
kubectl exec -n p05-02-attack escape-hostpath -- sh -c '
id -u
grep ^CapEff /proc/self/status | tr -s "\t" " "
cat /host/etc/hostname
stat -c "%a %U %n" /host/etc/kubernetes/pki/ca.key
head -c 10 /host/etc/kubernetes/pki/ca.key; echo'
```

<!-- gate: output -->

```
0
CapEff: 0000000000000000
sf-pilot-control-plane
600 root /host/etc/kubernetes/pki/ca.key
-----BEGIN
```

`/host` is the kind node container's root filesystem, not the machine that runs
kind. The hostname confirms it is the control-plane node. The key is mode `600`
and owned by root. The Pod is root, so it owns the read, and it holds no
capability at all. With the CA key an attacker can sign a client certificate for
any user: the API server takes the
[username and groups from the certificate](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#x509-client-certificates),
and the group `system:masters` is
[bound to `cluster-admin`](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#user-facing-roles).

Dropping capabilities did not stop the read. The next Pod changes one thing: it
runs as UID 65532.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: the same hostPath mount, run as UID 65532 with no capabilities. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-hostpath-nonroot
  namespace: p05-02-attack
spec:
  securityContext:
    runAsUser: 65532
    runAsGroup: 65532
  containers:
    - name: esc
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: nodefs
          mountPath: /host
          readOnly: true
  volumes:
    - name: nodefs
      hostPath:
        path: /
        type: Directory
```

```sh
kubectl exec -n p05-02-attack escape-hostpath-nonroot -- sh -c '
id -u
grep ^CapEff /proc/self/status | tr -s "\t" " "
cat /host/etc/hostname
stat -c "%a %U %n" /host/etc/kubernetes/pki/ca.key
head -c 10 /host/etc/kubernetes/pki/ca.key; echo'
```

<!-- gate: output -->

```
65532
CapEff: 0000000000000000
sf-pilot-control-plane
600 root /host/etc/kubernetes/pki/ca.key
head: /host/etc/kubernetes/pki/ca.key: Permission denied
```

The key is still owned by root and still mode `600`. A UID 65532 process is
neither its owner nor in its group, so the read is denied, even though the
Pod's capability set is the same empty set. Only the non-root UID changed. It
still reads world-readable node files and sees metadata, so non-root does not
make the mount safe. That is why `restricted` bans the volume type rather than
trying to judge which paths are safe.

### The runtime socket

The containerd socket is the runtime's control API. This Pod mounts it, plus the
node's own `crictl` binary, and is neither privileged nor given a capability:

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: the containerd socket and crictl mounted into the Pod, which is not privileged. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-socket
  namespace: p05-02-attack
spec:
  containers:
    - name: esc
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: containerd
          mountPath: /run/containerd/containerd.sock
        - name: crictl
          mountPath: /usr/local/bin/crictl
          readOnly: true
  volumes:
    - name: containerd
      hostPath:
        path: /run/containerd/containerd.sock
        type: Socket
    - name: crictl
      hostPath:
        path: /usr/local/bin/crictl
        type: File
```

```sh
kubectl exec -n p05-02-attack escape-socket -- sh -c '
R=unix:///run/containerd/containerd.sock
echo "containers visible: $(crictl -r $R ps -q 2>/dev/null | wc -l)"
crictl -r $R ps --name kube-apiserver -o table 2>/dev/null |
  grep -o "kube-apiserver-[a-z0-9-]*"'
```

<!-- gate: output -->

```
containers visible: 24
kube-apiserver-sf-pilot-control-plane
```

The socket lists every container on the node, the control plane included. The
lab only lists them. The
[cri-tools documentation](https://github.com/kubernetes-sigs/cri-tools/blob/master/docs/crictl.md)
describes `create`, `start` and `run`, which start new containers on the same
socket, so a reader who holds it can start one that mounts the node's root. The
lab does not do that. The Pod has no privilege and no added capability, which is
why a `hostPath` to the socket is dangerous on its own.

### Privileged with hostPID: the node's namespaces, and a neighbour

Now the two fields together. `privileged` supplies the capabilities, and
`hostPID` supplies the view of every process on the node:

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: privileged with hostPID, so nsenter can enter the node's namespaces. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-node
  namespace: p05-02-attack
spec:
  hostPID: true
  containers:
    - name: esc
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
```

```sh
kubectl apply -f escape-node.yaml
kubectl wait --for=condition=Ready pod/escape-node -n p05-02-attack --timeout=120s
kubectl exec -n p05-02-attack escape-node -- nsenter -t 1 -m -- cat /etc/hostname
kubectl exec -n p05-02-attack escape-node -- nsenter -t 1 -m -- ls -l /etc/kubernetes/super-admin.conf
kubectl exec -n p05-02-attack escape-node -- nsenter -t 1 -m -- runc --version | head -1
```

<!-- gate: output -->

```
pod/escape-node created
# ...
pod/escape-node condition met
# ...
sf-pilot-control-plane
# ...
-rw------- 1 root root 5666 Oct 30 14:28 /etc/kubernetes/super-admin.conf
# ...
runc version 1.4.3
```

`nsenter -t 1 -m` joins the node's mount namespace from PID 1, so the Pod reads
the node's files as if it were on the node. The admin kubeconfig is root-only,
and the lab reads only its metadata. The `runc` version is read from the node's
own binary, and the user namespace section relies on it.

With `hostPID` the Pod can also see the victim's sleep process. The next command
finds it, follows `/proc/<pid>/root` into the victim's filesystem, and copies
busybox in. Busybox runs an applet chosen by the name it is started under, so
the copy named `busybox` runs as `busybox`:

```sh
kubectl exec -n p05-02-attack escape-node -- sh -c '
VPID=$(ps -o pid,args | awk "\$2==\"sleep\" && \$3==\"1800\" {print \$1}")
set -- $VPID
[ $# = 1 ] || { echo "victim not unique: $VPID"; exit 1; }
echo "victim pid $VPID"
cp /bin/busybox /proc/$VPID/root/tmp/busybox && echo "copied to /tmp/busybox"'
kubectl exec -n p05-02-attack victim -- /tmp/busybox id
```

<!-- gate: output -->

```
victim pid 867048
copied to /tmp/busybox
# ...
uid=0(root) gid=0(root) groups=0(root),10(wheel)
```

The victim runs a binary that nobody shipped with it. Nothing in its spec
changed, and no vulnerability in its own code was needed. The copy never leaves
the kind node container: `/proc/<pid>/root` points into a Pod's filesystem on
that node. The script stops if more than one Pod runs `sleep 1800`, because then
the copy would be ambiguous.

### The same attacks under restricted

Now point the same attack manifests at `p05-02-restricted`, which enforces
`restricted`. A server-side dry run returns the admission verdict without
creating anything. The sed changes only the namespace.

```sh
for f in escape-privileged escape-hostpid escape-hostpath escape-socket escape-node; do
  sed 's/namespace: p05-02-attack/namespace: p05-02-restricted/' $f.yaml |
    kubectl apply --dry-run=server -f -
done
```

<!-- gate: output -->

```
Error from server (Forbidden): error when creating "STDIN": pods "escape-privileged" is forbidden: violates PodSecurity "restricted:latest": privileged (container "esc" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "esc" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "esc" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "esc" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "esc" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
# ...
Error from server (Forbidden): error when creating "STDIN": pods "escape-hostpid" is forbidden: violates PodSecurity "restricted:latest": host namespaces (hostPID=true), allowPrivilegeEscalation != false (container "esc" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "esc" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "esc" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "esc" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
# ...
Error from server (Forbidden): error when creating "STDIN": pods "escape-hostpath" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "esc" must set securityContext.allowPrivilegeEscalation=false), restricted volume types (volume "nodefs" uses restricted volume type "hostPath"), runAsNonRoot != true (pod or container "esc" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "esc" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
# ...
Error from server (Forbidden): error when creating "STDIN": pods "escape-socket" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "esc" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "esc" must set securityContext.capabilities.drop=["ALL"]), restricted volume types (volumes "containerd", "crictl" use restricted volume type "hostPath"), runAsNonRoot != true (pod or container "esc" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "esc" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
# ...
Error from server (Forbidden): error when creating "STDIN": pods "escape-node" is forbidden: violates PodSecurity "restricted:latest": host namespaces (hostPID=true), privileged (container "esc" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "esc" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "esc" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "esc" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "esc" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Every line names the fields that one Pod breaks. The first line refuses
`privileged` by name, and the second refuses `hostPID` as `host namespaces`.
Each refusal also lists the hardening fields that Pod leaves unset, because
`restricted` requires them whatever the attack is. A Pod with one host field is
therefore refused for that field and for the hardening it skipped. Nothing was
created, so no attacker ran.

### The hardened victim, and the same neighbour

The neighbour finds its target by its sleep process, so only one victim may run
`sleep 1800` at a time. Delete the default victim, then create the hardened one.
The hardened Pod carries the
[baseline](../01-core-workloads/01-pods.md#baseline) in full: its own
ServiceAccount, a non-root UID, no capabilities, no escalation,
`RuntimeDefault` seccomp, a read-only root and an `emptyDir` for `/tmp`.

```sh
kubectl delete pod victim -n p05-02-attack --wait=true
```

Save the two objects as `victim-hardened.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: victim-sa
  namespace: p05-02-restricted
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: victim
  namespace: p05-02-restricted
spec:
  serviceAccountName: victim-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "1800"]
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
kubectl apply -f victim-hardened.yaml
kubectl wait --for=condition=Ready pod/victim -n p05-02-restricted --timeout=120s
```

The victim's own writes come first. Then the read-outs show what the baseline
set:

```sh
kubectl exec -n p05-02-restricted victim -- sh -c 'cp /bin/busybox /usr/bin/implant'
kubectl exec -n p05-02-restricted victim -- sh -c 'cp /bin/busybox /tmp/busybox && /tmp/busybox id'
kubectl exec -n p05-02-restricted victim -- awk '/^(CapEff|NoNewPrivs|Seccomp):/ {print $1, $2}' /proc/self/status
```

<!-- gate: output -->

```
serviceaccount/victim-sa created
pod/victim created
# ...
pod/victim condition met
# ...
cp: can't create '/usr/bin/implant': Read-only file system
command terminated with exit code 1
# ...
uid=65532 gid=65532 groups=65532
# ...
CapEff: 0000000000000000
NoNewPrivs: 1
Seccomp: 2
```

The write to `/usr/bin` is refused because the root filesystem is read-only.
The copy into `/tmp` succeeds, and the copied busybox runs as UID 65532. The
read-out confirms the other fields: the capability set is empty, `NoNewPrivs`
is `1` from `allowPrivilegeEscalation: false`, and `Seccomp` is `2`, meaning a
filter is loaded from `RuntimeDefault`.

Now the neighbour, still in the privileged namespace, attacks the hardened
victim:

```sh
kubectl exec -n p05-02-attack escape-node -- sh -c '
VPID=$(ps -o pid,args | awk "\$2==\"sleep\" && \$3==\"1800\" {print \$1}")
set -- $VPID
[ $# = 1 ] || { echo "victim not unique: $VPID"; exit 1; }
echo "victim pid $VPID"
cp /bin/busybox /proc/$VPID/root/usr/bin/implant && echo "copied to /usr/bin/implant"'
kubectl exec -n p05-02-attack escape-node -- sh -c '
VPID=$(ps -o pid,args | awk "\$2==\"sleep\" && \$3==\"1800\" {print \$1}")
set -- $VPID
[ $# = 1 ] || { echo "victim not unique: $VPID"; exit 1; }
echo "victim pid $VPID"
cp /bin/busybox /proc/$VPID/root/tmp/id && echo "copied to /tmp/id"'
kubectl exec -n p05-02-restricted victim -- /tmp/id
```

<!-- gate: output -->

```
victim pid 868993
cp: can't create '/proc/868993/root/usr/bin/implant': Read-only file system
command terminated with exit code 1
# ...
victim pid 868993
copied to /tmp/id
# ...
uid=65532 gid=65532 groups=65532
```

The one write the neighbour tried into a system path failed: its `cp` into
`/usr/bin` returned `Read-only file system`. The lab tried no other write into
the victim's system paths, and it made no capability, setuid or syscall test
from inside the victim, so this chapter claims none of those. The same
neighbour copied busybox into the victim's `/tmp`, and the copy ran there as
UID 65532. `/tmp` is an `emptyDir`, so it is writable and executable, and a
read-only root filesystem does not stop a binary copied there. The lab found no
baseline field that stops execution from an `emptyDir`, so this chapter claims
none. Detecting a binary that runs from `/tmp` belongs to
[05.08](08-audit-detection-and-incident-response.md).

The victim's fields do not contain a privileged neighbour. The neighbour runs
as root with the full capability set, and `nsenter -t 1 -m` above shows it
reaches the node's mount namespace, so nothing in the victim's
`securityContext` limits what it does to the victim's filesystem. What stopped
the one refused write was the victim's read-only root. The control that
matters is that no namespace admits a Pod with both `hostPID` and privilege.
That means `restricted` in every namespace that could hold one, and RBAC that
limits who can create Pods in a privileged namespace
([ch.01](01-authn-authz-rbac.md)). A label on `p05-02-restricted` governs only
Pods created in that namespace, and the neighbour was created in
`p05-02-attack`, which admits privilege. The refusals above show the first
half in one namespace.

### User namespaces: an observed failure {#user-namespaces}

User namespaces are the deeper fix for "root in the container is root on the
node". With `hostUsers: false` the kubelet maps the Pod's UIDs to node UIDs
that no other Pod on the node shares. Root inside then has no privilege on the
host. Without the field, the mapping is the identity. The hardened victim shows
the before state:

```sh
kubectl exec -n p05-02-restricted victim -- cat /proc/self/uid_map | awk '{$1=$1;print}'
```

<!-- gate: output -->

```
0 0 4294967295
```

Container UID 0 is node UID 0 across the whole range. The probe below is the
hardened victim with `hostUsers: false`, and nothing else changed. It carries
the full baseline, including its `emptyDir` for `/tmp`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: userns-probe
  namespace: p05-02-restricted
spec:
  hostUsers: false
  serviceAccountName: victim-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "1800"]
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
kubectl apply -f userns-probe.yaml
kubectl wait --for=condition=Ready pod/userns-probe -n p05-02-restricted --timeout=60s
kubectl get events -n p05-02-restricted --field-selector involvedObject.name=userns-probe --sort-by=.lastTimestamp | tail -2
```

<!-- gate: output -->

```
pod/userns-probe created
# ...
error: timed out waiting for the condition on pods/userns-probe
# ...
28s         Warning   FailedCreatePodSandBox   pod/userns-probe   Failed to create pod sandbox: rpc error: code = Unknown desc = failed to start sandbox "1ec1897fb7dc4140f53d3ffcb0cdea23664aebaab3a724216daf19deaf3127d0": failed to create containerd task: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: error during container init: error mounting "sysfs" to rootfs at "/sys": mount src=sysfs, dst=/sys, dstFd=/proc/thread-self/fd/11, flags=MS_RDONLY|MS_NOSUID|MS_NODEV|MS_NOEXEC: operation not permitted
12s         Warning   FailedCreatePodSandBox   pod/userns-probe   Failed to create pod sandbox: rpc error: code = Unknown desc = failed to start sandbox "500d252cb2bab574b62239661fff8c05c21b2e837a8b12f7d54c0dff5aae8c50": failed to create containerd task: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: error during container init: error mounting "sysfs" to rootfs at "/sys": mount src=sysfs, dst=/sys, dstFd=/proc/thread-self/fd/11, flags=MS_RDONLY|MS_NOSUID|MS_NODEV|MS_NOEXEC: operation not permitted
```

The API server admitted the Pod, so `restricted` raised no objection to
`hostUsers: false`. The sandbox failed while containerd mounted `sysfs` inside
the new user namespace, which the kernel refused with `operation not permitted`.
The lab did not trace
that refusal further, so this chapter names no cause. The
[user namespaces page](https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/)
requires Linux 6.3 or later, runc 1.2 or later and containerd 2.0 or later, and
idmap support on the filesystems the node's pod directory and the Pod's volumes
use. The node meets the three version minimums: kernel 7.0.0, runc 1.4.3 and
containerd 2.3.4. The filesystem requirement was not checked in this run.

The page also marks the feature stable since Kubernetes v1.36. Stable is not the
same as working on this node, and the guide keeps `hostUsers` out of the
baseline until a run on kind passes on both Linux and macOS hosts. This run is
Linux only, and it failed.

### Baseline and restricted, one namespace each

`p05-02-baseline` enforces `baseline` and warns on `restricted`. A default Pod
in it shows the difference between the two lists:

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a default Pod in a baseline namespace, which restricted only warns about. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: victim
  namespace: p05-02-baseline
spec:
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "3600"]
```

```sh
kubectl apply -f victim-baseline.yaml
kubectl wait --for=condition=Ready pod/victim -n p05-02-baseline --timeout=120s
sed 's/namespace: p05-02-attack/namespace: p05-02-baseline/' escape-hostpid.yaml | kubectl apply --dry-run=server -f -
sed 's/namespace: p05-02-attack/namespace: p05-02-baseline/' escape-hostpath.yaml | kubectl apply --dry-run=server -f -
```

<!-- gate: output -->

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/victim created
# ...
pod/victim condition met
# ...
Error from server (Forbidden): error when creating "STDIN": pods "escape-hostpid" is forbidden: violates PodSecurity "baseline:latest": host namespaces (hostPID=true)
# ...
Error from server (Forbidden): error when creating "STDIN": pods "escape-hostpath" is forbidden: violates PodSecurity "baseline:latest": hostPath volumes (volume "nodefs")
```

The Pod with no `securityContext` is admitted, because `baseline` does not
require one. The `warn` label returns the `restricted` list as a client
warning, and the Pod is created anyway. The two dry runs show what `baseline`
refuses: the `hostPID` Pod is refused for host namespaces alone, and the
`hostPath` Pod is refused for its volume alone. Neither message mentions
`runAsNonRoot`, `seccompProfile` or the capability drop, because `baseline`
does not require them. That is the difference between the two lists. A
migration uses it: put the namespace at `warn` for `restricted`, read the
warnings, fix each workload, then move `enforce` to `restricted`.

### The Bookstore under restricted

The Bookstore's `bookstore` namespace enforces `restricted`
([`00-namespace.yaml`](../examples/bookstore/raw-manifests/00-namespace.yaml)).
Its workloads carry the baseline. The check reads warnings, because `enforce`
is not applied to a Deployment, only to the Pods it creates, while `audit` and
`warn` are applied to the Deployment itself. So the lab first proves that the
labels produce a warning, with two controls. A Deployment with no
`securityContext` in a labelled namespace must print a `Warning:`, and the same
Deployment in the unlabelled namespace must print nothing:

```sh
kubectl create deployment unhardened --image=busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 --dry-run=server -n p05-02-bookstore -- sleep 3600
kubectl create deployment unhardened --image=busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 --dry-run=server -n p05-02-unlabelled -- sleep 3600
```

<!-- gate: output -->

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "busybox" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "busybox" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "busybox" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "busybox" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/unhardened created (server dry run)
# ...
deployment.apps/unhardened created (server dry run)
```

The labelled namespace prints the warning, and the unlabelled one prints
nothing but the object line. A clean dry run in a namespace with no labels
means nothing.

Next, the Bookstore's ServiceAccounts go into the lab namespace, so the Pods
that name them can be admitted. Then the loop checks every workload manifest in
`raw-manifests/` that creates Pods. The loop finds them by kind, so a file added
later is covered:

```sh
sed 's/namespace: bookstore/namespace: p05-02-bookstore/' examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml | kubectl apply -f -
for f in $(grep -lE '^kind: (Pod|Deployment|StatefulSet|DaemonSet|Job|CronJob)( |$)' examples/bookstore/raw-manifests/*.yaml); do
  sed 's/namespace: bookstore/namespace: p05-02-bookstore/' "$f" |
    kubectl apply -n p05-02-bookstore --dry-run=server -f -
done
```

<!-- gate: output -->

```
serviceaccount/catalog-sa created
serviceaccount/storefront-sa created
serviceaccount/orders-sa created
serviceaccount/payments-worker-sa created
serviceaccount/postgres-sa created
serviceaccount/redis-sa created
serviceaccount/rabbitmq-sa created
serviceaccount/migrate-sa created
role.rbac.authorization.k8s.io/catalog-config-reader created
rolebinding.rbac.authorization.k8s.io/catalog-config-reader-binding created
# ...
pod/catalog created (server dry run)
pod/catalog created (server dry run)
deployment.apps/catalog created (server dry run)
deployment.apps/storefront created (server dry run)
deployment.apps/redis created (server dry run)
deployment.apps/rabbitmq created (server dry run)
deployment.apps/orders created (server dry run)
deployment.apps/payments-worker created (server dry run)
service/postgres created (server dry run)
statefulset.apps/postgres created (server dry run)
job.batch/db-migrate created (server dry run)
cronjob.batch/cleanup created (server dry run)
service/catalog created (server dry run)
deployment.apps/catalog-stable created (server dry run)
deployment.apps/catalog-canary created (server dry run)
```

Each workload object reports `created (server dry run)` with no `Warning:`
line. The two `pod/catalog` lines are the standalone Pods in `01-` and `02-`,
which name no namespace in their files. A dry run is not a boot test, though,
and PSA does not check whether an image starts. This lab starts the three stock
data images from their own manifests. It does not start the Go services or the
storefront, so their boot is not shown. The rollout below is the check for the
data tier:

```sh
for f in 16-db-credentials 35-priorityclasses 12-redis 13-rabbitmq 20-postgres-statefulset; do
  sed 's/namespace: bookstore/namespace: p05-02-bookstore/' examples/bookstore/raw-manifests/$f.yaml | kubectl apply -f -
done
kubectl rollout status -n p05-02-bookstore deployment/redis --timeout=180s
kubectl rollout status -n p05-02-bookstore deployment/rabbitmq --timeout=300s
kubectl rollout status -n p05-02-bookstore statefulset/postgres --timeout=180s
for w in deployment/redis deployment/rabbitmq statefulset/postgres; do
  kubectl exec -n p05-02-bookstore $w -- sh -c 'id; touch /usr/bin/backdoor || true'
done
```

<!-- gate: output -->

```
Waiting for deployment "redis" rollout to finish: 0 of 1 updated replicas are available...
deployment "redis" successfully rolled out
# ...
Waiting for deployment "rabbitmq" rollout to finish: 0 of 1 updated replicas are available...
deployment "rabbitmq" successfully rolled out
# ...
NAME                        READY   RESTARTS
rabbitmq-64d9d7659b-r4q2c   true    0
# ...
Server startup complete; 5 plugins started
Time to start RabbitMQ: 47061 ms
# ...
partitioned roll out complete: 1 new pods have been updated...
# ...
uid=999(redis) gid=999(redis) groups=999(redis)
touch: cannot touch '/usr/bin/backdoor': Read-only file system
# ...
uid=999(rabbitmq) gid=999(rabbitmq) groups=999(rabbitmq)
touch: cannot touch '/usr/bin/backdoor': Read-only file system
# ...
uid=999(postgres) gid=999(postgres) groups=999(postgres),101(ssl-cert)
touch: cannot touch '/usr/bin/backdoor': Read-only file system
```

Redis, rabbitmq and postgres start as UID 999, not as root, inside a namespace
that enforces `restricted`, with a read-only root, and each refuses the write
into `/usr/bin`. Postgres sets `fsGroup: 999`, so its data volume is writable
by its own UID, and it mounts `emptyDir` for `/tmp`, as
[01.01](../01-core-workloads/01-pods.md#baseline-read-only-root) describes.
Those fields are there so the image boots. The `restricted` verdict does not
depend on them.

rabbitmq reaches Ready as UID 999 with the same read-only root. The
`Time to start RabbitMQ` line in the output is the boot time the lab recorded,
and the startup probe in the manifest holds the liveness probe off until the
port opens.

### Clean up

Delete the five namespaces. This removes every Pod, Deployment and Job the lab
created. Namespace deletion can take longer than the wait. The script's exit
status reports a timeout if it does, and a later check shows whether the
namespaces are gone:

```sh
kubectl delete namespace p05-02-attack p05-02-baseline p05-02-restricted p05-02-bookstore p05-02-unlabelled --wait=true --timeout=300s
```

<!-- gate: output -->

```
namespace "p05-02-attack" deleted
namespace "p05-02-baseline" deleted
namespace "p05-02-restricted" deleted
namespace "p05-02-bookstore" deleted
namespace "p05-02-unlabelled" deleted
```

## Pod Security: levels, modes, and exceptions

PSA selects a standard per namespace through labels, and nothing else. The
standards are the table in the mental model. Three details decide how to use
them.

**Modes.** `enforce` rejects a violating Pod at admission. For workload objects
such as Deployments, enforce is not applied to the object, only to the Pods it
creates. `audit` and `warn` are applied to the workload objects as well, so a
Deployment with a bad template produces a `Warning:` line in a dry run, which is
the signal the Bookstore check reads
([PSA docs](https://kubernetes.io/docs/concepts/security/pod-security-admission/)).
Set all three at the same level, so a regression that gets past review still
shows up. Roll out in the order `warn`, `audit`, `enforce`, and never the other
way round.

**Version.** The `-version` label pins the ruleset to a Kubernetes minor, such
as `v1.37`, or follows the newest with `latest`. `latest` is right while you
test upgrades. A regulated cluster pins the version, so an upgrade cannot change
what `restricted` means without a deliberate change.

**Exceptions, not exemptions.** Some legitimate workloads cannot run under
`restricted`, and they are not a reason to loosen the default.

- Falco's modern eBPF driver needs at least `CAP_SYS_PTRACE`,
  `CAP_SYS_RESOURCE`, `CAP_BPF` and `CAP_PERFMON`, and the container example
  on the same page mounts host paths such as `/proc` and `/etc` ([Falco
  container setup](https://falco.org/docs/setup/container/)). The `restricted`
  standard lets a Pod add back only `NET_BIND_SERVICE`. The `baseline`
  standard allows added capabilities only from a short list that holds none of
  those four, and it forbids `hostPath` volumes ([Pod Security
  Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)).
  The levels are not stated for Falco anywhere upstream. This is read from the
  two pages: Falco's lowest working level is `privileged`.
- node-exporter's example runs with `--net="host"` and `--pid="host"`, and
  mounts the node's `/` read-only at `/host` with `--path.rootfs=/host` ([its
  README](https://github.com/prometheus/node_exporter#docker)). The `baseline`
  standard forbids host namespaces and `hostPath`, so node-exporter's lowest
  working level is also `privileged`.

The labels cannot be tuned to fit. They select a level and a version and nothing
between them, so there is no "baseline plus host networking". The other route is
an exemption in the admission controller configuration, which a namespace label
does not show, and the
[PSA exemptions](https://kubernetes.io/docs/concepts/security/pod-security-admission/#exemptions)
page describes it.

The rules the guide applies:

- The default stays `restricted`. A workload that needs more lives in its
  **own namespace**, labelled with the lowest level it works under, and only
  that namespace.
- If the privilege is for an optional feature, turn the feature off instead.
- Record each exception in the one registry with its reason, the chapter that
  owns it, and an expiry within twelve months, so it is revisited rather than
  forgotten. The registry is taught in
  [05.09](09-running-security-on-a-platform-team.md).
- A Pod in a privileged namespace can do what the node allows, so RBAC must
  limit who may create Pods there. [ch.01](01-authn-authz-rbac.md) sets that
  limit.

Never weaken an application namespace to fit an agent. Move the agent.

## How it works under the hood

[01.01](../01-core-workloads/01-pods.md#baseline) explains what each baseline
field does to the running container. The parts specific to Pod security:

- **Capabilities, `no_new_privs` and seccomp** are explained field by field in
  [01.01](../01-core-workloads/01-pods.md#baseline). The read-outs above show
  what each one did in this lab: `CapEff` is the full mask on the privileged
  Pod and zero on the hardened one, and the hardened victim reads
  `NoNewPrivs: 1` and `Seccomp: 2`.
- **AppArmor and SELinux** confine a process with a Linux Security Module, set
  through `securityContext.appArmorProfile` and `securityContext.seLinuxOptions`.
  Both are covered in [05.05](05-kernel-isolation.md).
- **PSA is a fixed policy that a namespace label selects.** It evaluates the
  Pod's `securityContext` and volume types against the standard, and it writes
  no rules of its own. Beyond the three standards, a policy engine or a
  ValidatingAdmissionPolicy does the job, and
  [05.07](07-admission-control-and-policy-as-code.md) covers that
.
- **PodSecurityPolicy is gone.** It was removed in Kubernetes v1.25, and its
  replacement is the namespace label above. A runbook that tells you to write a
  `PodSecurityPolicy` describes a removed API.

## Production notes

> **In production:** label every application namespace `enforce: restricted`,
> with `audit` and `warn` at the same level, and roll the label out as `warn`,
> then `audit`, then `enforce`. A namespace at `privileged` is an open door, and
> `baseline` is a minimum, not a goal.

> **In production:** pin the `-version` label on regulated clusters, so a
> Kubernetes upgrade cannot change what `restricted` means without a decision.

> **In production:** prefer purpose-built non-root images, so `restricted` costs
> nothing. For stock images that assume root, do what the Bookstore does: a
> specific non-root UID, an `fsGroup` for the data volume, a read-only root with
> an `emptyDir` for each path the image writes, and a test that the image boots.
> An image that cannot run on a read-only root is an exception: record it, with
> its reason, its chapter and an expiry.

> **In production (managed clusters):** PSA is part of the API server, so the
> labels are the same on any cluster that runs them. Operating a managed cluster
> is taught in [Part 10](../10-cloud-and-managed-kubernetes/01-managed-kubernetes-model.md),
> and runtime defense on a cloud cluster in
> [14.13](../14-eks-in-production-a-to-z/13-runtime-defense-and-container-security.md).

## Quick Reference

```sh
kubectl label ns <NS> \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest --overwrite
kubectl apply --dry-run=server -f pod.yaml
kubectl get ns <NS> --show-labels | tr ',' '\n' | grep pod-security
kubectl explain pod.spec.securityContext --recursive
kubectl explain pod.spec.containers.securityContext --recursive
```

The minimal `restricted`-compliant skeleton, which is the baseline in short. The
image is pinned by digest unless you built it:

```yaml
spec:
  serviceAccountName: app-sa             # never `default`
  automountServiceAccountToken: false
  securityContext:                       # pod-level
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: app
      securityContext:                   # container-level
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true     # + an emptyDir for any writable path
        capabilities: { drop: ["ALL"] }  # add back only NET_BIND_SERVICE if <1024
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 32Mi }
      volumeMounts: [ { name: tmp, mountPath: /tmp } ]
  volumes: [ { name: tmp, emptyDir: {} } ]
# namespace: pod-security.kubernetes.io/enforce: restricted (+ -version)
```

Checklist:

- [ ] `runAsNonRoot: true`, with a non-zero `runAsUser`; the image is not built
  to run as root
- [ ] `capabilities.drop: ["ALL"]`, with only proven additions
- [ ] `allowPrivilegeEscalation: false`, and never `privileged: true`
- [ ] `seccompProfile.type: RuntimeDefault`, or a vetted `Localhost` profile
- [ ] `readOnlyRootFilesystem: true`, with an `emptyDir` for each writable path,
  remembering that an `emptyDir` is executable too
- [ ] Only `restricted`-allowed volume types, and no `hostPath`, host ports or
  host namespaces - [ ] Namespace labelled `enforce: restricted` (+ `audit`,
  `warn` and `-version`)
- [ ] Server dry run of every workload shows no `Warning:` line, in a namespace
  that carries the labels

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise;
> the answer is the check.

1. **Your teammate says: "We have RBAC, so why do we also need Pod Security
   Admission?" Name the layer each one defends in one sentence.**
   <details><summary>Show answer</summary>

   RBAC controls which API calls a principal can make. PSA controls which
   kernel-level privileges a Pod may be admitted with. A Pod that RBAC allows
   can still mount the node's root and read the cluster CA key, as
   `escape-hostpath` did, so the two defend different layers.

   </details>

2. **In the lab, the root Pod with every capability dropped read the CA key, and
   the UID 65532 Pod did not. Both held an empty capability set. Why?**
   <details><summary>Show answer</summary>

   The key is owned by root with mode `600`. The root Pod is UID 0, which is the
   owner, so the owner bits allow the read, and no capability is needed. The
   UID 65532 Pod is neither the owner nor in the owning group, and it has no
   capability that would override the permission check. Only the UID changed,
   which is why `runAsNonRoot` and a non-zero `runAsUser` belong in the
   baseline.

   </details>

3. **The team wants a node-exporter DaemonSet in a namespace that enforces
   `restricted`. What do you tell them, and what is the right fix?**
   <details><summary>Show answer</summary>

   node-exporter's example needs host networking, host PID and a read-only
   mount of the node's root, and `restricted` and `baseline` both refuse all
   three. Do not weaken the application namespace. Put node-exporter in its
   own namespace labelled `privileged`, which is the lowest standard it works
   under, and record the exception with its reason, owning chapter and an
   expiry within twelve months. See "Exceptions, not exemptions" above.
   [06.01](../06-production-readiness/01-observability-metrics.md) does this
   for kube-prometheus-stack, with the chart's
   `prometheus-node-exporter.namespaceOverride`.

   </details>

4. **The baseline namespace admitted a default Pod with a warning, but refused
   the `hostPID` Pod. Which field refused it, and why was the default Pod
   still admitted?** <details><summary>Show answer</summary>

   The `hostPID` Pod was refused for host namespaces, which `baseline` forbids.
   The default Pod has no `securityContext` and no host field, so `baseline`
   admits it. Its missing non-root, drop-all and escalation fields are a
   `restricted` requirement, and `warn` reported them without refusing the Pod.

   </details>

## Further reading

- **Ibryam & Huß, _Kubernetes Patterns_ 2e, ch.23 _Process Containment_**:
  dropping privileges, capabilities, and the threat model behind running
  containers unprivileged.
- **Rosso et al., _Production Kubernetes_, ch.8 "Admission Control"**: enforcing
  Pod security at admission, and the migration from PSP to PSA.
- Official:
  <https://kubernetes.io/docs/concepts/security/pod-security-standards/>,
  <https://kubernetes.io/docs/concepts/security/pod-security-admission/>,
  <https://kubernetes.io/docs/tasks/configure-pod-container/security-context/>,
  and user namespaces,
  <https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/>.
- kind's "a node is a container": <https://kind.sigs.k8s.io/docs/design/initial/>.
