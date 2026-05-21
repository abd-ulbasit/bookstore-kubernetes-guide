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
#
# Production hardening (post-bootstrap):
#   - Wire SSO (argocd-server --oidc-config); rotate the initial admin.
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
# Argo CD Helm release — pinned to var.argocd_helm_chart_version. Restricted-
# compliant SecurityContexts on every component pod.
#
# CHART-VALUES NOTE: The argo-cd chart (7.7.x) does NOT honor
# `global.podSecurityContext` / `global.securityContext` for every component;
# each component (controller, server, repoServer, applicationSet, dex, redis,
# notifications) reads its own `<component>.podSecurityContext` and
# `<component>.containerSecurityContext` keys. We define the restricted
# values once in `local.argocd_secctx` and reference them per-component
# below. This is the chart-correct shape — verified against the chart's
# values.yaml schema for 7.7.10.
################################################################################

locals {
  # Pod-level restricted-compliant security context. Reused per-component.
  argocd_pod_secctx = {
    runAsNonRoot = true
    runAsUser    = 999
    runAsGroup   = 999
    fsGroup      = 999
    seccompProfile = {
      type = "RuntimeDefault"
    }
  }

  # Container-level restricted-compliant security context. Reused per-component.
  argocd_container_secctx = {
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    runAsNonRoot             = true
    runAsUser                = 999
    capabilities = {
      drop = ["ALL"]
    }
    seccompProfile = {
      type = "RuntimeDefault"
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
      # ──── controller — the application controller ────────────────────────
      controller = merge(local.argocd_node_pin, {
        replicas                 = 1
        podSecurityContext       = local.argocd_pod_secctx
        containerSecurityContext = local.argocd_container_secctx
      })

      # ──── server — argocd-server (UI + API) ──────────────────────────────
      server = merge(local.argocd_node_pin, {
        replicas                 = 2
        podSecurityContext       = local.argocd_pod_secctx
        containerSecurityContext = local.argocd_container_secctx
      })

      # ──── repoServer — clones Git repos + renders manifests ──────────────
      repoServer = merge(local.argocd_node_pin, {
        replicas                 = 2
        podSecurityContext       = local.argocd_pod_secctx
        containerSecurityContext = local.argocd_container_secctx
      })

      # ──── applicationSet — generates per-cluster/per-env Applications ────
      applicationSet = merge(local.argocd_node_pin, {
        replicas                 = 1
        podSecurityContext       = local.argocd_pod_secctx
        containerSecurityContext = local.argocd_container_secctx
      })

      # ──── notifications — Argo CD's notification controller ──────────────
      notifications = merge(local.argocd_node_pin, {
        podSecurityContext       = local.argocd_pod_secctx
        containerSecurityContext = local.argocd_container_secctx
      })

      # ──── dex — OIDC provider (off by default in this stack; kept aligned
      # in case users enable it via their own values).
      dex = merge(local.argocd_node_pin, {
        podSecurityContext       = local.argocd_pod_secctx
        containerSecurityContext = local.argocd_container_secctx
      })

      # ──── redis — in-process cache used by all components ────────────────
      # Redis runs as UID 999 in the chart; the restricted context matches.
      redis = merge(local.argocd_node_pin, {
        podSecurityContext       = local.argocd_pod_secctx
        containerSecurityContext = local.argocd_container_secctx
      })
    }),
  ]

  depends_on = [
    kubernetes_namespace.argocd,
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
      project = "default"

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
  ]
}
