################################################################################
# versions.tf — provider + Terraform CLI pins for the Bookstore Platform v2
# EKS deploy tree. Update with care; the README documents the version policy.
################################################################################

terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    # gavinbunney/kubectl is the de-facto provider for raw `kubectl apply` of
    # CRDs and other manifests without round-tripping through the kubernetes
    # provider's schema. We use it for Karpenter NodePool/EC2NodeClass.
    # Latest stable is 1.19.x — there is no 2.x line on the public registry.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.19.0, < 2.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    # hashicorp/time gives us `time_sleep` — a portable, OS-agnostic wait
    # primitive used by vault.tf's post-install warmup (replaces a previous
    # null_resource `sleep 60` local-exec which wasn't Windows-friendly).
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

################################################################################
# Provider configuration. AWS region is the only required input; everything
# else flows from there. The kubernetes/helm/kubectl providers all connect via
# the EKS module's cluster outputs + a short-lived token from the AWS provider.
################################################################################

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

# Short-lived bearer token for the EKS cluster, refreshed every plan/apply.
# This is the same token `aws eks get-token` returns.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
}
