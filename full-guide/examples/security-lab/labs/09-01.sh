#!/usr/bin/env bash
# Lab 09.01 on a GitHub Actions runner: the composed Bookstore stack.
# Tier A (kind).
#
# Run this ONLY against a kind cluster you own that the chapter's own config
# built (one control plane, three workers, the cluster named bookstore), from
# any directory. Print that config with:
#
#   09-01.sh kind-config > kind-capstone.yaml
#
# The workflow lab-on-runner.yml builds the cluster from it, builds the four
# Bookstore images with the chapter's docker build command, and then runs this
# script with no argument. The script installs, in the chapter's order and
# each into a namespace labelled before its chart: Traefik, kube-prometheus-
# stack, Argo CD, Argo Rollouts, KEDA, Kyverno and the Velero controller on
# the CSI path. A metrics-server comes first, because the HPA in step (g)
# needs a resource metrics API and the chapter's list has none; it is
# installed as 06.04 step 0 does, with verified kubelet serving certificates.
# The Bookstore prod overlay goes on top, with Traefik's prefix strip.
#
# What it does not do, and the transcript says so: a Git remote for Argo CD,
# a canary Rollout, an object store, a snapshot-capable CSI driver, a backup
# and a restore, and a node drain.
#
# The chart and image pins are the ones the chapters give. The values files
# are cut out of the chapters, not retyped. Generated passwords are never
# printed. Nothing here pushes an image or touches a cloud.
set +e

PYBIN=${PYBIN:-python3}
guide=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1   # full-guide/
ch09="$guide/09-end-to-end-bookstore/01-bookstore-end-to-end.md"

# Print the first yaml fence of a chapter that holds the needle.
chapter_block() {
  "$PYBIN" -I - "$1" "$2" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for block in re.findall(r"```yaml\n(.*?)```", text, re.S):
    if sys.argv[2] in block:
        print(block.rstrip())
        break
else:
    sys.exit(1)
PYEOF
}

if [ "${1:-}" = kind-config ]; then
  chapter_block "$ch09" 'kind: Cluster'
  exit $?
fi

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

# Stop the lab when something that every later step needs has not happened.
need() { "$@" >/dev/null 2>&1 || { echo "stopping: $* failed" >&2; exit 3; }; }

# One line of the job summary. Diagnostics go to stderr, so the transcript on
# stdout holds only what ran.
SUMMARY=${LAB_SUMMARY:-/dev/null}
summary() { printf '%s\n' "$*" >> "$SUMMARY"; printf 'summary: %s\n' "$*" >&2; }

fail=0

# Every Pod in a namespace is Running with all containers ready, or Completed.
ns_ready() {
  local label=$1 ns=$2 bad total
  bad=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '{split($2,a,"/")} ($3=="Completed") {next} ($3!="Running" || a[1]!=a[2]) {print $1}' | tr '\n' ' ')
  total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ -z "$bad" ] && [ "$total" -gt 0 ]; then
    summary "$label ($ns): $total Pods, every one ready"
  else
    summary "$label ($ns): NOT ready, ${bad:-no Pods}"
    fail=1
  fi
}

ctx=$(kubectl config current-context 2>/dev/null)
[ "$ctx" = kind-bookstore ] || { echo "refusing to run: kubectl context '$ctx' is not kind-bookstore" >&2; exit 2; }
for ns in traefik monitoring node-exporter argocd argo-rollouts keda kyverno velero metrics-server bookstore client; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then echo "refusing to run: namespace $ns exists" >&2; exit 2; fi
done

work=${LAB_WORK:-$(mktemp -d)} && mkdir -p "$work/examples" && cd "$work" || exit 1
[ -e examples/bookstore ] || cp -R "$guide/examples/bookstore" examples/bookstore

