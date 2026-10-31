#!/usr/bin/env bash
# Lab 05.07: Admission control and policy as code. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from any directory. It creates a
# throwaway kind cluster named p05-07 and a lab registry on the kind network. It
# attacks an open namespace, adds ValidatingAdmissionPolicy and
# MutatingAdmissionPolicy, attacks again, then installs Kyverno (Audit, then
# Enforce, then verifyImages against a cosign key) and Gatekeeper (the same rule
# in Rego, in dry-run, then removed). It runs the policy unit tests and the
# Conftest checks on the Bookstore's manifests and Terraform plan, then deletes
# everything it created.
#
# MODE selects the steps. MODE=full (the default) runs every step on the
# throwaway cluster p05-07. MODE=shared runs the attack, the policies and the
# checks on the shared kind-sf-pilot cluster, and renders the Kyverno and
# Gatekeeper charts without installing them. The steps that need the throwaway
# cluster or a heavy install are marked [full mode] in their headings.
#
# KIND is the kind command (default: kind). LAB_HOST, when set, is an ssh alias
# for the machine that runs kind and Docker: the script copies the kind config
# there, opens tunnels to its API server and registry ports, and runs kind and
# docker there. Then KIND names the command as the remote shell sees it, for
# example ~/.local/bin/kind-v0.33.0.
#
# A kind node is a container on the machine that runs kind, and it shares that
# machine's kernel. The attack Pods run in namespaces this script creates and
# only read the node's own /proc and the Pod's own service account directory.
# Nothing here writes outside the cluster, reaches a cloud, or runs a kernel
# exploit. The lab key is a throwaway key made in this run's work directory;
# nothing from it is committed.
set +e

CLUSTER=p05-07
PORT=36013
REG_PORT=5007
KIND=${KIND:-kind}
LAB_HOST=${LAB_HOST:-}
here=$(cd "$(dirname "$0")/../../.." && pwd)     # full-guide/
POLICY="$here/examples/bookstore/policy"
REG_NAME=p05-07-registry
REG_SVC=registry.p05-07-registry.svc.cluster.local:5000   # the name Pods use
REG_IMAGE='registry:3@sha256:d4032d4cc323c1731c707931ecada07a53076eac38e3b61ae57533f170f2c6c3'  # registry:3, as 05.03 pins it
BUSYBOX='busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662'  # busybox:1.36
CURL_IMAGE='curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777'  # curlimages/curl:8.22.0
KYVERNO_CHART=3.9.2
# MODE=full (the default) runs every step on the throwaway cluster p05-07.
# MODE=shared runs only the steps that need no throwaway cluster, on the
# shared kind-sf-pilot cluster: the attack, the policies, and the checks.
MODE=${MODE:-full}
GATEKEEPER_CHART=3.23.1

# Print a command as it runs, then run it. Output follows the command line.
# redact keeps the transcript free of local paths and of the Docker bridge
# address the lab registry gets. It runs on every line the lab prints.
redact() { sed -e "s|$here|guide|g" -e "s|$work|work|g" -e "s|$HOME|~|g" -e "s|172\.18\.[0-9]*\.[0-9]*|<kind-address>|g"; }
# Print a command as it runs, then run it. Output follows the command line.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$(printf "%s\n" "$cmd" | redact)"; eval "$cmd" 2>&1 | redact; echo; }
show() { printf '$ %s\n' "$(printf "%s" "$*" | redact)"; eval "$*" 2>&1 | redact; echo; }

# kind and docker, on the machine that runs them.
wait_sa() { for i in $(seq 1 60); do kubectl -n "$1" get serviceaccount default >/dev/null 2>&1 && return 0; sleep 1; done; }
kind() { if [ -n "$LAB_HOST" ]; then ssh "$LAB_HOST" "$KIND" "$@"; else "$KIND" "$@"; fi; }


# runs under heavy_lock because Kyverno and Gatekeeper are large installs; the

work=$(mktemp -d) && cd "$work" || exit 2

