#!/usr/bin/env bash
# Lab 06.02: logging. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from any directory. It creates
# three namespaces (p06-02-bookstore, p06-02-logging, p06-02-client), runs the
# logging stack in the logging one, and deletes all three at the end. It also
# creates two cluster-scoped objects, removed at the end: the agent's
# ClusterRole and binding. The Loki chart creates two more, which the script
# refuses to run beside if they already exist.
#
# The Bookstore manifests come from examples/bookstore/raw-manifests, copied
# with the namespace renamed and the priority classes dropped (they are
# cluster-scoped). The chapter prints the names bookstore and logging.
#
# The planted secret and the deliberately malformed DSN are on purpose. They
# show what reaches the store, and what the agent removes from it.
#
# Loki and the Alloy agent are heavy for a shared lab host. Take the heavy-
# install lock that lab runs share before running this script, and release
# it after.
set +e

# LAB_HEAVY=1 installs Loki and the agent. LAB_HEAVY=0 runs every other step,
# and checks the Loki and agent objects with a server dry run instead of an
# install. Use 0 when the heavy-install lock is held by another run.
HEAVY=${LAB_HEAVY:-1}

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

guide=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1   # full-guide/
raw="$guide/examples/bookstore/raw-manifests"
work=$(mktemp -d) && cd "$work" || exit 1
BK=p06-02-bookstore
LG=p06-02-logging
CL=p06-02-client

# Copy an example manifest into the lab with the namespace renamed.
rename() {
  sed -e "s/namespace: bookstore/namespace: $BK/g" \
      -e "s/\.bookstore\.svc/.$BK.svc/g" \
      -e "s/metadata.name: bookstore/metadata.name: $BK/g" \
      -e "s/^  name: bookstore\$/  name: $BK/" \
      -e '/priorityClassName:/d' "$raw/$1" > "$2"
}

echo '## step 0: start from a clean slate; refuse if a chart object of the same name exists'
kubectl delete ns "$BK" "$LG" "$CL" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete clusterrolebinding alloy-log-reader --ignore-not-found >/dev/null 2>&1
kubectl delete clusterrole alloy-log-reader --ignore-not-found >/dev/null 2>&1
if kubectl get clusterrole loki-clusterrole >/dev/null 2>&1; then
  echo 'refusing to run: a clusterrole named loki-clusterrole already exists' >&2; exit 2
fi
echo 'clean'
echo

echo '## step 1: the Bookstore data and API tiers, from the example tree'
rename 00-namespace.yaml 00-namespace.yaml
rename 05-serviceaccounts-rbac.yaml 05-serviceaccounts-rbac.yaml
rename 15-catalog-config.yaml 15-catalog-config.yaml
rename 16-db-credentials.yaml 16-db-credentials.yaml
rename 12-redis.yaml 12-redis.yaml
rename 20-postgres-statefulset.yaml 20-postgres-statefulset.yaml
rename 40-services.yaml 40-services.yaml
rename 60-networkpolicy.yaml 60-networkpolicy.yaml
rename 10-catalog-deploy.yaml 10-catalog-deploy.yaml
rename 14-orders-deploy.yaml 14-orders-deploy.yaml
run <<CMD
kubectl apply -f 00-namespace.yaml -f 05-serviceaccounts-rbac.yaml -f 15-catalog-config.yaml -f 16-db-credentials.yaml
CMD
run <<CMD
kubectl apply -f 12-redis.yaml -f 20-postgres-statefulset.yaml -f 40-services.yaml -f 60-networkpolicy.yaml
CMD
run <<CMD
kubectl apply -f 10-catalog-deploy.yaml -f 14-orders-deploy.yaml
CMD
run <<CMD
kubectl -n $BK rollout status statefulset/postgres --timeout=240s
kubectl -n $BK rollout status deploy/redis --timeout=240s
kubectl -n $BK rollout status deploy/catalog --timeout=240s
kubectl -n $BK rollout status deploy/orders --timeout=240s
CMD
rename 21-db-migrate-job.yaml 21-db-migrate-job.yaml
run <<CMD
kubectl apply -f 21-db-migrate-job.yaml
kubectl -n $BK wait --for=condition=complete job/db-migrate --timeout=240s
CMD

