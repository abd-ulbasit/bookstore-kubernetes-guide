#!/usr/bin/env bash
# Lab 06.01 on a GitHub Actions runner: the real kube-prometheus-stack install.
# Tier A (kind).
#
# Run this ONLY against a three-node kind cluster you own, from any directory.
# The workflow lab-on-runner.yml runs it on a runner, which has the memory the
# lab host lacked. It installs the chart with the chapter's own values, and it
# creates the namespaces monitoring, node-exporter and bookstore under the
# chapter's names, so it refuses to start if any of them exists. The chart's
# CRDs and cluster-scoped objects stay behind, because the runner is thrown
# away after the job. On a cluster you keep, run `helm uninstall` and delete
# the CRDs yourself.
#
# What it shows, in order:
#   1. the stack installed with --wait, monitoring at restricted and
#      node-exporter alone in its own namespace at privileged;
#   2. Prometheus's active targets and a node_ series, read through a
#      port-forward;
#   3. Grafana refusing a request with no credentials, and accepting one with
#      the generated password (the positive control, so the refusal means
#      something);
#   4. the Bookstore's catalog behind the default-deny policy, scraped through
#      the policy's rule 10 by the real Prometheus.
#
# The generated Grafana password is read into a shell variable and used only
# in a curl call that prints the HTTP status. It is never printed.
#
# The images bookstore/catalog:dev must already be loaded into the cluster.
# Step 5 is skipped, and says so, when they are not.
set +e

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

# Stop the lab when something that every later step needs has not happened.
need() { "$@" >/dev/null 2>&1 || { echo "stopping: $* failed" >&2; exit 3; }; }

# One line of the job summary. Diagnostics go to stderr, so the transcript on
# stdout holds only what ran.
SUMMARY=${LAB_SUMMARY:-/dev/null}
summary() { printf '%s\n' "$*" >> "$SUMMARY"; printf 'summary: %s\n' "$*" >&2; }

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac
for ns in monitoring node-exporter bookstore; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then echo "refusing to run: namespace $ns exists" >&2; exit 2; fi
done

guide=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1   # full-guide/
chapter="$guide/06-production-readiness/01-observability-metrics.md"
work=${LAB_WORK:-$(mktemp -d)} && mkdir -p "$work/examples/bookstore" && cd "$work" || exit 1
[ -e examples/bookstore/raw-manifests ] || ln -s "$guide/examples/bookstore/raw-manifests" examples/bookstore/raw-manifests

KPS=92.16.1
fail=0

echo "# Runner recording, from examples/security-lab/labs/06-01.sh."
echo "## runner step 0: the cluster"
run <<'CMD'
kubectl get nodes
CMD
run <<'CMD'
kubectl version
CMD
run <<'CMD'
helm version --short
CMD

echo '## runner step 1: two namespaces and the Grafana admin Secret'
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
helm repo update prometheus-community >/dev/null 2>&1
run <<'CMD'
helm show chart prometheus-community/kube-prometheus-stack --version 92.16.1 | grep -E '^(name|version|appVersion):'
CMD
run <<'CMD'
kubectl create namespace monitoring
kubectl label namespace monitoring \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
kubectl create namespace node-exporter
kubectl label namespace node-exporter \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
CMD

echo "## runner step 2: the chapter's values file, taken from the chapter"
awk "/cat > monitoring-values.yaml <<'EOF'/{f=1;next} f&&/^EOF\$/{exit} f" "$chapter" > monitoring-values.yaml
[ -s monitoring-values.yaml ] || { echo "stopping: the chapter's values file was not found" >&2; exit 3; }
run <<'CMD'
cat monitoring-values.yaml
CMD

echo '## runner step 3: the install, with --wait'
start=$(date +%s)
run <<'CMD'
helm install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --version 92.16.1 \
  --namespace monitoring \
  --values monitoring-values.yaml \
  --wait --timeout 10m
