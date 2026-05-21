################################################################################
# external-secrets.tf — optional External Secrets Operator (ESO).
#
# Default OFF. Enable with `enable_external_secrets = true`.
#
# What ESO is:
#   - A controller that watches `ExternalSecret` CRs in user namespaces.
#   - Each CR references a `SecretStore` or `ClusterSecretStore` that points
#     at an external secrets backend (Vault, AWS Secrets Manager, GCP SM,
#     Azure Key Vault, …).
#   - The controller pulls the referenced value, renders a Kubernetes Secret
#     in the same namespace, and refreshes it on a schedule.
#
# Why ESO over the Vault CSI provider or Vault Agent injector:
#   - One controller per cluster instead of a sidecar per pod (cheaper).
#   - No mutating admission webhook for annotation rewrites (simpler).
#   - Standard K8s Secret as the output — every consumer already understands it.
#   - Native rotation: change a value in Vault, ESO re-renders the Secret on
#     its next reconcile (default 1h interval, tunable per-ExternalSecret).
#
# Cost: $0 in AWS bill — runs as a small deployment on existing nodes.
#
# ────────────────────────────────────────────────────────────────────────────
# CR LIFECYCLE — what gets installed where:
#
#   Terraform (THIS FILE):
#     • `external-secrets` namespace
#     • The ESO controller Helm release + CRDs (ExternalSecret, SecretStore,
#       ClusterSecretStore, ClusterExternalSecret, PushSecret, …)
#     • IRSA role (if backend = AWS Secrets Manager; left empty by default
#       since Vault is the primary backend here and Vault auth uses
#       K8s ServiceAccount JWT, not IAM)
#
#   User namespaces (NOT here — owned by app charts / Argo CD Applications):
#     • `ClusterSecretStore` (one per backend): tells ESO how to reach Vault
#       (auth method = kubernetes, role = the Vault role bound to the SA).
#     • `ExternalSecret`: per-secret mapping (path in Vault → name + keys
#       in the target K8s Secret).
#
# Part 15 ch.15.05 walks the end-to-end ClusterSecretStore + ExternalSecret
# wiring against the Vault server installed by `vault.tf`.
# ────────────────────────────────────────────────────────────────────────────
#
# ────────────────────────────────────────────────────────────────────────────
# CHART-VALUES VERIFICATION (external-secrets/external-secrets v0.10.x)
# Verified keys against the upstream chart at v0.10.7:
#   - installCRDs                                — installs the CRD bundle
#   - replicaCount                               — controller replicas
#   - securityContext / podSecurityContext       — pod-level
#   - serviceAccount.{create,name,annotations}   — IRSA
#   - webhook.* + certController.*               — admission webhook + cert
#     subcomponents each have their own securityContext blocks
#   - resources                                  — controller CPU/mem
#   - leaderElect                                — required when replicaCount > 1
# To re-verify against your chart pin:
#   helm template external-secrets/external-secrets --version 0.10.7 --debug \
#     | grep -nE 'securityContext|replicas:'
# ────────────────────────────────────────────────────────────────────────────
################################################################################

