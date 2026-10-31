#!/usr/bin/env bash
# Lab for 05-security/08-audit-detection-and-incident-response.md: audit the
# attacks from 05.01 and 05.02, detect them with Falco, scan with Trivy
# Operator, and respond to a compromised Pod.
#
# Tier A: kind on a Linux host. The audit policy needs an API server flag, so
# the lab makes a throwaway cluster, p05-08, from kind's own configuration and
# deletes it at the end. Falco needs a Linux kernel with BTF, so the host that
# runs kind must be Linux. A kind node is a container that shares the host's
# kernel, and every payload here reads or writes only inside that container.
#
# Run it only against clusters you own. It creates and deletes its own
# namespaces and runs Pods marked INSECURE ON PURPOSE. The Falco and Trivy
# installs are heavy: run them when no other heavy install shares the cluster.
#
# Environment:
#   LAB_HOST  ssh alias of the Linux host that runs kind. Empty: this machine.
#   KIND_BIN  kind on that host. Default: kind.
#   LAB_PORT  API server port to forward to this machine. Default: 36081.
#   LAB_MODE  throwaway (the default), shared or full. See below.
#   LAB_CONTEXT  full mode only: the kubectl context of the kind cluster the
#             run may use. Required, and it must start with kind-.
#   LAB_NODE  full mode only: the node that runs Falco and the lab Pod.
#             Default: the first node without the control-plane role.
#   STEPS     full mode only: the steps to run, in order. Default: all of them.
#
# LAB_MODE=throwaway makes the p05-08 cluster with the audit policy and runs
# every step. LAB_MODE=shared runs only the attack and response steps that need
# no API server flag and no heavy install, on the shared cluster that KUBECONFIG
# names (kind-sf-pilot). Use shared only on a cluster you own.
#
# LAB_MODE=full installs Falco and Trivy Operator, one after the other, on the
# kind cluster that LAB_CONTEXT names, triggers real detections with a shell
# and a sensitive-file read in a lab Pod, captures what each tool reports, and
# removes each tool before the next goes in. It does not create a cluster, so
# the audit steps (which need an API server flag) are not part of it. The
# digest lookups in F1 use docker buildx, and F3 uses jq. Steps:
#   F1  tools, image digests, and the lab's namespaces and identities
#   F2  Falco with Falcosidekick, in the falco namespace
#   F3  detections: a shell in the lab Pod and a read of a sensitive file
#   F4  remove Falco
#   F5  Trivy Operator
#   F6  the reports it writes for the lab Pod
#   F7  remove Trivy Operator, its CRDs and any webhook configuration
#   F8  remove the lab's namespaces and check that nothing remains
# A step leaves its objects in place for the next, so a run that is too long
# for one sitting can be split across invocations. A run that fails, or that
# sees the control plane restart, removes everything it installed. The
# recorded run was split into 15 invocations.
#
# Run from the repository root:
#   bash full-guide/examples/security-lab/labs/05-08.sh \
#     > full-guide/examples/security-lab/evidence/05-08.txt
# or, for full mode:
#   LAB_MODE=full LAB_CONTEXT=kind-NAME STEPS="F1 F2" bash \
#     full-guide/examples/security-lab/labs/05-08.sh
#
# Each command is printed the way a reader types it, then run, so the output
# under it is what that command printed. The throwaway cluster is shown as
# p05-08.
#
# The shared-mode recording named the two privileged namespaces p05-08-attack
# and p05-08-falco. This file and the transcript carry the chapter's names,
# attack and falco, because the exceptions registry reads Pod Security labels
# from scripts and transcripts and registers the chapter's namespace, not a lab
# name. That rename is the only edit made to that recording.

set -uo pipefail

REPO=$(cd "$(dirname "$0")/../../../.." && pwd)
WORK=$(mktemp -d)
LAB_HOST=${LAB_HOST:-}
KIND_BIN=${KIND_BIN:-kind}
PORT=${LAB_PORT:-36081}
CLUSTER=p05-08
CTX=kind-p05-08
NODE=p05-08-control-plane
TUNNEL=""
CREATED=""
LAB_MODE=${LAB_MODE:-throwaway}
# LAB_MODE=full runs on the kind cluster that LAB_CONTEXT names and installs
# Falco and Trivy Operator there, one at a time. See the header.
LAB_CONTEXT=${LAB_CONTEXT:-}
STEPS=${STEPS:-F1 F2 F3 F4 F5 F6 F7 F8}
if [ "$LAB_MODE" = shared ]; then
  CTX=kind-sf-pilot
  NODE=sf-pilot-control-plane
fi
if [ "$LAB_MODE" = full ]; then
  CTX=$LAB_CONTEXT
fi

