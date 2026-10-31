#!/usr/bin/env bash
# Lab 08.04: Multi-tenancy and namespaces. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. It creates two namespaces, p08-04-bookstore and p08-04-acme. It
# applies the Bookstore namespace's guardrail objects (the namespace with its
# Pod Security labels, the quota and limits, the ServiceAccounts and RBAC, and
# the NetworkPolicies) without its workloads. It applies the chapter's
# second-tenant.yaml with only the namespace renamed. Object names stay as the
# chapter has them. The script runs the checks the chapter shows, then deletes
# both namespaces. The chapter prints the namespaces as bookstore and
# tenant-acme; the transcript carries the p08-04 names.
set +e

K="${KUBECTL:-kubectl}"
BS=p08-04-bookstore
AC=p08-04-acme
MANI=examples/bookstore/raw-manifests
TEN=examples/bookstore/operators/second-tenant.yaml
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

# Print a command the way a reader would type it, then run it.
show() { printf '$ %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

# rename FILE OLD NEW: change the namespace of a manifest and nothing else. The
# Namespace object's own name and every namespace: field move to NEW.
rename() {
  sed -e "s/^  name: $2\$/  name: $3/" -e "s/namespace: $2\$/namespace: $3/" "$1"
}

rename "$MANI/00-namespace.yaml" bookstore "$BS" > "$WORK/bs-00.yaml"
rename "$MANI/05-serviceaccounts-rbac.yaml" bookstore "$BS" > "$WORK/bs-05.yaml"
rename "$MANI/60-networkpolicy.yaml" bookstore "$BS" > "$WORK/bs-60.yaml"
rename "$TEN" tenant-acme "$AC" > "$WORK/acme.yaml"

step "Section 1: the Bookstore namespace's guardrails"
show "kubectl apply -f 00-namespace.yaml (namespace $BS)"
"$K" apply -f "$WORK/bs-00.yaml" 2>&1
show "kubectl apply -f 05-serviceaccounts-rbac.yaml (namespace $BS)"
"$K" apply -f "$WORK/bs-05.yaml" 2>&1
show "kubectl apply -f 60-networkpolicy.yaml (namespace $BS)"
"$K" apply -f "$WORK/bs-60.yaml" 2>&1

show "kubectl get resourcequota,limitrange -n $BS"
"$K" get resourcequota,limitrange -n "$BS" 2>&1
show "kubectl get serviceaccounts -n $BS"
"$K" get serviceaccounts -n "$BS" 2>&1
show "kubectl get networkpolicy -n $BS"
"$K" get networkpolicy -n "$BS" 2>&1
show "kubectl get networkpolicy default-deny-all -n $BS -o jsonpath='{.spec.policyTypes}'"
"$K" get networkpolicy default-deny-all -n "$BS" -o jsonpath='{.spec.policyTypes}' 2>&1; echo
show "kubectl get ns $BS -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'"
"$K" get ns "$BS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>&1; echo

step "Section 2: the second tenant, with its own full stack"
show "kubectl apply -f second-tenant.yaml (namespace $AC)"
"$K" apply -f "$WORK/acme.yaml" 2>&1
show "kubectl get ns $AC -o jsonpath='{.metadata.labels.tenant}'"
"$K" get ns "$AC" -o jsonpath='{.metadata.labels.tenant}' 2>&1; echo
show "kubectl get resourcequota,limitrange -n $AC"
"$K" get resourcequota,limitrange -n "$AC" 2>&1
show "kubectl get networkpolicy -n $AC"
"$K" get networkpolicy -n "$AC" 2>&1

step "Section 3: what the stack lets the tenant do, and what it refuses"
SA="system:serviceaccount:$AC:acme-deployer"
check() { show "kubectl auth can-i $*"; "$K" auth can-i "$@" 2>&1; }
check create deployments --as="$SA" -n "$AC"
check create deployments --as="$SA" -n "$BS"
check create resourcequotas --as="$SA" -n "$AC"
check create networkpolicies --as="$SA" -n "$AC"
check create pods --subresource=exec --as="$SA" -n "$AC"
check get pods --subresource=log --as="$SA" -n "$AC"
check get secrets --as="$SA" -n "$BS"

step "Section 3: a deliberate failure, refused by restricted"
show "kubectl run escape-probe -n $AC --image=bookstore/catalog:dev --restart=Never --privileged --dry-run=server"
"$K" run escape-probe -n "$AC" --image=bookstore/catalog:dev --restart=Never --privileged --dry-run=server 2>&1

step "Section 4: environments are overlays of one namespace, not tenants"
show "kubectl kustomize examples/bookstore/kustomize/overlays/dev | grep -m1 'namespace:'"
"$K" kustomize examples/bookstore/kustomize/overlays/dev 2>&1 | grep -m1 'namespace:'
show "kubectl kustomize examples/bookstore/kustomize/overlays/prod | grep -m1 'namespace:'"
"$K" kustomize examples/bookstore/kustomize/overlays/prod 2>&1 | grep -m1 'namespace:'

step "Cleanup"
show "kubectl delete namespace $AC $BS --wait=true"
"$K" delete namespace "$AC" "$BS" --wait=true 2>&1
echo "lab 08.04 done"
