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
KIND_VERSION="v0.27.0"
log "installing kind ${KIND_VERSION}"
curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" \
  -o /tmp/kind
sudo install /tmp/kind /usr/local/bin/kind
rm /tmp/kind

# --- k3d -----------------------------------------------------------------
# The guide also uses k3d (k3s in Docker) for the multi-cluster section.
log "installing k3d"
curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
  | TAG=v5.8.3 bash >/dev/null

# --- kustomize (standalone) ---------------------------------------------
# kubectl ships an older bundled kustomize; the standalone binary tracks
# the latest features (e.g. components, the `helmCharts` field).
KUSTOMIZE_VERSION="v5.5.0"
log "installing kustomize ${KUSTOMIZE_VERSION}"
curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
  | sudo tar -xz -C /usr/local/bin kustomize
sudo chmod +x /usr/local/bin/kustomize

# --- yq + jq -------------------------------------------------------------
# jq is usually present on the base image; double-check. yq is not.
log "installing jq + yq"
sudo apt-get update -qq
sudo apt-get install -y -qq jq
YQ_VERSION="v4.40.5"
sudo curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
  -o /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq

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
  go          1.22
  python      3.12
  aws-cli     v2 (latest)

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