cleanup() {
  rc=$?
  # Delete the lab's namespaces only on the lab cluster's context, never on
  # whatever context the caller's kubeconfig points at. A full-mode run splits
  # across invocations, so it removes its objects only when it failed or was
  # stopped; step F8 removes them on a run that finished.
  if [ -s "$WORK/admin.kubeconfig" ] && [ "$(KUBECONFIG="$WORK/admin.kubeconfig" \
      kubectl config current-context 2>/dev/null)" = "$CTX" ]; then
    if [ "$LAB_MODE" != full ]; then
      KUBECONFIG="$WORK/admin.kubeconfig" kubectl delete namespace attack \
        p05-08-app falco p05-08-trivy --ignore-not-found --wait=false \
        >/dev/null 2>&1
    elif [ "$rc" -ne 0 ]; then
      KUBECONFIG="$WORK/admin.kubeconfig" full_teardown "run failed or stopped (exit $rc)"
    fi
  fi
  if [ -n "$TUNNEL" ]; then kill "$TUNNEL" 2>/dev/null; fi
  # Delete only a cluster this run created. A refused start must never touch
  # a cluster that another run owns under the same name.
  if [ -n "$CREATED" ]; then
    on_host "$KIND_BIN delete cluster --name $CLUSTER" >/dev/null 2>&1
    on_host 'rm -rf "$HOME/p05-08"' >/dev/null 2>&1
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# on_host runs a shell string on the host that runs kind. Standard input is
# passed through, so a file can be copied with on_host 'cat > path' < file.
on_host() {
  if [ -n "$LAB_HOST" ]; then ssh "$LAB_HOST" "$1"; else sh -c "$1"; fi
}

# redact hides the work directory and any home path from the transcript.
redact() {
  sed -e "s|$WORK|work|g" -e 's|/home/[^ /"]*|~|g' -e 's|/Users/[^ /"]*|~|g'
}

# show prints the command as a reader types it, then runs the shell string
# that does the work and prints its output.
show() {
  printf '$ %s\n' "$1"
  eval "$2" 2>&1 | redact
}

# make_kubeconfig NAME TOKEN writes work/NAME.kubeconfig: the cluster and its
# CA, with no admin credential, and a token for NAME.
make_kubeconfig() {
  cp "$WORK/admin.kubeconfig" "$WORK/$1.kubeconfig"
  KUBECONFIG="$WORK/$1.kubeconfig" kubectl config unset "users.$CTX" >/dev/null
  KUBECONFIG="$WORK/$1.kubeconfig" kubectl config set-credentials "$1" \
    --token="$2" >/dev/null
  KUBECONFIG="$WORK/$1.kubeconfig" kubectl config set-context "$CTX" \
    --user="$1" >/dev/null
}

# query_audit MODE reads the audit log and prints one line per event for the
# lab's namespaces. Only ResponseComplete events are read, so each request
# appears once and carries its status code.
query_audit() {
  python3 - "$WORK/audit.log" "$1" <<'PY'
import json
import sys

LAB = ("attack", "p05-08-app")
path, mode = sys.argv[1], sys.argv[2]


def who(user):
    return user.replace("system:serviceaccount:", "")


for line in open(path):
    e = json.loads(line)
    if e.get("stage") != "ResponseComplete":
        continue
    ref = e.get("objectRef") or {}
    if ref.get("namespace") not in LAB:
        continue
    user = who(e["user"]["username"])
    code = e.get("responseStatus", {}).get("code", "")
    name = ref.get("name", "")
    spec = (e.get("requestObject") or {}).get("spec") or {}
    if mode == "secrets" and ref.get("resource") == "secrets":
        print(f"{user:<44} {e['verb']:<6} secrets/{name:<12} {code}")
    elif mode == "pods" and ref.get("resource") == "pods" and not ref.get("subresource"):
        if e["verb"] not in ("create", "delete"):
            continue
        vols = [v["hostPath"]["path"] for v in spec.get("volumes", []) if "hostPath" in v]
        priv = any(c.get("securityContext", {}).get("privileged")
                   for c in spec.get("containers", []))
        print(f"{user:<44} {e['verb']:<6} pods/{name:<12} {code}"
              f"  sa={spec.get('serviceAccountName', '-')}"
              f" privileged={str(priv).lower()} hostPath={','.join(vols) or '-'}")
    elif mode == "exec" and ref.get("subresource") == "exec":
        cmd = " ".join((e.get("requestObject") or {}).get("command", []))
        print(f"{user:<44} exec   pods/{name:<12} {code}  command={cmd}")
    elif mode == "tokens" and ref.get("subresource") == "token":
        print(f"{user:<44} {e['verb']:<6} serviceaccounts/{name} {code}")
    elif mode == "refused" and code == 403:
        print(f"{user:<44} {e['verb']:<6} {ref.get('resource', '')}/{name:<12} {code}")
PY
}

# apply_lab_objects creates the lab's namespaces, identities and victim Secret.
apply_lab_objects() {
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: attack
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: Namespace
metadata:
  name: p05-08-app
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.37
YAML
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: builder
  namespace: attack
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ops
  namespace: attack
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: builder
  namespace: attack
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: builder
  namespace: attack
subjects:
  - kind: ServiceAccount
    name: builder
    namespace: attack
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: builder
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: p05-08-app
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ops-secret-reader
  namespace: p05-08-app
subjects:
  - kind: ServiceAccount
    name: ops
    namespace: attack
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: secret-reader
YAML
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: app-db
  namespace: p05-08-app
type: Opaque
stringData:
  password: lab-only-value-not-a-credential
YAML

}

# write_escape_node writes the Pod the attacks and the detectors look at.
write_escape_node() {
cat > "$WORK/escape-node.yaml" <<'YAML'
# INSECURE ON PURPOSE: a Pod that mounts the node container's root and runs as the ops ServiceAccount. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-node
  namespace: attack
spec:
  serviceAccountName: ops
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "1800"]
      volumeMounts:
        - name: node-root
          mountPath: /host
  volumes:
    - name: node-root
      hostPath:
        path: /
        type: Directory
YAML
  if [ -n "${LAB_NODE:-}" ]; then
    awk -v node="$LAB_NODE" '{ print }
      /^  serviceAccountName: ops$/ { print "  nodeSelector:"; print "    kubernetes.io/hostname: " node }' \
      "$WORK/escape-node.yaml" > "$WORK/escape-node.pinned" && mv "$WORK/escape-node.pinned" "$WORK/escape-node.yaml"
  fi
}

# The values the Falco and Trivy Operator installs use.
write_falco_values() {
cat > "$WORK/falco-values.yaml" <<'YAML'
driver:
  kind: modern_ebpf
  modernEbpf:
    leastPrivileged: true
image:
  tag: "0.45.2@sha256:1562a643953f938e02f47319b5214d93a235f11f646d60e9b8a516fd5a64698e"
falcoctl:
  image:
    tag: "0.14.3@sha256:2230fb4802aafe09455b58d38f8f1faedd8f09f042e9a18fffd397e63488c023"
falcosidekick:
  enabled: true
  replicaCount: 1
  image:
    tag: "2.32.0@sha256:1976da72151850aae4436f33a5ed94bdef469f42a9b61c182b4feeb5441fb081"
  config:
    debug: true
YAML
# LAB_NODE pins the DaemonSet to one node, so that a shared host pulls and
# runs one Falco instead of one per node. Every node of a kind cluster shares
# the host's kernel, so one instance still sees the lab Pod's system calls.
if [ -n "${LAB_NODE:-}" ]; then
cat >> "$WORK/falco-values.yaml" <<YAML
nodeSelector:
  kubernetes.io/hostname: $LAB_NODE
YAML
fi
}

