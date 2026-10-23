#!/usr/bin/env bash
# Post-create hook for the devcontainer. Installs the tools that aren't in
# the Dev Container Features registry and prints a friendly verification
# banner so the user knows what to do next.
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- kind ----------------------------------------------------------------
# Kubernetes-in-Docker — runs a Kubernetes cluster as Docker containers.
# Picked over minikube because the guide standardises on kind (it's lighter,
# and its node-image versioning matches the Kubernetes release calendar).
#
# Every download below is pinned to a version AND to a sha256 copied from the
# project's published checksums for that release (verified when pinned). A
# version pin alone trusts whatever the URL serves today; the hash makes the
# install fail if the bytes ever change. Bump both together.
verify() { echo "$1  $2" | sha256sum -c - >/dev/null || { echo "checksum mismatch: $2" >&2; exit 1; }; }

KIND_VERSION="v0.27.0"
KIND_SHA256="a6875aaea358acf0ac07786b1a6755d08fd640f4c79b7a2e46681cc13f49a04b"
log "installing kind ${KIND_VERSION}"
curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" \
  -o /tmp/kind
verify "${KIND_SHA256}" /tmp/kind
sudo install /tmp/kind /usr/local/bin/kind
rm /tmp/kind

# --- k3d -----------------------------------------------------------------
# The guide also uses k3d (k3s in Docker) for the multi-cluster section.
# Release binary + checksum. This used to pipe install.sh from the k3d repo's
# MAIN branch into bash: whatever that script said on the day ran as this
# user, regardless of the TAG pin it was given.
K3D_VERSION="v5.8.3"
K3D_SHA256="dbaa79a76ace7f4ca230a1ff41dc7d8a5036a8ad0309e9c54f9bf3836dbe853e"
log "installing k3d ${K3D_VERSION}"
curl -fsSL "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-amd64" \
  -o /tmp/k3d
verify "${K3D_SHA256}" /tmp/k3d
sudo install /tmp/k3d /usr/local/bin/k3d
rm /tmp/k3d

# --- kustomize (standalone) ---------------------------------------------
# kubectl ships an older bundled kustomize; the standalone binary tracks
# the latest features (e.g. components, the `helmCharts` field).
KUSTOMIZE_VERSION="v5.5.0"
KUSTOMIZE_SHA256="6703a3a70a0c47cf0b37694030b54f1175a9dfeb17b3818b623ed58b9dbc2a77"
log "installing kustomize ${KUSTOMIZE_VERSION}"
curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
  -o /tmp/kustomize.tar.gz
verify "${KUSTOMIZE_SHA256}" /tmp/kustomize.tar.gz
sudo tar -xzf /tmp/kustomize.tar.gz -C /usr/local/bin kustomize
sudo chmod +x /usr/local/bin/kustomize
rm /tmp/kustomize.tar.gz

# --- yq + jq -------------------------------------------------------------
# jq is usually present on the base image; double-check. yq is not.
log "installing jq + yq"
sudo apt-get update -qq
sudo apt-get install -y -qq jq
YQ_VERSION="v4.40.5"
YQ_SHA256="0d6aaf1cf44a8d18fbc7ed0ef14f735a8df8d2e314c4cc0f0242d35c0a440c95"
curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
  -o /tmp/yq
verify "${YQ_SHA256}" /tmp/yq
sudo install /tmp/yq /usr/local/bin/yq
rm /tmp/yq

# --- MkDocs Material + plugins ------------------------------------------
# So `mkdocs serve` works for live-previewing the docs site at :8000.
log "installing mkdocs + plugins"
pip install --user --quiet -r requirements.txt

# --- friendly banner ----------------------------------------------------
cat <<'EOF'

╭──────────────────────────────────────────────────────────────────────╮
│  Bookstore Kubernetes Guide — dev container ready.                    │
╰──────────────────────────────────────────────────────────────────────╯

Versions installed:
  kubectl     1.35.0
  helm        3.16.0
  kustomize   5.5.0
  terraform   1.10.5
  kind        0.27.0
  k3d         5.8.3
  go          1.26.10
  python      3.12
  aws-cli     2.38.5
  node        24

Quick verifications:
  kubectl version --client
  helm version
  terraform version

Start a local cluster:
  kind create cluster --name bookstore

Preview the docs site (port 8000 is auto-forwarded by Codespaces):
  mkdocs serve -a 0.0.0.0:8000

Deploy the canonical Bookstore example into your kind cluster:
  helm install bookstore full-guide/examples/bookstore/helm/bookstore

Live site:
  https://abd-ulbasit.github.io/bookstore-kubernetes-guide/

EOF