echo '## step 2: what the services already write to stdout'
run <<CMD
kubectl -n $BK logs deploy/catalog --tail=2
kubectl -n $BK logs deploy/orders --tail=2
CMD

echo '## step 3: a DSN that cannot be parsed, with a planted fake password (deliberate)'
run <<CMD
kubectl -n $BK create secret generic dsn-demo --from-literal=PASSWORD=FAKE-PLANTED-PASSWORD
CMD
cat > dsn-demo.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dsn-demo
  namespace: $BK
  labels:
    app: dsn-demo
spec:
  serviceAccountName: orders-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: orders
      image: bookstore/orders:dev
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      env:
        - name: PORT
          value: "8080"
        - name: PW
          valueFrom:
            secretKeyRef: { name: dsn-demo, key: PASSWORD }
        - name: DB_DSN
          value: "postgres://app:\$(PW)%zz@localhost:5432/books"
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits: { memory: 128Mi }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
EOF
run <<CMD
kubectl apply -f dsn-demo.yaml
CMD
sleep 25
run <<CMD
kubectl -n $BK logs dsn-demo --tail=3
CMD

echo '## step 4: the logging namespace, the agent RBAC and its network policy'
cat > 00-logging-namespace.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $LG
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
EOF
cat > 01-agent-rbac.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: alloy
  namespace: $LG
automountServiceAccountToken: true
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: alloy-log-reader
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: alloy-log-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: alloy-log-reader
subjects:
  - kind: ServiceAccount
    name: alloy
    namespace: $LG
EOF
cat > 02-logging-netpol.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: $LG
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: $LG
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-agent-egress
  namespace: $LG
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: alloy
  policyTypes: ["Egress"]
  egress:
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: loki
      ports:
        - { protocol: TCP, port: 3100 }
    - ports:
        - { protocol: TCP, port: 443 }
        - { protocol: TCP, port: 6443 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-reads-to-loki
  namespace: $LG
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: loki
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: alloy
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: grafana
      ports:
        - { protocol: TCP, port: 3100 }
EOF
run <<CMD
kubectl apply -f 00-logging-namespace.yaml -f 01-agent-rbac.yaml -f 02-logging-netpol.yaml
CMD

echo '## step 5: Loki (single binary, no tenants) and the Alloy agent, pinned by digest'
cat > loki-values.yaml <<'EOF'
deploymentMode: SingleBinary
loki:
  image:
    digest: "sha256:44148ad243c07957113baea950ee5ba9b0c8eff8d7e38ff3cc1c0af705790945"  # 3.6.11
  auth_enabled: false
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  commonConfig:
    replication_factor: 1
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  storage:
    type: filesystem
  limits_config:
    retention_period: 168h
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
singleBinary:
  replicas: 1
  persistence:
    size: 1Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi
write:
  replicas: 0
read:
  replicas: 0
backend:
  replicas: 0
gateway:
  enabled: false
chunksCache:
  enabled: false
resultsCache:
  enabled: false
minio:
  enabled: false
lokiCanary:
  enabled: false
test:
  enabled: false
rbac:
  create: false
serviceAccount:
  automountServiceAccountToken: false
sidecar:
  rules:
    enabled: false
monitoring:
  selfMonitoring:
    enabled: false
  lokiCanary:
    enabled: false
  dashboards:
    enabled: false
  rules:
    enabled: false
  serviceMonitor:
    enabled: false
EOF
cat > alloy-values.yaml <<EOF
image:
  digest: "sha256:8ab871206bd2d8f89277f53abffee5f452a293980788d52f85fa183a87a505a4"  # v1.21.3
global:
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: 473
    runAsGroup: 473
    seccompProfile:
      type: RuntimeDefault
controller:
  type: daemonset
  volumes:
    extra:
      - name: tmp
        emptyDir: {}
alloy:
  enableReporting: false
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
  mounts:
    extra:
      - name: tmp
        mountPath: /tmp
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 256Mi
  configMap:
    content: |
      discovery.kubernetes "pods" {
        role = "pod"
        selectors {
          role  = "pod"
          field = "spec.nodeName=" + sys.env("K8S_NODE_NAME")
        }
      }

      discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets

        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app"]
          target_label  = "app"
        }
      }

      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pods.output
        forward_to = [loki.process.redact.receiver]
      }

      loki.process "redact" {
        stage.replace {
          expression = "\"token\":\"([^\"]*)\""
          replace    = "[REDACTED]"
        }
        stage.replace {
          expression = "://[^:/@\\\\s]+:([^@\\\\s]+)@"
          replace    = "[REDACTED]"
        }
        forward_to = [loki.write.loki.receiver]
      }

      loki.write "loki" {
        endpoint {
          url = "http://loki.$LG.svc.cluster.local:3100/loki/api/v1/push"
        }
      }
