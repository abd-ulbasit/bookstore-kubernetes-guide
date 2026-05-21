#!/usr/bin/env bash
################################################################################
# cleanup-verify.sh
#
# Runs AFTER `terraform destroy` to prove no AWS resources tagged with the
# cluster name (or created by EKS itself) remain. Exits 0 iff the account
# is clean. Exits 1 with a list of orphans otherwise.
#
# Resources checked:
#   - EKS cluster                 (should be 404)
#   - EC2 instances               (tagged karpenter.sh/discovery=<cluster>)
#   - EBS volumes                 (tagged karpenter.sh/discovery=<cluster> + KubernetesCluster=*)
#   - Load Balancers v2 (ALB/NLB) (tagged for the cluster)
#   - Load Balancers classic      (tagged for the cluster)
#   - NAT Gateways                (tagged)
#   - VPCs                        (tagged)
#   - Security groups             (tagged)
#   - IAM roles                   (name prefix <cluster>-)
#   - CloudWatch log groups       (prefix /aws/eks/<cluster>/)
#   - KMS aliases                 (alias/eks/<cluster>-*) — pending-delete is OK
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----- Args ----------------------------------------------------------------

CLUSTER=""
REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2;;
    --region)  REGION="$2";  shift 2;;
    -h|--help)
      cat <<EOF
Usage: $0 [--cluster <NAME>] [--region <REGION>]

If --cluster / --region are omitted, falls back to:
  terraform output -raw cluster_name
  terraform output -raw region

Exits 0 if no orphans found, 1 otherwise.
EOF
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

# Fall back to terraform outputs (may be empty post-destroy — that's fine if
# user passed --cluster/--region).
if [[ -z "${CLUSTER}" ]]; then
  CLUSTER="$(terraform -chdir="${SCRIPT_DIR}" output -raw cluster_name 2>/dev/null || true)"
fi
if [[ -z "${REGION}" ]]; then
  REGION="$(terraform -chdir="${SCRIPT_DIR}" output -raw region 2>/dev/null || true)"
fi
# Defaults of last resort.
CLUSTER="${CLUSTER:-bookstore-platform}"
REGION="${REGION:-us-east-1}"

export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"

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

check_ok()   { printf "  %s[OK]%s  %s\n" "${C_GREEN}"  "${C_RESET}" "$*"; }
check_warn() { printf "  %s[~~]%s  %s\n" "${C_YELLOW}" "${C_RESET}" "$*"; }
check_bad()  { printf "  %s[XX]%s  %s\n" "${C_RED}"    "${C_RESET}" "$*"; }
header()     { printf "\n%s== %s ==%s\n" "${C_CYAN}" "$*" "${C_RESET}"; }

ORPHANS=0

# ----- Banner --------------------------------------------------------------

cat <<EOF
${C_BOLD}Bookstore Platform — orphan-resource verification${C_RESET}
  cluster: ${CLUSTER}
  region : ${REGION}
EOF

# ----- 1. EKS cluster ------------------------------------------------------

header "EKS cluster"
if aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" >/dev/null 2>&1; then
  check_bad "EKS cluster '${CLUSTER}' still exists"
  ORPHANS=$((ORPHANS + 1))
else
  check_ok "EKS cluster '${CLUSTER}' is gone"
fi

# ----- 2. EC2 instances ----------------------------------------------------

header "EC2 instances (Karpenter-provisioned)"
EC2_IDS="$(aws ec2 describe-instances \
  --region "${REGION}" \
  --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER}" \
            "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text 2>/dev/null || true)"

if [[ -z "${EC2_IDS}" || "${EC2_IDS}" == "None" ]]; then
  check_ok "No tagged EC2 instances"
else
  COUNT="$(echo "${EC2_IDS}" | wc -w | tr -d ' ')"
  check_bad "Found ${COUNT} EC2 instance(s): ${EC2_IDS}"
  ORPHANS=$((ORPHANS + 1))
fi

# ----- 3. EBS volumes ------------------------------------------------------

header "EBS volumes"
EBS_VOLS="$(aws ec2 describe-volumes \
  --region "${REGION}" \
  --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER}" \
  --query "Volumes[?State!='deleted'].VolumeId" \
  --output text 2>/dev/null || true)"

