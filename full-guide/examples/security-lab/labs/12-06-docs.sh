#!/usr/bin/env bash
# Lab 12.06, docs step: the predictor's interactive docs routes without a token.
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. Its output is appended to the chapter's transcript as step 10. It
# creates one restricted namespace named <prefix>-docs, where <prefix> is
# LAB_PREFIX (default p12-06), runs one Pod from
# the serve image (SERVE_IMAGE, default bookstore/recommender-serve:dev, built
# from examples/bookstore/ml/serve), and deletes the namespace at the end.
#
# The Pod starts the image's own entrypoint (uvicorn predictor:app) on
# localhost. It first writes a two-book stand-in model and a generated token to
# an emptyDir, because the predictor refuses to start without either. The model
# exists only so that the routes can be asked; no recommendation is claimed
# from it. FastAPI would serve /docs, /redoc and /openapi.json without any
# check, so predictor.py turns the three off. The token is never printed.
set +e

K="${KUBECTL:-kubectl}"
NS="${LAB_PREFIX:-p12-06}-docs"
IMAGE="${SERVE_IMAGE:-bookstore/recommender-serve:dev}"

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

show() { printf '$ %s\n' "$*"; }

echo
echo "## step 10: the interactive docs routes without a token"
"$K" wait --for=delete "namespace/$NS" --timeout=240s >/dev/null 2>&1
show "kubectl create namespace $NS (restricted)"
"$K" create namespace "$NS" 2>&1
"$K" label namespace "$NS" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted >/dev/null 2>&1
show "kubectl apply -f docs-check.yaml (one Pod: the predictor on localhost and a probe)"
"$K" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: docs-check
  namespace: $NS
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: check
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command: ["python", "-c"]
      args:
        - |-
          import os, secrets, subprocess, time, urllib.error, urllib.request
          import joblib
          os.makedirs("/tmp/model")
          joblib.dump({"kind": "stand-in", "version": "lab", "n_books": 2, "top_k": 1,
                       "neighbours": {1: [(2, 0.5)], 2: [(1, 0.5)]},
                       "books_index": {1: {"title": "A", "author": "B"},
                                       2: {"title": "C", "author": "D"}}},
                      "/tmp/model/model.joblib")
          token = secrets.token_hex(32)
          open("/tmp/token", "w").write(token)
          env = dict(os.environ, MODEL_DIR="/tmp/model", AUTH_TOKEN_FILE="/tmp/token")
          server = subprocess.Popen(
              ["python", "-m", "uvicorn", "predictor:app", "--host", "127.0.0.1",
               "--port", "8080", "--log-level", "warning"], env=env)
          base = "http://127.0.0.1:8080"
          def status(path, bearer=None):
              req = urllib.request.Request(base + path)
              if bearer:
                  req.add_header("Authorization", "Bearer " + bearer)
              try:
                  return urllib.request.urlopen(req, timeout=5).status
              except urllib.error.HTTPError as e:
                  return e.code
          for _ in range(60):
              try:
                  status("/healthz")
                  break
              except urllib.error.URLError:
                  time.sleep(1)
          for path in ["/healthz", "/recommend?book_id=1", "/docs", "/redoc", "/openapi.json"]:
              print("GET", path, "without a token:", status(path))
          print("GET /recommend?book_id=1 with the token:", status("/recommend?book_id=1", token))
          server.terminate()
      resources:
        requests: { cpu: 50m, memory: 128Mi }
        limits: { memory: 256Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
EOF
show "kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/docs-check -n $NS --timeout=180s"
"$K" wait --for=jsonpath='{.status.phase}'=Succeeded pod/docs-check -n "$NS" --timeout=180s 2>&1
show "kubectl logs docs-check -n $NS"
"$K" logs docs-check -n "$NS" 2>&1

echo
echo "## step 11: cleanup of the docs step"
show "kubectl delete namespace $NS --wait=false"
"$K" delete namespace "$NS" --wait=false 2>&1
