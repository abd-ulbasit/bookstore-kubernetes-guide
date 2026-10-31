#!/usr/bin/env bash
# Lab 06.04: autoscaling as a cost attack. Tier A (kind).
#
# Run this ONLY against a three-node kind cluster you own, from any directory,
# one phase at a time:
#
#   06-04.sh metrics    metrics-server, the refusal, then kubelet serving
#                       certificates (the secure fix)
#   06-04.sh bookstore  the pieces of the Bookstore that catalog needs
#   06-04.sh spread     catalog's three replicas, placed on the two workers
#   06-04.sh idle       the chapter's HPA at its shipped target, left idle
#   06-04.sh load1      the 06.06 load Job, watched at the shipped target
#   06-04.sh load2 N    the same Job, with the CPU target lowered to N percent,
#                       until the HPA holds at maxReplicas
#   06-04.sh after      the HPA after the Job has ended: the scale-in
#   06-04.sh cleanup    remove everything the phases made, then check
#
# The phases split the run so that each fits one foreground command. The
# workflow lab-on-runner.yml runs them in this order on a GitHub Actions
# runner, which has room for the load. Set LAB_WORK to one directory for all
# phases.
#
# The Job is a tight loop of ten parallel curl calls. On a small shared host it
# drove the load average near 30 on four cores, slowed the API and coincided
# with a restart of kube-controller-manager and kube-scheduler, so the first
# run on such a host stopped and cleaned up. If your control plane restarts,
# do the same, or lower the `seq 10` in the Job's loop first.
#
# Catalog spreads over kubernetes.io/hostname with DoNotSchedule. The shipped
# Deployment sets nodeTaintsPolicy: Honor on that constraint, so the tainted
# control-plane node is not counted as an empty domain and all three replicas
# land on the two workers. The spread phase shows that placement.
#
# It creates two namespaces, metrics-server and bookstore, under the
# chapter's own names, so it refuses to start a phase if either exists. It
# also creates objects outside them, and removes them in the cleanup phase:
# the metrics-server chart's cluster-scoped objects and its RoleBinding in
# kube-system, the three Bookstore PriorityClasses, the kubelet serving
# CertificateSigningRequests, and a line in each node's kubelet config
# (the original is kept as config.yaml.orig and put back).
#
# The kubelet change is the secure route to resource metrics: each kubelet
# asks the cluster CA for a serving certificate that lists its IP address,
# and an administrator approves the request after checking it. The insecure
# flag that skips verification is never used.
set +e

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

# The lab API server restarts now and then when the host is busy, and answers
# EOF or a bare Forbidden until its authorizer has synced. Retry a kubectl call
# that failed that way, so the transcript shows the answer and not the restart.
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

ctx=$(command kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

guide=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1   # full-guide/
work=${LAB_WORK:-$(mktemp -d)} && mkdir -p "$work/examples/bookstore" && cd "$work" || exit 1
[ -e examples/bookstore/raw-manifests ] || ln -s "$guide/examples/bookstore/raw-manifests" examples/bookstore/raw-manifests
raw=examples/bookstore/raw-manifests
chap06="$guide/06-production-readiness/06-capacity-and-cost.md"

nodes() { command kubectl get nodes -o name | sed 's|node/||'; }

phase=${1:-}
case "$phase" in

metrics)
  if command kubectl get ns metrics-server >/dev/null 2>&1; then echo 'refusing to run: namespace metrics-server exists' >&2; exit 2; fi
  if command kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then echo 'refusing to run: the metrics API is already registered' >&2; exit 2; fi
  [ "$(nodes | wc -l | tr -d ' ')" -ge 3 ] || { echo 'refusing to run: need three nodes' >&2; exit 2; }
  echo '## step 0a: the cluster, and no resource metrics yet'
  run <<'CMD'
kubectl get nodes
CMD
  run <<'CMD'
kubectl get apiservice v1beta1.metrics.k8s.io
CMD
  run <<'CMD'
kubectl top nodes
CMD

  echo '## step 0b: metrics-server, installed as in 06.01 step 1'
  run <<'CMD'
kubectl create namespace metrics-server
CMD
  run <<'CMD'
kubectl label namespace metrics-server pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted
CMD
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1
  helm repo update metrics-server >/dev/null 2>&1
  run <<'CMD'
