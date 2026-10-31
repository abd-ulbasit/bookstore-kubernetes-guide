#!/usr/bin/env bash
# Lab 05.07: Admission control and policy as code. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from any directory. The lab
# names the kubectl context it may use in LAB_CONTEXT and refuses any other.
#
# MODE=shared (the default) attacks an open namespace, adds
# ValidatingAdmissionPolicy and MutatingAdmissionPolicy, attacks again, runs
# the policy unit tests and the Conftest checks on the Bookstore's manifests
# and Terraform plan, and renders the Kyverno and Gatekeeper charts without
# installing them. It installs nothing. LAB_CONTEXT defaults to kind-sf-pilot.
#
# MODE=full installs the two policy engines, one after the other, on the kind
# cluster that LAB_CONTEXT names, which it requires. Kyverno runs a privileged
# rule in Audit, then in Enforce, then a verifyImages rule against the signed
# Bookstore catalog image. Gatekeeper runs the same privileged rule in Rego,
# first as dryrun and then as deny. Each engine, its CRDs and its webhook
# configurations are removed before the next goes in, and the run ends by
# showing that none remain. The images come from ghcr.io and the signature
# checks reach the public Sigstore services, so the cluster needs internet
# access. Run it when no other heavy install shares the cluster.
#
# STEPS picks full-mode steps by name, in the order given. The default is all
# of them: F1 F2 F3 F4 F5 F6 F7 F8. A step leaves its objects in place for the
# next, so a long run can be split across several invocations. A run that
# fails, or that sees the control plane restart, removes what it installed.
#
# The steps this script no longer has were a throwaway cluster, a lab registry
# and a lab signing key (earlier steps 1 to 4, 7 to 12 and 15). The full mode
# never got past cluster creation on the lab host, and the Bookstore's own
# signed image tests the same rule against a real signature.
#
# A kind node is a container on the machine that runs kind, and it shares that
# machine's kernel. The attack Pods run in namespaces this script creates and
# only read the node's own /proc and the Pod's own service account directory.
# The privileged Pods in full mode never start: their node selector names a
# label no node carries. Nothing here writes outside the cluster, runs a kernel
# exploit, or pushes an image. The signature checks only read.
set +e

MODE=${MODE:-shared}
LAB_CONTEXT=${LAB_CONTEXT:-}
[ "$MODE" = shared ] && LAB_CONTEXT=${LAB_CONTEXT:-kind-sf-pilot}
here=$(cd "$(dirname "$0")/../../.." && pwd)     # full-guide/
POLICY="$here/examples/bookstore/policy"
BUSYBOX='busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662'  # busybox:1.36
# The tag-only Pod in step 6 names an image in a registry this lab does not
# run. The digest rule refuses the Pod before any pull.
REG_SVC=registry.p05-07-registry.svc.cluster.local:5000
KYVERNO_CHART=3.9.2
GATEKEEPER_CHART=3.23.1
# The identity 07.03 verifies: the reusable workflow, on the main branch.
SIGNER='https://github.com/abd-ulbasit/bookstore-kubernetes-guide/.github/workflows/bookstore-pipeline.yml@refs/heads/main'
ISSUER='https://token.actions.githubusercontent.com'
STEPS=${STEPS:-F1 F2 F3 F4 F5 F6 F7 F8}

# Print a command as it runs, then run it. Output follows the command line.
# redact keeps the transcript free of local paths. It runs on every line the
# lab prints.
redact() { sed -e "s|$here|guide|g" -e "s|$work|work|g" -e "s|$HOME|~|g"; }
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$(printf "%s\n" "$cmd" | redact)"; eval "$cmd" 2>&1 | redact; echo; }
show() { printf '$ %s\n' "$(printf "%s" "$*" | redact)"; eval "$*" 2>&1 | redact; echo; }

# A new namespace has no default ServiceAccount for a moment.
wait_sa() { for i in $(seq 1 60); do kubectl -n "$1" get serviceaccount default >/dev/null 2>&1 && return 0; sleep 1; done; }
fail() { echo "FAILED: $*"; exit 1; }
# Stop if the context is not the lab's. The cleanup then touches nothing.
ctx_check() { [ "$(kubectl config current-context 2>/dev/null)" = "$LAB_CONTEXT" ] || fail "the kubectl context is not the lab context"; }

# Kyverno and Gatekeeper are large installs: run this lab when no other heavy
# install is running on the same cluster.

work=$(mktemp -d) && cd "$work" || exit 2

# What the two engines leave behind, one object per line.
engine_left() {
  kubectl get --raw /readyz >/dev/null 2>&1 || echo "api-unreadable"
  kubectl get crd -o name 2>/dev/null | grep -E 'kyverno\.io|wgpolicyk8s\.io|gatekeeper\.sh'
  kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null | grep -iE 'kyverno|gatekeeper'
  kubectl get clusterrole,clusterrolebinding -o name 2>/dev/null | grep -iE 'kyverno|gatekeeper'
  kubectl get namespace -o name 2>/dev/null | grep -E 'namespace/(kyverno|gatekeeper-system|p05-07-)'
}

