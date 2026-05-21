################################################################################
# main.tf — instantiate the cluster-module/ wrapper once per region.
#
# Terraform's provider pattern for multi-region: declare one `provider "aws"`
# block per region (each with its own alias), then pass the matching aliased
# provider into each module instance.
#
# Terraform's for_each on a module is single-provider, so we can't dynamically
# loop providers — they have to be statically declared. We declare aliases for
# every region the variable file allows; any region not listed in var.regions
# simply has no module instance using it. The per-region provider blocks are
# free (no API calls) when they're not referenced.
#
# We keep the cluster module narrow (substrate only — VPC + EKS + addons), so
# only the AWS provider needs aliases here. Anything that needs to talk to
# the per-region cluster API (kubernetes, helm, kubectl providers) would live
# in a follow-up module that takes a single cluster's outputs as input.
################################################################################

terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags { tags = var.tags }
}

provider "aws" {
  alias  = "eu_west_1"
  region = "eu-west-1"

  default_tags { tags = var.tags }
}

provider "aws" {
  alias  = "ap_southeast_1"
  region = "ap-southeast-1"

  default_tags { tags = var.tags }
}

provider "aws" {
  alias  = "us_west_2"
  region = "us-west-2"

  default_tags { tags = var.tags }
}

provider "aws" {
  alias  = "ap_south_1"
  region = "ap-south-1"

  default_tags { tags = var.tags }
}

################################################################################
# Module instances. We declare them statically — pick one of the blocks below
# to activate by setting var.regions accordingly.
#
# Why static vs for_each? Because Terraform's for_each on a module requires a
# single provider; you cannot inject a different provider per iteration. Each
# block here is gated by a count expression that goes to 0 if the region isn't
# in var.regions, so unused blocks materialize nothing.
#
# Design constraint (intentional): Terraform's static provider configuration
# model requires explicit `provider "aws"` blocks per region; we ship 5
# commonly-used regions. To support an additional region, add another
# `provider "aws"` block with `alias = "<region_with_underscores>"`, append a
# `module "cluster_<region>"` block below using the existing five as
# templates, AND extend the `regions` validation list in variables.tf so the
# new region doesn't get rejected at plan time.
################################################################################

module "cluster_us_east_1" {
  source = "./cluster-module"
  count  = contains(var.regions, "us-east-1") ? 1 : 0

  providers = {
    aws = aws.us_east_1
  }

  region                               = "us-east-1"
  cluster_name                         = "${var.cluster_name}-us-east-1"
  kubernetes_version                   = var.kubernetes_version
  vpc_cidr                             = lookup(var.vpc_cidrs_by_region, "us-east-1", "10.10.0.0/16")
  common_tags                          = var.tags
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
}

module "cluster_eu_west_1" {
  source = "./cluster-module"
  count  = contains(var.regions, "eu-west-1") ? 1 : 0

  providers = {
    aws = aws.eu_west_1
  }

  region                               = "eu-west-1"
  cluster_name                         = "${var.cluster_name}-eu-west-1"
  kubernetes_version                   = var.kubernetes_version
  vpc_cidr                             = lookup(var.vpc_cidrs_by_region, "eu-west-1", "10.20.0.0/16")
  common_tags                          = var.tags
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
}

module "cluster_ap_southeast_1" {
  source = "./cluster-module"
  count  = contains(var.regions, "ap-southeast-1") ? 1 : 0

  providers = {
    aws = aws.ap_southeast_1
  }

  region                               = "ap-southeast-1"
  cluster_name                         = "${var.cluster_name}-ap-southeast-1"
  kubernetes_version                   = var.kubernetes_version
  vpc_cidr                             = lookup(var.vpc_cidrs_by_region, "ap-southeast-1", "10.30.0.0/16")
  common_tags                          = var.tags
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
}

module "cluster_us_west_2" {
  source = "./cluster-module"
  count  = contains(var.regions, "us-west-2") ? 1 : 0

  providers = {
    aws = aws.us_west_2
  }

  region                               = "us-west-2"
  cluster_name                         = "${var.cluster_name}-us-west-2"
  kubernetes_version                   = var.kubernetes_version
  vpc_cidr                             = lookup(var.vpc_cidrs_by_region, "us-west-2", "10.40.0.0/16")
  common_tags                          = var.tags
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
}

module "cluster_ap_south_1" {
  source = "./cluster-module"
  count  = contains(var.regions, "ap-south-1") ? 1 : 0

  providers = {
    aws = aws.ap_south_1
  }

  region                               = "ap-south-1"
  cluster_name                         = "${var.cluster_name}-ap-south-1"
  kubernetes_version                   = var.kubernetes_version
  vpc_cidr                             = lookup(var.vpc_cidrs_by_region, "ap-south-1", "10.50.0.0/16")
  common_tags                          = var.tags
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
}

################################################################################
# TODO (left as user homework — see README.md):
#
#   - Route 53 Latency-Based Routing across the per-region ALBs:
#     resource "aws_route53_record" "api_<region>" {
#       set_identifier = "<region>"
#       latency_routing_policy { region = "<region>" }
#       ...
#     }
#
#   - CNPG cross-region replication: configure CloudNativePG Cluster.spec
#     .replica.source pointing at the primary region's CNPG endpoint over a
#     transit-gateway-bridged VPC. The replica clusters here read from that.
#
#   - ApplicationSet using the Cluster generator to deploy the bookstore
#     workloads into every cluster registered with Argo CD. The Argo CD that
#     does the deploying lives in ONE region (the "control region"), and
#     registers the other clusters' API endpoints + tokens.
#
# These pieces are intentionally NOT in this Terraform because they belong to
# whoever owns the cross-cluster app lifecycle (typically a platform team).
# The cluster substrate is here; the topology is yours to wire.
################################################################################
