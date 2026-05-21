################################################################################
# audit-kms.tf — customer-managed KMS CMK for encrypting account-baseline
# audit artifacts (CloudTrail log files, Config snapshot history).
#
# Why a separate CMK (vs AES256 / aws/s3 alias):
#   - Long-lived audit data deserves a key whose policy WE control. The
#     aws-managed aws/s3 key has a built-in policy that grants every IAM
#     principal in the account decrypt access — usable for cross-team
#     "who did what" investigation BUT also means a compromised non-admin
#     IAM credential can read your audit history. A CMK locks the decrypt
#     surface to the principals we explicitly grant.
#   - CloudTrail-with-KMS also encrypts the trail's log file payload itself
#     (kms_key_id on aws_cloudtrail), not just the bucket-at-rest. This is
#     belt-and-suspenders for a forensic artifact.
#
# Regional (not multi-region). The audit data is regional; if you need a
# fail-over of the audit trail in another region, create the same key+alias
# there. Cross-region replication of CloudTrail logs is out of scope.
################################################################################

data "aws_iam_policy_document" "audit_kms" {
  count = (var.enable_cloudtrail || var.enable_config) ? 1 : 0

  # ──── Account-root: full key admin (lets IAM admins delegate further) ────
  statement {
    sid     = "EnableAccountRootAdmin"
    effect  = "Allow"
    actions = ["kms:*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }

    resources = ["*"]
  }

  # ──── CloudTrail service — encrypt log files written into the bucket ─────
  # CloudTrail uses kms:GenerateDataKey* when delivering log files; describe
  # is needed for the service to validate it can use the key before delivery.
  statement {
    sid    = "AllowCloudTrailEncryptDelivery"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # CloudTrail also needs Decrypt for the validation it performs on each
  # delivered log file (the log-file-validation feature reads back the
  # digest file to verify integrity).
  statement {
    sid    = "AllowCloudTrailDecryptForValidation"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # ──── AWS Config service — same shape as CloudTrail ──────────────────────
  statement {
    sid    = "AllowConfigEncryptDelivery"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "audit" {
  count = (var.enable_cloudtrail || var.enable_config) ? 1 : 0

  description             = "Audit-data CMK for CloudTrail + Config (Bookstore Platform account baseline)."
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.audit_kms[0].json

  tags = local.common_tags
}

resource "aws_kms_alias" "audit" {
  count = (var.enable_cloudtrail || var.enable_config) ? 1 : 0

  name          = "alias/${var.account_prefix}-audit"
  target_key_id = aws_kms_key.audit[0].key_id
}
