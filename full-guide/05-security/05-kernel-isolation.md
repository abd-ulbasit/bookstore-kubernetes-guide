# Kernel isolation: seccomp, AppArmor, SELinux, sandboxed runtimes

> Four ways to shrink what a container can ask the kernel to do, shown on a
> kind cluster where the lab host allows it: a seccomp filter built from an
> audit log, an AppArmor profile that refuses to run a program from a writable
> volume, and a gVisor sandbox chosen through a RuntimeClass. The seccomp
> filters and the gVisor sandbox ran. On the lab's nodes AppArmor could not
> load a profile, so the lab shows the node refusing a Pod that names one, and
> the profile's denial is cited, not run. SELinux and the Security Profiles
> Operator are cited, not run.

**Estimated time:** ~35 min read · ~60 min hands-on (the lab is scripted)
**Prerequisites:** [Part 05 ch.02](02-pod-security.md): the baseline's
seccomp and read-only root, and the escapes `restricted` closes ·
[Part 00 ch.02](../00-foundations/02-containers-and-images.md): namespaces,
cgroups and capabilities
**You'll know after this:** • read a seccomp profile and say which system
calls it allows · • run a workload under audit and read what the kernel
logged · • enforce a profile that refuses one call, and say why an allowlist
needs a complete audit · • say what happens to a Pod that names an AppArmor
profile its node cannot load, and explain how such a profile stops a program
running from `/tmp` (cited, not run here) · • say why a kind node cannot show
a host-kernel escape · • select a sandbox with a RuntimeClass, and read the
sandbox's own kernel from inside the Pod

<!-- tags: security, seccomp, apparmor, selinux, gvisor, runtimeclass -->

## Why this exists

[ch.02](02-pod-security.md) closed the escapes that come through the Pod spec:
privileged containers, host namespaces, hostPath, the runtime socket and a
writable root. What is left is the kernel itself. Every container process makes
system calls into the same kernel that runs the node. A Linux kernel exposes
hundreds of system calls, and an application uses a small fraction of them. A
kernel bug reachable through a call the application never makes is still
reachable by a container that can make it.

