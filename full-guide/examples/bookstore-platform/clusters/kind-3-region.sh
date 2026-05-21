#!/usr/bin/env bash
# Bookstore Platform v2 — Part 13 ch.01 / ch.03: spin up the three-region
# local kind topology that the platform runs across. Idempotent: re-runs after
# `kind delete` produce an identical set.
#
# What this creates:
#   bookstore-platform-us-east       (writer region for CNPG primary; 13.03)
#   bookstore-platform-eu-west       (CNPG replica region)
#   bookstore-platform-ap-southeast  (CNPG replica region)
#
# Each cluster:
#   - 1 control-plane node + 2 worker nodes
#   - PSA `restricted` baseline label on the kube-system + default ns are NOT
#     set (the platform's own namespaces handle PSA themselves — see
#     ../platform-base/00-namespaces.yaml; kube-system stays unlabelled so
#     cluster add-ons that need elevated capabilities still work).
#   - Distinct apiServerAddress + nodePort range per cluster so they coexist
#     on one machine.
#
# Honest scope: kind is the LOCAL stand-in for three real managed clusters
# (EKS/GKE/AKS) in three real regions, each in its own VPC, fronted by real
# DNS. This script proves the topology + apply path; it cannot simulate
# real cross-region latency, sovereign data residency, or the cloud LB
# behaviour. Those are documented in 13.03.
#
# Usage:
#   ./examples/bookstore-platform/clusters/kind-3-region.sh
#   kubectl config get-contexts | grep kind-bookstore-platform
#
# Teardown:
#   kind delete cluster --name bookstore-platform-us-east
#   kind delete cluster --name bookstore-platform-eu-west
#   kind delete cluster --name bookstore-platform-ap-southeast
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# REGIONS: name -> kind config file (kept on separate lines so this scans
# cleanly on a portable POSIX-ish shell; bash 3.x compatible).
create_cluster() {
  local name="$1"
  local cfg="$2"
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    echo "[skip] cluster $name already exists"
    return 0
  fi
  echo "[create] $name from $cfg"
  kind create cluster --name "$name" --config "$cfg" --wait 120s
}

create_cluster bookstore-platform-us-east       "${SCRIPT_DIR}/kind-us-east.yaml"
create_cluster bookstore-platform-eu-west       "${SCRIPT_DIR}/kind-eu-west.yaml"
create_cluster bookstore-platform-ap-southeast  "${SCRIPT_DIR}/kind-ap-southeast.yaml"

echo
echo "Contexts:"
kubectl config get-contexts -o name | grep '^kind-bookstore-platform-' || true
echo
echo "Next:"
echo "  kubectl --context kind-bookstore-platform-us-east apply -f examples/bookstore-platform/platform-base/"
echo "  kubectl --context kind-bookstore-platform-eu-west apply -f examples/bookstore-platform/platform-base/"
echo "  kubectl --context kind-bookstore-platform-ap-southeast apply -f examples/bookstore-platform/platform-base/"