write_trivy_values() {
cat > "$WORK/trivy-values.yaml" <<'YAML'
targetNamespaces: attack
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10000
  runAsGroup: 10000
  seccompProfile:
    type: RuntimeDefault
securityContext:
  privileged: false
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
operator:
  scanJobsConcurrentLimit: 1
  sbomGenerationEnabled: false
  exposedSecretScannerEnabled: false
  rbacAssessmentScannerEnabled: false
  infraAssessmentScannerEnabled: false
  clusterComplianceEnabled: false
trivyOperator:
  scanJobPodTemplatePodSecurityContext:
    runAsNonRoot: true
    runAsUser: 10000
    runAsGroup: 10000
    seccompProfile:
      type: RuntimeDefault
image:
  tag: "0.36.1@sha256:05191a514247ae644dd5cc71306a94f44faff0a6a3fa817235911b911ecebcb9"
trivy:
  image:
    tag: "0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c"
YAML
}


# The control plane's restart count, summed. A full-mode run stops if it goes up.
cp_restarts() {
  local o
  o=$(kubectl -n kube-system get pods -l tier=control-plane \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null) \
    && [ -n "$o" ] || { echo -1; return; }
  echo "$o" | tr ' ' '\n' | awk '{s+=$1} END{print s+0}'
}

# What Falco and Trivy Operator, and the lab, leave behind, one object per line.
trace_left() {
  kubectl get --raw /readyz >/dev/null 2>&1 || echo "api-unreadable"
  kubectl get crd -o name 2>/dev/null | grep -E 'aquasecurity\.github\.io'
  kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
    -o name 2>/dev/null | grep -iE 'falco|trivy'
  kubectl get clusterrole,clusterrolebinding -o name 2>/dev/null | grep -iE 'falco|trivy'
  kubectl get namespace -o name 2>/dev/null | grep -E 'namespace/(attack|falco|p05-08-)'
}

# full_teardown removes everything a full-mode run may have installed. The
# order matters: releases first, then the namespaces (a controller removed
# after its webhook configuration cannot write it back), then the webhook
# configurations and the CRDs, which a chart does not remove. A busy API server
# can refuse a delete, so the pass repeats until nothing is left, three times
# at most.
full_teardown() {
  local pass left
  echo "$1: removing Falco, Trivy Operator and the lab's namespaces"
  for pass in 1 2 3; do
    helm uninstall falco --namespace falco --wait --timeout 3m >/dev/null 2>&1
    helm uninstall trivy --namespace p05-08-trivy --wait --timeout 3m >/dev/null 2>&1
    kubectl delete namespace attack p05-08-app falco p05-08-trivy \
      --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1
    kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
      -o name 2>/dev/null | grep -iE 'falco|trivy' | xargs kubectl delete --ignore-not-found >/dev/null 2>&1
    kubectl get crd -o name 2>/dev/null | grep -E 'aquasecurity\.github\.io' \
      | xargs kubectl delete --wait=true --timeout=120s >/dev/null 2>&1
    kubectl get clusterrole,clusterrolebinding -o name 2>/dev/null | grep -iE 'falco|trivy' \
      | xargs kubectl delete --ignore-not-found >/dev/null 2>&1
    left=$(trace_left)
    [ -z "$left" ] && break
    sleep 15
  done
  if [ -n "$left" ]; then echo "STILL PRESENT, remove by hand:"; echo "$left"; else echo "nothing remains"; fi
}

# guard stops the run when the control plane restarts or stops answering. The
# cleanup then removes what the run installed.
guard() {
  local n
  n=$(cp_restarts)
  if [ "$n" -lt 0 ]; then echo "STOP: the API server did not answer"; exit 3; fi
  if [ "$n" -gt "$CP0" ]; then echo "STOP: the control plane restarted ($CP0 to $n)"; exit 3; fi
  echo "control plane restarts: $n (at the start of this run: $CP0)"
  echo
}

ctx_check() {
  [ "$(kubectl config current-context 2>/dev/null)" = "$CTX" ] \
    || { echo "FAILED: the kubectl context is not $CTX"; exit 2; }
}

# with_tty runs a command with a terminal attached, the way a person at a
# keyboard does, for `kubectl exec -it`. Falco's shell rule needs one.
with_tty() {
  python3 -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
out = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace").replace("\r\n", "\n"))
sys.exit(os.waitstatus_to_exitcode(status))
' "$@"
}

