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

  # The principal that runs `terraform apply` becomes a cluster-admin. Without
  # this, the deployer can create the cluster but cannot kubectl into it,
  # because EKS access entries are now the only auth path (no aws-auth CM).
  enable_cluster_creator_admin_permissions = true

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
      addon_version               = null # EKS picks the default for K8s 1.35
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