cleanup() {
  echo '## cleanup: the lab objects, the cluster, the registry and the tunnels'
  # Only the lab's own context: a shell whose kubeconfig names another cluster
  # must not get these deletes. MODE=shared works on kind-sf-pilot.
  want=kind-$CLUSTER
  [ "$MODE" = shared ] && want=kind-sf-pilot
  if [ "$(kubectl config current-context 2>/dev/null)" = "$want" ]; then
    show "for ns in p05-07-open p05-07-signed p05-07-kyverno; do kubectl -n \"\$ns\" delete pods --all --force --grace-period=0 --ignore-not-found 2>/dev/null; done"
show "kubectl delete namespace p05-07-open p05-07-kyverno p05-07-signed p05-07-registry p05-07-gatekeeper --ignore-not-found --wait=true --timeout=180s"
    show "kubectl delete validatingadmissionpolicybinding p05-07-no-external-ips p05-07-digest-pinned --ignore-not-found"
    show "kubectl delete validatingadmissionpolicy p05-07-no-external-ips p05-07-digest-pinned --ignore-not-found"
    show "kubectl delete mutatingadmissionpolicybinding p05-07-default-automount-off p05-07-default-seccomp --ignore-not-found"
    show "kubectl delete mutatingadmissionpolicy p05-07-default-automount-off p05-07-default-seccomp --ignore-not-found"
  fi
  if [ -n "$LAB_HOST" ]; then
    ssh -S "$work/ctl" -O exit "$LAB_HOST" >/dev/null 2>&1
    ssh "$LAB_HOST" 'rm -f p05-07-kind.yaml'
  fi
  [ "$MODE" = full ] && show "kind delete cluster --name $CLUSTER"
  [ "$MODE" = full ] && show "docker rm -f $REG_NAME"
  cd / && rm -rf "$work"
}
trap cleanup EXIT

if [ "$MODE" = full ]; then echo "## mode: full, on the throwaway cluster $CLUSTER"; else echo "## mode: shared, on the shared lab cluster; the throwaway p05-07 cluster is not created in this mode"; fi
if [ "$MODE" = shared ]; then
  [ "$(kubectl config current-context 2>/dev/null)" = kind-sf-pilot ] || {
    echo "refusing: MODE=shared needs the kubectl context kind-sf-pilot" >&2
    exit 2
  }
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

echo "## step 1: a throwaway cluster, two tunnels, and the Kubernetes version [full mode]"
if [ "$MODE" = full ]; then
show "kind version"
if [ -n "$LAB_HOST" ]; then
  ssh "$LAB_HOST" 'cat > p05-07-kind.yaml' < "$here/examples/security-lab/kind/admission.yaml" || exit 2
else
  cp "$here/examples/security-lab/kind/admission.yaml" p05-07-kind.yaml
fi
show "kind create cluster --config p05-07-kind.yaml --wait 5m"
kind get kubeconfig --name "$CLUSTER" > p05-07.kubeconfig || exit 2
if [ -n "$LAB_HOST" ]; then
  ssh -f -N -M -S "$work/ctl" -o ExitOnForwardFailure=yes \
    -L "$PORT:127.0.0.1:$PORT" -L "$REG_PORT:127.0.0.1:$REG_PORT" "$LAB_HOST" || exit 2
fi
export KUBECONFIG="$work/p05-07.kubeconfig"
[ "$(kubectl config current-context)" = "kind-$CLUSTER" ] || { echo "refusing: unexpected context" >&2; exit 2; }
show "kubectl version"
show "kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion"
show "kubectl api-resources --api-group=admissionregistration.k8s.io"

