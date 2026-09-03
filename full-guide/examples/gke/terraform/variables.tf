variable "project_id" {
  description = "GCP project that owns the cluster. Use a dedicated project, not one shared with anything else."
  type        = string
}

variable "region" {
  description = "Region. asia-south1 (Mumbai) is the closest GCP region to Pakistan."
  type        = string
  default     = "asia-south1"
}

variable "zone" {
  description = <<-EOT
    Single zone for the cluster. A ZONAL cluster is deliberate: the GKE free tier
    credit ($74.40/month) applies only to one zonal or Autopilot cluster and is
    explicitly NOT applied to the management fee of a regional cluster.
  EOT
  type        = string
  default     = "asia-south1-a"
}

variable "cluster_name" {
  type    = string
  default = "bookstore-lab"
}

variable "node_count" {
  description = "Nodes in the pool. 2 is enough for the bookstore and gives you drain/cordon drills that a single node cannot."
  type        = number
  default     = 2
}

variable "machine_type" {
  description = "e2-standard-2 is 2 vCPU / 8 GB. e2-medium (2 vCPU shared / 4 GB) is cheaper and tight for the full stack."
  type        = string
  default     = "e2-standard-2"
}

variable "use_spot" {
  description = <<-EOT
    Spot VMs are substantially cheaper and can be preempted with 30s notice.
    For a lab this is the right default, and handling preemption is itself a
    platform-engineering lesson you cannot get on a single-node k3s.
  EOT
  type        = bool
  default     = true
}

variable "budget_amount_usd" {
  description = "Monthly budget for the alert. Alerts only; it does NOT cap spend."
  type        = number
  default     = 25
}

variable "billing_account_id" {
  description = "Billing account for the budget alert, e.g. 0X0X0X-0X0X0X-0X0X0X. Leave empty to skip creating a budget."
  type        = string
  default     = ""
}
