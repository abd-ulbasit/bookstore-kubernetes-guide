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

# v0.33.0 defaults to kindest/node:v1.37.0, pinned by digest inside the
# binary, so a plain `kind create cluster` runs Kubernetes 1.37.
KIND_VERSION="v0.33.0"
KIND_SHA256="aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d"
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
#
# k3d bakes its default k3s image in at build time, and v5.9.0's default is
# k3s v1.35.5, so create clusters with `--image rancher/k3s:v1.37.1-k3s1`
# to get Kubernetes 1.37.
K3D_VERSION="v5.9.0"
K3D_SHA256="06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0"
log "installing k3d ${K3D_VERSION}"
curl -fsSL "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-amd64" \
  -o /tmp/k3d
verify "${K3D_SHA256}" /tmp/k3d
sudo install /tmp/k3d /usr/local/bin/k3d
rm /tmp/k3d

# --- kustomize (standalone) ---------------------------------------------
# kubectl 1.37.2 embeds kustomize v5.8.1, but `kubectl kustomize` is only
# the build command. The standalone binary adds `kustomize edit` and
# friends, and is pinned to the same release so both render identically.
KUSTOMIZE_VERSION="v5.8.1"
KUSTOMIZE_SHA256="029a7f0f4e1932c52a0476cf02a0fd855c0bb85694b82c338fc648dcb53a819d"
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
  kubectl     1.37.2
  helm        3.22.1
  kustomize   5.8.1
  terraform   1.14.8
  kind        0.33.0
  k3d         5.9.0
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
