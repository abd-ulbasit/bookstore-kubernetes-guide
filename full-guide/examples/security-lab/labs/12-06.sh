#!/usr/bin/env bash
# Lab 12.06: model serving and inference. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. It creates three namespaces, all named p12-06-*, and deletes them
# at the end. p12-06-ml stands in for bookstore-ml (restricted, where the model
# lives and is served), p12-06-store for the bookstore namespace whose catalog
# Pod is the caller, and p12-06-other for a namespace outside the allow-list.
# The chapter names bookstore-ml and bookstore; this script applies the same
# files with only those names replaced.
#
# It needs two images in the kind cluster: bookstore/recommender-train:dev
# (examples/bookstore/ml/train) and bookstore/recommender-serve:dev
# (examples/bookstore/ml/serve). The KServe step renders the CRD chart and
# checks the InferenceService schema. It applies nothing cluster-scoped.
#
# Three results are deliberate and labelled in the chapter: the 401 and 422
# answers, the 401 the callers get without a token, and the pickle load that
# fails. Generated values, the bearer token and local paths are never printed.
set +e

K="${KUBECTL:-kubectl}"
PY="${PY:-python3}"
HELM_BIN="${HELM:-helm}"
ML=p12-06-ml
STORE=p12-06-store
OTHER=p12-06-other
MANI=examples/bookstore/ml
DIR="$(mktemp -d)"
PF_PID=""
trap '[ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; rm -rf "$DIR"' EXIT

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

# Print a command the way a reader would type it, then run it.
show() { printf '$ %s\n' "$*"; }

echo "# Transcript for 12-kubernetes-for-machine-learning/06-model-serving-and-inference.md"
echo "# Tier A: a kind cluster that the lab owns. Kubernetes v1.37.0 server and"
echo "# kubectl v1.37.2, recorded below in step 0."
echo "# Recorded by running examples/security-lab/labs/12-06.sh from full-guide/."
echo "# The lab used namespaces p12-06-ml, p12-06-store and p12-06-other. The chapter"
echo "# names bookstore-ml and bookstore and applies the same files. The cluster's"
echo "# only node is named sf-pilot-control-plane; the node name is kept as captured."
echo "# The bearer token is written to a Secret by openssl and is never printed."
echo

echo "## step 0: versions and a clean start"
show "kubectl version"
"$K" version 2>&1 | grep -E 'Client Version|Server Version'
show "kubectl get nodes -o custom-columns=NAME:.metadata.name,RUNTIME:.status.nodeInfo.containerRuntimeVersion"
"$K" get nodes -o custom-columns=NAME:.metadata.name,RUNTIME:.status.nodeInfo.containerRuntimeVersion 2>&1
show "kubectl get namespace $ML $STORE $OTHER"
"$K" get namespace "$ML" "$STORE" "$OTHER" 2>&1
show "kubectl get apiservice v1beta1.metrics.k8s.io"
"$K" get apiservice v1beta1.metrics.k8s.io 2>&1
show "kubectl get crd -o name | grep -c serving.kserve.io"
"$K" get crd -o name 2>/dev/null | grep -c serving.kserve.io
echo

echo "## step 1: three namespaces, restricted where workloads run, and default-deny"
show "kubectl create namespace $ML"
"$K" create namespace "$ML" 2>&1
show "kubectl label namespace $ML pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted"
"$K" label namespace "$ML" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted 2>&1
show "kubectl create namespace $STORE"
"$K" create namespace "$STORE" 2>&1
show "kubectl label namespace $STORE pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted"
"$K" label namespace "$STORE" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted 2>&1
show "kubectl create namespace $OTHER"
"$K" create namespace "$OTHER" 2>&1
show "kubectl label namespace $OTHER pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted"
"$K" label namespace "$OTHER" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted 2>&1
show "kubectl apply -f - (default-deny ingress, the policy ch.01 applies)"
"$K" apply -f - 2>&1 <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: $ML
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
EOF
show "sed (namespaces replaced; the allow-list selects the $STORE namespace) recommender-security.yaml | kubectl apply -f -"
sed -e "s/namespace: bookstore-ml/namespace: $ML/" -e "s/kubernetes.io\/metadata.name: bookstore\$/kubernetes.io\/metadata.name: $STORE/" "$MANI/serve/recommender-security.yaml" | "$K" apply -f - 2>&1
echo

echo "## step 2: train the recommender (the ch.04 Job), which writes model.joblib"
show "sed 's/namespace: bookstore-ml/namespace: $ML/' $MANI/train/recommender-train-job.yaml | kubectl apply -f -"
sed "s/namespace: bookstore-ml/namespace: $ML/" "$MANI/train/recommender-train-job.yaml" | "$K" apply -f - 2>&1
show "kubectl wait --for=condition=complete job/recommender-train -n $ML --timeout=600s"
"$K" wait --for=condition=complete job/recommender-train -n "$ML" --timeout=600s 2>&1
show "kubectl logs job/recommender-train -n $ML --tail=3"
"$K" logs job/recommender-train -n "$ML" --tail=3 2>&1
echo

