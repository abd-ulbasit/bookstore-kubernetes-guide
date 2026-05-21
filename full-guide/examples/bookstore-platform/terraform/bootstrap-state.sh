#!/usr/bin/env bash
# bootstrap-state.sh — create the S3 bucket that backend-s3.tf.example references.
#
# Solves the chicken-and-egg of "Terraform needs the bucket before it can use
# it as state backend". Run this ONCE per bucket, before `terraform init`.
#
# Usage:
#   ./bootstrap-state.sh <BUCKET-NAME> [REGION]
#
# Idempotent: re-running on an existing bucket is a no-op (verifies settings).
#
# What it creates:
#   - S3 bucket with versioning enabled (state history)
#   - Default SSE-S3 (AES256) encryption (use SSE-KMS via the AWS console if
#     you want a customer-managed CMK)
#   - Public-access-block on all 4 dimensions (defense in depth)
#   - Lifecycle rule expiring noncurrent versions after 90 days
#
# What it does NOT create:
#   - DynamoDB lock table — not needed with Terraform 1.10+ use_lockfile = true
#   - KMS CMK — use SSE-S3 by default; switch to KMS later if required

set -euo pipefail

BUCKET="${1:?usage: $0 <BUCKET-NAME> [REGION]}"
REGION="${2:-ap-south-1}"

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

# ----- 3. Default encryption (SSE-S3 / AES256) -----------------------------
echo "[..] Enabling default encryption (SSE-S3)"
aws s3api put-bucket-encryption \
  --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' \
  >/dev/null
echo "[ok] SSE-S3 enabled"

# ----- 4. Block all public access ------------------------------------------
echo "[..] Blocking public access"
aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
    '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}' \
  >/dev/null
echo "[ok] Public access blocked"

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
NO DynamoDB table is required.
EOF
