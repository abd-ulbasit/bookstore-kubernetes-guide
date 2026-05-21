################################################################################
# karpenter-graviton.tf — optional arm64 (AWS Graviton) NodePool.
#
# Default OFF. Enable with `enable_graviton_pool = true`.
#
# Why bother: c7g/m7g/r7g are 20-40% cheaper than equivalent c7i/m7i/r7i for
# most stateless workloads, and the AL2023 EKS AMI for arm64 has the same
# kernel + addon support as x86. The kernel-bypass perf hit you'd worry about
# on bare ARM is irrelevant in Kubernetes — your bottleneck is the network and
# the runtime, both of which are JITted/compiled-native on the host arch.
#
# Caveats:
#   - Container images MUST be multi-arch (built with `docker buildx --platform
#     linux/amd64,linux/arm64`) or arm64-only. If you push amd64-only images,
#     pods on this NodePool will ImagePullBackOff with "no matching manifest".
#   - Anything that bundles a JNI native library or a non-Go binary needs an
#     arm64 build. Most modern OCI images already publish both.
#   - The amiSelectorTerms alias "al2023@latest" resolves to arm64 because the
#     NodePool requirements pin kubernetes.io/arch = arm64.
#
# Weight: 30 — between general=10 and spot=50. Karpenter prefers higher-weight
# pools when multiple pools could satisfy a pod's requirements. So spot wins
# first, then graviton, then general.
################################################################################

resource "kubectl_manifest" "nodepool_graviton" {
  count = var.enable_graviton_pool ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "graviton"
      labels = {
        "bookstore-platform.example.com/pool-arch" = "arm64"
      }
    }
    spec = {
      weight = 30

      template = {
        metadata = {
          labels = {
            "bookstore-platform.example.com/pool" = "graviton"
            "bookstore-platform.example.com/arch" = "arm64"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }

          expireAfter = var.karpenter_node_expire_after

          requirements = [
            # Pin to arm64 — this is the load-bearing constraint that makes
            # the al2023@latest alias resolve to the arm64 AMI.
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["arm64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            # Graviton 3 instance families: c7g (compute), m7g (general),
            # r7g (memory). Karpenter picks the cheapest fit by default.
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values = [
                "c7g.large", "c7g.xlarge", "c7g.2xlarge", "c7g.4xlarge",
                "m7g.large", "m7g.xlarge", "m7g.2xlarge", "m7g.4xlarge",
                "r7g.large", "r7g.xlarge", "r7g.2xlarge", "r7g.4xlarge",
              ]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot", "on-demand"]
            },
          ]
        }
      }

      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }

      limits = {
        cpu    = var.karpenter_general_cpu_limit
        memory = var.karpenter_general_memory_limit
      }
    }
  })

  depends_on = [
    helm_release.karpenter,
    kubectl_manifest.ec2nodeclass_default,
  ]
}
