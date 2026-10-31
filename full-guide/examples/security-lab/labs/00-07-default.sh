#!/usr/bin/env bash
# Lab for 00-foundations/07-local-cluster-setup.md: the restricted cluster-wide
# default, and the first Bookstore Pod under it.
#
# Tier A: kind. Run it only against a kind cluster you own, created from
# examples/security-lab/kind/cluster-restricted-default.yaml. The script
# refuses any kubectl context that is not kind-*, and it refuses to start while
# one of its namespaces is left over. It creates three namespaces, default-check,
# privileged-check and bookstore, and deletes them at the end.
#
# Run from the repository root:
#   KUBECONFIG=... bash full-guide/examples/security-lab/labs/00-07-default.sh \
#     > transcript.txt
#
# Each command is printed the way a reader types it, then run, so the output
# under it is what that command printed. The output is not redacted: the node
# is the lab cluster's own, p00-default-control-plane.

set -uo pipefail

GUIDE=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CONTEXT=$(kubectl config current-context 2>/dev/null)
case "$CONTEXT" in
  kind-*) ;;
  *) echo "refusing: kubectl context '$CONTEXT' is not a kind cluster" >&2; exit 2 ;;
esac

for ns in default-check privileged-check bookstore; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "refusing: namespace $ns exists; delete the old lab first" >&2
    exit 2
  fi
done

# show prints its arguments as one command, then runs that command.
show() {
  local cmd="$*"
  printf '$ %s\n' "$cmd"
  eval "$cmd" 2>&1
}

# say prints a command the way the chapter shows it, with a note that says what
# the script ran in its place, then runs the command it is given.
say() {
  printf '$ %s\n' "$1"
  eval "$2" 2>&1
}

BUSYBOX='busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec'
DEFAULT_SA_WAIT='until kubectl -n NS get serviceaccount default >/dev/null 2>&1; do sleep 1; done'

NODE_VERSION=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null)
printf '%s\n' \
  "## Cluster-wide default: a fresh kind cluster built from cluster-restricted-default.yaml" \
  "# Recorded by running labs/00-07-default.sh. Node $NODE_VERSION."

cd "$GUIDE" || exit 2

echo "## the cluster, and the flag the API server runs with"
show "kubectl get nodes"
show "kubectl -n kube-system get pod -l component=kube-apiserver -o jsonpath='{range .items[0].spec.containers[0].command[*]}{@}{\"\\n\"}{end}' | grep admission-control"

echo "## step 1: an unlabelled namespace takes the default"
echo "\$ BUSYBOX=$BUSYBOX  # busybox:1.37"
show "kubectl create namespace default-check"
show "${DEFAULT_SA_WAIT//NS/default-check}"
show "kubectl get namespace default-check --show-labels"
echo "# Deliberate failure: a privileged Pod in the unlabelled namespace. Expect it to be refused."
show "kubectl run privileged-probe -n default-check --image=\"\$BUSYBOX\" --restart=Never --privileged -- sleep 3600"
show "kubectl get pods -n default-check"

echo "## step 2: the same namespace admits a Pod that carries the baseline, and the storage provisioner still binds a claim"
cat > "$WORK/default-check.yaml" <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: check-sa
  namespace: default-check
automountServiceAccountToken: false
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: default-check
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: baseline-check
  namespace: default-check
  labels:
    app: baseline-check
spec:
  serviceAccountName: check-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: check
      image: busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec  # busybox:1.37
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
          memory: 32Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: data
          mountPath: /data
  volumes:
    - name: tmp
      emptyDir: {}
    - name: data
      persistentVolumeClaim:
        claimName: data
YAML
say "kubectl apply -f - <<'EOF'   # check-sa, a claim named data, and a Pod with the baseline that mounts it" \
  "kubectl apply -f $WORK/default-check.yaml"
rm -f "$WORK/default-check.yaml"
show "kubectl get pvc data -n default-check"
show "kubectl wait --for=condition=Ready pod/baseline-check -n default-check --timeout=120s"
show "kubectl get pvc data -n default-check"
show "kubectl get pod baseline-check -n default-check"
show "kubectl exec -n default-check baseline-check -- sh -c 'echo stored > /data/check && cat /data/check'"
show "VOLUME=\$(kubectl get pvc data -n default-check -o jsonpath='{.spec.volumeName}')"
show "kubectl -n local-path-storage logs deploy/local-path-provisioner | grep -o \"create the helper pod helper-pod-create-\$VOLUME into local-path-storage\""

