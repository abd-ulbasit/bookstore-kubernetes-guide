################################################################################
# kyverno-image-signing.tf — optional Kyverno install + ClusterPolicy that
# verifies images are cosign-signed.
#
# Default OFF. Enable with:
#   enable_image_signing          = true
#   image_signing_keyless_issuer  = "https://token.actions.githubusercontent.com"
#   image_signing_keyless_subject = "https://github.com/<ORG>/<REPO>/.github/workflows/<WORKFLOW>.yml@refs/heads/main"
#   image_signing_image_references = ["ghcr.io/<ORG>/*"]   # your images only
#
# The subject is REQUIRED (variable validation fails without it). It is the
# whole point of keyless verification. The issuer alone says "signed by
# some GitHub Actions workflow", and anyone can run one of those: an
# attacker's own repo produces a signature that passes an issuer-only check.
# Pin the exact workflow file AND ref that builds your images. Kyverno
# matches `subject` literally (with * and ? wildcards), not as a regex.
# Even a correct wildcard like https://github.com/<ORG>/* trusts every
# workflow on every branch of every repo in the org, PR branches included.
#
# Why bother:
#   - Without image signing, your cluster will pull and run ANY image whose
#     pull-spec resolves. A compromised registry pushes a malicious tag with
#     the same name as your real image, and your cluster runs it.
#   - With keyless cosign signatures, only images signed by an OIDC identity
#     matching the configured issuer + subject can run.
#
# Default failureAction: Audit. This is deliberate, and it means
# this policy BLOCKS NOTHING until you change it:
#   - "Audit" warns in the Kyverno policy-report CRD but DOES NOT BLOCK Pod
#     creation. Use this until your CI is reliably signing images and you've
#     verified zero policy-report warnings.
#   - Flip to "Enforce" with image_signing_validation_failure_action =
#     "Enforce" (or via Argo CD if you've moved the policy out of
#     Terraform). Narrow image_signing_image_references first, or every
#     third-party image in a non-excluded namespace is rejected.
#
# Excluded namespaces (kube-system, kube-public, kube-node-lease, kyverno,
# falco, velero, argocd, bookstore-platform-system) are skipped because
# their images aren't signed by you.
################################################################################

################################################################################
# Kyverno namespace
################################################################################
resource "kubernetes_namespace" "kyverno" {
  count = var.enable_image_signing ? 1 : 0

  metadata {
    name = "kyverno"

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
# Kyverno Helm release
################################################################################
resource "helm_release" "kyverno" {
  count = var.enable_image_signing ? 1 : 0

  name             = "kyverno"
  namespace        = kubernetes_namespace.kyverno[0].metadata[0].name
  create_namespace = false

  repository = "https://kyverno.github.io/kyverno/"
  chart      = "kyverno"
  version    = var.kyverno_chart_version

  timeout = 900
  wait    = true
  atomic  = true
  lint    = true

  values = [
    yamlencode({
      # Admission controller HA. Three replicas (one per AZ) is the
      # production-grade default.
      admissionController = {
        replicas = 3

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
          runAsUser    = 65532
          runAsGroup   = 65532
          fsGroup      = 65532
          seccompProfile = {
            type = "RuntimeDefault"
          }
        }

        container = {
          securityContext = {
            allowPrivilegeEscalation = false
            readOnlyRootFilesystem   = true
            runAsNonRoot             = true
            runAsUser                = 65532
            capabilities = {
              drop = ["ALL"]
            }
          }
        }
      }

      # The background controller scans existing objects against new policies.
      backgroundController = {
        replicas = 1
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
      }

      # The reports controller produces the policy-report CRDs that "Audit"
      # mode populates.
      reportsController = {
        replicas = 1
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
      }

      cleanupController = {
        replicas = 1
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
      }
    }),
  ]

  depends_on = [
    kubernetes_namespace.kyverno,
  ]
}

################################################################################
# ClusterPolicy: require-signed-images.
#
# Audit-first by design — production teams should run in Audit for 2-4 weeks
# to surface unsigned-image findings BEFORE flipping to Enforce.
################################################################################
resource "kubectl_manifest" "require_signed_images_policy" {
  count = var.enable_image_signing ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-signed-images"
      annotations = {
        "policies.kyverno.io/title"       = "Require Cosign-Signed Images"
        "policies.kyverno.io/category"    = "Supply Chain Security"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "Require all Pod container images to carry a valid cosign keyless signature matching the configured OIDC issuer + subject."
      }
    }
    spec = {
      background            = true
      webhookTimeoutSeconds = 30

      rules = [
        {
          name = "verify-image-signatures"

          match = {
            any = [
              {
                resources = {
                  kinds = ["Pod"]
                }
              },
            ]
          }

          # Skip namespaces whose images aren't signed by the user.
          exclude = {
            any = [
              {
                resources = {
                  namespaces = [
                    "kube-system",
                    "kube-public",
                    "kube-node-lease",
                    "kyverno",
                    "falco",
                    "velero",
                    "argocd",
                    "bookstore-platform-system",
                  ]
                }
              },
            ]
          }

          verifyImages = [
            {
              imageReferences = var.image_signing_image_references
              attestors = [
                {
                  entries = [
                    {
                      # Issuer AND subject, always. The variable validation
                      # guarantees a non-empty subject when this policy exists.
                      keyless = {
                        issuer  = var.image_signing_keyless_issuer
                        subject = var.image_signing_keyless_subject
                      }
                    },
                  ]
                },
              ]
              # Audit records a missing or mismatched signature in a policy
              # report; Enforce rejects the Pod. Kyverno 1.13 (chart 3.3.x)
              # reads the failure action here; the spec-level field is
              # deprecated.
              failureAction = var.image_signing_validation_failure_action
              mutateDigest  = true
              required     = true
              verifyDigest = true
            },
          ]
        },
      ]
    }
  })

  depends_on = [
    helm_release.kyverno,
  ]
}
