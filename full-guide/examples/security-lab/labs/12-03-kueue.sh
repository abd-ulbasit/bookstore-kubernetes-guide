#!/usr/bin/env bash
# Lab 12.03, Kueue step: install the pinned JobSet and Kueue charts, show a Job
# with no queue label held suspended, run the two-worker gang, then remove
# everything, CRDs included.
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory, and only when no other heavy install is running. It needs Helm
# and network access to registry.k8s.io. It creates three namespaces named
# with the prefix in LAB_PREFIX (default p12-03): <prefix>-jobset and
# <prefix>-kueue for the controllers, and <prefix>-ml standing in for
# bookstore-ml. The ML namespace carries the label the chart values select on,
# app.kubernetes.io/part-of=bookstore-ml, so the chart values apply to it.
#
# The cluster-scoped objects it creates (the ResourceFlavor, the ClusterQueue,
# the CRDs, the webhook configurations and the cluster roles) are removed at
# the end, and the script prints a count of the Kueue and JobSet CRDs left.
set +e

K="${KUBECTL:-kubectl}"
PFX="${LAB_PREFIX:-p12-03}"
JS="$PFX-jobset"
KQ="$PFX-kueue"
ML="$PFX-ml"
B=examples/bookstore/ml/batch
JOBSET_VERSION="0.11.1"
KUEUE_VERSION="0.17.0"

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

show() { printf '$ %s\n' "$*"; }
# The chapter's files name bookstore-ml; the lab applies them with only that
# name replaced.
lab() { sed "s/bookstore-ml/$ML/g" "$1"; }
crds() { "$K" get crd -o name 2>/dev/null | grep -c -E 'kueue\.x-k8s\.io|jobset\.x-k8s\.io'; }

echo
echo "## step 1: neither Kueue nor JobSet is installed"
show "kubectl get crd -o name | grep -c -E 'kueue|jobset'"
crds

echo
echo "## step 2: namespaces, labelled restricted before anything is installed"
for ns in "$JS" "$KQ" "$ML"; do
  show "kubectl create namespace $ns"
  "$K" create namespace "$ns" 2>&1
  "$K" label namespace "$ns" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/audit-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=latest >/dev/null 2>&1
done
show "kubectl label namespace $ML app.kubernetes.io/part-of=bookstore-ml"
"$K" label namespace "$ML" app.kubernetes.io/part-of=bookstore-ml 2>&1

echo
echo "## step 3: the pinned charts"
show "helm install jobset oci://registry.k8s.io/jobset/charts/jobset --version $JOBSET_VERSION -n $JS --wait (image pinned by digest)"
helm install jobset oci://registry.k8s.io/jobset/charts/jobset --version "$JOBSET_VERSION" \
  -n "$JS" --wait --timeout 5m \
  --set image.tag='v0.11.1@sha256:88154814bfd507042c5e7d3ea551c0a214a6d9b319e1fb2c7110532055c0b5c5' 2>&1 \
  | grep -E '^(NAME|NAMESPACE|STATUS|Error)'
show "helm install kueue oci://registry.k8s.io/kueue/charts/kueue --version $KUEUE_VERSION -n $KQ --wait -f $B/kueue-values.yaml"
helm install kueue oci://registry.k8s.io/kueue/charts/kueue --version "$KUEUE_VERSION" \
  -n "$KQ" --wait --timeout 5m -f "$B/kueue-values.yaml" 2>&1 \
  | grep -E '^(NAME|NAMESPACE|STATUS|Error)'
show "kubectl get pods -n $JS"
"$K" get pods -n "$JS" -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,PHASE:.status.phase 2>&1
show "kubectl get pods -n $KQ"
"$K" get pods -n "$KQ" -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,PHASE:.status.phase 2>&1

echo
echo "## step 4: the queue objects and the ServiceAccount"
for f in kueue-resourceflavor kueue-clusterqueue kueue-localqueue recommender-batch-serviceaccount; do
  show "kubectl apply -f $f.yaml (namespace $ML)"
  lab "$B/$f.yaml" | "$K" apply -f - 2>&1
done
show "kubectl get clusterqueue $ML-cq"
for _ in $(seq 1 30); do
  "$K" get clusterqueue "$ML-cq" -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null | grep -q True && break
  sleep 2
done
"$K" get clusterqueue "$ML-cq" 2>&1

echo
echo "## step 5: a Job with no queue label"
show "kubectl apply -f unlabelled-probe.yaml (namespace $ML)"
lab "$B/unlabelled-probe.yaml" | "$K" apply -f - 2>&1
show "kubectl get job unlabelled-probe -n $ML -o jsonpath='{.spec.suspend}'"
"$K" get job unlabelled-probe -n "$ML" -o jsonpath='{.spec.suspend}{"\n"}' 2>&1
show "kubectl get pods -n $ML -l job-name=unlabelled-probe"
"$K" get pods -n "$ML" -l job-name=unlabelled-probe 2>&1
show "kubectl delete job unlabelled-probe -n $ML"
"$K" delete job unlabelled-probe -n "$ML" 2>&1

