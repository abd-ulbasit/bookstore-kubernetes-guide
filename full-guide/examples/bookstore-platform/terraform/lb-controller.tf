################################################################################
# lb-controller.tf — AWS Load Balancer Controller install. This is the
# controller that turns a Kubernetes Service of type LoadBalancer into an NLB
# and an Ingress into an ALB. The IAM role + policy live in iam.tf.
#
# The LB controller is the source of "orphan ALBs/NLBs after terraform
# destroy" — see cleanup-pre-destroy.sh for the drain step that removes
# its Service objects *before* destroying the cluster.
################################################################################

resource "helm_release" "aws_load_balancer_controller" {
  count = var.enable_lb_controller ? 1 : 0

  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_chart_version

  timeout = 600
  wait    = true
  atomic  = true
  lint    = true

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      region      = var.region
      vpcId       = module.vpc.vpc_id

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.lb_controller[0].arn
        }
      }

      # The controller must run on the system node group so it survives a
      # full Karpenter-pool drain (which is what happens during teardown).
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

      podDisruptionBudget = {
        maxUnavailable = 1
      }

      resources = {
        requests = {
          cpu    = "100m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
      }
    }),
  ]

  depends_on = [
    module.eks,
    aws_iam_role.lb_controller,
    aws_iam_role_policy_attachment.lb_controller,
  ]
}
