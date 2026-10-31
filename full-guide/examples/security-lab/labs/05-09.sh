#!/usr/bin/env bash
# Chapter 05.09: the exceptions registry, checked two ways. Tier A (kind).
#
# Part 1 needs no cluster. It runs Trivy 0.76.1 on a manifest with one known
# finding, then uses the registry's ignore entry to show a scanner honouring an
# exception until its expired_at date, and reporting the finding again after.
# Part 1b runs the bookstore's own expiry stage the way CI runs it, on the
# repository's real exception files, then on a copy with a lapsed date.
#
# Part 2 runs only against a kind cluster you own: the kubectl context must
# start with kind-. It applies a ValidatingAdmissionPolicy that refuses a
# namespace below restricted unless the namespace carries a reason and an expiry
# date no more than 365 days out. It creates four p05-09-* namespaces to show
# which the policy admits. It then creates a restricted service namespace, server
# dry-runs a complete catalog Deployment in it, and shows a privileged Pod refused.
# It deletes everything it created. Namespace removal is slow on a busy control
# plane, so the script does not wait for it; it waits a bounded time before a
# run, for namespaces an earlier run left terminating.
#
# A kind node is a container on the machine that runs kind. Part 2 writes only
# namespaces and one cluster-scoped policy, both named p05-09-*. It does not run
# a Pod, so no payload runs anywhere. Nothing here reaches a cloud.
set +e

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

REPO=$(cd "$(dirname "$0")/../../../.." && pwd)
[ -f "$REPO/full-guide/examples/bookstore/ci/scan.sh" ] || { echo "not in the repository: $REPO" >&2; exit 2; }