TRAEFIK_CHART_VERSION=42.2.0     # 02.04
KPS_CHART_VERSION=92.16.1        # 06.01
KEDA_CHART_VERSION=2.21.0        # 06.04
KYVERNO_CHART_VERSION=3.9.2      # (c)5
VELERO_CHART_VERSION=12.2.2      # 08.02
VELERO_IMAGE_DIGEST=sha256:c89fb5b6d1fd6afd368e0f483e6f5555fd62851a1eada8ac5c72482e674ca17b  # velero/velero:v1.18.4
VELERO_AWS_PLUGIN=docker.io/velero/velero-plugin-for-aws@sha256:c85a7fa803569e3128c33e4f5766f84ab156c8d171c9f1dd2715581d45ce98fa  # v1.14.4
export TRAEFIK_CHART_VERSION KPS_CHART_VERSION KEDA_CHART_VERSION KYVERNO_CHART_VERSION VELERO_CHART_VERSION VELERO_IMAGE_DIGEST VELERO_AWS_PLUGIN

echo "# Runner recording, from examples/security-lab/labs/09-01.sh."
echo '## runner step (a): the cluster, built from the chapter'"'"'s kind-capstone.yaml'
run <<'CMD'
kubectl get nodes -L topology.kubernetes.io/zone,dedicated
CMD
run <<'CMD'
kubectl version
CMD
run <<'CMD'
helm version --short
CMD

echo '## runner step (b): load the four images, built before this script with docker build -t bookstore/<service>:dev'
run <<'CMD'
for s in catalog orders payments-worker storefront; do
  kind load docker-image bookstore/$s:dev --name bookstore
done
docker exec bookstore-control-plane crictl images | grep bookstore
CMD

# ---------------------------------------------------------------------------
echo '## runner step (c)0: a resource metrics API, added by this run (06.04 step 0)'
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1
helm repo update metrics-server >/dev/null 2>&1
run <<'CMD'
kubectl create namespace metrics-server
kubectl label namespace metrics-server pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted
helm install metrics-server metrics-server/metrics-server --version 3.14.0 --namespace metrics-server
CMD
run <<'CMD'
for n in $(kubectl get nodes -o name | sed 's|node/||'); do
  docker exec "$n" sh -c 'cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.orig && echo "serverTLSBootstrap: true" >> /var/lib/kubelet/config.yaml && systemctl restart kubelet && grep serverTLSBootstrap /var/lib/kubelet/config.yaml'
done
CMD
want=$(kubectl get nodes -o name | wc -l | tr -d ' ')
for i in $(seq 1 60); do
  have=$(kubectl get csr -o jsonpath='{range .items[*]}{.spec.signerName}{"\n"}{end}' 2>/dev/null | grep -c '^kubernetes.io/kubelet-serving$')
  [ "$have" -ge "$want" ] && break
  sleep 3
done
# A new cluster still holds the CSRs of the nodes' own client certificates,
# which are Approved already. Only the serving requests are checked and
# approved: they are the ones with this signer.
run <<'CMD'
kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving
CMD
run <<'CMD'
for c in $(kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o name); do
  u=$(kubectl get "$c" -o jsonpath='{.spec.username}')
  s=$(kubectl get "$c" -o jsonpath='{.spec.request}' | base64 -d | openssl req -noout -text | grep -A1 'Alternative Name' | tail -1 | sed 's/^ *//')
  echo "${c#*/} $u $s"
done
CMD
# Approve only a request from the node it names.
ok=1
for c in $(kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o name); do
  u=$(kubectl get "$c" -o jsonpath='{.spec.username}')
  kubectl get nodes -o name | sed 's|node/||' | grep -qx "${u#system:node:}" || ok=0
done
[ "$ok" = 1 ] || { echo "stopping: a certificate request does not come from a node" >&2; exit 3; }
run <<'CMD'
kubectl certificate approve $(kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o name)
CMD
for i in $(seq 1 60); do
  cert=$(kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o jsonpath='{range .items[*]}{.status.certificate}{"\n"}{end}' 2>/dev/null | grep -c .)
  [ "$cert" -ge "$want" ] && break
  sleep 3
