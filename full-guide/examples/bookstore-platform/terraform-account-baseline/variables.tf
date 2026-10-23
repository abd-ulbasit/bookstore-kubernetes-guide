################################################################################
# variables.tf — knobs for the account-baseline tree. Everything is OFF by
# default except the budget alarm (see budget.tf). Turn on what your
# compliance posture needs; the README documents the cost + value of each.
################################################################################

variable "region" {
  description = "AWS region for the regional services (Config recorder, CloudTrail, Security Hub aggregator). Pick the region where most of your workloads live."
  type        = string
  default     = "us-east-1"
}

variable "account_prefix" {
  description = "Prefix for names that must be unique per account (CloudTrail name, Config recorder name, S3 buckets). Lowercase, alphanumeric, hyphens only."
  type        = string
  default     = "bookstore-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.account_prefix))
    error_message = "account_prefix must be 3-40 chars, lowercase alphanumeric or hyphen, must start with a letter and end with letter/digit."
  }
}

################################################################################
# GuardDuty — anomalous-behavior detection (compromised credentials, mining
# malware, port scans). ~$1-3/month for a small account. Free 30-day trial.
################################################################################
variable "enable_guardduty" {
  description = "Enable GuardDuty in this region. Detects credential misuse, crypto-mining, and other anomalous behavior. ~$1-3/month for a small account; free 30-day trial. Recommended ON for production."
  type        = bool
  default     = false
}

################################################################################
# Security Hub — compliance posture aggregator. Pulls from GuardDuty, Inspector,
# Config, IAM Access Analyzer. ~$0.0030/check; small account < $5/month.
################################################################################
variable "enable_securityhub" {
  description = "Enable AWS Security Hub + the EKS-related standards (AWS Foundational Security Best Practices, CIS Kubernetes Benchmark). ~$0.0030 per finding check; <$5/month for a small account. Requires GuardDuty for full EKS Protection."
  type        = bool
  default     = false
}

################################################################################
# AWS Config — continuous resource configuration recording + conformance pack.
# Most expensive of the bunch (~$15-50/month depending on resource count).
################################################################################
variable "enable_config" {
  description = "Enable AWS Config with the EKS-related conformance pack. Records resource state changes for audit/drift detection. Pricing: $0.003 per recorded config item + $0.001 per rule evaluation; small account ~$15-50/month. Required for many compliance frameworks (SOC 2, PCI, HIPAA)."
  type        = bool
  default     = false
}

variable "config_s3_bucket_name" {
  description = "S3 bucket name for AWS Config history. Leave empty to auto-name (<account_prefix>-aws-config-<account-id-suffix>)."
  type        = string
  default     = ""
}

################################################################################
# CloudTrail — API audit log. Critical for forensics. Free for management
# events (first trail), then $2/100k events; data events extra.
################################################################################
variable "enable_cloudtrail" {
  description = "Enable a multi-region CloudTrail. Records every AWS API call; essential for incident-response timelines. Management events FREE for the first trail; data events ~$0.10/100k events. Recommended ON for any non-toy account."
  type        = bool
  default     = false
}

variable "is_organization_trail" {
  description = "If true, the CloudTrail is an org-wide trail (requires running this Terraform from the org management account). If false, it's a regional account-scoped trail."
  type        = bool
  default     = false
}

variable "cloudtrail_s3_bucket_name" {
  description = "S3 bucket name for CloudTrail log delivery. Leave empty to auto-name (<account_prefix>-cloudtrail-<account-id-suffix>)."
  type        = string
  default     = ""
}

################################################################################
# IAM Access Analyzer — finds resources shared externally (S3 buckets, IAM
# roles, KMS keys, etc.). Free.
################################################################################
variable "enable_iam_access_analyzer" {
  description = "Create an account-scoped IAM Access Analyzer. Identifies resources granting external access (S3 bucket policies, KMS keys, role trust policies). FREE — turn this on regardless of compliance posture."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags merged into local.common_tags and applied to every resource."
  type        = map(string)
  default     = {}
}

################################################################################
# Budget — the account's monthly cost alarm. The one capability that is ON by
# default (see budget.tf for why it lives here).
################################################################################
variable "enable_budget_alarm" {
  description = "Create the account-wide monthly AWS Budget with email alerts at 80% forecast and 100% actual. ON by default: a billing alarm is a day-one requirement. Set false only on purpose (for example, if the organization's management account already budgets this account)."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "Monthly cost cap for the whole account, in USD. Alerts only; AWS does not stop spending at the cap."
  type        = number
  default     = 50

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than 0."
  }
}

variable "budget_alarm_email" {
  description = "Email address that receives the budget alerts. Required while enable_budget_alarm = true."
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_budget_alarm || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.budget_alarm_email))
    error_message = "enable_budget_alarm = true (the default) requires budget_alarm_email to be a valid email address. Set it, or set enable_budget_alarm = false on purpose."
  }
}
