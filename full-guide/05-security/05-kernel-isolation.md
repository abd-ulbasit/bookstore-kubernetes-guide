# Kernel isolation: seccomp, AppArmor, SELinux, sandboxed runtimes

> Four ways to shrink what a container can ask the kernel to do, shown on a
> kind cluster where the lab host allows it: a seccomp filter built from an
> audit log, an AppArmor profile that refuses to run a program from a writable
> volume, and a gVisor sandbox chosen through a RuntimeClass. SELinux and the
> Security Profiles Operator are cited, not run.

**Estimated time:** ~35 min read · ~60 min hands-on (the lab is scripted)
**Prerequisites:** [Part 05 ch.02](02-pod-security.md): the baseline's
seccomp and read-only root, and the escapes `restricted` closes ·
[Part 00 ch.02](../00-foundations/02-containers-and-images.md): namespaces,
cgroups and capabilities
**You'll know after this:** • read a seccomp profile and say which system
calls it allows · • run a workload under audit and read what the kernel
logged · • enforce a profile that refuses one call, and say why an allowlist
needs a complete audit · • explain how an AppArmor profile stops a program
running from `/tmp` (cited, not run here) · • say why a kind node cannot show
a host-kernel escape · • select a sandbox with a RuntimeClass

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
to the node. The lab shows two of these controls working, the first two rows.
The rest are cited, and the text after the table says why none of them ran. It
runs no kernel exploit.

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
needs AppArmor loaded on the node. The lab loads no profile, because a profile
is kernel state shared with the Docker host, so that row is cited. The fourth
and fifth rows need a runtime the lab host does not provide by default, so
their install is described and not run here.

## What a kind node can and cannot show

A kind node is a container. It runs systemd, containerd and the kubelet, and it
shares the lab host's kernel. That fact sets what this lab can show truthfully.

- **A profile loaded in a node is loaded into the host's kernel.** AppArmor
  profiles are kernel state, shared by every container on the host. The lab
  therefore loads none. An earlier version loaded one and removed it at the
  end, but the host's policy still changed while it was loaded, so that step
  was removed.
- **A payload in a Pod is a process of the host's kernel.** A kernel escape
  would reach the lab host, not just the node. The lab runs no kernel exploit.
  Its payloads read `/proc`, copy busybox into a Pod's `/tmp`, run it, and ask
  for one personality call that a filter refuses. None of them reads or writes
  outside the node and the lab's own Pods.
- **A sandbox runs on the same host.** gVisor's `runsc` is a process on the lab
  host. It changes which kernel answers the Pod's system calls, not where the
  process runs.

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

- **Tier A, partly run.** The seccomp steps ran on a kind cluster named
  `sf-pilot`, with a node on Kubernetes v1.37.0 and containerd 2.3.4, on a Linux
  host whose kernel is 7.0.0 with AppArmor enabled. `kubectl` is v1.37.2. The
  lab's config names its cluster `security-lab-kernel`, so the captured node
  name differs from the one the commands would print. The gVisor install did
  not run, and the AppArmor steps are cited (see below). This lab has
  not been run on macOS, which has no AppArmor.
- **Script and transcript.**
  [`labs/05-05.sh`](../examples/security-lab/labs/05-05.sh) runs the steps
  below and deletes what it creates. Its recorded output is
  [`evidence/05-05.txt`](../examples/security-lab/evidence/05-05.txt), run with
  `P05_RUNTIME=0`, the mode that changes no node runtime. Run it only against a
  cluster you own. It refuses any kubectl context that is not `kind-*`.
- **Namespaces.** Two, named `kernel-attack` and `kernel-restricted` in the
  commands below. The captured output names them `kernel-attack` and
  `kernel-restricted`, the lab's own names. `kernel-attack` enforces `privileged`,
  because one Pod in it runs unconfined. It holds that one marked, insecure Pod
  only. `kernel-restricted` enforces, audits and warns on `restricted`, and
  holds every other Pod. A namespace above `restricted` is an exception. Its
  reason is that this Pod must run unconfined to show what unconfined allows.
  Its owning chapter is this one. Its expiry is 2027-10-31, within twelve
  months. The registry that 05.09 keeps is not in this repository yet, so the
  exception is recorded here <!-- link-later: 05.09 -->.
- **What did not run.** The AppArmor load, which the lab does not do (see the
  AppArmor section). Step 6, gVisor, needs a runtime installed into the node,
  which restarts the node's containerd and interrupts the Pods on it. Both are
  described below and cited, not shown as results.
