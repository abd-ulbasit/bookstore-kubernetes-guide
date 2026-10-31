#!/usr/bin/env bash
# Lab 08.03: troubleshooting and debugging without weakening controls. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. It creates two namespaces: p08-03-bookstore, which gets the chapter's
# Bookstore files with only the namespace name and its DNS names replaced, and
# p08-03-node-debug, a privileged namespace for the node-level step. Both are
# deleted at the end. The chapter names the bookstore and node-debug namespaces;
# this script applies the same files.
#
# Three failures are induced on the lab's catalog Deployment: a bad image tag,
# a malformed database DSN and a failing readiness probe. Each one is reverted.
# The debug steps attach ephemeral containers to a catalog Pod, which is
# distroless and has no shell, using a busybox image pinned by digest.
#
# The namespace is created with the Pod Security labels from 00-namespace.yaml
# and is never relaxed. The lab does not create or change any cluster-scoped
# object. It reads the bookstore-critical PriorityClass that the catalog Pod
# names and leaves it alone.
set +e

K="${KUBECTL:-kubectl}"
NS=p08-03-bookstore
NN=p08-03-node-debug
MANI=examples/bookstore/raw-manifests
DBG='busybox:1.36@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662'
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

# Print a command the way a reader would type it, then run it.
show() { printf '$ %s\n' "$*"; }

# Wait until an ephemeral container of the catalog Pod reports running. The
# kubelet creates it after the API server admits it, so a read straight after
# the debug command can find it still in ContainerCreating.
wait_eph() {
  for _ in $(seq 1 90); do
    "$K" get pod -n "$NS" "$POD" -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$1\")].state.running.startedAt}" 2>/dev/null | grep -q . && return 0
    sleep 2
  done
  return 1
}

# Apply a canonical file with only its namespace name and DNS names replaced.
apply_ns() {
  show "kubectl apply -f $MANI/$1   # namespace $NS"
  sed -e "s/^  name: bookstore\$/  name: $NS/" \
      -e "s/namespace: bookstore/namespace: $NS/g" \
      -e "s/\.bookstore\.svc/.$NS.svc/g" "$MANI/$1" | "$K" apply -f - 2>&1
}

echo "# Transcript for 08-day-2-operations/03-troubleshooting-playbook.md."
echo "# Tier A: a kind cluster the guide's author runs for the guide, shared with"
echo "# other parts of the guide. The lab used its own namespace, $NS. The chapter"
echo "# names the bookstore namespace and applies the same files; the only changes"
echo "# are the namespace name and the .bookstore.svc.cluster.local DNS names in"
echo "# the canonical manifests. Lines that name the lab namespace are kept as"
echo "# captured."
echo "# Not run here: the kind cluster create and delete, the image build and the"
echo "# kind load (the four Bookstore images were already loaded), the NetworkPolicy"
echo "# branch (the chapter's diagnosis is not induced in this run) and an OOMKilled"
echo "# drill (the bookstore LimitRange sets a 16Mi memory floor)."
echo "# The node-level step (step 11) used a second namespace, $NN, labelled"
echo "# privileged and registered in security/namespace-exceptions.yaml under the"
echo "# name node-debug. The chapter's manifest names it node-debug."
echo "# The debug image is busybox:1.36 pinned by digest. The digest matches the"
echo "# registry manifest for busybox:1.36, checked with docker buildx imagetools"
echo "# inspect before the run."
echo

echo "## step 0: versions and a clean start"
show "kubectl version"
"$K" version 2>&1 | grep -E 'Client Version|Server Version'
show "kubectl get namespace $NS"
"$K" get namespace "$NS" 2>&1
echo

echo "## step 1: the namespace, with the restricted Pod Security labels and quota"
apply_ns 00-namespace.yaml
show "kubectl get namespace $NS --show-labels"
"$K" get namespace "$NS" --show-labels 2>&1
echo

echo "## step 2: the data layer and the ServiceAccounts the catalog needs"
apply_ns 05-serviceaccounts-rbac.yaml
apply_ns 15-catalog-config.yaml
apply_ns 16-db-credentials.yaml
apply_ns 12-redis.yaml
apply_ns 20-postgres-statefulset.yaml
apply_ns 40-services.yaml
show "kubectl rollout status statefulset/postgres -n $NS --timeout=420s"
"$K" rollout status statefulset/postgres -n "$NS" --timeout=420s 2>&1
show "kubectl rollout status deployment/redis -n $NS --timeout=120s"
"$K" rollout status deployment/redis -n "$NS" --timeout=120s 2>&1
apply_ns 21-db-migrate-job.yaml
show "kubectl wait --for=condition=complete job/db-migrate -n $NS --timeout=180s"
"$K" wait --for=condition=complete job/db-migrate -n "$NS" --timeout=180s 2>&1
echo

