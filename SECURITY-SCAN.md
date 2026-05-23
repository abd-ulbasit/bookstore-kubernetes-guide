# Security Scan Baseline

**Scan date:** 2026-05-23
**Scanned by:** [`.github/workflows/security-scan.yml`](.github/workflows/security-scan.yml) (runs weekly + on push to `main`)
**Local-equivalent commands:** `make scan-trivy scan-tfsec scan-go`

This document is the **triaged baseline** of every finding the security
scanners produce against the repo. The workflow refreshes it on every
weekly run and uploads SARIF reports to the GitHub Security tab; this
file is the human-readable summary plus the *why* for each finding we've
chosen to accept rather than fix.

A core honesty principle: **finding count ≠ security**. Each finding below
is either *real and tracked*, *accepted with a documented reason*, or
*false positive against an educational anti-pattern intentionally shown*.

---

## 1) Filesystem scan — Trivy 0.70

Scanner: `trivy fs --severity HIGH,CRITICAL --scanners vuln,secret,misconfig`

| Class | Count | Status |
|---|---:|---|
| **Vulnerabilities** (Go modules) | 4 | All in stub services with old pinned deps — see §1.1 |
| **Secrets** (any) | 0 | ✓ clean |
| **Misconfigurations** (K8s manifests) | 87 | 84 are intentional educational/platform-level patterns; 3 worth following up — see §1.3 |

### 1.1) Vulnerabilities — accepted (pinned-stub status)

| CVE | Package | Where | Status |
|---|---|---|---|
| CVE-2026-33816 (CRITICAL) | `github.com/jackc/pgx/v5` | `examples/bookstore-platform/app/events/go.mod`, `examples/bookstore/app/catalog/go.mod`, `examples/bookstore/app/orders/go.mod` | **Tracked** — the affected services are Phase 16 stubs. Real-service catalog promotion (in progress) pins to a patched version; the other stubs upgrade with the same PR. |
| CVE-2025-22868 (HIGH) | `golang.org/x/oauth2` | `examples/bookstore/operator/go.mod` | **Tracked** — bump on the next operator-development chapter refresh. |

### 1.2) Secrets — 0

No real credentials, account IDs, or private keys detected in the working
tree. This is also enforced by the [`leak-scan`](.github/workflows/example-trees-check.yml)
CI job with a separate regex pass, so two independent scanners agree.

### 1.3) Misconfigurations — 84 accepted, 3 worth following up

The bulk of misconfig findings hit Kubernetes RBAC + ConfigMap content
that's intentionally permissive *because the resource is a platform-level
control plane*, not a workload. The three categories:

| Category | Count | Status | Why |
|---|---:|---|---|
| **Platform RBAC roles** under `platform-base/01-rbac.yaml` | ~70 | **Accepted** | The bookstore-platform-admin ClusterRole *is* the platform-admin role — wildcards on verbs and resources are the point. The neighboring `bookstore-platform-developer` role is not wildcard. The guide chapter that introduces this role (`13-grand-capstone/01-the-bookstore-platform-shape.md`) labels it explicitly. |
| **Backstage ConfigMap with secrets** (`KSV-0109`) | 1 | **Accepted (educational)** | The Backstage `app-config.yaml` snippet in `13-grand-capstone/03-backstage-on-day-one.md` includes `${GITHUB_TOKEN}` placeholder + an inline OIDC client secret. The chapter explicitly teaches "this is what the file looks like; in production these come from Vault via ESO and the ConfigMap holds only the `${ENV_VAR}` references." The example file is the teaching artifact. |
| **`runAsNonRoot`** missing on a handful of utility/cronjob Pods | 3 | **Tracked** — to fix | Real follow-up. Cronjobs that don't need root should declare it. Filed as an action item. |

---

## 2) Terraform — tfsec 1.28.14

Scanner: `tfsec --no-color --soft-fail` on each tree.

| Tree | CRITICAL | HIGH | MEDIUM | LOW |
|---|---:|---:|---:|---:|
| `examples/bookstore-platform/terraform` | 3 | 0 | 1 | 0 |
| `examples/bookstore-platform/terraform-account-baseline` | 0 | 0 | 0 | 0 |

