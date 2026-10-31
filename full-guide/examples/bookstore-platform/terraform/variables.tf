################################################################################
# variables.tf — every knob a user can turn without editing core HCL.
# Defaults target a single-region dev-grade cluster. README documents the
# production hardening overrides.
################################################################################

variable "region" {
  description = "AWS region for the EKS cluster. Default ap-south-1 (Mumbai) — change to your nearest region if needed. EKS 1.37 is GA + default in this region, with an AL2023 AMI (verified 2026-10-29 with aws eks describe-cluster-versions)."
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as the discovery tag value for Karpenter (karpenter.sh/discovery=<cluster_name>) and as the prefix for IAM roles created by this stack."
  type        = string
  default     = "bookstore-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3-40 chars, lowercase alphanumeric or hyphen, must start with a letter and end with letter/digit."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version. Pinned to 1.37, the latest standard-support version on 2026-10-29 (EKS release 2026-10-01). Standard support for 1.37 ends 2027-12-01, extended support 2028-12-01. EKS upgrades one minor at a time, so a 1.35 cluster goes through 1.36 first. Do not auto-upgrade; see README §3 'Version Policy' for the bump procedure."
  type        = string
  default     = "1.37"
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across. EKS requires >=2; 3 is recommended for production. The subnet plan scales with it (locals.tf); changing it on an existing cluster re-addresses, and so replaces, the private and intra subnets."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6."
  }
}

variable "vpc_cidr" {
  description = "Top-level VPC CIDR. Default 10.0.0.0/16 gives ~65k addresses. Every subnet is derived from it (locals.tf): public and private get 1/16 of the VPC each per AZ, intra 1/64. Must be /16 to /20: a /20 VPC already gives /24 private subnets, which VPC-CNI pod IPs exhaust quickly."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && can(regex("^[0-9.]+/(1[6-9]|20)$", var.vpc_cidr))
    error_message = "vpc_cidr must be an IPv4 CIDR with a prefix length from /16 to /20 (e.g. 10.0.0.0/16)."
  }
}

variable "single_nat_gateway" {
  description = "If true, all private subnets route through a single NAT Gateway (saves ~$0.045/hr per extra NAT). Set to false for production — multi-AZ NAT removes a single-zone failure mode."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Allow the EKS API server to be reached from the public internet. True for dev so the operator's laptop can `kubectl`; in production, set to false (or scope cluster_endpoint_public_access_cidrs) and use a bastion or VPN."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. 0.0.0.0/0 is wide-open and only acceptable for dev. Lock down to your office/VPN egress range for production. A validation refuses 0.0.0.0/0 on a public endpoint when tags.Environment is prod or production."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  # The open default is a DEV convenience (SECURITY-SCAN.md 2.1 accepts it
  # as such). This turns "the chapter teaches the production override" into
  # something the plan enforces: tag the stack as prod and the open
  # endpoint stops planning.
  validation {
    condition = !(
      var.cluster_endpoint_public_access &&
      contains(var.cluster_endpoint_public_access_cidrs, "0.0.0.0/0") &&
      contains(["prod", "production"], lower(lookup(var.tags, "Environment", "")))
    )
    error_message = "tags.Environment is prod/production but the public EKS endpoint is open to 0.0.0.0/0. Set cluster_endpoint_public_access = false, or narrow cluster_endpoint_public_access_cidrs to your VPN/office egress ranges."
  }
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Laptop mode. The EKS module gives whoever runs Terraform a cluster-admin access entry and makes them administrator of the cluster's secrets-encryption KMS key. It re-reads that identity on EVERY plan, so this is only stable when one identity runs both plan and apply. True by default for a laptop. CI, where plan and apply run as different roles, must set this false and set terraform_apply_role_arn (see eks.tf)."
  type        = bool
  default     = true
}

