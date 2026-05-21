################################################################################
# cloudtrail.tf — multi-region (or org-wide) CloudTrail.
#
# CloudTrail is the audit ledger of every AWS API call. Critical for incident-
# response timelines ("at 14:03 IAM role X called DeleteCluster on the prod
# EKS cluster from IP 1.2.3.4"). Free for the first trail's management events;
# data events ~$0.10 per 100k records.
#
# is_organization_trail = true requires running this Terraform from the
# org management account (the account that owns AWS Organizations). For a
# single-account deployment, leave it false.
#
# Encryption: the bucket uses SSE-KMS with the customer-managed CMK from
# audit-kms.tf, and the trail itself encrypts log files with the same key.
# This gives you a single key-policy chokepoint over who can read history.
################################################################################

############################
# S3 bucket for CloudTrail logs
############################
resource "aws_s3_bucket" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket        = local.cloudtrail_bucket_name
  force_destroy = false

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-KMS with the audit CMK (audit-kms.tf). Encrypts the bucket at rest;
# CloudTrail's own kms_key_id (below) encrypts the log file payload itself.
resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: transition objects to Glacier-IR after 90 days (cheaper for
# rarely-accessed audit history) and expire non-current versions after 365
# days (versioning is on, so a delete leaves a marker; this caps the
# noncurrent-storage cost). Tune per your retention policy.
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id

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

data "aws_iam_policy_document" "cloudtrail_bucket" {
  count = var.enable_cloudtrail ? 1 : 0

  statement {
    sid     = "AWSCloudTrailAclCheck"
    effect  = "Allow"
    actions = ["s3:GetBucketAcl"]
    resources = [
      aws_s3_bucket.cloudtrail[0].arn,
    ]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values = [
        "arn:${local.partition}:cloudtrail:${data.aws_region.current.name}:${local.account_id}:trail/${var.account_prefix}-trail",
      ]
    }
  }

  statement {
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.cloudtrail[0].arn}/AWSLogs/${local.account_id}/*",
    ]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values = [
        "arn:${local.partition}:cloudtrail:${data.aws_region.current.name}:${local.account_id}:trail/${var.account_prefix}-trail",
      ]
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
      aws_s3_bucket.cloudtrail[0].arn,
      "${aws_s3_bucket.cloudtrail[0].arn}/*",
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

resource "aws_s3_bucket_policy" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id
  policy = data.aws_iam_policy_document.cloudtrail_bucket[0].json
}

############################
# CloudTrail trail
############################
resource "aws_cloudtrail" "main" {
  count = var.enable_cloudtrail ? 1 : 0

  name           = "${var.account_prefix}-trail"
  s3_bucket_name = aws_s3_bucket.cloudtrail[0].id

  include_global_service_events = true
  is_multi_region_trail         = true
  is_organization_trail         = var.is_organization_trail
  enable_log_file_validation    = true

  # Trail-level KMS: encrypts the log file payload before CloudTrail hands
  # it to S3. The bucket already uses SSE-KMS for at-rest — this adds the
  # control-plane integrity layer (the key policy gates who can decrypt
  # log file contents, including for log-file-validation).
  kms_key_id = aws_kms_key.audit[0].arn

  # No data events by default — they're the expensive ones. To capture them
  # (e.g. S3 object-level access for a sensitive bucket), add:
  #   event_selector {
  #     read_write_type = "All"
  #     include_management_events = true
  #     data_resource {
  #       type = "AWS::S3::Object"
  #       values = ["arn:aws:s3:::sensitive-bucket/"]
  #     }
  #   }

  tags = local.common_tags

  depends_on = [
    aws_s3_bucket_policy.cloudtrail,
    aws_kms_key.audit,
  ]
}
