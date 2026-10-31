#!/usr/bin/env bash
# Lab 05.01, authenticators step: anonymous requests, and a workload
# certificate from a PodCertificateRequest. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from any directory. Its output
# is appended to the chapter's transcript. It creates one restricted namespace
# named <prefix>-pcr, where <prefix> is LAB_PREFIX (default p05-01), one
# cluster-scoped ClusterTrustBundle named lab.example.com:p05-01:ca, and it
# deletes both at the end.
#
# Part 1 sends requests with no credential, then with a bad one, with curl,
# and reads what the API server made of them (kubectl asks for a user name at
# the terminal when its kubeconfig holds no credential, so it cannot send an
# anonymous request unattended). Part 2 plays the signer of a Pod
# certificate. Kubernetes ships the API, the kubelet half and the projected
# volume, and no signer, so the lab's signer is a few lines of openssl that
# read the request and write the answer into its status. The CA is created for
# the run, lives in a temporary directory, and is deleted with it. The private
# key of the Pod is made by the kubelet and is never printed.
set +e

PFX="${LAB_PREFIX:-p05-01}"
export NS="$PFX-pcr"
export SIGNER="lab.example.com/p05-01"
export CTB="lab.example.com:p05-01:ca"
export BB=busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

# An ISO 8601 time from an openssl date, with GNU date or BSD date.
iso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -j -f "%b %e %T %Y %Z" "$1" +%Y-%m-%dT%H:%M:%SZ; }

work=$(mktemp -d) && cd "$work" || exit 1
cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl delete clustertrustbundle "$CTB" --ignore-not-found >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete clustertrustbundle "$CTB" --ignore-not-found >/dev/null 2>&1

echo '## authenticators step 1: requests with no credential, and with a bad one'
# The API server's address and the CA that signed its certificate. curl sends
# no credential at all, which is how an anonymous request looks to the server.
kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > cluster-ca.pem
export APISERVER
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

run <<'CMD'
curl -s --cacert cluster-ca.pem -w 'HTTP %{http_code}\n' "$APISERVER/version"
CMD
run <<'CMD'
curl -s --cacert cluster-ca.pem -w 'HTTP %{http_code}\n' "$APISERVER/api/v1/namespaces"
CMD
run <<'CMD'
curl -s --cacert cluster-ca.pem -H 'Authorization: Bearer not-a-token' -w 'HTTP %{http_code}\n' "$APISERVER/version"
CMD
run <<'CMD'
kubectl get clusterrolebinding system:public-info-viewer -o jsonpath='{range .subjects[*]}{.kind} {.name}{"\n"}{end}'
CMD

echo '## authenticators step 2: a trust bundle, and a Pod that asks for a certificate'
openssl ecparam -name prime256v1 -genkey -noout -out ca.key 2>/dev/null
openssl req -x509 -new -key ca.key -sha256 -days 2 -subj "/CN=p05-01 lab signer CA" -out ca.crt 2>/dev/null
{
  printf 'apiVersion: certificates.k8s.io/v1\nkind: ClusterTrustBundle\nmetadata:\n  name: %s\nspec:\n  signerName: %s\n  trustBundle: |\n' "$CTB" "$SIGNER"
  sed 's/^/    /' ca.crt
} > ctb.yaml

run <<'CMD'
kubectl create namespace "$NS"
CMD
run <<'CMD'
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=v1.37 pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted
CMD
until kubectl get serviceaccount default -n "$NS" >/dev/null 2>&1; do sleep 1; done
run <<'CMD'
kubectl create serviceaccount workload -n "$NS"
CMD
run <<'CMD'
kubectl create serviceaccount intruder -n "$NS"
CMD
run <<'CMD'
kubectl apply -f ctb.yaml
CMD

cat > pod.yaml <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: workload
  namespace: $NS
spec:
  serviceAccountName: workload
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $BB  # busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: identity
          mountPath: /var/run/identity
          readOnly: true
  volumes:
    - name: identity
      projected:
        sources:
          - podCertificate:
              signerName: $SIGNER
              keyType: ECDSAP256
              maxExpirationSeconds: 86400
              credentialBundlePath: credentialbundle.pem
          - clusterTrustBundle:
              signerName: $SIGNER
              labelSelector:
                matchLabels: {}
              path: ca.pem
YAML
sed -e 's/name: workload/name: intruder/' -e 's/serviceAccountName: workload/serviceAccountName: intruder/' pod.yaml > intruder.yaml

run <<'CMD'
kubectl apply -f pod.yaml -f intruder.yaml
CMD

# Wait for the kubelet to file one request for each Pod.
for i in $(seq 1 60); do
  [ "$(kubectl get podcertificaterequests -n "$NS" --no-headers 2>/dev/null | wc -l)" -ge 2 ] && break
  sleep 2
