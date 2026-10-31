#!/usr/bin/env bash
# Lab 05.05: Kernel isolation. Tier A (kind on a Linux host with AppArmor).
#
# Run this ONLY against a kind cluster you own, created from
# kind/kernel-cluster.yaml (named security-lab-kernel). The lab creates two
# namespaces of its own: kernel-attack, labelled `privileged` for the one Pod that
# runs unconfined, and kernel-restricted, labelled `restricted`, which holds every
# hardened Pod. It copies seccomp profiles into the kind node, reads the node's
# AppArmor filesystem but loads no profile, and, with P05_RUNTIME=1, runs one
# gVisor Pod through a RuntimeClass. Everything it created is deleted at the end.
#
# The recorded run named the two namespaces p05-05-attack and p05-05-restricted.
# This file and the transcript carry the chapter's names, kernel-attack and
# kernel-restricted. The exceptions registry reads Pod Security labels from
# scripts and transcripts, and it registers the chapter's namespace, not a lab
# name. That rename is the only edit made after the run.
#
# A kind node is a container. It shares the lab host's kernel, so a seccomp
# filter applies to the node's processes, and an AppArmor profile would enter
# that kernel too, so this lab loads none. The payloads touch only the node's
# processes and files and the lab's own Pods: they read /proc, copy busybox into
# a Pod's /tmp and run it, and ask the kernel for one personality call that a
# seccomp filter refuses. None of them reaches the lab host's files, another
# container or another cluster, and no kernel exploit runs.
#
# The one deliberately insecure manifest is unconfined. It runs in
# kernel-attack only.
#
# Two modes. By default (P05_RUNTIME=1) it also runs the gVisor step, which
# installs runsc into the node and restarts the node's containerd, so use a
# throwaway cluster from kind/kernel-cluster.yaml for it. With P05_RUNTIME=0 it
# runs the seccomp steps and read-only checks of the AppArmor and runtime
# prerequisites, and changes no node runtime.
#
# Step 6 (gVisor) has not run to completion. A fresh kind node on the lab host
# stalled in kubeadm init when the chapter was written, so the evidence file
# records only the steps that ran. The chapter says which parts are not run.
set +e

BB=busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
here=$(cd "$(dirname "$0")/.." && pwd)   # examples/security-lab/

# Read a command from stdin, print it as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$NODE" ]; then echo "refusing to run: the cluster has no node" >&2; exit 2; fi

work=$(mktemp -d) && cd "$work" || exit 1

# Copy a local file into the kind node. Streaming over stdin works on any
# Docker engine, local or remote, where a bind mount would not.
node_put() { # <local file> <path inside the node>
  docker exec -i "$NODE" sh -c 'mkdir -p "$(dirname "$1")" && cat > "$1"' sh "$2" < "$1"
}

trap 'cd / && rm -rf "$work"' EXIT

kubectl delete ns kernel-attack kernel-restricted --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete runtimeclass gvisor --ignore-not-found >/dev/null 2>&1

echo "## node: $NODE, kubectl $(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion/{print $2; exit}')"
echo

echo '## step 1: the node shares the lab host kernel, and sees AppArmor'
run <<CMD
docker exec $NODE uname -r
docker exec $NODE cat /sys/module/apparmor/parameters/enabled
docker exec $NODE sh -c 'test -d /sys/kernel/security/apparmor && echo apparmor-securityfs-present || echo apparmor-securityfs-absent'
docker exec $NODE sh -c 'test -e /sys/fs/selinux && echo selinux-present || echo selinux-absent'
CMD
RUNTIME=${P05_RUNTIME:-1}

echo '## step 2: two namespaces, one that permits everything and one restricted'
run <<'CMD'
kubectl create ns kernel-attack
kubectl label ns kernel-attack pod-security.kubernetes.io/enforce=privileged
kubectl create ns kernel-restricted
kubectl label ns kernel-restricted \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
CMD
# A Pod that names no ServiceAccount is refused until the controller has made
# the namespace's `default` one, so a scripted apply has to wait for it.
for ns in kernel-attack kernel-restricted; do
  until kubectl get sa default -n "$ns" >/dev/null 2>&1; do sleep 1; done
