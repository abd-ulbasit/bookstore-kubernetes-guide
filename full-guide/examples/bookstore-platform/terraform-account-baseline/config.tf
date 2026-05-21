################################################################################
# config.tf — AWS Config recorder + S3 bucket + EKS conformance pack.
#
# AWS Config records every resource configuration change (think: ledger of
# "this S3 bucket's policy was modified at 14:03 by IAM role X"). The
# conformance pack is a bundle of pre-built Config Rules that check for the
# CIS Kubernetes Benchmark + AWS EKS-related best practices.
#
# Pricing rules-of-thumb:
#   - $0.003 per configuration item recorded (an EBS volume = ~5 CIs)
#   - $0.001 per rule evaluation
#   - $15-50/month for a small account; explodes on Karpenter churn.
#
# Cost containment: filter recording_group.resource_types to JUST the resource
# types you actually need to audit. Default below is "all supported types" —
# good for compliance, expensive at scale.
################################################################################

############################
# S3 bucket for Config snapshot history
############################
resource "aws_s3_bucket" "config" {
  count = var.enable_config ? 1 : 0

  bucket        = local.config_bucket_name
  force_destroy = false # protect history; flip to true only for tear-down

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "config" {
  count = var.enable_config ? 1 : 0

  bucket = aws_s3_bucket.config[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-KMS using the audit CMK from audit-kms.tf. Same key as CloudTrail, so
# one key-policy chokepoint governs all account-baseline audit decryption.
resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  count = var.enable_config ? 1 : 0

  bucket = aws_s3_bucket.config[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  count = var.enable_config ? 1 : 0

  bucket = aws_s3_bucket.config[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: same shape as the CloudTrail bucket — transition to Glacier-IR
# at 90 days, expire non-current versions after 365 days.
resource "aws_s3_bucket_lifecycle_configuration" "config" {
  count = var.enable_config ? 1 : 0

  bucket = aws_s3_bucket.config[0].id

  rule {
    id     = "transition-and-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

# Bucket policy granting AWS Config write access. Standard policy from the
# AWS Config docs (https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-policy.html).
data "aws_iam_policy_document" "config_bucket" {
  count = var.enable_config ? 1 : 0

  statement {
    sid     = "AWSConfigBucketPermissionsCheck"
    effect  = "Allow"
    actions = ["s3:GetBucketAcl"]
    resources = [
      aws_s3_bucket.config[0].arn,
    ]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid     = "AWSConfigBucketExistenceCheck"
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      aws_s3_bucket.config[0].arn,
    ]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid     = "AWSConfigBucketDelivery"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.config[0].arn}/AWSLogs/${local.account_id}/Config/*",
    ]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }

  # DenyInsecureTransport: refuses any S3 request that arrives over plain HTTP.
  # The bucket is private (PAB on), but a downstream tool that follows a
  # presigned URL over http:// would otherwise punch through. Belt-and-braces.
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.config[0].arn,
      "${aws_s3_bucket.config[0].arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  count = var.enable_config ? 1 : 0

  bucket = aws_s3_bucket.config[0].id
  policy = data.aws_iam_policy_document.config_bucket[0].json
}

############################
# Config recorder role
############################
data "aws_iam_policy_document" "config_role_assume" {
  count = var.enable_config ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  count              = var.enable_config ? 1 : 0
  name               = "${var.account_prefix}-aws-config"
  assume_role_policy = data.aws_iam_policy_document.config_role_assume[0].json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  count      = var.enable_config ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

############################
# Config recorder + delivery channel
############################
resource "aws_config_configuration_recorder" "main" {
  count = var.enable_config ? 1 : 0

  name     = "${var.account_prefix}-config-recorder"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  count = var.enable_config ? 1 : 0

  name           = "${var.account_prefix}-config-channel"
  s3_bucket_name = aws_s3_bucket.config[0].bucket
  s3_key_prefix  = "config"

  depends_on = [
    aws_s3_bucket_policy.config,
    aws_config_configuration_recorder.main,
  ]
}

resource "aws_config_configuration_recorder_status" "main" {
  count = var.enable_config ? 1 : 0

  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true

  depends_on = [
    aws_config_delivery_channel.main,
  ]
}