done
kubectl -n metrics-server rollout status deployment/metrics-server --timeout=300s >/dev/null 2>&1
for i in $(seq 1 60); do kubectl top nodes >/dev/null 2>&1 && break; sleep 5; done
run <<'CMD'
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes
CMD
ns_ready 'metrics-server' metrics-server

# ---------------------------------------------------------------------------
echo '## runner step (c)1: Traefik, the edge'
chapter_block "$ch09" 'name: traefik' > traefik-namespace.yaml
chapter_block "$guide/02-networking/04-ingress.md" 'kubernetesIngress:' > traefik-values.yaml
run <<'CMD'
kubectl apply -f traefik-namespace.yaml
helm repo add traefik https://traefik.github.io/charts
helm repo update traefik
helm show chart traefik/traefik --version "$TRAEFIK_CHART_VERSION" \
  | grep -E '^(appVersion|name|version):'
helm install traefik traefik/traefik --version "$TRAEFIK_CHART_VERSION" \
  --namespace traefik -f traefik-values.yaml --wait
kubectl -n traefik get pods,svc
kubectl get ingressclass traefik
CMD
ns_ready 'Traefik' traefik

echo '## runner step (c)2: kube-prometheus-stack, node-exporter in its own namespace'
awk "/cat > monitoring-values.yaml <<'EOF'/{f=1;next} f&&/^EOF\$/{exit} f" "$guide/06-production-readiness/01-observability-metrics.md" > monitoring-values.yaml
[ -s monitoring-values.yaml ] || { echo "stopping: the 06.01 values file was not found" >&2; exit 3; }
run <<'CMD'
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
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
run <<'CMD'
helm install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --version "$KPS_CHART_VERSION" \
  --namespace monitoring \
  --values monitoring-values.yaml \
  --wait --timeout 10m
CMD
ns_ready 'kube-prometheus-stack' monitoring
ns_ready 'node-exporter' node-exporter

echo '## runner step (c)3: Argo CD and Argo Rollouts, delivery'
chapter_block "$guide/07-delivery/04-gitops-argocd.md" 'admin.enabled: false' > argocd-values.yaml
run <<'CMD'
kubectl create namespace argocd
kubectl label namespace argocd pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
kubectl create namespace argo-rollouts
kubectl label namespace argo-rollouts pod-security.kubernetes.io/enforce=restricted
CMD
run <<'CMD'
helm install argocd oci://ghcr.io/argoproj/argo-helm/argo-cd@sha256:90f462a0695121f65a71cd053619f80023b4efef6bc211f750ffcaaa1628b5b6 \
  -n argocd -f argocd-values.yaml --wait --timeout 10m
CMD
run <<'CMD'
helm install argo-rollouts oci://ghcr.io/argoproj/argo-helm/argo-rollouts@sha256:09afe23380ec7f804221fb31471e0225cd6328586df2cff4da6093da62aab1ed \
  -n argo-rollouts --wait --timeout 10m
kubectl -n argo-rollouts rollout status deploy/argo-rollouts
CMD
ns_ready 'Argo CD' argocd
ns_ready 'Argo Rollouts' argo-rollouts

echo '## runner step (c)4: KEDA'
chapter_block "$guide/06-production-readiness/04-autoscaling.md" 'metricsApiServer:' > keda-values.yaml
run <<'CMD'
helm repo add kedacore https://kedacore.github.io/charts
helm repo update kedacore
kubectl create namespace keda
kubectl label namespace keda \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
helm install keda kedacore/keda --version "$KEDA_CHART_VERSION" \
  --namespace keda -f keda-values.yaml --wait --timeout 10m
kubectl -n keda rollout status deployment/keda-operator
CMD
ns_ready 'KEDA' keda

echo '## runner step (c)5: Kyverno'
run <<'CMD'
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update kyverno
kubectl create namespace kyverno
kubectl label namespace kyverno pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
helm show chart kyverno/kyverno --version "$KYVERNO_CHART_VERSION" \
  | grep -E '^(appVersion|name|version):'
