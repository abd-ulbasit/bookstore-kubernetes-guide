# Security Scan Baseline

**Last hand-verified:** 2026-10-24 (sections 1.1, 1.2, 2 header, 6); 2026-07-27 (the rest)
**Scanned by:** [`.github/workflows/security-scan.yml`](.github/workflows/security-scan.yml) (runs weekly + on push to `main`)
**Local-equivalent commands:** `make scan-trivy scan-terraform scan-go scan-secrets`
**Scanner versions in CI:** Trivy v0.76.1 (trivy-action's `version:` input; Dependabot bumps the action's SHA but not this input, so it is bumped by hand), govulncheck v1.9.0, gitleaks v8.30.1. The `make` targets use whatever is installed locally; for Trivy, use v0.76.1 or later (v0.70.0, the action's own default, is affected by GHSA-mcj4-mphf-j9ff and GHSA-q3fv-x8vg-qqm4).

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
patched `x/net` requires it. On 2026-10-29 those pins moved with the
Kubernetes 1.37 upgrade, to `controller-runtime v0.25.2` +
`k8s.io/* v0.37.2` with envtest on Kubernetes 1.37.0.

**Fixed 2026-10-24.** The weekly scan had been red since at least
2026-10-19: new advisories against modules bumped above, plus
standard-library fixes in Go 1.26.6 to 1.26.9. Each module moved to the
*minimum* fixed version, not to latest:

| Advisory | Package | Where | Status |
|---|---|---|---|
| GO-2026-6372, -6491, -6492, -6494, -6496, -6498, -6500, -6502, -6503, -6700 | `github.com/rabbitmq/amqp091-go` | `examples/bookstore/app/orders`, `examples/bookstore/app/payments-worker` | **Fixed** — `v1.10.0` → `v1.14.0`. GO-2026-6700 appeared while this pass was in progress and is why the target is v1.14.0, not v1.13.0. |
| GO-2026-6603, -6610, -6611, -6612, -6617 | `golang.org/x/net` | `examples/bookstore/operator` | **Fixed** — `v0.56.0` → `v0.60.0`. The operator's `go` directive rose `1.25.0` → `1.26.0`, required by that `x/net`. |
| GO-2026-6629 | `golang.org/x/text` | `examples/bookstore/app/catalog`, `examples/bookstore/app/orders`, `examples/bookstore-platform/app/events` | **Fixed** — `v0.39.0` → `v0.41.0` (the operator gets `v0.42.0` via `x/net`). |
| Standard library (net/http, crypto/tls, encoding/asn1, net/url, …) | Go toolchain | every module | **Fixed** — CI and every Dockerfile builder `1.26.5` → `1.26.10`. |

`govulncheck ./...` (v1.9.0, Go 1.26.10) reports **no reachable
vulnerabilities in any of the 11 Go modules** as of 2026-10-24. Remaining
govulncheck output on a developer laptop is standard-library findings
against whatever local toolchain is installed.

**What the standard-library verdict actually describes.** govulncheck's
stdlib result is a statement about the toolchain it ran with, because the
Go standard library is compiled into each binary. It only describes the
images readers build if their builder stage uses the same patch release.
Until 2026-10-24 it did not: CI scanned with Go 1.26.5 while the platform
`orders` and `payments-worker` images built on `golang:1.22-alpine`
(end-of-life) and `catalog` on `golang:1.25-alpine`. The old sentence here
("CI pins Go 1.26.5, which is at or above every current stdlib fix
version") was wrong on both counts. 1.26.5 was already behind the stdlib
fixes in 1.26.6 to 1.26.9, and it was not the toolchain that built the
shipped binaries. Now CI (`GO_VERSION` in `security-scan.yml`) and every
Dockerfile builder are `1.26.10`, and the `go-toolchain-matches-scan` job
fails if they drift apart. Trivy's `fs` scan cannot catch this class: it
reads `go.mod`, not the toolchain inside a builder image. Only a `trivy
image` scan of the built image (which reads the Go version embedded in the
binary) would have seen it; see §6.

### 1.2) Secrets — 0

No real credentials or private keys detected in the working tree by
Trivy's secret scanner.

The second, independent scanner is **gitleaks**
([`secret-scan.yml`](.github/workflows/secret-scan.yml)), which runs on
every PR and nightly over the **full git history**, not just the tip. On
2026-10-24 it scanned the 25 pre-audit commits on `main` and found two hits, both
false positives (a third, in prose added during the audit, was reworded),
each allowlisted in [`.gitleaks.toml`](.gitleaks.toml) and pinned to one
rule, one file and one line shape. The DEMO-ONLY demo
passwords and the Stripe-shaped `REPLACE` placeholders produce no finding
with the default rules, so they are not allowlisted. Local equivalent:
`make scan-secrets`.

> **Correction (2026-10-24).** This section used to say a CI `leak-scan` job
> was a second secret scanner. It was a grep for five fixed strings in
> `full-guide/` (one of them the author's own email domain) and recognised no
> credential format. It is now `host-path-scan`, an authoring-hygiene check,
> and makes no secret-scanning claim.

### 1.3) Misconfigurations — triaged by category

The bulk of misconfig findings hit Kubernetes RBAC + ConfigMap content
that's intentionally permissive *because the resource is a platform-level
control plane*, not a workload. The categories:

| Category | Count | Status | Why |
|---|---:|---|---|
| **Platform RBAC roles** under `platform-base/01-rbac.yaml` | ~70 | **Accepted, with the risk stated** | `bookstore-platform-admin` is the break-glass role: `*/*/*`, equivalent to `cluster-admin`. Its blast radius is set by the binding (RoleBinding = one namespace; ClusterRoleBinding = the whole cluster) and by the human gate in 13.04, not by the rule. `bookstore-platform-operator` is **also** a wildcard for reads (`*/*` get/list/watch), which includes every Secret it is bound over. The neighbouring `tenant-admin` role is the only non-wildcard one. (Corrected 2026-10-24: this row used to name a non-existent `bookstore-platform-developer` role and a non-existent chapter file, and the YAML comment called the admin rule "NOT a cluster wildcard". The roles are introduced in [13.01](full-guide/13-grand-capstone-bookstore-platform/01-bookstore-2-from-toy-to-platform.md).) |
| **Backstage ConfigMap with secrets** (`KSV-0109`) | 1 | **Accepted (educational)** | The Backstage `app-config.yaml` snippet in `13-grand-capstone/03-backstage-on-day-one.md` includes `${GITHUB_TOKEN}` placeholder + an inline OIDC client secret. The chapter explicitly teaches "this is what the file looks like; in production these come from Vault via ESO and the ConfigMap holds only the `${ENV_VAR}` references." The example file is the teaching artifact. |
| **`runAsNonRoot`** missing (`KSV-0012`) | 0 | **Fixed (was 2, accepted)** | The only two Pod specs in the repo without `runAsNonRoot` were the Part 00/01 teaching seeds, [`raw-manifests/01-catalog-pod.yaml`](full-guide/examples/bookstore/raw-manifests/01-catalog-pod.yaml) and [`raw-manifests/02-catalog-pod-sidecar.yaml`](full-guide/examples/bookstore/raw-manifests/02-catalog-pod-sidecar.yaml). Both now carry the full security baseline, explained field by field in [Part 01 ch.01](full-guide/01-core-workloads/01-pods.md#baseline): a non-root user by number, `allowPrivilegeEscalation: false`, all capabilities dropped, a read-only root filesystem, a `RuntimeDefault` seccomp profile, no ServiceAccount token, and the busybox sidecar image pinned by digest. They run in the `bookstore` namespace, which enforces Pod Security `restricted`. The allowlist in [`check-runasnonroot.py`](.github/scripts/check-runasnonroot.py) is empty, and the script, which currently checks 49 Pod specs across the raw manifests, the rendered Helm chart and all three Kustomize overlays, fails if an unhardened Pod spec appears or if an entry is added without a reason here. |

---

## 2) Terraform — measured with tfsec 1.28.14, now scanned by Trivy

Scanner at the time of this measurement: `tfsec --no-color --soft-fail` on
two trees. **CI no longer runs tfsec.** The trivy job's `misconfig` scanner
already evaluates every Terraform root with the same `AVD-*` checks, and
covers the two roots tfsec never saw (`terraform/multi-region` and
`examples/gke/terraform`). Per-tree local equivalent: `make scan-terraform`.
The table below is the 2026-07-27 tfsec measurement, kept because the triage
under it is still correct; the rule IDs are the same in Trivy.

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
| `AVD-AWS-0041` Cluster public CIDR `0.0.0.0/0` | `main.tf:71` | **Accepted (DEV default; production override documented)** | Paired with AVD-0040. `cluster_endpoint_public_access_cidrs` defaults to `["0.0.0.0/0"]` for the DEV example. Production: scope to the operator egress CIDR. Same gating + chapter discussion as above. Since 2026-10-24 a variable validation refuses this open default when `tags.Environment` is `prod`/`production`, so the production override is enforced at plan time, not only taught. |
| `AVD-AWS-0104` Security group egress to internet | `node_groups.tf:247` | **Accepted** | Worker nodes egress to the internet for ECR image pulls + EKS addon delivery. The alternative is a fully private cluster with VPC endpoints for ECR-API + ECR-DKR + S3 — covered in ch.14.08 (`var.enable_vpc_endpoints = true`). |

### 2.2) Medium finding — tracked

| Rule | File:Line | Status |
|---|---|---|
| `AVD-AWS-0178` VPC Flow Logs not enabled | `main.tf:28` | **Tracked** — add a `var.enable_vpc_flow_logs = false` default-off variable per the var-gating convention. |

### 2.3) `terraform-account-baseline` — clean

Zero findings at all severity levels. The baseline tree is the account-wide
guardrail layer (CloudTrail, GuardDuty, Security Hub, IAM Access Analyzer);
it provisions controls, not workloads, so the surface for misconfig
findings is much smaller. Worth noting: no misconfig scanner validates that the
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
   check in §1.3 is enforced by
   [`.github/scripts/check-runasnonroot.py`](.github/scripts/check-runasnonroot.py),
   which fails CI both when a new unhardened Pod spec appears *and* when an
   allowlisted file no longer needs its exemption. Its allowlist is empty
   today. An acceptance list that can only silently grow is not a control.

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

---

## 6) What each scanner does *not* see

A green scan only covers what the scanner can see. Each control here has a
blind spot, and the blind spots are where this repo has actually been
wrong before.

| Control | Gates? | Does not see |
|---|---|---|
| **Trivy `fs`** (vuln + secret + misconfig) | No (`exit-code: 0`, report-only) | Anything inside a built image: base-image OS packages, and the Go toolchain compiled into a binary. It reads `go.mod`, not the builder image, so it could not have caught the `golang:1.22` builders (§1.1). It also omits npm/yarn/pnpm devDependencies unless run with `--include-dev-deps`. It reports *any* vulnerable module, reachable or not, which is why it does not gate (on 2026-10-24 it listed dozens of HIGH module CVEs that govulncheck shows are unreachable). |
| **Trivy `image`** + CycloneDX SBOM | No (report-only) | Only what the example Dockerfiles build. Images readers pull from elsewhere (Helm chart dependencies, operators, the `kubectl` image the ML pipeline's register and promote steps run) are not scanned. On 2026-10-29 those steps moved from `bitnami/kubectl:1.31.1`, which Docker Hub no longer serves, to a digest-pinned `cgr.dev/chainguard/kubectl:latest-dev`; the new image is not scanned either. |
| **Trivy misconfig on Terraform** | No | Your `*.tfvars` (never committed), so it judges the *defaults*. That is why the DEV defaults in §2.1 fire. Findings on the EKS/VPC trees are raised against upstream `terraform-aws-modules` source, not this repo's files. It also cannot tell whether a control is *correctly scoped*: it does not know whether an IAM statement is too broad for its purpose. |
| **govulncheck** | **Yes** (the only vulnerability gate) | Non-Go code (Python ML images, nginx, npm). Its standard-library verdict is about `GO_VERSION` only; `go-toolchain-matches-scan` is what ties that to the shipped images. |
| **gitleaks** (`secret-scan.yml`) | **Yes** | Credentials that match no rule (a plain-word demo password is invisible to it), anything outside git (issues, PR comments, Actions logs, artifacts). It reads history but cannot unpublish it. A file deleted in a later commit, such as the generation specs removed in `d21571d`, is still in history and still public ([ADR 0002](docs/adr/0002-multi-agent-fix-loop.md)). |
| **host-path-scan** | Yes | Not a secret scanner. It catches workstation traces in prose and nothing else. |
| **runAsNonRoot acceptance** | Yes | Only `runAsNonRoot`. Other restricted-PSA fields are left to PSA admission at apply time and to Trivy's report-only misconfig scan. |
| **`terraform validate`** + lock files | Yes | Whether a plan would succeed against a real account. Validation runs with `-backend=false` and no credentials. |
