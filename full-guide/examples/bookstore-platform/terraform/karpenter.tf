################################################################################
# karpenter.tf — Karpenter controller install. We delegate the IAM + SQS
# interruption-queue plumbing to the upstream eks/karpenter sub-module, and
# add here the controller permissions that newer Karpenter releases need and
# the sub-module's last v20 release (v20.37.2) does not grant.
#
# The Helm charts live at oci://public.ecr.aws/karpenter/karpenter and
# oci://public.ecr.aws/karpenter/karpenter-crd. Version 1.15.1 is Karpenter
# v1 (NodePool/EC2NodeClass at karpenter.sh/v1). Karpenter's compatibility
# matrix requires 1.15.x for Kubernetes 1.37
# (https://karpenter.sh/docs/upgrading/compatibility/).
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name = module.eks.cluster_name

  # Karpenter v1 needs the sub-module's v1 policy. The v20 default (false)
  # is the v0.33-v0.37 policy, whose instance-tagging statement does not
  # allow the eks:eks-cluster-name tag that v1 adds (modules/karpenter
  # variables.tf and policy.tf at v20.37.2).
  enable_v1_permissions = true

  # Permissions newer Karpenter releases need on top of that policy; see
  # aws_iam_policy.karpenter_controller_extra below.
  iam_role_policies = {
    controller_extra = aws_iam_policy.karpenter_controller_extra.arn
  }

  # Enable the controller's IRSA role (vs. EKS Pod Identity, which the
  # sub-module also supports). The Helm release below wires it in through
  # the service-account annotation.
  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["${var.karpenter_namespace}:karpenter"]

  # Name the controller role under the stack's prefix, like the other roles
  # this tree creates. The sub-module default is "KarpenterController-<random>",
  # which sat outside the <cluster_name>-* scope of the breakglass IAM repair
  # statement (../hotfix/breakglass-iam-policy.json), so an IRSA lockout of
  # the one controller that provisions nodes could not be repaired with it.
  # On an existing cluster this rename replaces the role: the Helm release
  # below picks up the new ARN through the service-account annotation and
  # restarts the controller. Node provisioning pauses for that window.
  iam_role_use_name_prefix = false
  iam_role_name            = "${local.name_prefix}-karpenter-controller"

  # The sub-module creates a node IAM role + instance profile for
  # Karpenter-provisioned EC2 instances. We reference it from the
  # EC2NodeClass in karpenter-pools.tf.
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${local.name_prefix}-karpenter-node"

  # SQS queue receives EC2 interruption + spot-rebalance + scheduled-maintenance
  # events so Karpenter can drain nodes gracefully. Created by the sub-module.
  enable_spot_termination = true

  tags = local.common_tags
}

# Controller permissions added after v20.37.2 that Karpenter's upgrade guide
# lists as required (https://karpenter.sh/v1.15/upgrading/upgrade-guide/):
#   1.7.0+   iam:ListInstanceProfiles (instance profiles now live under
#            /karpenter/<region>/<cluster>/<nodeclass-uid>/)
#   1.12.0+  ec2:DescribeInstanceStatus (instance status health checks in
#            the interruption controller)
# Opt-in features this tree does not use need more, as in Karpenter's
# CloudFormation reference policy: placement groups (1.11.0+), zonal shift
# (1.12.0+) and the RebootForRepair feature gate (1.15.0+).
#
# A separate policy, not the sub-module's iam_policy_statements: its v1
# policy is already about 5,700 of the 6,144 characters IAM allows in a
# managed policy with this tree's default names, and it grows with the
# cluster name and region. Karpenter split its own reference policy into
# five for the same limit (upgrade guide, 1.9.0; aws/karpenter-provider-aws
# issue 7874).
data "aws_iam_policy_document" "karpenter_controller_extra" {
  statement {
    sid       = "AllowUnscopedInstanceProfileListAction"
    actions   = ["iam:ListInstanceProfiles"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowRegionalInstanceStatusRead"
    actions   = ["ec2:DescribeInstanceStatus"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
}

resource "aws_iam_policy" "karpenter_controller_extra" {
  name        = "${local.name_prefix}-karpenter-controller-extra"
  description = "Karpenter controller permissions the eks/karpenter v20 sub-module does not grant (Karpenter 1.7+ and 1.12+)."
  policy      = data.aws_iam_policy_document.karpenter_controller_extra.json
  tags        = local.common_tags
}

# Register the Karpenter node IAM role as an EKS access entry so nodes can
# join the cluster (replaces the old aws-auth ConfigMap path).
resource "aws_eks_access_entry" "karpenter_nodes" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.karpenter.node_iam_role_arn
  type          = "EC2_LINUX"

  tags = local.common_tags
}

# The CRDs as their own release, at the controller's version. Helm installs
# the karpenter chart's crds/ directory on first install only and never
# upgrades it, while Karpenter's CRDs change with its version: 1.14.0 adds
# the capacitybuffers CRD and 1.15.0 adds the Unhealthy disruption-budget
# reason. Karpenter's upgrade guide recommends this chart for that reason
# (https://karpenter.sh/v1.15/upgrading/upgrade-guide/#crd-upgrades).
#
# helm.sh/resource-policy=keep stops Helm deleting the CRDs on uninstall or
# rollback, as it never deleted the crds/ copies: deleting a CRD deletes
# every NodePool, EC2NodeClass and NodeClaim with it.
#
# A cluster first applied before the 1.15.1 bump has the CRDs without Helm
# ownership metadata, and this release fails until they get it. README §7
# "Upgrading Karpenter" has the commands.
resource "helm_release" "karpenter_crd" {
  name             = "karpenter-crd"
  namespace        = var.karpenter_namespace
  create_namespace = false # kube-system already exists

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = var.karpenter_chart_version

  wait   = true
  atomic = true
  lint   = true

  values = [
    yamlencode({
      additionalAnnotations = {
        "helm.sh/resource-policy" = "keep"
      }
    }),
  ]

  depends_on = [module.eks]
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = var.karpenter_namespace
  create_namespace = false # kube-system already exists

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_chart_version

  # The CRDs come from helm_release.karpenter_crd above.
  skip_crds = true

  # Helm timeouts: the controller takes ~2 minutes to settle on a fresh
  # cluster (waiting for the webhook? no — v1 has no webhook — but the
  # leader-election lease + readiness probe still take a beat).
  timeout = 600
  wait    = true
  atomic  = true
  lint    = true

  values = [
    yamlencode({
      replicas = 2

      serviceAccount = {
        create = true
        name   = "karpenter"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.karpenter.iam_role_arn
        }
      }

      settings = {
        clusterName       = module.eks.cluster_name
        interruptionQueue = module.karpenter.queue_name
      }

      # Run on the system node group only — Karpenter must not depend on
      # itself for scheduling.
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

      controller = {
        resources = {
          requests = {
            cpu    = "200m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }
      }

      # No `webhook` values: the chart dropped them in 1.1.0 along with the
      # v1beta1 conversion webhook (charts/karpenter/values.yaml), so the
      # `webhook.enabled = false` that used to sit here did nothing.

      # Spread the two replicas across AZs.
      topologySpreadConstraints = [
        {
          maxSkew           = 1
          topologyKey       = "topology.kubernetes.io/zone"
          whenUnsatisfiable = "ScheduleAnyway"
          labelSelector = {
            matchLabels = {
              "app.kubernetes.io/name" = "karpenter"
            }
          }
        },
      ]
    }),
  ]

  depends_on = [
    module.eks,
    module.karpenter,
    aws_eks_access_entry.karpenter_nodes,
    helm_release.karpenter_crd,
  ]
}