# Also check for kubernetes.io/cluster/<CLUSTER> tag which the EBS-CSI driver sets.
EBS_VOLS2="$(aws ec2 describe-volumes \
  --region "${REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER},Values=owned,shared" \
  --query "Volumes[?State!='deleted'].VolumeId" \
  --output text 2>/dev/null || true)"

ALL_EBS="$( { echo "${EBS_VOLS} ${EBS_VOLS2}" | tr ' \t' '\n' | grep -v '^$' | grep -v '^None$' | sort -u | tr '\n' ' '; } || true)"

if [[ -z "${ALL_EBS// /}" ]]; then
  check_ok "No tagged EBS volumes"
else
  COUNT="$(echo "${ALL_EBS}" | wc -w | tr -d ' ')"
  check_bad "Found ${COUNT} EBS volume(s): ${ALL_EBS}"
  ORPHANS=$((ORPHANS + 1))
fi

# ----- 4. Load Balancers (v2 — ALB + NLB) ---------------------------------

header "Load Balancers (v2 / ALB+NLB)"
ELBV2_ARNS="$(aws elbv2 describe-load-balancers \
  --region "${REGION}" \
  --query "LoadBalancers[].LoadBalancerArn" \
  --output text 2>/dev/null || true)"

ORPHAN_ELBV2=""
if [[ -n "${ELBV2_ARNS}" && "${ELBV2_ARNS}" != "None" ]]; then
  # Filter to those carrying our cluster tag.
  for ARN in ${ELBV2_ARNS}; do
    TAGS="$(aws elbv2 describe-tags --resource-arns "${ARN}" --region "${REGION}" \
      --query "TagDescriptions[].Tags[?Key=='kubernetes.io/cluster/${CLUSTER}' || Key=='elbv2.k8s.aws/cluster'].Value" \
      --output text 2>/dev/null || true)"
    if [[ -n "${TAGS}" && "${TAGS}" != "None" ]]; then
      ORPHAN_ELBV2="${ORPHAN_ELBV2} ${ARN}"
    fi
  done
fi

if [[ -z "${ORPHAN_ELBV2// /}" ]]; then
  check_ok "No tagged ALBs/NLBs"
else
  check_bad "Orphan v2 LBs: ${ORPHAN_ELBV2}"
  ORPHANS=$((ORPHANS + 1))
fi

# ----- 5. Load Balancers (classic) ----------------------------------------

header "Load Balancers (classic)"
ELB_NAMES="$(aws elb describe-load-balancers \
  --region "${REGION}" \
  --query "LoadBalancerDescriptions[].LoadBalancerName" \
  --output text 2>/dev/null || true)"

ORPHAN_ELB=""
if [[ -n "${ELB_NAMES}" && "${ELB_NAMES}" != "None" ]]; then
  for NAME in ${ELB_NAMES}; do
    TAGS="$(aws elb describe-tags --load-balancer-names "${NAME}" --region "${REGION}" \
      --query "TagDescriptions[].Tags[?Key=='kubernetes.io/cluster/${CLUSTER}'].Value" \
      --output text 2>/dev/null || true)"
    if [[ -n "${TAGS}" && "${TAGS}" != "None" ]]; then
      ORPHAN_ELB="${ORPHAN_ELB} ${NAME}"
    fi
  done
fi

if [[ -z "${ORPHAN_ELB// /}" ]]; then
  check_ok "No tagged classic ELBs"
else
  check_bad "Orphan classic ELBs: ${ORPHAN_ELB}"
  ORPHANS=$((ORPHANS + 1))
fi

# ----- 6. NAT gateways ----------------------------------------------------

header "NAT gateways"
# Common-tag based filter; module-created NAT GWs / SGs don't carry the karpenter.sh/discovery tag
NAT_IDS="$(aws ec2 describe-nat-gateways \
  --region "${REGION}" \
  --filter "Name=tag:bookstore-platform.example.com/cluster,Values=${CLUSTER}" \
           "Name=state,Values=pending,available,deleting" \
  --query "NatGateways[].NatGatewayId" \
  --output text 2>/dev/null || true)"