################################################################################
# Namespace — PSA restricted.
#
# ESO's controller, webhook, and cert-controller pods all run as non-root
# and ship a restricted-compliant securityContext out of the chart. We pin
# explicit values below for symmetry with the rest of this tree.
################################################################################
resource "kubernetes_namespace" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  metadata {
    name = "external-secrets"

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
# IRSA — IAM role assumed by the `external-secrets:external-secrets`
# ServiceAccount.
#
# Default: an empty inline policy (`{}` document is invalid; we use a
# documented "no permissions" policy that allows the role to exist with no
# AWS-side privileges). Users that point ESO at AWS Secrets Manager or AWS
# Parameter Store attach a scoped secretsmanager:GetSecretValue / ssm:Get*
# policy to this role via their own Terraform overlay or aws-iam-policy
# resource — see Part 15 ch.15.05.
#
# When ESO is paired with Vault (the primary backend in this stack), the
# controller authenticates to Vault via the K8s ServiceAccount JWT — no AWS
# IAM permissions are required. The IRSA role is provisioned anyway so
# add-on backends can be enabled without an out-of-band role-bootstrap.
################################################################################
data "aws_iam_policy_document" "external_secrets_assume" {
  count = var.enable_external_secrets ? 1 : 0

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
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  count              = var.enable_external_secrets ? 1 : 0
  name               = "${local.name_prefix}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_assume[0].json
  tags               = local.common_tags

  # No inline policy or managed-policy attachment by default — users add
  # what they need (Vault: none; AWS SM: secretsmanager:GetSecretValue
  # scoped to their secret ARNs; etc).
}

################################################################################
# Helm release — external-secrets/external-secrets chart v0.10.x.
################################################################################
resource "helm_release" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  name             = "external-secrets"
  namespace        = kubernetes_namespace.external_secrets[0].metadata[0].name
  create_namespace = false

  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.eso_chart_version

  timeout = 600
  wait    = true
  atomic  = true
  lint    = true

  values = [
    yamlencode({
      # Install the CRD bundle (ExternalSecret, SecretStore, ClusterSecretStore,
      # ClusterExternalSecret, PushSecret). Always TRUE here — user-namespace
      # CRs require these CRDs to exist before they can be applied.
      #
      # installCRDs = true is fine for the initial install; for chart upgrades
      # across CRD-breaking versions (rare, but Helm cannot diff CRDs through
      # the normal release path), see
      # https://external-secrets.io/latest/guides/upgrading-crds/ — may
      # require a manual `kubectl apply --server-side` reconciliation of the
      # new CRDs before the chart upgrade lands.
      installCRDs = true

      # ──── Controller (the main reconciler) ───────────────────────────────
      replicaCount = 2
      leaderElect  = true

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

      # PSA restricted — pod-level.
      podSecurityContext = {
        runAsNonRoot = true
        runAsUser    = 65534
        runAsGroup   = 65534
        fsGroup      = 65534
        seccompProfile = {
          type = "RuntimeDefault"
        }
      }

      # PSA restricted — container-level.
      securityContext = {
        allowPrivilegeEscalation = false
        readOnlyRootFilesystem   = true
        runAsNonRoot             = true
        runAsUser                = 65534
        capabilities = {
          drop = ["ALL"]
        }
      }

      serviceAccount = {
        create = true
        name   = "external-secrets"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.external_secrets[0].arn
        }
      }

      resources = {
        requests = {
          cpu    = "10m"
          memory = "32Mi"
        }
        limits = {
          cpu    = "100m"
          memory = "128Mi"
        }
      }

      # ──── Webhook subcomponent (validates ES/SS CRs on admission) ────────
      webhook = {
        replicaCount = 2
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
        podSecurityContext = {
          runAsNonRoot = true
          runAsUser    = 65534
          runAsGroup   = 65534
          fsGroup      = 65534
          seccompProfile = {
            type = "RuntimeDefault"
          }
        }
        securityContext = {
          allowPrivilegeEscalation = false
          readOnlyRootFilesystem   = true
          runAsNonRoot             = true
          runAsUser                = 65534
          capabilities = {
            drop = ["ALL"]
          }
        }
        resources = {
          requests = {
            cpu    = "10m"
            memory = "32Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }

      # ──── Cert-controller subcomponent (mints + rotates webhook TLS) ─────
      certController = {
        replicaCount = 1
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
        podSecurityContext = {
          runAsNonRoot = true
          runAsUser    = 65534
          runAsGroup   = 65534
          fsGroup      = 65534
          seccompProfile = {
            type = "RuntimeDefault"
          }
        }
        securityContext = {
          allowPrivilegeEscalation = false
          readOnlyRootFilesystem   = true
          runAsNonRoot             = true
          runAsUser                = 65534
          capabilities = {
            drop = ["ALL"]
          }
        }
        resources = {
          requests = {
            cpu    = "10m"
            memory = "32Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }
    }),
  ]

  depends_on = [
    kubernetes_namespace.external_secrets,
  ]
}