cleanup() {
  rc=$?
  echo '## cleanup'
  ctx_ok=no
  [ "$(kubectl config current-context 2>/dev/null)" = "$LAB_CONTEXT" ] && ctx_ok=yes
  if [ "$ctx_ok" = yes ] && [ "$MODE" = shared ]; then
    show "for ns in p05-07-open p05-07-kyverno; do kubectl -n \"\$ns\" delete pods --all --force --grace-period=0 --ignore-not-found 2>/dev/null; done"
    show "kubectl delete namespace p05-07-open p05-07-kyverno --ignore-not-found --wait=true --timeout=180s"
    show "kubectl delete validatingadmissionpolicybinding p05-07-no-external-ips p05-07-digest-pinned --ignore-not-found"
    show "kubectl delete validatingadmissionpolicy p05-07-no-external-ips p05-07-digest-pinned --ignore-not-found"
    show "kubectl delete mutatingadmissionpolicybinding p05-07-default-automount-off p05-07-default-seccomp --ignore-not-found"
    show "kubectl delete mutatingadmissionpolicy p05-07-default-automount-off p05-07-default-seccomp --ignore-not-found"
  fi
  if [ "$ctx_ok" = yes ] && [ "$MODE" = full ] && [ "$rc" -ne 0 ]; then
    # A failed or stopped run removes everything it may have installed. The
    # order matters: policies first, then the charts, then the webhook
    # configurations a chart leaves behind, then the CRDs and the namespaces.
    # A busy API server can refuse a delete, so the pass repeats until
    # nothing is left, three times at most.
    echo "run failed or stopped (exit $rc): removing both engines"
    for pass in 1 2 3; do
      kubectl delete clusterpolicy p05-07-disallow-privileged p05-07-verify-signed-images --ignore-not-found >/dev/null 2>&1
      kubectl delete p05noprivileged p05-no-privileged --ignore-not-found >/dev/null 2>&1
      kubectl delete constrainttemplate p05noprivileged --ignore-not-found >/dev/null 2>&1
      helm uninstall kyverno --namespace kyverno --wait --timeout 3m >/dev/null 2>&1
      helm uninstall gatekeeper --namespace gatekeeper-system --wait --timeout 3m >/dev/null 2>&1
      # The controllers go before their webhook configurations, or they
      # write the configurations back.
      kubectl delete namespace kyverno gatekeeper-system --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1
      kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null | grep -iE 'kyverno|gatekeeper' | xargs kubectl delete --ignore-not-found >/dev/null 2>&1
      kubectl get crd -o name 2>/dev/null | grep -E 'kyverno\.io|wgpolicyk8s\.io|gatekeeper\.sh' | xargs kubectl delete --wait=true --timeout=120s >/dev/null 2>&1
      kubectl get clusterrole,clusterrolebinding -o name 2>/dev/null | grep -iE 'kyverno|gatekeeper' | xargs kubectl delete --ignore-not-found >/dev/null 2>&1
      kubectl delete namespace kyverno gatekeeper-system p05-07-kyverno p05-07-signed --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1
      left=$(engine_left)
      [ -z "$left" ] && break
      sleep 15
    done
    if [ -n "$left" ]; then echo "STILL PRESENT, remove by hand:"; echo "$left"; else echo "nothing of either engine remains"; fi
  fi
  cd / && rm -rf "$work"
}
trap cleanup EXIT

if [ "$MODE" = full ]; then
  echo "## mode: full, on the kind cluster LAB_CONTEXT names; Kyverno and Gatekeeper are installed in turn"
else
  echo "## mode: shared, on the lab cluster; no engine is installed in this mode"
fi
case "$LAB_CONTEXT" in
  kind-*) ;;
  *) echo "refusing: set LAB_CONTEXT to the kind-* context of a cluster you own" >&2; exit 2 ;;
esac
if [ "$(kubectl config current-context 2>/dev/null)" != "$LAB_CONTEXT" ]; then
  echo "refusing: the kubectl context is not the one LAB_CONTEXT names" >&2
  exit 2
fi
echo '## step 0: the tools this run used'
run <<'CMD'
kubectl version
helm version --short
cosign version | grep GitVersion
opa version | head -1
conftest --version | head -1
terraform version | head -1
CMD


if [ "$MODE" = shared ]; then
echo '## step 5: the attack, in a namespace with no policy'
show "kubectl create namespace p05-07-open"
wait_sa p05-07-open
show "kubectl -n p05-07-open get serviceaccount default -o name"
cat > attack-service.yaml <<'YAML'
# INSECURE ON PURPOSE: a Service that asks for an external IP. Lab cluster only.
apiVersion: v1
kind: Service
metadata:
  name: catalog-ext
  namespace: p05-07-open