echo "## step 3: joblib.load is pickle, and pickle runs the code it reads"
# The payload is a protocol 0 pickle that calls builtins.exec on one line of
# Python. It prints one line, then tries to write under the root filesystem.
cat > "$DIR/poisoned-model.joblib" <<'PAYLOAD'
cbuiltins
exec
(S'print("payload ran as uid", __import__("os").getuid()); open("/workspace/pwned.txt", "w")'
tR.
PAYLOAD
show "python: pickletools.dis on the file (disassembles the opcodes; runs nothing)"
"$PY" -c "import pickletools,sys; pickletools.dis(open(sys.argv[1],'rb').read())" "$DIR/poisoned-model.joblib" 2>&1
show "kubectl create configmap poisoned-model -n $ML --from-file=poisoned-model.joblib=<the file above>"
"$K" create configmap poisoned-model -n "$ML" --from-file=poisoned-model.joblib="$DIR/poisoned-model.joblib" 2>&1
show "sed 's/namespace: bookstore-ml/namespace: $ML/' $MANI/serve/pickle-check.yaml | kubectl apply -f -"
sed "s/namespace: bookstore-ml/namespace: $ML/" "$MANI/serve/pickle-check.yaml" | "$K" apply -f - 2>&1
show "kubectl wait --for=jsonpath='{.status.phase}'=Failed pod/pickle-check -n $ML --timeout=180s"
"$K" wait --for=jsonpath='{.status.phase}'=Failed pod/pickle-check -n "$ML" --timeout=180s 2>&1
show "kubectl logs pod/pickle-check -n $ML"
"$K" logs pod/pickle-check -n "$ML" 2>&1
show "kubectl get pod pickle-check -n $ML -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}'"
"$K" get pod pickle-check -n "$ML" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>&1
echo
echo

echo "## step 4: the caller token, the identity, the allow-list and the quota, then the Deployment"
show "kubectl create secret generic recommender-caller-token -n $ML --from-literal=token=\"\$(openssl rand -hex 32)\""
"$K" create secret generic recommender-caller-token -n "$ML" --from-literal=token="$(openssl rand -hex 32)" 2>&1
show "sed 's/namespace: bookstore-ml/namespace: $ML/' $MANI/serve/recommender-deployment.yaml | kubectl apply -f -"
sed "s/namespace: bookstore-ml/namespace: $ML/" "$MANI/serve/recommender-deployment.yaml" | "$K" apply -f - 2>&1
show "sed 's/namespace: bookstore-ml/namespace: $ML/' $MANI/serve/recommender-service.yaml | kubectl apply -f -"
sed "s/namespace: bookstore-ml/namespace: $ML/" "$MANI/serve/recommender-service.yaml" | "$K" apply -f - 2>&1
show "kubectl rollout status deploy/recommender -n $ML --timeout=180s"
"$K" rollout status deploy/recommender -n "$ML" --timeout=180s 2>&1
show "kubectl get deploy recommender -n $ML -o jsonpath='{.spec.template.spec.serviceAccountName} automount={.spec.template.spec.automountServiceAccountToken}'"
"$K" get deploy recommender -n "$ML" -o jsonpath='{.spec.template.spec.serviceAccountName} automount={.spec.template.spec.automountServiceAccountToken}' 2>&1
echo
echo

echo "## step 5: call the endpoint from outside the Pod (port-forward is the reader's path)"
"$K" port-forward -n "$ML" svc/recommender 18080:8080 >"$DIR/pf.log" 2>&1 &
PF_PID=$!
for _ in $(seq 1 30); do
  curl -s -o /dev/null http://127.0.0.1:18080/healthz && break
  sleep 1
done
TOKEN=$("$K" get secret recommender-caller-token -n "$ML" -o jsonpath='{.data.token}' | base64 -d)
BIG=$("$PY" -c 'import json; print(json.dumps({"instances": [{"book_id": 1, "k": 3}] * 51}))')
show "curl -s -w ' %{http_code}\n' http://127.0.0.1:18080/ready"
curl -s -w ' %{http_code}\n' http://127.0.0.1:18080/ready
show "curl -s -w ' %{http_code}\n' 'http://127.0.0.1:18080/recommend?book_id=1&k=3'   (no token: denied)"
curl -s -w ' %{http_code}\n' 'http://127.0.0.1:18080/recommend?book_id=1&k=3'
show "curl -s -w ' %{http_code}\n' -H \"Authorization: Bearer \$TOKEN\" 'http://127.0.0.1:18080/recommend?book_id=1&k=3'"
curl -s -w ' %{http_code}\n' -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:18080/recommend?book_id=1&k=3'
show "curl -s -o /dev/null -w '%{http_code}\n' -H \"Authorization: Bearer \$TOKEN\" -X POST -d '<51 instances>' .../v1/models/recommender:predict   (over the cap)"
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' -X POST -d "$BIG" http://127.0.0.1:18080/v1/models/recommender:predict
show "curl -s -w ' %{http_code}\n' -H \"Authorization: Bearer \$TOKEN\" -H 'content-type: application/json' -X POST -d '{\"instances\":[{\"book_id\":1,\"k\":3},{\"book_id\":2,\"k\":2}]}' .../v1/models/recommender:predict"
curl -s -w ' %{http_code}\n' -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' -X POST -d '{"instances":[{"book_id":1,"k":3},{"book_id":2,"k":2}]}' http://127.0.0.1:18080/v1/models/recommender:predict
kill "$PF_PID" 2>/dev/null
wait "$PF_PID" 2>/dev/null
PF_PID=""
echo

echo "## step 6: the allow-list in place, and the two callers that were not admitted"
show "kubectl get networkpolicy -n $ML"
"$K" get networkpolicy -n "$ML" 2>&1
for spec in "$STORE catalog-client catalog" "$OTHER stranger none"; do
  set -- $spec
  ns=$1; name=$2; label=$3
  if [ "$label" = "none" ]; then labels_yaml="{}"; else labels_yaml="{app: $label}"; fi
  show "kubectl apply -f - (a client Pod in $ns, label app=$label)"
  "$K" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $ns
  labels: $labels_yaml
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: client
      image: bookstore/recommender-serve:dev
      imagePullPolicy: IfNotPresent
      command:
        - python
        - -c
        - "import urllib.request as r, urllib.error as e\ntry:\n  r.urlopen('http://recommender.$ML.svc.cluster.local:8080/recommend?book_id=1&k=3', timeout=10); print('200')\nexcept e.HTTPError as x: print(x.code)"
      resources:
        requests:
          cpu: "50m"
          memory: 64Mi
        limits:
          memory: 128Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
  # A client whose request times out exits with an error, so wait for either
  # terminal phase and report the phase the Pod reached.
  for _ in $(seq 1 60); do
    p=$("$K" get pod/"$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$p" in Succeeded|Failed) break ;; esac
    sleep 3
  done
  show "kubectl get pod $name -n $ns -o jsonpath='{.status.phase}'"
  "$K" get pod "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>&1; echo
  show "kubectl logs pod/$name -n $ns"
  "$K" logs pod/"$name" -n "$ns" 2>&1
done
echo

echo "## step 7: the cost ceiling: a quota, and a scale-up past it"
show "kubectl get resourcequota recommender-quota -n $ML"
"$K" get resourcequota recommender-quota -n "$ML" 2>&1
show "kubectl scale deploy/recommender -n $ML --replicas=10"
"$K" scale deploy/recommender -n "$ML" --replicas=10 2>&1
# Wait until the ReplicaSet controller has recorded the refusal, up to two minutes.
for _ in $(seq 1 40); do
  n=$("$K" get events -n "$ML" --field-selector reason=FailedCreate --no-headers 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && break
  sleep 3
done
show "kubectl get deploy recommender -n $ML"
"$K" get deploy recommender -n "$ML" 2>&1
show "kubectl get events -n $ML --field-selector reason=FailedCreate"
"$K" get events -n "$ML" --field-selector reason=FailedCreate 2>&1
show "kubectl describe resourcequota recommender-quota -n $ML"
"$K" describe resourcequota recommender-quota -n "$ML" 2>&1
show "kubectl scale deploy/recommender -n $ML --replicas=1"
"$K" scale deploy/recommender -n "$ML" --replicas=1 2>&1
echo

echo "## step 8: the InferenceService: its schema from the release's CRD chart"
"$HELM_BIN" template kserve-crd oci://ghcr.io/kserve/charts/kserve-crd --version v0.21.0 >"$DIR/kserve-crd.yaml" 2>"$DIR/helm.err"
show "helm template kserve-crd oci://ghcr.io/kserve/charts/kserve-crd --version v0.21.0 | check the v1beta1 predictor fields"
"$PY" - "$DIR/kserve-crd.yaml" <<'PYEOF' 2>&1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
for d in docs:
    if d.get("kind") == "CustomResourceDefinition" and d["spec"]["names"]["kind"] == "InferenceService":
        for v in d["spec"]["versions"]:
            if v["name"] != "v1beta1":
                continue
            pred = v["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["predictor"]["properties"]
            for k in ["serviceAccountName", "automountServiceAccountToken", "securityContext", "containers", "volumes", "minReplicas", "maxReplicas", "timeout", "canaryTrafficPercent", "scaleTarget", "scaleMetric"]:
                print("predictor." + k + ":", "present" if k in pred else "MISSING")
PYEOF
show "sed 's/namespace: bookstore-ml/namespace: $ML/' $MANI/serve/recommender-inferenceservice.yaml | kubectl apply --dry-run=server -f -"
sed "s/namespace: bookstore-ml/namespace: $ML/" "$MANI/serve/recommender-inferenceservice.yaml" | "$K" apply --dry-run=server -f - 2>&1
echo

echo "## step 9: delete what the lab created"
show "kubectl delete namespace $ML $STORE $OTHER --wait=true --timeout=300s"
"$K" delete namespace "$ML" "$STORE" "$OTHER" --wait=true --timeout=300s 2>&1
show "kubectl get namespace $ML $STORE $OTHER"
"$K" get namespace "$ML" "$STORE" "$OTHER" 2>&1
echo "# end of lab 12.06"