fi
echo '## step 2: a lab registry on the kind network, the nodes told to trust it, and a name the Pods resolve [full mode]'
if [ "$MODE" = full ]; then
show "docker rm -f $REG_NAME"
show "docker run -d --name $REG_NAME --network kind -p 127.0.0.1:$REG_PORT:5000 $REG_IMAGE"
for i in $(seq 1 30); do curl -fsS -m 2 "http://localhost:$REG_PORT/v2/" >/dev/null 2>&1 && break; sleep 1; done
REG_IP=$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' $REG_NAME 2>/dev/null)
echo "registry address: found on the kind network"
printf '[host."http://%s:5000"]\n  capabilities = ["pull", "resolve"]\n' "$REG_IP" > hosts.toml
for n in $(docker ps --filter label=io.x-k8s.kind.cluster=$CLUSTER --format '{{.Names}}'); do
  show "docker exec $n mkdir -p /etc/containerd/certs.d/$REG_SVC"
  docker exec -i "$n" sh -c "cat > /etc/containerd/certs.d/$REG_SVC/hosts.toml" < hosts.toml
  show "docker exec $n cat /etc/containerd/certs.d/$REG_SVC/hosts.toml"
done
show "kubectl create namespace p05-07-registry"
cat > registry-service.yaml <<YAML
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: p05-07-registry
spec:
  ports:
    - name: http
      port: 5000
      targetPort: 5000
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: registry
  namespace: p05-07-registry
  labels:
    kubernetes.io/service-name: registry
addressType: IPv4
ports:
  - name: http
    port: 5000
    protocol: TCP
endpoints:
  - addresses: ["$REG_IP"]
    conditions:
      ready: true
YAML
show "kubectl apply -f registry-service.yaml"

fi
echo '## step 3: a Bookstore image pushed to the lab registry, and a tampered copy of it [full mode]'
if [ "$MODE" = full ]; then
show "docker tag bookstore/catalog:dev localhost:$REG_PORT/bookstore/catalog:lab"
show "docker push localhost:$REG_PORT/bookstore/catalog:lab"
D_SIGNED=$(docker inspect -f '{{index .RepoDigests 0}}' localhost:$REG_PORT/bookstore/catalog:lab | sed 's/.*@//')
echo "signed candidate digest: $D_SIGNED"
show "docker build -q -t localhost:$REG_PORT/bookstore/catalog:tampered - <<'DOCKERFILE'
FROM bookstore/catalog:dev
LABEL lab.p05-07.note=\"tampered after the build\"
DOCKERFILE"
show "docker push localhost:$REG_PORT/bookstore/catalog:tampered"
D_TAMPERED=$(docker inspect -f '{{index .RepoDigests 0}}' localhost:$REG_PORT/bookstore/catalog:tampered | sed 's/.*@//')
echo "tampered digest: $D_TAMPERED"
echo "the two digests differ: $([ "$D_SIGNED" != "$D_TAMPERED" ] && echo yes || echo no)"
echo

fi
echo '## step 4: sign the candidate with a throwaway key and no transparency log; verify both digests [full mode]'
if [ "$MODE" = full ]; then
show "COSIGN_PASSWORD= cosign generate-key-pair"
cat > signing-config.json <<'JSON'
{
  "mediaType": "application/vnd.dev.sigstore.signingconfig.v0.2+json",
  "caUrls": [],
  "oidcUrls": [],
  "rekorTlogUrls": [],
  "tsaUrls": []
}
JSON
show "COSIGN_PASSWORD= cosign sign --yes --key cosign.key --signing-config=signing-config.json localhost:$REG_PORT/bookstore/catalog@$D_SIGNED >/dev/null 2>sign.err; echo \"sign exit=\$?\""
show "cosign verify --key cosign.pub --insecure-ignore-tlog localhost:$REG_PORT/bookstore/catalog@$D_SIGNED >/dev/null 2>verify-signed.err; echo \"verify signed exit=\$?\""
show "cosign verify --key cosign.pub --insecure-ignore-tlog localhost:$REG_PORT/bookstore/catalog@$D_TAMPERED >/dev/null 2>verify-tampered.err; echo \"verify tampered exit=\$?\""
show "head -n 1 verify-tampered.err"

