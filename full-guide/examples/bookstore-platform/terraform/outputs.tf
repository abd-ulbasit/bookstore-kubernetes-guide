################################################################################
# outputs.tf — public surface. Anything documented in the README's quick-start
# or cleanup section must be reachable via `terraform output`.
################################################################################

output "region" {
  description = "AWS region the cluster lives in."
  value       = var.region
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the cluster API server."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_oidc_provider_arn" {
  description = "OIDC provider ARN, used to build new IRSA roles for in-cluster workloads."
  value       = module.eks.oidc_provider_arn
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL — paste this into IRSA trust policies for new workload roles."
  value       = module.eks.cluster_oidc_issuer_url
}

output "kubeconfig_command" {
  description = "Command to merge this cluster into the user's local kubeconfig. The Terraform-managed kubeconfig.yaml is a separate, self-contained file the cleanup scripts use."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "kubeconfig_path" {
  description = "Path to the kubeconfig.yaml written by Terraform. Use with KUBECONFIG=./kubeconfig.yaml kubectl get nodes."
  value       = local_file.kubeconfig.filename
}

output "karpenter_node_iam_role_arn" {
  description = "IAM role assumed by Karpenter-provisioned worker nodes."
  value       = module.karpenter.node_iam_role_arn
}

output "karpenter_controller_iam_role_arn" {
  description = "IAM role assumed by the Karpenter controller (IRSA)."
  value       = module.karpenter.iam_role_arn
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue Karpenter watches for EC2 interruption events."
  value       = module.karpenter.queue_name
}

output "lb_controller_iam_role_arn" {
  description = "IAM role assumed by the AWS Load Balancer Controller (IRSA). Null when var.enable_lb_controller = false."
  value       = var.enable_lb_controller ? aws_iam_role.lb_controller[0].arn : null
}

output "vpc_id" {
  description = "VPC ID the cluster lives in."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "Primary CIDR of the cluster VPC."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs used by the system node group and Karpenter."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs used by internet-facing LBs."
  value       = module.vpc.public_subnets
}

output "intra_subnet_ids" {
  description = "Intra (no-NAT) subnet IDs hosting the EKS control-plane ENIs."
  value       = module.vpc.intra_subnets
}

output "cluster_kms_key_arn" {
  description = "ARN of the customer-managed KMS CMK that envelope-encrypts EKS Secrets at rest. Useful for cleanup-verify.sh (which checks the key isn't orphaned after destroy) and for IRSA policies that need kms:Decrypt against it."
  value       = try(module.eks.kms_key_arn, null)
}

output "cluster_kms_key_alias" {
  description = "The KMS key alias managed by the EKS module for the secrets CMK (always alias/eks/<cluster_name>). Stable across re-creates of the underlying key — use this in IAM policies or for cleanup-verify."
  value       = "alias/eks/${var.cluster_name}"
}

################################################################################
# Phase 15-R — Vault + External Secrets Operator outputs
################################################################################

output "vault_namespace" {
  description = "Kubernetes namespace where Vault runs. Null when enable_vault = false. Useful for `kubectl -n $(terraform output -raw vault_namespace) get pods` smoke checks."
  value       = var.enable_vault ? kubernetes_namespace.vault[0].metadata[0].name : null
}

output "vault_kms_key_arn" {
  description = "ARN of the customer-managed KMS CMK used for Vault auto-unseal. Document this in your DR runbook — losing the key = losing the cluster. Null when enable_vault = false."
  value       = var.enable_vault ? aws_kms_key.vault_unseal[0].arn : null
  sensitive   = true
}

output "external_secrets_namespace" {
  description = "Kubernetes namespace where the External Secrets Operator runs. Null when enable_external_secrets = false. Apps reference this when wiring ClusterSecretStore / ExternalSecret CRs (see Part 15 ch.15.05)."
  value       = var.enable_external_secrets ? kubernetes_namespace.external_secrets[0].metadata[0].name : null
}