spec:
  selector:
    app: catalog
  ports:
    - port: 8080
      targetPort: 8080
  externalIPs:
    - 203.0.113.10
YAML
show "kubectl apply -f attack-service.yaml"
cat > attack-forgetful.yaml <<YAML
# INSECURE ON PURPOSE: a Pod that leaves out the baseline. Lab cluster only.
# The default ServiceAccount token is mounted and seccomp is unset.
apiVersion: v1
kind: Pod
metadata:
  name: forgetful
  namespace: p05-07-open
spec:
  containers:
    - name: app
      image: $BUSYBOX
      command: ["sleep", "3600"]
YAML
show "kubectl apply -f attack-forgetful.yaml"
show "kubectl -n p05-07-open wait --for=condition=Ready pod/forgetful --timeout=120s"
show "kubectl -n p05-07-open exec forgetful -- sh -c 'grep Seccomp: /proc/self/status | tr \"\\t\" \" \"; ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>/dev/null | tr \"\\n\" \" \"; echo'"
show "kubectl -n p05-07-open get pod forgetful -o jsonpath='{.spec.volumes[*].name}{\"\\n\"}'"

echo '## step 6: the same namespace, with the policies in place and the namespace labelled'
cat > vap-no-external-ips.yaml <<'YAML'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: p05-07-no-external-ips
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["services"]
  validations:
    - expression: "!has(object.spec.externalIPs) || size(object.spec.externalIPs) == 0"
      message: "a Service may not set spec.externalIPs"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: p05-07-no-external-ips
spec:
  policyName: p05-07-no-external-ips
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        p05-07-lab: "true"
YAML
cat > vap-digest-pinned.yaml <<'YAML'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: p05-07-digest-pinned
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  variables:
    - name: images
      expression: "object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : [])"
  validations:
    - expression: "variables.images.all(c, c.image.contains('@sha256:') || c.image.startsWith('registry.example.com/bookstore/'))"
      message: "BK-POL-009: every third-party image must be pinned by digest"
      reason: Forbidden
    - expression: "variables.images.all(c, !c.image.endsWith(':latest'))"
      message: "BK-POL-009: no image may use the latest tag"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: p05-07-digest-pinned
spec:
  policyName: p05-07-digest-pinned
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        p05-07-lab: "true"
YAML
cat > map-automount-off.yaml <<'YAML'
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: p05-07-default-automount-off
spec:
  failurePolicy: Fail
  reinvocationPolicy: IfNeeded
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  matchConditions:
    - name: automount-unset
      expression: "!has(object.spec.automountServiceAccountToken)"
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >-
          Object{
            spec: Object.spec{
              automountServiceAccountToken: false
            }
          }
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: p05-07-default-automount-off
spec:
  policyName: p05-07-default-automount-off
  matchResources:
    namespaceSelector:
      matchLabels:
        p05-07-lab: "true"
YAML
cat > map-seccomp.yaml <<'YAML'
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: p05-07-default-seccomp
spec:
  failurePolicy: Fail
  reinvocationPolicy: IfNeeded
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  matchConditions:
    - name: seccomp-unset
      expression: "!has(object.spec.securityContext) || !has(object.spec.securityContext.seccompProfile)"
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >-
          Object{
            spec: Object.spec{
              securityContext: Object.spec.securityContext{
                seccompProfile: Object.spec.securityContext.seccompProfile{
                  type: "RuntimeDefault"
                }
              }
            }
          }
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: p05-07-default-seccomp
spec:
  policyName: p05-07-default-seccomp
  matchResources:
    namespaceSelector:
      matchLabels:
        p05-07-lab: "true"