helm install kyverno kyverno/kyverno --version "$KYVERNO_CHART_VERSION" \
  --namespace kyverno --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 --set cleanupController.replicas=1 \
  --set reportsController.replicas=1 --wait --timeout 10m
CMD
ns_ready 'Kyverno' kyverno

echo '## runner step (c)6: Velero, the controller on the CSI snapshot path'
chapter_block "$guide/08-day-2-operations/02-backup-and-dr.md" 'kind: Namespace' > velero-namespace.yaml
run <<'CMD'
kubectl apply -f velero-namespace.yaml
umask 077
CREDS_FILE="$(mktemp)"
printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' lab-placeholder lab-placeholder > "$CREDS_FILE"
kubectl create secret generic velero-cloud-credentials -n velero --from-file=cloud="$CREDS_FILE"
rm -f "$CREDS_FILE"
CMD
VELERO_BUCKET=example
VELERO_REGION=us-east-1
VELERO_S3_URL=https://s3.example.com
export VELERO_BUCKET VELERO_REGION VELERO_S3_URL
run <<'CMD'
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update vmware-tanzu
helm install velero vmware-tanzu/velero -n velero \
  --version "$VELERO_CHART_VERSION" --wait \
  --set image.digest="$VELERO_IMAGE_DIGEST" \
  --set-json 'initContainers=[{"name":"velero-plugin-for-aws","image":"'"$VELERO_AWS_PLUGIN"'","imagePullPolicy":"IfNotPresent","securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},"volumeMounts":[{"mountPath":"/target","name":"plugins"}]}]' \
  --set-json 'podSecurityContext={"runAsNonRoot":true,"runAsUser":1002,"runAsGroup":1000,"seccompProfile":{"type":"RuntimeDefault"}}' \
  --set-json 'containerSecurityContext={"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}' \
  --set resources.requests.cpu=500m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=512Mi \
  --set configuration.features=EnableCSI \
  --set deployNodeAgent=false \
  --set snapshotsEnabled=false \
  --set 'configuration.backupStorageLocation[0].name=default' \
  --set 'configuration.backupStorageLocation[0].provider=aws' \
  --set "configuration.backupStorageLocation[0].bucket=$VELERO_BUCKET" \
  --set "configuration.backupStorageLocation[0].config.region=$VELERO_REGION" \
  --set "configuration.backupStorageLocation[0].config.s3Url=$VELERO_S3_URL" \
  --set 'configuration.backupStorageLocation[0].config.s3ForcePathStyle=true' \
  --set credentials.existingSecret=velero-cloud-credentials
kubectl -n velero rollout status deploy/velero
kubectl -n velero get pods
CMD
for i in $(seq 1 40); do
  [ -n "$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null)" ] && break
  sleep 3
done
run <<'CMD'
kubectl -n velero get backupstoragelocation
CMD
ns_ready 'Velero controller' velero

echo '## runner step (c): what the platform holds, before the Bookstore'
run <<'CMD'
kubectl get ns
CMD
run <<'CMD'
kubectl get pods -A --no-headers | awk '{print $1}' | sort | uniq -c
CMD
run <<'CMD'
kubectl top nodes
CMD
run <<'CMD'
free -m
CMD
run <<'CMD'
df -h /
CMD

