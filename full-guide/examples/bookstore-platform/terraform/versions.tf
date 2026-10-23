################################################################################
# versions.tf — provider + Terraform CLI pins for the Bookstore Platform v2
# EKS deploy tree. Update with care; the README documents the version policy.
################################################################################

terraform {
  # 1.11 is where the S3 backend's use_lockfile (backend-s3.tf.example) is
  # GA; 1.10 has it as an experiment. CI, the devcontainer and
  # .terraform-version run 1.14.8, the version the lock file was made with.
  required_version = ">= 1.11.0, < 2.0.0"

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
# the EKS module's cluster outputs and an `aws eks get-token` exec plugin.
################################################################################

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

# Cluster authentication: an exec plugin, not a token in configuration.
#
# Each provider runs `aws eks get-token` itself, at the moment it connects,
# with whatever AWS credentials the current run holds: the plan identity
# during plan, the apply identity during apply. Nothing is stored.
#
# This used to be `token = data.aws_eks_cluster_auth.this.token`. A data
# source is read once at plan time, and both state and a saved plan carry
# its value: a cleartext bearer token in terraform.tfstate and in the
# tfplan artifact. Worse, `terraform apply tfplan` does not re-read data
# sources, so the CI apply job (which runs after a human approves, often
# more than the token's ~15 minutes later) would connect with the PLAN
# role's token: view-only, and usually expired. Every Helm, kubectl or
# Kubernetes change would fail with 401 or 403.
#
# Requires the AWS CLI v2 on PATH (already a README prerequisite; GitHub's
# ubuntu runners include it).
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}