fi
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
  validations:
    - expression: "object.spec.containers.all(c, c.image.contains('@sha256:'))"
      message: "every container image must be pinned by digest"
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
echo '## step 7: the Bookstore catalog, with the full baseline and a digest, in a namespace the policies cover [full mode]'
if [ "$MODE" = full ]; then
show "kubectl create namespace p05-07-signed"
wait_sa p05-07-signed
show "kubectl -n p05-07-signed get serviceaccount default -o name"
show "kubectl label namespace p05-07-signed p05-07-lab=true"
cat > catalog-signed.yaml <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: catalog
  namespace: p05-07-signed
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
      image: $REG_SVC/bookstore/catalog@$D_SIGNED
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
sed "s|@$D_SIGNED|@$D_TAMPERED|; s|name: catalog\$|name: catalog-tampered|" catalog-signed.yaml > catalog-tampered.yaml
show "kubectl apply -f catalog-signed.yaml"
show "kubectl -n p05-07-signed wait --for=condition=Ready pod/catalog --timeout=180s"
show "kubectl apply -f catalog-tampered.yaml"
show "kubectl -n p05-07-signed delete pod catalog-tampered --wait=true"

fi
echo '## step 8: Kyverno, installed with the chart pinned and the namespace labelled [full mode]'
if [ "$MODE" = full ]; then
show "helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update"
show "helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts --force-update"
show "helm show chart kyverno/kyverno --version $KYVERNO_CHART"
show "kubectl create namespace kyverno"
show "kubectl label namespace kyverno pod-security.kubernetes.io/enforce=restricted"
show "helm upgrade --install kyverno kyverno/kyverno --version $KYVERNO_CHART --namespace kyverno --wait --timeout 10m --set features.registryClient.allowInsecure=true --set admissionController.replicas=1 --set backgroundController.replicas=1 --set cleanupController.replicas=1 --set reportsController.replicas=1"
show "kubectl -n kyverno get deploy"

fi
echo '## step 9: Audit before Enforce: a privileged Pod is admitted and reported [full mode]'
if [ "$MODE" = full ]; then
show "kubectl create namespace p05-07-kyverno"
wait_sa p05-07-kyverno
show "kubectl -n p05-07-kyverno get serviceaccount default -o name"
cat > escape-node.yaml <<'YAML'
# INSECURE ON PURPOSE: a privileged container, which the Kyverno rule refuses. Lab cluster only.
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
      image: REPLACE_CATALOG
      securityContext:
        privileged: true
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
sed -i.bak "s|REPLACE_CATALOG|$REG_SVC/bookstore/catalog@$D_SIGNED|" escape-node.yaml
cat > policy-disallow-privileged.yaml <<'YAML'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: p05-07-disallow-privileged
  annotations:
    policies.kyverno.io/title: Disallow privileged containers
    policies.kyverno.io/description: The Bookstore rule BK-POL-001, enforced at admission.
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: no-privileged-containers
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [p05-07-kyverno]
      validate:
        message: "BK-POL-001: privileged containers are not allowed"
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): false
YAML
show "kubectl apply -f policy-disallow-privileged.yaml"
show "sleep 5"
show "kubectl apply -f escape-node.yaml"
show "kubectl -n p05-07-kyverno get pod escape-node -o jsonpath='{.metadata.name} admitted, privileged={.spec.containers[0].securityContext.privileged}{\"\\n\"}'"
show "sleep 20"
show "kubectl -n p05-07-kyverno get ephemeralreports,policyreports 2>/dev/null | head -5"

fi
echo '## step 10: Enforce: the same rule refuses the next privileged Pod [full mode]'
if [ "$MODE" = full ]; then
show "kubectl patch clusterpolicy p05-07-disallow-privileged --type merge -p '{\"spec\":{\"validationFailureAction\":\"Enforce\"}}'"
show "sleep 5"
sed 's/name: escape-node$/name: escape-node-2/' escape-node.yaml > escape-node-2.yaml
show "kubectl apply -f escape-node-2.yaml"

