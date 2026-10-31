#!/usr/bin/env bash
# Lab 12.08: ML platform cost and MLOps. Tier A (kind), dry-run path.
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. It creates three namespaces, p12-08-opencost, p12-08-ml and
# p12-08-mlflow, applies the chapter's namespace, policy and quota manifests
# in them, applies two suspended probe Jobs, refuses a third over the cap
# with a server dry run, renders the OpenCost chart with helm template and
# sends the result to the server as a dry run, and deletes its namespaces at
# the end. The chapter names opencost, bookstore-ml and mlflow; this script
# applies the same manifests with only the namespace names replaced.
#
# No chart is installed and no Pod starts. The heavy-install lock was held by
# another worker, so the OpenCost and MLflow charts were rendered and
# server-dry-run, not installed.
set +e

K="${KUBECTL:-kubectl}"
H="${HELM:-helm}"
OC=p12-08-opencost
ML=p12-08-ml
MF=p12-08-mlflow
WORK="$(mktemp -d)"
cd "$WORK" || exit 2

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

show() { printf '$ %s\n' "$*"; }

## step 0: versions, chart and image pins
show "$K version --client"
"$K" version --client 2>&1 | head -1
show "$H version --short"
"$H" version --short
show "$H show chart opencost/opencost --version 2.5.33"
"$H" repo add opencost https://opencost.github.io/opencost-helm-chart >/dev/null 2>&1
"$H" repo update opencost >/dev/null 2>&1
"$H" show chart opencost/opencost --version 2.5.33 2>&1 | grep -E "^(version|appVersion):"
show "docker buildx imagetools inspect ghcr.io/opencost/opencost:1.121.3 (digest)"
docker buildx imagetools inspect ghcr.io/opencost/opencost:1.121.3 --format '{{.Manifest.Digest}}' 2>&1 | head -1
show "docker buildx imagetools inspect ghcr.io/opencost/opencost-ui:1.121.3 (digest)"
docker buildx imagetools inspect ghcr.io/opencost/opencost-ui:1.121.3 --format '{{.Manifest.Digest}}' 2>&1 | head -1
show "docker buildx imagetools inspect ghcr.io/mlflow/mlflow:v3.3.2 (digest)"
docker buildx imagetools inspect ghcr.io/mlflow/mlflow:v3.3.2 --format '{{.Manifest.Digest}}' 2>&1 | head -1
show "docker buildx imagetools inspect docker.io/bitnami/mlflow:3.3.2-debian-12-r0"
docker buildx imagetools inspect docker.io/bitnami/mlflow:3.3.2-debian-12-r0 --format '{{.Manifest.Digest}}' 2>&1 | head -1

## step 1: the three lab namespaces, restricted, from the chapter's labels
cat > "namespaces.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $OC
  labels:
    app.kubernetes.io/part-of: platform-cost
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
---
apiVersion: v1
kind: Namespace
metadata:
  name: $ML
  labels:
    app.kubernetes.io/part-of: bookstore-ml
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
---
apiVersion: v1
kind: Namespace
metadata:
  name: $MF
  labels:
    app.kubernetes.io/part-of: mlflow
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
YAML
show "$K apply -f opencost-namespace.yaml  (one namespace per chapter block; all three here)"
"$K" apply -f "namespaces.yaml" 2>&1

## step 2: OpenCost policies and values, rendered and sent as a server dry run
cat > "opencost-netpol.yaml" <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: $OC
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: opencost-api-and-prometheus
  namespace: $OC
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: opencost
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: prometheus-system
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 9003
  egress:
    - to:
        - ipBlock:
            cidr: 192.0.2.10/32
      ports:
        - protocol: TCP
          port: 6443
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: prometheus-system
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 9090
YAML
cat > "opencost-values.yaml" <<'YAML'
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1001
  runAsGroup: 1001
  seccompProfile:
    type: RuntimeDefault
extraVolumes:
  - name: tmp
    emptyDir: {}
networkPolicies:
  enabled: false        # the chart's policy would block the API server
