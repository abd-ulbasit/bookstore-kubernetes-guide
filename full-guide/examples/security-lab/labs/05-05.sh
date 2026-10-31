#!/usr/bin/env bash
# Lab 05.05: Kernel isolation. Tier A (kind on a Linux host with AppArmor).
#
# Run this ONLY against a kind cluster you own: kind/kernel-cluster.yaml, or any
# kind cluster of yours. The lab creates two namespaces of its own:
# kernel-attack, labelled `privileged` for the one Pod that runs unconfined, and
# kernel-restricted, labelled `restricted`, which holds every hardened Pod. It
# copies seccomp profiles into a kind node, asks every node whether it can load
# an AppArmor profile, and, with P05_RUNTIME=1, installs gVisor's runsc into one
# node and runs one Pod through a RuntimeClass. Everything it created or
# installed is removed at the end.
#
# A kind node is a container. It shares the lab host's kernel, so a seccomp
# filter applies to the node's processes, and an AppArmor profile loaded from a
# node would enter that kernel too. This lab loads none: no node has
# apparmor_parser, and step 5 records what the kubelet does when a Pod names a
# profile that no node holds. The payloads touch only the node's processes and
# files and the lab's own Pods: they read /proc, copy busybox into a Pod's /tmp
# and run it, and ask the kernel for one personality call that a seccomp filter
# refuses. None of them reaches the lab host's files, another container or
# another cluster, and no kernel exploit runs.
#
# The one deliberately insecure manifest is unconfined. It runs in
# kernel-attack only.
#
# Switches.
#   P05_RUNTIME=1 (default) runs step 6. It installs runsc and its shim into
#     /usr/local/bin of one node, adds a runsc entry to that node's containerd
#     configuration, and restarts that node's containerd, which interrupts the
#     Pods on the node for a moment. Step 7 puts the node back. Use a cluster
#     you can lose. With P05_RUNTIME=0 no node runtime changes.
#   P05_SECCOMP=1 (default) runs steps 3 and 4. They read the kernel log of the
#     machine that runs this script (journalctl -k) and copy a Localhost
#     profile into one node, so they suit a single-node cluster on that
#     machine. P05_SECCOMP=0 skips them.
#   GVISOR_RELEASE and GVISOR_SHA512 name the gVisor release and the SHA-512 of
#     its tarball for the node's architecture. The defaults pin the x86_64
#     build that was recorded.
#
# The recorded run is in two parts, and the transcript says where they join.
# Steps 3 and 4 ran earlier on a single-node cluster, with the two namespaces
# named p05-05-attack and p05-05-restricted. This file and the transcript carry
# the chapter's names, kernel-attack and kernel-restricted. The exceptions
# registry reads Pod Security labels from scripts and transcripts, and it
# registers the chapter's namespace, not a lab name. That rename is the only
# edit made to the recorded lines. Steps 1, 2 and 5 to 7 ran later on a
# three-node cluster, with P05_SECCOMP=0 and the chapter's names.
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

# macOS has shasum and no sha512sum. A one-line shim keeps the commands below
# the ones a Linux reader types.
if ! command -v sha512sum >/dev/null 2>&1; then
  mkdir -p "$work/bin" && printf '#!/bin/sh\nexec shasum -a 512 "$@"\n' >"$work/bin/sha512sum" \
    && chmod +x "$work/bin/sha512sum" && PATH="$work/bin:$PATH"
fi

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
SECCOMP=${P05_SECCOMP:-1}

# The node that gets runsc: a worker if the cluster has one, else the only node.
WORKER=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
WORKER=${WORKER:-$NODE}

GVISOR_RELEASE=${GVISOR_RELEASE:-20261026.0}
ARCH=$(docker exec "$WORKER" uname -m 2>/dev/null)
if [ "$ARCH" = x86_64 ]; then
  GVISOR_SHA512=${GVISOR_SHA512:-e6aa030fb8379fe92b53e9b8b696419e0dce8a3bbcc7d4c1cf76b2ea3d6569eabd7360e694deda6ccbdcd77095b3e82ca0f90a3d8fd13a3e5d6b11cd29fe4649}
fi
if [ "$RUNTIME" = 1 ] && [ -z "$GVISOR_SHA512" ]; then
  echo "refusing to run: no pinned SHA-512 for '$ARCH'; set GVISOR_SHA512 or P05_RUNTIME=0" >&2
  exit 2
fi

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

if [ "$SECCOMP" = 1 ]; then
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

fi

echo '## step 5: AppArmor: no node can load a profile, and the kubelet refuses a Pod that names one'
run <<'CMD'
for n in $(kubectl get nodes -o name | cut -d/ -f2); do docker exec "$n" sh -c 'command -v apparmor_parser || echo apparmor_parser-absent'; done
docker exec $WORKER apparmor_parser --version
CMD

