################################################################################
# versions.tf — Terraform CLI + AWS provider pins for the account-baseline tree.
#
# This is intentionally separate state from the main `../terraform/` tree
# because:
#   1. It's per-AWS-account, NOT per-cluster.
#   2. It changes on a different cadence (yearly compliance review vs
#      monthly cluster lifecycle).
#   3. Different IAM blast radius: this stack creates account-wide CloudTrail
#      trails, Security Hub aggregators, GuardDuty detectors. You don't want a
#      cluster operator's typo destroying your audit pipeline.
################################################################################

terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}
