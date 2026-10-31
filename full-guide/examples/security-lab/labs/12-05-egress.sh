#!/usr/bin/env bash
# Lab 12.05, step 11: the chart's singleuser NetworkPolicy, enforced.
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory, after 12-05.sh. Its output is appended to the chapter's transcript
# as step 11. It creates one namespace, p12-05-jupyter, labels it restricted,
# renders only the singleuser NetworkPolicy of the pinned Zero-to-JupyterHub
# chart, applies it, and runs two Pods in the namespace: one labelled as a
# singleuser server, which the policy selects, and one unlabelled control.
# It deletes the namespace at the end.
#
# VALUES must point to a copy of the chapter's jupyterhub-values.yaml. The
# chart is added to a throwaway Helm config, so the user's repositories stay as
# they are.
set +e

K="${KUBECTL:-kubectl}"
H="${HELM:-helm}"
NS=p12-05-jupyter
VALUES="${VALUES:?set VALUES to a copy of the jupyterhub-values.yaml file}"

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac
WORK=$(mktemp -d)
export HELM_REPOSITORY_CONFIG="$WORK/repositories.yaml"
export HELM_REPOSITORY_CACHE="$WORK/cache"
trap 'rm -rf "$WORK"' EXIT

show() { printf '$ %s\n' "$*"; }

echo
echo "## step 11: the singleuser NetworkPolicy, enforced (the chart's render; a probe from two Pods)"
show "helm repo add jupyterhub https://hub.jupyter.org/helm-chart/"
"$H" repo add jupyterhub https://hub.jupyter.org/helm-chart/ >/dev/null 2>&1
"$H" repo update jupyterhub >/dev/null 2>&1
show "helm template jupyterhub jupyterhub/jupyterhub --version 4.4.4 -n $NS -f jupyterhub-values.yaml --show-only templates/singleuser/netpol.yaml"
"$H" template jupyterhub jupyterhub/jupyterhub --version 4.4.4 --namespace "$NS" \
  -f "$VALUES" --show-only templates/singleuser/netpol.yaml > "$WORK/netpol.yaml" 2>&1
grep -n -e 'name:' -e 'component: singleuser-server' -e 'port:' "$WORK/netpol.yaml" | head -12
"$K" wait --for=delete "namespace/$NS" --timeout=240s >/dev/null 2>&1
"$K" create namespace "$NS" 2>&1
"$K" label namespace "$NS" pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null 2>&1
show "kubectl apply -f netpol.yaml -n $NS"
"$K" apply -n "$NS" -f "$WORK/netpol.yaml" 2>&1

show "kubectl get endpoints kubernetes -n default (the address is read into a variable and not printed)"
API_IP=$("$K" get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
API_PORT=$("$K" get endpoints kubernetes -n default -o jsonpath='{.subsets[0].ports[0].port}' 2>/dev/null)
for POD in notebook-probe control; do
  if [ "$POD" = notebook-probe ]; then
    LABEL='    component: singleuser-server
    app: jupyterhub
    release: jupyterhub'
  else
    LABEL='    app: control'
  fi
  cat > "$WORK/$POD.yaml" <<EOF2
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
  labels:
$LABEL
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: bookstore/recommender-serve:dev
      imagePullPolicy: IfNotPresent
      command: ["sleep", "600"]
      env:
        - name: API_ADDR
          value: "$API_IP:$API_PORT"
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { memory: 128Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
EOF2
  show "kubectl apply -f $POD.yaml (labels: $(echo "$LABEL" | sed 's/^ *//'))"
  "$K" apply -n "$NS" -f "$WORK/$POD.yaml" 2>&1
  "$K" wait --for=condition=Ready "pod/$POD" -n "$NS" --timeout=120s 2>&1
done
cat > "$WORK/probe.py" <<'PY'
import os, socket, ssl, urllib.error, urllib.request
host, port = os.environ["API_ADDR"].rsplit(":", 1)
ctx = ssl._create_unverified_context()
def check(label, fn):
    try:
        print(label, fn())
    except urllib.error.HTTPError as e:
        print(label, "HTTP", e.code)
    except Exception as e:
        print(label, "failed:", type(e).__name__)
check("dns kubernetes.default.svc:", lambda: socket.gethostbyname("kubernetes.default.svc"))
check("https GET /version on the API server:",
      lambda: "HTTP " + str(urllib.request.urlopen(f"https://{host}:{port}/version", timeout=5, context=ctx).status))
PY
for POD in notebook-probe control; do
  show "kubectl exec -i $POD -- python -I - < probe.py"
  "$K" exec -i -n "$NS" "$POD" -- python -I - < "$WORK/probe.py" 2>&1
done

echo
show "kubectl delete namespace $NS --wait=false"
"$K" delete namespace "$NS" --wait=false 2>&1
