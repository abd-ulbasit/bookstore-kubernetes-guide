################################################################################
# gp3-storageclass.tf — make gp3 the default StorageClass and demote gp2.
#
# Why bother: every fresh EKS cluster ships a gp2 default StorageClass. gp2 is
# legacy, more expensive at small sizes, and tops out at 250 MB/s. gp3 is
# 20% cheaper and lets you tune iops/throughput independently of size. There's
# no reason to use gp2 on a new cluster.
#
# Strategy:
#   1. Create a customer-managed KMS key for EBS. The EBS-CSI controller role
#      gets the volume-use actions on it.
#   2. Create gp3-encrypted with is-default-class=true, encrypted with that key,
#      and reclaimPolicy Retain, so a deleted claim keeps its volume.
#   3. PATCH the existing gp2 to flip is-default-class=false. Kubernetes
#      documents keeping one default StorageClass, so gp2 must lose the
#      annotation.
#
# Both StorageClasses depend on the EBS-CSI addon since gp3 needs the
# ebs.csi.aws.com provisioner present on the cluster.
################################################################################

# Customer-managed key for EBS volumes and snapshots. The AWS-managed aws/ebs
# key cannot be used to share snapshots, and AWS rotates it on its own schedule.
# A customer-managed key gives us the key policy, yearly rotation and a switch
# to disable it. The account root keeps administrative control of the key.
# The EBS-CSI controller role gets the volume-use actions, and no other role
# is named.
data "aws_iam_policy_document" "ebs_key" {
  statement {
    sid       = "AccountKeyAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "EbsCsiControllerUse"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.ebs_csi.arn]
    }
  }

  statement {
    sid       = "EbsCsiControllerGrants"
    effect    = "Allow"
    actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.ebs_csi.arn]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_kms_key" "ebs" {
  description             = "${local.name_prefix} EBS volumes and snapshots"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.ebs_key.json
  tags                    = local.common_tags
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${local.name_prefix}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}

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
      kmsKeyId   = aws_kms_key.ebs.arn
      iops       = "3000"
      throughput = "125"
      # fsType empty → defaults to ext4 at provision time. Override per-PVC
      # by setting storageClassName parameters; rarely worth doing.
    }
    volumeBindingMode    = "WaitForFirstConsumer"
    allowVolumeExpansion = true
    # Retain keeps the volume after its claim is deleted. Kubernetes uses
    # Delete when this field is omitted.
    reclaimPolicy = "Retain"
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