done

cat >unconfined.yaml <<YAML
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
      image: $BB
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
YAML

cat >runtimedefault.yaml <<YAML
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
      image: $BB
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
YAML

echo '## step 3: seccomp Unconfined against RuntimeDefault, for one personality call'
run <<'CMD'
kubectl apply -f unconfined.yaml
kubectl apply -f runtimedefault.yaml
kubectl -n kernel-attack wait --for=condition=Ready pod/unconfined --timeout=180s
kubectl -n kernel-restricted wait --for=condition=Ready pod/runtimedefault --timeout=180s
CMD

echo '## step 3a: the Unconfined Pod: no filter, the personality call succeeds'
run <<'CMD'
kubectl -n kernel-attack exec unconfined -- sh -c 'grep "^Seccomp:" /proc/self/status | tr "\t" " "; setarch linux64 -R /bin/true 2>&1; echo exit=$?'
CMD

echo '## step 3b: the RuntimeDefault Pod: the same call is refused by the filter'
run <<'CMD'
kubectl -n kernel-restricted exec runtimedefault -- sh -c 'grep "^Seccomp:" /proc/self/status | tr "\t" " "; setarch linux64 -R /bin/true 2>&1; echo exit=$?'
CMD

echo '## step 3c: restricted refuses the Unconfined spec at admission (server dry run)'
cat >unconfined-restricted.yaml <<YAML
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
      image: $BB
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
YAML
run <<'CMD'
kubectl apply --dry-run=server -f unconfined-restricted.yaml
CMD

echo '## step 4: audit, then enforce. A custom Localhost profile, logged first'
node_put "$here/profiles/audit.json" /var/lib/kubelet/seccomp/profiles/audit.json
cat >audit.yaml <<YAML
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
      image: $BB
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
YAML
run <<'CMD'
kubectl apply -f audit.yaml
kubectl -n kernel-restricted wait --for=condition=Ready pod/audit --timeout=180s
CMD

# The audit profile's default action is SCMP_ACT_LOG: every syscall is logged
# and allowed. Note the time, run a short workload, then read the kernel's audit
# records from the host's kernel log. The journal is read because dmesg is
# restricted on many hosts. -o cat keeps only the record text, so the transcript
# carries no host name.
SINCE=$(date +%s)
run <<'CMD'
kubectl -n kernel-restricted exec audit -- sh -c 'id -u; cat /etc/passwd >/dev/null; ls / >/dev/null; echo done'
CMD
# The kernel prints its count of dropped records only when it next prints one,
# so wait out the rate-limit window and make one more exec to flush the count.
sleep 6
kubectl -n kernel-restricted exec audit -- true >/dev/null 2>&1
journalctl -k -o cat --since "@$SINCE" --no-pager > audit-journal.txt 2>/dev/null
echo '## step 4a: the kernel log: the records it printed, and the ones it dropped'
run <<'CMD'
grep -c 'type=1326' audit-journal.txt
grep -c 'exe="/bin/busybox"' audit-journal.txt
grep 'callbacks suppressed' audit-journal.txt | tail -1
CMD

# Enforce. An allowlist built from this audit would be the stronger profile,
# but the records above are incomplete: the kernel dropped most of them, and an
# allowlist built from a partial log would break the workload. This lab
# therefore enforces one call, personality, which step 3 showed RuntimeDefault
# refuses. Every other call stays allowed, so this profile is weaker than
# RuntimeDefault. The Pod is a deliberate exception to the baseline. It installs
# the profile on the node.
echo '## step 4b: enforce profile: allow everything except personality, which returns EPERM'
node_put "$here/profiles/deny-personality.json" /var/lib/kubelet/seccomp/profiles/deny-personality.json
run <<CMD
docker exec $NODE cat /var/lib/kubelet/seccomp/profiles/deny-personality.json
CMD

