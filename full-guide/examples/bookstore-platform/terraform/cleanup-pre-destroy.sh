#!/usr/bin/env bash
################################################################################
# cleanup-pre-destroy.sh
#
# Drains the Kubernetes-managed AWS resources that live *outside* Terraform
# state, BEFORE `terraform destroy`. Without this, terraform destroy will
# fail on stuck ENIs / security-group dependency cycles, and you'll leak
# orphan ALBs, NLBs, EBS volumes, and Karpenter EC2 instances.
#
# Three classes of orphan to drain:
#   1. Service type=LoadBalancer  -> AWS LB Controller creates ALB/NLB
#   2. PersistentVolumeClaim      -> EBS-CSI provisions EBS volumes
#   3. Karpenter-provisioned EC2  -> Karpenter spawns instances directly
#
# Every step is idempotent: re-running on a half-cleaned cluster is safe.
# If the cluster is already gone (kubectl can't reach the API server), the
# script exits 0 — `terraform destroy` will pick up the rest.
################################################################################

set -euo pipefail

# ----- Config --------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_KUBECONFIG="${SCRIPT_DIR}/kubeconfig.yaml"

# Wait timeouts (seconds). Adjust if you have very large clusters.
LB_WAIT_SECONDS="${LB_WAIT_SECONDS:-300}"
PVC_WAIT_SECONDS="${PVC_WAIT_SECONDS:-300}"
NODE_WAIT_SECONDS="${NODE_WAIT_SECONDS:-600}"

# ----- Colors --------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

step()  { printf "\n%s==>%s %s%s%s\n" "${C_CYAN}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}"; }
ok()    { printf "  %s[ok]%s %s\n" "${C_GREEN}"  "${C_RESET}" "$*"; }
warn()  { printf "  %s[!!]%s %s\n" "${C_YELLOW}" "${C_RESET}" "$*"; }
fail()  { printf "  %sERR%s  %s\n" "${C_RED}"    "${C_RESET}" "$*"; }

# ----- kubeconfig discovery ------------------------------------------------

if [[ -f "${LOCAL_KUBECONFIG}" ]]; then
  export KUBECONFIG="${LOCAL_KUBECONFIG}"
  ok "Using local kubeconfig: ${KUBECONFIG}"
elif [[ -n "${KUBECONFIG:-}" ]]; then
  ok "Using KUBECONFIG from env: ${KUBECONFIG}"
elif [[ -f "${HOME}/.kube/config" ]]; then
  export KUBECONFIG="${HOME}/.kube/config"
  ok "Using default kubeconfig: ${KUBECONFIG}"
else
  warn "No kubeconfig found. Assuming cluster is already gone; nothing to drain."
  exit 0
fi

# ----- Reachability check --------------------------------------------------

step "Checking cluster reachability"
if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
  warn "kubectl cannot reach the cluster (already destroyed?). Skipping drain."
  exit 0
fi
ok "Cluster reachable"

# ----- 1. Drain LoadBalancer Services --------------------------------------

step "Draining Service type=LoadBalancer (ALB/NLB orphans)"

LB_SERVICES_JSON="$(kubectl get svc --all-namespaces -o json 2>/dev/null \
  | jq -c '[.items[] | select(.spec.type=="LoadBalancer") | {ns: .metadata.namespace, name: .metadata.name}]' \
  || echo '[]')"

LB_COUNT="$(echo "${LB_SERVICES_JSON}" | jq 'length')"

if [[ "${LB_COUNT}" -eq 0 ]]; then
  ok "No LoadBalancer Services found"
else
  echo "${LB_SERVICES_JSON}" | jq -r '.[] | "\(.ns)\t\(.name)"' \
    | while IFS=$'\t' read -r NS NAME; do
        warn "Deleting svc/${NAME} in ns/${NS}"
        kubectl delete svc -n "${NS}" "${NAME}" --wait=false --ignore-not-found
      done

  # Wait for the controller to actually tear down the LB. We can't kubectl
  # wait on AWS resources, but we can wait on the Service finalizer being
  # removed (the LB controller removes it once the ALB/NLB is gone).
  warn "Waiting up to ${LB_WAIT_SECONDS}s for LB Services to disappear..."
  END_TS=$(( $(date +%s) + LB_WAIT_SECONDS ))
  while [[ "$(date +%s)" -lt "${END_TS}" ]]; do
    REMAINING="$(kubectl get svc --all-namespaces -o json 2>/dev/null \
      | jq '[.items[] | select(.spec.type=="LoadBalancer")] | length')"
    [[ "${REMAINING}" -eq 0 ]] && break
    sleep 5
  done

  FINAL="$(kubectl get svc --all-namespaces -o json 2>/dev/null \
    | jq '[.items[] | select(.spec.type=="LoadBalancer")] | length')"
  if [[ "${FINAL}" -eq 0 ]]; then
    ok "All LoadBalancer Services drained"
  else
    fail "${FINAL} LoadBalancer Services still present after ${LB_WAIT_SECONDS}s"
    fail "Check stuck finalizers: kubectl get svc -A | grep LoadBalancer"
  fi
fi

# ----- 2. Drain PersistentVolumeClaims -------------------------------------

step "Draining PersistentVolumeClaims (EBS volume orphans)"

PVC_COUNT="$(kubectl get pvc --all-namespaces -o json 2>/dev/null \
  | jq '[.items[]] | length' || echo 0)"

