################################################################################
# addons.tf — EKS-managed addons. We let EKS pick the version compatible with
# the cluster's Kubernetes version (1.35) by leaving addon_version null.
# IRSA roles are attached for the ones that need AWS API access.
#
# vpc-cni lives inside module.eks.cluster_addons (see eks.tf) with
# before_compute = true, so it's installed before the managed node group
# launches its EC2 instances. The `moved` block migrates existing state from
# the old aws_eks_addon.vpc_cni resource (pre-Phase 14) into the module path
# without forcing a recreate. New users won't notice; existing users get a
# zero-diff plan.
################################################################################

moved {
  from = aws_eks_addon.vpc_cni
  to   = module.eks.aws_eks_addon.this["vpc-cni"]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "kube-proxy"
  addon_version               = null
  resolve_conflicts_on_update = "OVERWRITE"
  resolve_conflicts_on_create = "OVERWRITE"
  # On destroy, remove the addon — don't leave dangling state. The default
  # `null` would leave the addon attached to the cluster after Terraform
  # forgets it, surfacing as drift on the next plan.
  preserve = false

  tags = local.common_tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  addon_version               = null
  resolve_conflicts_on_update = "OVERWRITE"
  resolve_conflicts_on_create = "OVERWRITE"
  preserve                    = false

  # CoreDNS prefers to run on the system node group (it's a cluster-critical
  # add-on). The addon doesn't accept tolerations directly; we patch via
  # configuration_values. The CriticalAddonsOnly taint is already tolerated
  # by the upstream CoreDNS Deployment for backward compatibility.
  configuration_values = jsonencode({
    nodeSelector = {
      "bookstore-platform.example.com/pool" = "system"
    }
    tolerations = [
      {
        key      = "CriticalAddonsOnly"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      },
    ]
    replicaCount = 2
  })

  tags = local.common_tags
}

resource "aws_eks_addon" "aws_ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = null
  resolve_conflicts_on_update = "OVERWRITE"
  resolve_conflicts_on_create = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  preserve                    = false

  # Pin the controller to the system node group so it survives Karpenter drains.
  configuration_values = jsonencode({
    controller = {
      nodeSelector = {
        "bookstore-platform.example.com/pool" = "system"
      }
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        },
      ]
    }
  })

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi_managed,
  ]
}
