################################################################################
# falco.tf — optional Falco install for runtime threat detection.
#
# Default OFF. Enable with `enable_falco = true`.
#
# What Falco watches:
#   - Syscalls via eBPF (file opens, exec, network connects, mounts).
#   - The Kubernetes audit log: not wired here (see the note at the end of
#     the Helm values).
#   - Compares observed behavior against a ruleset (the default rules cover
#     shell-in-container, sensitive-file reads, unexpected egress and
#     container-escape attempts).
#
# Cost: no AWS charge for Falco itself. It uses node CPU and memory, set by
# the resources block below.
#
# ────────────────────────────────────────────────────────────────────────────
# CHART-VALUES VERIFICATION
# These values were verified against the falcosecurity/falco chart at
# version 4.13.0. The keys that matter for daemonset privilege:
#   - driver.kind                       — selects the eBPF driver
#   - containerSecurityContext.*        — container-level (privileged, runAsUser)
#   - podSecurityContext.*              — pod-level (rarely needed for Falco)
#   - falcoctl.*                        — sub-chart for rule lifecycle
#   - serviceAccount.annotations        — IRSA via eks.amazonaws.com/role-arn
# To re-verify the privilege the rendered DaemonSet gets:
#   helm template falcosecurity/falco --version 4.13.0 \
#     --set driver.kind=modern_ebpf | grep -n 'privileged\|hostPID\|hostNetwork'
# ────────────────────────────────────────────────────────────────────────────
#
# ────────────────────────────────────────────────────────────────────────────
# PSA EXCEPTION: the falco namespace runs PSA enforce=privileged. The container
# is not privileged: driver.modernEbpf.leastPrivileged replaces privileged with
# CAP_BPF, CAP_PERFMON, CAP_SYS_RESOURCE and CAP_SYS_PTRACE. The DaemonSet still
# mounts host paths, among them the runtime sockets, and restricted and baseline
# both forbid hostPath, so the namespace stays privileged. Falco and kube-system
# (Cilium) are the two privileged namespaces in this Terraform tree.
# ────────────────────────────────────────────────────────────────────────────
################################################################################

################################################################################
# Falco namespace — PRIVILEGED PSA (intentional exception, see file header).
################################################################################
resource "kubernetes_namespace" "falco" {
  count = var.enable_falco ? 1 : 0

  metadata {
    name = "falco"

    labels = {
      # Falco's daemonset needs CAP_BPF/CAP_PERFMON and hostPath mounts.
      # PSA restricted cannot allow these. This namespace is one of the two
      # privileged namespaces in the tree (kube-system is the other).
      "pod-security.kubernetes.io/enforce"         = "privileged"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"           = "privileged"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/warn"            = "privileged"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    }
  }
}