cat >apparmor.yaml <<YAML
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
      image: $BB
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
YAML
echo '## step 5a: a Pod that names a Localhost profile no node holds'
run <<'CMD'
kubectl apply -f apparmor.yaml
kubectl -n kernel-restricted wait --for=jsonpath='{.status.phase}'=Failed pod/apparmor --timeout=120s
kubectl -n kernel-restricted get pod apparmor -o jsonpath='{.status.reason}{"\n"}{.status.message}{"\n"}'
kubectl -n kernel-restricted get events --field-selector involvedObject.name=apparmor --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.reportingComponent}{" "}{.reason}{"\n"}{end}'
CMD

if [ "$RUNTIME" = 1 ]; then
echo '## step 6: SELinux and sandboxed runtimes: gVisor, through a RuntimeClass'
echo '## SELinux is not run here: step 1 shows the node has no SELinux filesystem.'
echo "## runtime node: $WORKER, gVisor release $GVISOR_RELEASE for $ARCH"
echo
# The release is pinned and its SHA-512 is checked twice: against the file
# published beside the tarball, and against the digest pinned in this script.
# Both come from the same bucket, so they catch a damaged download, not a
# compromised release. The tarball is extracted in this script's own empty
# directory, never beside the script.
run <<'CMD'
URL=https://storage.googleapis.com/gvisor/releases/release/$GVISOR_RELEASE/$ARCH
curl -fsSLO "$URL/gvisor.tar.zstd" -O "$URL/gvisor.tar.zstd.sha512"
sha512sum -c gvisor.tar.zstd.sha512
echo "$GVISOR_SHA512  gvisor.tar.zstd" | sha512sum -c -
tar --zstd -tf gvisor.tar.zstd
CMD
mkdir gvisor-dist && tar --zstd -xf gvisor.tar.zstd -C gvisor-dist
docker exec "$WORKER" cp -p /etc/containerd/config.toml /etc/containerd/config.toml.lab-backup
run <<'CMD'
tar -C gvisor-dist -cf - runsc containerd-shim-runsc-v1 gvisor-bin | docker exec -i $WORKER tar --no-same-owner -C /usr/local/bin -xf -
docker exec $WORKER /usr/local/bin/runsc --version | head -1
CMD
docker exec -i "$WORKER" sh -c 'cat >> /etc/containerd/config.toml' <<'TOML'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
TOML
echo '## step 6a: the node learns the runtime: a containerd entry, a restart, a node label'
run <<'CMD'
docker exec $WORKER tail -3 /etc/containerd/config.toml
docker exec $WORKER systemctl restart containerd
kubectl wait --for=condition=Ready node/$WORKER --timeout=240s
kubectl label node $WORKER example.com/runsc=installed
CMD

cat >runtimeclass.yaml <<YAML
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    example.com/runsc: installed
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
echo '## step 6b: a RuntimeClass and a Pod that selects it'
run <<'CMD'
kubectl apply -f runtimeclass.yaml
kubectl apply -f gvisor.yaml
kubectl -n kernel-restricted wait --for=condition=Ready pod/gvisor --timeout=240s
CMD
echo '## step 6c: the Pod reports a kernel of its own; the node reports the lab host kernel'
run <<'CMD'
kubectl -n kernel-restricted get pod gvisor -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl -n kernel-restricted exec gvisor -- sh -c 'uname -r; cat /proc/version; dmesg | head -3'
docker exec $WORKER uname -r
CMD
echo '## step 6d: the sandbox is processes on the node, and a seccomp check reads differently inside it'
run <<'CMD'
docker exec $WORKER sh -c 'ps -eo comm | grep -E "^(runsc|gvisor_sentry)" | sort | uniq -c'
kubectl -n kernel-restricted exec gvisor -- sh -c 'grep "^Seccomp:" /proc/self/status | tr "\t" " "; setarch linux64 -R /bin/true 2>&1; echo exit=$?'
CMD
else
echo '## step 6: gVisor: not installed (P05_RUNTIME=0). Its install restarts the node containerd, which interrupts the Pods on the node.'
echo
fi

echo '## step 7: cleanup: the namespaces, the RuntimeClass, the node label, the profiles and the runtime install'
run <<'CMD'
kubectl delete ns kernel-attack kernel-restricted --wait=true
kubectl delete runtimeclass gvisor --ignore-not-found
CMD
if [ "$SECCOMP" = 1 ]; then
run <<CMD
docker exec $NODE rm -f /var/lib/kubelet/seccomp/profiles/audit.json /var/lib/kubelet/seccomp/profiles/deny-personality.json
CMD
fi
if [ "$RUNTIME" = 1 ]; then
run <<'CMD'
kubectl label node $WORKER example.com/runsc-
docker exec $WORKER rm -rf /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /usr/local/bin/gvisor-bin
docker exec $WORKER mv /etc/containerd/config.toml.lab-backup /etc/containerd/config.toml
docker exec $WORKER systemctl restart containerd
kubectl wait --for=condition=Ready node/$WORKER --timeout=240s
CMD
echo '## step 7a: what remains of the install'
run <<'CMD'
docker exec $WORKER sh -c 'ls /usr/local/bin | grep -c -E "runsc|gvisor"; grep -c runsc /etc/containerd/config.toml; ls /etc/containerd'
kubectl get runtimeclass
CMD
fi
echo '## not run in this lab: AppArmor profile load and denial, SELinux, Security Profiles Operator (cited in the chapter).'