### 2.1) Critical findings — all documented intentional

| Rule | File:Line | Status | Why |
|---|---|---|---|
| `AVD-AWS-0040` Public cluster access enabled | `main.tf:70` | **Accepted (DEV default; production override documented)** | `cluster_endpoint_public_access = true` is the default *for the DEV example* so a reader can `kubectl` from their laptop without setting up a bastion. The variable is gated; the chapter explicitly teaches `cluster_endpoint_public_access = false` for production. |
| `AVD-AWS-0041` Cluster public CIDR `0.0.0.0/0` | `main.tf:71` | **Accepted (DEV default; production override documented)** | Paired with AVD-0040. `cluster_endpoint_public_access_cidrs` defaults to `["0.0.0.0/0"]` for the DEV example. Production: scope to the operator egress CIDR. Same gating + chapter discussion as above. |
| `AVD-AWS-0104` Security group egress to internet | `node_groups.tf:247` | **Accepted** | Worker nodes egress to the internet for ECR image pulls + EKS addon delivery. The alternative is a fully private cluster with VPC endpoints for ECR-API + ECR-DKR + S3 — covered in ch.14.08 (`var.enable_vpc_endpoints = true`). |

### 2.2) Medium finding — tracked

| Rule | File:Line | Status |
|---|---|---|
| `AVD-AWS-0178` VPC Flow Logs not enabled | `main.tf:28` | **Tracked** — add a `var.enable_vpc_flow_logs = false` default-off variable per the var-gating convention. |

### 2.3) `terraform-account-baseline` — clean

Zero findings at all severity levels. The baseline tree is the account-wide
guardrail layer (CloudTrail, GuardDuty, Security Hub, IAM Access Analyzer);
it provisions controls, not workloads, so the surface for misconfig
findings is much smaller. Worth noting: tfsec doesn't validate that the
*controls themselves* are correctly scoped — that's a separate review pass.

---

## 3) Go vulnerabilities — govulncheck

Scanner: `govulncheck ./...` per service, run in CI from
[`.github/workflows/security-scan.yml`](.github/workflows/security-scan.yml).

The CI job runs against every service with a `go.mod`. Findings (if any)
surface as a matrix-job failure and as a SARIF upload to the Security
tab. Local-equivalent: `make scan-go`. The known vulnerability findings
that overlap with §1.1 are the same vulnerabilities; govulncheck additionally
confirms which symbols are *actually called* by the service (Trivy reports
*any* vulnerable dependency; govulncheck reports *exercised* vulnerabilities).

---

## 4) Standing acceptance principles

Some findings will recur on every scan because they are *intentional
educational content*. We document them once here rather than triaging
each scan:

1. **Permissive examples are flagged as security teaching artifacts.** The
   guide intentionally shows the `default-allow NetworkPolicy`, the
   wildcard RBAC role, the `runAsRoot: true` Pod, in chapters that say
   *"here is what NOT to do, and here is why a scanner will yell at you."*
   The next chapter shows the production-shape correction. Both stay in
   the example tree because removing the anti-pattern removes the lesson.
2. **DEV defaults are not production defaults.** Several Terraform
   variables default to the *demo-friendly* value (public cluster
   endpoint, broad node egress) so a reader can apply the tree on a
   sandbox account and reach the cluster. The chapter for each one
   teaches the production override. Scanners flagging the DEV default is
   correct — the *acceptance* is that the demo and the production
   path differ deliberately.
3. **Stub services have older pins.** The Phase 16 service stubs were
   pinned when introduced and haven't been bumped because they aren't
   exercised. Promoting `catalog/` to a real service is the trigger for
   bumping all stubs in a single coordinated PR.

---

## 5) What this baseline is *for*

* **Recruiters / interviewers** — confirms that security scanning is
  done, on a schedule, with findings triaged honestly rather than
  ignored. A clean scan report on a project this size would be a red
  flag, not a green one.
* **Contributors** — gives an explicit list of what's accepted so a PR
  doesn't accidentally "fix" an intentional educational artifact.
* **Future-me** — when the next scanner version surfaces a new finding,
  this page is the place to triage it (real fix vs. add to acceptance
  table).