YAML
show "kubectl apply -f vap-no-external-ips.yaml -f vap-digest-pinned.yaml -f map-automount-off.yaml -f map-seccomp.yaml"
show "sleep 5"
show "kubectl label namespace p05-07-open p05-07-lab=true"
show "sleep 5"
# A new name: re-applying the first Service would change nothing, and the
# server skips admission for an unchanged object.
sed 's/catalog-ext$/catalog-ext-2/' attack-service.yaml > attack-service-2.yaml
show "kubectl apply -f attack-service-2.yaml"
cat > tag-only.yaml <<YAML
# The tag is the point: the digest rule in the lab policy refuses this Pod.
apiVersion: v1
kind: Pod
metadata:
  name: tag-only
  namespace: p05-07-open
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $REG_SVC/bookstore/catalog:lab
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 50m, memory: 32Mi}
        limits: {memory: 64Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
YAML
show "kubectl apply -f tag-only.yaml"
cat > forgetful-2.yaml <<YAML
# INSECURE ON PURPOSE: a Pod that leaves out the baseline. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: forgetful-2
  namespace: p05-07-open
spec:
  containers:
    - name: app
      image: $BUSYBOX
      command: ["sleep", "3600"]
YAML
show "kubectl apply -f forgetful-2.yaml"
show "kubectl -n p05-07-open wait --for=condition=Ready pod/forgetful-2 --timeout=120s"
show "kubectl -n p05-07-open get pod forgetful-2 -o jsonpath='{.spec.automountServiceAccountToken}{\" \"}{.spec.securityContext.seccompProfile.type}{\"\\n\"}'"
show "kubectl -n p05-07-open exec forgetful-2 -- sh -c 'grep Seccomp: /proc/self/status | tr \"\\t\" \" \"; ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>/dev/null | tr \"\\n\" \" \"; echo'"

show "kubectl -n p05-07-open get pod forgetful-2 -o jsonpath='{.spec.volumes[*].name}{\"\\n\"}'"
cat > baseline.yaml <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: baseline
  namespace: p05-07-open
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
      image: $BUSYBOX
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 32Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
YAML
show "kubectl apply -f baseline.yaml"
show "kubectl -n p05-07-open wait --for=condition=Ready pod/baseline --timeout=120s"
show "kubectl -n p05-07-open exec baseline -- sh -c 'ls /var/run/secrets/kubernetes.io/serviceaccount 2>&1; echo'"

if [ "$MODE" = shared ]; then
echo '## step 12b: the built-in validation refuses privileged with allowPrivilegeEscalation false, before any policy [shared mode]'
show "kubectl create namespace p05-07-kyverno"
wait_sa p05-07-kyverno
cat > escape-conflict.yaml <<YAML
# INSECURE ON PURPOSE: a privileged container. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-node
  namespace: p05-07-kyverno
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $BUSYBOX
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
YAML
show "kubectl apply --dry-run=server -f escape-conflict.yaml; echo \"server dry-run exit=\$?\""
sed '/allowPrivilegeEscalation: false/d' escape-conflict.yaml > escape-node-dryrun.yaml
show "kubectl apply --dry-run=server -f escape-node-dryrun.yaml; echo \"server dry-run exit=\$?\""
show "kubectl delete namespace p05-07-kyverno --wait=true --ignore-not-found"

fi

echo '## step 13: the same policy as unit tests and as checks on manifests and a Terraform plan (no cluster)'
show "opa test $POLICY -v | tail -n 1"
show "kubectl kustomize $here/examples/bookstore/kustomize/overlays/prod > prod-overlay.yaml"
show "conftest test --no-color --policy $POLICY --all-namespaces prod-overlay.yaml"
show "conftest test --no-color --policy $POLICY --all-namespaces $POLICY/terraform/plan.json"
jq '(.resource_changes[0].change.after.metadata[0].labels["pod-security.kubernetes.io/enforce"]) = "privileged"' \
  "$POLICY/terraform/plan.json" > planted-plan.json
show "conftest test --no-color --policy $POLICY --all-namespaces planted-plan.json; echo \"planted plan exit=\$?\""

echo '## step 14: the Kyverno admission path, read back from the cluster'
show "kubectl get validatingadmissionpolicy,mutatingadmissionpolicy -o name | grep p05-07 | sort"

if [ "$MODE" = shared ]; then
echo '## step 16: the Kyverno and Gatekeeper installs, rendered and checked without a cluster [shared mode]'
show "helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update"
show "helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts --force-update"
show "helm template kyverno kyverno/kyverno --version $KYVERNO_CHART --namespace kyverno --set features.registryClient.allowInsecure=true --set admissionController.replicas=1 --set backgroundController.replicas=1 --set cleanupController.replicas=1 --set reportsController.replicas=1 > kyverno-rendered.yaml"
show "grep -c '^kind: ' kyverno-rendered.yaml"
show "grep -c 'deprecationWarning: kyverno.io/v1 ClusterPolicy is deprecated' kyverno-rendered.yaml"
show "grep -h 'image: ' kyverno-rendered.yaml | sed 's/^ *//' | sort -u | head -4"
show "helm template gatekeeper gatekeeper/gatekeeper --version $GATEKEEPER_CHART --namespace gatekeeper-system --set replicas=1 > gatekeeper-rendered.yaml"
show "grep -c '^kind: ' gatekeeper-rendered.yaml"
cat > policy-disallow-privileged.yaml <<'YAML'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: p05-07-disallow-privileged
spec:
  background: true
  rules:
    - name: no-privileged-containers
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [p05-07-kyverno]
      validate:
        failureAction: Audit
        message: "BK-POL-001: privileged containers are not allowed"
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): false
YAML
show "kubectl apply --dry-run=client -f policy-disallow-privileged.yaml"
show "kubectl apply --dry-run=server -f policy-disallow-privileged.yaml; echo \"server dry-run exit=\$?\""
cat > gatekeeper-constraint.yaml <<'YAML'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: P05NoPrivileged
metadata:
  name: p05-no-privileged