# wait_falco waits for the Falco DaemonSet and Falcosidekick, checking the
# control plane every ten seconds, and prints what failed if they never come up.
wait_falco() {
  local i n want have sk bad p
  for i in $(seq 1 "$1"); do
    n=$(cp_restarts)
    if [ "$n" -gt "$CP0" ]; then echo "STOP: the control plane restarted ($CP0 to $n)"; exit 3; fi
    want=$(kubectl -n falco get daemonset falco -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
    have=$(kubectl -n falco get daemonset falco -o jsonpath='{.status.numberReady}' 2>/dev/null)
    sk=$(kubectl -n falco get deployment falco-falcosidekick -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
    if [ -n "$want" ] && [ "$want" != 0 ] && [ "$want" = "$have" ] && [ -n "$sk" ]; then
      echo "falco DaemonSet ready on $have of $want nodes; falcosidekick available: $sk"
      echo
      return 0
    fi
    sleep 10
  done
  echo "Falco was not ready in time"
  show "kubectl get pods -n falco -o wide" "kubectl get pods -n falco -o wide"
  bad=$(kubectl -n falco get pods -l app.kubernetes.io/name=falco --no-headers 2>/dev/null \
    | awk '{split($2,a,"/"); if (a[1]!=a[2]) print $1}' | head -1)
  for p in $bad; do
    show "kubectl logs -n falco $p --all-containers --prefix --tail=25" \
      "kubectl logs -n falco $p --all-containers --prefix --tail=25"
    show "kubectl logs -n falco $p -c falco --previous --tail=25" "kubectl logs -n falco $p -c falco --previous --tail=25"
    show "kubectl get events -n falco --field-selector involvedObject.name=$p" \
      "kubectl get events -n falco --field-selector involvedObject.name=$p"
  done
  return 1
}

# wait_deploys waits for every Deployment in a namespace, checking the control
# plane every ten seconds, and prints what failed if they never come up.
wait_deploys() {
  local ns=$1 tries=$2 i n all not p
  for i in $(seq 1 "$tries"); do
    n=$(cp_restarts)
    if [ "$n" -gt "$CP0" ]; then echo "STOP: the control plane restarted ($CP0 to $n)"; exit 3; fi
    all=$(kubectl -n "$ns" get deploy -o name 2>/dev/null)
    not=$(kubectl -n "$ns" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.availableReplicas}{"/"}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
      | awk '{split($2,a,"/"); if (a[1]!=a[2]) print $1}')
    if [ -n "$all" ] && [ -z "$not" ]; then
      echo "every Deployment in $ns is available"
      echo
      return 0
    fi
    sleep 10
  done
  echo "not available in time: $not"
  show "kubectl get pods -n $ns" "kubectl get pods -n $ns"
  for p in $(kubectl -n "$ns" get pods -o name 2>/dev/null); do
    show "kubectl logs -n $ns $p --tail=15" "kubectl logs -n $ns $p --tail=15"
  done
  return 1
}

# apply_builder_kubeconfig writes work/builder.kubeconfig with a fresh token.
builder_kubeconfig() {
  make_kubeconfig builder "$(kubectl create token builder -n attack --duration=30m)"
}

step_F1() {
  echo "## step F1: tools, image digests, and the lab's namespaces and identities"
  ctx_check
  show "kubectl version --client" "kubectl version --client | head -1"
  show "helm version --short" "helm version --short"
  show "kubectl get nodes -o wide" "kubectl get nodes -o wide"
  show "kubectl -n kube-system get pods -l tier=control-plane" \
    "kubectl -n kube-system get pods -l tier=control-plane"
  local ref
  for ref in docker.io/falcosecurity/falco:0.45.2 docker.io/falcosecurity/falcoctl:0.14.3 \
      docker.io/falcosecurity/falcosidekick:2.32.0 mirror.gcr.io/aquasec/trivy-operator:0.36.1 \
      mirror.gcr.io/aquasec/trivy:0.76.1; do
    show "docker buildx imagetools inspect $ref | grep -E '^(Name|Digest):'" \
      "docker buildx imagetools inspect $ref | grep -E '^(Name|Digest):'"
  done
  local left
  left=$(trace_left)
  if [ -n "$left" ]; then
    echo "refusing: an earlier run left objects on this cluster:" >&2
    echo "$left" >&2
    exit 2
  fi
  apply_lab_objects
  # The privileged namespaces are listed without their labels: the namespace
  # manifest sets the label, and the exceptions registry reads it there.
  show "kubectl get namespace attack" "kubectl get namespace attack"
  show "kubectl get namespace p05-08-app --show-labels" "kubectl get namespace p05-08-app --show-labels"
  guard
}

step_F2() {
  echo "## step F2: Falco with Falcosidekick, in the falco namespace"
  ctx_check
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    pod-security.kubernetes.io/enforce: privileged
  annotations:
    security.example/exception-reason: "Falco driver mounts host paths; the container runs without privilege."
    security.example/exception-expires: "2027-06-30"
YAML
  write_falco_values
  show "kubectl get namespace falco" "kubectl get namespace falco"
  show "cat falco-values.yaml" "cat $WORK/falco-values.yaml"
  show "helm install falco falcosecurity/falco --version 9.2.2 --namespace falco -f falco-values.yaml" \
    "helm install falco falcosecurity/falco --version 9.2.2 --namespace falco -f $WORK/falco-values.yaml"
  wait_falco 48 || return 1
  show "kubectl get pods -n falco -o wide" "kubectl get pods -n falco -o wide"
  FALCO_POD=$(kubectl get pods -n falco -l app.kubernetes.io/name=falco -o jsonpath='{.items[0].metadata.name}')
  show "kubectl logs -n falco $FALCO_POD -c falco | head -30" \
    "kubectl logs -n falco $FALCO_POD -c falco | head -30"
  guard
}

step_F3() {
  echo "## step F3: detections: a shell in the lab Pod and a read of a sensitive file"
  ctx_check
  guard
  builder_kubeconfig
  write_escape_node
  kubectl delete pod escape-node -n attack --ignore-not-found --wait=true >/dev/null 2>&1
  show "kubectl --kubeconfig=work/builder.kubeconfig apply -f escape-node.yaml" \
    "KUBECONFIG=$WORK/builder.kubeconfig kubectl apply -f $WORK/escape-node.yaml"
  show "kubectl wait --for=condition=Ready pod/escape-node -n attack --timeout=180s" \
    "kubectl wait --for=condition=Ready pod/escape-node -n attack --timeout=180s"
  show "kubectl get pod escape-node -n attack -o wide" "kubectl get pod escape-node -n attack -o wide"
  sleep 15
  show "kubectl --kubeconfig=work/builder.kubeconfig exec -it -n attack escape-node -- sh -c 'cat /etc/shadow > /dev/null && echo shadow-read'" \
    "KUBECONFIG=$WORK/builder.kubeconfig with_tty kubectl exec -it -n attack escape-node -- sh -c 'cat /etc/shadow > /dev/null && echo shadow-read'"
  show "kubectl --kubeconfig=work/builder.kubeconfig exec -it -n attack escape-node -- sh -c 'chroot /host cat /etc/shadow > /dev/null && echo node-shadow-read'" \
    "KUBECONFIG=$WORK/builder.kubeconfig with_tty kubectl exec -it -n attack escape-node -- sh -c 'chroot /host cat /etc/shadow > /dev/null && echo node-shadow-read'"
  show "kubectl --kubeconfig=work/builder.kubeconfig exec -n attack escape-node -- sh -c 'cat /host/etc/shadow > /dev/null && echo host-path-read'" \
    "KUBECONFIG=$WORK/builder.kubeconfig kubectl exec -n attack escape-node -- sh -c 'cat /host/etc/shadow > /dev/null && echo host-path-read'"
  sleep 20
  cat > "$WORK/alert.jq" <<'JQ'
"\(.priority) | \(.rule) | \(.output_fields["proc.cmdline"])"
JQ
  show "cat alert.jq" "cat $WORK/alert.jq"
  show "kubectl logs -n falco ds/falco -c falco | grep escape-node | jq -r -f alert.jq" \
    "kubectl logs -n falco ds/falco -c falco | grep escape-node | jq -r -f $WORK/alert.jq"
  show "kubectl logs -n falco ds/falco -c falco | grep 'Read sensitive file untrusted' | grep escape-node | head -1 | jq ." \
    "kubectl logs -n falco ds/falco -c falco | grep 'Read sensitive file untrusted' | grep escape-node | head -1 | jq ."
  show "kubectl logs -n falco deploy/falco-falcosidekick | grep -c escape-node" \
    "kubectl logs -n falco deploy/falco-falcosidekick | grep -c escape-node"
  show "kubectl logs -n falco deploy/falco-falcosidekick | grep -m1 'Sensitive file opened' | cut -c1-120" \
    "kubectl logs -n falco deploy/falco-falcosidekick | grep -m1 'Sensitive file opened' | cut -c1-120"
  guard
}

step_F4() {
  echo "## step F4: remove Falco"
  ctx_check
  show "helm uninstall falco -n falco" "helm uninstall falco -n falco --wait --timeout 3m"
  show "kubectl delete namespace falco" "kubectl delete namespace falco --wait=true --timeout=180s"
  show "kubectl get namespace falco" "kubectl get namespace falco"
  show "kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ci falco" \
    "kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ci falco"
  show "kubectl get clusterrole,clusterrolebinding -o name | grep -ci falco" \
    "kubectl get clusterrole,clusterrolebinding -o name | grep -ci falco"
  guard
}

step_F5() {
  echo "## step F5: Trivy Operator, installed with the chart pinned and the namespace labelled"
  ctx_check
  guard
  if ! kubectl get pod escape-node -n attack >/dev/null 2>&1; then
    builder_kubeconfig
    write_escape_node
    show "kubectl --kubeconfig=work/builder.kubeconfig apply -f escape-node.yaml" \
      "KUBECONFIG=$WORK/builder.kubeconfig kubectl apply -f $WORK/escape-node.yaml"
    show "kubectl wait --for=condition=Ready pod/escape-node -n attack --timeout=180s" \
      "kubectl wait --for=condition=Ready pod/escape-node -n attack --timeout=180s"
  fi
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: p05-08-trivy
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
YAML
  write_trivy_values
  show "kubectl get namespace p05-08-trivy --show-labels" "kubectl get namespace p05-08-trivy --show-labels"
  show "cat trivy-values.yaml" "cat $WORK/trivy-values.yaml"
  show "helm install trivy aqua/trivy-operator --version 0.38.1 --namespace p05-08-trivy -f trivy-values.yaml" \
    "helm install trivy aqua/trivy-operator --version 0.38.1 --namespace p05-08-trivy -f $WORK/trivy-values.yaml"
  wait_deploys p05-08-trivy 48 || return 1
  show "kubectl get pods -n p05-08-trivy" "kubectl get pods -n p05-08-trivy"
  guard
}

step_F6() {
  echo "## step F6: the reports Trivy Operator writes for the lab Pod"
  ctx_check
  guard
  local i guard_n
  for i in $(seq 1 24); do
    guard_n=$(cp_restarts)
    if [ "$guard_n" -gt "$CP0" ]; then echo "STOP: the control plane restarted ($CP0 to $guard_n)"; exit 3; fi
    kubectl get configauditreport pod-escape-node -n attack >/dev/null 2>&1 && break
    sleep 10
  done
  show "kubectl get configauditreports -n attack" "kubectl get configauditreports -n attack"
  show "kubectl get configauditreport pod-escape-node -n attack -o jsonpath='{range .report.checks[?(@.success==false)]}{.checkID} {.severity} {.title}{\"\\n\"}{end}'" \
    "kubectl get configauditreport pod-escape-node -n attack -o jsonpath='{range .report.checks[?(@.success==false)]}{.checkID} {.severity} {.title}{\"\\n\"}{end}'"
  for i in $(seq 1 30); do
    guard_n=$(cp_restarts)
    if [ "$guard_n" -gt "$CP0" ]; then echo "STOP: the control plane restarted ($CP0 to $guard_n)"; exit 3; fi
    kubectl get vulnerabilityreports -n attack -o name 2>/dev/null | grep -q . && break
    sleep 10
  done
  show "kubectl get vulnerabilityreports -n attack -o wide" "kubectl get vulnerabilityreports -n attack -o wide"
  show "kubectl get vulnerabilityreport pod-escape-node-app -n attack -o jsonpath='{.report.scanner.name} {.report.scanner.version}{\"\\n\"}{.report.artifact.repository}{\"\\n\"}'" \
    "kubectl get vulnerabilityreport pod-escape-node-app -n attack -o jsonpath='{.report.scanner.name} {.report.scanner.version}{\"\\n\"}{.report.artifact.repository}{\"\\n\"}'"
  show "kubectl get jobs,pods -n p05-08-trivy" "kubectl get jobs,pods -n p05-08-trivy"
  guard
}

step_F7() {
  echo "## step F7: remove Trivy Operator, its CRDs and any webhook configuration"
  ctx_check
  show "helm uninstall trivy -n p05-08-trivy" "helm uninstall trivy -n p05-08-trivy --wait --timeout 3m"
  show "kubectl delete namespace p05-08-trivy" "kubectl delete namespace p05-08-trivy --wait=true --timeout=180s"
  show "kubectl get crd -o name | grep aquasecurity.github.io" \
    "kubectl get crd -o name | grep aquasecurity.github.io"
  show "kubectl get crd -o name | grep aquasecurity.github.io | xargs kubectl delete" \
    "kubectl get crd -o name | grep aquasecurity.github.io | xargs kubectl delete --wait=true --timeout=120s"
  show "kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ci trivy" \
    "kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ci trivy"
  show "kubectl get clusterrole,clusterrolebinding -o name | grep -ci trivy" \
    "kubectl get clusterrole,clusterrolebinding -o name | grep -ci trivy"
  guard
}

step_F8() {
  echo "## step F8: remove the lab's namespaces and check that nothing remains"
  ctx_check
  show "kubectl delete namespace attack p05-08-app" \
    "kubectl delete namespace attack p05-08-app --wait=true --timeout=180s"
  show "kubectl get namespace" "kubectl get namespace"
  show "kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations" \
    "kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations"
  show "kubectl get crd" "kubectl get crd"
  local left
  left=$(trace_left)
  [ -z "$left" ] || { echo "left behind:"; echo "$left"; exit 1; }
  echo "nothing of the lab remains"
  guard
}

full_mode() {
  case "$LAB_CONTEXT" in
    kind-*) ;;
    *) echo "refusing: set LAB_CONTEXT to the kind-* context of a cluster you own" >&2; exit 2 ;;
  esac
  cp "${KUBECONFIG:?set KUBECONFIG to the lab cluster}" "$WORK/admin.kubeconfig"
  export KUBECONFIG="$WORK/admin.kubeconfig"
  ctx_check
  CP0=$(cp_restarts)
  # The first node without the control-plane role runs Falco and the lab Pod.
  LAB_NODE=${LAB_NODE:-$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[0].metadata.name}')}
  echo "# Lab 05-08: Falco and Trivy Operator. Tier A, full mode, on the kind cluster named by LAB_CONTEXT."
  local s
  for s in $STEPS; do
    case "$s" in
      F1|F2|F3|F4|F5|F6|F7|F8) "step_$s" || exit 1 ;;
      *) echo "refusing: unknown step $s" >&2; exit 2 ;;
    esac
  done
}