helm install metrics-server metrics-server/metrics-server --version 3.14.0 --namespace metrics-server
CMD
  run <<'CMD'
kubectl -n metrics-server get deploy metrics-server -o jsonpath='{.metadata.labels.helm\.sh/chart}{"\n"}{.spec.template.spec.containers[0].image}{"\n"}'
CMD
  for i in $(seq 1 60); do
    command kubectl -n metrics-server logs deploy/metrics-server --tail=20 2>/dev/null | grep -q 'Failed to scrape node' && break
    sleep 5
  done
  run <<'CMD'
kubectl -n metrics-server get pods
CMD
  run <<'CMD'
kubectl get apiservice v1beta1.metrics.k8s.io
CMD
  run <<'CMD'
kubectl top nodes
CMD
  run <<'CMD'
kubectl -n metrics-server logs deploy/metrics-server --tail=3
CMD

  echo '## step 0c: kubelet serving certificates'
  run <<'CMD'
kubectl get csr
CMD
  run <<'CMD'
for n in $(kubectl get nodes -o name | sed 's|node/||'); do
  docker exec "$n" sh -c 'cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.orig && echo "serverTLSBootstrap: true" >> /var/lib/kubelet/config.yaml && systemctl restart kubelet && grep serverTLSBootstrap /var/lib/kubelet/config.yaml'
done
CMD
  want=$(nodes | wc -l | tr -d ' ')
  for i in $(seq 1 60); do
    have=$(command kubectl get csr -o jsonpath='{range .items[*]}{.spec.signerName}{"\n"}{end}' 2>/dev/null | grep -c '^kubernetes.io/kubelet-serving$')
    [ "$have" -ge "$want" ] && break
    sleep 3
  done
  # A new cluster still holds the CSRs of the nodes' own client certificates,
  # which are Approved already. Only the serving requests are listed, checked
  # and approved: they are the ones with this signer.
  run <<'CMD'
kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving
CMD
  echo '## step 0d: check each request before approving it'
  run <<'CMD'
for c in $(kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o name); do
  u=$(kubectl get "$c" -o jsonpath='{.spec.username}')
  s=$(kubectl get "$c" -o jsonpath='{.spec.request}' | base64 -d | openssl req -noout -text | grep -A1 'Alternative Name' | tail -1 | sed 's/^ *//')
  echo "${c#*/} $u $s"
done
CMD
  # Approve only if every request came from the node it names.
  ok=1
  for c in $(command kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o name); do
    u=$(command kubectl get "$c" -o jsonpath='{.spec.username}')
    n=${u#system:node:}
    nodes | grep -qx "$n" || ok=0
  done
  [ "$ok" = 1 ] || { echo 'stopping: a request does not come from a node' >&2; exit 3; }
  run <<'CMD'
kubectl certificate approve $(kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o name)
CMD
  for i in $(seq 1 60); do
    cert=$(command kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o jsonpath='{range .items[*]}{.status.certificate}{"\n"}{end}' 2>/dev/null | grep -c .)
    [ "$cert" -ge "$want" ] && break
    sleep 3
  done
  run <<'CMD'
kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving
CMD

  echo '## step 0e: metrics-server serves, with verification still on'
  need command kubectl -n metrics-server rollout status deployment/metrics-server --timeout=300s
  for i in $(seq 1 60); do
    command kubectl top nodes >/dev/null 2>&1 && break
    sleep 5
  done
  run <<'CMD'
kubectl -n metrics-server rollout status deployment/metrics-server --timeout=300s
CMD
  run <<'CMD'
kubectl get apiservice v1beta1.metrics.k8s.io
CMD
  run <<'CMD'
kubectl top nodes
CMD
  run <<'CMD'
kubectl -n metrics-server get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'
CMD
  run <<'CMD'
kubectl -n metrics-server get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -c insecure
CMD
  ;;

bookstore)
  if command kubectl get ns bookstore >/dev/null 2>&1; then echo 'refusing to run: namespace bookstore exists' >&2; exit 2; fi
  echo '## step 0f: the Bookstore pieces that catalog needs'
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
CMD
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
CMD
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/15-catalog-config.yaml
CMD
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/16-db-credentials.yaml
CMD
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/35-priorityclasses.yaml
CMD
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/20-postgres-statefulset.yaml
CMD
  need command kubectl -n bookstore rollout status statefulset/postgres --timeout=300s
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/21-db-migrate-job.yaml
CMD
  need command kubectl -n bookstore wait --for=condition=complete job/db-migrate --timeout=300s
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/12-redis.yaml
CMD
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/10-catalog-deploy.yaml
CMD
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/40-services.yaml
CMD
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/60-networkpolicy.yaml
CMD
  ;;

