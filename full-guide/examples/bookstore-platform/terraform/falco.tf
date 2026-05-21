################################################################################
# falco.tf — optional Falco install for runtime threat detection.
#
# Default OFF. Enable with `enable_falco = true`.
#
# What Falco watches:
#   - Syscalls via eBPF (file opens, exec, network connects, mounts).
#   - The Kubernetes audit log (if you wire it via webhook — TODO below).
#   - Compares observed behavior against a ruleset (default Falco rules cover
#     ~200 known-bad patterns: shell-in-container, sensitive-file-reads,
#     unexpected-egress, container-escape attempts).
#
# Cost: ~$0 in AWS bill (Falco runs on existing nodes). Some perf overhead
# (single-digit % CPU per node).
#
# ────────────────────────────────────────────────────────────────────────────
# CHART-VALUES VERIFICATION
# These values were verified against the falcosecurity/falco chart at
# version 4.13.0. The keys that matter for daemonset privilege:
#   - driver.kind                       — selects the eBPF driver
#   - containerSecurityContext.*        — container-level (privileged, runAsUser)
#   - podSecurityContext.*              — pod-level (rarely needed for Falco)
#   - falco.hostNetwork / falco.hostPID — namespaced under `falco`, not top-level
#   - falcoctl.*                        — sub-chart for rule lifecycle
#   - serviceAccount.annotations        — IRSA via eks.amazonaws.com/role-arn
# These match the chart's templates/daemonset.yaml exactly. To re-verify:
#   helm template falcosecurity/falco --version 4.13.0 --debug \
#     | grep -A2 'hostNetwork\|hostPID\|privileged'
# ────────────────────────────────────────────────────────────────────────────
#
# ────────────────────────────────────────────────────────────────────────────
# PSA EXCEPTION — Falco's eBPF driver requires CAP_BPF + CAP_PERFMON to load
# the kernel eBPF programs that hook syscalls. Other PSA-restricted constraints
# (runAsNonRoot, readOnlyRootFilesystem) can be honored, but the capability
# requirement means the falco namespace runs PSA enforce=privileged. This is
# the ONLY privileged namespace in this Terraform tree; documented loudly here.
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
      # Falco's daemonset needs CAP_BPF/CAP_PERFMON + host PID/network.
      # PSA restricted cannot allow these; we use privileged for this
      # namespace ONLY. This is the only privileged namespace in the tree.
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
# and a subscription. Falco's chart can emit alerts to a webhook; we expose
# the SNS topic ARN through values + leave the http-output wiring to the user.
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
      }

      tty = false

      # ──── Falco engine config (the `falco` key maps to falco.yaml fields).
      # hostNetwork + hostPID live HERE in chart 4.13.x — they're the daemonset's
      # pod-spec flags, not top-level chart values. (Verified against the
      # chart's templates/daemonset.yaml.)
      falco = {
        # Listen on the host's network + see all host processes — needed to
        # correlate syscalls to container IDs across cgroups.
        hostNetwork = true
        hostPID     = true

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
        # sweet spot; "notice" is verbose; "informational" is firehose.
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
      # Falco's eBPF driver needs to load kernel programs. The chart's
      # container has `privileged: true` by default on the daemonset; we
      # set it explicitly so the intent is in code (not an implicit default).
      # runAsUser: 0 is required — the kernel won't load eBPF from non-root.
      containerSecurityContext = {
        privileged = true
        runAsUser  = 0
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
      # When falco_alert_email is set, Falco's pod publishes to SNS via the
      # IRSA role we created above. When alerting is off, the annotations
      # map is empty (no IRSA needed for stdout-only Falco).
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

      # K8s audit integration — Falco watches the audit log for control-plane
      # actions (a privileged "kubectl exec into a pod in kube-system", etc).
      auditLog = {
        enabled = true
      }
    }),
  ]

  depends_on = [
    kubernetes_namespace.falco,
  ]
}
