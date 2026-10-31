# The Bookstore namespace, as Terraform manages it (Part 05 ch.07).
#
# The plan this file produces is what conftest checks in CI. Nothing here
# reaches a cloud provider: the only provider is the Kubernetes one, and the
# plan only has to read the cluster's kubeconfig.
#
#   terraform init
#   terraform plan -out=tfplan
#   terraform show -json tfplan > plan.json
terraform {
  required_version = ">= 1.6"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.4.0"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

resource "kubernetes_namespace_v1" "bookstore" {
  metadata {
    name = "bookstore"

    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}