# ---------------------------------------------------------------------------
echo '## runner step (d.2): the prod overlay, with the prefix strip and the images from (b)'
# The chapter edits the overlay in place and reverts it. This run edits the
# copy of the tree it made at the start, so the repository is never touched.
sed -i 's|^  - images$|  - images\n  - ../../components/traefik-rewrite|' examples/bookstore/kustomize/overlays/prod/kustomization.yaml
{
  echo 'apiVersion: kustomize.config.k8s.io/v1alpha1'
  echo 'kind: Component'
  echo 'images:'
  for s in catalog orders payments-worker storefront; do
    printf -- '- name: bookstore/%s\n  newTag: dev\n' "$s"
  done
} > examples/bookstore/kustomize/overlays/prod/images/kustomization.yaml
run <<'CMD'
grep -A3 '^components:' examples/bookstore/kustomize/overlays/prod/kustomization.yaml
cat examples/bookstore/kustomize/overlays/prod/images/kustomization.yaml
kubectl kustomize examples/bookstore/kustomize/overlays/prod | grep -c '^kind:'
CMD
run <<'CMD'
# Namespace first: the labelled manifest, so the restricted level is in place
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
kubectl apply -f examples/bookstore/raw-manifests/15-catalog-config.yaml
# kind only: db-credentials, generated here and never committed
kubectl -n bookstore create secret generic db-credentials \
  --from-literal=POSTGRES_USER=bookstore \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=POSTGRES_DB=bookstore
kubectl apply -f examples/bookstore/raw-manifests/35-priorityclasses.yaml

# A self-signed certificate stands in for the one cert-manager issues in prod
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -subj "/CN=bookstore.example.com" -keyout tls.key -out tls.crt 2>/dev/null
kubectl -n bookstore create secret tls bookstore-tls --cert=tls.crt --key=tls.key
CMD
run <<'CMD'
kubectl apply -k examples/bookstore/kustomize/overlays/prod
CMD
if ! kubectl wait --for=condition=complete job/db-migrate -n bookstore --timeout=180s >/dev/null 2>&1; then
  echo '# the migration Job did not complete; the chapter says to delete it and apply the overlay again'
  run <<'CMD'
kubectl get job db-migrate -n bookstore
CMD
  run <<'CMD'
kubectl delete job db-migrate -n bookstore
kubectl apply -k examples/bookstore/kustomize/overlays/prod
CMD
fi
run <<'CMD'
kubectl wait --for=condition=complete job/db-migrate -n bookstore --timeout=180s
kubectl wait --for=condition=available deploy --all -n bookstore --timeout=300s
kubectl get pods,svc,netpol -n bookstore
CMD
ns_ready 'Bookstore prod overlay' bookstore

# ---------------------------------------------------------------------------
echo '## runner step (e): the edge, from the runner and from a Pod'
for i in $(seq 1 30); do
  c=$(curl -sk -o /dev/null -w '%{http_code}' -H 'Host: bookstore.example.com' https://localhost/api/books)
  [ "$c" = 200 ] && break
  sleep 3
done
run <<'CMD'
curl -sk -o /dev/null -w '%{http_code}\n' \
  -H 'Host: bookstore.example.com' https://localhost/api/books
CMD
run <<'CMD'
curl -sk -H 'Host: bookstore.example.com' https://localhost/api/books
CMD
code=$(curl -sk -o /dev/null -w '%{http_code}' -H 'Host: bookstore.example.com' https://localhost/api/books)
summary "GET /api/books through Traefik with the prefix strip: HTTP $code"
[ "$code" = 200 ] || fail=1
run <<'CMD'
kubectl -n bookstore get middleware.traefik.io rewrite-api-prefix -o jsonpath='{.spec.replacePathRegex}{"\n"}'
CMD
echo '## runner step (e): the edge does not deliver /metrics to the app (06.01 section 4)'
run <<'CMD'
for p in /metrics /api/books/metrics /api/orders/metrics; do
  curl -sk -o /dev/null -w "%{http_code} $p\n" -H 'Host: bookstore.example.com' "https://localhost$p"
done
CMD
run <<'CMD'
for p in /metrics /api/books/metrics; do
  printf '%s go_info lines: ' "$p"
  curl -sk -H 'Host: bookstore.example.com' "https://localhost$p" | grep -c '^go_info'
done
CMD
chapter_block "$ch09" 'name: edge-client' > edge-client.yaml
chapter_block "$ch09" 'name: npblock' > npblock.yaml
run <<'CMD'
kubectl create namespace client
kubectl label namespace client pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
CMD
for i in $(seq 1 60); do kubectl get sa default -n client >/dev/null 2>&1 && break; sleep 1; done
run <<'CMD'
kubectl apply -f edge-client.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/edge-client \
  -n client --timeout=120s
kubectl logs pod/edge-client -n client
CMD
echo '## runner step (e): the refusal, a deliberate action'
run <<'CMD'
kubectl apply -f npblock.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/npblock -n bookstore --timeout=120s
kubectl logs pod/npblock -n bookstore
kubectl delete pod npblock -n bookstore
CMD

# ---------------------------------------------------------------------------
echo '## runner step (f): observability, Prometheus scraping the Bookstore through the edge traffic'
run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/80-servicemonitor.yaml
kubectl apply -f examples/bookstore/raw-manifests/81-prometheusrule.yaml
CMD
run <<'CMD'
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 8
CMD
run <<'CMD'
for i in $(seq 1 300); do
  curl -sk -o /dev/null -H 'Host: bookstore.example.com' https://localhost/api/books
done
echo sent 300 requests through the edge
CMD
for i in $(seq 1 40); do
  h=$(curl -s 'localhost:9090/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | select(.labels.namespace=="bookstore" and .labels.job=="catalog") | .health' 2>/dev/null | sort -u | tr '\n' ' ')
  case "$h" in *up*) break ;; esac
  sleep 5
done
sleep 45
run <<'CMD'
curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.labels.namespace=="bookstore") | [.labels.job, .labels.namespace, .health] | @tsv' | sort
CMD
run <<'CMD'
curl -s 'localhost:9090/api/v1/rules' \
  | jq -r '.data.groups[] | select(.name=="bookstore-catalog.rules") | .rules[] | [.name, .state, .health] | @tsv'
