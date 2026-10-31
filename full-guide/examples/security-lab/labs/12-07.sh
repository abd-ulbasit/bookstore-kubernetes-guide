#!/usr/bin/env bash
# Lab 12.07: ML pipelines and workflows. Tier A (kind), light steps only.
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. It creates two namespaces prefixed p12-07-, labels them
# restricted, and applies the pipeline's ServiceAccounts, Roles and bindings
# (with only the namespace names replaced). It then checks what each identity
# may do, server-dry-runs the baseline Pod and a deliberately refused variant,
# and shows the Argo Events objects failing with the expected "no matches"
# error, because their CRDs are not installed. It renders the Argo Workflows
# chart with the chapter's values file and reads the restricted settings out
# of the render. It installs no Argo component: those installs are heavy, so
# the chapter cites them. It deletes its namespaces at the end.
#
# The chapter names the bookstore-ml and argo-events namespaces; this lab uses
# p12-07-bookstore-ml and p12-07-argo-events.
set +e

K="${KUBECTL:-kubectl}"
H="${HELM:-helm}"
NS=p12-07-bookstore-ml
EV=p12-07-argo-events
PIPE=examples/bookstore/ml/pipeline

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

WORK=$(mktemp -d)
export HELM_REPOSITORY_CONFIG="$WORK/repositories.yaml"
export HELM_REPOSITORY_CACHE="$WORK/cache"
trap 'rm -rf "$WORK"' EXIT

echo "# Transcript for 12-kubernetes-for-machine-learning/07-ml-pipelines-and-workflows.md,"
echo "# lab steps 0 to 10. Recorded by running examples/security-lab/labs/12-07.sh"
echo "# from full-guide/ against the kind cluster sf-pilot (Tier A)."
echo "# The chapter names the bookstore-ml and argo-events namespaces. The lab used"
echo "# p12-07-bookstore-ml and p12-07-argo-events, and applied the same files with"
echo "# only the namespace names replaced. Lines that name the lab namespaces are"
echo "# kept as captured."
echo "# No Argo component is installed: the install is heavy, so the chapter cites"
echo "# it. Step 7 renders the chart and reads the result; it installs nothing."
echo "# Steps 8 and 9 read image facts with docker run and test the step Pods' egress"
echo "# in a namespace of their own, with a test default-deny for egress."

# Print a command the way a reader would type it, then run it.
show() { printf '$ %s\n' "$*"; }

# Replace the chapter's namespace names with the lab's.
lab_ns() { sed -e "s/namespace: bookstore-ml/namespace: $NS/g" -e "s/namespace: argo-events/namespace: $EV/g"; }

# Print the documents of a manifest file, leaving out the listed kinds.
drop_kinds() {
  python3 - "$1" "$2" <<'PY'
import sys
path, kinds = sys.argv[1], sys.argv[2].split(",")
docs = open(path, encoding="utf-8").read().split("\n---\n")
keep = []
for doc in docs:
    body = "\n" + doc + "\n"
    if any(f"\nkind: {k}\n" in body for k in kinds):
        continue
    keep.append(doc)
print("\n---\n".join(keep))
PY
}

echo
echo "## step 0: versions and the cluster"
show "kubectl version"
"$K" version 2>&1 | grep -E 'Client Version|Server Version'
show "kubectl config current-context"
echo "$ctx"

echo
echo "## step 1: two namespaces labelled restricted"
show "kubectl create namespace $NS"
"$K" create namespace "$NS"
show "kubectl create namespace $EV"
"$K" create namespace "$EV"
for ns in "$NS" "$EV"; do
  show "kubectl label namespace $ns (restricted: enforce, audit, warn)"
  "$K" label namespace "$ns" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/audit-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=latest --overwrite
done
show "kubectl get namespace $NS $EV --show-labels"
"$K" get namespace "$NS" "$EV" --show-labels 2>&1

echo
echo "## step 2: the pipeline's identities (from recommender-workflow.yaml and recommender-sensor.yaml)"
show "kubectl apply -f recommender-workflow.yaml (ServiceAccounts, Roles, RoleBindings; no WorkflowTemplate)"
drop_kinds "$PIPE/recommender-workflow.yaml" WorkflowTemplate | lab_ns | "$K" apply -f - 2>&1
show "kubectl apply -f recommender-sensor.yaml (the Sensor's ServiceAccount, Role and RoleBinding; no Sensor)"
drop_kinds "$PIPE/recommender-sensor.yaml" Sensor | lab_ns | "$K" apply -f - 2>&1
show "kubectl apply -f recommender-dataset-curl.yaml (ServiceAccount only; no Pod)"
drop_kinds "$PIPE/recommender-dataset-curl.yaml" Pod | lab_ns | "$K" apply -f - 2>&1

echo
echo "## step 3: what each identity may do (RBAC answers)"
PROMOTE="system:serviceaccount:$NS:recommender-promote"
REGISTER="system:serviceaccount:$NS:recommender-register"
SENSOR="system:serviceaccount:$EV:recommender-sensor"
show "kubectl auth can-i patch deployments/recommender --as=$PROMOTE"
"$K" auth can-i patch deployments/recommender -n "$NS" --as="$PROMOTE" 2>&1
show "kubectl auth can-i patch deployments/another --as=$PROMOTE"
"$K" auth can-i patch deployments/another -n "$NS" --as="$PROMOTE" 2>&1
show "kubectl auth can-i get secrets --as=$REGISTER"
"$K" auth can-i get secrets -n "$NS" --as="$REGISTER" 2>&1
show "kubectl auth can-i create configmaps --as=$REGISTER"
"$K" auth can-i create configmaps -n "$NS" --as="$REGISTER" 2>&1
show "kubectl auth can-i create configmaps --as=$SENSOR"
"$K" auth can-i create configmaps -n "$NS" --as="$SENSOR" 2>&1

