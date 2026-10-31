#!/usr/bin/env bash
# Lab 06.05: PodDisruptionBudgets and a node drain. Tier A (kind).
#
# Run this ONLY against a multi-node kind cluster you own (one control-plane
# and at least two workers), from any directory. It creates one namespace,
# p06-finish-pdb, and deletes it at the end. It cordons ONE worker for the
# drain, and uncordons it again when the drain is over, whether or not the
# drain finished. It creates no cluster-scoped objects.
#
# The Bookstore catalog needs its database to report Ready, so the three front
# tiers are stand-ins: a busybox sleeper with the chapter's labels, the
# chapter's ServiceAccounts and the restricted settings, which reports Ready
# 10 seconds after it starts, the way a service with a slow start does, and
# stops 5 seconds after SIGTERM, which a bare sleep would otherwise ignore for
# the full 30. The
# PodDisruptionBudgets are the chapter's own 84-pdb.yaml, copied with the
# namespace renamed. The chapter prints the name bookstore.
#
# A shared cluster may carry taints or a cordon that another run set. The
# script waits for both workers to be free of them (up to ten minutes) and
# refuses to run otherwise.
set +e

NS=p06-finish-pdb

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

# The lab API server restarts now and then when the host is busy, and answers
# EOF or a bare Forbidden until its authorizer has synced. Retry a kubectl call
# that failed that way, so the transcript shows the answer and not the restart.
# Any other failure, such as the refused eviction, is printed as it came.
kubectl() {
  local out rc n=0
  while :; do
    out=$(command kubectl "$@" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [ "$n" -lt 36 ] && printf '%s' "$out" | grep -Eq ': EOF|rbac: RBAC|connection refused|TLS handshake timeout|Client.Timeout|cannot (get|list|watch|create|patch|update|delete) resource'; then
      n=$((n + 1)); sleep 5; continue
    fi
    [ -n "$out" ] && printf '%s\n' "$out"
    return "$rc"
  done
}

# Stop the lab when something that every later step needs has not happened.
need() { "$@" >/dev/null 2>&1 || { echo "stopping: $* failed" >&2; exit 3; }; }

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

guide=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1   # full-guide/
raw="$guide/examples/bookstore/raw-manifests"
work=$(mktemp -d) && cd "$work" || exit 1
NODE=""
trap '[ -n "$NODE" ] && kubectl uncordon "$NODE" >/dev/null 2>&1' EXIT

# Workers are the nodes without the control-plane label.
workers() { kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | sed 's|node/||'; }

echo '## step 0: the cluster, and a wait until both workers are free of taints and cordons'
for attempt in $(seq 1 120); do
  busy=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.taints}{" "}{.spec.unschedulable}{"\n"}{end}' \
    | awk 'NF>1 && ($2!="" || $3=="true")')
  [ -z "$busy" ] && break
  sleep 5
done
if [ -n "$busy" ]; then echo "refusing to run: a worker is tainted or cordoned: $busy" >&2; exit 2; fi
if [ "$(workers | wc -l | tr -d ' ')" -lt 2 ]; then echo 'refusing to run: need two workers' >&2; exit 2; fi
run <<'CMD'
kubectl get nodes
CMD
kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null 2>&1

echo '## step 1: the namespace, the ServiceAccounts and three stand-in workloads'
cat > ns.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
EOF
sed "s/namespace: bookstore/namespace: $NS/" "$raw/05-serviceaccounts-rbac.yaml" > sa.yaml
sed "s/namespace: bookstore/namespace: $NS/" "$raw/84-pdb.yaml" > pdb.yaml

standin() { # name replicas
cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $1
  namespace: $NS
  labels:
    app: $1
spec:
  replicas: $2
  selector:
    matchLabels:
      app: $1
  template:
    metadata:
      labels:
        app: $1
    spec:
      serviceAccountName: $1-sa
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 5
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: $1
          image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
          command: ["sleep", "3600"]
          readinessProbe:
            exec:
              command: ["true"]
            initialDelaySeconds: 10
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: 20m, memory: 32Mi }
            limits: { memory: 64Mi }
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
EOF
}
{ standin catalog 3; echo '---'; standin storefront 2; echo '---'; standin orders 2; } > standins.yaml

