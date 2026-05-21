################################################################################
# securityhub.tf — AWS Security Hub aggregator + standards subscriptions.
#
# Security Hub doesn't FIND issues itself — it collects findings from
# GuardDuty / Inspector / Config / IAM Access Analyzer / its own standard
# checks, normalizes them, and gives you one dashboard + one event stream.
#
# Pricing: ~$0.0030 per standards check; <$5/month for a small account.
#
# Standards we subscribe to:
#   1. AWS Foundational Security Best Practices (FSBP) — broad baseline.
#   2. CIS AWS Foundations Benchmark v3.0 — industry-standard hardening.
#   3. NIST SP 800-53 r5 — for compliance-driven accounts.
#
# EKS-specific findings come via GuardDuty's Kubernetes audit log integration
# (enabled in guardduty.tf above).
################################################################################

resource "aws_securityhub_account" "main" {
  count = var.enable_securityhub ? 1 : 0

  enable_default_standards  = false
  control_finding_generator = "SECURITY_CONTROL"
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  count = var.enable_securityhub ? 1 : 0

  standards_arn = "arn:${local.partition}:securityhub:${data.aws_region.current.name}::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "cis_v3" {
  count = var.enable_securityhub ? 1 : 0

  standards_arn = "arn:${local.partition}:securityhub:${data.aws_region.current.name}::standards/cis-aws-foundations-benchmark/v/3.0.0"

  depends_on = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "nist_800_53" {
  count = var.enable_securityhub ? 1 : 0

  standards_arn = "arn:${local.partition}:securityhub:${data.aws_region.current.name}::standards/nist-800-53/v/5.0.0"

  depends_on = [aws_securityhub_account.main]
}