done
run <<'CMD'
kubectl get pod -n "$NS"
CMD
run <<'CMD'
kubectl get podcertificaterequests -n "$NS" -o custom-columns=POD:.spec.podName,SERVICEACCOUNT:.spec.serviceAccountName,SIGNER:.spec.signerName,ISSUED:.status.conditions[*].type
CMD

echo '## authenticators step 3: the signer decides, and the Pod gets a certificate or a refusal'
REQ=$(kubectl get podcertificaterequests -n "$NS" -o jsonpath='{range .items[?(@.spec.podName=="workload")]}{.metadata.name}{end}')
BAD=$(kubectl get podcertificaterequests -n "$NS" -o jsonpath='{range .items[?(@.spec.podName=="intruder")]}{.metadata.name}{end}')
export REQ BAD
run <<'CMD'
kubectl get podcertificaterequest "$REQ" -n "$NS" -o jsonpath='{.spec.stubPKCS10Request}' | base64 -d | openssl req -inform DER -out csr.pem
CMD
run <<'CMD'
openssl req -in csr.pem -noout -verify
CMD
printf 'subjectAltName=URI:spiffe://lab.example.com/ns/%s/sa/workload\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth,serverAuth\n' "$NS" > ext.cnf
run <<'CMD'
openssl x509 -req -in csr.pem -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -sha256 -extfile ext.cnf -out leaf.crt
CMD
run <<'CMD'
openssl x509 -in leaf.crt -noout -issuer -ext subjectAltName
CMD

NB=$(iso "$(openssl x509 -in leaf.crt -noout -startdate | cut -d= -f2)")
NA=$(iso "$(openssl x509 -in leaf.crt -noout -enddate | cut -d= -f2)")
REFRESH=$(date -u -d '+12 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+12H +%Y-%m-%dT%H:%M:%SZ)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat leaf.crt ca.crt > chain.pem
"${PYTHON:-python3}" - "$NB" "$NA" "$REFRESH" "$NOW" > issue.json <<'PY'
import json, sys
nb, na, refresh, now = sys.argv[1:5]
print(json.dumps({"status": {
    "certificateChain": open("chain.pem").read(),
    "notBefore": nb, "notAfter": na, "beginRefreshAt": refresh,
    "conditions": [{"type": "Issued", "status": "True", "reason": "Issued",
                    "message": "issued by the lab signer", "lastTransitionTime": now}]}}))
PY
"${PYTHON:-python3}" - "$NOW" > deny.json <<'PY'
import json, sys
print(json.dumps({"status": {"conditions": [{
    "type": "Denied", "status": "True", "reason": "UnknownServiceAccount",
    "message": "this signer issues only for the workload ServiceAccount",
    "lastTransitionTime": sys.argv[1]}]}}))
PY
run <<'CMD'
kubectl patch podcertificaterequest "$REQ" -n "$NS" --subresource=status --type=merge --patch-file issue.json
CMD
run <<'CMD'
kubectl patch podcertificaterequest "$BAD" -n "$NS" --subresource=status --type=merge --patch-file deny.json
CMD
kubectl wait --for=condition=Ready pod/workload -n "$NS" --timeout=120s >/dev/null 2>&1
run <<'CMD'
kubectl get pod -n "$NS"
CMD
run <<'CMD'
kubectl get podcertificaterequests -n "$NS" -o custom-columns=POD:.spec.podName,STATE:.status.conditions[*].type,REASON:.status.conditions[*].reason
CMD

echo '## authenticators step 4: what the Pod holds'
run <<'CMD'
kubectl exec workload -n "$NS" -- ls /var/run/identity
CMD
run <<'CMD'
kubectl exec workload -n "$NS" -- cat /var/run/identity/credentialbundle.pem | grep -c 'BEGIN CERTIFICATE'
CMD
run <<'CMD'
kubectl exec workload -n "$NS" -- cat /var/run/identity/credentialbundle.pem | grep -c 'BEGIN PRIVATE KEY'
CMD
kubectl exec workload -n "$NS" -- cat /var/run/identity/credentialbundle.pem > bundle.pem
kubectl exec workload -n "$NS" -- cat /var/run/identity/ca.pem > ca-from-pod.pem
run <<'CMD'
openssl x509 -in bundle.pem -noout -issuer -ext subjectAltName
CMD
run <<'CMD'
openssl verify -CAfile ca-from-pod.pem bundle.pem
CMD
run <<'CMD'
kubectl get clustertrustbundle "$CTB" -o jsonpath='{.spec.signerName}{"\n"}'
CMD
echo '## done: the namespace and the trust bundle are deleted on exit'
