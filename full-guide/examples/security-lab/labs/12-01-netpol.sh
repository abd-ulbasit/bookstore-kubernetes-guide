#!/usr/bin/env bash
# Lab 12.01, NetworkPolicy step: the default-deny policy refusing a connection.
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. Its output is appended to the chapter's transcript as step 5. It
# creates two restricted namespaces named <prefix>-bookstore-ml and
# <prefix>-open, where <prefix> is LAB_PREFIX (default p12-01), and deletes
# both at the end. The first gets the chapter's own Namespace and default-deny
# NetworkPolicy, with only the name replaced. The second has no policy, and
# serves as the control.
#
# Each namespace runs one identical Pod from the serve image (SERVE_IMAGE,
# default bookstore/recommender-serve:dev, used here only for its Python) that
# opens a TCP connection to the cluster's own API Service address and reports
# the result. The address is read from the Pod's environment and not printed.
set +e

K="${KUBECTL:-kubectl}"
PFX="${LAB_PREFIX:-p12-01}"
NS="$PFX-bookstore-ml"
OPEN="$PFX-open"
IMAGE="${SERVE_IMAGE:-bookstore/recommender-serve:dev}"

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

show() { printf '$ %s\n' "$*"; }

manifest() {
cat <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: bookstore-ml
  labels:
    app.kubernetes.io/part-of: bookstore-ml
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: bookstore-ml
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
YAML
}

probe_pod() {
cat <<EOF2
apiVersion: v1
kind: Pod
metadata:
  name: connect-check
  namespace: $1
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: check
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command: ["python", "-c"]
      args:
        - |-
          import os, socket
          host = os.environ["KUBERNETES_SERVICE_HOST"]
          try:
              socket.create_connection((host, 443), timeout=3).close()
              print("connect to the API Service address: connected")
          except OSError as e:
              print("connect to the API Service address:", type(e).__name__, e)
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { memory: 128Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
EOF2
}

echo
echo "## step 5: the default-deny policy refuses a connection, and a namespace without one does not"
"$K" wait --for=delete "namespace/$NS" "namespace/$OPEN" --timeout=240s >/dev/null 2>&1
show "kubectl apply -f - <<'EOF'   # Namespace bookstore-ml and default-deny NetworkPolicy"
manifest | sed "s/bookstore-ml/$NS/g" | "$K" apply -f -
show "kubectl create namespace $OPEN (restricted, no NetworkPolicy)"
"$K" create namespace "$OPEN" 2>&1
"$K" label namespace "$OPEN" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted >/dev/null 2>&1
for n in "$NS" "$OPEN"; do
  for _ in $(seq 1 30); do "$K" get serviceaccount default -n "$n" >/dev/null 2>&1 && break; sleep 1; done
done
for n in "$NS" "$OPEN"; do
  show "kubectl apply -f connect-check.yaml (in $n)"
  probe_pod "$n" | "$K" apply -f - 2>&1
done
for n in "$NS" "$OPEN"; do
  "$K" wait --for=jsonpath='{.status.phase}'=Succeeded pod/connect-check -n "$n" --timeout=120s >/dev/null 2>&1
  show "kubectl logs connect-check -n $n"
  "$K" logs connect-check -n "$n" 2>&1
done

echo
echo "## step 6: cleanup of the NetworkPolicy step"
show "kubectl delete namespace $NS $OPEN --wait=false"
"$K" delete namespace "$NS" "$OPEN" --wait=false 2>&1