variable "terraform_apply_role_arn" {
  description = "CI mode. ARN of the IAM role CI uses for `terraform apply` (see .github/workflows/terraform.yml). When set, it gets an explicit, cluster-scoped AmazonEKSClusterAdminPolicy access entry and is always an administrator of the cluster's KMS key, so neither depends on who ran the plan. Requires enable_cluster_creator_admin_permissions = false. Empty = no entry (laptop mode)."
  type        = string
  default     = ""

  validation {
    condition     = var.terraform_apply_role_arn == "" || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.terraform_apply_role_arn))
    error_message = "terraform_apply_role_arn must be empty or an IAM role ARN (arn:aws:iam::<12-digit account>:role/<name>)."
  }

  # With both, the module's creator entry and this one can name the same
  # principal, and EKS allows one access entry per principal.
  validation {
    condition     = var.terraform_apply_role_arn == "" || !var.enable_cluster_creator_admin_permissions
    error_message = "terraform_apply_role_arn requires enable_cluster_creator_admin_permissions = false. The creator entry follows whoever runs Terraform; the apply-role entry replaces it."
  }

  # This tree installs Helm charts and CRDs, so whoever applies it must be
  # cluster-admin. With the creator entry off, the apply-role entry is the
  # only path this tree provides. (Checked here, not on the creator
  # variable: two variables validating each other is a dependency cycle.)
  validation {
    condition     = var.enable_cluster_creator_admin_permissions || var.terraform_apply_role_arn != ""
    error_message = "enable_cluster_creator_admin_permissions = false needs terraform_apply_role_arn: the identity that applies this tree must be cluster-admin, and with the creator entry off nothing else grants it."
  }
}

variable "terraform_plan_role_arn" {
  description = "CI mode. ARN of the read-only IAM role CI uses for `terraform plan` (see .github/workflows/terraform.yml). When set, it gets a cluster-scoped AmazonEKSAdminViewPolicy access entry: plan must read Helm release Secrets to refresh, and nothing more. Requires CI mode (creator entry off, terraform_apply_role_arn set). Empty = no entry."
  type        = string
  default     = ""

  validation {
    condition     = var.terraform_plan_role_arn == "" || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.terraform_plan_role_arn))
    error_message = "terraform_plan_role_arn must be empty or an IAM role ARN (arn:aws:iam::<12-digit account>:role/<name>)."
  }

  # A separate plan role with the creator entry still on is the dangerous
  # mix: every plan would propose making the plan role the cluster creator
  # (cluster-admin and KMS key administrator), and an approved apply of
  # that plan would do it.
  validation {
    condition     = var.terraform_plan_role_arn == "" || (!var.enable_cluster_creator_admin_permissions && var.terraform_apply_role_arn != "")
    error_message = "terraform_plan_role_arn is for CI, where plan and apply run as different roles. Also set enable_cluster_creator_admin_permissions = false and terraform_apply_role_arn; otherwise every plan proposes the plan role as cluster creator."
  }

  validation {
    condition     = var.terraform_plan_role_arn == "" || var.terraform_plan_role_arn != var.terraform_apply_role_arn
    error_message = "terraform_plan_role_arn and terraform_apply_role_arn must be different roles. The plan role runs pull-request code and must stay read-only."
  }
}

variable "kms_key_administrators" {
  description = "Extra IAM principal ARNs to administer the cluster's secrets-encryption KMS key, for example a break-glass role. terraform_apply_role_arn, when set, is always added. If the combined list is empty (laptop mode), the EKS module uses whoever runs Terraform. The key policy also keeps the account-root statement, so IAM policies in this account can still grant key access."
  type        = list(string)
  default     = []
}

variable "write_kubeconfig" {
  description = "Write ./kubeconfig.yaml (used by the cleanup scripts) on apply. True for laptop use. CI and drift checks must set false: the file lives on the runner, so the next run always finds it missing, every plan re-creates it, and `plan -refresh-only` reports it as drift."
  type        = bool
  default     = true
}