opencost:
  mcp:
    enabled: false      # default on; this chapter does not use it
  updateCaTrust:
    enabled: false      # default off; it would run a root container
  ui:
    enabled: false      # default on; the API on 9003 is all this chapter uses
  exporter:
    extraVolumeMounts:
      - name: tmp
        mountPath: /tmp
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
YAML
show "APISERVER_IP=\$(kubectl get endpoints kubernetes -n default -o jsonpath=...)"
APISERVER_IP=$("$K" get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
echo "API server endpoint address read from the cluster: $APISERVER_IP"
show "sed \"s#192.0.2.10/32#\${APISERVER_IP}/32#\" opencost-netpol.yaml | kubectl apply -f -"
sed "s#192.0.2.10/32#${APISERVER_IP}/32#" "opencost-netpol.yaml" | "$K" apply -f - 2>&1
show "helm template opencost opencost/opencost --version 2.5.33 -n $OC -f opencost-values.yaml | kubectl apply --dry-run=server -f -"
"$H" template opencost opencost/opencost --version 2.5.33 -n "$OC" \
  -f "opencost-values.yaml" > "opencost-render.yaml" 2>"opencost-render.err"
echo "helm template exit: $?"
"$K" apply --dry-run=server -n "$OC" -f "opencost-render.yaml" 2>&1
show "grep -c 'runAsUser: 1001' rendered objects"
grep -c 'runAsUser: 1001' "opencost-render.yaml"
show "grep image: rendered objects"
grep 'image:' "opencost-render.yaml" | sed 's/^ *//'

## step 3: spend caps. The quota, two suspended probes, and a deliberate denial
cat > "ml-job-cap.yaml" <<YAML
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ml-job-cap
  namespace: $ML
spec:
  hard:
    count/jobs.batch: "2"   # small on purpose, so the cap shows on kind
YAML
cat > "cap-probe.yaml" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: cap-probe
  namespace: $ML
spec:
  suspend: true         # no Pod starts; Kueue suspends queued Jobs the same way
  backoffLimit: 1
  activeDeadlineSeconds: 21600
  template:
    spec:
      serviceAccountName: recommender-train
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: train
          image: bookstore/recommender-train:dev   # built by ch.04
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
              nvidia.com/gpu: "1"
            limits:
              memory: 1Gi
              nvidia.com/gpu: "1"
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
YAML
show "kubectl apply -f ml-job-cap.yaml"
"$K" apply -f "ml-job-cap.yaml" 2>&1
show "kubectl apply -f cap-probe.yaml"
"$K" apply -f "cap-probe.yaml" 2>&1
show "sed 's/name: cap-probe\$/name: cap-probe-2/' cap-probe.yaml | kubectl apply -f -"
sed 's/name: cap-probe$/name: cap-probe-2/' "cap-probe.yaml" | "$K" apply -f - 2>&1
show "# Deliberate denial: a third Job over the cap, sent as a server dry run."
show "sed 's/name: cap-probe\$/name: cap-probe-3/' cap-probe.yaml > cap-probe-3.yaml"
sed 's/name: cap-probe$/name: cap-probe-3/' "cap-probe.yaml" > "cap-probe-3.yaml"
show "kubectl apply --dry-run=server -f cap-probe-3.yaml"
"$K" apply --dry-run=server -f "cap-probe-3.yaml" 2>&1
show "kubectl get resourcequota ml-job-cap -n $ML"
"$K" get resourcequota ml-job-cap -n "$ML" 2>&1

## step 4: MLflow manifests as a server dry run (the namespace already exists)
cat > "mlflow.yaml" <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mlflow
  namespace: $MF
automountServiceAccountToken: false
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: $MF
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-bookstore-ml
  namespace: $MF
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mlflow
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              app.kubernetes.io/part-of: bookstore-ml
      ports:
        - protocol: TCP
          port: 5000
---
apiVersion: v1
kind: Service
metadata:
  name: mlflow
  namespace: $MF
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: mlflow
  ports:
    - name: http
      port: 5000
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mlflow
  namespace: $MF
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: mlflow
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mlflow
    spec:
      serviceAccountName: mlflow
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: mlflow
          image: ghcr.io/mlflow/mlflow@sha256:b166428a3ab479e396f14d671987a70b27741a8d9b22f9d69a559c1fbf09d551
          command: ["/bin/sh", "-c"]
          args:
            - >-
              exec mlflow server --host 0.0.0.0 --port 5000
              --app-name basic-auth
              --backend-store-uri "\$(cat /etc/mlflow-auth/backend-store-uri)"
              --artifacts-destination "\$ARTIFACT_ROOT"
          env:
            - name: MLFLOW_AUTH_CONFIG_PATH
              value: /etc/mlflow-auth/basic_auth.ini
            - name: MLFLOW_AUTH_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mlflow-auth
                  key: admin-password
            - name: ARTIFACT_ROOT
              value: s3://example-bucket/mlflow
          ports:
            - name: http
              containerPort: 5000
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 1Gi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: auth
              mountPath: /etc/mlflow-auth
              readOnly: true
      volumes:
        - name: tmp
          emptyDir: {}
        - name: auth
          secret:
            secretName: mlflow-auth
            items:
              - key: basic_auth.ini
                path: basic_auth.ini
              - key: backend-store-uri
                path: backend-store-uri
YAML
show "kubectl apply --dry-run=server -f mlflow.yaml"
"$K" apply --dry-run=server -f "mlflow.yaml" 2>&1
show "kubectl get networkpolicy -n $MF"
"$K" get networkpolicy -n "$MF" 2>&1

## step 5: clean up the lab namespaces
show "kubectl delete namespace $OC $ML $MF --wait=false"
"$K" delete namespace "$OC" "$ML" "$MF" --wait=false 2>&1
rm -rf "$WORK"