CMD
run <<'CMD'
curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum(rate(http_requests_total{namespace="bookstore"}[5m]))' \
  | jq -r '.status, (.data.result | length), (.data.result[0].value[1] | tonumber > 0)'
CMD
run <<'CMD'
curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum(rate(http_requests_total{namespace="bookstore",code=~"5.."}[5m])) / sum(rate(http_requests_total{namespace="bookstore"}[5m]))' \
  | jq -r '.status, (.data.result | length)'
CMD
run <<'CMD'
curl -s localhost:9090/api/v1/query --data-urlencode 'query=histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{handler="books"}[5m])))' \
  | jq -r '.status, (.data.result | length), (.data.result[0].value[1] | tonumber > 0)'
CMD
bt=$(curl -s 'localhost:9090/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | select(.labels.namespace=="bookstore" and .labels.job=="catalog") | .health' 2>/dev/null | sort | uniq -c | tr '\n' ';')
summary "Prometheus targets for bookstore/catalog: ${bt:-none}"
case "$bt" in *up*) ;; *) fail=1 ;; esac
pkill -f 'kubectl.*port-forward' 2>/dev/null

# ---------------------------------------------------------------------------
echo '## runner step (g): scaling, the HPA on metrics-server and KEDA on the RabbitMQ queue'
run <<'CMD'
kubectl get hpa catalog -n bookstore
CMD
run <<'CMD'
kubectl get pdb -n bookstore
CMD
run <<'CMD'
PW="$(openssl rand -hex 24)"
kubectl -n bookstore exec deploy/rabbitmq -- rabbitmqctl add_user keda-scaler "$PW"
kubectl -n bookstore exec deploy/rabbitmq -- rabbitmqctl set_permissions -p / keda-scaler '^$' '^$' '^orders$'
kubectl -n bookstore create secret generic rabbitmq-conn \
  --from-literal=host="amqp://keda-scaler:$PW@rabbitmq.bookstore.svc.cluster.local:5672/"
