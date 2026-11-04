# A budget ALERT, not a cap. GCP has no hard spend stop; this emails you when
# you cross thresholds. Say that out loud, because "I set a budget" is commonly
# and wrongly assumed to mean spend cannot exceed it.
#
# Requires the Cloud Billing Budget API and billing.budgets.create on the
# billing account. Skipped entirely when billing_account_id is empty.

# The budget filter is documented as projects/{project_number}. Given the
# project ID instead, the API accepts it but returns the number, so a plan
# showed the filter as changed (projects/<number> to projects/<id>) with no
# edit to the config.
data "google_project" "lab" {
  count = var.billing_account_id == "" ? 0 : 1

  project_id = var.project_id
}

resource "google_billing_budget" "lab" {
  count = var.billing_account_id == "" ? 0 : 1

  billing_account = var.billing_account_id
  display_name    = "${var.cluster_name} lab budget"

  budget_filter {
    projects = ["projects/${data.google_project.lab[0].number}"]

    # The default, INCLUDE_ALL_CREDITS, measures spend after credits. On a
    # free-trial or promotional credit the lab then costs $0 net and no alert
    # ever fires, while the credit drains. Gross spend is what to watch.
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
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