CMD
code=$(helm status kube-prometheus-stack -n monitoring -o json 2>/dev/null | grep -o '"status":"[a-z-]*"' | head -1)
echo "# install took $(( $(date +%s) - start )) seconds"
echo
case "$code" in
  *deployed*) summary "kube-prometheus-stack $KPS: helm install --wait finished ($(( $(date +%s) - start )) s)" ;;
  *) summary "kube-prometheus-stack $KPS: the install did NOT finish ($code)"; fail=1 ;;
esac
run <<'CMD'
kubectl get pods -n monitoring
CMD
run <<'CMD'
kubectl get pods -n node-exporter
CMD
run <<'CMD'
kubectl get events -A --field-selector reason=FailedCreate
CMD
run <<'CMD'
kubectl -n node-exporter get daemonset -o jsonpath='{.items[0].metadata.name} hostNetwork={.items[0].spec.template.spec.hostNetwork} hostPID={.items[0].spec.template.spec.hostPID}{"\n"}'
CMD
notready=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed" {print $2 " " $4}' | tr '\n' ';')
if [ -z "$notready" ]; then summary "every Pod in the cluster is Running or Completed"; else summary "Pods not Running: $notready"; fail=1; fi

echo '## runner step 4: Prometheus and Grafana through port-forwards'
run <<'CMD'
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 >/dev/null 2>&1 &
sleep 8
CMD
# Prometheus scrapes every 30 seconds by default. Wait for the first full pass.
for i in $(seq 1 40); do
  n=$(curl -s 'localhost:9090/api/v1/targets?state=active' | jq '[.data.activeTargets[] | select(.health=="up")] | length' 2>/dev/null)
  [ "${n:-0}" -ge 8 ] && break
  sleep 5
done
sleep 20
run <<'CMD'
curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | [.labels.job, .labels.namespace, .health] | @tsv' | sort
CMD
run <<'CMD'
curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | .health' | sort | uniq -c
CMD
up=$(curl -s 'localhost:9090/api/v1/targets?state=active' | jq '[.data.activeTargets[] | select(.health=="up")] | length' 2>/dev/null)
total=$(curl -s 'localhost:9090/api/v1/targets?state=active' | jq '.data.activeTargets | length' 2>/dev/null)
summary "Prometheus active targets: ${up:-?} up of ${total:-?}"
run <<'CMD'
curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.health!="up") | [.labels.job, .scrapeUrl, .lastError] | @tsv' | sort
CMD
echo '## runner step 4b: node-exporter, in its own namespace, still feeds node_ series'
run <<'CMD'
curl -s 'localhost:9090/api/v1/query' --data-urlencode 'query=count(node_cpu_seconds_total) by (namespace)' \
  | jq -r '.data.result[] | [.metric.namespace, .value[1]] | @tsv'
CMD
run <<'CMD'
curl -s 'localhost:9090/api/v1/query' --data-urlencode 'query=count(up{job="node-exporter"} == 1)' \
  | jq -r '.data.result[0].value[1]'
CMD

echo '## runner step 4c: Grafana without credentials, then with them'
run <<'CMD'
curl -s -o /dev/null -w '%{http_code}\n' localhost:3000/api/org
CMD
GPW=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
echo '## runner step 4d: the positive control, so the refusal above means something'
run <<'CMD'
curl -s -o /dev/null -w '%{http_code}\n' -u "admin:$GPW" localhost:3000/api/org
CMD
no_cred=$(curl -s -o /dev/null -w '%{http_code}' localhost:3000/api/org)
with_cred=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$GPW" localhost:3000/api/org)
unset GPW
summary "Grafana /api/org without credentials: $no_cred; with the generated admin password: $with_cred"
[ "$no_cred" = 401 ] && [ "$with_cred" = 200 ] || fail=1

