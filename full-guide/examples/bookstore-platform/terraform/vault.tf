################################################################################
# vault.tf — optional HashiCorp Vault install for production secrets.
#
# Default OFF. Enable with `enable_vault = true`.
#
# What Vault gives you on top of K8s Secrets:
#   - A dynamic-secret engine (DBs/AWS/PKI/SSH) — credentials rotated per-lease
#     instead of static `data.password` blobs sitting in etcd forever.
#   - Transit encryption (envelope-encryption-as-a-service) for app payloads
#     that mustn't be decryptable by anyone with kubectl-get-secret rights.
#   - A first-class K8s auth method (ServiceAccount JWT → Vault role binding)
#     so workloads authenticate by SA identity, not by long-lived tokens.
#   - Auto-unseal via AWS KMS — the seal-and-unseal master key is held in a
#     KMS CMK; Vault auto-unseals on every pod restart instead of an operator
#     manually entering 3-of-5 Shamir key shares (the production footgun this
#     replaces).
#
# Cost (HA defaults, ap-south-1):
#   - 3x t3.medium-equivalent pods on existing Karpenter nodes (no extra EC2).
#   - 3x EBS gp3 volumes (10 GiB default) ~= $2.40/month.
#   - 1x KMS CMK for auto-unseal: $1/month + minimal API-call cost.
#   - 1x KMS CMK for transit (created separately by users that opt in).
#   Total: ~$4-5/month additive over the base cluster.
#
# Non-HA mode (single replica, no Raft consensus): set vault_replicas = 1.
# Use that for dev or smoke-test environments. Production stays at 3.
#
# ────────────────────────────────────────────────────────────────────────────
# CHART-VALUES VERIFICATION (chart 0.30.0, app version 1.18.x)
# Verified keys against hashicorp/vault chart at v0.30.0:
#   - server.ha.enabled / server.ha.raft.enabled       — HA toggle (raft)
#   - server.ha.raft.config (HCL string)               — raft + seal stanzas
#   - server.serviceAccount.create + annotations       — IRSA wiring
#   - server.dataStorage.size / .storageClass          — Raft persistence PVC
#   - server.statefulSet.{pod,container}SecurityContext — PSA restricted shape
#   - server.extraEnvironmentVars                      — KMS region + key
#   - server.readinessProbe / livenessProbe            — must allow uninit/sealed
# To re-verify against your chart pin:
#   helm template hashicorp/vault --version 0.30.0 --debug \
#     | grep -nE 'securityContext|readinessProbe|raft'
# ────────────────────────────────────────────────────────────────────────────
#
# ────────────────────────────────────────────────────────────────────────────
# PSA — RESTRICTED COMPLIANCE
# Vault chart 0.30.x runs the server as UID/GID 100 (the `vault` user baked
# into the official image) and does NOT require any Linux capabilities for
# normal Raft + KMS-unseal operation. mlock() is the historical reason Vault
# wanted IPC_LOCK; we disable mlock in the HCL config (`disable_mlock = true`)
# which is the documented + safe path on K8s (kubelet doesn't swap pods, so
# mlock just adds operational friction without a security gain).
#
# Result: the `vault` namespace enforces PSA `restricted` and the
# server-statefulset securityContext satisfies it (runAsNonRoot=true,
# readOnlyRootFilesystem=true, capabilities.drop=[ALL], seccomp=RuntimeDefault).
# ────────────────────────────────────────────────────────────────────────────
#
# ────────────────────────────────────────────────────────────────────────────
# !!! TLS POSTURE — INTRA-CLUSTER PLAINTEXT BY DEFAULT !!!
# This Vault install serves the API/Raft on plaintext inside the cluster.
# Threat model: cluster mesh (Istio/Cilium) provides the encryption boundary;
# Vault traffic stays within the cluster network (ClusterIP-only Service).
# For internet-exposed Vault (Ingress / NLB), enable TLS by:
#   1. cert-manager Certificate provisioning a server cert+key Secret
#   2. server.extraVolumes mounting the Secret at /vault/tls
#   3. global.tlsDisable = false + listener block with tls_cert_file/tls_key_file paths
# Until that's wired, this stays mesh-encrypted at the network layer, not TLS-encrypted at the application layer.
# ────────────────────────────────────────────────────────────────────────────
################################################################################