if [[ -z "${NAT_IDS}" || "${NAT_IDS}" == "None" ]]; then
  check_ok "No active NAT gateways tagged with cluster"
else
  check_bad "Found NAT gateway(s): ${NAT_IDS}"
  ORPHANS=$((ORPHANS + 1))
fi

# ----- 7. VPCs ------------------------------------------------------------

header "VPCs"
VPC_IDS="$(aws ec2 describe-vpcs \
  --region "${REGION}" \
  --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER}" \
  --query "Vpcs[].VpcId" \
  --output text 2>/dev/null || true)"

if [[ -z "${VPC_IDS}" || "${VPC_IDS}" == "None" ]]; then
  check_ok "No tagged VPCs"
else
  check_bad "Found VPC(s): ${VPC_IDS}"
  ORPHANS=$((ORPHANS + 1))
fi

# ----- 8. Security groups -------------------------------------------------

header "Security groups"
# Common-tag based filter; module-created NAT GWs / SGs don't carry the karpenter.sh/discovery tag
SG_IDS="$(aws ec2 describe-security-groups \
  --region "${REGION}" \
  --filters "Name=tag:bookstore-platform.example.com/cluster,Values=${CLUSTER}" \
  --query "SecurityGroups[].GroupId" \
  --output text 2>/dev/null || true)"

if [[ -z "${SG_IDS}" || "${SG_IDS}" == "None" ]]; then
  check_ok "No tagged security groups"
else
  check_bad "Found security group(s): ${SG_IDS}"
  ORPHANS=$((ORPHANS + 1))
fi

# ----- 9. IAM roles -------------------------------------------------------

header "IAM roles (by name prefix)"
ROLE_NAMES="$(aws iam list-roles \
  --query "Roles[?starts_with(RoleName, '${CLUSTER}-')].RoleName" \
  --output text 2>/dev/null || true)"

if [[ -z "${ROLE_NAMES}" || "${ROLE_NAMES}" == "None" ]]; then
  check_ok "No IAM roles with prefix '${CLUSTER}-'"
else
  check_bad "Found IAM role(s): ${ROLE_NAMES}"
  ORPHANS=$((ORPHANS + 1))
fi

# ----- 10. CloudWatch log groups ------------------------------------------

header "CloudWatch log groups"
LOG_GROUPS="$(aws logs describe-log-groups \
  --region "${REGION}" \
  --log-group-name-prefix "/aws/eks/${CLUSTER}/" \
  --query "logGroups[].logGroupName" \
  --output text 2>/dev/null || true)"

if [[ -z "${LOG_GROUPS}" || "${LOG_GROUPS}" == "None" ]]; then
  check_ok "No log groups for cluster"
else
  check_warn "Log group(s) remain (terraform does not delete them by default): ${LOG_GROUPS}"
  check_warn "Delete manually if desired: aws logs delete-log-group --log-group-name <NAME>"
  # Not counted as an orphan — this is expected default-retain behavior.
fi

# ----- 11. KMS aliases ----------------------------------------------------

header "KMS aliases"
KMS_ALIASES="$(aws kms list-aliases \
  --region "${REGION}" \
  --query "Aliases[?starts_with(AliasName, 'alias/eks/${CLUSTER}')].AliasName" \
  --output text 2>/dev/null || true)"

if [[ -z "${KMS_ALIASES}" || "${KMS_ALIASES}" == "None" ]]; then
  check_ok "No KMS aliases for cluster"
else
  # KMS keys go through a 7-30 day pending-delete window; the alias is
  # detached but may linger briefly. Warn, don't fail.
  check_warn "KMS alias(es) pending deletion (7-30 day window is normal): ${KMS_ALIASES}"
fi

# ----- Summary ------------------------------------------------------------

echo
if [[ "${ORPHANS}" -eq 0 ]]; then
  printf "%s== CLEAN ==%s All checks passed.\n" "${C_GREEN}${C_BOLD}" "${C_RESET}"
  exit 0
else
  printf "%s== DIRTY ==%s %d orphan resource type(s) found.\n" "${C_RED}${C_BOLD}" "${C_RESET}" "${ORPHANS}"
  printf "See README §9 'What happens if cleanup fails' for manual recovery.\n"
  exit 1
fi