unset PW
CMD
run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/83-keda-scaledobject.yaml
CMD
for i in $(seq 1 40); do
  r=$(kubectl -n bookstore get scaledobject payments-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [ "$r" = True ] && break
  sleep 3
done
run <<'CMD'
kubectl get scaledobject,hpa -n bookstore
CMD
# The queue is empty, so KEDA scales payments-worker to zero after the cooldown.
sleep 90
run <<'CMD'
kubectl get scaledobject -n bookstore
kubectl get deploy payments-worker -n bookstore
CMD
r=$(kubectl -n bookstore get scaledobject payments-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
summary "KEDA ScaledObject payments-worker Ready: ${r:-unknown}"
[ "$r" = True ] || fail=1
cpu=$(kubectl get hpa catalog -n bookstore -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)
summary "HPA catalog reads CPU through metrics-server: ${cpu:-no value}%"
[ -n "$cpu" ] || fail=1

# ---------------------------------------------------------------------------
echo '## runner step (h): security posture'
run <<'CMD'
# busybox:1.36, pinned by digest as 08.03 does
kubectl run psa-bad -n bookstore --restart=Never --dry-run=server \
  --image=busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 \
  --overrides='{"spec":{"containers":[{"name":"psa-bad","image":"busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662","securityContext":{"privileged":true}}]}}'
CMD
run <<'CMD'
kubectl auth can-i --list --as=system:serviceaccount:bookstore:catalog-sa -n bookstore \
  | grep -E '^(Resources|configmaps)'
kubectl auth can-i get secrets --as=system:serviceaccount:bookstore:catalog-sa -n bookstore
CMD
echo '## runner step (h): Kyverno in Audit mode over the running workloads'
run <<'CMD'
kubectl apply -f examples/bookstore/raw-manifests/70-kyverno-policy.yaml
CMD
sleep 90
run <<'CMD'
kubectl get clusterpolicy
CMD
run <<'CMD'
kubectl get policyreport -n bookstore
CMD
run <<'CMD'
kubectl get policyreport -n bookstore -o jsonpath='{range .items[*]}{.summary}{"\n"}{end}' | head -3
CMD

# ---------------------------------------------------------------------------
echo '## runner step (i): the controllers that the delivery steps need'
run <<'CMD'
kubectl get pods -n argocd
kubectl get pods -n argo-rollouts
kubectl get crd applications.argoproj.io appprojects.argoproj.io rollouts.argoproj.io analysistemplates.argoproj.io
CMD

echo '## runner step (j): the Velero controller, with no object store behind it'
run <<'CMD'
kubectl -n velero get backupstoragelocation
kubectl get crd -o name | grep -c '\.velero\.io$'
CMD

echo '## runner step (k): day-2 sampler, a debug container on distroless catalog'
run <<'CMD'
POD=$(kubectl get pods -n bookstore -l app=catalog -o jsonpath='{.items[0].metadata.name}')
# gcr.io/distroless/static:debug-nonroot, pinned by the digest below
kubectl debug -n bookstore pod/$POD --target=catalog --profile=restricted \
  --image=gcr.io/distroless/static@sha256:c7b8faacc4439b8f5c41ca7ce4a3f8ff3e8520cb0c3444fae7292f687b00d0dd \
  --container=debugger -i --quiet -- /busybox/sh -c \
  'id -u; nc -z -w 3 postgres.bookstore.svc.cluster.local 5432 && echo PG-REACHABLE'
CMD

echo '## runner step (c): the platform and the Bookstore together'
run <<'CMD'
kubectl get pods -A --no-headers | awk '{print $1}' | sort | uniq -c
CMD
run <<'CMD'
kubectl get pods -A --no-headers | awk '{split($3,a,"/"); if ($4 != "Running" && $4 != "Completed") print $1, $2, $4}'
CMD
run <<'CMD'
kubectl top nodes
CMD
run <<'CMD'
free -m
CMD
run <<'CMD'
helm list -A
CMD

echo '## runner step (l): teardown, as the chapter does on a shared cluster'
run <<'CMD'
helm uninstall traefik -n traefik
kubectl delete namespace client bookstore traefik
kubectl get namespace bookstore
kubectl get ingressclass traefik
CMD
exit $fail