echo "## step 3: the PriorityClass the catalog names (cluster-scoped, read only)"
show "kubectl get priorityclass bookstore-critical"
"$K" get priorityclass bookstore-critical 2>&1
echo

echo "## step 4: the catalog Deployment, with the full baseline"
apply_ns 10-catalog-deploy.yaml
show "kubectl rollout status deployment/catalog -n $NS --timeout=180s"
"$K" rollout status deployment/catalog -n "$NS" --timeout=180s 2>&1
show "kubectl get pods -n $NS"
"$K" get pods -n "$NS" 2>&1
echo

echo "## step 5: the distroless reality check"
show "kubectl exec -n $NS deploy/catalog -- sh"
"$K" exec -n "$NS" deploy/catalog -- sh 2>&1
show "kubectl exec -n $NS statefulset/postgres -- sh -c 'echo postgres has a shell'"
"$K" exec -n "$NS" statefulset/postgres -- sh -c 'echo postgres has a shell' 2>&1
echo

echo "## step 6: one ephemeral container per debug profile, with the default image"
POD=$("$K" get pod -n "$NS" -l app=catalog -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
for p in general baseline restricted netadmin sysadmin; do
  show "kubectl debug -n $NS $POD --image=$DBG --profile=$p -c dbg-$p --target=catalog -- sleep 600"
  "$K" debug -n "$NS" "$POD" --image="$DBG" --profile="$p" -c "dbg-$p" --target=catalog -- sleep 600 2>&1
done
wait_eph dbg-restricted
show "kubectl describe pod -n $NS $POD"
"$K" describe pod -n "$NS" "$POD" 2>&1 | sed -n '/^Ephemeral Containers:/,/^Conditions:/p' | grep -E '^  [a-z0-9-]+:$|State:|Reason:' | head -40
echo

echo "## step 6b: the grant to add an ephemeral container is an RBAC rule"
show "kubectl auth can-i create pods --subresource=ephemeralcontainers -n $NS --as=system:serviceaccount:$NS:catalog-sa"
"$K" auth can-i create pods --subresource=ephemeralcontainers -n "$NS" --as=system:serviceaccount:"$NS":catalog-sa 2>&1
show "kubectl auth can-i create pods --subresource=exec -n $NS --as=system:serviceaccount:$NS:catalog-sa"
"$K" auth can-i create pods --subresource=exec -n "$NS" --as=system:serviceaccount:"$NS":catalog-sa 2>&1
echo

echo "## step 7: restricted with a numeric UID that matches the catalog process"
printf '%s\n' '{"securityContext":{"runAsUser":65532}}' > dbg-uid.json
show "kubectl debug -n $NS $POD --image=$DBG --profile=restricted --custom=dbg-uid.json -c dbg-restricted-uid --target=catalog -- sleep 600"
"$K" debug -n "$NS" "$POD" --image="$DBG" --profile=restricted --custom=dbg-uid.json -c dbg-restricted-uid --target=catalog -- sleep 600 2>&1
rm -f dbg-uid.json
wait_eph dbg-restricted-uid
show "kubectl exec -n $NS $POD -c dbg-restricted-uid -- sh -c 'id -u; wget -qO- http://localhost:8080/healthz; echo; tr \"\\0\" \" \" < /proc/1/cmdline; echo; tr \"\\0\" \"\\n\" < /proc/1/environ | grep -c \"^DB_DSN=\"'"
"$K" exec -n "$NS" "$POD" -c dbg-restricted-uid -- sh -c 'id -u; wget -qO- http://localhost:8080/healthz; echo; tr "\0" " " < /proc/1/cmdline; echo; tr "\0" "\n" < /proc/1/environ | grep -c "^DB_DSN="' 2>&1
echo

echo "## step 8: induced failure A, a bad image tag, then the revert"
show "kubectl set image deploy/catalog catalog=bookstore/catalog:nonexistent -n $NS   # deliberate failure"
"$K" set image deploy/catalog catalog=bookstore/catalog:nonexistent -n "$NS" 2>&1
show "kubectl rollout status deployment/catalog -n $NS --timeout=60s"
"$K" rollout status deployment/catalog -n "$NS" --timeout=60s 2>&1
show "kubectl get pods -n $NS -l app=catalog"
"$K" get pods -n "$NS" -l app=catalog 2>&1
BAD=$("$K" get pods -n "$NS" -l app=catalog --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1)
show "kubectl describe $BAD -n $NS   # Events only"
"$K" describe "$BAD" -n "$NS" 2>&1 | sed -n '/^Events:/,$p'
show "kubectl set image deploy/catalog catalog=bookstore/catalog:dev -n $NS   # revert"
"$K" set image deploy/catalog catalog=bookstore/catalog:dev -n "$NS" 2>&1
show "kubectl rollout status deployment/catalog -n $NS --timeout=180s"
"$K" rollout status deployment/catalog -n "$NS" --timeout=180s 2>&1
echo

echo "## step 9: induced failure B, a malformed DSN, then the revert"
show "kubectl set env deploy/catalog -n $NS 'DB_DSN=host=postgres.$NS.svc.cluster.local port=5432 sslmode=bogus'   # deliberate failure"
"$K" set env deploy/catalog -n "$NS" "DB_DSN=host=postgres.$NS.svc.cluster.local port=5432 sslmode=bogus" 2>&1
show "kubectl rollout status deployment/catalog -n $NS --timeout=60s"
"$K" rollout status deployment/catalog -n "$NS" --timeout=60s 2>&1
show "kubectl get pods -n $NS -l app=catalog"
"$K" get pods -n "$NS" -l app=catalog 2>&1
CRASH=$("$K" get pods -n "$NS" -l app=catalog -o jsonpath='{.items[?(@.status.containerStatuses[0].restartCount>0)].metadata.name}' 2>/dev/null | awk '{print $1}')
show "kubectl logs -n $NS $CRASH --previous --tail=5"
"$K" logs -n "$NS" "$CRASH" --previous --tail=5 2>&1
show "kubectl apply -f $MANI/10-catalog-deploy.yaml   # revert to the canonical Deployment"
apply_ns 10-catalog-deploy.yaml
show "kubectl rollout status deployment/catalog -n $NS --timeout=180s"
"$K" rollout status deployment/catalog -n "$NS" --timeout=180s 2>&1
echo

echo "## step 10: induced failure C, a readiness probe on the wrong path, then the revert"
show "kubectl patch deploy/catalog -n $NS --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/httpGet/path\",\"value\":\"/wrong\"}]'   # deliberate failure"
"$K" patch deploy/catalog -n "$NS" --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/wrong"}]' 2>&1
show "kubectl rollout status deployment/catalog -n $NS --timeout=60s"
"$K" rollout status deployment/catalog -n "$NS" --timeout=60s 2>&1
show "kubectl get pods -n $NS -l app=catalog"
"$K" get pods -n "$NS" -l app=catalog 2>&1
show "kubectl get endpoints catalog -n $NS"
"$K" get endpoints catalog -n "$NS" 2>&1
NOTREADY=$("$K" get pods -n "$NS" -l app=catalog --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1)
show "kubectl describe $NOTREADY -n $NS   # Events only"
"$K" describe "$NOTREADY" -n "$NS" 2>&1 | sed -n '/^Events:/,$p'
show "kubectl patch deploy/catalog -n $NS --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/httpGet/path\",\"value\":\"/readyz\"}]'   # revert"
"$K" patch deploy/catalog -n "$NS" --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/readyz"}]' 2>&1
show "kubectl rollout status deployment/catalog -n $NS --timeout=180s"
"$K" rollout status deployment/catalog -n "$NS" --timeout=180s 2>&1
echo

echo "## step 11: node-level debugging: refused in restricted, admitted in a registered privileged namespace"
NODE=$("$K" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
show "kubectl debug node/$NODE -n $NS --profile=sysadmin --image=$DBG   # the same Pod, in restricted"
"$K" debug node/"$NODE" -n "$NS" --profile=sysadmin --image="$DBG" 2>&1
cat > "$WORK/node-ns.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: p08-03-node-debug
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
EOF
show "kubectl apply -f node-debug-namespace.yaml   # namespace $NN"
"$K" apply -f "$WORK/node-ns.yaml" 2>&1
show "kubectl debug node/$NODE -n $NN --profile=sysadmin --image=$DBG"
"$K" debug node/"$NODE" -n "$NN" --profile=sysadmin --image="$DBG" 2>&1
NPOD=$("$K" get pods -n "$NN" -o name 2>/dev/null | head -1)
show "kubectl get pods -n $NN -o wide"
"$K" get pods -n "$NN" -o wide 2>&1
show "kubectl get $NPOD -n $NN -o jsonpath='hostPID={.spec.hostPID} hostNetwork={.spec.hostNetwork} hostIPC={.spec.hostIPC} node={.spec.nodeName}'"
"$K" get "$NPOD" -n "$NN" -o jsonpath='hostPID={.spec.hostPID} hostNetwork={.spec.hostNetwork} hostIPC={.spec.hostIPC} node={.spec.nodeName}' 2>&1; echo
echo

echo "## step 12: back to known-good, then delete the namespaces"
show "kubectl get pods -n $NS"
"$K" get pods -n "$NS" 2>&1
show "kubectl get deploy catalog -n $NS -o jsonpath='{.spec.template.spec.containers[0].image}'"
"$K" get deploy catalog -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1; echo
show "kubectl delete namespace $NS --wait --timeout=300s"
"$K" delete namespace "$NS" --wait --timeout=300s 2>&1
show "kubectl delete namespace $NN --wait --timeout=300s"
"$K" delete namespace "$NN" --wait --timeout=300s 2>&1
