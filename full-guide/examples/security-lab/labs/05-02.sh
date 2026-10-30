#!/usr/bin/env bash
# Lab 05.02 — Pod security and container escape. Tier A (kind).
#
# Run this ONLY against a kind cluster you own. It creates two throwaway
# namespaces (psa-lab permits everything, psa-restricted enforces
# `restricted`), runs container-escape attacks that reach the kind NODE,
# then shows the restricted namespace refusing every one of them at
# admission. It deletes both namespaces at the end.
#
# Every escape stops at the kind node, which is itself a container: nothing
# here targets the machine that runs kind, and nothing touches another
# container. Host-kernel escapes are a tier-B lab, out of this chapter.
#
# The attack manifests are deliberately insecure and live only in psa-lab.
set +e

# busybox:1.36, pinned by digest (the image 01.01 uses).
BB=busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
W="kubectl wait -n psa-lab --for=condition=Ready --timeout=90s"

c() { echo "\$ $1"; }   # print a command the way the chapter shows it
nl() { echo; }

work=$(mktemp -d) && cd "$work" || exit 1

kubectl delete ns psa-lab psa-restricted --ignore-not-found --wait=true >/dev/null 2>&1

echo '## step 1 — one namespace that permits everything, one that enforces restricted'
c 'kubectl create ns psa-lab && kubectl label ns psa-lab pod-security.kubernetes.io/enforce=privileged'
kubectl create ns psa-lab >/dev/null && kubectl label ns psa-lab pod-security.kubernetes.io/enforce=privileged 2>&1; nl
c 'kubectl create ns psa-restricted && kubectl label ns psa-restricted pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted'
kubectl create ns psa-restricted >/dev/null && kubectl label ns psa-restricted pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted 2>&1; nl

echo '## step 2 — privileged: full capabilities over the node kernel'
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
c 'kubectl apply -f esc-privileged.yaml && kubectl wait -n psa-lab --for=condition=Ready pod/escape-privileged --timeout=90s'
kubectl apply -f esc-privileged.yaml && $W pod/escape-privileged 2>&1; nl
c 'kubectl exec -n psa-lab escape-privileged -- grep -E "^Cap(Eff|Bnd)" /proc/self/status | sed "s/\\t/ /"'
kubectl exec -n psa-lab escape-privileged -- grep -E "^Cap(Eff|Bnd)" /proc/self/status 2>&1 | sed 's/\t/ /'; nl

echo '## step 3 — hostPath / : read every file on the node, including the cluster CA key'
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
c 'kubectl apply -f esc-hostpath.yaml && kubectl wait -n psa-lab --for=condition=Ready pod/escape-hostpath --timeout=90s'
kubectl apply -f esc-hostpath.yaml && $W pod/escape-hostpath 2>&1; nl
c 'kubectl exec -n psa-lab escape-hostpath -- sh -c "cat /host/etc/hostname; ls /host/etc/kubernetes/pki/ca.key"'
kubectl exec -n psa-lab escape-hostpath -- sh -c 'cat /host/etc/hostname; ls /host/etc/kubernetes/pki/ca.key' 2>&1; nl

echo '## step 4 — hostPID: see and signal every process on the node'
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
c 'kubectl apply -f esc-hostpid.yaml && kubectl wait -n psa-lab --for=condition=Ready pod/escape-hostpid --timeout=90s'
kubectl apply -f esc-hostpid.yaml && $W pod/escape-hostpid 2>&1; nl
c 'kubectl exec -n psa-lab escape-hostpid -- sh -c "ps -o pid,comm | grep -E \"kubelet|containerd\$\"" | awk "{\$1=\$1;print}"'
kubectl exec -n psa-lab escape-hostpid -- sh -c 'ps -o pid,comm 2>/dev/null | grep -E "kubelet|containerd$"' 2>&1 | awk '{$1=$1;print}'; nl

echo '## step 5 — a mounted runtime socket is root over every pod on the node'
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
c 'kubectl apply -f esc-socket.yaml && kubectl wait -n psa-lab --for=condition=Ready pod/escape-socket --timeout=90s'
kubectl apply -f esc-socket.yaml && $W pod/escape-socket 2>&1; nl
c 'kubectl exec -n psa-lab escape-socket -- sh -c "R=unix:///run/containerd/containerd.sock; echo containers visible: $(crictl -r $R ps -q | wc -l); crictl -r $R ps --name kube-apiserver -o table | grep -o kube-apiserver-[a-z0-9-]*"'
kubectl exec -n psa-lab escape-socket -- sh -c 'R=unix:///run/containerd/containerd.sock; echo "containers visible: $(crictl -r $R ps -q 2>/dev/null | wc -l)"; crictl -r $R ps --name kube-apiserver -o table 2>/dev/null | grep -o "kube-apiserver-[a-z0-9-]*"' 2>&1; nl