if [ "$LAB_MODE" = full ]; then
  full_mode
  exit 0
fi

if [ "$LAB_MODE" = shared ]; then
  echo "# Lab 05-08: attack and response, shared mode, on the shared kind cluster."
else
  echo "# Lab 05-08: audit, detection and response. Tier A, throwaway cluster p05-08."
  show "$KIND_BIN version" "on_host '$KIND_BIN version'"
fi
show "kubectl version --client" "kubectl version --client | head -1"
show "helm version --short" "helm version --short"

if [ "$LAB_MODE" = shared ]; then
  cp "${KUBECONFIG:?set KUBECONFIG to the shared kubeconfig}" "$WORK/admin.kubeconfig"
  export KUBECONFIG="$WORK/admin.kubeconfig"
  if [ "$(kubectl config current-context)" != "$CTX" ]; then
    echo "refusing: current context is not $CTX" >&2
    exit 2
  fi
  # A namespace that is still terminating from an earlier run blocks new objects.
  for ns in attack p05-08-app; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
      echo "refusing: namespace $ns exists or is terminating; wait for it to go" >&2
      exit 2
    fi
  done
else
# Refuse to start over a leftover cluster or a busy port.
if on_host "$KIND_BIN get clusters" | grep -qx "$CLUSTER"; then
  echo "refusing: kind cluster $CLUSTER exists; delete it first" >&2
  exit 2
