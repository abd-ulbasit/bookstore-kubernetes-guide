################################################################################
# cost-budgets.tf — optional monthly AWS Budgets alarm + SNS email forwarding.
#
# Default OFF. Enable with:
#   enable_budget_alarm = true
#   monthly_budget_usd  = 100
#   budget_alarm_email  = "platform-team@example.com"
#
# What you get:
#   - One aws_budgets_budget that fires at 80% (forecast) and 100% (actual).
#   - One SNS topic, encrypted with a customer-managed KMS key whose policy
#     lets AWS Budgets and CloudWatch publish to it.
#   - One email subscription. AWS sends a confirmation link the user MUST
#     click before email starts flowing.
#
# This is the CLUSTER's budget, and it is destroyed with the cluster. The
# account-wide alarm that must survive teardown lives in
# ../terraform-account-baseline/budget.tf and is on by default there.
#
# Cost: the budget is free (2 per account). The KMS key is ~$1/month.
################################################################################

# Precondition gate: enable_budget_alarm = true requires budget_alarm_email.
# Using terraform_data is the canonical way to attach a plan-time validation
# that doesn't materialize a real cloud object.
resource "terraform_data" "budget_alarm_precondition" {
  count = var.enable_budget_alarm ? 1 : 0

  lifecycle {
    precondition {
      condition     = !var.enable_budget_alarm || trimspace(var.budget_alarm_email) != ""
      error_message = "enable_budget_alarm = true requires budget_alarm_email to be non-empty."
    }
  }
}

################################################################################
# SNS topic for budget alarm notifications, encrypted with a customer-managed
# key.
#
# It used to use the AWS-managed alias/aws/sns key. That looks equivalent,
# but an AWS-managed key's policy cannot be edited, and AWS Budgets (and
# CloudWatch alarms, which ch.14.05 points at this topic) can only publish to
# an encrypted topic if the key policy lets their service principal use the
# key. With alias/aws/sns the topic accepted the subscription and then never
# delivered a single alarm, and nothing reported the failure.
################################################################################
data "aws_iam_policy_document" "budget_alarms_key" {
  count = var.enable_budget_alarm ? 1 : 0

  statement {
    sid       = "AccountAdministersKey"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AlarmServicesPublishEncrypted"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com", "cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "budget_alarms" {
  count = var.enable_budget_alarm ? 1 : 0

  description             = "${local.name_prefix} budget/alarm SNS topic encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.budget_alarms_key[0].json

  tags = local.common_tags
}

resource "aws_sns_topic" "budget_alarms" {
  count = var.enable_budget_alarm ? 1 : 0

  name              = "${local.name_prefix}-budget-alarms"
  kms_master_key_id = aws_kms_key.budget_alarms[0].arn

  tags = local.common_tags
}

# Allow the AWS Budgets service to publish into this topic.
data "aws_iam_policy_document" "budget_alarms_topic_policy" {
  count = var.enable_budget_alarm ? 1 : 0

  statement {
    sid     = "AllowBudgetsToPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]
    resources = [
      aws_sns_topic.budget_alarms[0].arn,
    ]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # ch.14.05 attaches a CloudWatch log-volume alarm to this topic.
  statement {
    sid     = "AllowCloudWatchAlarmsToPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]
    resources = [
      aws_sns_topic.budget_alarms[0].arn,
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "budget_alarms" {
  count = var.enable_budget_alarm ? 1 : 0

  arn    = aws_sns_topic.budget_alarms[0].arn
  policy = data.aws_iam_policy_document.budget_alarms_topic_policy[0].json
}

resource "aws_sns_topic_subscription" "budget_alarm_email" {
  count = var.enable_budget_alarm ? 1 : 0

  topic_arn = aws_sns_topic.budget_alarms[0].arn
  protocol  = "email"
  endpoint  = var.budget_alarm_email
}

################################################################################
# Monthly cost budget.
#
# Two notifications:
#   - FORECASTED 80%: warns when AWS's billing forecast projects you'll exceed
#     80% of the cap by month end. Catches runaway usage early.
#   - ACTUAL 100%: fires when you've already breached the cap.
#
# The TimeUnit MONTHLY + LimitAmount in USD is the standard cost-budget
# configuration. AWS Budgets evaluates once per ~3 hours.
################################################################################
resource "aws_budgets_budget" "monthly_cost" {
  count = var.enable_budget_alarm ? 1 : 0

  name         = "${local.name_prefix}-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Forecast warning at 80%.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alarms[0].arn]
    subscriber_email_addresses = []
  }

  # Actual breach at 100%.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alarms[0].arn]
    subscriber_email_addresses = []
  }

  depends_on = [
    aws_sns_topic_policy.budget_alarms,
  ]
}
