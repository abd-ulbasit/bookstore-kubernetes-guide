#!/usr/bin/env bash
# Lab 08.05: operators and CRDs. Tier A (kind), render and admission steps.
#
# Run this ONLY against a kind cluster you own, from any directory. It creates
# two namespaces, `cnpg-system` and `bookstore` (set NS_CNPG and NS_BOOK to
# rename them), and deletes both at the end. It installs nothing. It reads the
# RBAC and the CRD schema that the CloudNativePG chart renders, has the API
# server dry-run the chart's CRDs and operator objects, and shows the
# restricted namespace refusing a privileged Pod while admitting the migration
# Pod from chapter 05. Server-side dry runs store nothing.
#
# The operator install, the Cluster, the failover and the DB_DSN rewire are
# chapter steps you run yourself. They are not in this script.
set +e

NS_CNPG=${NS_CNPG:-cnpg-system}
NS_BOOK=${NS_BOOK:-bookstore}
CHART=0.29.1
# Operator image (chart appVersion 1.30.1), pinned by digest.
OP_TAG='1.30.1@sha256:923c267ec29636db3bee20f993d0ec4973fa22998e1adad37da79e4d32b5bc07'
PG_IMAGE='ghcr.io/cloudnative-pg/postgresql:16.10-minimal-trixie@sha256:294fd7631f8d66fa54bf6ffa2948af685a20fb695fe748a6bafa71c42f1233b7'

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

guide=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1   # full-guide/
bk="$guide/examples/bookstore"
work=$(mktemp -d) && cd "$work" || exit 1

for ns in "$NS_CNPG" "$NS_BOOK"; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    echo "refusing to run: namespace $ns already exists" >&2; exit 2
  fi
done

# The Bookstore manifests name the bookstore namespace. NS_BOOK renames it.
nsrender() {
  sed -e "s/^  name: bookstore\$/  name: $NS_BOOK/" \
      -e "s/namespace: bookstore\$/namespace: $NS_BOOK/" \
      -e "s/bookstore\.svc/$NS_BOOK.svc/g" "$1"
}

helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1
helm repo update cnpg >/dev/null 2>&1

echo '## step 1: the chart version the guide pins'
run <<'CMD'
helm show chart cnpg/cloudnative-pg --version "$CHART" | grep -E '^(version|appVersion|kubeVersion):'
CMD

cat > cnpg-namespace.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS_CNPG
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
EOF

echo '## step 2: the operator namespace, labelled restricted before the install'
run <<'CMD'
kubectl apply -f cnpg-namespace.yaml
kubectl get namespace "$NS_CNPG" -L pod-security.kubernetes.io/enforce
CMD

echo '## step 3: the ClusterRole the chart renders, read before installing'
run <<'CMD'
helm template cnpg cnpg/cloudnative-pg --version "$CHART" --namespace "$NS_CNPG" --show-only templates/rbac.yaml > rbac.yaml
awk '/^kind: ClusterRole$/{on=1} /^---$/{on=0} on' rbac.yaml | grep -B3 -A9 '^  - secrets$'
CMD

echo '## step 3b: the same ClusterRole also execs into pods and creates bindings'
run <<'CMD'
awk '/^kind: ClusterRole$/{on=1} /^---$/{on=0} on' rbac.yaml | grep -B3 -A4 '^  - pods/exec$'
awk '/^kind: ClusterRole$/{on=1} /^---$/{on=0} on' rbac.yaml | grep -B3 -A6 '^  - rolebindings$'
CMD

echo '## step 3c: the binding that gives the ClusterRole to the operator ServiceAccount'
run <<'CMD'
awk '/^kind: ClusterRoleBinding$/{on=1} /^---$/{on=0} on' rbac.yaml
CMD

echo '## step 4: the same render with the namespaced option'
run <<'CMD'
helm template cnpg cnpg/cloudnative-pg --version "$CHART" --namespace "$NS_CNPG" --set config.clusterWide=false --show-only templates/rbac.yaml > rbac-namespaced.yaml
awk '/^kind: ClusterRole$/{on=1} /^---$/{on=0} on' rbac-namespaced.yaml | grep -c '^  - secrets$'
grep -c '^kind: Role$' rbac-namespaced.yaml
CMD

