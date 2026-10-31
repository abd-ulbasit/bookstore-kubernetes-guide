#!/usr/bin/env bash
# Lab 12.05: notebooks and interactive ML. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. It creates one namespace, p12-05-jupyter, labels it restricted,
# stores the demo login Secret, renders the Zero-to-JupyterHub chart with the
# chapter's values file and server-dry-runs the result, then checks the
# notebook Pod shape, a deliberately refused variant and the fleet quota. It
# does not install the hub. It deletes the namespace at the end.
#
# The chapter names the jupyter namespace; this script uses p12-05-jupyter.
# Set VALUES to a copy of the chapter's jupyterhub-values.yaml. The example Pod
# is read from this tree with only the namespace name replaced.
set +e

K="${KUBECTL:-kubectl}"
H="${HELM:-helm}"
NS=p12-05-jupyter
VALUES="${VALUES:?set VALUES to a copy of the jupyterhub-values.yaml file}"
POD=examples/bookstore/ml/notebook/singleuser-restricted-podtemplate.yaml

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

# Print a command the way a reader would type it, then run it.
show() { printf '$ %s\n' "$*"; }

echo "## step 0: versions and the chart"
show "kubectl version"
"$K" version
show "helm show chart jupyterhub/jupyterhub --version 4.4.4"
"$H" show chart jupyterhub/jupyterhub --version 4.4.4

echo
echo "## step 1: a restricted namespace"
show "kubectl apply -f - <<'EOF'   # Namespace jupyter, labelled restricted"
cat <<YAML | "$K" apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
YAML
show "kubectl get namespace $NS --show-labels"
"$K" get namespace "$NS" --show-labels

echo
echo "## step 2: the hub's login Secret, created from a generated password"
# The password is generated and written to a temporary file, never printed.
tmp=$(mktemp "${TMPDIR:-/tmp}/hub-secret.XXXXXX")
umask 077
printf 'hub:\n  config:\n    SharedPasswordAuthenticator:\n      user_password: "%s"\n' \
  "$(openssl rand -hex 24)" > "$tmp"
show "kubectl create secret generic jupyterhub-hub-secrets -n $NS --from-file=values.yaml=<generated file>"
"$K" create secret generic jupyterhub-hub-secrets -n "$NS" --from-file=values.yaml="$tmp"
rm -f "$tmp"
show "kubectl get secret jupyterhub-hub-secrets -n $NS"
"$K" get secret jupyterhub-hub-secrets -n "$NS"

echo
echo "## step 3: the chart, rendered with the chapter's values, server dry run"
show "helm template jupyterhub jupyterhub/jupyterhub --version 4.4.4 -n $NS -f jupyterhub-values.yaml | kubectl apply --dry-run=server -n $NS -f -"
"$H" template jupyterhub jupyterhub/jupyterhub --version 4.4.4 --namespace "$NS" \
  -f "$VALUES" | "$K" apply --dry-run=server -n "$NS" -f -

echo
echo "## step 4: the notebook ServiceAccount, then the notebook Pod shape"
show "kubectl apply -f - <<'EOF'   # ServiceAccount jupyterhub-singleuser, no token"
cat <<YAML | "$K" apply -n "$NS" -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jupyterhub-singleuser
  namespace: $NS
automountServiceAccountToken: false
YAML
show "kubectl apply --dry-run=server -n $NS -f <the example notebook Pod>"
sed "s/^  namespace: jupyter$/  namespace: $NS/" "$POD" |
  "$K" apply --dry-run=server -n "$NS" -f -

echo
echo "## step 5: a deliberate refusal, the chart's default init container"
# With blockWithIptables left at its default, KubeSpawner adds this init
# container. It is privileged, runs as root and adds NET_ADMIN.
show "kubectl apply --dry-run=server -n $NS -f <Pod with the default init container>"
cat <<YAML | "$K" apply --dry-run=server -n "$NS" -f -
apiVersion: v1
kind: Pod
metadata:
  name: jupyter-singleuser-privileged-init
  namespace: $NS
  labels:
    app: jupyterhub
    component: singleuser-server
    release: jupyterhub
spec:
  serviceAccountName: jupyterhub-singleuser
  automountServiceAccountToken: false
  restartPolicy: OnFailure
  securityContext:
    runAsNonRoot: true
    fsGroup: 100
    seccompProfile:
      type: RuntimeDefault
  initContainers:
    - name: block-cloud-metadata
      image: quay.io/jupyterhub/k8s-network-tools:4.4.4@sha256:9253a270fd2627154b38aea8a43a12e5afbebeb0d0b7d4c13679301cd9a83a0c
      command: ["iptables", "--append", "OUTPUT", "--protocol", "tcp", "--destination", "169.254.169.254", "--destination-port", "80", "--jump", "DROP"]
      securityContext:
        privileged: true
        runAsUser: 0
        capabilities:
          add: ["NET_ADMIN"]
  containers:
    - name: notebook
      image: quay.io/jupyter/scipy-notebook:2024-08-12@sha256:a8925f5242a701edd718a4c1afc3bdeabb7dcb9ae6ff55116db790379a6f6e04
      args: ["start-singleuser.sh"]
      securityContext:
        runAsUser: 1000
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
YAML

echo
echo "## step 6: the fleet quota, server dry run"
show "kubectl create quota nb-quota --hard=requests.cpu=8,requests.memory=16Gi,requests.nvidia.com/gpu=2 -n $NS --dry-run=server"
"$K" create quota nb-quota --hard=requests.cpu=8,requests.memory=16Gi,requests.nvidia.com/gpu=2 \
  -n "$NS" --dry-run=server

echo
echo "## step 7: the cluster's network plugin, which decides whether NetworkPolicy is enforced"
show "kubectl get daemonset kindnet -n kube-system -o name"
"$K" get daemonset kindnet -n kube-system -o name

echo
echo "## step 8: cleanup"
show "kubectl delete namespace $NS --wait=true"
"$K" delete namespace "$NS" --wait=true