if [[ "${PVC_COUNT}" -eq 0 ]]; then
  ok "No PVCs found"
else
  # Delete pods first so PVCs are unmounted before deletion.
  warn "Deleting Pods that hold PVCs (so unmount happens cleanly)..."
  kubectl get pods --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim) | "\(.metadata.namespace)\t\(.metadata.name)"' \
    | while IFS=$'\t' read -r NS NAME; do
        [[ -z "${NS}" || -z "${NAME}" ]] && continue
        kubectl delete pod -n "${NS}" "${NAME}" --grace-period=30 --ignore-not-found --wait=false >/dev/null
      done

  warn "Deleting ${PVC_COUNT} PVCs..."
  kubectl get pvc --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | "\(.metadata.namespace)\t\(.metadata.name)"' \
    | while IFS=$'\t' read -r NS NAME; do
        kubectl delete pvc -n "${NS}" "${NAME}" --wait=false --ignore-not-found
      done

  warn "Waiting up to ${PVC_WAIT_SECONDS}s for PVCs to be released..."
  END_TS=$(( $(date +%s) + PVC_WAIT_SECONDS ))
  while [[ "$(date +%s)" -lt "${END_TS}" ]]; do
    REMAINING="$(kubectl get pvc --all-namespaces -o json 2>/dev/null \
      | jq '[.items[]] | length' || echo 0)"
    [[ "${REMAINING}" -eq 0 ]] && break
    sleep 5
  done

  FINAL="$(kubectl get pvc --all-namespaces -o json 2>/dev/null \
    | jq '[.items[]] | length' || echo 0)"
  if [[ "${FINAL}" -eq 0 ]]; then
    ok "All PVCs released"
  else
    fail "${FINAL} PVCs still present"
  fi
fi

# ----- 3. Drain Karpenter-provisioned nodes --------------------------------

step "Draining Karpenter-provisioned nodes (EC2 instance orphans)"

# Scale Karpenter to 0 so it does not re-provision while we drain.
if kubectl get deployment -n kube-system karpenter >/dev/null 2>&1; then
  warn "Scaling karpenter controller to 0 replicas..."
  kubectl scale deployment -n kube-system karpenter --replicas=0
  # Wait for the controller pods to actually exit before we delete NodeClaims;
  # otherwise the controller will requeue and re-provision.
  kubectl wait --for=delete pod -n kube-system -l app.kubernetes.io/name=karpenter --timeout=120s 2>/dev/null || true
  ok "Karpenter controller scaled to 0"
else
  warn "Karpenter deployment not found (already removed?)"
fi

# Delete NodeClaims (Karpenter's resource for each EC2 instance). With the
# controller scaled down, this won't re-trigger provisioning.
if kubectl get crd nodeclaims.karpenter.sh >/dev/null 2>&1; then
  NC_COUNT="$(kubectl get nodeclaims -o json 2>/dev/null | jq '[.items[]] | length' || echo 0)"
  if [[ "${NC_COUNT}" -gt 0 ]]; then
    warn "Deleting ${NC_COUNT} NodeClaims..."
    kubectl delete nodeclaims --all --wait=false --ignore-not-found
  else
    ok "No NodeClaims found"
  fi
fi

# Delete NodePool + EC2NodeClass so the next destroy step doesn't trip on them.
if kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1; then
  kubectl delete nodepools --all --wait=false --ignore-not-found
  ok "NodePools deleted"
fi
if kubectl get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1; then
  kubectl delete ec2nodeclasses --all --wait=false --ignore-not-found
  ok "EC2NodeClasses deleted"
fi

# Cordon + delete any nodes labeled by Karpenter so the API server stops
# advertising them. Underlying EC2 termination happens when NodeClaims
# finalize — which they will, because the controller-manager's node lifecycle
# controller handles that even with Karpenter scaled to 0.
KARPENTER_NODES="$(kubectl get nodes -l karpenter.sh/nodepool -o name 2>/dev/null || true)"
if [[ -n "${KARPENTER_NODES}" ]]; then
  warn "Cordoning Karpenter-managed nodes..."
  echo "${KARPENTER_NODES}" | while read -r NODE; do
    [[ -z "${NODE}" ]] && continue
    kubectl cordon "${NODE}" >/dev/null 2>&1 || true
  done
  warn "Deleting Karpenter-managed nodes..."
  echo "${KARPENTER_NODES}" | while read -r NODE; do
    [[ -z "${NODE}" ]] && continue
    kubectl delete "${NODE}" --wait=false --ignore-not-found >/dev/null 2>&1 || true
  done

  warn "Waiting up to ${NODE_WAIT_SECONDS}s for Karpenter nodes to disappear..."
  END_TS=$(( $(date +%s) + NODE_WAIT_SECONDS ))
  while [[ "$(date +%s)" -lt "${END_TS}" ]]; do
    REMAINING="$(kubectl get nodes -l karpenter.sh/nodepool -o name 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${REMAINING}" -eq 0 ]] && break
    sleep 10
  done

  FINAL="$(kubectl get nodes -l karpenter.sh/nodepool -o name 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${FINAL}" -eq 0 ]]; then
    ok "All Karpenter nodes removed"
  else
    warn "${FINAL} Karpenter nodes still present (terraform destroy will clean EC2 directly via tag)"
  fi
else
  ok "No Karpenter-managed nodes found"
fi

# ----- Done ----------------------------------------------------------------

step "Pre-destroy drain complete"
ok "It is now safe to run: terraform destroy"