variable "system_node_instance_types" {
  description = "Instance types for the small EKS-managed 'system' node group that hosts cluster-critical add-ons (Karpenter, LB controller, CoreDNS, metrics-server). Karpenter scales the rest."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "system_node_desired_size" {
  description = "Desired count of the system managed node group. 2 is enough to keep Karpenter HA across an AZ failure."
  type        = number
  default     = 2
}

variable "system_node_min_size" {
  description = "Minimum count of the system managed node group."
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum count of the system managed node group. Keep small — workloads should land on Karpenter-provisioned nodes."
  type        = number
  default     = 4
}

variable "system_node_disk_size" {
  description = "EBS gp3 root volume size (GB) for system nodes. 30 GB is comfortable for the controllers we host."
  type        = number
  default     = 30
}

variable "karpenter_namespace" {
  description = "Namespace for the Karpenter controller. Karpenter v1 best practice is `kube-system` (the controller is a cluster-critical component, and putting it there avoids the chicken-and-egg of Karpenter needing to provision nodes for its own namespace)."
  type        = string
  default     = "kube-system"
}

variable "karpenter_chart_version" {
  description = "Karpenter Helm chart version, used for both the karpenter and karpenter-crd charts. Pinned to 1.15.1: Karpenter's compatibility matrix requires 1.15.x for Kubernetes 1.37. The controller IAM permissions that the eks/karpenter v20 sub-module lacks are added in karpenter.tf; re-check them against Karpenter's upgrade guide on every bump."
  type        = string
  default     = "1.15.1"
}

variable "enable_spot_pool" {
  description = "Create a second Karpenter NodePool that prefers Spot capacity. Cheaper but interruptible — fine for stateless workloads (which is most of the Bookstore Platform). Spot-aware pods should set podDisruptionBudgets."
  type        = bool
  default     = true
}

variable "enable_lb_controller" {
  description = "Install the AWS Load Balancer Controller (creates ALBs/NLBs for Service type=LoadBalancer and Ingress). Required by the Bookstore Platform's Ingress + Gateway API resources."
  type        = bool
  default     = true
}

variable "lb_controller_chart_version" {
  description = "AWS Load Balancer Controller Helm chart version. Pinned to 1.13.0 (which carries controller image v2.13.0 and its IAM policy)."
  type        = string
  default     = "1.13.0"
}

variable "lb_controller_iam_policy_url" {
  description = "Optional override: fetch the LB controller IAM policy from this URL at plan time instead of using the vendored, reviewed copy in policies/ (the default, empty). Fetching makes an unreviewed remote file an IAM policy and makes every plan depend on the network; see iam.tf."
  type        = string
  default     = ""
}

variable "enable_metrics_server" {
  description = "Install metrics-server. Karpenter itself does not need it, but HorizontalPodAutoscaler and `kubectl top` do — leave on unless you have a reason to disable."
  type        = bool
  default     = true
}

variable "metrics_server_chart_version" {
  description = "metrics-server Helm chart version."
  type        = string
  default     = "3.13.0"
}

variable "karpenter_general_cpu_limit" {
  description = "Sanity-bound cpu limit for the general NodePool (in vCPUs). Stops a runaway HPA from provisioning a $thousand worth of nodes."
  type        = number
  default     = 1000
}

variable "karpenter_general_memory_limit" {
  description = "Sanity-bound memory limit for the general NodePool (e.g. '1000Gi'). Same purpose as karpenter_general_cpu_limit."
  type        = string
  default     = "1000Gi"
}

variable "karpenter_node_disk_size" {
  description = "EBS gp3 root volume size (GB) for Karpenter-provisioned nodes. 50 GB is the default — bump for image-heavy workloads."
  type        = number
  default     = 50
}

variable "karpenter_node_expire_after" {
  description = "How long before Karpenter retires a node (rolling replacement). 720h ≈ 30 days; supports security patching cadence."
  type        = string
  default     = "720h"
}

variable "tags" {
  description = "Extra tags merged into local.common_tags and applied to every resource that supports tagging."
  type        = map(string)
  default     = {}
}

################################################################################
# Tier 1 — main tree additions
################################################################################

# CloudWatch log retention: EKS control-plane logs accumulate fast (~$0.03/GB-mo
# of storage + ~$0.50/GB ingestion). Without a retention cap they grow forever.
# 30 days is the operational sweet spot: long enough to debug last week's
# incident, short enough to keep the bill bounded. Bump to 90/365 for compliance
# audits, or to 3653 (10y) for SOX retention.
variable "cloudwatch_log_group_retention_in_days" {
  description = "Days to retain EKS control-plane logs in CloudWatch. Cost ~$0.03/GB-month storage + $0.50/GB ingestion. 30 = default operational; 90/365 for compliance; 3653 = ~10 years (CloudWatch maximum)."
  type        = number
  default     = 30

  validation {
    condition     = var.cloudwatch_log_group_retention_in_days >= 1 && var.cloudwatch_log_group_retention_in_days <= 3653
    error_message = "cloudwatch_log_group_retention_in_days must be between 1 and 3653 (CloudWatch hard limit ≈ 10 years)."
  }
}

################################################################################
# Tier 1 — cost-budget alarm (T1.4)
################################################################################

variable "enable_budget_alarm" {
  description = "Create an AWS Budgets monthly cost alarm + SNS topic for email notifications. Default OFF — opt-in for cost-conscious environments. Requires budget_alarm_email when enabled."
  type        = bool
  default     = false
}

variable "monthly_budget_usd" {
  description = "Monthly budget cap in USD. Notifications fire at 80% (forecast warning) and 100% (actual breach)."
  type        = number
  default     = 50

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than 0."
  }
}

