################################################################################
# guardduty.tf — Amazon GuardDuty continuous threat detection.
#
# What it watches:
#   - CloudTrail event logs (for compromised credential patterns)
#   - VPC Flow Logs (for anomalous network behavior)
#   - DNS query logs (for known-bad domains, cobalt-strike beacons)
#   - EKS audit logs (when EKS_AUDIT_LOGS feature is enabled)
#   - EKS runtime activity (when EKS_RUNTIME_MONITORING is enabled — needs the
#     GuardDuty agent on every node; we let GuardDuty manage the addon)
#   - S3 data events (when S3_DATA_EVENTS is enabled)
#   - EBS volume scans for malware (when EBS_MALWARE_PROTECTION is enabled)
#
# Pricing rounding-of-thumb for a small account:
#   - $0.10 per million CloudTrail events analyzed (FREE-tier first month)
#   - $0.85 per million VPC Flow Logs analyzed
#   - EKS runtime monitoring: per-vCPU-hour (varies by node fleet size)
#   - Total: ~$1-3/month for a single small account; $10-30/month with
#     EKS Runtime Monitoring on a 10-node Karpenter fleet.
#
# IMPORTANT: We use the standalone aws_guardduty_detector_feature resources
# (the AWS-provider 5.x forward-compatible pattern). The inline `datasources`
# block on aws_guardduty_detector is deprecated; this resource layout makes
# it trivial to flip a single feature on/off via Terraform state.
################################################################################

resource "aws_guardduty_detector" "main" {
  count = var.enable_guardduty ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = local.common_tags
}

# ────────────────────────────────────────────────────────────────────────────
# Feature flags — one resource per data source. AWS treats these as opt-in,
# so a detector with NO features set is the equivalent of "GuardDuty enabled,
# nothing watching".
# ────────────────────────────────────────────────────────────────────────────

resource "aws_guardduty_detector_feature" "s3_protection" {
  count = var.enable_guardduty ? 1 : 0

  detector_id = aws_guardduty_detector.main[0].id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  count = var.enable_guardduty ? 1 : 0

  detector_id = aws_guardduty_detector.main[0].id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

# EKS Runtime Monitoring requires a GuardDuty agent on every node. Letting
# GuardDuty manage the addon (EKS_ADDON_MANAGEMENT = ENABLED) is the
# zero-touch option — GuardDuty installs/maintains the agent across the
# cluster's MNGs and Karpenter-provisioned nodes.
resource "aws_guardduty_detector_feature" "eks_runtime" {
  count = var.enable_guardduty ? 1 : 0

  detector_id = aws_guardduty_detector.main[0].id
  name        = "EKS_RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}

resource "aws_guardduty_detector_feature" "ebs_malware" {
  count = var.enable_guardduty ? 1 : 0

  detector_id = aws_guardduty_detector.main[0].id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "ENABLED"
}
