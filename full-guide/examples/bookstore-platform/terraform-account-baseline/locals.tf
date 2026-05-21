################################################################################
# locals.tf — shared values across the account-baseline tree.
################################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id        = data.aws_caller_identity.current.account_id
  account_id_suffix = substr(data.aws_caller_identity.current.account_id, -6, 6)
  partition         = data.aws_partition.current.partition

  # Bucket names that must be globally unique get the account-id suffix.
  config_bucket_name     = coalesce(var.config_s3_bucket_name, "${var.account_prefix}-aws-config-${local.account_id_suffix}")
  cloudtrail_bucket_name = coalesce(var.cloudtrail_s3_bucket_name, "${var.account_prefix}-cloudtrail-${local.account_id_suffix}")

  common_tags = merge(var.tags, {
    "bookstore-platform.example.com/managed-by" = "terraform"
    "bookstore-platform.example.com/scope"      = "account-baseline"
    Project                                     = "bookstore-platform"
  })
}