fi
if on_host "ss -ltn | grep -q ':$PORT '"; then
  echo "refusing: port $PORT is busy on the kind host" >&2
  exit 2
fi

##@ Cluster with an audit policy

on_host 'mkdir -p "$HOME/p05-08"'
on_host 'cat > "$HOME/p05-08/audit-policy.yaml"' \
  < "$REPO/full-guide/examples/security-lab/audit/audit-policy.yaml"
on_host 'sed "s|AUDIT_DIR|$HOME/p05-08|" > "$HOME/p05-08/audit-cluster.yaml"' \
  < "$REPO/full-guide/examples/security-lab/kind/audit-cluster.yaml"

show "kind create cluster --config audit-cluster.yaml --kubeconfig admin.kubeconfig" \
  "on_host 'cd \"\$HOME/p05-08\" && $KIND_BIN create cluster --config audit-cluster.yaml --kubeconfig admin.kubeconfig'"
if ! on_host 'test -s "$HOME/p05-08/admin.kubeconfig"'; then
  echo "refusing: kind did not write a kubeconfig; the cluster was not created" >&2
  exit 2
fi
CREATED=1

on_host 'cat "$HOME/p05-08/admin.kubeconfig"' > "$WORK/admin.kubeconfig"
if [ -n "$LAB_HOST" ]; then
  ssh -fN -o ExitOnForwardFailure=yes -L "$PORT:127.0.0.1:$PORT" "$LAB_HOST"
  TUNNEL=$(pgrep -n -f "ssh -fN .*-L $PORT:127.0.0.1:$PORT" || true)
fi
export KUBECONFIG="$WORK/admin.kubeconfig"

show "kubectl config current-context" "kubectl config current-context"
if [ "$(kubectl config current-context)" != "$CTX" ]; then
  echo "refusing: current context is not $CTX" >&2
  exit 2
fi

show "kubectl taint nodes $NODE node-role.kubernetes.io/control-plane:NoSchedule-" \
  "kubectl taint nodes $NODE node-role.kubernetes.io/control-plane:NoSchedule-"
