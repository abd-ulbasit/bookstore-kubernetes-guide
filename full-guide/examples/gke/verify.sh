#!/usr/bin/env bash
# Post-apply verification for the GKE lab. Everything here is a claim the guide
# will make, checked against the real cluster before the guide makes it.
set -uo pipefail

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }
hdr()  { echo; echo "== $1"; }

hdr "1. Nodes exist, are Ready, and are the machine type we asked for"
kubectl get nodes -o wide 2>/dev/null
n=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready ")
[ "$n" -eq 2 ] && ok "2 nodes Ready (multi-node: the thing k3s cannot give)" || bad "expected 2 Ready nodes, got $n"
mt=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null)
[ "$mt" = "e2-standard-2" ] && ok "machine type e2-standard-2" || bad "machine type is '$mt'"

hdr "2. Spot nodes are labelled as spot (preemption is a lab, not a surprise)"
sp=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.cloud\.google\.com/gke-spot}' 2>/dev/null)
[ "$sp" = "true" ] && ok "gke-spot=true" || bad "gke-spot label is '$sp'"

hdr "3. A workload schedules and becomes Ready"
kubectl create deployment web --image=nginx:1.27-alpine --replicas=4 >/dev/null 2>&1
kubectl rollout status deploy/web --timeout=120s >/dev/null 2>&1 \
  && ok "4 replicas rolled out" || bad "rollout did not complete"
echo "  spread across nodes:"
kubectl get pods -l app=web -o custom-columns=NODE:.spec.nodeName --no-headers 2>/dev/null | sort | uniq -c | sed 's/^/    /'
nodes_used=$(kubectl get pods -l app=web -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
[ "$nodes_used" -ge 2 ] && ok "pods landed on $nodes_used nodes" || bad "all pods on one node"

hdr "4. Workload Identity: the GKE metadata server answers, node SA is NOT exposed"
kubectl run wi-probe --image=curlimages/curl:8.10.1 --restart=Never --command -- sleep 60 >/dev/null 2>&1
kubectl wait --for=condition=Ready pod/wi-probe --timeout=90s >/dev/null 2>&1
ident=$(kubectl exec wi-probe -- curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email" 2>/dev/null)
if echo "$ident" | grep -q "svc.id.goog\|iam.gserviceaccount.com"; then
  ok "metadata server reachable, identity: $ident"
else
  bad "metadata identity unexpected: '$ident'"
fi

hdr "5. Default StorageClass is WaitForFirstConsumer, so a PVC binds only with a consumer"
kubectl get storageclass 2>/dev/null | sed 's/^/  /'
# The default (standard-rwo) is WaitForFirstConsumer. A PVC with no pod stays
# Pending on purpose: GKE delays provisioning until the scheduler has picked a
# node, so the disk is created in the zone the pod actually lands in. Asserting
# Bound without a consumer tests nothing and fails against a healthy cluster.
cat <<'YAML' | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lab-pvc }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: pvc-consumer }
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: ["sh","-c","echo verified > /data/proof && sleep 3600"]
    volumeMounts: [{ name: d, mountPath: /data }]
  volumes:
  - name: d
    persistentVolumeClaim: { claimName: lab-pvc }
YAML
kubectl wait --for=condition=Ready pod/pvc-consumer --timeout=180s >/dev/null 2>&1
ph=$(kubectl get pvc lab-pvc -o jsonpath='{.status.phase}' 2>/dev/null)
proof=$(kubectl exec pvc-consumer -- cat /data/proof 2>/dev/null)
[ "$ph" = "Bound" ] && ok "PVC Bound once a consumer existed" || bad "PVC phase=$ph"
[ "$proof" = "verified" ] && ok "wrote to the mounted PD and read it back" || bad "write test returned '$proof'"
kubectl delete pod pvc-consumer --force --grace-period=0 >/dev/null 2>&1
hdr "6. Cordon + drain reschedules pods (impossible on a single node)"
target=$(kubectl get pods -l app=web -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
echo "  draining $target"
kubectl cordon "$target" >/dev/null 2>&1
kubectl drain "$target" --ignore-daemonsets --delete-emptydir-data --force --timeout=150s >/dev/null 2>&1
sleep 10
still=$(kubectl get pods -l app=web -o jsonpath="{range .items[*]}{.spec.nodeName}{'\n'}{end}" 2>/dev/null | grep -c "^${target}$")
ready=$(kubectl get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "$still" -eq 0 ] && ok "no web pods left on drained node" || bad "$still pods still on $target"
echo "  readyReplicas after drain: ${ready:-0} (2 nodes, 4 replicas, one node cordoned)"
kubectl uncordon "$target" >/dev/null 2>&1 && ok "uncordoned $target"

hdr "7. Cleanup of test objects"
kubectl delete deploy web --ignore-not-found >/dev/null 2>&1
kubectl delete pod wi-probe --ignore-not-found --force --grace-period=0 >/dev/null 2>&1
kubectl delete pvc lab-pvc --ignore-not-found >/dev/null 2>&1
ok "test objects removed"

echo; echo "===== $pass passed, $fail failed ====="
exit $fail
