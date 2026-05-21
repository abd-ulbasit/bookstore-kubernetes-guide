################################################################################
# gp3-storageclass.tf — make gp3 the default StorageClass and demote gp2.
#
# Why bother: every fresh EKS cluster ships a gp2 default StorageClass. gp2 is
# legacy, more expensive at small sizes, and tops out at 250 MB/s. gp3 is
# 20% cheaper and lets you tune iops/throughput independently of size. There's
# no reason to use gp2 on a new cluster.
#
# Strategy:
#   1. Create gp3-encrypted with is-default-class=true.
#   2. PATCH the existing gp2 to flip is-default-class=false. (Kubernetes
#      requires exactly one default; having two is a "multiple defaults" error
#      from kubectl describe pvc when you don't specify a class explicitly.)
#
# Both manifests depend_on the EBS-CSI addon since gp3 needs the
# ebs.csi.aws.com provisioner present on the cluster.
################################################################################

resource "kubectl_manifest" "gp3_default_storage_class" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "gp3-encrypted"
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "true"
      }
      labels = local.common_tags
    }
    provisioner = "ebs.csi.aws.com"
    parameters = {
      type       = "gp3"
      encrypted  = "true"
      iops       = "3000"
      throughput = "125"
      # fsType empty → defaults to ext4 at provision time. Override per-PVC
      # by setting storageClassName parameters; rarely worth doing.
    }
    volumeBindingMode    = "WaitForFirstConsumer"
    allowVolumeExpansion = true
    reclaimPolicy        = "Delete"
  })

  depends_on = [
    aws_eks_addon.aws_ebs_csi_driver,
  ]
}

# Demote the default gp2 StorageClass. We use kubectl_manifest with
# server-side apply + force_conflicts so we can patch an existing object
# we didn't originally create.
#
# yaml_body must match the existing gp2 — we don't redefine the whole class,
# just send the metadata patch. Server-side apply merges this against the
# stored object using the storage.k8s.io/v1 schema.
resource "kubectl_manifest" "gp2_demote" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "gp2"
      annotations = {
        # Explicitly set to "false" — Kubernetes treats the absence of the
        # annotation as "not default", so "false" and missing-key are
        # equivalent. We set explicit to make intent obvious in `describe`.
        "storageclass.kubernetes.io/is-default-class" = "false"
      }
    }
    # Required fields the apiserver expects when re-applying.
    provisioner       = "kubernetes.io/aws-ebs"
    parameters        = { type = "gp2" }
    volumeBindingMode = "WaitForFirstConsumer"
    reclaimPolicy     = "Delete"
  })

  # We didn't create gp2; allow taking ownership of fields.
  force_conflicts   = true
  server_side_apply = true

  depends_on = [
    kubectl_manifest.gp3_default_storage_class,
  ]
}
