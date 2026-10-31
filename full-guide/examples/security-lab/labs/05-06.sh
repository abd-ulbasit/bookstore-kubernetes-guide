#!/usr/bin/env bash
# Lab 05.06: Control plane and node hardening. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from any directory. It reads the
# control plane's settings from the kind node, runs kube-bench against the
# cluster, probes the API server, the kubelet and etcd from a restricted Pod that
# holds no token, checks a ServiceAccount token against fine-grained kubelet
# authorization, verifies the kubectl binary on this workstation by checksum and
# signature, and deletes everything it created. It changes no flag on the
# cluster. The hardening edits that need a cluster started with other flags are
# in the chapter, cited to upstream, and are not run here.
#
# A kind node is a container on the machine that runs kind, and it shares that
# machine's kernel. The probes run from a Pod on the node network. The only
# objects this script creates are in the namespaces kube-bench, p05-attack and
# p05-kubelet-authz and in cluster-scoped objects named p05-06-*, and it deletes
# them on exit.
#
# Namespace exception: kube-bench is labelled privileged, because the kube-bench
# Job reads the node's files and process table as root. Chapter 05.06. Expiry
# 2027-10-31, within twelve months.
#
# The recorded run named that namespace p05-kube-bench. This file and the
# transcript carry the chapter's name, kube-bench, because the exceptions
# registry reads Pod Security labels from scripts and transcripts and registers
# the chapter's namespace, not a lab name. That rename is the only edit made
# after the run.
set +e

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

# The kube-bench Job reads files of the node and runs as root, which the image
# declares no user for. The probe image is pinned by digest.
CURL_IMAGE='curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777'  # curlimages/curl:8.22.0
# The identity that signs Kubernetes release binaries, as the Kubernetes docs name it.
KREL_IDENTITY='krel-staging@k8s-releng-prod.iam.gserviceaccount.com'
BENCH_IMAGE='docker.io/aquasec/kube-bench@sha256:75506f222d1eb6ce2a751a5533bdc0a3b54c898e2e49e7751d0ee22cfb862679'  # aquasec/kube-bench:v0.16.0

# Wait for the kube-bench Job to finish: 0 complete, 1 failed, 2 timed out.
wait_job() {
  local s f
  for _ in $(seq 1 120); do
    s=$(kubectl -n kube-bench get job kube-bench -o jsonpath='{.status.succeeded}' 2>/dev/null)
    f=$(kubectl -n kube-bench get job kube-bench -o jsonpath='{.status.failed}' 2>/dev/null)
    [ "$s" = 1 ] && return 0
    [ "$f" = 1 ] && return 1
    sleep 3
  done
  return 2
}

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

work=$(mktemp -d) && cd "$work" || exit 1

cleanup() {
  echo '## cleanup: the lab namespaces and the cluster-scoped objects'
  run <<'CMD'
kubectl delete ns p05-attack p05-kubelet-authz kube-bench --ignore-not-found --wait=true
kubectl delete clusterrolebinding p05-06-node-stats p05-06-node-pods p05-06-node-proxy --ignore-not-found
kubectl delete clusterrole p05-06-node-stats p05-06-node-pods p05-06-node-proxy --ignore-not-found
CMD
  cd / && rm -rf "$work"
}
trap cleanup EXIT

# The probe is a restricted Pod with no token. It stands for a Pod an attacker
# already controls. It reads the cluster CA from a ConfigMap, so the requests to
# the API server verify the server's certificate.
cat > probe.yaml <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: p05-attack
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: probe
  namespace: p05-attack
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: p05-attack
spec:
  serviceAccountName: probe
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $CURL_IMAGE
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cluster-ca
          mountPath: /etc/cluster-ca
          readOnly: true
  volumes:
    - name: tmp
      emptyDir: {}
    - name: cluster-ca
      configMap:
        name: kube-root-ca.crt
YAML

# The kube-bench Job, as the upstream Job runs it, with the benchmark pinned.
# kube-bench runs as root: it reads root-owned files on the node. Its Pod sits
# in a namespace labelled privileged, for the host access it needs.
cat > kube-bench.yaml <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: kube-bench
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-bench
  namespace: kube-bench
