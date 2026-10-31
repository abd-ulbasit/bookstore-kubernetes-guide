#!/usr/bin/env bash
# Lab 12.08, MLflow step: the tracker with basic authentication, started once.
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory, after the other 12-08 steps. Its output is appended to the
# chapter's transcript as step 12. It creates three namespaces, all named
# p12-08-*: p12-08-mlflow for the tracker, p12-08-ml standing in for
# bookstore-ml (the one namespace the allow policy admits) and p12-08-store
# for a namespace outside the allow-list. It deletes them at the end.
#
# The image bookstore/mlflow-auth:dev (examples/bookstore/ml/tracking) must be
# loaded into the cluster. The lab has no PostgreSQL, so the first start keeps
# its database in SQLite on an emptyDir. The generated values are written to
# files in a temporary directory and never printed.
set +e

K="${KUBECTL:-kubectl}"
NS=p12-08-mlflow
ML=p12-08-ml
ST=p12-08-store
MANI=examples/bookstore/ml/tracking/mlflow.yaml

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

show() { printf '$ %s\n' "$*"; }

echo
echo "## step 12: the MLflow tracker with basic authentication, started once"
"$K" wait --for=delete "namespace/$ML" --timeout=240s >/dev/null 2>&1
"$K" wait --for=delete "namespace/$ST" --timeout=240s >/dev/null 2>&1
"$K" wait --for=delete "namespace/$NS" --timeout=240s >/dev/null 2>&1
show "kubectl create namespace $ML (stands in for bookstore-ml) and $ST (outside the allow-list)"
"$K" create namespace "$ML" 2>&1
"$K" create namespace "$ST" 2>&1
show "python: write the manifest with the lab namespace names (the Namespace object, the policy's namespace and the allowed namespace)"
python3 - "$MANI" "$WORK/mlflow.yaml" "$NS" "$ML" <<'PY'
import sys, yaml
src, dst, ns, ml = sys.argv[1:5]
docs = list(yaml.safe_load_all(open(src, encoding="utf-8")))
for d in docs:
    if d.get("kind") == "Namespace":
        d["metadata"]["name"] = ns
    if "namespace" in d.get("metadata", {}):
        d["metadata"]["namespace"] = ns
    text = yaml.safe_dump(d, sort_keys=False)
    if "bookstore-ml" in text:
        text = text.replace("bookstore-ml", ml)
    d.clear(); d.update(yaml.safe_load(text))
with open(dst, "w", encoding="utf-8") as fh:
    yaml.safe_dump_all(docs, fh, sort_keys=False)
print("wrote", len(docs), "documents")
PY
show "kubectl apply -f mlflow.yaml (the namespace, the policies, the Service and the Deployment)"
"$K" apply -f "$WORK/mlflow.yaml" 2>&1
show "kubectl create secret generic mlflow-auth -n $NS (basic_auth.ini, backend-store-uri and the Flask key, generated; none printed)"
umask 077
printf '[mlflow]\ndefault_permission = NO_PERMISSIONS\ndatabase_uri = sqlite:////var/lib/mlflow-db/auth.db\nadmin_username = admin\nadmin_password = %s\n' "$(openssl rand -base64 24)" > "$WORK/basic_auth.ini"
printf 'sqlite:////var/lib/mlflow-db/tracking.db' > "$WORK/backend-store-uri"
"$K" create secret generic mlflow-auth -n "$NS" \
  --from-file=basic_auth.ini="$WORK/basic_auth.ini" \
  --from-file=backend-store-uri="$WORK/backend-store-uri" \
  --from-literal=flask-secret-key="$(openssl rand -hex 32)" 2>&1
show "kubectl rollout status deployment/mlflow -n $NS --timeout=300s"
"$K" rollout status deployment/mlflow -n "$NS" --timeout=300s 2>&1

cat > "$WORK/probe.py" <<'PY'
import os, time, urllib.error, urllib.request
url = os.environ["MLFLOW_URL"]
last = None
for _ in range(45):
    try:
        r = urllib.request.urlopen(url + "/api/2.0/mlflow/experiments/search", timeout=5)
        print("experiments/search without credentials: HTTP", r.status)
        break
    except urllib.error.HTTPError as e:
        print("experiments/search without credentials: HTTP", e.code)
        break
    except urllib.error.URLError as e:
        last = e.reason
        time.sleep(2)
else:
    print("experiments/search without credentials: failed:", type(last).__name__, str(last)[:60])
PY
for PAIR in "caller:$ML" "stranger:$ST"; do
  POD=${PAIR%%:*}
  PNS=${PAIR#*:}
  cat > "$WORK/$POD.yaml" <<EOF2
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $PNS
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: bookstore/recommender-serve:dev
      imagePullPolicy: IfNotPresent
      command: ["sleep", "600"]
      env:
        - name: MLFLOW_URL
          value: "http://mlflow.$NS.svc.cluster.local:5000"
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { memory: 128Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
EOF2
  show "kubectl apply -f $POD.yaml (in $PNS)"
  "$K" apply -f "$WORK/$POD.yaml" 2>&1
  "$K" wait --for=condition=Ready "pod/$POD" -n "$PNS" --timeout=120s 2>&1
  show "kubectl exec -i -n $PNS $POD -- python -I - < probe.py"
  "$K" exec -i -n "$PNS" "$POD" -- python -I - < "$WORK/probe.py" 2>&1
done

show "kubectl logs deployment/mlflow -n $NS --tail=4"
"$K" logs deployment/mlflow -n "$NS" --tail=4 2>&1 | cut -c1-160

echo
echo "## step 13: cleanup of the MLflow step"
show "kubectl delete namespace $NS $ML $ST --wait=false"
"$K" delete namespace "$NS" "$ML" "$ST" --wait=false 2>&1
