#!/usr/bin/env bash
# Lab 08.04: Multi-tenancy and namespaces. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. It creates three namespaces: p08-04-bookstore and p08-04-acme, and
# p08-04-probe, a plain namespace with no NetworkPolicy of its own that holds a
# Pod from outside the tenant. It applies the Bookstore namespace's guardrail
# objects (the namespace with its Pod Security labels, the quota and limits, the
# ServiceAccounts and RBAC, and the NetworkPolicies) without its workloads. It
# applies the chapter's second-tenant.yaml with only the namespace renamed. Object
# names stay as the chapter has them. The script runs the checks the chapter
# shows, then deletes all three namespaces. The chapter prints the namespaces as
# bookstore, tenant-acme and probe; the transcript carries the p08-04 names.
set +e

K="${KUBECTL:-kubectl}"
BS=p08-04-bookstore
AC=p08-04-acme
PR=p08-04-probe
DBG='busybox:1.36@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662'
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

# Apply a file from the scratch directory, so an error message names the file
# and not the scratch path.
apply_here() { (cd "$WORK" && "$K" apply -f "$1" 2>&1); }

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

step "Section 4: a tenant at its quota, and a Pod from another namespace"
cat > "$WORK/acme-hog.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: acme-hog
  namespace: $AC
spec:
  serviceAccountName: acme-deployer
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $DBG
      command: ["sh", "-c", "echo ok > /tmp/index.html && exec httpd -f -p 8080 -h /tmp"]
      ports:
        - containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 50m, memory: 1Gi}
        limits: {cpu: 250m, memory: 1Gi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
EOF
show "kubectl apply -f acme-hog.yaml   # tenant-acme; asks for the whole 1Gi memory quota"
apply_here acme-hog.yaml
show "kubectl wait --for=condition=Ready pod/acme-hog -n $AC --timeout=180s"
"$K" wait --for=condition=Ready pod/acme-hog -n "$AC" --timeout=180s 2>&1
show "kubectl get resourcequota tenant-acme-quota -n $AC"
"$K" get resourcequota tenant-acme-quota -n "$AC" 2>&1

sed -e 's/acme-hog/acme-second/' -e 's/memory: 1Gi/memory: 512Mi/g' "$WORK/acme-hog.yaml" > "$WORK/acme-second.yaml"
show "kubectl apply -f acme-second.yaml   # tenant-acme; deliberate failure, the quota is full"
apply_here acme-second.yaml

sed -e 's/acme-hog/acme-big/' -e 's/requests: {cpu: 50m, memory: 1Gi}/requests: {cpu: 50m, memory: 64Mi}/' -e 's/limits: {cpu: 250m, memory: 1Gi}/limits: {cpu: 250m, memory: 2Gi}/' "$WORK/acme-hog.yaml" > "$WORK/acme-big.yaml"
show "kubectl apply -f acme-big.yaml   # tenant-acme; deliberate failure, over the LimitRange max"
apply_here acme-big.yaml

cat > "$WORK/probe.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $PR
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: $PR
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
      image: $DBG
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 64Mi}
---
apiVersion: v1
kind: Pod
metadata:
  name: peer
  namespace: $PR
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
      image: $DBG
      command: ["sh", "-c", "echo ok > /tmp/index.html && exec httpd -f -p 8080 -h /tmp"]
      ports:
        - containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 64Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
EOF
show "kubectl apply -f probe.yaml   # namespace $PR, no NetworkPolicy of its own"
apply_here probe.yaml
show "kubectl wait --for=condition=Ready pod/probe pod/peer -n $PR --timeout=180s"
"$K" wait --for=condition=Ready pod/probe pod/peer -n "$PR" --timeout=180s 2>&1
PEER_IP=$("$K" get pod peer -n "$PR" -o jsonpath='{.status.podIP}' 2>/dev/null)
ACME_IP=$("$K" get pod acme-hog -n "$AC" -o jsonpath='{.status.podIP}' 2>/dev/null)
show "kubectl exec -n $PR probe -- wget -T 5 -qO- http://\$PEER_IP:8080/; echo \"exit status: \$?\"   # control: a Pod in the same namespace"
"$K" exec -n "$PR" probe -- wget -T 5 -qO- "http://$PEER_IP:8080/" 2>&1
echo "exit status: $?"
show "kubectl exec -n $PR probe -- wget -T 5 -qO- http://\$ACME_IP:8080/; echo \"exit status: \$?\"   # deliberate: another tenant's Pod"
"$K" exec -n "$PR" probe -- wget -T 5 -qO- "http://$ACME_IP:8080/" 2>&1
echo "exit status: $?"

step "Section 5: a deliberate failure, refused by restricted"
show "kubectl run escape-probe -n $AC --image=bookstore/catalog:dev --restart=Never --privileged --dry-run=server"
"$K" run escape-probe -n "$AC" --image=bookstore/catalog:dev --restart=Never --privileged --dry-run=server 2>&1

step "Section 6: environments are overlays of one namespace, not tenants"
show "kubectl kustomize examples/bookstore/kustomize/overlays/dev | grep -m1 'namespace:'"
"$K" kustomize examples/bookstore/kustomize/overlays/dev 2>&1 | grep -m1 'namespace:'
show "kubectl kustomize examples/bookstore/kustomize/overlays/prod | grep -m1 'namespace:'"
"$K" kustomize examples/bookstore/kustomize/overlays/prod 2>&1 | grep -m1 'namespace:'

step "Cleanup"
show "kubectl delete namespace $AC $BS $PR --wait=true"
"$K" delete namespace "$AC" "$BS" "$PR" --wait=true 2>&1
echo "lab 08.04 done"