rbac:
  create: false
serviceAccount:
  create: false
  name: alloy
configReloader:
  enabled: false
EOF
run <<CMD
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1; helm repo update grafana >/dev/null 2>&1; echo repo ready
CMD
if [ "$HEAVY" = 1 ]; then
run <<CMD
helm install loki grafana/loki --version 7.5.0 --namespace $LG -f loki-values.yaml --wait --timeout 6m
CMD
run <<CMD
helm install alloy grafana/alloy --version 1.15.0 --namespace $LG -f alloy-values.yaml --wait --timeout 6m
CMD
run <<CMD
kubectl -n $LG get ds alloy
kubectl -n $LG get pods
CMD
else
run <<CMD
helm template loki grafana/loki --version 7.5.0 --namespace $LG -f loki-values.yaml | kubectl apply --dry-run=server -n $LG -f -
helm template alloy grafana/alloy --version 1.15.0 --namespace $LG -f alloy-values.yaml | kubectl apply --dry-run=server -n $LG -f -
CMD
fi

echo '## step 6: what the agent may read, checked with the API, not by running it'
run <<CMD
kubectl auth can-i get pods/log -n $BK --as=system:serviceaccount:$LG:alloy
kubectl auth can-i list pods -n $BK --as=system:serviceaccount:$LG:alloy
kubectl auth can-i create pods -n $BK --as=system:serviceaccount:$LG:alloy
kubectl auth can-i get secrets -n $BK --as=system:serviceaccount:$LG:alloy
kubectl auth can-i get pods/log -n $LG --as=system:serviceaccount:$LG:alloy
CMD

echo '## step 7: a planted fake token and DSN password, written by a deliberately bad app'
cat > leaky-app.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: leaky-app
  namespace: $BK
  labels:
    app: leaky-app
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
      command:
        - sh
        - -c
        - 'while true; do echo "{\"level\":\"INFO\",\"msg\":\"upstream call\",\"token\":\"FAKE-PLANTED-TOKEN\",\"dsn\":\"postgres://app:FAKE-PLANTED-PASSWORD@localhost:5432/books\"}"; sleep 5; done'
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
EOF
run <<CMD
kubectl apply -f leaky-app.yaml
CMD
sleep 45
run <<CMD
kubectl -n $BK logs leaky-app --tail=1
CMD
if [ "$HEAVY" = 1 ]; then
kubectl -n "$LG" port-forward svc/loki 3100:3100 >pf.log 2>&1 &
pf=$!
sleep 5
run <<CMD
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range --data-urlencode 'query={namespace="$BK", app="leaky-app"} |= "FAKE-PLANTED-PASSWORD"' --data-urlencode 'since=30m' | jq '[.data.result[].values[]] | length'
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range --data-urlencode 'query={namespace="$BK", app="leaky-app"} |= "FAKE-PLANTED-TOKEN"' --data-urlencode 'since=30m' | jq '[.data.result[].values[]] | length'
CMD
run <<CMD
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range --data-urlencode 'query={namespace="$BK", app="leaky-app"} |= "REDACTED"' --data-urlencode 'since=30m' --data-urlencode 'limit=1' | jq -r '.data.result[].values[][1]'
CMD
else
echo '# Loki queries not run: LAB_HEAVY=0'
fi