echo
echo "## step 4: the baseline Pod, server dry-run under restricted"
show "kubectl apply --dry-run=server -f recommender-dataset-curl.yaml (the Pod)"
drop_kinds "$PIPE/recommender-dataset-curl.yaml" ServiceAccount | lab_ns | "$K" apply --dry-run=server -f - 2>&1

echo
echo "## step 5: a deliberate refusal: the same Pod with runAsUser 0"
show "kubectl apply --dry-run=server -f (the Pod with runAsUser: 0, a deliberate refusal)"
drop_kinds "$PIPE/recommender-dataset-curl.yaml" ServiceAccount | lab_ns \
  | sed 's/runAsUser: 100$/runAsUser: 0/' | "$K" apply --dry-run=server -f - 2>&1

echo
echo "## step 6: the Argo Events objects need their CRDs (the expected error)"
show "kubectl apply --dry-run=server -f recommender-eventsource.yaml (EventSource; CRD not installed)"
drop_kinds "$PIPE/recommender-eventsource.yaml" ServiceAccount | lab_ns | "$K" apply --dry-run=server -f - 2>&1 | head -3

echo
echo "## step 7: the chart renders the pinned settings (helm template; nothing installed)"
show "helm repo add argo https://argoproj.github.io/argo-helm"
"$H" repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1
show "helm template argo-workflows argo/argo-workflows --version 2.0.15 -n argo -f argo-workflows-values.yaml > argo-workflows.yaml"
"$H" template argo-workflows argo/argo-workflows --version 2.0.15 -n argo \
  -f "$PIPE/argo-workflows-values.yaml" > "$WORK/argo-workflows.yaml" 2>&1
show "grep -n -e 'argoexec:' -e 'workflow-controller:' -e 'crdinstaller:' argo-workflows.yaml"
grep -n -e 'argoexec:' -e 'workflow-controller:' -e 'crdinstaller:' "$WORK/argo-workflows.yaml" 2>&1
show "sed -n '/^  config: |/,/^    nodeEvents:/p' argo-workflows.yaml"
sed -n '/^  config: |/,/^    nodeEvents:/p' "$WORK/argo-workflows.yaml" 2>&1
show "grep -n -B2 -A1 'seccompProfile' argo-workflows.yaml"
grep -n -B2 -A1 'seccompProfile' "$WORK/argo-workflows.yaml" 2>&1

echo
echo "## step 8: the image facts the chapter cites (docker run on the remote engine)"
CG=cgr.dev/chainguard/kubectl:latest-dev@sha256:ee760c803cc3856d99f13dfd989bce461d2b324ae49e70b72c717f3bfaba9cbb
CURL=curlimages/curl:8.10.1@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b
show "docker run --rm --entrypoint /bin/sh $CG -c 'id; kubectl version --client'"
docker run --rm --entrypoint /bin/sh "$CG" -c 'id; kubectl version --client' 2>&1
show "docker run --rm --entrypoint /bin/sh $CURL -c 'id'"
docker run --rm --entrypoint /bin/sh "$CURL" -c 'id' 2>&1

echo
echo "## step 9: a step Pod's egress: default-deny, then the Workflow Pod allow"
show "kubectl get endpoints kubernetes -n default (the API server address is read into a variable and not printed)"
API_IP=$("$K" get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
API_PORT=$("$K" get endpoints kubernetes -n default -o jsonpath='{.subsets[0].ports[0].port}' 2>/dev/null)
echo "endpoint read: ok"
"$K" create namespace "$NS" >/dev/null 2>&1
"$K" label namespace "$NS" pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null 2>&1
show "kubectl apply -f default-deny-egress (test policy: egress only, every Pod in $NS)"
cat > "$WORK/deny.yaml" <<EOF2
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: $NS
spec:
  podSelector: {}
  policyTypes: [Egress]
EOF2
"$K" apply -f "$WORK/deny.yaml" 2>&1
show "kubectl apply -f workflow-egress.yaml (the chapter's file, namespace replaced, the documentation address replaced with the endpoint)"
sed -e "s/namespace: bookstore-ml/namespace: $NS/" -e "s|203.0.113.10/32|$API_IP/32|" \
  "$PIPE/workflow-egress.yaml" | "$K" apply -f - 2>&1
for POD in workflow-probe stranger; do
  if [ "$POD" = workflow-probe ]; then
    LABEL='    workflows.argoproj.io/workflow: p12-07-probe'
  else
    LABEL='    app: stranger'
  fi
  cat > "$WORK/$POD.yaml" <<EOF3
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
        - name: API_ADDR
          value: "$API_IP:$API_PORT"
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { memory: 128Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
EOF3
  show "kubectl apply -f $POD.yaml (the Pod's labels: $(echo "$LABEL" | sed 's/^ *//'))"
  "$K" apply -f "$WORK/$POD.yaml" 2>&1
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
show "kubectl exec -i workflow-probe -- python -I - < probe.py (labelled as a Workflow Pod)"
"$K" exec -i -n "$NS" workflow-probe -- python -I - < "$WORK/probe.py" 2>&1
show "kubectl exec -i stranger -- python -I - < probe.py (no Workflow label)"
"$K" exec -i -n "$NS" stranger -- python -I - < "$WORK/probe.py" 2>&1

echo
echo "## step 10: cleanup"
show "kubectl delete namespace $NS $EV --wait=false"
"$K" delete namespace "$NS" "$EV" --wait=false 2>&1
