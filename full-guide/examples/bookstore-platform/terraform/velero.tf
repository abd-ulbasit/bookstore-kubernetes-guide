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
# Cost follows backup size and retention. Current prices: the S3 and EBS
# pricing pages (https://aws.amazon.com/s3/pricing/,
# https://aws.amazon.com/ebs/pricing/). EBS snapshots are incremental.
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

# Versioning only. Object Lock is not set here; the Velero chapter explains
# what it adds and why it is a decision for the backup owner.
resource "aws_s3_bucket_versioning" "velero" {
  count = var.enable_velero ? 1 : 0

  bucket = aws_s3_bucket.velero[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Customer-managed key. Backups hold Secret objects as plain JSON, so the key
# policy, not an AWS-managed key, decides who can decrypt them.
resource "aws_kms_key" "velero" {
  count = var.enable_velero ? 1 : 0

  description         = "${local.name_prefix} Velero backup bucket"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.velero_key[0].json
  tags                = local.common_tags
}

data "aws_iam_policy_document" "velero_key" {
  count = var.enable_velero ? 1 : 0

  # Account administration only. Decrypt is granted by IAM to the Velero role
  # (velero_perms below); no other principal is named here.
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
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  count = var.enable_velero ? 1 : 0

  bucket = aws_s3_bucket.velero[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.velero[0].arn
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

  # ──── EBS lifecycle scoped to Velero-created snapshots and volumes ─────
  # The AWS plugin tags each snapshot with velero.io/backup = <backup name>
  # and velero.io/pv = <PV name> (plugin source: volume_snapshotter.go).
  # The value is the backup name, not "true", so the conditions test that
  # the key is present (StringLike "*").
  statement {
    actions = [
      "ec2:DeleteSnapshot",
      "ec2:DeleteVolume",
    ]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "ec2:ResourceTag/velero.io/backup"
      values   = ["*"]
    }
  }

  # Create only with the tag in the request, so everything this role creates
  # can be deleted by the statement above.
  statement {
    actions = [
      "ec2:CreateSnapshot",
      "ec2:CreateVolume",
    ]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/velero.io/backup"
      values   = ["*"]
    }
  }

  # Tags only as part of creating a snapshot or volume. AWS evaluates
  # ec2:CreateTags for tag-on-create, and ec2:CreateAction names the create
  # call, so the role cannot tag existing resources.
  statement {
    actions   = ["ec2:CreateTags"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSnapshot", "CreateVolume"]
    }
  }

  # Backup bucket key: Velero encrypts uploads and decrypts reads.
  statement {
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
    ]
    resources = [aws_kms_key.velero[0].arn]
  }

  # Restores create volumes from encrypted snapshots, which needs the EBS
  # volume key (gp3-storageclass.tf) for these actions.
  statement {
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncrypt*",
    ]
    resources = [aws_kms_key.ebs.arn]
  }

  statement {
    actions   = ["kms:CreateGrant"]
    resources = [aws_kms_key.ebs.arn]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
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
      # v1.14.x pairs with Velero 1.18.x (plugin README compatibility table).
      # Init containers are checked by restricted too, so each one carries its own
      # securityContext. The plugin image is FROM scratch with USER 65532:65532.
      initContainers = [
        {
          name            = "velero-plugin-for-aws"
          image           = "velero/velero-plugin-for-aws:v1.14.4"
          imagePullPolicy = "IfNotPresent"
          securityContext = {
            runAsNonRoot             = true
            runAsUser                = 65532
            runAsGroup               = 65532
            allowPrivilegeEscalation = false
            readOnlyRootFilesystem   = true
            capabilities = {
              drop = ["ALL"]
            }
          }
          resources = {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
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
          # Velero calls the API, so its dedicated ServiceAccount keeps the token.
          automountServiceAccountToken = true
        }
      }

      credentials = {
        # IRSA path; no secret needed.
        useSecret = false
      }

      # Restricted-compliant. The UID and GID are the ones the images declare:
      # velero/velero ends with USER cnb:cnb, which is 1002:1000 in the Paketo
      # run image it is built on. fsGroup is for the IRSA token volume (see the
      # chart's values.yaml note on AWS IAM Roles for Service Accounts).
      podSecurityContext = {
        runAsNonRoot = true
        runAsUser    = 1002
        runAsGroup   = 1000
        fsGroup      = 1000
        seccompProfile = {
          type = "RuntimeDefault"
        }
      }

      containerSecurityContext = {
        allowPrivilegeEscalation = false
        readOnlyRootFilesystem   = true
        runAsNonRoot             = true
        runAsUser                = 1002
        runAsGroup               = 1000
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
      }
    }
  })

  depends_on = [
    helm_release.velero,
  ]
}