Kernel isolation shrinks that reachable set, and adds confinement the kernel
enforces on each process. seccomp decides which system calls a process may
make. AppArmor and SELinux decide which paths, capabilities and labels it may
use when it does make them. A sandboxed runtime decides which kernel answers the
call at all. None of these replaces the baseline from
[01.01](../01-core-workloads/01-pods.md#baseline). They sit beneath it, and each
one is a second line behind a field the baseline already sets.

## Mental model

Four layers, each stopping a different thing:

- **seccomp: the system-call filter.** A small BPF program the kernel runs on
  every system call a process makes. It sees the call's number and its argument
  registers, not paths, and it returns a decision: allow, return an error,
  log and allow, kill, or trap. `RuntimeDefault` is the container runtime's
  allowlist. It lets ordinary containers run and refuses the rest. `Unconfined`
  installs no filter at all. `Localhost` names a profile file on the node, which
  the kubelet reads from under its seccomp root, `/var/lib/kubelet/seccomp`.
- **AppArmor: a path-based policy.** A Linux Security Module. A profile is
  attached to a process by name, and it decides file access, capabilities and
  network by path. It can allow `/bin/sh` and refuse to execute `/tmp/bb`,
  because it sees two different paths. Kubernetes sets it per container with
  `securityContext.appArmorProfile`. The field is stable since Kubernetes 1.31.
- **SELinux: a label-based policy.** Also a Linux Security Module, but it works
  on labels. Each file and process carries a label, and the policy names the
  label pairs that may interact. Kubernetes sets the label through
  `seLinuxOptions`. Distributions that enable SELinux by default use it. The
  lab host here uses AppArmor, so SELinux is cited, not run.
- **Sandboxed runtimes: a different kernel answers.** gVisor's `runsc` runs a
  user-space kernel between the container and the host kernel. The container's
  system calls go to that kernel first, so most of them never reach the host
  kernel. Kata Containers puts the container in a lightweight virtual machine
  for a similar boundary. A RuntimeClass names the runtime a Pod uses, and
  containerd maps the name to the runtime's binary.

The layers stack. seccomp limits the calls, AppArmor limits the paths and
capabilities a process uses when it makes them, and a sandbox replaces the
kernel that answers. A process that holds root and every capability can still
do a great deal through the paths it may write. That is why the baseline comes
first, and why each layer here is evidence of defence in depth, not a
replacement for it.

## Threats and controls

Each threat is something a process inside a container can do to the kernel or
to the node. The lab shows three of these controls working: the first two rows
and the sandbox row. The AppArmor row is partly shown, and the rest are cited.
The text after the table says why. The lab runs no kernel exploit.

| Threat | Control this chapter teaches | Where it goes deeper |
|---|---|---|
| A rarely used system call reaches a kernel bug | A seccomp filter that refuses calls the workload does not need. `RuntimeDefault` is the baseline, and [02](02-pod-security.md) teaches it. A `Localhost` profile is shown as the mechanism for a custom filter, not as a finished profile | [Kubernetes seccomp tutorial](https://kubernetes.io/docs/tutorials/security/seccomp/) |
| A Pod runs with **no** seccomp filter at all | `restricted` refuses `Unconfined`, which the lab shows at admission. [02](02-pod-security.md) sets the baseline `RuntimeDefault` | [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) |
| A program is copied into a writable volume and run there | An AppArmor profile that denies execute under `/tmp` and `/dev/shm`, applied with `securityContext.appArmorProfile` | [Kubernetes AppArmor tutorial](https://kubernetes.io/docs/tutorials/security/apparmor/) |
| A label-based policy must separate workloads on a shared host | SELinux labels through `seLinuxOptions`, cited, not run on this lab host | [SELinux](https://kubernetes.io/docs/concepts/security/linux-kernel-security-constraints/) |
| A kernel bug is reached through the container's own system calls | A sandboxed runtime: gVisor selected by a RuntimeClass. Its user-space kernel answers the calls first | [gVisor](https://gvisor.dev/docs/), [RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/) |
| A node-level profiler or recorder must be deployed safely | The Security Profiles Operator, cited, not run | [Security Profiles Operator](https://github.com/kubernetes-sigs/security-profiles-operator) |

The first two rows need the baseline's `seccompProfile` field and the
`restricted` level, so the lab sets both on every hardened Pod. The third row
needs a profile loaded on the node, and none of the lab's nodes can load one.
The lab shows what a node does with a Pod that names a profile it does not
hold, and cites the denial itself. The fifth row needs a runtime that a kind
node does not ship with, so the lab installs gVisor into one node, shows a Pod
running under it, and removes it. The fourth and sixth rows are cited.

## What a kind node can and cannot show

A kind node is a container. It runs systemd, containerd and the kubelet, and it
shares the lab host's kernel. That fact sets what this lab can show truthfully.

- **A profile loaded in a node is loaded into the host's kernel.** AppArmor
  profiles are kernel state, shared by every container on the host. A load
  from a node therefore changes the lab host's policy, outside the node's own
  view. The lab loads none, and in the recorded run no node could have loaded
  one (see the AppArmor section). If you do load a profile on a host you own,
  give it a name nothing else uses, say so to whoever shares the host, and
  remove it when you finish. An earlier version of this lab loaded one and
  removed it at the end, but the host's policy still changed while it was
  loaded, so that step was removed.
- **A payload in a Pod is a process of the host's kernel.** A kernel escape
  would reach the lab host, not just the node. The lab runs no kernel exploit.
  Its payloads read `/proc`, copy busybox into a Pod's `/tmp`, run it, and ask
  for one personality call that a filter refuses. None of them reads or writes
  outside the node and the lab's own Pods.
- **A sandbox runs on the same host.** gVisor's `runsc` is a set of processes
  on the lab host. It changes which kernel answers the Pod's system calls, not
  where the process runs. Step 6 lists those processes on the node.
- **A runtime install is a change to the node.** Adding `runsc` writes files
  into one node, adds an entry to that node's containerd configuration and
  restarts containerd there, which interrupts the Pods on that node for a
  moment. The lab does this to one worker and puts the node back in step 7.

Parts 10, 14 and 15 cover operating these controls on managed clusters, where
the node image, the runtime and the admission policy belong to the platform
team. The [managed Kubernetes
model](../10-cloud-and-managed-kubernetes/01-managed-kubernetes-model.md) says
what the provider owns, and [runtime defence and container
security](../14-eks-in-production-a-to-z/13-runtime-defense-and-container-security.md)
covers the production side of detection. This chapter teaches the mechanism on
a lab cluster and links to them rather than repeating them.

## Lab: attack, harden, re-attack, evidence

### Lab header

- **Tier A, run in two parts.** The seccomp steps (3 and 4) ran on a
  single-node kind cluster named `sf-pilot`. The other steps (1, 2 and 5 to 7)
  ran later on a three-node kind cluster named `demo-lab`. Both have nodes on
  Kubernetes v1.37.0 and containerd 2.3.4, on a Linux host whose kernel is
  7.0.0 with AppArmor enabled. `kubectl` is v1.37.2. The gVisor release is
  `20261026.0`, and `runsc --version` printed `release-20261026.0`. The lab's
  config names its cluster `security-lab-kernel`, so the captured node names
  differ from the ones the commands would print. The AppArmor profile was not
  loaded and its denial did not run (see below). This lab has not been run on
  macOS, which has no AppArmor.
- **Script and transcript.**
  [`labs/05-05.sh`](../examples/security-lab/labs/05-05.sh) runs the steps
  below and deletes what it creates. Its recorded output is
  [`evidence/05-05.txt`](../examples/security-lab/evidence/05-05.txt), two runs
  joined at lines that say so: the seccomp part with `P05_RUNTIME=0`, the mode
  that changes no node runtime, and the later part with `P05_SECCOMP=0` and
  `P05_RUNTIME=1`. Run it only against a cluster you own. It refuses any
  kubectl context that is not `kind-*`. With `P05_RUNTIME=1` it changes one
  node's runtime, so use a cluster you can lose.
- **Namespaces.** Two, `kernel-attack` and `kernel-restricted`. The seccomp
  part of the recording named them `p05-05-attack` and `p05-05-restricted`;
  the script and the transcript carry the chapter's names, and the
  transcript's header says so. The later part used the chapter's names.
  `kernel-attack` enforces `privileged`, because one Pod in it runs unconfined.
  It holds that one marked, insecure Pod only. `kernel-restricted` enforces,
  audits and warns on `restricted`, and holds every other Pod. A namespace
  above `restricted` is an exception. Its reason is that this Pod must run
  unconfined to show what unconfined allows. Its owning chapter is this one.
  Its expiry is 2027-10-31, within twelve months. The entry is in
  `security/namespace-exceptions.yaml` at the repository root, and
  [05.09](09-running-security-on-a-platform-team.md) explains how the registry
  is kept.
- **What changed on the cluster, and what was put back.** Step 6 adds `runsc`,
  its containerd shim and a directory of helper binaries to one worker's
  `/usr/local/bin`, appends a `runsc` entry to that worker's containerd
  configuration after saving a copy, restarts containerd there, and labels the
  node. Step 7 reverses each of these, and the transcript shows the files, the
  entry and the RuntimeClass gone. The lab installs no webhook, no CRD and no
  chart. No AppArmor profile was loaded, on the node or on the lab host.
- **What did not run.** Loading the AppArmor profile and seeing it deny a
  write. No node had `apparmor_parser` or the AppArmor filesystem, and the lab
  did not add them, because the profile would then have entered the lab
  host's kernel policy. What the lab does show is the node refusing a Pod that
  names a profile it does not hold. SELinux and the Security Profiles Operator
  also did not run.
- **What did not work the first time.** The audit step did not produce what
  the lab wanted, and the chapter says what it produced instead. When the
  chapter was first written, a fresh kind cluster on the lab host stalled in
  `kubeadm init` on six attempts. The later steps ran on a cluster that
  already existed. The first gVisor attempt requested `runsc`, its shim and
  their checksum files as separate downloads from the release directory and
  got HTTP 404 for all four. The install page now describes one tarball,
  `gvisor.tar.zstd`, that holds `runsc`, the shim and a directory of helper
  binaries, and the lab uses it. The transcript is the third gVisor install: a
  trial and an earlier recording ran first, and each was removed.

### Step 1: the node shares the lab host's kernel

A kind node is a container. It runs systemd, containerd and the kubelet, and it
uses the host's kernel. So the kernel release it reports is the host's, and an
AppArmor profile loaded inside it is loaded into that host kernel. The lab
asks the node four questions. First set `NODE` to the kind node's name, and
keep it set for the rest of the lab:

```sh
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
docker exec "$NODE" uname -r
docker exec "$NODE" cat /sys/module/apparmor/parameters/enabled
docker exec "$NODE" sh -c 'test -d /sys/kernel/security/apparmor && echo apparmor-securityfs-present || echo apparmor-securityfs-absent'
docker exec "$NODE" sh -c 'test -e /sys/fs/selinux && echo selinux-present || echo selinux-absent'
```

<!-- gate: output -->

```
7.0.0-38-generic
Y
apparmor-securityfs-absent
selinux-absent
```

The kernel is the host's, and AppArmor is enabled in it (`Y`). The node does
not expose the AppArmor filesystem, so no profile can be loaded into it from
the node, and the lab does not try to change that. The node has no SELinux
filesystem, so this lab cannot show SELinux labels. Both results are why the
profile load and the SELinux part below are cited, not run, on this cluster.
The node in this capture is the control-plane node of the three-node cluster.
The AppArmor section asks every node.

### Seccomp, first: RuntimeDefault against Unconfined

[02](02-pod-security.md) teaches `RuntimeDefault` and the refusal of
`Unconfined`. This part repeats them only to set up the `Localhost` lesson: one
workload, run with no filter and with the default filter.

Create the two namespaces. The `privileged` one exists only for the Pod that
runs unconfined.

```sh
kubectl create ns kernel-attack
kubectl label ns kernel-attack pod-security.kubernetes.io/enforce=privileged
kubectl create ns kernel-restricted
kubectl label ns kernel-restricted \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

The insecure Pod comes first. It is the baseline in every field except one: the
seccomp profile is `Unconfined`, so no filter applies to its system calls. The
marker line above the fence is the lab's record that it is insecure on purpose.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: seccomp Unconfined, so no syscall filter applies. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: unconfined
  namespace: kernel-attack
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: Unconfined
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 # busybox:1.36
      command: ["sleep", "3600"]
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

The control is the same Pod with `RuntimeDefault`, in the `restricted`
namespace. `restricted` admits it, and it is the baseline from
[01.01](../01-core-workloads/01-pods.md#baseline) with the seccomp field set to
the runtime's own filter.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: runtimedefault
  namespace: kernel-restricted
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 # busybox:1.36
      command: ["sleep", "3600"]
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

Save each block as `unconfined.yaml` and `runtimedefault.yaml`, apply them, and
wait for both to be Ready. Then ask each Pod for its seccomp mode, from
`/proc/self/status`, and try one personality call. `setarch` with `-R` sets
`ADDR_NO_RANDOMIZE`, which needs no capability, so the Pods have nothing to
differ on except the filter.

```sh
kubectl -n kernel-attack exec unconfined -- sh -c 'grep "^Seccomp:" /proc/self/status | tr "\t" " "; setarch linux64 -R /bin/true 2>&1; echo exit=$?'
kubectl -n kernel-restricted exec runtimedefault -- sh -c 'grep "^Seccomp:" /proc/self/status | tr "\t" " "; setarch linux64 -R /bin/true 2>&1; echo exit=$?'
```

<!-- gate: output -->

```
Seccomp: 0
exit=0
```

<!-- gate: output -->

```
Seccomp: 2
linux64: personality(0x40000): Operation not permitted
exit=1
```

`Seccomp: 0` means no filter. `Seccomp: 2` means a filter is installed. The
unconfined Pod makes the call and succeeds. The `RuntimeDefault` Pod makes the
same call and the filter returns `EPERM`. The Pod has no capability in either
case, so the refusal comes from the filter alone.

Restricted also refuses the unconfined spec before any Pod runs. The lab copies
the insecure Pod into `kernel-restricted` and asks the admission chain, with a
server dry run that creates nothing.

<!-- gate: insecure-on-purpose -->
```yaml
# INSECURE ON PURPOSE: the Unconfined spec, offered to restricted. Dry run only. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: unconfined-restricted
  namespace: kernel-restricted
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: Unconfined
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
      command: ["sleep", "3600"]
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
kubectl apply --dry-run=server -f unconfined-restricted.yaml
```

<!-- gate: output -->

```
Error from server (Forbidden): error when creating "unconfined-restricted.yaml": pods "unconfined-restricted" is forbidden: violates PodSecurity "restricted:latest": seccompProfile (pod must not set securityContext.seccompProfile.type to "Unconfined")
```

### Seccomp, then a custom profile: audit, then enforce

A `Localhost` profile is a JSON file on the node. The kubelet resolves the
`localhostProfile` path under its seccomp root, `/var/lib/kubelet/seccomp`. So
`profiles/audit.json` in the lab is the file
`/var/lib/kubelet/seccomp/profiles/audit.json` on the node. The audit
profile changes one thing from allowing everything: its default action is
`SCMP_ACT_LOG`. Every system call is logged and still allowed.

```json
{
  "defaultAction": "SCMP_ACT_LOG",
  "architectures": ["SCMP_ARCH_X86_64"]
}
```

Copy the file into the node, for example with `docker exec -i` and a redirect.
That works on a local or a remote engine, where a bind mount would not. Then run
the audited Pod. It is the baseline with its profile set to the file, and it is
a deliberate exception to `RuntimeDefault`: this profile allows every call and
restricts nothing.

```yaml
# DELIBERATE EXCEPTION to the baseline seccompProfile (RuntimeDefault): a Localhost
# profile that allows every call but one. It is weaker than RuntimeDefault.
apiVersion: v1
kind: Pod
metadata:
  name: audit
  namespace: kernel-restricted
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/audit.json
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 # busybox:1.36
      command: ["sleep", "3600"]
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

Run a short workload in it, then read the kernel's audit records from the
host's kernel log. Without an audit daemon, a seccomp `log` record goes to the
kernel's printk path, and the kernel rate-limits that path. The lab records
the time with `SINCE=$(date +%s)` before the workload and reads the journal
from that epoch time, so the window holds on any host time zone. `-o cat`
keeps only the record text, so no host name reaches the transcript.

```sh
kubectl -n kernel-restricted exec audit -- sh -c 'id -u; cat /etc/passwd >/dev/null; ls / >/dev/null; echo done'
journalctl -k -o cat --since "@$SINCE" --no-pager > audit-journal.txt
grep -c 'type=1326' audit-journal.txt
grep -c 'exe="/bin/busybox"' audit-journal.txt
grep 'callbacks suppressed' audit-journal.txt | tail -1
```

<!-- gate: output -->

```
8
0
kauditd_printk_skb: 515 callbacks suppressed
```

This is the honest result, and it changes the lesson. The kernel printed eight
records and dropped 515. Not one busybox record reached the journal. An
allowlist derived from this log would be empty, and the first enforcing run
would break every process in the Pod. The audit method works only when something
consumes every record: an audit daemon, or a logging pipeline that reads the
audit socket. A lab host without one does not, and the chapter does not
pretend otherwise.

So the enforce step below is a deny-list, not an allowlist. It allows every call
except `personality`. The audit did not find that call. The lab chose it because
step 3 showed `RuntimeDefault` refusing it. The default is `ALLOW`, so the
profile is weaker than `RuntimeDefault`, which refuses many more calls. That is
why the two Pods that use a `Localhost` profile are deliberate exceptions to the
baseline, and why neither is a model for a production profile.

```json
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": ["SCMP_ARCH_X86_64"],
  "syscalls": [
    {
      "names": ["personality"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
```

The lab installs that profile and prints it back from the node, so the
transcript shows the file the node holds.

In production nobody copies a profile file into a node by hand. The profile
belongs to the node image, or to an operator that distributes it, and it is
versioned with the image, so a node that lacks the profile is caught before a
Pod lands on it. The lab's `docker exec` copy shows the mechanism without that
discipline. Start from `RuntimeDefault`, and build a custom allowlist only once
the audit records are complete, which needs a consumer for every record.

<!-- gate: output -->

```
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": ["SCMP_ARCH_X86_64"],
  "syscalls": [
    {
      "names": ["personality"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
```

The enforcing Pod is the baseline with the deny-list profile. It is the second
restricted Pod that uses a `Localhost` profile, and a deliberate exception to
the baseline's `RuntimeDefault`.

```yaml
# DELIBERATE EXCEPTION to the baseline seccompProfile (RuntimeDefault): a Localhost
# profile that allows every call but one. It is weaker than RuntimeDefault.
apiVersion: v1
kind: Pod
metadata:
  name: enforce
  namespace: kernel-restricted
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/deny-personality.json
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 # busybox:1.36
      command: ["sleep", "3600"]
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

Run the same workload, then the personality call, under the enforcing profile.

```sh
kubectl -n kernel-restricted exec enforce -- sh -c 'grep "^Seccomp:" /proc/self/status | tr "\t" " "; id -u; cat /etc/passwd >/dev/null && echo workload-ok; setarch linux64 -R /bin/true 2>&1; echo exit=$?'
```

<!-- gate: output -->

```
Seccomp: 2
65532
workload-ok
linux64: personality(0x40000): Operation not permitted
exit=1
```

The workload still runs, and the call the audit was looking for returns `EPERM`.
The filter is installed (`Seccomp: 2`), and the Pod has no capability to
undo it.

### AppArmor: a profile no node here can load, and what the node does instead

AppArmor confines a process by path. A profile is compiled by
`apparmor_parser` and written into the kernel through the AppArmor filesystem.
A container then names the loaded profile in
`securityContext.appArmorProfile`. The profile in
[`profiles/no-tmp-exec`](../examples/security-lab/profiles/no-tmp-exec) allows
the file access a container normally needs, and it denies execute under `/tmp`
and `/dev/shm`. The baseline gives a Pod one writable volume, `/tmp`, from its
emptyDir. `/dev/shm` is a tmpfs that the runtime mounts. Both are writable,
which is why they matter: `readOnlyRootFilesystem` does not stop a binary
being copied into a writable path and run from there.

Loading that profile needs two things on the node: `apparmor_parser` and the
AppArmor filesystem. Step 1 showed the filesystem missing from the control-plane
node. Now ask every node for the parser, and try to run it on a worker. Pick the
worker first. On a single-node cluster, use `NODE` instead.

```sh
WORKER=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].metadata.name}')
for n in $(kubectl get nodes -o name | cut -d/ -f2); do
  docker exec "$n" sh -c 'command -v apparmor_parser || echo apparmor_parser-absent'
done
docker exec "$WORKER" apparmor_parser --version
```

<!-- gate: output -->

```
apparmor_parser-absent
apparmor_parser-absent
apparmor_parser-absent
OCI runtime exec failed: exec failed: unable to start container process: exec: "apparmor_parser": executable file not found in $PATH
```

None of the three nodes has the parser, and the last command is the real error
from asking for it. The lab did not add the parser or mount the filesystem in
a node. A profile loaded from a node goes into the lab host's kernel policy,
outside the node's own view, and the lab leaves that policy alone. Nothing was
loaded, on a node or on the host. Had it been, the rule is a profile name that
nothing else on the host uses, and removal as soon as the demonstration ends,
with the chapter saying so plainly.

What the lab can show is what a node does with a Pod that names a profile it
does not hold. This is the baseline Pod with one more field, in the
`restricted` namespace. `Localhost` is the type that names a profile loaded on
the node, and `no-tmp-exec` is the name the profile file declares.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: apparmor
  namespace: kernel-restricted
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 # busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
        appArmorProfile:
          type: Localhost
          localhostProfile: no-tmp-exec
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

Save it as `apparmor.yaml` and apply it. The Pod will never be Ready, so wait
for its phase to become `Failed`, then read the reason, the message and the
events that name which component said what.

```sh
kubectl apply -f apparmor.yaml
kubectl -n kernel-restricted wait --for=jsonpath='{.status.phase}'=Failed pod/apparmor --timeout=120s
kubectl -n kernel-restricted get pod apparmor -o jsonpath='{.status.reason}{"\n"}{.status.message}{"\n"}'
kubectl -n kernel-restricted get events --field-selector involvedObject.name=apparmor --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.reportingComponent}{" "}{.reason}{"\n"}{end}'
```

<!-- gate: output -->

```
pod/apparmor created
pod/apparmor condition met
AppArmor
Pod was rejected: Cannot enforce AppArmor: AppArmor is not enabled on the host
default-scheduler Scheduled
kubelet AppArmor
```

The API server admitted the Pod: `restricted` allows a `Localhost` profile, and
the apply succeeded. The scheduler placed it. Then the node's kubelet refused
it, and the Pod ended in phase `Failed` with the reason `AppArmor`. It did not
run, and it did not fall back to running unconfined. That is the behaviour to
want from a control you rely on: a node that cannot enforce the profile
refuses the Pod instead of starting it without the profile.

Two limits on that result. Step 1 showed the kernel parameter at `Y` and the
AppArmor filesystem absent from the node. The message says AppArmor is not
enabled on the host, which fits the missing filesystem, but the lab did not
find out which check the kubelet makes. And the refusal says nothing about the
profile's rules. What the profile does to a process is the expected result on
a node that has both pieces: a copy of busybox run from `/tmp` is refused, and
the kernel log holds a `DENIED` record. That result is cited, not shown,
because no node here could load the profile.

The mechanism stands on the [AppArmor
tutorial](https://kubernetes.io/docs/tutorials/security/apparmor/). That page
states that the field has been stable since Kubernetes 1.31, and that a
profile must be loaded on every node where a Pod can land.

### SELinux: cited, not run

SELinux is also a Linux Security Module, and it labels files and processes
rather than naming paths. Kubernetes sets the label through
`securityContext.seLinuxOptions`. Step 1 showed that the node exposes no
SELinux filesystem, so this lab cannot apply a label and see it enforced. The
mechanism and the field are in the [Linux kernel security
constraints](https://kubernetes.io/docs/concepts/security/linux-kernel-security-constraints/)
page. Distributions that enable SELinux by default are the ones where the
field matters in practice.

### gVisor: a sandboxed runtime through a RuntimeClass

The other kind of boundary changes which kernel answers. gVisor's `runsc`
runs a user-space kernel for the Pod, so most of the Pod's system calls are
answered by that kernel and never reach the host's. A RuntimeClass names the
runtime. Its `handler` is the name containerd maps to a runtime binary, so a
Pod selects the sandbox with `runtimeClassName` and the cluster-scoped
RuntimeClass decides which handler runs it.

A kind node does not ship with `runsc`, so the lab installs it into the one
worker from the previous section. The [gVisor install
page](https://gvisor.dev/docs/user_guide/install/) says it needs Linux 5.6 or
later, and the lab host's kernel is 7.0.0. The lab pins release `20261026.0`
and checks the tarball's SHA-512 twice: against the file published beside it,
and against a digest written into the lab script. Both come from the same
bucket, so the checks catch a damaged download. They do not prove the release
is genuine. Work in a new, empty directory, because an archive you downloaded
is data until you have checked it.

```sh
GVISOR_RELEASE=20261026.0
ARCH=$(docker exec "$WORKER" uname -m)
GVISOR_SHA512=e6aa030fb8379fe92b53e9b8b696419e0dce8a3bbcc7d4c1cf76b2ea3d6569eabd7360e694deda6ccbdcd77095b3e82ca0f90a3d8fd13a3e5d6b11cd29fe4649
URL=https://storage.googleapis.com/gvisor/releases/release/$GVISOR_RELEASE/$ARCH
curl -fsSLO "$URL/gvisor.tar.zstd" -O "$URL/gvisor.tar.zstd.sha512"
sha512sum -c gvisor.tar.zstd.sha512
echo "$GVISOR_SHA512  gvisor.tar.zstd" | sha512sum -c -
tar --zstd -tf gvisor.tar.zstd
```

<!-- gate: output -->

```
gvisor.tar.zstd: OK
gvisor.tar.zstd: OK
containerd-shim-runsc-v1
runsc
gvisor-bin/
gvisor-bin/checkpointgofer
gvisor-bin/gvisor-proc-umounter
gvisor-bin/gvisor-sentry-prewarmer
gvisor-bin/gvisor_sentry
gvisor-bin/runsc-fd-parking
gvisor-bin/runsc-metric-server
```

The digest above is for the `x86_64` build. On another architecture, take the
digest from that architecture's published file and check it the same way.
Extract the tarball, then stream the three items into the node's
`/usr/local/bin`. `runsc` looks for `gvisor-bin/` next to its own binary, so
the three move together. Save the node's containerd configuration first, so
that cleanup can restore it. The `--no-same-owner` flag matters: a `tar` run
as root in the node otherwise keeps the numeric owner of the machine that made
the archive.

```sh
mkdir gvisor-dist && tar --zstd -xf gvisor.tar.zstd -C gvisor-dist
docker exec "$WORKER" cp -p /etc/containerd/config.toml /etc/containerd/config.toml.lab-backup
tar -C gvisor-dist -cf - runsc containerd-shim-runsc-v1 gvisor-bin \
  | docker exec -i "$WORKER" tar --no-same-owner -C /usr/local/bin -xf -
docker exec "$WORKER" /usr/local/bin/runsc --version | head -1
```

<!-- gate: output -->

```
runsc version release-20261026.0
```

Then tell that node's containerd that a handler named `runsc` exists. This is
the node's configuration, not the cluster's, so it is done on the node, and it
needs a containerd restart. The restart interrupts the Pods on that node for a
moment. The lab also labels the node. A label is how a cluster records which
nodes have a runtime, and `example.com` is a placeholder prefix.

```toml
# appended to /etc/containerd/config.toml in the worker
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
```

```sh
printf '\n[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]\n  runtime_type = "io.containerd.runsc.v1"\n' \
  | docker exec -i "$WORKER" sh -c 'cat >> /etc/containerd/config.toml'
docker exec "$WORKER" tail -3 /etc/containerd/config.toml
docker exec "$WORKER" systemctl restart containerd
kubectl wait --for=condition=Ready node/"$WORKER" --timeout=240s
kubectl label node "$WORKER" example.com/runsc=installed
```

<!-- gate: output -->

```
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
node/demo-lab-worker condition met
node/demo-lab-worker labeled
```

The RuntimeClass names the handler. Its `scheduling.nodeSelector` is merged
into the node selector of every Pod that uses the class, as the
[RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/)
page describes, so those Pods land only on nodes that carry the label. Without
it, a Pod could be scheduled to a node that has no `runsc`. The Pod below is
the baseline plus `runtimeClassName`.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    example.com/runsc: installed
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gvisor
  namespace: kernel-restricted
spec:
  runtimeClassName: gvisor
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 # busybox:1.36
      command: ["sleep", "3600"]
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

Save them as `runtimeclass.yaml` and `gvisor.yaml`, apply both, and wait for
the Pod.

```sh
kubectl apply -f runtimeclass.yaml
kubectl apply -f gvisor.yaml
kubectl -n kernel-restricted wait --for=condition=Ready pod/gvisor --timeout=240s
```

<!-- gate: output -->

```
runtimeclass.node.k8s.io/gvisor created
pod/gvisor created
pod/gvisor condition met
```

Ask the Pod which kernel it is running on, and ask the node the same
question.

```sh
kubectl -n kernel-restricted get pod gvisor -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl -n kernel-restricted exec gvisor -- sh -c 'uname -r; cat /proc/version; dmesg | head -3'
docker exec "$WORKER" uname -r
```

<!-- gate: output -->

```
gvisor
4.19.0-gvisor
Linux version 4.19.0-gvisor #1 SMP Sun Jan 10 15:06:54 PST 2016
[   0.000000] Starting gVisor...
[   0.417457] Politicking the oom killer...
[   0.730007] Granting licence to kill(2)...
7.0.0-38-generic
```

The Pod reports a kernel of its own, `4.19.0-gvisor`, and `dmesg` shows the
sandbox's start-up log. The node reports the lab host's kernel,
`7.0.0-38-generic`. That is the boundary: the Pod's system calls are answered
by a different kernel from the one that runs the node. Two more checks. The
first lists the sandbox's processes on the node, which shows the sandbox is
ordinary processes of the lab host's kernel. `ps` shows the first 15
characters of a process name, so `runsc-fd-parkin` is `runsc-fd-parking`. The
second repeats the seccomp check from earlier steps inside the sandbox.

```sh
docker exec "$WORKER" sh -c 'ps -eo comm | grep -E "^(runsc|gvisor_sentry)" | sort | uniq -c'
kubectl -n kernel-restricted exec gvisor -- sh -c 'grep "^Seccomp:" /proc/self/status | tr "\t" " "; setarch linux64 -R /bin/true 2>&1; echo exit=$?'
```

<!-- gate: output -->

```
     16 gvisor_sentry
      2 runsc
      1 runsc-fd-parkin
Seccomp: 0
linux64: personality(0x40000): Invalid argument
exit=1
```

Inside the sandbox `/proc/self/status` reports `Seccomp: 0`, although the
Pod's spec asks for `RuntimeDefault`. The personality call, which succeeded in
the unconfined Pod and got `EPERM` from the default filter, now gets `EINVAL`,
an answer neither earlier Pod gave. That is what a different kernel answering
looks like. The lab did not look into why the spec's filter does not show up in
the sandbox. The lesson is narrower: the `Seccomp:` line from the earlier steps
cannot judge a sandboxed Pod, so do not read it as proof that the baseline's
filter is absent or present there.

Two limits hold even when a sandbox runs. The sandbox is still a set of
processes on the lab host, so it changes which kernel answers the Pod's calls,
not where the process lives. And a sandbox does not replace the baseline. A
Pod that runs as root inside a sandbox still holds whatever the sandbox grants
it. The sandbox's cost is stated in the [Linux kernel security
constraints](https://kubernetes.io/docs/concepts/security/linux-kernel-security-constraints/)
page: sandboxes "require more compute resources on your nodes".

### Security Profiles Operator: cited, not run

The Security Profiles Operator manages seccomp and AppArmor profiles as
Kubernetes objects, and it can record a workload's syscalls into a profile. It
runs a daemon on each node, so it is a heavy install, and this lab did not run
it. Its
[project](https://github.com/kubernetes-sigs/security-profiles-operator) and its
documentation describe the install and the recording. The lab keeps profiles as
files, which is the mechanism the Operator automates.

### Clean up

The lab deletes its namespaces and the RuntimeClass, removes the node label,
deletes the `runsc` files it copied into the worker, puts back the containerd
configuration it saved, and restarts containerd there. It also removes the
seccomp profiles it copied into the node of the seccomp part. The lab installed
no webhook, no CRD and no chart, so none of those remains to remove.

```sh
kubectl delete ns kernel-attack kernel-restricted --wait=true
kubectl delete runtimeclass gvisor --ignore-not-found
```

<!-- gate: output -->

```
namespace "kernel-attack" deleted
namespace "kernel-restricted" deleted
runtimeclass.node.k8s.io "gvisor" deleted
```

```sh
kubectl label node "$WORKER" example.com/runsc-
docker exec "$WORKER" rm -rf /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /usr/local/bin/gvisor-bin
docker exec "$WORKER" mv /etc/containerd/config.toml.lab-backup /etc/containerd/config.toml
docker exec "$WORKER" systemctl restart containerd
kubectl wait --for=condition=Ready node/"$WORKER" --timeout=240s
```

<!-- gate: output -->

```
node/demo-lab-worker unlabeled
node/demo-lab-worker condition met
```

Then check what remains of the install. The first two numbers count `runsc` or
gVisor files in `/usr/local/bin` and `runsc` entries in the containerd
configuration. The node holds its two original configuration files, and the
cluster holds no RuntimeClass.

```sh
docker exec "$WORKER" sh -c 'ls /usr/local/bin | grep -c -E "runsc|gvisor"; grep -c runsc /etc/containerd/config.toml; ls /etc/containerd'
kubectl get runtimeclass
```

<!-- gate: output -->

```
0
0
config.toml
cri-base.json
No resources found
```

## How it works under the hood

- **A seccomp filter is a BPF program.** It runs on every system call entry,
  before the kernel handles the call. It reads the call's number and its
  argument registers. It returns one action per call: allow, return an errno,
  log and allow, kill or trap. An unprivileged process may install a filter only
  if it has `CAP_SYS_ADMIN` or `no_new_privs` is set. The baseline's
  `allowPrivilegeEscalation: false` sets `no_new_privs`, so that no unprivileged
  process can install a filter that changes how a setuid program runs. Filters
  are never loosened: when several apply, the action with the highest precedence
  wins. See
  [seccomp(2)](https://man7.org/linux/man-pages/man2/seccomp.2.html).
- **A log action leaves the kernel by the audit path.** `SCMP_ACT_LOG` writes an
  audit record, `type=1326`, for each call. When no audit daemon consumes the
  records, the kernel prints them, and the printk path is rate-limited. The lab
  saw 515 records dropped in one window. A consumer that reads the audit socket
  keeps them all.
- **AppArmor attaches on exec.** A profile is loaded into the kernel by
  `apparmor_parser`, through the AppArmor filesystem. A process that execs
  under the profile is confined by path rules, and a `deny` rule overrides an
  `allow` rule. The `file,` rule in the lab profile allows everything, and the
  two `deny` lines take back execute under `/tmp` and `/dev/shm`.
- **The kubelet refuses a Pod it cannot confine.** In the lab the API server
  admitted the Pod and the scheduler placed it. Then the kubelet on the node
  refused it, and the Pod ended in phase `Failed` with the reason `AppArmor`.
  The events name the two components: `default-scheduler` and `kubelet`.
- **The kubelet resolves a `Localhost` path.** The path is relative to the
  kubelet's seccomp root, `/var/lib/kubelet/seccomp`, and the kubelet hands the
  file to containerd, which applies it through runc. A missing file is found
  when the container starts, not at admission.
- **A RuntimeClass selects a handler.** The `handler` names a runtime that
  containerd knows by name in its configuration. The Pod's sandbox and its
  containers then run under that runtime, and the host kernel answers only the
  calls the sandbox passes through.

## Production notes

Managed clusters decide the node image and the default seccomp and AppArmor
behaviour for you, which [the managed Kubernetes
model](../10-cloud-and-managed-kubernetes/01-managed-kubernetes-model.md)
explains, and production runtime detection is covered in [runtime defence and
container
security](../14-eks-in-production-a-to-z/13-runtime-defense-and-container-security.md).

## Quick Reference

The secure forms only. Each block is a fragment. The baseline in
[01.01](../01-core-workloads/01-pods.md#baseline) and the lab above show the
complete Pods.

```yaml
# spec.securityContext: the seccomp filter the Pod runs under
seccompProfile:
  type: RuntimeDefault          # or type: Localhost, with localhostProfile: profiles/<name>.json
# spec.containers[].securityContext: the AppArmor profile, loaded on every node
appArmorProfile:
  type: Localhost
  localhostProfile: <loaded profile name>
# spec: a sandboxed runtime, named by a cluster-scoped RuntimeClass
runtimeClassName: <runtimeclass name>
```

| Question | Command or field |
|---|---|
| Is this process filtered? | `grep "^Seccomp:" /proc/self/status`: `2` means a filter is installed |
| Is AppArmor available on the node? | `test -d /sys/kernel/security/apparmor` inside the node |
| Which AppArmor profiles are loaded? | `cat /sys/kernel/security/apparmor/profiles` inside the node |
| Did the node accept the profile? | `kubectl get pod <pod> -o jsonpath='{.status.reason}'`: `AppArmor` means the node refused the Pod |
| Which kernel answers this Pod? | `kubectl exec <pod> -- uname -r`, against `uname -r` in the node |
| Would the namespace admit this Pod? | `kubectl apply --dry-run=server -f pod.yaml` |

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise;
> the answer is the check.

1. **The unconfined Pod and the `RuntimeDefault` Pod both drop every
   capability. Only one of them could make the personality call. Why?**
   <details><summary>Show answer</summary>

   The call with `ADDR_NO_RANDOMIZE` needs no capability, so capabilities
   cannot be the difference. The unconfined Pod has `Seccomp: 0`, no filter at
   all, and the call succeeds. The `RuntimeDefault` Pod has `Seccomp: 2`, and
   its filter returns `EPERM` for that argument value. The filter is the only
   thing that differs.

   </details>

2. **The audit log in this lab showed eight records and 515 dropped. A
   teammate proposes building the enforcing allowlist from the journal. What do
   you tell them, and what would make the log usable?**
   <details><summary>Show answer</summary>

   Do not build an allowlist from that log. The records that survived are a
   small, arbitrary sample, and an allowlist built from them breaks any call
   that was dropped. The kernel dropped the records because nothing consumed
   the audit path, and the printk fallback is rate-limited. Run an audit daemon,
   or a pipeline that reads every record from the audit socket, and confirm the
   count of dropped records is zero before deriving the list. Then test the
   result under enforce.

   </details>

3. **A process copies busybox into `/tmp` in a `restricted` Pod and runs it.
   The baseline sets `readOnlyRootFilesystem`. Why does the baseline not stop
   it, and which control does?**
   <details><summary>Show answer</summary>

   The baseline makes the root filesystem read-only, but `/tmp` is an `emptyDir`
   volume, which is writable, and nothing in the baseline forbids executing from
   it. An AppArmor profile with `deny /tmp/** x` refuses the execute, and the
   Pod names that profile in `securityContext.appArmorProfile`. This part is
   cited, not run on this cluster, so the claim rests on the profile and the
   AppArmor tutorial.

   </details>

4. **A Pod in a `restricted` namespace names an AppArmor `Localhost` profile
   that its node has not loaded. What happens, and why is that the behaviour
   you want?**
   <details><summary>Show answer</summary>

   Admission lets it through, because `restricted` allows a `Localhost`
   profile, and the scheduler places it. The kubelet on the node then refuses
   it: in the lab the Pod ended in phase `Failed` with the reason `AppArmor`
   and the message "Cannot enforce AppArmor". It did not start without the
   profile. A control that fails open leaves a workload unconfined while the
   manifest looks protected, so the refusal is what lets you trust the field.
   The profile has to be loaded on every node where the Pod can land.

   </details>

5. **Inside the gVisor Pod, `grep Seccomp: /proc/self/status` prints
   `Seccomp: 0`, although the spec sets `RuntimeDefault`. A teammate concludes
   the Pod runs with no seccomp filter. What do you tell them?**
   <details><summary>Show answer</summary>

   The line is read from the sandbox's kernel, not the host's, and the lab saw
   `0` there without finding out why. So the line cannot show that the filter
   is absent, and it cannot show that it is present. The check that worked for
   ordinary Pods does not carry over to a sandboxed one. Keep the baseline
   field set, because admission still checks it, and judge the sandbox by what
   it does: its own kernel, shown by `uname -r`, answers the Pod's system
   calls.

   </details>

## Further reading

- [Restrict a container's syscalls with seccomp](https://kubernetes.io/docs/tutorials/security/seccomp/):
  the `Localhost` profile path and the audit profile.
- [Restrict a container's access with AppArmor](https://kubernetes.io/docs/tutorials/security/apparmor/):
  the `appArmorProfile` field and the node requirement.
- [Linux kernel security constraints](https://kubernetes.io/docs/concepts/security/linux-kernel-security-constraints/):
  seccomp, AppArmor, SELinux and sandboxed runtimes in one page.
- [RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/):
  the handler and the Pod field that selects it.
- [seccomp(2)](https://man7.org/linux/man-pages/man2/seccomp.2.html) and
  [AppArmor](https://apparmor.net/): the kernel interfaces the policies use.
- [gVisor](https://gvisor.dev/docs/) and its
  [install guide](https://gvisor.dev/docs/user_guide/install/).
- [Security Profiles Operator](https://github.com/kubernetes-sigs/security-profiles-operator).
