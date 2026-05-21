################################################################################
# variables.tf — parent-level inputs for the multi-region instantiation.
################################################################################

variable "regions" {
  description = "List of AWS regions to instantiate the cluster in. Each must support EKS 1.35 and the AL2023 EKS-optimized AMI. Default mirrors a common 3-region active-active footprint. Only regions with provider aliases declared in main.tf are accepted — to add more, extend main.tf AND the validation list below."
  type        = list(string)
  default     = ["us-east-1", "eu-west-1", "ap-southeast-1"]

  validation {
    condition     = length(var.regions) >= 1 && length(var.regions) <= 8
    error_message = "regions must contain between 1 and 8 entries."
  }

  # Static-provider constraint: every region in this list must have a
  # `provider "aws"` block declared in main.tf with a matching alias.
  # main.tf ships with 5 aliases (us-east-1, eu-west-1, ap-southeast-1,
  # us-west-2, ap-south-1). If you need another region, add a provider
  # block + module instance in main.tf, then append the region here.
  validation {
    condition = alltrue([
      for r in var.regions : contains(
        [
          "us-east-1",
          "eu-west-1",
          "ap-southeast-1",
          "us-west-2",
          "ap-south-1",
        ],
        r,
      )
    ])
    error_message = "Only these regions have provider aliases declared in main.tf: us-east-1, eu-west-1, ap-southeast-1, us-west-2, ap-south-1. To support more, add another provider \"aws\" block in main.tf with the appropriate alias, then extend this validation list."
  }
}

variable "cluster_name" {
  description = "Base cluster name. The per-region cluster is named <cluster_name>-<region>."
  type        = string
  default     = "bookstore-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,32}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3-34 chars, lowercase alphanumeric or hyphen."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version. Same across all regions; bump in lockstep."
  type        = string
  default     = "1.35"
}

variable "vpc_cidrs_by_region" {
  description = "Per-region VPC CIDR. MUST NOT overlap if you plan to peer or transit-gateway the VPCs later. Defaults are non-overlapping /16s."
  type        = map(string)
  default = {
    "us-east-1"      = "10.10.0.0/16"
    "eu-west-1"      = "10.20.0.0/16"
    "ap-southeast-1" = "10.30.0.0/16"
    "us-west-2"      = "10.40.0.0/16"
    "ap-south-1"     = "10.50.0.0/16"
  }
}

variable "tags" {
  description = "Tags merged into every resource."
  type        = map(string)
  default = {
    Project = "bookstore-platform"
    Managed = "terraform"
  }
}

variable "cluster_endpoint_public_access" {
  description = "Whether each region's EKS API server is reachable from the public internet. Defaults to true so kubeconfig works from operator laptops; flip to false for production and rely on a bastion/VPN."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint in every region. 0.0.0.0/0 is wide-open and only acceptable for dev. Lock down to your office/VPN egress range for production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