spread)
  command kubectl get ns bookstore >/dev/null 2>&1 || { echo 'refusing to run: run the bookstore phase first' >&2; exit 2; }
  echo '## step 0g: the third catalog replica, placed on the two workers'
  need command kubectl -n bookstore rollout status deployment/catalog --timeout=300s
  run <<'CMD'
kubectl get deployment catalog -n bookstore -o jsonpath='{.spec.template.spec.topologySpreadConstraints}{"\n"}'
CMD
  run <<'CMD'
kubectl rollout status deployment/catalog -n bookstore
CMD
  run <<'CMD'
kubectl get pods -n bookstore -l app=catalog -o wide
CMD
  run <<'CMD'
kubectl get events -n bookstore --field-selector reason=FailedScheduling
CMD
  ;;

idle)
  command kubectl get ns bookstore >/dev/null 2>&1 || { echo 'refusing to run: run the bookstore phase first' >&2; exit 2; }
  echo '## step 2: the HPA at its shipped target, with no load'
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/82-hpa-catalog.yaml
CMD
  for i in $(seq 1 40); do
    command kubectl get hpa catalog -n bookstore --no-headers 2>/dev/null | grep -q '[0-9]%/70%' && break
    sleep 5
  done
  run <<'CMD'
kubectl get hpa catalog -n bookstore
CMD
  run <<'CMD'
kubectl describe hpa catalog -n bookstore | sed -n '/^Reference:/,$p'
CMD
  echo '## step 2b: the same HPA over the next six minutes, still no load'
  run <<'CMD'
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt 360 ]; do
  echo "t=+$(( $(date +%s) - start ))s"
  kubectl get hpa catalog -n bookstore --no-headers
  kubectl top pods -n bookstore -l app=catalog --no-headers
  sleep 30
done
CMD
  ;;

load1)
  command kubectl get hpa catalog -n bookstore >/dev/null 2>&1 || { echo 'refusing to run: run the idle phase first' >&2; exit 2; }
  echo '## step 4: the 06.06 load Job, with the loop lengthened to 420 seconds'
  python3 -I - "$chap06" <<'PY'
import re, sys
md = open(sys.argv[1]).read()
sec = md.split("### 1. Measure catalog's real usage", 1)[1].split("\n### 2.", 1)[0]
blocks = re.findall(r"```yaml\n(.*?)```", sec, re.S)
assert "kind: ServiceAccount" in blocks[0] and "kind: Job" in blocks[1]
open("load-allow.yaml", "w").write(blocks[0])
open("load-catalog.yaml.orig", "w").write(blocks[1])
PY
  sed 's/+ 180/+ 420/' load-catalog.yaml.orig > load-catalog.yaml
  run <<'CMD'
grep -n 'end=' load-catalog.yaml
CMD
  run <<'CMD'
kubectl apply -f load-allow.yaml
CMD
  run <<'CMD'
kubectl apply -f load-catalog.yaml
CMD
  need command kubectl -n bookstore wait --for=condition=Ready pod -l role=load-generator --timeout=180s
  echo '## step 4: the load Pod reaches catalog through the allow policies'
  run <<'CMD'
kubectl -n bookstore exec job/load-catalog -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://catalog.bookstore.svc.cluster.local/books
CMD
  code=$(command kubectl -n bookstore exec job/load-catalog -- curl -sS -m 5 -o /dev/null -w '%{http_code}' http://catalog.bookstore.svc.cluster.local/books 2>/dev/null)
  [ "$code" = 200 ] || { echo "stopping: the load Pod cannot reach catalog (answer: $code)" >&2; exit 3; }
  echo '## step 4a: at the shipped 70 percent target'
  run <<'CMD'
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt 120 ]; do
  echo "t=+$(( $(date +%s) - start ))s"
  kubectl get hpa catalog -n bookstore --no-headers
  kubectl top pods -n bookstore --no-headers
  sleep 20
done
CMD
  ;;

