################################################################################
# outputs.tf — surface the identifiers of each enabled service.
################################################################################

output "guardduty_detector_id" {
  description = "GuardDuty detector ID (null when enable_guardduty = false)."
  value       = var.enable_guardduty ? aws_guardduty_detector.main[0].id : null
}

output "securityhub_enabled" {
  description = "Whether Security Hub is enabled in this region."
  value       = var.enable_securityhub
}

output "config_recorder_name" {
  description = "AWS Config recorder name (null when enable_config = false)."
  value       = var.enable_config ? aws_config_configuration_recorder.main[0].name : null
}

output "config_s3_bucket" {
  description = "S3 bucket holding AWS Config history (null when enable_config = false)."
  value       = var.enable_config ? aws_s3_bucket.config[0].id : null
}

output "cloudtrail_arn" {
  description = "CloudTrail ARN (null when enable_cloudtrail = false)."
  value       = var.enable_cloudtrail ? aws_cloudtrail.main[0].arn : null
}

output "cloudtrail_s3_bucket" {
  description = "S3 bucket holding CloudTrail logs (null when enable_cloudtrail = false)."
  value       = var.enable_cloudtrail ? aws_s3_bucket.cloudtrail[0].id : null
}

output "access_analyzer_arn" {
  description = "IAM Access Analyzer ARN (null when enable_iam_access_analyzer = false)."
  value       = var.enable_iam_access_analyzer ? aws_accessanalyzer_analyzer.main[0].arn : null
}

output "account_id" {
  description = "AWS account this baseline applies to."
  value       = local.account_id
}

output "region" {
  description = "Region for regional services."
  value       = var.region
}