echo
echo "## step 6: the two-worker gang"
show "kubectl apply -f recommender-jobset.yaml (namespace $ML)"
lab "$B/recommender-jobset.yaml" | "$K" apply -f - 2>&1
show "kubectl wait --for=condition=Completed jobset/recommender-train -n $ML --timeout=240s"
"$K" wait --for=condition=Completed jobset/recommender-train -n "$ML" --timeout=240s 2>&1
show "kubectl get workloads.kueue.x-k8s.io -n $ML"
"$K" get workloads.kueue.x-k8s.io -n "$ML" 2>&1
show "kubectl get pods -n $ML -l app.kubernetes.io/component=recommender-train -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startTime"
"$K" get pods -n "$ML" -l app.kubernetes.io/component=recommender-train \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startTime 2>&1
show "kubectl get jobset recommender-train -n $ML"
"$K" get jobset recommender-train -n "$ML" 2>&1

echo
echo "## step 7: quota below what the gang needs, then restored"
show "kubectl delete jobset recommender-train -n $ML"
"$K" delete jobset recommender-train -n "$ML" 2>&1
show "kubectl patch clusterqueue $ML-cq (cpu nominalQuota to 0)"
"$K" patch clusterqueue "$ML-cq" --type=json \
  -p '[{"op":"replace","path":"/spec/resourceGroups/0/flavors/0/resources/0/nominalQuota","value":"0"}]' 2>&1
show "kubectl apply -f recommender-jobset.yaml (namespace $ML)"
lab "$B/recommender-jobset.yaml" | "$K" apply -f - 2>&1
sleep 15
show "kubectl get workloads.kueue.x-k8s.io -n $ML"
"$K" get workloads.kueue.x-k8s.io -n "$ML" 2>&1
show "kubectl get pods -n $ML -l app.kubernetes.io/component=recommender-train"
"$K" get pods -n "$ML" -l app.kubernetes.io/component=recommender-train 2>&1
show "kubectl patch clusterqueue $ML-cq (cpu nominalQuota back to 4)"
"$K" patch clusterqueue "$ML-cq" --type=json \
  -p '[{"op":"replace","path":"/spec/resourceGroups/0/flavors/0/resources/0/nominalQuota","value":"4"}]' 2>&1
show "kubectl wait --for=condition=Completed jobset/recommender-train -n $ML --timeout=240s"
"$K" wait --for=condition=Completed jobset/recommender-train -n "$ML" --timeout=240s 2>&1

echo
echo "## step 8: remove everything, CRDs included"
show "kubectl delete jobset,localqueue --all -n $ML; kubectl delete clusterqueue,resourceflavor (the lab's two)"
"$K" delete jobset --all -n "$ML" --wait=true --timeout=120s 2>&1
"$K" delete localqueue --all -n "$ML" --wait=true --timeout=120s 2>&1
"$K" delete clusterqueue "$ML-cq" --wait=true --timeout=120s 2>&1
"$K" delete resourceflavor "$ML-flavor" --wait=true --timeout=120s 2>&1
show "helm uninstall kueue -n $KQ; helm uninstall jobset -n $JS"
helm uninstall kueue -n "$KQ" --wait 2>&1
helm uninstall jobset -n "$JS" --wait 2>&1
show "kubectl delete namespace $ML $KQ $JS --wait=true"
"$K" delete namespace "$ML" "$KQ" "$JS" --wait=true --timeout=240s 2>&1
show "kubectl get crd -o name | grep -E 'kueue|jobset' (what the uninstalls left behind)"
"$K" get crd -o name 2>/dev/null | grep -E 'kueue\.x-k8s\.io|jobset\.x-k8s\.io'
show "kubectl delete (each CRD listed above)"
for c in $("$K" get crd -o name 2>/dev/null | grep -E 'kueue\.x-k8s\.io|jobset\.x-k8s\.io'); do
  "$K" delete "$c" --wait=true --timeout=240s 2>&1
done
show "kubectl get crd -o name | grep -c -E 'kueue|jobset'"
crds
show "kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration -o name | grep -c -E 'kueue|jobset'"
"$K" get validatingwebhookconfiguration,mutatingwebhookconfiguration -o name 2>/dev/null | grep -c -E 'kueue|jobset'
show "kubectl get clusterrole -o name | grep -c -E 'kueue|jobset'"
"$K" get clusterrole -o name 2>/dev/null | grep -c -E 'kueue|jobset'