fi
echo '## step 11: verifyImages: the signature is checked, not only the digest [full mode]'
if [ "$MODE" = full ]; then
show "kubectl -n kyverno create secret generic p05-07-cosign-pub --from-file=cosign.pub=cosign.pub"
cat > policy-verify-signed.yaml <<YAML
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: p05-07-verify-signed-images
  annotations:
    policies.kyverno.io/title: Verify lab image signatures
    policies.kyverno.io/description: Pods in p05-07-signed run only images signed by the lab key.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: signed-by-lab-key
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [p05-07-signed]
      verifyImages:
        - imageReferences:
            - "$REG_SVC/bookstore/*"
          verifyDigest: true
          required: true
          attestors:
            - entries:
                - keys:
                    secret:
                      name: p05-07-cosign-pub
                      namespace: kyverno
YAML
show "kubectl apply -f policy-verify-signed.yaml"
show "sleep 5"
show "kubectl apply -f catalog-tampered.yaml"
show "kubectl -n p05-07-signed get pod catalog -o jsonpath='{.status.phase}{\"\\n\"}'"

fi
echo '## step 12: Gatekeeper, the same rule in Rego, in dry-run beside Kyverno [full mode]'
if [ "$MODE" = full ]; then
show "kubectl create namespace gatekeeper-system"
show "kubectl label namespace gatekeeper-system pod-security.kubernetes.io/enforce=restricted"
show "helm upgrade --install gatekeeper gatekeeper/gatekeeper --version $GATEKEEPER_CHART --namespace gatekeeper-system --wait --timeout 10m --set replicas=1"
cat > gatekeeper-template.yaml <<'YAML'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: p05nopriv
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
show "kubectl delete pod escape-node -n p05-07-kyverno --wait=true"
show "kubectl delete p05noprivileged p05-no-privileged"
show "kubectl delete constrainttemplate p05nopriv"
show "helm uninstall gatekeeper --namespace gatekeeper-system --wait"
show "kubectl get crd -o name | grep 'gatekeeper.sh' | xargs kubectl delete --wait=true"
show "kubectl delete namespace gatekeeper-system --wait=true"

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
[ "$MODE" = full ] && show "kubectl get clusterpolicy"
show "kubectl get validatingadmissionpolicy,mutatingadmissionpolicy -o name | grep p05-07 | sort"

echo '## step 15: remove Kyverno and the lab objects [full mode]'
if [ "$MODE" = full ]; then
show "kubectl delete clusterpolicy p05-07-disallow-privileged p05-07-verify-signed-images --ignore-not-found"
show "helm uninstall kyverno --namespace kyverno --wait"
show "kubectl get crd -o name | grep 'kyverno.io' | xargs kubectl delete --wait=true"
show "kubectl delete namespace kyverno --wait=true"

fi

if [ "$MODE" = shared ]; then
echo '## step 16: the Kyverno and Gatekeeper installs, rendered and checked without a cluster [shared mode]'
show "helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update"
show "helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts --force-update"
show "helm template kyverno kyverno/kyverno --version $KYVERNO_CHART --namespace kyverno --set features.registryClient.allowInsecure=true --set admissionController.replicas=1 --set backgroundController.replicas=1 --set cleanupController.replicas=1 --set reportsController.replicas=1 > kyverno-rendered.yaml"
show "grep -c '^kind: ' kyverno-rendered.yaml"
show "grep -h 'image: ' kyverno-rendered.yaml | sed 's/^ *//' | sort -u | head -4"
show "helm template gatekeeper gatekeeper/gatekeeper --version $GATEKEEPER_CHART --namespace gatekeeper-system --set replicas=1 > gatekeeper-rendered.yaml"
show "grep -c '^kind: ' gatekeeper-rendered.yaml"
cat > policy-disallow-privileged.yaml <<'YAML'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: p05-07-disallow-privileged
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: no-privileged-containers
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [p05-07-kyverno]
      validate:
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
