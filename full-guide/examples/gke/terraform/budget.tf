# A budget ALERT, not a cap. GCP has no hard spend stop; this emails you when
# you cross thresholds. Say that out loud, because "I set a budget" is commonly
# and wrongly assumed to mean spend cannot exceed it.
#
# Requires the Cloud Billing Budget API and billing.budgets.create on the
# billing account. Skipped entirely when billing_account_id is empty.

resource "google_billing_budget" "lab" {
  count = var.billing_account_id == "" ? 0 : 1

  billing_account = var.billing_account_id
  display_name    = "${var.cluster_name} lab budget"

  budget_filter {
    projects = ["projects/${var.project_id}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 0.9
  }

  threshold_rules {
    threshold_percent = 1.0
  }
}
