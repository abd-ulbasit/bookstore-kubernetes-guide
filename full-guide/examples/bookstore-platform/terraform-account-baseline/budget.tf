################################################################################
# budget.tf — the account's monthly cost alarm. ON by default.
#
# Everything else in this tree is opt-in. The budget is the exception: a
# billing alarm is a day-one requirement for any AWS account, and it belongs
# HERE rather than in the workload tree (../terraform/cost-budgets.tf). In the
# workload tree, `terraform destroy` of the cluster destroys the alarm with it,
# and an account with no cluster can still run up a bill (a forgotten NAT
# gateway, an orphaned load balancer, a GPU instance someone started by hand).
#
# Notifications go straight to email subscribers on the budget. There is no
# SNS topic, so there is no KMS key policy to get wrong (an SNS topic encrypted
# with the AWS-managed alias/aws/sns key silently drops Budgets messages) and
# no confirmation link to forget to click.
#
# Cost: AWS Budgets is free for the first two budgets per account.
#
# Turn it off only on purpose: enable_budget_alarm = false.
################################################################################

resource "aws_budgets_budget" "account_monthly" {
  count = var.enable_budget_alarm ? 1 : 0

  name         = "${var.account_prefix}-account-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Early warning: AWS's forecast says the month will end above 80%.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alarm_email]
  }

  # The cap is already breached.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alarm_email]
  }
}
