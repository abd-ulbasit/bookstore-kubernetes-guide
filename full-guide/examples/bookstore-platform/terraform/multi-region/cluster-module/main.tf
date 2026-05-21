################################################################################
# cluster-module/main.tf — module wrapper for a single-region cluster.
# The parent ../main.tf instantiates this once per region in `var.regions`.
#
# This module owns:
#   - The VPC
#   - The EKS control plane + system node group
#   - The EKS-managed addons (vpc-cni with before_compute=true, kube-proxy,
#     coredns, aws-ebs-csi-driver)
#
# It does NOT own (intentionally; see ../README.md):
#   - Karpenter — the parent's choice whether to install it per-region or
#     federate via Crossplane/argo from a control cluster.
#   - AWS Load Balancer Controller — same.
#   - Route 53 health checks / LBR records (global, created in the parent).
#   - CNPG cross-region replication (left as TODO in the parent).
#   - ApplicationSet generators (manifest-only; not Terraform's concern).
#
# We deliberately keep this module narrow: just the substrate. The parent (or
# Argo CD bootstrapped from a control cluster) handles workloads. Adding
# Helm/kubectl providers here would force the parent to declare them N times
# (one per region), which adds 30+ lines of boilerplate per region — not
# worth it for substrate alone.
#
# Pinned versions match the main terraform tree exactly. Edit there first,
# then propagate here.
################################################################################

terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.95"
      configuration_aliases = [aws]
    }
  }
}

variable "region" {
  description = "AWS region for this cluster instance."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name. Must be unique per AWS account + region."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version."
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "VPC CIDR for this region. Must NOT overlap with other regions if you peer them later."
  type        = string
}

variable "common_tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "cluster_endpoint_public_access" {
  description = "Whether the EKS API server is reachable from the public internet for this region. Defaults to true so the per-region kubeconfig works from operator laptops without extra networking; flip to false for production and rely on a bastion/VPN."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint for this region. 0.0.0.0/0 is wide-open and only acceptable for dev. Lock down to your office/VPN egress range for production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_partition" "current" {}

locals {
  azs                  = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnet_cidrs  = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1), cidrsubnet(var.vpc_cidr, 4, 2)]
  private_subnet_cidrs = [cidrsubnet(var.vpc_cidr, 4, 3), cidrsubnet(var.vpc_cidr, 4, 4), cidrsubnet(var.vpc_cidr, 4, 5)]
  intra_subnet_cidrs   = [cidrsubnet(var.vpc_cidr, 6, 24), cidrsubnet(var.vpc_cidr, 6, 25), cidrsubnet(var.vpc_cidr, 6, 26)]
}

################################################################################
# VPC
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.19"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnet_cidrs
  private_subnets = local.private_subnet_cidrs
  intra_subnets   = local.intra_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = true # cost-optimized; flip per-region for production HA

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  }

  intra_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  vpc_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = var.common_tags
}

################################################################################
# EKS — same shape as the main tree. See ../../eks.tf for inline comments.
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access           = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  cluster_endpoint_private_access          = true
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  cluster_encryption_config = {
    resources = ["secrets"]
  }

  cluster_enabled_log_types = [
    "api", "audit", "authenticator", "controllerManager", "scheduler",
  ]
  cloudwatch_log_group_retention_in_days = 30

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
  cluster_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  cluster_addons = {
    vpc-cni = {
      addon_version               = null
      resolve_conflicts_on_update = "OVERWRITE"
      resolve_conflicts_on_create = "OVERWRITE"
      before_compute              = true
      # Explicit destroy intent — don't leave dangling addons on the
      # cluster if this entry is ever removed from the map.
      preserve = false
    }
    kube-proxy = {
      addon_version               = null
      resolve_conflicts_on_update = "OVERWRITE"
      resolve_conflicts_on_create = "OVERWRITE"
      preserve                    = false
    }
    coredns = {
      addon_version               = null
      resolve_conflicts_on_update = "OVERWRITE"
      resolve_conflicts_on_create = "OVERWRITE"
      preserve                    = false
    }
    aws-ebs-csi-driver = {
      addon_version               = null
      resolve_conflicts_on_update = "OVERWRITE"
      resolve_conflicts_on_create = "OVERWRITE"
      preserve                    = false
    }
  }

  eks_managed_node_groups = {
    system = {
      name            = "system"
      use_name_prefix = false

      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = 2
      max_size     = 4
      desired_size = 2

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      labels = {
        "bookstore-platform.example.com/pool" = "system"
      }

      taints = {
        critical = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      tags = var.common_tags
    }
  }

  tags = var.common_tags
}

################################################################################
# Outputs — the parent stitches Route53 / CNPG / ApplicationSet against these.
################################################################################
output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "cluster_oidc_issuer_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
