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
# Sections 3 to 6 run in their own namespace at the restricted Pod Security
# level, like every lab in this guide, never in default. Fixed name for the
# same reason as verify-netpol below: cleanup deletes it.
ns=verify-lab
kubectl delete ns "$ns" --ignore-not-found >/dev/null 2>&1   # leftover from an interrupted run
kubectl create ns "$ns" >/dev/null 2>&1
kubectl label ns "$ns" pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null 2>&1
k() { kubectl -n "$ns" "$@"; }
cat <<'YAML' | k apply -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata: { name: web }
spec:
  replicas: 4
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:1.27-alpine
        resources: { requests: { cpu: 10m, memory: 32Mi } }
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
YAML
k rollout status deploy/web --timeout=120s >/dev/null 2>&1 \
  && ok "4 replicas rolled out" || bad "rollout did not complete"
echo "  spread across nodes:"
k get pods -l app=web -o custom-columns=NODE:.spec.nodeName --no-headers 2>/dev/null | sort | uniq -c | sed 's/^/    /'
nodes_used=$(k get pods -l app=web -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
[ "$nodes_used" -ge 2 ] && ok "pods landed on $nodes_used nodes" || bad "all pods on one node"

hdr "4. Workload Identity: the GKE metadata server answers, node SA is NOT exposed"
cat <<'YAML' | k apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: { name: wi-probe }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 100, seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: curl
    image: curlimages/curl:8.10.1
    command: ["sleep","60"]
    securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
YAML
k wait --for=condition=Ready pod/wi-probe --timeout=90s >/dev/null 2>&1
ident=$(k exec wi-probe -- curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email" 2>/dev/null)
# Only the Workload Identity pool counts. A node on GKE_METADATA=off answers
# with <sa>@<project>.iam.gserviceaccount.com, which is the leak this check
# exists to catch, so that form must fail.
if echo "$ident" | grep -q "\.svc\.id\.goog$"; then
  ok "metadata server reachable, identity: $ident"
else
  bad "metadata identity is not the Workload Identity pool: node SA may be exposed: '$ident'"
fi

hdr "5. Default StorageClass is WaitForFirstConsumer, so a PVC binds only with a consumer"
kubectl get storageclass 2>/dev/null | sed 's/^/  /'
# The default (standard-rwo) is WaitForFirstConsumer. A PVC with no pod stays
# Pending on purpose: GKE delays provisioning until the scheduler has picked a
# node, so the disk is created in the zone the pod actually lands in. Asserting
# Bound without a consumer tests nothing and fails against a healthy cluster.
# fsGroup makes the new disk writable by the non-root user.
cat <<'YAML' | k apply -f - >/dev/null 2>&1
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
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    fsGroup: 65534
    seccompProfile: { type: RuntimeDefault }
  containers:
  - name: c
    image: busybox:1.36
    command: ["sh","-c","echo verified > /data/proof && sleep 3600"]
    volumeMounts: [{ name: d, mountPath: /data }]
    securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
  volumes:
  - name: d
    persistentVolumeClaim: { claimName: lab-pvc }
YAML
k wait --for=condition=Ready pod/pvc-consumer --timeout=180s >/dev/null 2>&1
ph=$(k get pvc lab-pvc -o jsonpath='{.status.phase}' 2>/dev/null)
proof=$(k exec pvc-consumer -- cat /data/proof 2>/dev/null)
[ "$ph" = "Bound" ] && ok "PVC Bound once a consumer existed" || bad "PVC phase=$ph"
[ "$proof" = "verified" ] && ok "wrote to the mounted PD and read it back" || bad "write test returned '$proof'"
k delete pod pvc-consumer --force --grace-period=0 >/dev/null 2>&1
hdr "6. Cordon + drain reschedules pods (impossible on a single node)"
target=$(k get pods -l app=web -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
echo "  draining $target"
kubectl cordon "$target" >/dev/null 2>&1
kubectl drain "$target" --ignore-daemonsets --delete-emptydir-data --force --timeout=150s >/dev/null 2>&1
sleep 10
still=$(k get pods -l app=web -o jsonpath="{range .items[*]}{.spec.nodeName}{'\n'}{end}" 2>/dev/null | grep -c "^${target}$")
ready=$(k get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "$still" -eq 0 ] && ok "no web pods left on drained node" || bad "$still pods still on $target"
echo "  readyReplicas after drain: ${ready:-0} (2 nodes, 4 replicas, one node cordoned)"
kubectl uncordon "$target" >/dev/null 2>&1 && ok "uncordoned $target" || bad "could not uncordon $target"

hdr "7. NetworkPolicy is enforced: a default-deny policy stops a pod that could connect a moment ago"
# main.tf turns on Dataplane V2 because without it a NetworkPolicy applies
# cleanly and blocks nothing. This is the check that would catch that. A fixed
# namespace name on purpose: it is deleted below, so it must not come from the
# environment. The namespace enforces the restricted Pod Security level.
np_ns=verify-netpol
kubectl delete ns "$np_ns" --ignore-not-found >/dev/null 2>&1   # leftover from an interrupted run
kubectl create ns "$np_ns" >/dev/null 2>&1
kubectl label ns "$np_ns" pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null 2>&1
cat <<'YAML' | kubectl -n "$np_ns" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: { name: np-srv, labels: { app: np-srv } }
spec:
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: nginx
    image: nginxinc/nginx-unprivileged:1.27-alpine
    ports: [{ containerPort: 8080 }]
    resources: { requests: { cpu: 10m, memory: 32Mi } }
    securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
---
apiVersion: v1
kind: Service
metadata: { name: np-srv }
spec: { selector: { app: np-srv }, ports: [{ port: 80, targetPort: 8080 }] }
---
apiVersion: v1
kind: Pod
metadata: { name: np-cli }
spec:
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 100, seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: curl
    image: curlimages/curl:8.10.1
    command: ["sleep","600"]
    resources: { requests: { cpu: 10m, memory: 32Mi } }
    securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
YAML
kubectl -n "$np_ns" wait --for=condition=Ready pod/np-srv pod/np-cli --timeout=120s >/dev/null 2>&1
before=$(kubectl -n "$np_ns" exec np-cli -- curl -s -m 5 -o /dev/null -w '%{http_code}' http://np-srv/ 2>/dev/null)
cat <<'YAML' | kubectl -n "$np_ns" apply -f - >/dev/null 2>&1
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: np-deny }
spec: { podSelector: {}, policyTypes: [Ingress] }
YAML
sleep 8
after=$(kubectl -n "$np_ns" exec np-cli -- curl -s -m 5 -o /dev/null -w '%{http_code}' http://np-srv/ 2>/dev/null)
if [ "$before" != "200" ]; then
  bad "no baseline: the client could not reach the server before any policy (before=$before)"
elif [ "$after" = "000" ]; then
  # curl prints 000 when the connection times out, which is what a drop does
  ok "default-deny blocked traffic (before=$before, after=$after)"
elif [ "$after" = "200" ]; then
  bad "NetworkPolicy not enforced (before=$before, after=$after)"
else
  bad "unexpected answer after the policy, not a clean block (after='$after')"
fi

hdr "8. Cleanup of test objects"
# Wait for verify-lab: its PVC's disk is deleted with it, and a disk left
# behind keeps billing after the cluster is gone.
kubectl delete ns "$ns" --ignore-not-found --timeout=180s >/dev/null 2>&1; gone=$?
kubectl delete ns "$np_ns" --ignore-not-found --wait=false >/dev/null 2>&1; gone2=$?
[ "$gone" -eq 0 ] && [ "$gone2" -eq 0 ] && ok "test objects removed" || bad "test namespaces were not removed"

echo; echo "===== $pass passed, $fail failed ====="
exit $fail