fi
show "kubectl get nodes -o wide" "kubectl get nodes -o wide"
show "docker exec $NODE grep -n audit /etc/kubernetes/manifests/kube-apiserver.yaml" \
  "docker exec $NODE grep -n audit /etc/kubernetes/manifests/kube-apiserver.yaml"

##@ Namespaces and identities

apply_lab_objects

make_kubeconfig builder "$(kubectl create token builder -n attack --duration=30m)"
show "kubectl --kubeconfig=work/builder.kubeconfig auth whoami" \
  "KUBECONFIG=$WORK/builder.kubeconfig kubectl auth whoami"

##@ Attack round 1: the attacks from 05.01 and 05.02, with the audit log on

show "kubectl --kubeconfig=work/builder.kubeconfig get secret app-db -n p05-08-app" \
  "KUBECONFIG=$WORK/builder.kubeconfig kubectl get secret app-db -n p05-08-app"

write_escape_node
show "kubectl --kubeconfig=work/builder.kubeconfig apply -f escape-node.yaml" \
  "KUBECONFIG=$WORK/builder.kubeconfig kubectl apply -f $WORK/escape-node.yaml"
show "kubectl wait --for=condition=Ready pod/escape-node -n attack --timeout=180s" \
  "kubectl wait --for=condition=Ready pod/escape-node -n attack --timeout=180s"

show "kubectl --kubeconfig=work/builder.kubeconfig exec -n attack escape-node -- sh -c 'test -s /var/run/secrets/kubernetes.io/serviceaccount/token && echo token-file-present'" \
  "KUBECONFIG=$WORK/builder.kubeconfig kubectl exec -n attack escape-node -- sh -c 'test -s /var/run/secrets/kubernetes.io/serviceaccount/token && echo token-file-present'"

OPS_TOKEN=$(KUBECONFIG="$WORK/builder.kubeconfig" kubectl exec -n attack escape-node -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token)
make_kubeconfig ops "$OPS_TOKEN"
show "kubectl --kubeconfig=work/ops.kubeconfig get secret app-db -n p05-08-app -o name" \
  "KUBECONFIG=$WORK/ops.kubeconfig kubectl get secret app-db -n p05-08-app -o name"

show "kubectl --kubeconfig=work/builder.kubeconfig exec -n attack escape-node -- sh -c 'cat /host/etc/hostname; touch /host/tmp/p05-08-marker && echo marker-written'" \
  "KUBECONFIG=$WORK/builder.kubeconfig kubectl exec -n attack escape-node -- sh -c 'cat /host/etc/hostname; touch /host/tmp/p05-08-marker && echo marker-written'"

##@ Query the audit log

if [ "$LAB_MODE" != shared ]; then

show "docker exec $NODE cat /var/log/kubernetes/kube-apiserver-audit.log > work/audit.log" \
  "docker exec $NODE cat /var/log/kubernetes/kube-apiserver-audit.log > $WORK/audit.log"
show "wc -l < work/audit.log" "wc -l < $WORK/audit.log"

show "query: who asked for the Secret, and what came back" \
  "query_audit secrets"
show "query: Pods created or deleted in the lab namespaces" \
  "query_audit pods"
show "query: exec sessions in the lab namespaces" \
  "query_audit exec"
show "query: ServiceAccount tokens minted" \
  "query_audit tokens"
show "query: requests refused with 403" \
  "query_audit refused"
fi

##@ Harden: restricted refuses the escape, and the refusal is logged

cat > "$WORK/escape-app.yaml" <<'YAML'
# INSECURE ON PURPOSE: the same privileged Pod, aimed at the restricted namespace, which refuses it. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-app
  namespace: p05-08-app
spec:
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "1800"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: node-root
          mountPath: /host
  volumes:
    - name: node-root
      hostPath:
        path: /
        type: Directory
YAML
show "kubectl apply -f escape-app.yaml" "kubectl apply -f $WORK/escape-app.yaml"
show "kubectl --kubeconfig=work/builder.kubeconfig auth can-i create pods -n p05-08-app" \
  "KUBECONFIG=$WORK/builder.kubeconfig kubectl auth can-i create pods -n p05-08-app"
if [ "$LAB_MODE" != shared ]; then
show "query: requests refused with 403" "query_audit refused"
fi

##@ Charts: the versions, the settings the installs render with, and a restricted probe (no install)

show "helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update" \
  "helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update"
show "helm repo add aqua https://aquasecurity.github.io/helm-charts/ --force-update" \
  "helm repo add aqua https://aquasecurity.github.io/helm-charts/ --force-update"
show "helm show chart falcosecurity/falco --version 9.2.2 | grep -E '^(version|appVersion)'" \
  "helm show chart falcosecurity/falco --version 9.2.2 | grep -E '^(version|appVersion)'"
show "helm show chart aqua/trivy-operator --version 0.38.1 | grep -E '^(version|appVersion)'" \
  "helm show chart aqua/trivy-operator --version 0.38.1 | grep -E '^(version|appVersion)'"
show "kubectl -n kube-system get daemonset -o name" "kubectl -n kube-system get daemonset -o name"

cat > "$WORK/falco-driver.yaml" <<'YAML'
driver:
  kind: modern_ebpf
  modernEbpf:
    leastPrivileged: true
YAML
show "helm template falco falcosecurity/falco --version 9.2.2 --namespace falco -f falco-driver.yaml > falco-rendered.yaml" \
  "helm template falco falcosecurity/falco --version 9.2.2 --namespace falco -f $WORK/falco-driver.yaml > $WORK/falco-rendered.yaml"
show "grep -c 'privileged: true' falco-rendered.yaml" "grep -c 'privileged: true' $WORK/falco-rendered.yaml"
show "grep -A5 'capabilities:' falco-rendered.yaml | head -6" "grep -A5 'capabilities:' $WORK/falco-rendered.yaml | head -6"

