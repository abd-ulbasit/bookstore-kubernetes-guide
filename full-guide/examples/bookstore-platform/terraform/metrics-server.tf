################################################################################
# metrics-server.tf — required for `kubectl top` and HorizontalPodAutoscaler.
# Karpenter itself does NOT need metrics-server (it watches Pod events and
# the scheduler's queue, not metrics) but most platforms expect it present.
################################################################################

resource "helm_release" "metrics_server" {
  count = var.enable_metrics_server ? 1 : 0

  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version

  timeout = 300
  wait    = true
  atomic  = true
  lint    = true

  values = [
    yamlencode({
      # --kubelet-insecure-tls is acceptable on EKS where the kubelet's serving
      # cert is signed by a per-node CA the metrics-server doesn't trust by
      # default. The alternative is to wire the per-node CA in, which the EKS
      # docs themselves don't recommend.
      args = [
        "--kubelet-preferred-address-types=InternalIP",
        "--kubelet-insecure-tls",
        "--metric-resolution=15s",
      ]

      replicas = 2

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

      resources = {
        requests = {
          cpu    = "50m"
          memory = "64Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "256Mi"
        }
      }

      podDisruptionBudget = {
        enabled        = true
        maxUnavailable = 1
      }
    }),
  ]

  depends_on = [
    module.eks,
    aws_eks_addon.coredns,
  ]
}
