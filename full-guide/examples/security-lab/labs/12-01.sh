#!/usr/bin/env bash
# Lab 12.01: why ML on Kubernetes. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. It creates one namespace, p12-01-bookstore-ml, applies the
# chapter's Namespace and default-deny NetworkPolicy in it, shows restricted
# refusing a Pod with no securityContext, and deletes the namespace at the end.
# The chapter names the bookstore-ml namespace; this script applies the same
# manifests with only the namespace name replaced.
set +e

K="${KUBECTL:-kubectl}"
NS=p12-01-bookstore-ml

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

# Print a command the way a reader would type it, then run it.
show() { printf '$ %s\n' "$*"; }

# The chapter's manifests. Only the namespace name is substituted below.
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

echo "## step 0: versions"
show "kubectl version"
"$K" version

echo
echo "## step 1: a restricted namespace and a default-deny NetworkPolicy"
show "kubectl apply -f - <<'EOF'   # Namespace bookstore-ml and default-deny NetworkPolicy"
manifest | sed "s/bookstore-ml/$NS/g" | "$K" apply -f -
# A controller creates the namespace's default ServiceAccount a moment after
# the namespace. Wait for it, so step 3 meets the Pod Security check.
for _ in $(seq 1 30); do "$K" get serviceaccount default -n "$NS" >/dev/null 2>&1 && break; sleep 1; done

echo
echo "## step 2: the restricted labels, and the policy stored in the namespace"
show "kubectl get namespace $NS -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep pod-security"
"$K" get namespace "$NS" -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep pod-security
show "kubectl get networkpolicy -n $NS"
"$K" get networkpolicy -n "$NS"

echo
echo "## step 3: a deliberate refusal, a Pod with no securityContext"
show "kubectl run unhardened --image=bookstore/catalog:dev --restart=Never --dry-run=server -n $NS"
"$K" run unhardened --image=bookstore/catalog:dev --restart=Never --dry-run=server -n "$NS"
echo "exit status: $?"

echo
echo "## step 4: delete the lab namespace"
show "kubectl delete namespace $NS"
"$K" delete namespace "$NS"
