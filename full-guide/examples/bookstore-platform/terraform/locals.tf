################################################################################
# locals.tf — derived values used across the configuration. Keep this small;
# anything reused 3+ times graduates into a local, otherwise inline it.
################################################################################

data "aws_availability_zones" "available" {
  state = "available"

  # Filter out opt-in zones (Wavelength, Local Zones) that EKS doesn't support.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  name_prefix = var.cluster_name

  common_tags = merge(var.tags, {
    "bookstore-platform.example.com/managed-by" = "terraform"
    "bookstore-platform.example.com/cluster"    = var.cluster_name
    Project                                     = "bookstore-platform"
  })

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Subnet CIDR allocation — explicit on purpose so reviewers see the
  # address-plan at a glance. Aligns with the README's network section.
  public_subnet_cidrs  = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
  private_subnet_cidrs = ["10.0.48.0/20", "10.0.64.0/20", "10.0.80.0/20"]
  intra_subnet_cidrs   = ["10.0.96.0/22", "10.0.100.0/22", "10.0.104.0/22"]
}
