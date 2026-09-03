terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Found by running this, not by reading docs. google_billing_budget calls
  # billingbudgets.googleapis.com, which refuses user credentials that carry no
  # quota project:
  #
  #   "Your application is authenticating by using local Application Default
  #    Credentials. The billingbudgets.googleapis.com API requires a quota
  #    project, which is not set by default."
  #
  # The cluster itself applies fine without this; only the budget fails, and it
  # fails AFTER the cluster is created, so you get a half-applied stack and a
  # running bill. user_project_override tells the provider to bill and attribute
  # such calls to billing_project.
  user_project_override = true
  billing_project       = var.project_id
}