echo '## step 8: the query for one request, by label and by a field of the line'
cat > loadgen.yaml <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: loadgen
  namespace: $BK
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: storefront
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: loadgen
          image: curlimages/curl@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b
          command:
            - sh
            - -c
            - 'for i in \$(seq 1 20); do curl -s -o /dev/null -XPOST http://orders.$BK.svc.cluster.local/orders -H "Content-Type: application/json" -d "{\"book_id\":1,\"qty\":2}"; done; echo done'
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { memory: 64Mi }
EOF
run <<CMD
kubectl apply -f loadgen.yaml
kubectl -n $BK wait --for=condition=complete job/loadgen --timeout=180s
CMD
sleep 20
if [ "$HEAVY" = 1 ]; then
run <<CMD
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range --data-urlencode 'query={namespace="$BK", app="orders"} | json | msg="order placed"' --data-urlencode 'since=30m' --data-urlencode 'limit=3' | jq -r '.data.result[].values[][1]'
CMD
run <<CMD
curl -sG http://127.0.0.1:3100/loki/api/v1/query --data-urlencode 'query=sum by (level) (count_over_time({namespace="$BK", app="orders"} | json [30m]))' | jq -r '.data.result[] | "\(.metric.level) \(.value[1])"'
CMD
kill "$pf" 2>/dev/null
else
run <<CMD
kubectl -n $BK logs deploy/orders --tail=300 | grep 'order placed' | tail -3
CMD
echo '# Loki queries not run: LAB_HEAVY=0'
fi

echo '## step 9: two denied paths, shown as the network policy decides them'
if [ "$HEAVY" != 1 ]; then
echo '# denied-path probes not run: they need the Loki Service, and LAB_HEAVY=0'
echo
else
kubectl create ns "$CL" >/dev/null 2>&1
kubectl label ns "$CL" pod-security.kubernetes.io/enforce=restricted >/dev/null 2>&1
cat > probe-client.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: probe-client
  namespace: $CL
  labels:
    app: client
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  restartPolicy: Never
  containers:
    - name: probe
      image: curlimages/curl@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b
      command: ["sh", "-c", "curl -s -m 5 -o /dev/null -w 'status=%{http_code}\\\\n' http://loki.$LG.svc.cluster.local:3100/ready; echo rc=\$?"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
EOF
sed -e "s/namespace: $CL/namespace: $BK/" -e 's/name: probe-client/name: probe-bookstore/' -e 's/app: client/app: other/' probe-client.yaml > probe-bookstore.yaml
run <<CMD
kubectl apply -f probe-client.yaml -f probe-bookstore.yaml
CMD
sleep 40
run <<CMD
kubectl -n $CL logs probe-client
kubectl -n $BK logs probe-bookstore
CMD
fi

echo '## step 10: log readers: pods/log is the reach, and it shows the raw line'
cat > log-reader.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: log-reader
  namespace: $BK
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: log-reader
  namespace: $BK
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: log-reader
  namespace: $BK
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: log-reader
subjects:
  - kind: ServiceAccount
    name: log-reader
    namespace: $BK
EOF
run <<CMD
kubectl apply -f log-reader.yaml
kubectl auth can-i get pods/log -n $BK --as=system:serviceaccount:$BK:log-reader
kubectl auth can-i get pods/log -n $LG --as=system:serviceaccount:$BK:log-reader
kubectl auth can-i get secrets -n $BK --as=system:serviceaccount:$BK:log-reader
CMD
run <<CMD
kubectl -n $BK logs leaky-app --tail=1 --as=system:serviceaccount:$BK:log-reader
CMD

echo '## cleanup'
run <<CMD
if [ "$HEAVY" = 1 ]; then
helm uninstall alloy -n $LG
helm uninstall loki -n $LG
fi
kubectl delete clusterrolebinding alloy-log-reader loki-clusterrolebinding --ignore-not-found
kubectl delete clusterrole alloy-log-reader loki-clusterrole --ignore-not-found
kubectl delete ns $BK $LG $CL --wait=true
kubectl get ns -o name | grep p06-02 || echo 'no p06-02 namespaces left'
CMD