write_trivy_values
show "helm template trivy aqua/trivy-operator --version 0.38.1 --namespace p05-08-trivy -f trivy-values.yaml > trivy-rendered.yaml" \
  "helm template trivy aqua/trivy-operator --version 0.38.1 --namespace p05-08-trivy -f $WORK/trivy-values.yaml > $WORK/trivy-rendered.yaml"
show "grep -c 'runAsNonRoot: true' trivy-rendered.yaml" "grep -c 'runAsNonRoot: true' $WORK/trivy-rendered.yaml"

cat > "$WORK/trivy-ns.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: p05-08-trivy
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
YAML
show "kubectl apply -f trivy-ns.yaml" "kubectl apply -f $WORK/trivy-ns.yaml"
cat > "$WORK/operator-probe.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: operator-probe
  namespace: p05-08-trivy
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10000
    runAsGroup: 10000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: operator
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        privileged: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - mountPath: /tmp
          name: cache-policies
  volumes:
    - name: cache-policies
      emptyDir: {}
YAML
sed '/runAsNonRoot: true/d' "$WORK/operator-probe.yaml" > "$WORK/operator-probe-root.yaml"
show "kubectl apply --dry-run=server -f operator-probe.yaml; echo \"server dry-run exit=\$?\"" \
  "cd $WORK && kubectl apply --dry-run=server -f operator-probe.yaml; echo \"server dry-run exit=\$?\""
show "kubectl apply --dry-run=server -f operator-probe-root.yaml; echo \"server dry-run exit=\$?\"" \
  "cd $WORK && kubectl apply --dry-run=server -f operator-probe-root.yaml; echo \"server dry-run exit=\$?\""

if [ "$LAB_MODE" != shared ]; then
CP0=$(cp_restarts)
for s in F2 F3 F4 F5 F6 F7; do "step_$s" || exit 1; done
fi

##@ Respond: a compromised Pod

show "kubectl label pod escape-node -n attack quarantine=true" \
  "kubectl label pod escape-node -n attack quarantine=true"
show "kubectl exec -n attack escape-node -- nslookup kubernetes.default.svc.cluster.local | expand -t 4" \
  "kubectl exec -n attack escape-node -- nslookup kubernetes.default.svc.cluster.local | expand -t 4"

cat > "$WORK/quarantine.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: quarantine
  namespace: attack
spec:
  podSelector:
    matchLabels:
      quarantine: "true"
  policyTypes:
    - Ingress
    - Egress
YAML
show "kubectl apply -f quarantine.yaml" "kubectl apply -f $WORK/quarantine.yaml"
show "kubectl exec -n attack escape-node -- nslookup kubernetes.default.svc.cluster.local | expand -t 4" \
  "kubectl exec -n attack escape-node -- nslookup kubernetes.default.svc.cluster.local | expand -t 4"

mkdir -p "$WORK/evidence"
show "kubectl get pod escape-node -n attack -o yaml > evidence/pod.yaml" \
  "kubectl get pod escape-node -n attack -o yaml > $WORK/evidence/pod.yaml"
show "kubectl get events -n attack > evidence/events.txt" \
  "kubectl get events -n attack > $WORK/evidence/events.txt"
show "kubectl describe pod escape-node -n attack > evidence/describe.txt" \
  "kubectl describe pod escape-node -n attack > $WORK/evidence/describe.txt"
show "kubectl logs escape-node -n attack > evidence/logs.txt" \
  "kubectl logs escape-node -n attack > $WORK/evidence/logs.txt"
if [ "$LAB_MODE" != shared ]; then
show "query: exec and create events for escape-node, from the audit log" \
  "query_audit exec > $WORK/evidence/audit-exec.txt; cat $WORK/evidence/audit-exec.txt"
fi
show "ls -1 evidence" "ls -1 $WORK/evidence"

if [ "$LAB_MODE" != shared ]; then
show "kubectl cordon $NODE" "kubectl cordon $NODE"
fi

show "kubectl delete rolebinding ops-secret-reader -n p05-08-app" \
  "kubectl delete rolebinding ops-secret-reader -n p05-08-app"
show "kubectl delete pod escape-node -n attack" \
  "kubectl delete pod escape-node -n attack --wait=true"
show "kubectl --kubeconfig=work/ops.kubeconfig get secret app-db -n p05-08-app -o name" \
  "KUBECONFIG=$WORK/ops.kubeconfig kubectl get secret app-db -n p05-08-app -o name"
show "kubectl --kubeconfig=work/ops.kubeconfig auth whoami" \
  "KUBECONFIG=$WORK/ops.kubeconfig kubectl auth whoami"

show "kubectl delete serviceaccount builder -n attack" \
  "kubectl delete serviceaccount builder -n attack"
cat > "$WORK/builder-sa.yaml" <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: builder
  namespace: attack
YAML
show "kubectl apply -f builder-sa.yaml" "kubectl apply -f $WORK/builder-sa.yaml"
show "kubectl --kubeconfig=work/builder.kubeconfig auth whoami" \
  "KUBECONFIG=$WORK/builder.kubeconfig kubectl auth whoami"

show "kubectl patch secret app-db -n p05-08-app --type merge -p '{\"stringData\":{\"password\":\"lab-rotated-value\"}}'" \
  "kubectl patch secret app-db -n p05-08-app --type merge -p '{\"stringData\":{\"password\":\"lab-rotated-value\"}}'"

# No uncordon: the escape reached the node's root, so the node is replaced, not
# returned to service.

##@ Cleanup: remove what the lab installed, then the throwaway cluster

show "kubectl delete namespace attack p05-08-app falco p05-08-trivy" \
  "kubectl delete namespace attack p05-08-app falco p05-08-trivy --ignore-not-found --wait=true"
if [ "$LAB_MODE" != shared ]; then
show "$KIND_BIN delete cluster --name p05-08" "on_host '$KIND_BIN delete cluster --name $CLUSTER'"
show "$KIND_BIN get clusters" "on_host '$KIND_BIN get clusters'"
fi
