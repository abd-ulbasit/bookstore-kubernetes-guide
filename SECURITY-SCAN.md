# Security Scan Baseline

**Last hand-verified:** 2026-07-27
**Scanned by:** [`.github/workflows/security-scan.yml`](.github/workflows/security-scan.yml) (runs weekly + on push to `main`)
**Local-equivalent commands:** `make scan-trivy scan-tfsec scan-go`

This document is the **hand-written triage** of the findings the security
scanners produce against the repo: which are real, which are accepted, and
*why*. It is **not** auto-generated and carries **no live counts** — the
[Security tab](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/security/code-scanning)
is the live source of truth, and each workflow run writes a coverage summary
listing exactly what was scanned. Numbers quoted below are point-in-time
measurements with the date they were taken; treat them as illustrative of
*shape*, not as a current tally.

A core honesty principle: **finding count ≠ security**. Each finding below
is either *real and tracked*, *accepted with a documented reason*, or
*false positive against an educational anti-pattern intentionally shown*.

> **2026-07-27 — this page was materially wrong, and so was the scanner.**
> Three claims here were false: that the workflow regenerated this file (it
> never had such a step), that there were 4 Go-module vulnerabilities (there
> were 91 open Go/CVE alerts), and that a `runAsNonRoot` item had been
> "filed as an action item" (no such issue existed). The root cause of the
> undercount was a **scanner blind spot**: the govulncheck job built its path
> as `full-guide/examples/bookstore-platform/app/<service>`, so it only ever
> scanned the Platform v2 tree. `examples/bookstore/` — the canonical tree
> Parts 02–08 tell readers to run — was never scanned, and had drifted onto
> `pgx v5.7.5`, carrying [GO-2026-5004](https://pkg.go.dev/vuln/GO-2026-5004)
> (SQL injection via placeholder confusion), reachable from `loadBooks`.
> `make scan-go` had the same hardcoded path, so local runs agreed with CI —
> both wrong. Both now **discover** modules instead of listing them. The
> affected modules were bumped; see §1.1.

---

## 1) Filesystem scan — Trivy

Scanner: `trivy fs --severity HIGH,CRITICAL --scanners vuln,secret,misconfig`

Open Code Scanning alerts as measured on **2026-07-27**, before the fixes in
this pass landed (`gh api .../code-scanning/alerts?state=open`):

| Class | Count (2026-07-27) | Status |
|---|---:|---|
| **Vulnerabilities** (Go modules, `CVE-*`/`GO-*`) | 91 | Bumped to clean — see §1.1 |
| **Secrets** (any) | 0 | ✓ clean |
| **Misconfigurations** (K8s, `KSV-*`) | 637 | Dominated by repeated rules across the example trees; triage by *category* in §1.3, not by count |
| **Misconfigurations** (Terraform, `AWS-*`) | 17 | See §2 |
| **Misconfigurations** (Dockerfile, `DS-*`) | 14 | Base-image + root-FS rules across the example Dockerfiles |

Counts are high because every rule fires once per manifest per example tree,
and the guide ships many deliberately-illustrative manifests. That is exactly
why this page triages by category and reason rather than chasing a number to
zero.

### 1.1) Vulnerabilities — fixed 2026-07-27

Previously logged here as "accepted (pinned-stub status)". That framing was
wrong: two of the three affected modules are **not** stubs, they are the
canonical `examples/bookstore/` services a reader is told to build and run.
They have been bumped rather than accepted.

| Advisory | Package | Where | Status |
|---|---|---|---|
| [GO-2026-5004](https://pkg.go.dev/vuln/GO-2026-5004) (SQL injection) | `github.com/jackc/pgx/v5` | `examples/bookstore/app/catalog`, `examples/bookstore/app/orders` | **Fixed** — `v5.7.5` → `v5.9.2`. govulncheck confirmed the vulnerable symbol was *actually reachable* (`loadBooks` → `pgxpool.Pool.Query` → `sanitize.SanitizeSQL`), not merely present. |
| [GO-2026-5970](https://pkg.go.dev/vuln/GO-2026-5970) (infinite loop) | `golang.org/x/text` | `examples/bookstore/app/catalog`, `examples/bookstore/app/orders`, `examples/bookstore/operator` | **Fixed** — `v0.25.0`/`v0.17.0` → `v0.39.0`. |
| [GO-2026-5026](https://pkg.go.dev/vuln/GO-2026-5026), [GO-2026-4918](https://pkg.go.dev/vuln/GO-2026-4918) | `golang.org/x/net` | `examples/bookstore/operator` | **Fixed** — `v0.28.0` → `v0.56.0`. |
| CVE-2025-22868 | `golang.org/x/oauth2` | `examples/bookstore/operator` | **Fixed** — `v0.21.0` → `v0.33.0`. |

The operator's `controller-runtime v0.19.x` + `k8s.io/* v0.31.x` pins are
deliberate (they are mutually consistent and target the guide's Kubernetes
floor) and were **not** touched; only the vulnerable `golang.org/x/*`
transitives moved. Its `go` directive rose `1.23.0` → `1.25.0` because the
patched `x/net` requires it.

`govulncheck ./...` now reports **zero module-level vulnerabilities across
all 11 Go modules**. Remaining govulncheck output on a developer laptop is
standard-library findings against whatever local toolchain is installed;
CI pins Go 1.26.5, which is at or above every current stdlib fix version.

### 1.2) Secrets — 0

No real credentials, account IDs, or private keys detected in the working
tree. This is also enforced by the [`leak-scan`](.github/workflows/example-trees-check.yml)
CI job with a separate regex pass, so two independent scanners agree.

### 1.3) Misconfigurations — triaged by category

The bulk of misconfig findings hit Kubernetes RBAC + ConfigMap content
that's intentionally permissive *because the resource is a platform-level
control plane*, not a workload. The categories:

| Category | Count | Status | Why |
|---|---:|---|---|
| **Platform RBAC roles** under `platform-base/01-rbac.yaml` | ~70 | **Accepted** | The bookstore-platform-admin ClusterRole *is* the platform-admin role — wildcards on verbs and resources are the point. The neighboring `bookstore-platform-developer` role is not wildcard. The guide chapter that introduces this role (`13-grand-capstone/01-the-bookstore-platform-shape.md`) labels it explicitly. |
| **Backstage ConfigMap with secrets** (`KSV-0109`) | 1 | **Accepted (educational)** | The Backstage `app-config.yaml` snippet in `13-grand-capstone/03-backstage-on-day-one.md` includes `${GITHUB_TOKEN}` placeholder + an inline OIDC client secret. The chapter explicitly teaches "this is what the file looks like; in production these come from Vault via ESO and the ConfigMap holds only the `${ENV_VAR}` references." The example file is the teaching artifact. |
| **`runAsNonRoot`** missing (`KSV-0012`) | 2 | **Accepted (frozen teaching seeds)** | Not cronjobs — the earlier text here was wrong on both the count and the location. The only two Pod specs in the repo without `runAsNonRoot` are [`raw-manifests/01-catalog-pod.yaml`](full-guide/examples/bookstore/raw-manifests/01-catalog-pod.yaml) (Part 00 ch.06, the minimal spec/status object-model seed) and [`raw-manifests/02-catalog-pod-sidecar.yaml`](full-guide/examples/bookstore/raw-manifests/02-catalog-pod-sidecar.yaml) (Part 01 ch.01–02). Both live in `default`, both are explicitly frozen — Part 01 ch.03 tells the reader they are *"frozen teaching snapshots; don't edit them"* — and both are reproduced verbatim in chapter prose that walks them field by field. Hardening is taught as a deliberate later increment in [Part 05 ch.02](full-guide/05-security/02-pod-security.md); every Pod that can land in the `bookstore` namespace **is** `restricted`-valid — enforced on every run by [`check-runasnonroot.py`](.github/scripts/check-runasnonroot.py), which currently checks 49 Pod specs across the raw manifests, the rendered Helm chart, and all three Kustomize overlays, and fails if this exemption list grows *or* stops applying. Note the app container is non-root at runtime regardless: `app/catalog/Dockerfile` sets `USER 65532:65532` on `gcr.io/distroless/static:nonroot`. The finding is that the *manifest* does not assert it, which is true and intended at that point in the arc. |

---

## 2) Terraform — tfsec 1.28.14

Scanner: `tfsec --no-color --soft-fail` on each tree.

| Tree | CRITICAL | HIGH | MEDIUM | LOW |
|---|---:|---:|---:|---:|
| `examples/bookstore-platform/terraform` | 3 | 0 | 2 | 0 |
| `examples/bookstore-platform/terraform-account-baseline` | 0 | 0 | 0 | 0 |

> **Read the `File:Line` column below carefully.** These findings are raised
> against the **upstream `terraform-aws-modules/*` source** that `terraform
> init` downloads (`terraform-aws-modules/eks/aws/main.tf`,
> `.../vpc/aws/main.tf`), not against this repo's own `.tf` files. What this
> repo controls is the *input variables* it passes; that is what the
> acceptances below are actually about. The second MEDIUM is `AWS-0342`
> inside the vendored Karpenter submodule — upstream module code this repo
> does not configure, listed here only so the table matches what the Security
> tab shows.

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

Scanner: `govulncheck ./...` per module, run in CI from
[`.github/workflows/security-scan.yml`](.github/workflows/security-scan.yml).

The module list is **discovered** (`find full-guide/examples -name go.mod`),
not hardcoded, and a `discover-go-modules` job fails outright if it finds zero
modules — a green scan over an empty matrix is the failure mode that hid
GO-2026-5004, and it should never look like success again. As of 2026-07-27
that discovers **11 modules**; the previous hardcoded list covered 7, all in
the Platform v2 tree.

Findings surface as a **matrix-job failure**, one job per module, so the
failing module is named in the job title. They do *not* produce a SARIF
upload — govulncheck's SARIF output is not wired up, and an earlier version
of this page wrongly claimed it was. Trivy is what populates the Security tab
for Go modules. Local-equivalent: `make scan-go`, which uses the same
discovery so it cannot drift from CI.

The overlap with §1.1 is the same set of vulnerabilities seen two ways:
Trivy reports *any* vulnerable dependency, govulncheck reports the ones whose
vulnerable symbols are *actually reachable* from the service's own code. That
distinction is what made GO-2026-5004 urgent rather than theoretical.

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
3. **"It's only a stub" is not an acceptance reason.** This principle used
   to read *"stub services have older pins… they aren't exercised."* That
   reasoning is retired. It was used to defer a reachable SQL-injection
   advisory in `examples/bookstore/`, which is not a stub at all — it is the
   tree Parts 02–08 tell readers to build and run. Vulnerable pins in any
   example a reader is invited to copy get fixed, not filed. Deliberately
   old pins that *teach* something (a chapter demonstrating an upgrade) must
   say so in the chapter and be listed explicitly here.

4. **Acceptances are executable where they can be.** The `runAsNonRoot`
   acceptance in §1.3 is enforced by
   [`.github/scripts/check-runasnonroot.py`](.github/scripts/check-runasnonroot.py),
   which fails CI both when a new unhardened Pod spec appears *and* when an
   allowlisted file no longer needs its exemption. An acceptance list that
   can only silently grow is not a control.

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