echo '## step 6 — no read-only rootfs: drop a binary into the running container'
cat >esc-mutable.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: escape-mutable, namespace: psa-lab}
spec:
  containers:
    - name: esc
      image: $BB
      command: ["sleep", "3600"]
YAML
c 'kubectl apply -f esc-mutable.yaml && kubectl wait -n psa-lab --for=condition=Ready pod/escape-mutable --timeout=90s'
kubectl apply -f esc-mutable.yaml && $W pod/escape-mutable 2>&1; nl
c 'kubectl exec -n psa-lab escape-mutable -- sh -c "printf %s\\\\n \"#!/bin/sh\" \"echo INJECTED\" > /usr/bin/backdoor; chmod +x /usr/bin/backdoor; /usr/bin/backdoor"'
kubectl exec -n psa-lab escape-mutable -- sh -c 'printf "%s\n" "#!/bin/sh" "echo INJECTED" > /usr/bin/backdoor; chmod +x /usr/bin/backdoor; /usr/bin/backdoor' 2>&1; nl

echo '## step 7 — user namespaces: what they would do, and why default kind cannot'
cat >userns-off.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: userns-off, namespace: psa-lab}
spec:
  containers:
    - name: app
      image: $BB
      command: ["sleep", "3600"]
YAML
c 'kubectl apply -f userns-off.yaml && kubectl wait -n psa-lab --for=condition=Ready pod/userns-off --timeout=90s'
kubectl apply -f userns-off.yaml && $W pod/userns-off 2>&1; nl
c 'kubectl exec -n psa-lab userns-off -- cat /proc/self/uid_map | awk "{\$1=\$1;print}"'
kubectl exec -n psa-lab userns-off -- cat /proc/self/uid_map 2>&1 | awk '{$1=$1;print}'; nl
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
c 'kubectl apply -f userns-on.yaml && kubectl wait -n psa-lab --for=condition=Ready pod/userns-on --timeout=30s'
kubectl apply -f userns-on.yaml && kubectl wait -n psa-lab --for=condition=Ready pod/userns-on --timeout=30s 2>&1; nl
c 'kubectl get pod -n psa-lab userns-on'
kubectl get pod -n psa-lab userns-on 2>&1; nl
c 'kubectl get events -n psa-lab --field-selector reason=FailedCreatePodSandBox -o jsonpath="{range .items[*]}{.message}{end}"'
kubectl get events -n psa-lab --field-selector reason=FailedCreatePodSandBox -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>&1 | sed 's/sandbox "[0-9a-f]*"/sandbox/' | tail -1; nl

echo '## step 8 — re-attack a restricted namespace: admission refuses every one'
c 'for a in privileged hostpath hostpid socket; do echo "== $a =="; sed "s/psa-lab/psa-restricted/" esc-$a.yaml | kubectl apply --dry-run=server -f - 2>&1 | sed -n "1p"; done'
for a in privileged hostpath hostpid socket; do
  echo "== $a =="
  sed 's/psa-lab/psa-restricted/' esc-$a.yaml | kubectl apply --dry-run=server -f - 2>&1 | sed -n '1p'
done; nl

echo '## step 9 — the hardened form carries the baseline and is admitted'
cat >hardened.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: hardened, namespace: psa-restricted}
spec:
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
      volumeMounts:
        - {name: tmp, mountPath: /tmp}
  volumes:
    - {name: tmp, emptyDir: {}}
YAML
c 'kubectl apply -f hardened.yaml && kubectl wait -n psa-restricted --for=condition=Ready pod/hardened --timeout=90s'
kubectl apply -f hardened.yaml && kubectl wait -n psa-restricted --for=condition=Ready pod/hardened --timeout=90s 2>&1; nl
c 'kubectl exec -n psa-restricted hardened -- sh -c "exec 2>&1; id; grep ^CapEff /proc/self/status | sed \"s/\\t/ /\"; printf x > /usr/bin/backdoor || true"'
kubectl exec -n psa-restricted hardened -- sh -c 'exec 2>&1; id; grep ^CapEff /proc/self/status | sed "s/\t/ /"; printf x > /usr/bin/backdoor || true' 2>&1; nl

echo '## step 10 — tear down the lab namespaces'
c 'kubectl delete ns psa-lab psa-restricted --wait=true'
kubectl delete ns psa-lab psa-restricted --wait=true 2>&1; nl
rm -rf "$work"