spec:
  enforcementAction: dryrun
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces: ["p05-07-kyverno"]
YAML
show "kubectl apply --dry-run=server -f gatekeeper-constraint.yaml; echo \"server dry-run exit=\$?\""
fi

fi

if [ "$MODE" = full ]; then

# The catalog digest is the one the production overlay pins, read from the
# rendered overlay so that the lab cannot drift from it.
CATALOG=$(kubectl kustomize "$here/examples/bookstore/kustomize/overlays/prod" 2>/dev/null | grep -o 'ghcr.io/abd-ulbasit/bookstore-catalog@sha256:[0-9a-f]*' | sort -u)
[ -n "$CATALOG" ] || { echo "refusing: no catalog digest in the prod overlay" >&2; exit 2; }
case "${STEPS%% *}" in
  F1) left=$(engine_left)
      [ -z "$left" ] || { echo "refusing: an earlier install of either engine is still on this cluster:" >&2; echo "$left" >&2; exit 2; } ;;
esac

# The control plane's restart count, summed. The run stops if it goes up.
cp_restarts() { local o; o=$(kubectl -n kube-system get pods -l tier=control-plane -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null) && [ -n "$o" ] || { echo -1; return; }; echo "$o" | tr ' ' '\n' | awk '{s+=$1} END{print s+0}'; }
CP0=$(cp_restarts)
guard() {
  n=$(cp_restarts)
  if [ "$n" -lt 0 ]; then echo "STOP: the API server did not answer"; exit 3; fi
  if [ "$n" -gt "$CP0" ]; then echo "STOP: the control plane restarted ($CP0 to $n)"; exit 3; fi
  echo "control plane restarts: $n (at the start of this run: $CP0)"
  echo
}
# helm --wait cannot stop for a control plane that restarts, so the installs
# here do not use it. This waits instead, checking the control plane every ten
# seconds: it returns when every Deployment in the namespace is available,
# stops the run when the control plane restarts, and gives up after $2 tries.
wait_deploys() {
  local ns=$1 tries=$2 i n all not
  for i in $(seq 1 "$tries"); do
    n=$(cp_restarts)
    if [ "$n" -gt "$CP0" ]; then echo "STOP: the control plane restarted ($CP0 to $n)"; exit 3; fi
    all=$(kubectl -n "$ns" get deploy -o name 2>/dev/null)
    not=$(kubectl -n "$ns" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.availableReplicas}{"/"}{.spec.replicas}{"\n"}{end}' 2>/dev/null | awk '{split($2,a,"/"); if (a[1]!=a[2]) print $1}')
    if [ -n "$all" ] && [ -z "$not" ]; then echo "every Deployment in $ns is available"; echo; return 0; fi
    sleep 10
  done
  echo "not available in time: $not"
  show "kubectl -n $ns get pods"
  for p in $(kubectl -n "$ns" get pods -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==false)]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    show "kubectl -n $ns logs $p --tail=12"
    show "kubectl -n $ns get events --field-selector involvedObject.name=$p"
  done
  return 1
}

# Every Pod here is admitted and then left Pending: the node selector names a
# label no node carries, so the lab tests admission and pulls no image.
cat > escape-node.yaml <<YAML
# INSECURE ON PURPOSE: a privileged container, which the Kyverno rule refuses. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-node
  namespace: p05-07-kyverno
spec:
  nodeSelector:
    lab-never-scheduled: "true"
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $CATALOG
      securityContext:
        privileged: true
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 50m, memory: 32Mi}
        limits: {memory: 64Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
YAML
sed 's/name: escape-node$/name: escape-node-2/' escape-node.yaml > escape-node-2.yaml
# The same Pod without the one field that is the attack, and with the field
# the baseline wants in its place.
sed -e 's/name: escape-node$/name: compliant/' -e '/^# INSECURE ON PURPOSE/d' -e 's/privileged: true/allowPrivilegeEscalation: false/' escape-node.yaml > compliant.yaml
sed 's/name: compliant$/name: compliant-2/' compliant.yaml > compliant-2.yaml
cat > policy-disallow-privileged.yaml <<'YAML'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: p05-07-disallow-privileged
  annotations:
    policies.kyverno.io/title: Disallow privileged containers
    policies.kyverno.io/description: The Bookstore rule BK-POL-001, enforced at admission.
spec:
  background: true
  rules:
    - name: no-privileged-containers
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [p05-07-kyverno]
      validate:
        failureAction: Audit
        message: "BK-POL-001: privileged containers are not allowed"
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): false
YAML
cat > catalog-signed.yaml <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: catalog
  namespace: p05-07-signed