echo '## step 5: the CRD schema the chart renders: the privileged field and the enum'
run <<'CMD'
helm template cnpg cnpg/cloudnative-pg --version "$CHART" --namespace "$NS_CNPG" --show-only templates/crds/crds.yaml > crds.yaml
grep -m1 -A4 'privileged:' crds.yaml
grep -m1 -A10 'primaryUpdateStrategy:' crds.yaml | tail -n 4
CMD

echo '## step 6: the API server accepts the chart CRDs (server dry run, nothing stored)'
run <<'CMD'
kubectl apply --dry-run=server -f crds.yaml
CMD

echo '## step 6b: the same CRDs with server-side apply (server dry run, nothing stored)'
run <<'CMD'
kubectl apply --dry-run=server --server-side -f crds.yaml
CMD

echo '## step 7: before the CRDs are installed, the Cluster kind does not exist'
run <<'CMD'
nsrender "$bk/operators/cnpg-cluster.yaml" | kubectl apply --dry-run=client -f -
CMD

echo '## step 8: the Bookstore namespace with its quota, labelled restricted'
run <<'CMD'
nsrender "$bk/raw-manifests/00-namespace.yaml" | kubectl apply -f -
for i in $(seq 1 60); do kubectl get serviceaccount default -n "$NS_BOOK" >/dev/null 2>&1 && break; sleep 1; done
kubectl get serviceaccount default -n "$NS_BOOK" --no-headers
CMD

cat > migrate.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: db-migrate-cnpg
  namespace: $NS_BOOK
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 26
    runAsGroup: 26
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: migrate
      image: $PG_IMAGE
      command: ["/bin/sh", "-c"]
      args:
        - |
          until pg_isready -q; do sleep 2; done
          psql -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS books (id SERIAL PRIMARY KEY, title TEXT, author TEXT, price NUMERIC); CREATE TABLE IF NOT EXISTS orders (id SERIAL PRIMARY KEY, book_id INT, qty INT, created_at TIMESTAMPTZ);"
          echo migration complete
      env:
        - name: PGHOST
          value: bookstore-db-rw.$NS_BOOK.svc.cluster.local
        - name: PGDATABASE
          value: bookstore
        - name: PGUSER
          valueFrom: {secretKeyRef: {name: cnpg-app-credentials, key: username}}
        - name: PGPASSWORD
          valueFrom: {secretKeyRef: {name: cnpg-app-credentials, key: password}}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 50m, memory: 64Mi}
        limits: {memory: 128Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
EOF

echo '## step 9: the restricted namespace refuses a privileged Pod (deliberate)'
run <<'CMD'
kubectl run privileged-probe -n "$NS_BOOK" --image="$PG_IMAGE" --restart=Never --dry-run=server --overrides='{"spec":{"containers":[{"name":"privileged-probe","image":"'"$PG_IMAGE"'","securityContext":{"privileged":true}}]}}'
CMD

echo '## step 10: the same namespace admits the migration Pod from chapter 05'
run <<'CMD'
kubectl apply --dry-run=server -f migrate.yaml
CMD

echo '## step 11: the operator objects, with the image pinned by digest, dry-run into the restricted namespace'
run <<'CMD'
helm template cnpg cnpg/cloudnative-pg --version "$CHART" --namespace "$NS_CNPG" --set image.tag="$OP_TAG" --show-only templates/deployment.yaml > operator-deploy.yaml
grep -m1 'image:' operator-deploy.yaml
helm template cnpg cnpg/cloudnative-pg --version "$CHART" --namespace "$NS_CNPG" --set image.tag="$OP_TAG" --show-only templates/rbac.yaml --show-only templates/config.yaml --show-only templates/deployment.yaml --show-only templates/service.yaml > operator.yaml
kubectl apply --dry-run=server -n "$NS_CNPG" -f operator.yaml
CMD

echo '## step 12: delete the namespaces this lab created'
run <<'CMD'
kubectl delete namespace "$NS_BOOK" "$NS_CNPG" --wait=true --timeout=300s
kubectl get namespace "$NS_BOOK" "$NS_CNPG" 2>&1 | tail -n 2
CMD

echo "lab 08.05 finished"