echo "## step 3: CoreDNS still runs, and the Pod resolves a Service name"
show "kubectl -n kube-system get pods -l k8s-app=kube-dns"
show "kubectl exec -n default-check baseline-check -- nslookup kubernetes.default.svc.cluster.local | tr '\t' ' '"

echo "## step 4: a namespace labelled privileged admits the same privileged Pod"
show "kubectl create namespace privileged-check"
show "${DEFAULT_SA_WAIT//NS/privileged-check}"
show "kubectl label namespace privileged-check pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted"
show "kubectl run privileged-probe -n privileged-check --image=\"\$BUSYBOX\" --restart=Never --privileged -- sleep 3600"
show "kubectl get pod privileged-probe -n privileged-check -o jsonpath='{.metadata.name} privileged={.spec.containers[0].securityContext.privileged}{\"\n\"}'"

echo "## also recorded for 05-security/02-pod-security.md: a Deployment in the unlabelled namespace"
show "kubectl create deployment unhardened --image=\"\$BUSYBOX\" --dry-run=server -n default-check -- sleep 3600"

echo "## step 5: remove what the checks created"
show "kubectl delete namespace default-check privileged-check --wait=true --timeout=180s"

echo "## step 6: the first Bookstore Pod and the NetworkPolicy check, on this cluster"
cat > "$WORK/bookstore-ns.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: bookstore
  labels:
    app.kubernetes.io/part-of: bookstore
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: catalog-sa
  namespace: bookstore
  labels:
    app: catalog
    app.kubernetes.io/part-of: bookstore
automountServiceAccountToken: false
YAML
say "kubectl apply -f - <<'EOF'   # Namespace bookstore and ServiceAccount catalog-sa" \
  "kubectl apply -f $WORK/bookstore-ns.yaml"
rm -f "$WORK/bookstore-ns.yaml"
show "kubectl apply -n bookstore -f examples/bookstore/raw-manifests/01-catalog-pod.yaml"
show "kubectl wait --for=condition=Ready pod/catalog -n bookstore --timeout=120s"
show "kubectl get pod catalog -n bookstore"
show "kubectl logs catalog -n bookstore | head -2"
cat > "$WORK/probe.yaml" <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: probe-sa
  namespace: bookstore
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: bookstore
  labels:
    app: probe
spec:
  serviceAccountName: probe-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec  # busybox:1.37
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
          memory: 32Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
YAML
say "kubectl apply -f - <<'EOF'   # probe ServiceAccount and Pod, same baseline as catalog" \
  "kubectl apply -f $WORK/probe.yaml"
rm -f "$WORK/probe.yaml"
show "kubectl wait --for=condition=Ready pod/probe -n bookstore --timeout=120s"
CATALOG_IP=$(kubectl get pod catalog -n bookstore -o jsonpath='{.status.podIP}')
echo '$ CATALOG_IP=$(kubectl get pod catalog -n bookstore -o jsonpath='"'"'{.status.podIP}'"'"')'
show 'kubectl exec -n bookstore probe -- wget -qO- -T 3 "http://$CATALOG_IP:8080/healthz"'
cat > "$WORK/deny.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: bookstore
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
YAML
say "kubectl apply -f - <<'EOF'   # default-deny ingress for the namespace" \
  "kubectl apply -f $WORK/deny.yaml"
rm -f "$WORK/deny.yaml"
echo "# Deliberate failure: the same request, now under the policy. Expect it to time out."
show 'kubectl exec -n bookstore probe -- wget -qO- -T 3 "http://$CATALOG_IP:8080/healthz"'
show "kubectl delete networkpolicy default-deny-ingress -n bookstore"
show 'kubectl exec -n bookstore probe -- wget -qO- -T 3 "http://$CATALOG_IP:8080/healthz"'
show "kubectl delete namespace bookstore --wait=true --timeout=180s"