# Wait up to 300 seconds for p05-09 namespaces from an earlier run to finish
# terminating. Returns 1 if any is still there.
gone_wait() {
  local left i
  for i in $(seq 1 60); do
    left=$(kubectl get ns p05-09-restricted p05-09-no-expiry p05-09-exception p05-09-too-long p05-09-service --ignore-not-found --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$left" = 0 ] && return 0
    sleep 5
  done
  return 1
}

work=$(mktemp -d) && cd "$work" || exit 1
have_cluster=0
cleanup() {
  if [ "$have_cluster" = 1 ]; then
    kubectl delete ns p05-09-restricted p05-09-no-expiry p05-09-exception p05-09-too-long p05-09-service --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl delete validatingadmissionpolicybinding p05-09-exception-expiry --ignore-not-found >/dev/null 2>&1
    kubectl delete validatingadmissionpolicy p05-09-exception-expiry --ignore-not-found >/dev/null 2>&1
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# Dates relative to today, for the ignore entries in Part 1. The policy in Part 2
# cannot read a clock (CEL here has no `now`), so it measures the expiry window from
# metadata.creationTimestamp, which the API server sets before validating admission.
future=$(date -u -d '+180 days' +%F 2>/dev/null || date -u -v+180d +%F)
past=$(date -u -d '-30 days' +%F 2>/dev/null || date -u -v-30d +%F)

echo '## part 1: a scanner honours a registry entry until its expired_at date'

cat >exception-demo.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: exception-demo
  namespace: p05-09-demo
spec:
  containers:
    - name: app
      image: example.invalid/app@sha256:0000000000000000000000000000000000000000000000000000000000000000
      securityContext:
        privileged: true
YAML

run <<'CMD'
trivy --version | head -1
CMD

echo '## step 1: no registry entry, so the privileged container fails KSV-0017'
run <<'CMD'
trivy config --quiet --format json --ignorefile "" exception-demo.yaml | grep -c '"ID": "KSV-0017"'
CMD

echo "## step 2: an entry with expired_at $future, still in force"
cat >ignore-future.yaml <<YAML
misconfigurations:
  - id: KSV-0017
    paths:
      - exception-demo.yaml
    statement: "Demo entry: privileged container excepted for the registry worked example."
    expired_at: $future
YAML
run <<'CMD'
trivy config --quiet --format json --ignorefile ignore-future.yaml exception-demo.yaml | grep -c '"ID": "KSV-0017"'
CMD

echo "## step 3: the same entry with expired_at $past, now past its date"
cat >ignore-expired.yaml <<YAML
misconfigurations:
  - id: KSV-0017
    paths:
      - exception-demo.yaml
    statement: "Demo entry: privileged container excepted for the registry worked example."
    expired_at: $past
YAML
run <<'CMD'
trivy config --quiet --format json --ignorefile ignore-expired.yaml exception-demo.yaml | grep -c '"ID": "KSV-0017"'
CMD

echo '## part 1b, step 1: the bookstore expiry stage, as CI runs it on the repository'
run <<'CMD'
(cd "$REPO" && REPORT_DIR="$work/reports-ci" bash full-guide/examples/bookstore/ci/scan.sh expiry "full-guide/examples/bookstore/ci/zap/baseline.conf full-guide/examples/bookstore/ci/kube-linter.yaml"; echo "exit=$?")
CMD

echo '## part 1b, step 2: the same stage on a copy whose entry has a Revisit by date in the past'
mkdir -p lapsed
cat >lapsed/exceptions.conf <<'YAML'
checks:
  exclude:
    # Demo entry for chapter 05.09. Revisit by 2020-01-01.
    - no-anti-affinity
YAML
run <<'CMD'
(cd "$work/lapsed" && REPORT_DIR=reports bash "$REPO/full-guide/examples/bookstore/ci/scan.sh" expiry exceptions.conf; echo "exit=$?"; cat reports/expiry.txt)
CMD

echo '## part 2: the admission half, on a kind cluster you own'
ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "part 2 refused: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac
have_cluster=1

echo '## part 2, step 0: no p05-09 namespace from an earlier run is left'
kubectl delete ns p05-09-restricted p05-09-no-expiry p05-09-exception p05-09-too-long p05-09-service --ignore-not-found --wait=false >/dev/null 2>&1
if gone_wait; then
  echo 'none left'
else
  echo 'a p05-09 namespace is still terminating after 300 seconds; rerun later' >&2
  exit 2
fi
echo

cat >policy.yaml <<'YAML'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: p05-09-exception-expiry
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["namespaces"]
  matchConditions:
    - name: demo-namespaces-only
      expression: "object.metadata.name.startsWith('p05-09-')"
  variables:
    - name: level
      expression: >-
        has(object.metadata.labels) &&
        'pod-security.kubernetes.io/enforce' in object.metadata.labels ?
        object.metadata.labels['pod-security.kubernetes.io/enforce'] : 'restricted'
    - name: notes
      expression: >-
        has(object.metadata.annotations) ? object.metadata.annotations : {}
  validations:
    - expression: >-
        variables.level == 'restricted' ||
        ('security.example/exception-reason' in variables.notes &&
         'security.example/exception-expires' in variables.notes &&
         timestamp(variables.notes['security.example/exception-expires'] + 'T00:00:00Z') > timestamp(object.metadata.creationTimestamp) &&
         timestamp(variables.notes['security.example/exception-expires'] + 'T00:00:00Z') <= timestamp(object.metadata.creationTimestamp) + duration('8760h'))
      message: "a namespace below restricted needs a reason and an expiry within 365 days"
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: p05-09-exception-expiry
spec:
  policyName: p05-09-exception-expiry
  validationActions: ["Deny"]
YAML

run <<'CMD'
kubectl apply -f policy.yaml
CMD

echo '## step 4: wait until the binding enforces, using a server dry run'
cat >probe.yaml <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: p05-09-probe
  labels:
    pod-security.kubernetes.io/enforce: baseline
YAML
for i in $(seq 1 30); do
  if kubectl apply --dry-run=server -f probe.yaml 2>&1 | grep -q 'denied request'; then
    echo "binding enforced after about $i second(s)"
    break
  fi
  sleep 1
done
echo

cat >namespaces.yaml <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: p05-09-restricted
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.37
---
apiVersion: v1
kind: Namespace
metadata:
  name: p05-09-no-expiry
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/warn-version: v1.37
---
apiVersion: v1
kind: Namespace
metadata:
  name: p05-09-exception
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/warn-version: v1.37
  annotations:
    security.example/exception-reason: "Demo record: stands in for a registry entry. See chapter 05.09."
    security.example/exception-expires: "2027-06-30"
---
apiVersion: v1
kind: Namespace
metadata:
  name: p05-09-too-long
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/warn-version: v1.37
  annotations:
    security.example/exception-reason: "Demo record with an expiry more than 365 days out."
    security.example/exception-expires: "2028-01-01"
YAML

echo '## step 5: apply four namespaces; the policy admits or refuses each'
run <<'CMD'
kubectl apply -f namespaces.yaml
CMD

echo '## step 6: which of the four exist now'
run <<'CMD'
kubectl get ns p05-09-restricted p05-09-no-expiry p05-09-exception p05-09-too-long --ignore-not-found -L pod-security.kubernetes.io/enforce
CMD

echo '## step 7: a restricted service namespace, then its workload checked by a server dry run'
cat >service-ns.yaml <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: p05-09-service
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.37
YAML
run <<'CMD'
kubectl apply -f service-ns.yaml || { sleep 5; kubectl apply -f service-ns.yaml; }
CMD

cat >catalog-review.yaml <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: catalog
  namespace: p05-09-service
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
  namespace: p05-09-service
  labels:
    app.kubernetes.io/name: catalog
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: catalog
  template:
    metadata:
      labels:
        app.kubernetes.io/name: catalog
    spec:
      serviceAccountName: catalog
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: bookstore/catalog:dev
          ports:
            - containerPort: 8080
              name: http
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 128Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
YAML
run <<'CMD'
kubectl apply --dry-run=server -f catalog-review.yaml
CMD

echo '## step 7b: the namespace gets its default ServiceAccount, which admission looks up'
run <<'CMD'
for i in $(seq 1 60); do kubectl -n p05-09-service get serviceaccount default -o name 2>/dev/null && break; sleep 2; done
CMD

echo '## step 8: a deliberately privileged Pod in the same namespace, refused at admission'
run <<'CMD'
kubectl -n p05-09-service run catalog-privileged --image=bookstore/catalog:dev --privileged --dry-run=server
CMD

echo '## step 9: clean up what this run created'
run <<'CMD'
kubectl delete ns p05-09-restricted p05-09-no-expiry p05-09-exception p05-09-too-long p05-09-service --ignore-not-found --wait=false
CMD
run <<'CMD'
kubectl delete validatingadmissionpolicybinding p05-09-exception-expiry --ignore-not-found
CMD
run <<'CMD'
kubectl delete validatingadmissionpolicy p05-09-exception-expiry --ignore-not-found
CMD
