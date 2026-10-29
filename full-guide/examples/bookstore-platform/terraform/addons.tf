################################################################################
# addons.tf — EKS-managed addons. Each addon_version is the build EKS marks
# as the default for the cluster's Kubernetes version (1.37), looked up by
# the aws_eks_addon_version data source below. IRSA roles are attached for
# the ones that need AWS API access.
#
# Why not addon_version = null: the provider treats addon_version as
# optional and computed, so null only lets EKS choose at create time. After
# that, a null plans no change, and a cluster upgrade would leave each addon
# on the build it got for the old version. The lookup is keyed on
# module.eks.cluster_version, so bumping kubernetes_version moves the addons
# in the same plan.
#
# vpc-cni lives inside module.eks.cluster_addons (see eks.tf) with
# before_compute = true, so it's installed before the managed node group
# launches its EC2 instances; the module does the same default-build lookup
# for it. The module keeps before_compute addons in
# aws_eks_addon.before_compute, not aws_eks_addon.this. The `moved` block
# migrates existing state from the old aws_eks_addon.vpc_cni resource
# (pre-Phase 14) to that address, so the addon is never destroyed and
# re-created. New users won't notice. Existing users get no replacement; if
# their installed vpc-cni build is not the default for the cluster's
# version, the plan also shows an in-place addon_version change.
################################################################################

moved {
  from = aws_eks_addon.vpc_cni
  to   = module.eks.aws_eks_addon.before_compute["vpc-cni"]
}

# most_recent = false returns the build EKS marks as the default for that
# Kubernetes version; true would return the newest build instead.
data "aws_eks_addon_version" "default" {
  for_each = toset(["kube-proxy", "coredns", "aws-ebs-csi-driver"])

  addon_name         = each.key
  kubernetes_version = module.eks.cluster_version
  most_recent        = false
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.default["kube-proxy"].version
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
  addon_version               = data.aws_eks_addon_version.default["coredns"].version
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
  addon_version               = data.aws_eks_addon_version.default["aws-ebs-csi-driver"].version
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