variable "budget_alarm_email" {
  description = "Email address that receives budget alarms. Required when enable_budget_alarm = true (precondition enforced). Subscriber must click the confirmation link AWS SNS sends — until then no emails arrive."
  type        = string
  default     = ""
}

################################################################################
# Tier 2 — VPC endpoints (T2.7)
################################################################################

variable "enable_vpc_endpoints" {
  description = "Create VPC endpoints (S3 gateway + ECR/STS/EC2/Logs/KMS interfaces) to keep AWS API and image traffic off NAT. Each interface endpoint costs ~$0.01/hr per AZ + $0.01/GB data, so it breaks even at about 208 GB/month of traffic moved off NAT per AZ."
  type        = bool
  default     = false
}

################################################################################
# Tier 2 — Graviton NodePool (T2.8)
################################################################################

variable "enable_graviton_pool" {
  description = "Create a Karpenter NodePool that requires arm64 (Graviton c7g/m7g/r7g). 20-40% cheaper than equivalent x86 with no performance penalty for most stateless workloads. Container images must be multi-arch or arm64-only — set this AFTER you've verified your images."
  type        = bool
  default     = false
}

################################################################################
# Tier 2 — Argo CD bootstrap (T2.9)
################################################################################

variable "enable_argocd_bootstrap" {
  description = "Install Argo CD + bootstrap a root App-of-Apps Application. Default OFF — most users want manual control over the GitOps bootstrap. Requires argocd_repo_url when enabled (precondition enforced)."
  type        = bool
  default     = false
}

variable "argocd_helm_chart_version" {
  description = "Argo CD Helm chart version (chart argo-cd in argoproj/argo-helm). Pinned to 7.7.10 (the latest stable 7.7.x patch at time of authoring, 2026-05-20). For production: override via tfvars to the EXACT patch you've tested; do not let this float to a different patch via terraform refresh. Bump procedure: read release notes for 7.7.x → 7.8.x first, then bump in tfvars and re-plan."
  type        = string
  default     = "7.7.10"
}

