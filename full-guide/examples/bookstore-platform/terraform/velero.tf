################################################################################
# velero.tf — optional Velero install for Kubernetes backups.
#
# Default OFF. Enable with `enable_velero = true`.
#
# What Velero gives you on top of EKS-managed etcd snapshots:
#   - Backup of Kubernetes API objects (Deployments, ConfigMaps, Secrets,
#     CRDs) to S3. EKS's etcd snapshots are managed but NOT accessible to
#     you — Velero gives you the actual export.
#   - EBS volume snapshots tied to PVCs (so a PVC restore brings the data back).
#   - Selective restore (one namespace, one label-selected set of resources)
#     to a different cluster or the same cluster.
#
# Cost: ~$5-15/month for a small cluster with a 30-day retention. S3 storage
# at $0.023/GB-month + EBS snapshot at $0.05/GB-month, both incremental.
#
# Backup of WORKLOAD data still requires the workload to be quiesced or
# crash-consistent (CNPG handles this for Postgres via WAL; Velero hooks
# integrate via pre/post-backup commands).
################################################################################

locals {
  velero_bucket_name = var.enable_velero ? coalesce(
    var.velero_backup_bucket,
    "${local.name_prefix}-velero-backups-${substr(data.aws_caller_identity.current.account_id, -6, 6)}",
  ) : ""
}