echo '## runner step 5: the Bookstore catalog behind default-deny, scraped by the real Prometheus'
if docker exec "$(kubectl get nodes -o name | sed -n 's|node/||p' | head -1)" crictl images 2>/dev/null | grep -q 'bookstore/catalog'; then
  raw=examples/bookstore/raw-manifests
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
kubectl apply -f examples/bookstore/raw-manifests/15-catalog-config.yaml
kubectl apply -f examples/bookstore/raw-manifests/16-db-credentials.yaml
kubectl apply -f examples/bookstore/raw-manifests/35-priorityclasses.yaml
CMD
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/20-postgres-statefulset.yaml
kubectl -n bookstore rollout status statefulset/postgres --timeout=300s
kubectl apply -f examples/bookstore/raw-manifests/21-db-migrate-job.yaml
kubectl -n bookstore wait --for=condition=complete job/db-migrate --timeout=300s
CMD
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/12-redis.yaml
kubectl apply -f examples/bookstore/raw-manifests/10-catalog-deploy.yaml
kubectl apply -f examples/bookstore/raw-manifests/40-services.yaml
kubectl apply -f examples/bookstore/raw-manifests/60-networkpolicy.yaml
kubectl -n bookstore rollout status deployment/catalog --timeout=300s
CMD
  echo '## runner step 5b: the ServiceMonitor and the PrometheusRule (section 3 and 6)'
  run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/80-servicemonitor.yaml
kubectl apply -f examples/bookstore/raw-manifests/81-prometheusrule.yaml
CMD
  for i in $(seq 1 40); do
    h=$(curl -s 'localhost:9090/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | select(.labels.namespace=="bookstore") | .health' 2>/dev/null | sort -u | tr '\n' ' ')
    case "$h" in *up*) break ;; esac
    sleep 5
  done
  sleep 20
  echo '## runner step 5c: the Prometheus pods the rule admits, and the Bookstore targets'
  run <<'CMD'
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus
CMD
  run <<'CMD'
curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.labels.namespace=="bookstore") | [.labels.job, .labels.namespace, .health] | @tsv' | sort
CMD
  run <<'CMD'
curl -s 'localhost:9090/api/v1/rules' \
  | jq -r '.data.groups[] | select(.name=="bookstore-catalog.rules") | .rules[] | [.name, .state, .health] | @tsv'
CMD
  # CatalogAbsent holds while no catalog target is up. Wait for it to clear.
  for i in $(seq 1 40); do
    st=$(curl -s 'localhost:9090/api/v1/rules' | jq -r '.data.groups[] | select(.name=="bookstore-catalog.rules") | .rules[] | select(.name=="CatalogAbsent") | .state' 2>/dev/null)
    [ "$st" = inactive ] && break
    sleep 5
  done
  echo '## runner step 5d: the rules again, once the targets have been scraped'
  run <<'CMD'
curl -s 'localhost:9090/api/v1/rules' \
  | jq -r '.data.groups[] | select(.name=="bookstore-catalog.rules") | .rules[] | [.name, .state, .health] | @tsv'
CMD
  run <<'CMD'
curl -s 'localhost:9090/api/v1/query' --data-urlencode 'query=sum(rate(http_requests_total{namespace="bookstore",handler!="metrics"}[2m])) by (handler)' \
  | jq -r '.data.result[] | .metric.handler' | sort
CMD
  bt=$(curl -s 'localhost:9090/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | select(.labels.namespace=="bookstore" and .labels.job=="catalog") | .health' 2>/dev/null | sort -u | tr '\n' ' ')
  summary "Prometheus scrape of bookstore/catalog through rule 10: ${bt:-no target}"
  case "$bt" in *up*) ;; *) fail=1 ;; esac
else
  echo '# step 5 not run: the catalog image is not loaded into this cluster'
  echo
  summary "step 5 (Bookstore catalog scrape) not run: no image"
fi

pkill -f 'kubectl.*port-forward' 2>/dev/null
echo '## runner step 6: the state at the end'
run <<'CMD'
kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c
CMD
run <<'CMD'
helm list -A
CMD
exit $fail