variable "argocd_repo_url" {
  description = "Git URL of the repo Argo CD's root Application syncs from (e.g. https://github.com/your-org/platform-gitops). Required when enable_argocd_bootstrap is true."
  type        = string
  default     = ""
}

variable "argocd_root_app_path" {
  description = "Path inside argocd_repo_url that the root Application points at (App-of-Apps root)."
  type        = string
  default     = "argocd/apps"
}

variable "argocd_target_revision" {
  description = "Git revision the root Application tracks. Defaults to \"main\" (the standard default branch). For production, pin to a release tag (e.g. \"v1.2.3\") so a force-push to main can't auto-deploy unreviewed changes. Avoid \"HEAD\" — it's an Argo CD convenience that hides which ref is actually deployed."
  type        = string
  default     = "main"
}

################################################################################
# Tier 4 — Velero (T4.13)
################################################################################

variable "enable_velero" {
  description = "Install Velero for cluster backups (etcd snapshots are EKS-managed, but Velero handles Kubernetes resources + EBS volume snapshots). Adds an S3 bucket (versioned, customer-managed KMS key) + IRSA role. Cost follows backup size and retention."
  type        = bool
  default     = false
}

variable "velero_backup_bucket" {
  description = "S3 bucket name for Velero backups. Leave empty to auto-generate (<cluster_name>-velero-backups-<account-suffix>). Bucket is versioned + SSE-KMS-encrypted + public-access-blocked."
  type        = string
  default     = ""
}

variable "velero_chart_version" {
  description = "Velero Helm chart version (vmware-tanzu/velero). 12.2.x installs Velero 1.18.x."
  type        = string
  default     = "12.2.2"
}

################################################################################
# Tier 4 — Falco (T4.14)
################################################################################

variable "enable_falco" {
  description = "Install Falco for runtime threat detection. NOTE: Falco's eBPF driver requires CAP_BPF + CAP_PERFMON; its namespace runs PSA enforce=privileged. Falco and kube-system (Cilium) are the two privileged namespaces in the tree; documented in falco.tf."
  type        = bool
  default     = false
}

variable "falco_alert_email" {
  description = "Email address to send Falco alerts to (via SNS). Leave empty to skip the SNS forwarding sidecar; Falco still emits JSON to stdout."
  type        = string
  default     = ""
}

variable "falco_chart_version" {
  description = "Falco Helm chart version (falcosecurity/falco). 4.13.x is the current stable line."
  type        = string
  default     = "4.13.0"
}

################################################################################
# Tier 4 — Kyverno image-signing (T4.15)
################################################################################

variable "enable_image_signing" {
  description = "Install Kyverno + a ClusterPolicy that verifies images are cosign-signed. Default failureAction is Audit (warn, don't block) — flip to Enforce once your CI is reliably signing images."
  type        = bool
  default     = false
}

variable "image_signing_keyless_issuer" {
  description = "OIDC issuer URL for keyless cosign verification. Default is GitHub Actions' OIDC issuer; swap to GitLab/Jenkins/etc as needed."
  type        = string
  default     = "https://token.actions.githubusercontent.com"
}

variable "image_signing_keyless_subject" {
  description = "The exact signing identity (certificate subject) a signature must carry, e.g. https://github.com/<ORG>/<REPO>/.github/workflows/<WORKFLOW>.yml@refs/heads/main. Required when enable_image_signing = true. NOT a regular expression: Kyverno matches it literally (with * and ? wildcards), so a value like https://github.com/<ORG>/.+ never matches anything. Without a subject, the issuer check alone accepts a signature from ANY GitHub Actions workflow in ANY repository."
  type        = string
  default     = ""

  validation {
    condition = !var.enable_image_signing || (
      trimspace(var.image_signing_keyless_subject) != "" &&
      trimspace(var.image_signing_keyless_subject) != "*" &&
      !strcontains(var.image_signing_keyless_subject, ".+")
    )
    error_message = "enable_image_signing = true requires image_signing_keyless_subject: the exact signing identity, e.g. https://github.com/<ORG>/<REPO>/.github/workflows/<WORKFLOW>.yml@refs/heads/main. It may not be empty or \"*\", and it is not a regex (\".+\" would never match)."
  }
}

