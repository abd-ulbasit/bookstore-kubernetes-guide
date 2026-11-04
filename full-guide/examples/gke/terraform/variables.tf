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
  description = "Cluster name; also the prefix of the node service account id (<cluster_name>-nodes), which GCP limits to 30 characters."
  type        = string
  default     = "bookstore-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3-24 characters of lowercase letters, digits and hyphens, starting with a letter and not ending with a hyphen (the node service account id <cluster_name>-nodes must fit in 30)."
  }
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

variable "authorized_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the PUBLIC control plane endpoint, for example your
    own address as "203.0.113.7/32". Required, with no default: the open
    default leaves the API server reachable from the whole internet, and an
    empty list locks you out of it. Nodes and pods can always reach the
    control plane. Google Cloud public IPs are not allowed in addition. If
    your address changes you are locked out until you run: gcloud container
    clusters update <cluster_name> --zone <zone>
    --enable-master-authorized-networks --master-authorized-networks=<ip>/32
  EOT
  type        = list(string)

  validation {
    condition     = length(var.authorized_cidrs) > 0
    error_message = "Set at least one CIDR, or you lock yourself out of the API server."
  }
}

variable "private_nodes" {
  description = <<-EOT
    Give the nodes no public IP address and add Cloud NAT so they can still
    pull images (nat.tf). Off by default: NAT bills per node and per GiB,
    and this is the Part 16 chapter 09 exercise. Set it when the cluster is
    created: flipping it on a running lab has not been tested.
  EOT
  type        = bool
  default     = false
}

variable "secrets_kms_key" {
  description = <<-EOT
    Optional Cloud KMS key for application-layer encryption of Kubernetes
    Secrets, as projects/<p>/locations/<region>/keyRings/<r>/cryptoKeys/<k>.
    Empty (the default) leaves Secrets on Google's default encryption at
    rest. The GKE service agent needs roles/cloudkms.cryptoKeyEncrypterDecrypter
    on the key, and the Cloud KMS API must be enabled; key versions and key
    operations are billed.
  EOT
  type        = string
  default     = ""
}

variable "enable_binauthz" {
  description = <<-EOT
    Turn on Binary Authorization in project-singleton enforce mode. Off by
    default: it is billed per cluster per hour, and the default project
    policy allows every image, so it enforces nothing until you write a
    policy (Part 16 chapter 13).
  EOT
  type        = bool
  default     = false
}