load2)
  target=${2:?usage: 06-04.sh load2 PERCENT}
  command kubectl -n bookstore get job load-catalog >/dev/null 2>&1 || { echo 'refusing to run: run the load1 phase first' >&2; exit 2; }
  echo "## step 4b: the CPU target lowered to $target percent, bounds unchanged"
  run <<CMD
kubectl patch hpa catalog -n bookstore --type json -p '[{"op":"replace","path":"/spec/metrics/0/resource/target/averageUtilization","value":$target}]'
CMD
  run <<'CMD'
kubectl get hpa catalog -n bookstore -o jsonpath='min={.spec.minReplicas} max={.spec.maxReplicas} target={.spec.metrics[0].resource.target.averageUtilization}{"\n"}'
CMD
  run <<'CMD'
start=$(date +%s)
held=0
while [ $(( $(date +%s) - start )) -lt 300 ]; do
  echo "t=+$(( $(date +%s) - start ))s"
  kubectl get hpa catalog -n bookstore --no-headers
  kubectl top pods -n bookstore --no-headers
  if [ "$(kubectl get hpa catalog -n bookstore -o jsonpath='{.status.currentReplicas}')" = 6 ]; then held=$((held + 1)); fi
  if [ "$held" = 3 ]; then
    echo "-- the HPA has read 6 replicas on 3 samples, with the Job still running"
    kubectl describe hpa catalog -n bookstore | sed -n '/^Conditions:/,/^Events:/p'
  fi
  sleep 20
done
CMD
  echo '## step 4c: the HPA at the ceiling, and the end of the Job'
  run <<'CMD'
kubectl describe hpa catalog -n bookstore | sed -n '/^Reference:/,$p'
CMD
  run <<'CMD'
kubectl get deployment catalog -n bookstore
CMD
  run <<'CMD'
kubectl get job load-catalog -n bookstore
CMD
  ;;

after)
  command kubectl get hpa catalog -n bookstore >/dev/null 2>&1 || { echo 'refusing to run: no HPA' >&2; exit 2; }
  echo '## step 4d: after the Job ends'
  run <<'CMD'
kubectl get job load-catalog -n bookstore
CMD
  run <<'CMD'
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt 660 ]; do
  echo "t=+$(( $(date +%s) - start ))s"
  kubectl get hpa catalog -n bookstore --no-headers
  kubectl top pods -n bookstore -l app=catalog --no-headers
  sleep 30
done
CMD
  run <<'CMD'
kubectl describe hpa catalog -n bookstore | sed -n '/^Events:/,$p'
CMD
  ;;

cleanup)
  echo '## cleanup'
  run <<'CMD'
kubectl delete namespace bookstore --wait=true
CMD
  run <<'CMD'
kubectl delete priorityclass bookstore-critical bookstore-data bookstore-batch
CMD
  run <<'CMD'
helm uninstall metrics-server --namespace metrics-server
CMD
  run <<'CMD'
kubectl delete namespace metrics-server --wait=true
CMD
  run <<'CMD'
for n in $(kubectl get nodes -o name | sed 's|node/||'); do
  docker exec "$n" sh -c 'cp /var/lib/kubelet/config.yaml.orig /var/lib/kubelet/config.yaml && rm /var/lib/kubelet/config.yaml.orig && rm -f /var/lib/kubelet/pki/kubelet-server-*.pem && systemctl restart kubelet && grep -c serverTLSBootstrap /var/lib/kubelet/config.yaml'
done
CMD
  run <<'CMD'
kubectl delete csr --field-selector spec.signerName=kubernetes.io/kubelet-serving
CMD
  echo '## cleanup check'
  run <<'CMD'
kubectl get ns
CMD
  run <<'CMD'
kubectl get crd,validatingwebhookconfigurations,mutatingwebhookconfigurations,csr,priorityclass
CMD
  run <<'CMD'
kubectl get apiservices | grep -v Local
CMD
  run <<'CMD'
kubectl get clusterrole,clusterrolebinding -o name | grep -c metrics-server
CMD
  run <<'CMD'
kubectl -n kube-system get rolebinding -o name | grep -c metrics-server
CMD
  run <<'CMD'
kubectl get nodes
CMD
  ;;

*)
  echo 'usage: 06-04.sh metrics|bookstore|spread|idle|load1|load2 PERCENT|after|cleanup' >&2
  exit 2
  ;;
esac