automountServiceAccountToken: false
---
# INSECURE ON PURPOSE: a diagnostic Job that reads the node's process table and config files as root, so it needs hostPID, hostPath and root. Lab cluster only.
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench
  namespace: kube-bench
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-bench
    spec:
      serviceAccountName: kube-bench
      automountServiceAccountToken: false
      restartPolicy: Never
      hostPID: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: kube-bench
          image: $BENCH_IMAGE
          command: ["kube-bench"]
          args: ["run", "--benchmark", "cis-1.12"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              add: ["DAC_READ_SEARCH"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: var-lib-cni
              mountPath: /var/lib/cni
              readOnly: true
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: var-lib-kube-scheduler
              mountPath: /var/lib/kube-scheduler
              readOnly: true
            - name: var-lib-kube-controller-manager
              mountPath: /var/lib/kube-controller-manager
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: lib-systemd
              mountPath: /lib/systemd/
              readOnly: true
            - name: srv-kubernetes
              mountPath: /srv/kubernetes/
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: usr-bin
              mountPath: /usr/local/mount-from-host/bin
              readOnly: true
            - name: etc-cni-netd
              mountPath: /etc/cni/net.d/
              readOnly: true
            - name: opt-cni-bin
              mountPath: /opt/cni/bin/
              readOnly: true
      volumes:
        - name: tmp
          emptyDir: {}
        - name: var-lib-cni
          hostPath:
            path: /var/lib/cni
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: var-lib-kube-scheduler
          hostPath:
            path: /var/lib/kube-scheduler
        - name: var-lib-kube-controller-manager
          hostPath:
            path: /var/lib/kube-controller-manager
        - name: etc-systemd
          hostPath:
            path: /etc/systemd
        - name: lib-systemd
          hostPath:
            path: /lib/systemd
        - name: srv-kubernetes
          hostPath:
            path: /srv/kubernetes
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
        - name: usr-bin
          hostPath:
            path: /usr/bin
        - name: etc-cni-netd
          hostPath:
            path: /etc/cni/net.d
        - name: opt-cni-bin
          hostPath:
            path: /opt/cni/bin
YAML
# The first run leaves the benchmark to kube-bench, as the upstream Job does.
sed '/args:/d' kube-bench.yaml > kube-bench-auto.yaml

# A ServiceAccount that a metrics agent would hold: a dedicated token, and only
# the kubelet's stats subresource. The Pod is restricted and mounts that token.
cat > stats-agent.yaml <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: p05-kubelet-authz
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: stats-agent
  namespace: p05-kubelet-authz
automountServiceAccountToken: true
---
apiVersion: v1
kind: Pod
metadata:
  name: stats-agent
  namespace: p05-kubelet-authz
spec:
  serviceAccountName: stats-agent
  automountServiceAccountToken: true
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $CURL_IMAGE
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
YAML

cat > node-stats.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: p05-06-node-stats
rules:
  - apiGroups: [""]
    resources: ["nodes/stats"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: p05-06-node-stats
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: p05-06-node-stats
subjects:
  - kind: ServiceAccount
    name: stats-agent
    namespace: p05-kubelet-authz
YAML

cat > node-pods.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: p05-06-node-pods
rules:
  - apiGroups: [""]
    resources: ["nodes/pods"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: p05-06-node-pods
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: p05-06-node-pods
subjects:
  - kind: ServiceAccount
    name: stats-agent
    namespace: p05-kubelet-authz
YAML

# The broad grant. It is applied for one check and removed in the same step.
cat > node-proxy.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: p05-06-node-proxy
rules:
  - apiGroups: [""]
    resources: ["nodes/proxy"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: p05-06-node-proxy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: p05-06-node-proxy
subjects:
  - kind: ServiceAccount
    name: stats-agent
    namespace: p05-kubelet-authz
YAML

echo '## step 0: the cluster this run used'
run <<'CMD'
kubectl version --client
kubectl get nodes -o wide
CMD
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
NODE_IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "node: $NODE, internal address: $NODE_IP"
echo

echo '## step 1: the settings the node runs with, read from the node'
run <<'CMD'
docker exec $NODE grep -n -E '^readOnlyPort|^  anonymous:|enabled: |^  mode: ' /var/lib/kubelet/config.yaml
docker exec $NODE grep -n -E 'kube-apiserver$|anonymous|profiling|authorization-mode' /etc/kubernetes/manifests/kube-apiserver.yaml
docker exec $NODE grep -n -E 'client-cert-auth|listen-client-urls' /etc/kubernetes/manifests/etcd.yaml
CMD

echo '## step 2: kube-bench with no benchmark named, as its upstream Job runs it'
run <<'CMD'
kubectl apply -f kube-bench-auto.yaml
wait_job; echo "job status: $? (0 complete, 1 failed, 2 timed out)"
kubectl -n kube-bench logs job/kube-bench > kb-auto.txt
head -n 2 kb-auto.txt
grep -A4 '^== Summary total' kb-auto.txt
kubectl -n kube-bench delete job kube-bench --wait=true
CMD

echo '## step 3: kube-bench pinned to cis-1.12, against the settings above'
run <<'CMD'
kubectl apply -f kube-bench.yaml
wait_job; echo "job status: $?"
kubectl -n kube-bench logs job/kube-bench > kb-run.txt
grep -A4 '^== Summary total' kb-run.txt
grep -E '^== Summary (master|etcd|controlplane|node|policies)' -A4 kb-run.txt
grep -E '^\[FAIL\]' kb-run.txt
grep -E '^\[(PASS|FAIL|WARN|INFO)\] (1\.2\.1|1\.2\.15|2\.2|4\.2\.1|4\.2\.2|4\.2\.4) ' kb-run.txt
kubectl -n kube-bench delete job kube-bench --wait=true
CMD

echo '## step 4: attack from a restricted Pod with no token'
run <<'CMD'
kubectl apply -f probe.yaml
kubectl -n p05-attack wait --for=condition=Ready pod/probe --timeout=180s
CMD
run <<'CMD'
kubectl auth can-i get pods --as=system:anonymous --as-group=system:unauthenticated
kubectl exec -n p05-attack probe -- sh -c 'curl -s -o /dev/null -w "anonymous, secrets in kube-system: %{http_code}\n" --cacert /etc/cluster-ca/ca.crt https://kubernetes.default.svc/api/v1/namespaces/kube-system/secrets'
kubectl exec -n p05-attack probe -- sh -c 'curl -s -o /dev/null -w "anonymous, pods in all namespaces: %{http_code}\n" --cacert /etc/cluster-ca/ca.crt https://kubernetes.default.svc/api/v1/pods'
CMD
run <<'CMD'
kubectl exec -n p05-attack probe -- env NODE_IP=$NODE_IP sh -c 'curl -s -o /dev/null -w "kubelet read-only port 10255: %{http_code}\n" --max-time 5 http://$NODE_IP:10255/pods; echo "exit code: $?"'
kubectl exec -n p05-attack probe -- env NODE_IP=$NODE_IP sh -c 'curl -sk -o /dev/null -w "kubelet 10250, anonymous: %{http_code}\n" --max-time 5 https://$NODE_IP:10250/pods'
CMD
run <<'CMD'
kubectl exec -n p05-attack probe -- env NODE_IP=$NODE_IP sh -c 'curl -sSk --max-time 5 https://$NODE_IP:2379/version 2>&1; echo "exit code: $?"'
kubectl exec -n p05-attack probe -- env NODE_IP=$NODE_IP sh -c 'curl -sSk --max-time 5 -H "Content-Type: application/json" -d "{\"key\":\"L3JlZ2lzdHJ5L25hbWVzcGFjZXMva3ViZS1zeXN0ZW0=\"}" https://$NODE_IP:2379/v3/kv/range 2>&1; echo "exit code: $?"'
CMD

echo '## step 5: fine-grained kubelet authorization, on this cluster'
run <<'CMD'
kubectl apply -f stats-agent.yaml
kubectl apply -f node-stats.yaml
kubectl -n p05-kubelet-authz wait --for=condition=Ready pod/stats-agent --timeout=180s
kubectl exec -n p05-kubelet-authz stats-agent -- env NODE_IP=$NODE_IP sh -c 'T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); for p in /stats/summary /metrics /pods /healthz /containerLogs/p05-kubelet-authz/none/none; do curl -sk -o /dev/null -w "$p, nodes/stats only: %{http_code}\n" -H "Authorization: Bearer $T" --max-time 5 https://$NODE_IP:10250$p; done'
CMD
run <<'CMD'
kubectl apply -f node-pods.yaml
sleep 35
kubectl exec -n p05-kubelet-authz stats-agent -- env NODE_IP=$NODE_IP sh -c 'T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); for p in /stats/summary /metrics /pods /healthz /containerLogs/p05-kubelet-authz/none/none; do curl -sk -o /dev/null -w "$p, with nodes/pods added: %{http_code}\n" -H "Authorization: Bearer $T" --max-time 5 https://$NODE_IP:10250$p; done'
CMD
run <<'CMD'
kubectl apply -f node-proxy.yaml
sleep 35
kubectl exec -n p05-kubelet-authz stats-agent -- env NODE_IP=$NODE_IP sh -c 'T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); for p in /metrics /healthz /containerLogs/p05-kubelet-authz/none/none; do curl -sk -o /dev/null -w "$p, with the broad nodes/proxy grant: %{http_code}\n" -H "Authorization: Bearer $T" --max-time 5 https://$NODE_IP:10250$p; done'
kubectl delete clusterrolebinding p05-06-node-proxy clusterrole p05-06-node-proxy --ignore-not-found
sleep 310
kubectl exec -n p05-kubelet-authz stats-agent -- env NODE_IP=$NODE_IP sh -c 'T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -o /dev/null -w "/containerLogs, after the broad grant is removed: %{http_code}\n" -H "Authorization: Bearer $T" --max-time 5 https://$NODE_IP:10250/containerLogs/p05-kubelet-authz/none/none'
CMD

echo '## step 6: the kubectl binary on this workstation, by checksum and signature'
run <<'CMD'
kubectl version --client -o yaml | grep gitVersion
os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m); [ "$arch" = x86_64 ] && arch=amd64
ver=$(kubectl version --client -o yaml | awk '/gitVersion/{print $2; exit}')
echo "release path: https://dl.k8s.io/release/$ver/bin/$os/$arch/"
cp "$(command -v kubectl)" kubectl
curl -sSfL -o kubectl.sha256 "https://dl.k8s.io/release/$ver/bin/$os/$arch/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | shasum -a 256 -c
curl -sSfL -o kubectl.sig "https://dl.k8s.io/release/$ver/bin/$os/$arch/kubectl.sig"
curl -sSfL -o kubectl.cert "https://dl.k8s.io/release/$ver/bin/$os/$arch/kubectl.cert"
cosign verify-blob kubectl --signature kubectl.sig --certificate kubectl.cert --certificate-identity "$KREL_IDENTITY" --certificate-oidc-issuer https://accounts.google.com
CMD

echo '## lab complete'
