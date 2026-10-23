################################################################################
# iam.tf — IRSA roles that live outside individual feature files:
#   - aws-ebs-csi-driver addon role
#   - vpc-cni addon role
#   - AWS Load Balancer Controller role
#
# Karpenter's controller + node IAM is created inside karpenter.tf via the
# upstream sub-module so it stays version-locked to the controller behavior.
################################################################################

############################
# EBS-CSI driver IRSA role
############################
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name_prefix}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_managed" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

############################
# VPC-CNI IRSA role
############################
data "aws_iam_policy_document" "vpc_cni_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpc_cni" {
  name               = "${local.name_prefix}-vpc-cni"
  assume_role_policy = data.aws_iam_policy_document.vpc_cni_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "vpc_cni_managed" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

############################
# AWS Load Balancer Controller IRSA role
#
# The policy JSON is VENDORED: policies/aws-load-balancer-controller-v2.13.0.json
# is upstream docs/install/iam_policy.json at tag v2.13.0 (commit
# 73980cf11d1c79c310f4f14a089554f58b165d7d, sha256
# 16f232c9d9f79366fe949c4550ad517a202380058a9e48d45a4e215044a20a6a).
#
# It used to be fetched with data.http from a raw.githubusercontent.com URL
# on every plan. A tag is a mutable pointer, so whatever that URL returned on
# the day became an IAM policy without anyone reviewing it, and every plan
# depended on GitHub being reachable. Vendoring makes a policy change a diff
# in a PR. When you bump lb_controller_chart_version, replace the file with
# the matching tag's iam_policy.json and review the diff.
#
# lb_controller_iam_policy_url is kept as an explicit override (default
# empty = use the vendored file) for anyone who prefers the old behaviour.
############################
data "http" "lb_controller_policy" {
  count = var.enable_lb_controller && var.lb_controller_iam_policy_url != "" ? 1 : 0
  url   = var.lb_controller_iam_policy_url

  request_headers = {
    Accept = "application/json"
  }
}

resource "aws_iam_policy" "lb_controller" {
  count       = var.enable_lb_controller ? 1 : 0
  name        = "${local.name_prefix}-lb-controller"
  description = "IAM policy for the AWS Load Balancer Controller (Bookstore Platform). Source: kubernetes-sigs/aws-load-balancer-controller v2.13.0"
  policy = (var.lb_controller_iam_policy_url != ""
    ? data.http.lb_controller_policy[0].response_body
    : file("${path.module}/policies/aws-load-balancer-controller-v2.13.0.json")
  )
  tags = local.common_tags
}

data "aws_iam_policy_document" "lb_controller_assume" {
  count = var.enable_lb_controller ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  count              = var.enable_lb_controller ? 1 : 0
  name               = "${local.name_prefix}-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume[0].json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  count      = var.enable_lb_controller ? 1 : 0
  role       = aws_iam_role.lb_controller[0].name
  policy_arn = aws_iam_policy.lb_controller[0].arn
}