################################################################################
# Namespace — PSA restricted.
################################################################################
resource "kubernetes_namespace" "vault" {
  count = var.enable_vault ? 1 : 0

  metadata {
    name = "vault"

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

################################################################################
# KMS CMK for Vault auto-unseal.
#
# This key encrypts Vault's master key at rest. Vault's startup sequence:
#   1. Pod boots, reads its sealed root-key blob from Raft.
#   2. Calls kms:Decrypt on this key via the IRSA role to unseal.
#   3. Serves API.
#
# Losing this key = losing the cluster (you cannot recover sealed data). The
# Terraform `prevent_destroy` lifecycle below trips a deletion guard; the
# 30-day KMS deletion window is a second safety net. Document the key ARN in
# your DR runbook.
################################################################################
resource "aws_kms_key" "vault_unseal" {
  count = var.enable_vault ? 1 : 0

  description             = "Vault auto-unseal CMK for ${var.cluster_name}. Encrypts Vault's master key. DO NOT DELETE without a documented runbook."
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    "bookstore-platform.example.com/role" = "vault-unseal"
  })

  lifecycle {
    # Belt-and-suspenders: even with the 30-day window, prevent_destroy stops
    # a `terraform destroy` from queuing the deletion at all. Comment this
    # out only during a documented full-teardown.
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "vault_unseal" {
  count = var.enable_vault ? 1 : 0

  name          = "alias/${local.name_prefix}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal[0].key_id
}

################################################################################
# Explicit KMS key policy for the unseal CMK.
#
# Without this, AWS applies a default policy that grants kms:* to the account
# root principal — too broad for an audit-friendly posture. We pin an explicit
# policy that:
#   1. Keeps the standard "EnableIAMUserPermissions" statement so account-root
#      can still manage the key (IAM policies layered on top of the key policy
#      keep working — this is the standard AWS pattern).
#   2. Explicitly grants the Vault IRSA role only the unseal-related actions
#      (Encrypt/Decrypt/DescribeKey/GenerateDataKey*) — the same set granted
#      by the identity-based policy below. Belt-and-suspenders: the key
#      policy AND the IAM policy both need to allow the action for it to
#      succeed (AWS evaluates both for cross-resource access).
################################################################################
data "aws_iam_policy_document" "vault_unseal_key" {
  count = var.enable_vault ? 1 : 0

  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "VaultIRSAUnsealAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.vault[0].arn]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = ["*"]
  }
}

resource "aws_kms_key_policy" "vault_unseal" {
  count  = var.enable_vault ? 1 : 0
  key_id = aws_kms_key.vault_unseal[0].key_id
  policy = data.aws_iam_policy_document.vault_unseal_key[0].json
}

################################################################################
# IRSA — IAM role assumed by the `vault:vault` ServiceAccount.
#
# Scoped to:
#   - kms:Encrypt / kms:Decrypt / kms:DescribeKey on the unseal CMK only.
#   - kms:GenerateDataKey* (required by AWS KMS for envelope encryption of the
#     master-key blob; the Vault `seal "awskms"` stanza calls this).
################################################################################
data "aws_iam_policy_document" "vault_assume" {
  count = var.enable_vault ? 1 : 0

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
      values   = ["system:serviceaccount:vault:vault"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vault" {
  count              = var.enable_vault ? 1 : 0
  name               = "${local.name_prefix}-vault"
  assume_role_policy = data.aws_iam_policy_document.vault_assume[0].json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "vault_unseal_perms" {
  count = var.enable_vault ? 1 : 0

  statement {
    sid    = "VaultAutoUnseal"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = [
      aws_kms_key.vault_unseal[0].arn,
    ]
  }
}

resource "aws_iam_policy" "vault_unseal" {
  count       = var.enable_vault ? 1 : 0
  name        = "${local.name_prefix}-vault-unseal"
  description = "Permits the Vault IRSA role to use the unseal CMK only."
  policy      = data.aws_iam_policy_document.vault_unseal_perms[0].json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "vault_unseal" {
  count      = var.enable_vault ? 1 : 0
  role       = aws_iam_role.vault[0].name
  policy_arn = aws_iam_policy.vault_unseal[0].arn
}

################################################################################
# Helm release — hashicorp/vault chart 0.30.x.
#
# Notes on the values shape (verified against chart 0.30.0):
#   - server.ha.{enabled,raft.enabled,replicas}  → HA Raft cluster
#   - server.ha.raft.config (HCL string)          → seal "awskms" stanza
#   - server.dataStorage.{size,storageClass}      → PVC per replica
#   - server.serviceAccount.{create,name,annotations} → IRSA wiring
#   - server.statefulSet.{pod,container}SecurityContext → PSA restricted
#   - server.readinessProbe / livenessProbe with conditional codes — Vault
#     answers /v1/sys/health with 200 only when unsealed + active; 429 for
#     standby, 472 for DR secondary, 501 for not-initialized, 503 for sealed.
#     The chart's default probes accept the sealed code so the pod is "ready"
#     enough for the auto-unseal init container to reach it.
################################################################################
resource "helm_release" "vault" {
  count = var.enable_vault ? 1 : 0

  name             = "vault"
  namespace        = kubernetes_namespace.vault[0].metadata[0].name
  create_namespace = false

  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = var.vault_chart_version

  timeout = 900
  wait    = true
  atomic  = true
  lint    = true

  values = [
    yamlencode({
      global = {
        # Open-source Vault — the chart also supports Vault Enterprise. We
        # target OSS here; Enterprise auto-unseal works identically with the
        # awskms seal so users that switch licenses don't change this file.
        enabled = true
        # See the TLS POSTURE banner at the top of this file: intra-cluster
        # plaintext is the documented default. Flip this to false (and wire
        # the listener tls_cert_file/tls_key_file) only when exposing Vault
        # via Ingress/NLB; until then this MUST match the listener's
        # tls_disable = 1 below or pods will refuse to come up.
        tlsDisable = true
      }

      # ──── injector — sidecar/init pattern. We default OFF and use ESO
      # instead (ExternalSecrets pulls Vault data into K8s Secrets, less
      # mutating-webhook surface, no per-pod annotation dance). Users that
      # want injector-style flows can override this with their own values.
      injector = {
        enabled = false
      }

      # ──── server — the Vault statefulset itself ──────────────────────────
      server = {
        # Run on the system node pool — Vault is cluster-critical.
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

        # Image pin — the chart's default already pins to a known-good Vault
        # OSS image tag; we set it explicitly so the SBOM is unambiguous.
        # NOTE: this explicit `image.tag = "1.18.4"` OVERRIDES the chart's
        # default tag. If the chart bumps (e.g. 0.31.0 ships with vault
        # 1.19.x), this pin stays put — you'll get the new chart wiring
        # against the old Vault binary, which is usually fine for one
        # minor but should be bumped in lockstep during planned upgrades.
        # To track the chart default instead, remove the `tag` key.
        image = {
          repository = "hashicorp/vault"
          tag        = "1.18.4"
          pullPolicy = "IfNotPresent"
        }

        # PSA restricted — pod-level.
        # UID 100 / GID 1000 match the hashicorp/vault image's baked-in user
        # (the image's `vault` user is UID 100, group `vault` is GID 1000).
        # Using a different UID here would leave PVC-mounted files owned by
        # someone Vault can't read.
        statefulSet = {
          securityContext = {
            pod = {
              runAsNonRoot = true
              runAsUser    = 100
              runAsGroup   = 1000
              fsGroup      = 1000
              seccompProfile = {
                type = "RuntimeDefault"
              }
            }
            container = {
              allowPrivilegeEscalation = false
              readOnlyRootFilesystem   = true
              runAsNonRoot             = true
              runAsUser                = 100
              capabilities = {
                drop = ["ALL"]
              }
            }
          }
        }

        # IRSA wiring — the chart's ServiceAccount picks up the role-arn
        # annotation, then Vault's seal "awskms" stanza authenticates to KMS
        # via the pod's projected token + sts:AssumeRoleWithWebIdentity.
        serviceAccount = {
          create = true
          name   = "vault"
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.vault[0].arn
          }
        }

        # ──── HA + Raft integrated storage ─────────────────────────────────
        # Raft is the recommended production backend (no external etcd/Consul
        # dependency). HCL config below is what Vault evaluates at boot.
        ha = {
          enabled  = true
          replicas = var.vault_replicas

          raft = {
            enabled   = true
            setNodeId = true

            # Raft cluster config + AWS KMS auto-unseal stanza. This HCL is
            # rendered into /vault/config/extraconfig-from-values.hcl by the
            # chart and merged into Vault's main config.
            #
            # SECURITY: `disable_mlock = true` is set because (a) mlock
            # requires IPC_LOCK which violates PSA restricted, and (b)
            # K8s kubelet doesn't swap pod memory by default — there's
            # nothing for mlock to lock against. See HashiCorp's K8s
            # production hardening docs.
            config = <<-EOT
              ui = true

              listener "tcp" {
                tls_disable     = 1
                address         = "[::]:8200"
                cluster_address = "[::]:8201"
              }

              storage "raft" {
                path = "/vault/data"
              }

              service_registration "kubernetes" {}

              seal "awskms" {
                region     = "${var.region}"
                kms_key_id = "${aws_kms_key.vault_unseal[0].key_id}"
              }

              # K8s pods don't swap; mlock just adds operational friction
              # (and a CAP_IPC_LOCK requirement that breaks PSA restricted).
              disable_mlock = true
            EOT
          }
        }

        # AWS KMS region passed via env so the AWS SDK in Vault's seal
        # plugin picks it up; the seal stanza also names it explicitly above.
        extraEnvironmentVars = {
          AWS_REGION         = var.region
          AWS_DEFAULT_REGION = var.region
          # The SDK reads VAULT_AWSKMS_SEAL_KEY_ID only when the seal stanza
          # doesn't carry it; we set the stanza so this is belt-and-braces.
          VAULT_AWSKMS_SEAL_KEY_ID = aws_kms_key.vault_unseal[0].key_id
        }

        # Persistent data for Raft. One PVC per replica via the statefulset.
        dataStorage = {
          enabled      = true
          size         = var.vault_storage_size
          mountPath    = "/vault/data"
          storageClass = "gp3" # the gp3 StorageClass made default by gp3-storageclass.tf
          accessMode   = "ReadWriteOnce"
        }

        # Audit-log volume — separate PVC so audit doesn't compete with Raft
        # for IOPS. Small (1 GiB) by default; users with high-volume audit
        # output should bump via their own values overlay.
        #
        # MANUAL POST-INSTALL STEP: this PVC is mounted but Vault's file
        # audit device is NOT auto-enabled by the chart. After first apply,
        # once Vault is initialized + unsealed, run:
        #
        #   kubectl -n vault exec -ti vault-0 -- vault audit enable file \
        #     path=/vault/audit/audit.log
        #
        # This is part of the Vault bootstrap sequence documented in
        # Part 15 ch.15.05 (alongside `vault operator init`, K8s auth
        # method config, the first ClusterSecretStore wiring, etc.).
        # Without this step, the PVC mounts cleanly but no audit log is
        # written — a silent compliance gap. Audit one of the first things
        # to enable after init.
        auditStorage = {
          enabled      = true
          size         = "1Gi"
          mountPath    = "/vault/audit"
          storageClass = "gp3"
          accessMode   = "ReadWriteOnce"
        }

        resources = {
          requests = {
            cpu    = "250m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "1000m"
            memory = "512Mi"
          }
        }

        # Readiness — accept the sealed code (503) during early startup so
        # the auto-unseal goroutine can run. Without this, the pod stays
        # NotReady forever and Vault never gets a chance to call KMS.
        readinessProbe = {
          enabled = true
          # uninitialized (501) + sealed (503) both count as "alive but not
          # serving yet" so the chart's default ?standbyok=true&sealedok=true
          # query strings are appropriate; we keep them via the chart default.
        }

        # Inheriting the chart's default probe with ?standbyok=true&sealedok=true
        # query (the canonical Vault HA probe — accepts standby + sealed
        # states as "alive" so the kubelet doesn't kill a pod that's
        # legitimately waiting on raft leader election or KMS unseal).
        livenessProbe = {
          enabled = true
        }

        # Anti-affinity — spread the 3 raft replicas across distinct nodes
        # (and ideally distinct AZs via topology spread; the chart's default
        # podAntiAffinity preferred-during-scheduling handles AZ spread).
        #
        # podAntiAffinity required-on-hostname (below) ensures one Vault pod
        # per node — strict, so it CAN cause unschedulable pods if the system
        # node pool has fewer nodes than vault_replicas. The chart's default
        # soft podAntiAffinity-on-topology.kubernetes.io/zone spreads pods
        # across AZs when az_count >= 3. With az_count = 2 and
        # vault_replicas = 3, two pods will land in one AZ — accept that
        # trade-off, or set vault_replicas = 1 for the dev path (single
        # replica, no quorum, no anti-affinity stress).
        affinity = {
          podAntiAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = [
              {
                labelSelector = {
                  matchLabels = {
                    "app.kubernetes.io/name"     = "vault"
                    "app.kubernetes.io/instance" = "vault"
                    component                    = "server"
                  }
                }
                topologyKey = "kubernetes.io/hostname"
              },
            ]
          }
        }
      }

      # ──── ui — Vault's web UI exposed as a ClusterIP.
      #
      # UI is enabled for operator convenience; access is via
      # `kubectl port-forward -n vault svc/vault 8200:8200`.
      # ClusterIP-only Service prevents accidental Ingress exposure.
      # publishNotReadyAddresses = true allows reaching sealed pods during init
      # (so an operator can hit /v1/sys/init from a not-yet-ready pod during
      # the first-boot bootstrap walk).
      # In production: either disable the UI entirely OR put it behind an
      # auth-proxy with audit logging (oauth2-proxy + Pomerium pattern).
      ui = {
        enabled                  = true
        serviceType              = "ClusterIP"
        publishNotReadyAddresses = true
      }

      # ──── csi — the Vault CSI provider for the Secrets Store CSI Driver.
      # We keep this OFF because ESO is the bridge we install separately.
      # Users that want CSI-mounted secrets can enable it via their own overlay.
      csi = {
        enabled = false
      }
    }),
  ]

  depends_on = [
    kubernetes_namespace.vault,
    aws_iam_role_policy_attachment.vault_unseal,
    aws_kms_alias.vault_unseal,
  ]
}

################################################################################
# Wait gate — give Vault's auto-unseal + raft-leader-election time to settle
# before downstream resources (ESO ClusterSecretStore CRs, app workloads)
# assume Vault is functional.
#
# `wait = true` + `atomic = true` on the helm_release above ensures pod
# readiness, but Vault's first-boot init (raft bootstrap, KMS unseal call,
# leader election) can take up to ~60s on a cold start. This `time_sleep`
# is the documented pattern: it doesn't gate Vault itself (Helm already
# does), it gates the ASSUMPTION that Vault is serving the API.
#
# We use `time_sleep` (from the hashicorp/time provider, pinned in
# versions.tf) rather than `null_resource` + `local-exec "sleep 60"` because
# the latter shells out to the OS — non-portable (no `sleep` on Windows
# without WSL) and non-deterministic in CI workers with different shells.
# `time_sleep` is OS-agnostic and reruns only when its inputs change
# (via the implicit dependency on helm_release.vault[0].id).
################################################################################
resource "time_sleep" "vault_warmup" {
  count = var.enable_vault ? 1 : 0

  # 60s is the documented worst-case for raft bootstrap + KMS unseal on a
  # cold cluster; in practice it's usually <30s on warm nodes.
  create_duration = "60s"

  triggers = {
    vault_release_id = helm_release.vault[0].id
  }

  depends_on = [
    helm_release.vault,
  ]
}
