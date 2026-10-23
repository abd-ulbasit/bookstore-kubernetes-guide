#!/usr/bin/env bash
# bootstrap-state.sh — create the S3 bucket that backend-s3.tf.example references.
#
# Solves the chicken-and-egg of "Terraform needs the bucket before it can use
# it as state backend". Run this ONCE per bucket, before `terraform init`.
#
# Usage:
#   ./bootstrap-state.sh <BUCKET-NAME> [REGION] [KMS-KEY-ARN]
#
# Idempotent: re-running on an existing bucket is a no-op (verifies settings).
#
# What it creates:
#   - S3 bucket with versioning enabled (state history)
#   - Default encryption: SSE-S3 (AES256), or SSE-KMS with the customer-
#     managed key you pass as the third argument (recommended for anything
#     beyond a lab, see below)
#   - Public-access-block on all 4 dimensions (defense in depth)
#   - A bucket policy that DENIES any request not made over TLS
#     (aws:SecureTransport = false)
#   - Lifecycle rule expiring noncurrent versions after 90 days
#
# What it does NOT create:
#   - DynamoDB lock table — not needed with use_lockfile = true (GA from
#     Terraform 1.11, experimental in 1.10)
#   - The KMS key itself. Create it separately and pass its ARN.
#
# Why SSE-KMS matters for STATE specifically: with SSE-S3, anyone with
# s3:GetObject on the bucket can read the state, which contains every
# attribute Terraform manages (see README "What is in state"). With
# SSE-KMS and a key policy, reading state also needs kms:Decrypt on that
# key. That is a second gate, owned separately from S3 permissions, and
# every decrypt is logged in CloudTrail.

set -euo pipefail

BUCKET="${1:?usage: $0 <BUCKET-NAME> [REGION]}"
REGION="${2:-ap-south-1}"
KMS_KEY_ARN="${3:-}"

echo "Bootstrap S3 state backend"
echo "  bucket: ${BUCKET}"
echo "  region: ${REGION}"
echo

# ----- 1. Create bucket (or verify existing) -------------------------------
if aws s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" 2>/dev/null; then
  echo "[ok] Bucket already exists: ${BUCKET}"
else
  echo "[..] Creating bucket: ${BUCKET}"
  if [[ "${REGION}" == "us-east-1" ]]; then
    # us-east-1 is special: no LocationConstraint accepted.
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
  fi
  echo "[ok] Bucket created"
fi

# ----- 2. Versioning (state history) ---------------------------------------
echo "[..] Enabling versioning"
aws s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled >/dev/null
echo "[ok] Versioning enabled"

# ----- 3. Default encryption (SSE-KMS if a key was given, else SSE-S3) ------
if [[ -n "${KMS_KEY_ARN}" ]]; then
  echo "[..] Enabling default encryption (SSE-KMS, ${KMS_KEY_ARN})"
  aws s3api put-bucket-encryption \
    --bucket "${BUCKET}" \
    --server-side-encryption-configuration \
      "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"${KMS_KEY_ARN}\"},\"BucketKeyEnabled\":true}]}" \
    >/dev/null
  echo "[ok] SSE-KMS enabled. Set kms_key_id in backend-s3.tf to the same ARN."
else
  echo "[..] Enabling default encryption (SSE-S3). Pass a KMS key ARN as the"
  echo "     third argument to use SSE-KMS instead (recommended beyond a lab)."
  aws s3api put-bucket-encryption \
    --bucket "${BUCKET}" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' \
    >/dev/null
  echo "[ok] SSE-S3 enabled"
fi

# ----- 4. Block all public access ------------------------------------------
echo "[..] Blocking public access"
aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
    '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}' \
  >/dev/null
echo "[ok] Public access blocked"

# ----- 4b. Deny anything that is not TLS ------------------------------------
# State travels to and from this bucket on every plan and apply. The policy
# makes plain-HTTP access impossible even for principals that would
# otherwise be allowed. put-bucket-policy REPLACES any existing policy, so
# this script refuses to overwrite a policy it did not write.
echo "[..] Applying TLS-only bucket policy"
if EXISTING_POLICY="$(aws s3api get-bucket-policy --bucket "${BUCKET}" --query Policy --output text 2>/dev/null)" \
   && ! grep -q '"DenyInsecureTransport"' <<<"${EXISTING_POLICY}"; then
  echo "[!!] ${BUCKET} already has a bucket policy that this script did not write."
  echo "     Not overwriting it. Add this statement to it yourself:"
  echo "     Deny s3:* on the bucket and its objects when aws:SecureTransport is false."
else
  aws s3api put-bucket-policy --bucket "${BUCKET}" --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"DenyInsecureTransport\",
      \"Effect\": \"Deny\",
      \"Principal\": \"*\",
      \"Action\": \"s3:*\",
      \"Resource\": [\"arn:aws:s3:::${BUCKET}\", \"arn:aws:s3:::${BUCKET}/*\"],
      \"Condition\": {\"Bool\": {\"aws:SecureTransport\": \"false\"}}
    }]
  }" >/dev/null
  echo "[ok] TLS-only policy applied"
fi

# ----- 5. Lifecycle: expire noncurrent versions after 90 days --------------
echo "[..] Setting lifecycle rule (expire noncurrent versions @ 90 days)"
TMP_LIFECYCLE="$(mktemp)"
cat > "${TMP_LIFECYCLE}" <<'EOF'
{
  "Rules": [
    {
      "ID": "expire-noncurrent-state-versions",
      "Status": "Enabled",
      "Filter": {},
      "NoncurrentVersionExpiration": {
        "NoncurrentDays": 90
      }
    }
  ]
}
EOF
aws s3api put-bucket-lifecycle-configuration \
  --bucket "${BUCKET}" \
  --lifecycle-configuration "file://${TMP_LIFECYCLE}" >/dev/null
rm -f "${TMP_LIFECYCLE}"
echo "[ok] Lifecycle rule set"

cat <<EOF

Bootstrap complete. Next steps:

  1. cp backend-s3.tf.example backend-s3.tf
  2. Edit backend-s3.tf — set bucket = "${BUCKET}" and region = "${REGION}"
  3. terraform init -migrate-state
       Terraform will detect the local state file, prompt you to copy it to
       S3, and switch to the S3 backend.
  4. (Optional) rm terraform.tfstate terraform.tfstate.backup
       After confirming the S3 backend works.

Native state locking is enabled via use_lockfile = true.
NO DynamoDB table is required. Whoever runs plan/apply WITH a lock needs
s3:GetObject, s3:PutObject and s3:DeleteObject on <key>.tflock; a run that
is killed mid-apply leaves that object behind (terraform force-unlock).
EOF
