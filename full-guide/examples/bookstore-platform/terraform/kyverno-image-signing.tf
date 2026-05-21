################################################################################
# kyverno-image-signing.tf — optional Kyverno install + ClusterPolicy that
# verifies images are cosign-signed.
#
# Default OFF. Enable with:
#   enable_image_signing         = true
#   image_signing_keyless_issuer = "https://token.actions.githubusercontent.com"
#   image_signing_keyless_subject = "https://github.com/your-org/.+"
#
# Why bother:
#   - Without image signing, your cluster will pull and run ANY image whose
#     pull-spec resolves. A compromised registry pushes a malicious tag with
#     the same name as your real image, and your cluster runs it.
#   - With keyless cosign signatures, only images signed by an OIDC identity
#     matching the configured issuer + subject can run.
#
# Default validationFailureAction: Audit. This is deliberate:
#   - "Audit" warns in the Kyverno policy-report CRD but DOES NOT BLOCK Pod
#     creation. Use this until your CI is reliably signing images and you've
#     verified zero policy-report warnings.
#   - Flip to "Enforce" later by editing the manifest below (or via Argo CD
#     if you've moved the policy out of Terraform).
#
# Excluded namespaces (kube-system, kyverno, falco, velero, bookstore-
# platform-system) are skipped because their images aren't signed by you.
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
      validationFailureAction = "Audit"
      background              = true
      webhookTimeoutSeconds   = 30

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
              imageReferences = ["*"]
              attestors = [
                {
                  entries = [
                    {
                      keyless = merge(
                        {
                          issuer = var.image_signing_keyless_issuer
                        },
                        trimspace(var.image_signing_keyless_subject) != "" ? {
                          subject = var.image_signing_keyless_subject
                        } : {},
                      )
                    },
                  ]
                },
              ]
              # Audit mode: a missing signature surfaces as a policy-report
              # warning instead of a Pod creation rejection.
              mutateDigest = true
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