cat >enforce.yaml <<YAML
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
      image: $BB
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
YAML
run <<'CMD'
kubectl apply -f enforce.yaml
kubectl -n kernel-restricted wait --for=condition=Ready pod/enforce --timeout=180s
CMD
echo '## step 4c: enforce: the workload still runs, and the personality call is refused'
run <<'CMD'
kubectl -n kernel-restricted exec enforce -- sh -c 'grep "^Seccomp:" /proc/self/status | tr "\t" " "; id -u; cat /etc/passwd >/dev/null && echo workload-ok; setarch linux64 -R /bin/true 2>&1; echo exit=$?'
CMD

echo '## step 5: AppArmor: read-only checks, nothing loaded. A profile would enter the host kernel.'
run <<CMD
docker exec \$NODE sh -c 'test -d /sys/kernel/security/apparmor && echo apparmor-securityfs-present || echo apparmor-securityfs-absent'
docker exec \$NODE sh -c 'command -v apparmor_parser || echo apparmor_parser-absent'
CMD
if [ "$RUNTIME" = 1 ]; then
echo '## step 6: SELinux and sandboxed runtimes: gVisor, through a RuntimeClass'
echo '## SELinux is not run here: step 1 shows the node has no SELinux filesystem.'
echo
# The gVisor install follows the upstream instructions, with the tarball and its
# checksum fetched from the release bucket and verified before anything runs.
run <<'CMD'
URL=https://storage.googleapis.com/gvisor/releases/release/latest/$(uname -m)
curl -fsSLO "$URL/gvisor.tar.zstd" && curl -fsSLO "$URL/gvisor.tar.zstd.sha512" && sha512sum -c gvisor.tar.zstd.sha512
tar --zstd -tf gvisor.tar.zstd
CMD
mkdir -p gvisor-dist && tar --zstd -xf gvisor.tar.zstd -C gvisor-dist
run <<'CMD'
gvisor-dist/runsc --version | head -1
CMD
tar -C gvisor-dist -cf - runsc containerd-shim-runsc-v1 gvisor-bin | docker exec -i "$NODE" tar -C /usr/local/bin -xf -
run <<'CMD'
docker exec $NODE sh -c 'ls /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 && /usr/local/bin/runsc --version | head -1'
CMD
docker exec -i "$NODE" sh -c 'cat >> /etc/containerd/config.toml' <<'TOML'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
TOML
run <<CMD
docker exec $NODE systemctl restart containerd
kubectl wait --for=condition=Ready node/$NODE --timeout=240s
CMD

cat >runtimeclass.yaml <<YAML
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
YAML
cat >gvisor.yaml <<YAML
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
      image: $BB
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
YAML
run <<'CMD'
kubectl apply -f runtimeclass.yaml
kubectl apply -f gvisor.yaml
kubectl -n kernel-restricted wait --for=condition=Ready pod/gvisor --timeout=240s
CMD
echo '## step 6a: the gVisor Pod reports a kernel of its own; the node reports the host kernel'
run <<'CMD'
kubectl -n kernel-restricted exec gvisor -- sh -c 'uname -r; dmesg | head -2'
docker exec $NODE uname -r
CMD

else
echo '## step 6: gVisor: not installed. Its install restarts the node containerd, which would interrupt the Pods on the node.'
echo
fi

echo '## step 7: cleanup: the namespaces, the RuntimeClass and the seccomp profiles'
run <<CMD
kubectl delete ns kernel-attack kernel-restricted --wait=true
kubectl delete runtimeclass gvisor --ignore-not-found
docker exec $NODE rm -f /var/lib/kubelet/seccomp/profiles/audit.json /var/lib/kubelet/seccomp/profiles/deny-personality.json
CMD
echo '## not run in this lab: Security Profiles Operator (cited in the chapter).'