################################################################################
# IRSA role for Falco — used when Falco publishes alerts to the SNS topic via
# the AWS API (sns:Publish). Created only when both Falco is enabled AND an
# alert email is configured (the only path that needs publish access today).
################################################################################
data "aws_iam_policy_document" "falco_assume" {
  count = var.enable_falco && trimspace(var.falco_alert_email) != "" ? 1 : 0

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
      values   = ["system:serviceaccount:falco:falco"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "falco" {
  count              = var.enable_falco && trimspace(var.falco_alert_email) != "" ? 1 : 0
  name               = "${local.name_prefix}-falco"
  assume_role_policy = data.aws_iam_policy_document.falco_assume[0].json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "falco_publish" {
  count = var.enable_falco && trimspace(var.falco_alert_email) != "" ? 1 : 0

  statement {
    sid       = "PublishFalcoAlerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.falco_alerts[0].arn]
  }
}

resource "aws_iam_policy" "falco_publish" {
  count       = var.enable_falco && trimspace(var.falco_alert_email) != "" ? 1 : 0
  name        = "${local.name_prefix}-falco-publish"
  description = "Permits the Falco IRSA role to sns:Publish to the falco-alerts topic only."
  policy      = data.aws_iam_policy_document.falco_publish[0].json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "falco_publish" {
  count      = var.enable_falco && trimspace(var.falco_alert_email) != "" ? 1 : 0
  role       = aws_iam_role.falco[0].name
  policy_arn = aws_iam_policy.falco_publish[0].arn
}

################################################################################
# Optional SNS forwarding — if falco_alert_email is set, create an SNS topic
# and a subscription. Falco's chart can emit alerts to a webhook, but this
# file does not configure that output; the wiring is left to the user.
################################################################################
resource "aws_sns_topic" "falco_alerts" {
  count = var.enable_falco && trimspace(var.falco_alert_email) != "" ? 1 : 0

  name              = "${local.name_prefix}-falco-alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = local.common_tags
}

# Topic policy: only the Falco IRSA role (in this account) can publish.
# aws:SourceAccount guards against confused-deputy if the role ARN ever
# gets cross-account-assumed by accident.
data "aws_iam_policy_document" "falco_sns_topic_policy" {
  count = var.enable_falco && trimspace(var.falco_alert_email) != "" ? 1 : 0

  statement {
    sid     = "AllowFalcoIRSAPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]
    resources = [
      aws_sns_topic.falco_alerts[0].arn,
    ]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.falco[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "falco_alerts" {
  count = var.enable_falco && trimspace(var.falco_alert_email) != "" ? 1 : 0

  arn    = aws_sns_topic.falco_alerts[0].arn
  policy = data.aws_iam_policy_document.falco_sns_topic_policy[0].json
}

resource "aws_sns_topic_subscription" "falco_alert_email" {
  count = var.enable_falco && trimspace(var.falco_alert_email) != "" ? 1 : 0

  topic_arn = aws_sns_topic.falco_alerts[0].arn
  protocol  = "email"
  endpoint  = var.falco_alert_email

  depends_on = [
    aws_sns_topic_policy.falco_alerts,
  ]
}

################################################################################
# Helm release
################################################################################
resource "helm_release" "falco" {
  count = var.enable_falco ? 1 : 0

  name             = "falco"
  namespace        = kubernetes_namespace.falco[0].metadata[0].name
  create_namespace = false

  repository = "https://falcosecurity.github.io/charts"
  chart      = "falco"
  version    = var.falco_chart_version

  timeout = 900
  wait    = true
  atomic  = true
  lint    = true

  values = [
    yamlencode({
      # ──── Driver ──────────────────────────────────────────────────────────
      # The modern eBPF driver — no kernel module, kernel >= 5.8 required.
      # AL2023 EKS-optimized AMIs ship a 6.x kernel; this is the default
      # supported path on EKS today.
      driver = {
        kind = "modern_ebpf"
        modernEbpf = {
          # Least privilege: the four capabilities below replace privileged.
          leastPrivileged = true
        }
      }

      tty = false

      # ──── Falco engine config (the `falco` key maps to falco.yaml fields).
      # falco.* keys are written to falco.yaml. No host namespace is set: the
      # chart 4.13.x DaemonSet runs in the pod's own network and PID namespaces.
      falco = {
        # Machine-readable output for SIEM ingestion.
        json_output                  = true
        json_include_output_property = true

        # Send to stdout — Falco's pod logs go to CloudWatch via the EKS
        # log forwarder. Add http_output for SNS / webhooks separately.
        stdout_output = {
          enabled = true
        }
        log_stderr = true

        # Tune to your noise level. "warning" is the typical signal/noise
        # sweet spot; "notice" is verbose; "info" is firehose. Rules below
        # the floor do not load, so NOTICE rules such as Terminal shell in
        # container stay off at "warning".
        priority = "warning"
      }

      # Default ruleset + the standard sub-rulesets for K8s audit and
      # workload-anomaly detection.
      falcoctl = {
        artifact = {
          install = {
            enabled = true
          }
          follow = {
            enabled = true
          }
        }
      }

      # Daemonset runs on every node, including Karpenter pools.
      tolerations = [
        {
          operator = "Exists"
          effect   = "NoSchedule"
        },
      ]

      # ──── containerSecurityContext (container-level) ──────────────────────
      # Not privileged. Setting this map replaces the chart's own capability
      # list, so the four capabilities of the least-privileged modern eBPF
      # driver are repeated here (verified by helm template, chart 4.13.0).
      # runAsUser = 0 pins UID 0, which the eBPF loader needs. See the PSA
      # EXCEPTION note at the top.
      containerSecurityContext = {
        runAsUser = 0
        capabilities = {
          add = ["BPF", "SYS_RESOURCE", "PERFMON", "SYS_PTRACE"]
        }
      }

      # ──── podSecurityContext (pod-level) ──────────────────────────────────
      # No fsGroup remap (Falco talks directly to /proc and /sys with its
      # own UID 0); seccompProfile RuntimeDefault is fine for the syscalls
      # the eBPF program triggers.
      podSecurityContext = {
        seccompProfile = {
          type = "RuntimeDefault"
        }
      }

      # ──── ServiceAccount — IRSA wiring (only when alerting is enabled) ────
      # When falco_alert_email is set, the service account carries the IRSA
      # role that can publish to the alerts topic. Nothing here makes Falco
      # publish; the output that does is yours to add (14.13, step 7). When
      # alerting is off, the annotations map is empty.
      serviceAccount = {
        create = true
        name   = "falco"
        annotations = trimspace(var.falco_alert_email) != "" ? {
          "eks.amazonaws.com/role-arn" = aws_iam_role.falco[0].arn
        } : {}
      }

      resources = {
        requests = {
          cpu    = "100m"
          memory = "512Mi"
        }
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }

      # No Kubernetes audit source is set here. The chart 4.13.x values have
      # no auditLog key, and the k8saudit plugin needs audit events sent to a
      # webhook. EKS writes its audit log to CloudWatch Logs; see 14.13.
    }),
  ]

  depends_on = [
    kubernetes_namespace.falco,
  ]
}