spec:
  nodeSelector:
    lab-never-scheduled: "true"
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $CATALOG
      ports:
        - containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 50m, memory: 32Mi}
        limits: {memory: 64Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
YAML
cat > policy-verify-signed.yaml <<YAML
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: p05-07-verify-signed-images
  annotations:
    policies.kyverno.io/title: Verify image signatures
    policies.kyverno.io/description: Pods in p05-07-signed run only images that the Bookstore pipeline signed.
spec:
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: signed-by-the-pipeline
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [p05-07-signed]
      verifyImages:
        - imageReferences:
            - "*"
          type: SigstoreBundle
          verifyDigest: true
          required: true
          failureAction: Enforce
          attestors:
            - entries:
                - keyless:
                    issuer: "$ISSUER"
                    subject: "$SIGNER"
                    rekor:
                      url: https://rekor.sigstore.dev
YAML
cat > gatekeeper-template.yaml <<'YAML'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: p05noprivileged
spec:
  crd:
    spec:
      names:
        kind: P05NoPrivileged
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package p05nopriv

        violation[{"msg": msg}] {
          c := input_containers[_]
          c.securityContext.privileged == true
          msg := sprintf("BK-POL-001 container %v runs privileged", [c.name])
        }

        input_containers[c] {
          c := input.review.object.spec.containers[_]
        }

        input_containers[c] {
          c := input.review.object.spec.initContainers[_]
        }
YAML
cat > gatekeeper-constraint.yaml <<'YAML'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: P05NoPrivileged
metadata:
  name: p05-no-privileged
spec:
  enforcementAction: dryrun
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces: ["p05-07-kyverno"]
YAML

# Remove one engine: release, namespace, webhook configurations, CRDs and
# cluster roles, in that order. The order matters. The chart's pre-delete hook
# can outlast helm's wait on a busy cluster, so a failed uninstall does not
# stop the removal. The namespace goes next, because a running controller
# writes its webhook configurations back as fast as they are deleted, and a
# configuration left pointing at a Service that no longer exists makes every
# request it matches fail. Arguments: release, namespace, a CRD pattern, and a
# pattern for the webhook and role names.
teardown() {
  show "helm uninstall $1 --namespace $2 --wait --timeout 4m $5"
  show "kubectl delete namespace $2 --wait=true"
  show "kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -iE '$4' | xargs kubectl delete --ignore-not-found"
  show "kubectl get crd -o name | grep -E '$3' | xargs kubectl delete --wait=true"
  show "kubectl get clusterrole,clusterrolebinding -o name | grep -iE '$4' | xargs kubectl delete --ignore-not-found"
}

step_F1() {
echo '## step F1: Kyverno, installed with the chart pinned and the namespace labelled'
ctx_check
show "helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update"
show "helm show chart kyverno/kyverno --version $KYVERNO_CHART | grep -E '^(name|version|appVersion|kubeVersion):'"
show "kubectl create namespace kyverno"
show "kubectl label namespace kyverno pod-security.kubernetes.io/enforce=restricted"
ctx_check
# Values that differ from the chart's defaults, all to keep the install small
# enough for a lab host. One admission controller and one reports controller.
# No background controller (it serves generate and mutate-existing rules) and
# no cleanup controller (TTL cleanup), which this lab does not use. No
# generated ValidatingAdmissionPolicies and no reports for them, which the
# chart switches on and which add watches on the API server. ndots 1 on the
# admission controller: verifyImages looks up ghcr.io, the Sigstore services
# and each image's registry, and the Pod default of five search suffixes turns
# every such lookup into several queries. Lookups had timed out before the
# option was added, and one registry still timed out after it, so it is a
# precaution and not a fix.
show "helm upgrade --install kyverno kyverno/kyverno --version $KYVERNO_CHART --namespace kyverno --set admissionController.replicas=1 --set reportsController.replicas=1 --set backgroundController.enabled=false --set cleanupController.enabled=false --set features.generateValidatingAdmissionPolicy.enabled=false --set features.validatingAdmissionPolicyReports.enabled=false --set-string 'admissionController.dnsConfig.options[0].name=ndots' --set-string 'admissionController.dnsConfig.options[0].value=1'"
wait_deploys kyverno 45 || fail "the Kyverno Deployments were not available in time"
[ "$(helm status kyverno --namespace kyverno -o json 2>/dev/null | jq -r .info.status)" = deployed ] || fail "the Kyverno install did not finish"
show "kubectl -n kyverno get deploy"
show "kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep kyverno | sort"
guard
}

step_F2() {
echo '## step F2: Audit before Enforce: a privileged Pod is admitted and reported'
ctx_check
show "kubectl create namespace p05-07-kyverno"
wait_sa p05-07-kyverno
show "kubectl -n p05-07-kyverno get serviceaccount default -o name"
show "kubectl apply -f policy-disallow-privileged.yaml"
show "kubectl wait --for=condition=Ready clusterpolicy/p05-07-disallow-privileged --timeout=120s"
show "kubectl apply -f escape-node.yaml"
show "kubectl -n p05-07-kyverno get pod escape-node -o jsonpath='{.metadata.name} admitted, privileged={.spec.containers[0].securityContext.privileged}{\"\\n\"}'"
# The admission controller writes an EphemeralReport at once. The reports
# controller aggregates it into a PolicyReport, which can take a while on a
# busy cluster, so the wait is bounded and the lab reads both.
for i in $(seq 1 18); do kubectl -n p05-07-kyverno get policyreports -o jsonpath='{.items[*].results[*].result}' 2>/dev/null | grep -q fail && break; sleep 5; done
show "kubectl -n p05-07-kyverno get ephemeralreports,policyreports"
show "kubectl -n p05-07-kyverno get ephemeralreports -o jsonpath='{range .items[*].spec.results[*]}{.policy}{\" \"}{.rule}{\" \"}{.result}{\" \"}{.message}{\"\\n\"}{end}'"
guard
}

step_F3() {
echo '## step F3: Enforce: the same rule refuses the next privileged Pod'
ctx_check
show "kubectl patch clusterpolicy p05-07-disallow-privileged --type json -p '[{\"op\":\"replace\",\"path\":\"/spec/rules/0/validate/failureAction\",\"value\":\"Enforce\"}]'"
# Wait for the webhook to carry the new action. A server dry run is refused
# the same way as the real request and stores nothing.
for i in $(seq 1 30); do kubectl apply --dry-run=server -f escape-node-2.yaml 2>&1 | grep -q 'blocked' && break; sleep 2; done
show "kubectl apply -f escape-node-2.yaml; echo \"apply exit=\$?\""
show "kubectl apply -f compliant.yaml"
show "kubectl -n p05-07-kyverno get pods -o name"
guard
}

step_F4() {
echo '## step F4: verifyImages: the signature and the workflow identity are checked, not only the digest'
ctx_check
show "kubectl kustomize $here/examples/bookstore/kustomize/overlays/prod | grep -o 'ghcr.io/abd-ulbasit/bookstore-catalog@sha256:[0-9a-f]*' | sort -u"
show "DOCKER_CONFIG=\$(mktemp -d) cosign verify --certificate-identity '$SIGNER' --certificate-oidc-issuer $ISSUER $CATALOG >/dev/null 2>verify.err; echo \"cosign verify exit=\$?\"; grep -E '^(Verification for|  - )' verify.err"
show "kubectl create namespace p05-07-signed"
wait_sa p05-07-signed
show "kubectl -n p05-07-signed get serviceaccount default -o name"
show "kubectl apply -f policy-verify-signed.yaml"
show "kubectl wait --for=condition=Ready clusterpolicy/p05-07-verify-signed-images --timeout=120s"
show "kubectl apply -f catalog-signed.yaml"
show "kubectl -n p05-07-signed get pod catalog -o jsonpath='{.metadata.annotations.kyverno\\.io/verify-images}{\"\\n\"}'"
# An image the pipeline did not sign. It is one of Kyverno's own images, read
# from the running admission controller so that the digest is the one the
# cluster pulled. It is on a registry the cluster can reach, and cosign finds no
# signature on it under any identity.
show "kubectl -n kyverno get pod -l app.kubernetes.io/component=admission-controller -o jsonpath='{.items[0].status.initContainerStatuses[0].imageID}{\"\\n\"}'"
UNSIGNED=$(kubectl -n kyverno get pod -l app.kubernetes.io/component=admission-controller -o jsonpath='{.items[0].status.initContainerStatuses[0].imageID}' 2>/dev/null)
[ -n "$UNSIGNED" ] || fail "no image digest to use as the unsigned image"
show "DOCKER_CONFIG=\$(mktemp -d) cosign verify --certificate-identity-regexp '.*' --certificate-oidc-issuer-regexp '.*' $UNSIGNED >/dev/null 2>verify-unsigned.err; echo \"cosign verify exit=\$?\"; head -n 1 verify-unsigned.err"
sed -e "s|image: .*|image: $UNSIGNED|" -e 's/name: catalog$/name: unsigned/' -e '/ports:/,/containerPort/d' catalog-signed.yaml > unsigned.yaml
show "kubectl apply -f unsigned.yaml; echo \"apply exit=\$?\""
show "kubectl -n p05-07-signed get pods -o name"
guard
}

step_F5() {
echo '## step F5: remove Kyverno, its CRDs and its webhook configurations'
ctx_check
show "kubectl delete clusterpolicy p05-07-disallow-privileged p05-07-verify-signed-images --ignore-not-found"
show "kubectl delete namespace p05-07-signed --ignore-not-found --wait=true"
# --no-hooks: the chart's pre-delete Job scales Kyverno to zero and clears its
# webhooks, which deleting the namespace does as well. On this cluster the Job
# outlasted helm's wait once and failed on etcd timeouts once. This form of F5
# has not run to the end; the header of evidence/05-07.txt says what ran.
teardown kyverno kyverno 'kyverno\.io|wgpolicyk8s\.io' kyverno --no-hooks
echo '## nothing of Kyverno remains'
show "kubectl get crd -o name | grep -cE 'kyverno\\.io|wgpolicyk8s\\.io'"
show "kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ci kyverno"
show "kubectl get clusterrole,clusterrolebinding -o name | grep -ci kyverno"
show "kubectl get namespace -o name | grep -c 'namespace/kyverno\$'"
left=$(engine_left | grep -v 'namespace/p05-07-'); [ -z "$left" ] || fail "left behind: $left"
guard
}

step_F6() {
echo '## step F6: Gatekeeper, installed with the chart pinned and the namespace labelled'
ctx_check
[ -z "$(engine_left | grep -v 'namespace/p05-07-' | grep -iE 'kyverno|wgpolicyk8s')" ] || fail "Kyverno is still on this cluster; run F5 first"
kubectl -n p05-07-kyverno get pod escape-node >/dev/null 2>&1 || fail "the Pod Kyverno admitted in Audit is gone; run F2 first"
show "kubectl -n p05-07-kyverno get pod escape-node -o name"
show "helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts --force-update"
show "helm show chart gatekeeper/gatekeeper --version $GATEKEEPER_CHART | grep -E '^(name|version|appVersion|kubeVersion):'"
show "kubectl create namespace gatekeeper-system"
show "kubectl label namespace gatekeeper-system pod-security.kubernetes.io/enforce=restricted"
ctx_check
show "helm upgrade --install gatekeeper gatekeeper/gatekeeper --version $GATEKEEPER_CHART --namespace gatekeeper-system --set replicas=1"
wait_deploys gatekeeper-system 45 || fail "the Gatekeeper Deployments were not available in time"
[ "$(helm status gatekeeper --namespace gatekeeper-system -o json 2>/dev/null | jq -r .info.status)" = deployed ] || fail "the Gatekeeper install did not finish"
show "kubectl -n gatekeeper-system get deploy"
show "kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep gatekeeper | sort"
guard
}

step_F7() {
echo '## step F7: the same rule in Rego: dryrun reports the Pod, deny refuses the next one'
ctx_check
show "kubectl apply -f gatekeeper-template.yaml"
show "kubectl wait --for=condition=Established crd/p05noprivileged.constraints.gatekeeper.sh --timeout=120s"
show "kubectl apply -f gatekeeper-constraint.yaml"
echo "## waiting for the Gatekeeper audit to list the Pod that Kyverno admitted in Audit"
for i in $(seq 1 30); do
  n=$(kubectl get p05noprivileged p05-no-privileged -o jsonpath='{.status.totalViolations}' 2>/dev/null)
  [ "${n:-0}" -gt 0 ] && break
  sleep 10
done
show "kubectl get p05noprivileged p05-no-privileged -o jsonpath='{.spec.enforcementAction}{\" \"}{.status.totalViolations}{\"\\n\"}'"
show "kubectl get p05noprivileged p05-no-privileged -o jsonpath='{.status.violations[0].message}{\"\\n\"}'"
show "kubectl apply -f escape-node-2.yaml"
show "kubectl delete pod escape-node-2 -n p05-07-kyverno --wait=true"
show "kubectl patch p05noprivileged p05-no-privileged --type merge -p '{\"spec\":{\"enforcementAction\":\"deny\"}}'"
for i in $(seq 1 30); do kubectl apply --dry-run=server -f escape-node-2.yaml 2>&1 | grep -q 'denied the request' && break; sleep 2; done
show "kubectl apply -f escape-node-2.yaml; echo \"apply exit=\$?\""
show "kubectl apply -f compliant-2.yaml"
show "kubectl -n p05-07-kyverno get pods -o name"
guard
}

step_F8() {
echo '## step F8: remove Gatekeeper, its CRDs and its webhook configurations, then the lab namespaces'
ctx_check
show "kubectl delete p05noprivileged p05-no-privileged"
show "kubectl delete constrainttemplate p05noprivileged"
teardown gatekeeper gatekeeper-system 'gatekeeper\.sh' gatekeeper
show "kubectl delete namespace p05-07-kyverno --wait=true"
echo '## nothing of either engine remains'
show "kubectl get crd -o name | grep -cE 'kyverno\\.io|wgpolicyk8s\\.io|gatekeeper\\.sh'"
show "kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ciE 'kyverno|gatekeeper'"
show "kubectl get clusterrole,clusterrolebinding -o name | grep -ciE 'kyverno|gatekeeper'"
show "kubectl get namespace -o name | grep -cE 'namespace/(kyverno|gatekeeper-system|p05-07-)'"
left=$(engine_left); [ -z "$left" ] || fail "left behind: $left"
guard
}

for s in $STEPS; do
  case "$s" in
    F1|F2|F3|F4|F5|F6|F7|F8) "step_$s" ;;
    *) echo "refusing: unknown step $s" >&2; exit 2 ;;
  esac
done

fi
