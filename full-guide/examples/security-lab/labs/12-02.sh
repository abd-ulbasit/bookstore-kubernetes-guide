#!/usr/bin/env bash
# Lab 12.02: GPUs and accelerators. Tier A (kind), CPU only.
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. It creates one namespace, p12-02-gpu, labelled restricted the way
# chapter 12.01 labels bookstore-ml, and deletes it at the end. It applies the
# chapter's GPU Job with only the namespace replaced.
#
# The lab never installs the GPU Operator: this cluster has no GPU. The
# chapter's GPU steps are cited, not run. Step 5 reads the operator's own
# DaemonSet sources at a pinned release, and the chart render, to show which
# parts need host access. Nothing is created on a cloud provider.
set +e

K="${KUBECTL:-kubectl}"
NS=p12-02-gpu
MANI=examples/bookstore/ml/gpu/recommender-train-gpu.yaml
CUDA=nvidia/cuda@sha256:0f6bfcbf267e65123bcc2287e2153dedfc0f24772fb5ce84afe16ac4b2fada95
CHART=v26.7.2

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

WORK=$(mktemp -d)
export HELM_REPOSITORY_CONFIG="$WORK/repositories.yaml"
export HELM_REPOSITORY_CACHE="$WORK/cache"
trap 'rm -rf "$WORK"' EXIT

# Print a command the way a reader would type it, then run it.
show() { printf '$ %s\n' "$*"; }

# The example file names bookstore-ml. This lab applies the same file with only
# the namespace replaced, so the Job lands in its own namespace.
mani_in_lab() { sed "s/namespace: bookstore-ml/namespace: $NS/" "$MANI"; }

echo "## step 0: versions, the cluster, the image pin and the GPU column"
show "kubectl version"
"$K" version 2>&1 | grep -E 'Client Version|Server Version'
show "kubectl get nodes (GPU column)"
"$K" get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu' 2>&1
show "kubectl get nodes (taints)"
"$K" get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints' 2>&1
show "docker buildx imagetools inspect nvidia/cuda:12.4.1-base-ubuntu22.04 (digest)"
docker buildx imagetools inspect nvidia/cuda:12.4.1-base-ubuntu22.04 2>&1 | grep '^Digest:'
show "docker buildx imagetools inspect ... (declared user)"
docker buildx imagetools inspect nvidia/cuda:12.4.1-base-ubuntu22.04 --format '{{json .Image}}' 2>/dev/null \
  | jq -r '."linux/amd64".config.User // "<no USER declared>"'
echo

echo "## step 1: a restricted namespace, labelled as chapter 12.01 labels bookstore-ml"
show "kubectl get namespace $NS"
"$K" get namespace "$NS" 2>&1
if "$K" get namespace "$NS" >/dev/null 2>&1; then
  echo "refusing to run: namespace $NS already exists" >&2
  exit 2
fi
show "kubectl create namespace $NS"
"$K" create namespace "$NS"
show "kubectl label namespace $NS (restricted, enforce audit warn, version latest)"
"$K" label namespace "$NS" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest --overwrite
echo

echo "## step 2: deliberate denial, a root-default CUDA image with no securityContext"
show "kubectl run gpu-root-test -n $NS --image=$CUDA --restart=Never -- nvidia-smi"
"$K" run gpu-root-test -n "$NS" --image="$CUDA" --restart=Never -- nvidia-smi 2>&1
show "kubectl get pods -n $NS"
"$K" get pods -n "$NS" 2>&1
echo

echo "## step 3: the restricted GPU Job, checked by the client and by the server"
show "kubectl apply --dry-run=client -f $MANI (namespace $NS)"
mani_in_lab | "$K" apply --dry-run=client -f - 2>&1
show "kubectl apply --dry-run=server -n $NS -f $MANI (namespace $NS)"
mani_in_lab | "$K" apply --dry-run=server -n "$NS" -f - 2>&1
echo

echo "## step 4: the same Job applied to a cluster with no GPU"
show "kubectl apply -n $NS -f $MANI (namespace $NS)"
mani_in_lab | "$K" apply -n "$NS" -f - 2>&1
show "kubectl wait pod -n $NS -l job-name=recommender-train-gpu --for=create --timeout=60s"
"$K" wait pod -n "$NS" -l job-name=recommender-train-gpu --for=create --timeout=60s 2>&1
show "kubectl wait pod -n $NS -l job-name=recommender-train-gpu --for=condition=PodScheduled=False --timeout=120s"
"$K" wait pod -n "$NS" -l job-name=recommender-train-gpu --for=condition=PodScheduled=False --timeout=120s 2>&1
show "kubectl get pods -n $NS"
"$K" get pods -n "$NS" 2>&1
show "kubectl get events -n $NS --field-selector reason=FailedScheduling"
"$K" get events -n "$NS" --field-selector reason=FailedScheduling \
  -o custom-columns='REASON:.reason,MESSAGE:.message' 2>&1
echo

echo "## step 5: where the GPU stack needs host access (chart render and operator sources)"
show "helm show chart nvidia/gpu-operator --version $CHART"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>&1 | tail -1
helm repo update nvidia >/dev/null 2>&1
helm show chart nvidia/gpu-operator --version "$CHART" 2>&1 | grep -E '^(version|appVersion):'
show "helm template gpu-operator nvidia/gpu-operator --version $CHART -n gpu-operator"
helm template gpu-operator nvidia/gpu-operator --version "$CHART" -n gpu-operator > "$WORK/render.yaml" 2>"$WORK/render.err"
echo "render exit: $?"
echo "privileged: true in the render: $(grep -c 'privileged: true' "$WORK/render.yaml")"
echo "hostPath volumes in the render: $(grep -c 'hostPath:' "$WORK/render.yaml")"
show "curl the $CHART DaemonSet sources and count their host access"
for f in state-driver/0500_daemonset.yaml state-container-toolkit/0500_daemonset.yaml \
         state-device-plugin/0500_daemonset.yaml state-dcgm-exporter/0800_daemonset.yaml \
         gpu-feature-discovery/0500_daemonset.yaml; do
  out="$WORK/$(echo "$f" | tr / _)"
  curl -fsS -m 60 -o "$out" "https://raw.githubusercontent.com/NVIDIA/gpu-operator/$CHART/assets/$f" 2>&1
  printf '%-44s privileged=%s hostPID=%s hostPath=%s\n' "$f" \
    "$(grep -c 'privileged: true' "$out")" \
    "$(grep -c 'hostPID: true' "$out")" \
    "$(grep -c 'hostPath:' "$out")"
done
echo

echo "## step 6: clean up the lab namespace"
show "kubectl delete namespace $NS"
"$K" delete namespace "$NS" --wait=true 2>&1
show "kubectl get namespace $NS"
"$K" get namespace "$NS" 2>&1
exit 0
