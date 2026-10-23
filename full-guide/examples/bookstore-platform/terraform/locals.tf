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

  # Subnet CIDR allocation, derived from var.vpc_cidr and var.az_count so
  # that changing either produces a plan you can predict. (It used to be
  # three hardcoded 10.0.x.x lists: a different vpc_cidr produced subnets
  # outside the VPC, and any az_count other than 3 silently mismatched the
  # number of AZs and subnets.)
  #
  # Layout for N = az_count, carving vpc_cidr into 16ths and 64ths:
  #   public  : N blocks of /(+4), indexes 0     .. N-1
  #   private : N blocks of /(+4), indexes N     .. 2N-1
  #   intra   : N blocks of /(+6), indexes 8N    .. 8N+N-1  (just past private)
  # With the defaults (10.0.0.0/16, N = 3) this is exactly the original plan:
  #   public  10.0.0.0/20  10.0.16.0/20 10.0.32.0/20
  #   private 10.0.48.0/20 10.0.64.0/20 10.0.80.0/20
  #   intra   10.0.96.0/22 10.0.100.0/22 10.0.104.0/22
  # N = 6 still fits in a /16 (the last intra block is index 53 of 64).
  # Changing az_count re-addresses the private and intra subnets, which
  # replaces them: plan it before an existing cluster depends on them.
  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, var.az_count + i)]
  intra_subnet_cidrs   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 6, 8 * var.az_count + i)]
}
