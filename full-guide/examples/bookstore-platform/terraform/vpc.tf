################################################################################
# vpc.tf — VPC + subnets sized for an EKS cluster with Karpenter.
#
# Topology (per AZ; default is 3 AZ):
#   - public  /20 — for LBs (ALB/NLB internet-facing)
#   - private /20 — for worker nodes (system MNG + Karpenter)
#   - intra   /22 — for the EKS control-plane ENIs (no NAT egress)
#
# Subnet tags are load-bearing. AWS LB Controller picks subnets by
# kubernetes.io/role/elb (public) and kubernetes.io/role/internal-elb (private).
# Karpenter discovers subnets by karpenter.sh/discovery=<cluster_name>.
# Missing/wrong tags here will cause silent runtime failures, not Terraform
# errors. Keep these in lockstep with eks.tf + karpenter-pools.tf.
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.19"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnet_cidrs
  private_subnets = local.private_subnet_cidrs
  intra_subnets   = local.intra_subnet_cidrs

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # LB controller subnet discovery. Both 0/1 and "true"/"false" tag values are
  # honored by the controller; the integer form is the documented canonical.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Karpenter subnet discovery — must equal var.cluster_name to match the
    # EC2NodeClass subnetSelectorTerms in karpenter-pools.tf.
    "karpenter.sh/discovery" = var.cluster_name
  }

  intra_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  # Karpenter also discovers the VPC via this tag (used implicitly by
  # security-group lookups in some setups).
  vpc_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = local.common_tags
}