- **What did not work the first time.** The audit step did not produce what
  the lab wanted, and the chapter says what it produced instead. A fresh kind
  cluster on the lab host stalled in `kubeadm init` on six attempts, so the
  gVisor step had no node to run on.

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
the node, and the lab does not try. The node has no SELinux filesystem, so
this lab cannot show SELinux labels. Both results are why the AppArmor and
SELinux parts below are cited, not run, on this cluster.

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

### AppArmor: a profile the node cannot load on this cluster

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

The lab does not load this profile. A profile is kernel state, and the kernel
is the Docker host's, so a load from the node would change the host's policy.
Step 5 runs read-only checks instead: whether the node exposes the AppArmor
filesystem, and whether it has `apparmor_parser`. The expected result on a node
that exposes both is a refusal from the policy for a copy of busybox run from
`/tmp`, and a `DENIED` record in the kernel log. That result is cited, not
shown, because the captured node has neither.

<!-- gate: output -->

```
apparmor-securityfs-absent
apparmor_parser-absent
```

The kind config in the repository,
[`kind/kernel-cluster.yaml`](../examples/security-lab/kind/kernel-cluster.yaml),
mounts no host filesystem, so this lab cannot show the profile on a node. The
mechanism stands on the AppArmor tutorial. That page states that the field has
been stable since Kubernetes 1.31, and that a profile must be loaded on every
node where a Pod can land. What the kubelet does with a Pod whose profile is
missing is covered there, and this lab did not reach that point.

### SELinux: cited, not run

SELinux is also a Linux Security Module, and it labels files and processes
rather than naming paths. Kubernetes sets the label through
`securityContext.seLinuxOptions`. Step 1 showed that the node exposes no
SELinux filesystem, so this lab cannot apply a label and see it enforced. The
mechanism and the field are in the [Linux kernel security
constraints](https://kubernetes.io/docs/concepts/security/linux-kernel-security-constraints/)
page. Distributions that enable SELinux by default are the ones where the
field matters in practice.

### gVisor: a sandboxed runtime through a RuntimeClass: not run

The other kind of boundary changes which kernel answers. gVisor's `runsc`
runs a user-space kernel for the Pod, so most of the Pod's system calls are
answered by that kernel and never reach the host's. A RuntimeClass names the
runtime. Its `handler` is the name containerd maps to a runtime binary, so a
Pod selects the sandbox with `runtimeClassName` and the cluster-scoped
RuntimeClass decides which handler runs it.

Step 6 of the script installs gVisor into a throwaway node. It fetches the
release tarball and its SHA-512 checksum from the upstream bucket, verifies
the checksum, copies `runsc`, its shim and its sidecar binaries into the node,
adds a `runsc` entry to the node's containerd configuration, restarts
containerd, and then runs a Pod through a RuntimeClass with `handler: runsc`.
The Pod reports a kernel of its own. Step 6 did not run. Installing it means
restarting the node's containerd, which would interrupt every Pod on that
node, so the captured run did not do it. A fresh kind node has also stalled in
`kubeadm init` on the lab host. The install is described in the [gVisor
install guide](https://gvisor.dev/docs/user_guide/install/), and the sandbox's
cost is stated in the [Linux kernel security
constraints](https://kubernetes.io/docs/concepts/security/linux-kernel-security-constraints/)
page: sandboxes "require more compute resources on your nodes".

Two limits hold even when a sandbox runs. The sandbox is still a process on the
lab host, so it changes which kernel answers the Pod's calls, not where the
process lives. And a sandbox does not replace the baseline. A Pod that runs as
root inside a sandbox still holds whatever the sandbox grants it.

### Security Profiles Operator: cited, not run

The Security Profiles Operator manages seccomp and AppArmor profiles as
Kubernetes objects, and it can record a workload's syscalls into a profile. It
runs a daemon on each node, so it is a heavy install, and this lab did not run
it. Its
[project](https://github.com/kubernetes-sigs/security-profiles-operator) and its
documentation describe the install and the recording. The lab keeps profiles as
files, which is the mechanism the Operator automates.

### Clean up

The lab deletes its namespaces and removes the seccomp profiles it copied into
the node. It prints what remains.

<!-- gate: output -->

```
namespace "p05-05-attack" deleted
namespace "p05-05-restricted" deleted
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
