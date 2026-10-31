################################################################################
# argocd-bootstrap.tf — install Argo CD + create a root Application
# (App-of-Apps pattern) so the cluster self-provisions everything else.
#
# Default OFF. Enable with:
#   enable_argocd_bootstrap = true
#   argocd_repo_url         = "https://github.com/your-org/platform-gitops"
#   argocd_root_app_path    = "argocd/apps"
#
# The chicken-and-egg: Argo CD itself can't be installed by Argo CD (something
# has to bring it up first). So Terraform installs the controller; the root
# Application points at a Git repo whose `argocd/apps/` directory contains
# Application manifests for everything else — including, recursively, more
# Applications. This is the App-of-Apps pattern.
#
# After this runs:
#   1. kubectl port-forward svc/argo-cd-server -n argocd 8080:443
#   2. kubectl -n argocd get secret argocd-initial-admin-secret \
#        -o jsonpath="{.data.password}" | base64 -d
#   3. Log in at https://localhost:8080 as `admin`.
#   4. Change the password, then delete argocd-initial-admin-secret.
#
# Production hardening (post-bootstrap):
#   - Wire SSO (argocd-server --oidc-config); then disable the local admin.
#   - Expose argo-cd-server via a real Ingress + a real DNS + TLS.
#   - Set syncPolicy.automated.prune + selfHeal on all Applications.
################################################################################

# Precondition gate: argocd_repo_url required when enable_argocd_bootstrap is true.
resource "terraform_data" "argocd_precondition" {
  count = var.enable_argocd_bootstrap ? 1 : 0

  lifecycle {
    precondition {
      condition     = !var.enable_argocd_bootstrap || trimspace(var.argocd_repo_url) != ""
      error_message = "enable_argocd_bootstrap = true requires argocd_repo_url to be non-empty."
    }
  }
}

################################################################################
# Namespace — created with restricted PodSecurity labels.
################################################################################
resource "kubernetes_namespace" "argocd" {
  count = var.enable_argocd_bootstrap ? 1 : 0

  metadata {
    name = "argocd"

    labels = {
      # Pod Security Standards — Argo CD's controllers and the repo-server work
      # fine under restricted (no privileged escalations, no root containers).
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    }
  }

  depends_on = [
    module.eks,
    terraform_data.argocd_precondition,
  ]
}

################################################################################
# Argo CD Helm release — pinned to var.argocd_helm_chart_version.
#
# CHART-VALUES NOTE: argo-cd 7.7.10 has no podSecurityContext key. Pod-level
# context comes from global.securityContext, which every component reads except
# Redis (redis.securityContext), and container-level context comes from each
# component's containerSecurityContext. The keys were checked against the
# chart's templates at 7.7.10. The same values appear in the self-management
# Application in the 14.10 chapter; the two must stay identical.
################################################################################

locals {
  # Pod-level context for every Argo CD component except Redis. 999 is the UID
  # and GID the argocd image declares.
  argocd_pod_secctx = {
    runAsNonRoot = true
    runAsUser    = 999
    runAsGroup   = 999
    seccompProfile = {
      type = "RuntimeDefault"
    }
  }

  # Container-level context reused per component.
  argocd_container_secctx = {
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    capabilities = {
      drop = ["ALL"]
    }
  }

  # Pin every heavy Argo CD component on the system node group so it survives
  # Karpenter consolidation churn.
  argocd_node_pin = {
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
}

resource "helm_release" "argocd" {
  count = var.enable_argocd_bootstrap ? 1 : 0

  name             = "argo-cd"
  namespace        = kubernetes_namespace.argocd[0].metadata[0].name
  create_namespace = false

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_helm_chart_version

  timeout = 900
  wait    = true
  atomic  = true
  lint    = true

  values = [
    yamlencode({
      # Node placement and pod-level context for every component except Redis.
      global = merge(local.argocd_node_pin, {
        securityContext = local.argocd_pod_secctx
      })

      controller = {
        replicas                 = 1
        containerSecurityContext = local.argocd_container_secctx
      }

      server = {
        replicas                 = 2
        containerSecurityContext = local.argocd_container_secctx
      }

      # The repo-server calls no Kubernetes API, so it mounts no token.
      repoServer = {
        replicas                     = 2
        automountServiceAccountToken = false
        containerSecurityContext     = local.argocd_container_secctx
      }

      applicationSet = {
        replicas                 = 1
        containerSecurityContext = local.argocd_container_secctx
      }

      notifications = {
        containerSecurityContext = local.argocd_container_secctx
      }

      # Dex keeps its ServiceAccount token: argocd-dex builds a Kubernetes
      # client at startup, and the chart's argocd-dex-server Role grants its
      # reads. The Dex image declares 1001:1001, so its container overrides
      # the pod UID.
      dex = {
        containerSecurityContext = merge(local.argocd_container_secctx, {
          runAsUser  = 1001
          runAsGroup = 1001
        })
      }

      # Redis reads its own pod context and gets a dedicated ServiceAccount.
      redis = {
        automountServiceAccountToken = false
        serviceAccount = {
          create = true
        }
        securityContext = {
          runAsNonRoot = true
          runAsUser    = 999
          seccompProfile = {
            type = "RuntimeDefault"
          }
        }
        containerSecurityContext = local.argocd_container_secctx
      }
    }),
  ]

  depends_on = [
    kubernetes_namespace.argocd,
  ]
}

################################################################################
# Bootstrap AppProject — the only project the root Application uses. It allows
# no cluster-scoped kinds and lets the root create Applications and AppProjects
# in the argocd namespace, nothing else.
################################################################################
resource "kubectl_manifest" "argocd_bootstrap_project" {
  count = var.enable_argocd_bootstrap ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "platform-bootstrap"
      namespace = "argocd"
    }
    spec = {
      description = "Root of the App-of-Apps tree. Creates Applications and AppProjects only."
      sourceRepos = [var.argocd_repo_url]
      destinations = [
        {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        },
      ]
      clusterResourceWhitelist = []
      namespaceResourceWhitelist = [
        { group = "argoproj.io", kind = "Application" },
        { group = "argoproj.io", kind = "AppProject" },
      ]
    }
  })

  depends_on = [
    helm_release.argocd,
  ]
}

################################################################################
# Root Application — the entry point for App-of-Apps. Argo CD itself watches
# this Application and syncs everything under argocd_root_app_path.
################################################################################
resource "kubectl_manifest" "argocd_root_app" {
  count = var.enable_argocd_bootstrap ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root-app"
      namespace = "argocd"
      labels = {
        "bookstore-platform.example.com/role" = "root-app"
      }
      # finalizer ensures Argo CD cascades deletes of child Applications
      # before this one is removed (no orphan workloads).
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "platform-bootstrap"

      source = {
        repoURL = var.argocd_repo_url
        path    = var.argocd_root_app_path
        # Pinning to a named ref (default "main") rather than "HEAD". HEAD is
        # an Argo CD shortcut that hides which branch is actually tracked;
        # the named ref shows in `argocd app get` and in the UI. For
        # production, pin to an immutable tag (e.g. "v1.2.3") — see the
        # README's GitOps section for the tag-promotion pattern.
        targetRevision = var.argocd_target_revision
        directory = {
          recurse = true
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.argocd_bootstrap_project,
  ]
}