variable "image_signing_image_references" {
  description = "Image reference patterns the signature check applies to (Kyverno imageReferences, * and ? wildcards). Default [\"*\"] checks every image in non-excluded namespaces, including third-party images your CI never signed. Narrow it to your registry (e.g. [\"ghcr.io/<ORG>/*\"]) before switching to Enforce, or those images will be rejected."
  type        = list(string)
  default     = ["*"]
}

variable "image_signing_validation_failure_action" {
  description = "Kyverno failureAction for the signature rule (set on its verifyImages entry). Audit (default) records failures in PolicyReports and admits the Pod; Enforce rejects it. Audit gates nothing, so plan the switch: run Audit until reports are clean, then set Enforce here rather than patching the live policy."
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Enforce"], var.image_signing_validation_failure_action)
    error_message = "image_signing_validation_failure_action must be \"Audit\" or \"Enforce\"."
  }
}

variable "kyverno_chart_version" {
  description = "Kyverno Helm chart version. 3.3.x is the current stable line."
  type        = string
  default     = "3.3.4"
}

################################################################################
# Phase 15-R — Vault + External Secrets Operator (Part 15 ch.15.05)
#
# Production secrets management. Vault provides dynamic-secret engines + a
# K8s auth method; ESO bridges Vault values into K8s Secrets for app
# consumption. Both default OFF — opt-in via the var pair.
################################################################################

variable "enable_vault" {
  description = "Install HashiCorp Vault as the production secrets backend. Adds: namespace, IRSA role, AWS KMS CMK for auto-unseal, and a HA Raft cluster of `vault_replicas` pods. ~$4-5/month additive (mostly the KMS CMK + 3x small EBS volumes for Raft). See Part 15 ch.15.05 for the end-to-end Vault + ESO wiring story."
  type        = bool
  default     = false
}

variable "vault_chart_version" {
  description = "HashiCorp Vault Helm chart version (hashicorp/vault). Pinned to 0.30.0 — the current stable line; ships Vault app version 1.18.x. Bump procedure: read the chart's CHANGELOG.md for the target version, override via tfvars, and re-plan in a non-prod cluster first."
  type        = string
  default     = "0.30.0"
}

variable "vault_storage_size" {
  description = "Size of each Vault Raft data PVC (per replica). 10Gi is plenty for the metadata + small-payload secrets workload most teams have; bump for large-volume secret backends or long audit-log retention on disk."
  type        = string
  default     = "10Gi"
}

variable "vault_replicas" {
  description = "Number of Vault server replicas in the Raft cluster. Production = 3 (quorum = 2; survives one pod loss); dev = 1 (no quorum, but cheaper and faster to bring up). 5 is the documented upper bound for Vault Raft — beyond that, leader election cost outweighs the resilience gain."
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3, 5], var.vault_replicas)
    error_message = "vault_replicas must be 1, 3, or 5 (Raft quorum requires an odd count; 1 = dev, 3 = production, 5 = very-large clusters)."
  }
}

variable "enable_external_secrets" {
  description = "Install External Secrets Operator (ESO). The controller watches ExternalSecret CRs in user namespaces and materializes K8s Secrets from external backends (Vault, AWS SM, …). Typically enabled together with Vault but useful standalone for AWS Secrets Manager workflows. ~$0 AWS bill — runs as a small deployment on existing nodes."
  type        = bool
  default     = false
}

variable "eso_chart_version" {
  description = "External Secrets Operator Helm chart version (external-secrets/external-secrets). Pinned to 0.10.7 — the current stable patch in the 0.10.x line; matches ESO controller image v0.10.7."
  type        = string
  default     = "0.10.7"
}
