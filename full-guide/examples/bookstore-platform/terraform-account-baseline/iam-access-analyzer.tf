################################################################################
# iam-access-analyzer.tf — IAM Access Analyzer for the account.
#
# Access Analyzer scans IAM policies, S3 bucket policies, KMS key policies,
# SQS/SNS policies, IAM role trust policies, and identifies resources that
# grant access to principals OUTSIDE the trust boundary (the AWS account or
# AWS Organization, depending on type).
#
# FREE. Turn it on.
#
# Two types:
#   - ACCOUNT: trust boundary = this AWS account.
#   - ORGANIZATION: trust boundary = the org the account belongs to.
#     Requires running from the org management account.
################################################################################

resource "aws_accessanalyzer_analyzer" "main" {
  count = var.enable_iam_access_analyzer ? 1 : 0

  analyzer_name = "${var.account_prefix}-access-analyzer"
  type          = "ACCOUNT"

  tags = local.common_tags
}
