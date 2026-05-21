################################################################################
# karpenter-pools.tf — the actual NodePool + EC2NodeClass that tell Karpenter
# *what* to provision. These are Karpenter v1 (karpenter.sh/v1 +
# karpenter.k8s.aws/v1) — different schema from the v1beta1 docs you'll find
# in older blog posts.
#
# Shape of a v1 NodePool:
#   spec.template.spec.nodeClassRef:
#     kind: EC2NodeClass
#     group: karpenter.k8s.aws
#     name: default
#
# Shape of a v1 EC2NodeClass:
#   spec.amiSelectorTerms: [{alias: "al2023@latest"}]   # NEW in v1; required
#   spec.role: <node-iam-role-name>
#   spec.subnetSelectorTerms / securityGroupSelectorTerms
################################################################################

resource "kubectl_manifest" "ec2nodeclass_default" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      # Karpenter v1 requires amiSelectorTerms (no defaultAMI shortcut).
      # "al2023@latest" tracks the EKS-optimized Amazon Linux 2023 AMI that
      # matches the cluster's Kubernetes version (no manual AMI ID bumps).
      amiSelectorTerms = [
        { alias = "al2023@latest" },
      ]

      role = module.karpenter.node_iam_role_name

      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } },
      ]

      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } },
      ]

      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "${var.karpenter_node_disk_size}Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        },
      ]

      # NOTE: karpenter.sh/* is a Karpenter-reserved tag namespace — the
      # webhook rejects manually-set tags in it; Karpenter populates
      # karpenter.sh/nodepool on instances itself. We only set our own tags.
      tags = merge(local.common_tags, {
        "bookstore-platform.example.com/managed-by" = "karpenter"
      })
    }
  })

  depends_on = [
    helm_release.karpenter,
    aws_eks_access_entry.karpenter_nodes,
  ]
}

############################
# NodePool: general (on-demand only)
############################
resource "kubectl_manifest" "nodepool_general" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "general"
    }
    spec = {
      weight = 10

      template = {
        metadata = {
          labels = {
            "bookstore-platform.example.com/pool" = "general"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }

          # Auto-recycle nodes every ~30 days for patching.
          expireAfter = var.karpenter_node_expire_after

          requirements = [
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["c", "m", "r"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["4"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
          ]
        }
      }

      # Karpenter v1 disruption block. consolidateAfter is required for
      # WhenEmptyOrUnderutilized. 30s = fast feedback for dev; bump to a few
      # minutes if you see nodes flapping under bursty load.
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }

      # Sanity bounds — guard against a runaway HPA loop provisioning the
      # entire region.
      limits = {
        cpu    = var.karpenter_general_cpu_limit
        memory = var.karpenter_general_memory_limit
      }
    }
  })

  depends_on = [
    kubectl_manifest.ec2nodeclass_default,
  ]
}

############################
# NodePool: spot (cheaper, interruptible)
############################
resource "kubectl_manifest" "nodepool_spot" {
  count = var.enable_spot_pool ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "spot"
    }
    spec = {
      # Higher weight = preferred when both pools fit. Karpenter will choose
      # spot first; fall back to general (on-demand) on capacity rejection.
      weight = 50

      template = {
        metadata = {
          labels = {
            "bookstore-platform.example.com/pool" = "spot"
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
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["c", "m", "r"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["4"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot", "on-demand"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
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
    kubectl_manifest.ec2nodeclass_default,
  ]
}
