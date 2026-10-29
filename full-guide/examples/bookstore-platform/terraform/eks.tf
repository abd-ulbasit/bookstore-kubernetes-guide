################################################################################
# eks.tf — EKS control plane + one small managed node group ("system") that
# hosts cluster-critical add-ons (Karpenter, AWS LB Controller, CoreDNS,
# metrics-server, EBS-CSI controller). All other workloads land on Karpenter-
# provisioned nodes from karpenter-pools.tf.
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  # DEV: API endpoint is reachable from the public internet so the operator
  # can `kubectl` from their laptop. For production, set
  # cluster_endpoint_public_access = false and rely on a bastion/VPN, or
  # scope cluster_endpoint_public_access_cidrs to your egress range.
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  cluster_endpoint_private_access      = true

  # Who is cluster-admin. This tree installs Helm charts and CRDs through
  # the kubernetes/helm/kubectl providers, so the identity that APPLIES it
  # must be cluster-admin (EKS access entries are the only auth path; there
  # is no aws-auth ConfigMap). Two modes:
  #
  # Laptop (default): enable_cluster_creator_admin_permissions = true. The
  # module gives a cluster-admin access entry to the identity running
  # Terraform and makes it administrator of the secrets-encryption KMS key
  # below. It reads that identity (aws_iam_session_context) on EVERY plan,
  # not once at creation: whoever runs the next plan is the proposed
  # creator. That is stable only when one identity runs both plan and apply.
  #
  # CI: plan and apply run as different roles. With the creator entry on,
  # every plan would propose replacing the admin entry with one for the
  # read-only plan role, handing that role the KMS key, and adding a second
  # entry for a principal that already has one (EKS rejects that). So CI
  # sets enable_cluster_creator_admin_permissions = false and
  # terraform_apply_role_arn: the apply role gets the fixed entry below and
  # is named as KMS key administrator, whoever runs the plan. The
  # validations in variables.tf refuse the mixed setups.
  #
  # Moving an existing cluster from laptop to CI mode: if the apply role
  # was already the creator, rename its entry in state first, or the plan
  # destroys and re-creates the same principal's entry and the create can
  # race the destroy (README "GitHub Actions workflow").
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions

  access_entries = {
    for k, v in {
      # CI apply role: cluster-admin, by ARN, independent of the caller.
      # The production environment's reviewers and this role's trust
      # policy are what protect it.
      terraform-apply = {
        principal_arn = var.terraform_apply_role_arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }

      # CI plan role: read-only. `terraform plan` refreshes the Helm
      # releases and Kubernetes objects this tree manages, and Helm stores
      # release state in Secrets, so the plan role needs a view-everything
      # policy (AmazonEKSAdminViewPolicy, which includes Secrets) and
      # nothing more. Anyone who can push a branch can exercise this role
      # through a PR plan; that is why it gets view, not edit.
      terraform-plan = {
        principal_arn = var.terraform_plan_role_arn
        policy_associations = {
          view = {
            policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    } : k => v if v.principal_arn != ""
  }

  # Name the KMS key administrators explicitly in CI mode. Left empty, the
  # module falls back to the caller identity on every plan (see above).
  kms_key_administrators = distinct(compact(concat([var.terraform_apply_role_arn], var.kms_key_administrators)))

  # IRSA = IAM Roles for Service Accounts. Auto-creates the OIDC provider
  # (no separate aws_iam_openid_connect_provider needed).
  enable_irsa = true

  # Cluster-level KMS key for envelope-encrypting Secrets at rest. The module
  # creates a customer-managed key by default.
  cluster_encryption_config = {
    resources = ["secrets"]
  }

  # Send the cluster's control-plane logs to CloudWatch. Cheap and answers
  # nearly every "what happened to my cluster?" question.
  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  # Without a retention cap, CloudWatch log storage grows forever — and the
  # audit log alone can hit several GB/day on a busy cluster. The EKS module
  # creates /aws/eks/<cluster>/cluster and applies this retention to it.
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days

  # Networking — wired into the VPC module's outputs.
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  # Most EKS addons (kube-proxy, coredns, aws-ebs-csi-driver) live as standalone
  # aws_eks_addon resources in addons.tf so we control IRSA wiring + ordering.
  #
  # vpc-cni is the exception: it MUST exist before the node group provisions
  # nodes, because nodes can't join the cluster's pod network without it.
  # `before_compute = true` makes the EKS module install vpc-cni between the
  # control plane coming up and the managed node group launching its EC2
  # instances. Standalone aws_eks_addon resources don't get this ordering for
  # free — the addon and the node group are concurrent siblings, which has
  # been observed to race in fresh-cluster bootstraps.
  cluster_addons = {
    vpc-cni = {
      addon_version               = null # the module's aws_eks_addon_version lookup picks the default
      resolve_conflicts_on_update = "OVERWRITE"
      resolve_conflicts_on_create = "OVERWRITE"
      service_account_role_arn    = aws_iam_role.vpc_cni.arn
      before_compute              = true
      # On terraform destroy, also remove the addon. The default `null`
      # leaves it dangling on the cluster, which is irrelevant for a full
      # destroy (cluster's gone too) but matters if you ever remove this
      # entry from the map without removing the cluster.
      preserve = false
    }
  }

  # Karpenter discovers security groups via this tag (matches the EC2NodeClass
  # securityGroupSelectorTerms in karpenter-pools.tf). Without these tags the
  # NodeClass shows SecurityGroupsReady=False and Karpenter never provisions.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
  cluster_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  eks_managed_node_groups = {
    system = {
      # Short name: the module auto-builds IAM role names from this with a
      # "-eks-node-group-<random>" suffix; AWS IAM caps name_prefix at 38 chars,
      # so any prefix longer than ~22 chars overflows. "system" keeps headroom.
      name            = "system"
      use_name_prefix = false

      instance_types = var.system_node_instance_types
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = var.system_node_min_size
      max_size     = var.system_node_max_size
      desired_size = var.system_node_desired_size

      # Encrypted gp3 root volume (delete on termination; matches Karpenter EC2NodeClass).
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.system_node_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # Pool label = "system" so the LB controller / Karpenter / metrics-server
      # can nodeSelect onto these nodes. Pair with the CriticalAddonsOnly
      # taint below — only workloads that explicitly tolerate it land here.
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

      tags = merge(local.common_tags, {
        "bookstore-platform.example.com/node-pool" = "system"
      })
    }
  }

  tags = local.common_tags
}
