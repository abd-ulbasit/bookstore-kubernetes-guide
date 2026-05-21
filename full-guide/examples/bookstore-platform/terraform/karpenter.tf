################################################################################
# karpenter.tf — Karpenter controller install. We delegate the IAM + SQS
# interruption-queue plumbing to the upstream eks/karpenter sub-module so it
# stays in lockstep with the controller's expected permissions.
#
# The Helm chart lives at oci://public.ecr.aws/karpenter/karpenter. Version
# 1.6.0 is Karpenter v1 (NodePool/EC2NodeClass at karpenter.sh/v1).
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name = module.eks.cluster_name

  # Enable the controller's IRSA role (vs. IAM Roles for Pods, which the
  # sub-module supports but the chart still defaults to IRSA in 1.6.x).
  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["${var.karpenter_namespace}:karpenter"]

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

# Register the Karpenter node IAM role as an EKS access entry so nodes can
# join the cluster (replaces the old aws-auth ConfigMap path).
resource "aws_eks_access_entry" "karpenter_nodes" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.karpenter.node_iam_role_arn
  type          = "EC2_LINUX"

  tags = local.common_tags
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = var.karpenter_namespace
  create_namespace = false # kube-system already exists

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_chart_version

  # Karpenter v1 chart skip-crds is false by default; let the chart install
  # the karpenter.sh/v1 and karpenter.k8s.aws/v1 CRDs.
  skip_crds = false

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

      # Karpenter v1 dropped the conversion webhook (v1beta1 was removed).
      webhook = {
        enabled = false
      }

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
  ]
}