run <<CMD
kubectl apply -f ns.yaml
CMD
run <<CMD
kubectl apply -f sa.yaml 2>&1 | grep -E 'catalog-sa|storefront-sa|orders-sa'
CMD
run <<CMD
kubectl apply -f standins.yaml
CMD
run <<CMD
kubectl wait --for=condition=Available deployment --all -n $NS --timeout=600s
CMD
need kubectl wait --for=condition=Ready pod --all -n "$NS" --timeout=600s
run <<CMD
kubectl get pods -n $NS -o wide --sort-by=.metadata.name
CMD

echo '## step 2: add the PodDisruptionBudgets (the chapter step 1)'
run <<CMD
kubectl apply -f pdb.yaml
CMD
need kubectl wait --for=jsonpath='{.status.currentHealthy}'=3 pdb/catalog -n "$NS" --timeout=60s
run <<CMD
kubectl get pdb -n $NS
CMD
run <<CMD
kubectl describe pdb catalog -n $NS | sed -n '1,20p'
CMD

echo '## step 3: a budget set to the replica count refuses the eviction (a deliberate action)'
run <<CMD
kubectl patch pdb catalog -n $NS --type merge -p '{"spec":{"minAvailable":3}}'
CMD
need kubectl wait --for=jsonpath='{.status.disruptionsAllowed}'=0 pdb/catalog -n "$NS" --timeout=60s
run <<CMD
kubectl get pdb catalog -n $NS
CMD
run <<CMD
POD=\$(kubectl get pods -n $NS -l app=catalog -o jsonpath='{.items[0].metadata.name}'); printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"$NS"}}' "\$POD" > eviction.json; kubectl create --raw /api/v1/namespaces/$NS/pods/\$POD/eviction -f eviction.json
CMD
run <<CMD
kubectl describe pdb catalog -n $NS | sed -n '1,20p'
CMD
run <<CMD
kubectl delete pod "\$(kubectl get pods -n $NS -l app=catalog -o jsonpath='{.items[0].metadata.name}')" -n $NS
CMD
run <<CMD
kubectl wait --for=jsonpath='{.status.readyReplicas}'=3 deployment/catalog -n $NS --timeout=120s; kubectl get pods -n $NS -l app=catalog --no-headers | awk '{print \$1, \$2, \$3}'
CMD
run <<CMD
kubectl auth can-i update poddisruptionbudgets.policy -n $NS --as=system:serviceaccount:$NS:catalog-sa
CMD
run <<CMD
kubectl auth can-i create pods/eviction -n $NS --as=system:serviceaccount:$NS:catalog-sa
CMD
run <<CMD
kubectl patch pdb catalog -n $NS --type merge -p '{"spec":{"minAvailable":2}}'
CMD
need kubectl wait --for=jsonpath='{.status.disruptionsAllowed}'=1 pdb/catalog -n "$NS" --timeout=60s
run <<CMD
kubectl get pdb catalog -n $NS
CMD

echo '## step 4: drain the worker that holds the most catalog Pods'
NODE=$(kubectl get pods -n "$NS" -l app=catalog -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
run <<CMD
kubectl get pods -n $NS -o wide --sort-by=.spec.nodeName | awk '{print \$1, \$2, \$3, \$7}'
CMD
run <<CMD
echo "draining $NODE"
CMD
run <<CMD
( trap 'exit 0' TERM; while :; do kubectl get pdb catalog -n $NS --no-headers | awk '{print \$1, \$2, \$4}'; sleep 2; done ) > pdb-poll.txt 2>&1 &
POLL=\$!
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=240s
kill \$POLL; wait \$POLL
CMD
echo '## step 4b: the budget as the drain moved through it (distinct values, in order)'
run <<CMD
uniq pdb-poll.txt
CMD
run <<CMD
kubectl get pods -n $NS -o wide --sort-by=.spec.nodeName | awk '{print \$1, \$2, \$3, \$7}'
CMD
need kubectl wait --for=jsonpath='{.status.disruptionsAllowed}'=1 pdb/catalog -n "$NS" --timeout=300s
run <<CMD
kubectl get pdb -n $NS
CMD
run <<CMD
kubectl get nodes
CMD
run <<CMD
kubectl uncordon "$NODE"
CMD
run <<CMD
kubectl get nodes
CMD
NODE=""

echo '## step 5: clean up'
run <<CMD
kubectl delete ns $NS --wait=true
CMD
run <<CMD
kubectl get ns | grep -c '$NS'
CMD