################################################################################
# S3 bucket for backup objects
################################################################################
resource "aws_s3_bucket" "velero" {
  count = var.enable_velero ? 1 : 0

  bucket        = local.velero_bucket_name
  force_destroy = false # protect backups; flip during full teardown only

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "velero" {
  count = var.enable_velero ? 1 : 0

  bucket = aws_s3_bucket.velero[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  count = var.enable_velero ? 1 : 0

  bucket = aws_s3_bucket.velero[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  count = var.enable_velero ? 1 : 0

  bucket = aws_s3_bucket.velero[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DenyInsecureTransport on the Velero bucket. Backups are sensitive (they
# contain Secrets manifests, ConfigMap values, EBS-volume contents); a
# presigned URL accidentally followed over http:// would leak them.
data "aws_iam_policy_document" "velero_bucket" {
  count = var.enable_velero ? 1 : 0

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.velero[0].arn,
      "${aws_s3_bucket.velero[0].arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "velero" {
  count = var.enable_velero ? 1 : 0

  bucket = aws_s3_bucket.velero[0].id
  policy = data.aws_iam_policy_document.velero_bucket[0].json
}

# Lifecycle: backups are accessed less often than audit logs (you only read
# them for a restore drill or a real incident), so we transition sooner
# (30 days vs 90). Non-current versions expire after 180 days — Velero
# manages its own retention via the Schedule's `ttl`; this is a safety net
# in case someone overwrites a backup object out-of-band.
resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  count = var.enable_velero ? 1 : 0

  bucket = aws_s3_bucket.velero[0].id

  rule {
    id     = "transition-and-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days = 180
    }
  }
}

################################################################################
# IRSA: IAM role for the Velero ServiceAccount (velero:velero).
################################################################################
data "aws_iam_policy_document" "velero_assume" {
  count = var.enable_velero ? 1 : 0

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
      values   = ["system:serviceaccount:velero:velero"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "velero" {
  count              = var.enable_velero ? 1 : 0
  name               = "${local.name_prefix}-velero"
  assume_role_policy = data.aws_iam_policy_document.velero_assume[0].json
  tags               = local.common_tags
}

# Custom policy — S3 access scoped to the backup bucket, EC2 snapshot
# perms scoped to volumes tagged with the Velero ownership tag.
data "aws_iam_policy_document" "velero_perms" {
  count = var.enable_velero ? 1 : 0

  # S3 — object lifecycle on the velero bucket only.
  statement {
    actions = [
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = [
      "${aws_s3_bucket.velero[0].arn}/*",
    ]
  }

  statement {
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.velero[0].arn,
    ]
  }

  # ──── ec2:Describe* — must be unscoped (AWS Describe APIs don't support
  # resource-level or tag conditions). This is by design at the API layer.
  statement {
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
    ]
    resources = ["*"]
  }

  # ──── EBS lifecycle scoped to Velero-tagged volumes/snapshots ──────────
  # Velero's velero-plugin-for-aws tags every snapshot it creates with
  # `velero.io/backup` (the backup name) and `velero.io/restore` (on
  # restore-time snapshots). We require that any DeleteSnapshot / DeleteVolume
  # is only authorized when the target resource carries the tag — this
  # prevents the role being used to wipe non-Velero snapshots/volumes.
  #
  # CreateSnapshot / CreateVolume use ResourceTag aws:RequestTag/...
  # condition: the IAM request must propose the tag at create-time.
  statement {
    actions = [
      "ec2:DeleteSnapshot",
      "ec2:DeleteVolume",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/velero.io/backup"
      values   = ["true"]
    }
  }

  # CreateSnapshot / CreateVolume — require the tag at request time so the
  # role can only create snapshots that will be subject to the
  # ResourceTag-scoped Delete above.
  statement {
    actions = [
      "ec2:CreateSnapshot",
      "ec2:CreateVolume",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/velero.io/backup"
      values   = ["true"]
    }
  }

  # CreateTags — limited to the tag key Velero uses. Without this, the role
  # could write arbitrary tags onto any EC2 resource, defeating the scoping
  # above.
  statement {
    actions   = ["ec2:CreateTags"]
    resources = ["*"]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values = [
        "velero.io/backup",
        "velero.io/restore",
      ]
    }
  }
}

resource "aws_iam_policy" "velero" {
  count       = var.enable_velero ? 1 : 0
  name        = "${local.name_prefix}-velero"
  description = "Velero S3 + EBS snapshot lifecycle (Bookstore Platform)."
  policy      = data.aws_iam_policy_document.velero_perms[0].json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "velero" {
  count      = var.enable_velero ? 1 : 0
  role       = aws_iam_role.velero[0].name
  policy_arn = aws_iam_policy.velero[0].arn
}

################################################################################
# Velero namespace + Helm release
################################################################################
resource "kubernetes_namespace" "velero" {
  count = var.enable_velero ? 1 : 0

  metadata {
    name = "velero"

    labels = {
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    }
  }
}

resource "helm_release" "velero" {
  count = var.enable_velero ? 1 : 0

  name             = "velero"
  namespace        = kubernetes_namespace.velero[0].metadata[0].name
  create_namespace = false

  repository = "https://vmware-tanzu.github.io/helm-charts"
  chart      = "velero"
  version    = var.velero_chart_version

  timeout = 900
  wait    = true
  atomic  = true
  lint    = true

  values = [
    yamlencode({
      # Velero needs an AWS plugin for object storage + EBS snapshot integration.
      initContainers = [
        {
          name            = "velero-plugin-for-aws"
          image           = "velero/velero-plugin-for-aws:v1.10.0"
          imagePullPolicy = "IfNotPresent"
          volumeMounts = [
            {
              mountPath = "/target"
              name      = "plugins"
            },
          ]
        },
      ]

      configuration = {
        backupStorageLocation = [
          {
            name     = "default"
            provider = "aws"
            bucket   = local.velero_bucket_name
            config = {
              region = var.region
            }
          },
        ]

        volumeSnapshotLocation = [
          {
            name     = "default"
            provider = "aws"
            config = {
              region = var.region
            }
          },
        ]
      }

      serviceAccount = {
        server = {
          create = true
          name   = "velero"
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.velero[0].arn
          }
        }
      }

      credentials = {
        # IRSA path; no secret needed.
        useSecret = false
      }

      # Restricted-compliant security context.
      podSecurityContext = {
        runAsNonRoot = true
        runAsUser    = 65534
        runAsGroup   = 65534
        fsGroup      = 65534
        seccompProfile = {
          type = "RuntimeDefault"
        }
      }

      containerSecurityContext = {
        allowPrivilegeEscalation = false
        readOnlyRootFilesystem   = true
        runAsNonRoot             = true
        runAsUser                = 65534
        capabilities = {
          drop = ["ALL"]
        }
      }

      # Run on the system node group; this is a cluster-critical component.
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
    kubernetes_namespace.velero,
    aws_iam_role_policy_attachment.velero,
    aws_s3_bucket.velero,
  ]
}

################################################################################
# Default daily Schedule — backs up every namespace at 02:00 UTC, retains 30d.
################################################################################
resource "kubectl_manifest" "velero_daily_schedule" {
  count = var.enable_velero ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "velero.io/v1"
    kind       = "Schedule"
    metadata = {
      name      = "nightly-cluster-backup"
      namespace = "velero"
    }
    spec = {
      schedule = "0 2 * * *"
      template = {
        ttl = "720h" # 30 days
        includedNamespaces = [
          "*",
        ]
        # Why these are excluded:
        #   - kube-system / kube-public / kube-node-lease are managed by EKS;
        #     their state is recreated automatically and would just bloat backups.
        # Why we DO include these (intentionally NOT in the excludelist):
        #   - kyverno, falco, velero, argocd: their CRDs (Policies, Schedules,
        #     Applications) ARE workload state that you want back after a
        #     restore. The controllers themselves are reinstalled by Terraform,
        #     but the CRs they manage are the source of truth.
        excludedNamespaces = [
          "kube-system",
          "kube-public",
          "kube-node-lease",
        ]
        storageLocation = "default"
        volumeSnapshotLocations = [
          "default",
        ]
        snapshotVolumes          = true
        defaultVolumesToFsBackup = false
        # CSI snapshot timeout. Default is 10m, which is too tight for PVCs
        # larger than ~50 GiB on EBS (snapshot completion is proportional to
        # block-store size + change rate). 30m gives ample headroom for the
        # PVC sizes we expect; bump higher for very large stateful workloads.
        csiSnapshotTimeout = "30m"
      }
    }
  })

  depends_on = [
    helm_release.velero,
  ]
}
