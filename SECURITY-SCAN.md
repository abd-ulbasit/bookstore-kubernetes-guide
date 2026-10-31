# Security Scan Baseline

**Last hand-verified:** 2026-10-31 (sections 0, 1.0, 1.3, 7 and 8). Older sections carry their own dates.
**Scanned by:** [`security-scan.yml`](.github/workflows/security-scan.yml) (weekly, on push to `main`, on pull requests that touch the examples); [`security-gates.yml`](.github/workflows/security-gates.yml) (every pull request that touches `full-guide/` or the gates); [`bookstore-pipeline-check.yml`](.github/workflows/bookstore-pipeline-check.yml) (the services' pipeline, plus one control per scanner); [`secret-scan.yml`](.github/workflows/secret-scan.yml) (the full git history).
**Local-equivalent commands:** `make scan-trivy scan-terraform scan-go scan-secrets` for the scanners, `make gates-test gates-static gates-registry gates-admission` for the gates.
**Scanner versions in CI:** Trivy v0.76.1 (trivy-action's `version:` input; Dependabot bumps the action's SHA but not this input, so it is bumped by hand, and `security-gates.yml` carries its own copy with a SHA-256), govulncheck v1.9.0, gitleaks v8.30.1. The pipeline's scanners are pinned by digest in [`ci/scan.sh`](full-guide/examples/bookstore/ci/scan.sh). For Trivy, use v0.76.1 or later locally (v0.70.0, the action's own default, is affected by GHSA-mcj4-mphf-j9ff and GHSA-q3fv-x8vg-qqm4).

This document is the **hand-written triage** of what the security scanners
say about the repo: which findings are real, which are accepted, and why. It
is not generated and it carries no live counts. The
[Security tab](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/security/code-scanning)
is the live source of truth, and each workflow run writes a coverage summary
listing what was scanned. Every number below is a point-in-time measurement
with its date. Read it for shape, not as a tally.

**The list of what is accepted lives in two files, not here.** Section 0 says
which, and what CI checks about them. This page keeps the reasoning.

A core honesty principle: **finding count is not security**. Each finding is
either *real and tracked*, *accepted with a written reason and an expiry
date*, or *a false positive against something the guide shows on purpose*.

> **2026-10-31. This page was rewritten around the registry.** The
> security-first rewrite (ADR [0009](docs/adr/0009-security-first-guide-and-gates.md))
> moved every acceptance into a machine-checked registry, so this page stopped
> being the list. Things it said that were no longer true, now corrected:
>
> * **Platform RBAC: "~70" findings.** The Security tab showed 12 open alerts
>   for `platform-base/01-rbac.yaml` on `main` that day (section 1.3).
> * **Backstage ConfigMap.** It named the wrong chapter and said the file holds
>   "an inline OIDC client secret". The file is
>   `bookstore-platform/backstage/app-config.yaml`, the chapter is 13.11, and
>   every secret key in it is an `${ENV_VAR}` reference.
> * **"Permissive examples are flagged as teaching artifacts."** Principle 1
>   in section 4 let any chapter show a root Pod or a wildcard role. The guide
>   no longer does: an insecure example is allowed only in a Part 05 lab,
>   behind a marker, in a namespace the lab creates (section 4).
> * **"A clean scan on a project this size would be a red flag."** Removed
>   from section 5. A clean report means the scanner was pointed at the
>   right place, and section 6 says where each one is blind.
>
> The `runAsNonRoot` row and the 49-Pod-spec count were checked on 2026-10-31
> and still hold (section 1.3).
>
> **2026-07-27. The earlier version of this page was materially wrong, and so
> was the scanner.** Three claims were false: that the workflow regenerated
> this file (it never had such a step), that there were 4 Go-module
> vulnerabilities (there were 91 open Go/CVE alerts), and that a `runAsNonRoot`
> item had been "filed as an action item" (no such issue existed). The root
> cause of the undercount was a **scanner blind spot**: the govulncheck job
> built its path as `full-guide/examples/bookstore-platform/app/<service>`, so
> it only ever scanned the Platform v2 tree. `examples/bookstore/`, the
> canonical tree Parts 02 to 08 tell readers to run, was never scanned, and
> had drifted onto `pgx v5.7.5`, carrying
> [GO-2026-5004](https://pkg.go.dev/vuln/GO-2026-5004) (SQL injection via
> placeholder confusion), reachable from `loadBooks`. `make scan-go` had the
> same hardcoded path, so local runs agreed with CI, and both were wrong. Both
> now **discover** modules instead of listing them. The affected modules were
> bumped; see section 1.1.

---

## 0) The registry: where every accepted exception lives

Two files hold every exception the guide makes. Nothing is accepted in prose
alone, and an exception that is not in a file is not an exception.

| File | Holds | Each entry has |
|---|---|---|
| [`security/namespace-exceptions.yaml`](security/namespace-exceptions.yaml) | a namespace labelled above `restricted` (Pod Security `baseline` or `privileged`) | `namespace`, `level`, `reason`, `upstream`, `chapter`, `expires` |
| [`.trivyignore.yaml`](.trivyignore.yaml) | a scanner finding the guide accepts | `id`, `paths`, `statement`, `expired_at` |

**What CI checks, in both directions** (gate G5, `make gates-registry`, the
`registry` job of `security-gates.yml`):

* every `pod-security.kubernetes.io/{enforce,audit,warn}` label set to
  `baseline` or `privileged`, in a chapter or an example tree, has an entry at
  that level, and every entry is still in use;
* every scanner entry still matches a finding when Trivy runs without the
  ignore file, so a fixed finding leaves a stale entry that fails the build;
* every entry has a reason and a date that is still ahead and no more than 12
  months out;
* an inline `trivy:ignore` comment, or any other Trivy ignore file, is a
  failure. The registry is the only place to accept a finding.

Trivy v0.76.1 does not load `.trivyignore.yaml` on its own and marks the
feature experimental. So `make gates-static` reads the file itself, drops a
finding only for a sound and unexpired entry, and an unsound entry grants
nothing. The `trivy` job in `security-scan.yml` runs Trivy directly and does
not read it, which is why the accepted findings below still appear in the
Security tab (section 1.3).

**To accept a finding or a namespace:** add the entry with its reason and
citation, put the explanation in the chapter that owns it, and give it a date
no more than 12 months out. When the date comes, either fix it or renew it
with a fresh reason.

### 0.1) Namespaces above `restricted` (3 entries, checked 2026-10-31)

| Namespace | Level | Why | Chapter | Expires |
|---|---|---|---|---|
| `falco` | `privileged` | The Falco DaemonSet needs `CAP_BPF`, `CAP_PERFMON` and `CAP_SYS_ADMIN` for its modern eBPF driver, plus host PID and network access. `restricted` lets a container add back only `NET_BIND_SERVICE`. [Falco setup docs](https://falco.org/docs/setup/container/). | 14.13 | 2027-06-30 |
| `psa-lab` | `privileged` | The Part 05 Pod Security lab runs deliberately insecure Pods in a throwaway kind namespace to show what `privileged` allows. The lab creates, labels and deletes it. | 05.02 | 2027-06-30 |
| `runtime-test` | `baseline` | The Falco test Pod runs a busybox image as root with no `securityContext`, which `restricted` rejects and `baseline` admits. It only reads `/etc/shadow` to trigger a rule. The namespace is throwaway. | 14.13 | 2027-06-30 |

This extends [ADR 0005](docs/adr/0005-restricted-psa-default-with-exceptions.md),
which limited the privileged exceptions to the Terraform tree. The rule now
covers every namespace the guide creates.

### 0.2) Scanner findings (9 entries, checked 2026-10-31)

| Check | Where | Why it is accepted | Expires |
|---|---|---|---|
| `KSV-0041`, `-0044`, `-0045`, `-0046`, `-0056` | `bookstore-platform/platform-base/01-rbac.yaml` and the three region overlays that build on it | Break-glass and tenant platform roles, accepted by design (13.01). The file ships ClusterRoles only, so the blast radius is set by each binding and by the human gate in 13.12. Detail in section 1.3. | 2027-06-30 |
| `KSV-0056` | `bookstore/operator/config/rbac/role.yaml` and `config/default` | The operator's manager role writes the Services of each tenant it reconciles. It grants no Secrets and no wildcards. | 2027-06-30 |
| `KSV-0053`, `KSV-0056` | `bookstore/operators/second-tenant.yaml` | A tenant admin Role, namespaced to `tenant-acme`, for debugging that tenant's own pods (08.04). | 2027-06-30 |
| `KSV-0109` | `bookstore-platform/backstage/app-config.yaml` | The ConfigMap names secret keys but holds only `${ENV_VAR}` references. External Secrets supplies the values (13.11). | 2027-06-30 |

---

## 1) Filesystem scan: Trivy

Scanner: `trivy fs --severity HIGH,CRITICAL --scanners vuln,secret,misconfig`,
run by the `trivy` job of `security-scan.yml`. It never fails the build, and
`trivy-action` drops the severity filter when it writes SARIF, so the Security
tab also lists LOW and MEDIUM. The pull request check named `Trivy` (GitHub's
code scanning, not this job) does fail on a new HIGH alert in code the pull
request changes.

Two paths are skipped: `full-guide/examples/bookstore/ci/fixtures`, the
pipeline's deliberately vulnerable fixture, and `.github/scripts/gates/fixtures`,
the gates' control fixtures. Both exist to break on purpose. Each is proven
elsewhere: the pipeline check runs every scanner against the first and
requires it to flag the planted issue, and `static_gate.py` scans the second
before it trusts any result and exits 2 unless Trivy flags each violating
fixture and passes the hardened one. Before the second path was skipped, PR 7's
Trivy check failed on three new HIGH alerts (KSV-0014, KSV-0118 twice) that were
the whole point of those files.

### 1.0) What the Security tab showed on `main`, 2026-10-31

Open alerts on `main`, before the security-first rewrite merges
(`gh api .../code-scanning/alerts?state=open&ref=refs/heads/main`). 1,327 in
all.

| Class | Open | By severity | What it is |
|---|---:|---|---|
| Kubernetes misconfiguration (`KSV-*`) | 654 | 551 low, 67 medium, 26 high, 10 critical | 478 are `KSV-0039` and `KSV-0040` (239 each), "limit range usage" and "resource quota usage", raised on workload files that have no LimitRange or ResourceQuota beside them (the guide's are in `00-namespace.yaml`). The 36 high and critical are section 1.3. |
| Vulnerabilities in built images | 567 | 156 high, 3 critical, 222 medium, 160 low, 26 note | Almost all in three images: `app/storefront` (the nginx 1.27 base), `ml/train` and `ml/serve` (Python bases). Section 3. |
| Vulnerabilities in dependency files | 54 | 25 high, 19 medium | Mostly `go.mod` files in the Platform v2 tree (`catalog`, `events`, then one each in `recommendations` and `payments-gateway`), where Trivy lists every vulnerable module and govulncheck finds none reachable (section 3). |
| Terraform (`AWS-*`, `GCP-*`) | 24 | 12 critical, 1 high | Section 2. |
| Dockerfile (`DS-*`) | 14 | all low | `DS-0026`, "no HEALTHCHECK", one per Dockerfile. |
| Secrets | 0 | | Section 1.2. |
| Retired scanners | 4 | | Alerts from `tfsec` (tool `defsec`) on `eks.tf` and `vpc.tf`. CI stopped running tfsec, so nothing will ever close them. They should be dismissed in the Security tab. |

The branch that carries the rewrite changes this picture: the read-only root
filesystem fixes remove the `KSV-0014` highs in the raw manifests, the
Kustomize base and the Helm chart, and the storefront image moved to nginx
1.30. The Security tab will say so after the merge, and this table is dated
so it can be compared.

### 1.1) Vulnerabilities fixed in the Go modules

Fixed on 2026-07-27. Earlier this page logged them as "accepted (pinned-stub
status)". That framing was wrong: two of the three affected modules are not
stubs, they are the canonical `examples/bookstore/` services a reader is told
to build and run. They were bumped, not accepted.

| Advisory | Package | Where | Status |
|---|---|---|---|
| [GO-2026-5004](https://pkg.go.dev/vuln/GO-2026-5004) (SQL injection) | `github.com/jackc/pgx/v5` | `examples/bookstore/app/catalog`, `examples/bookstore/app/orders` | **Fixed**, `v5.7.5` to `v5.9.2`. govulncheck confirmed the vulnerable symbol was actually reachable (`loadBooks`, then `pgxpool.Pool.Query`, then `sanitize.SanitizeSQL`), not merely present. |
| [GO-2026-5970](https://pkg.go.dev/vuln/GO-2026-5970) (infinite loop) | `golang.org/x/text` | `examples/bookstore/app/catalog`, `examples/bookstore/app/orders`, `examples/bookstore/operator` | **Fixed**, `v0.25.0`/`v0.17.0` to `v0.39.0`. |
| [GO-2026-5026](https://pkg.go.dev/vuln/GO-2026-5026), [GO-2026-4918](https://pkg.go.dev/vuln/GO-2026-4918) | `golang.org/x/net` | `examples/bookstore/operator` | **Fixed**, `v0.28.0` to `v0.56.0`. |
| CVE-2025-22868 | `golang.org/x/oauth2` | `examples/bookstore/operator` | **Fixed**, `v0.21.0` to `v0.33.0`. |

On 2026-10-29 the operator's `controller-runtime` and `k8s.io/*` pins moved
with the Kubernetes 1.37 upgrade, to `controller-runtime v0.25.2` and
`k8s.io/* v0.37.2`, with envtest on Kubernetes 1.37.0. Before that they had
been left alone on purpose, and only the vulnerable `golang.org/x/*`
transitives moved; its `go` directive rose `1.23.0` to `1.25.0` because the
patched `x/net` requires it.

**Fixed on 2026-10-24.** The weekly scan had been red since at least
2026-10-19: new advisories against modules bumped above, plus standard-library
fixes in Go 1.26.6 to 1.26.9. Each module moved to the minimum fixed version,
not to latest:

| Advisory | Package | Where | Status |
|---|---|---|---|
| GO-2026-6372, -6491, -6492, -6494, -6496, -6498, -6500, -6502, -6503, -6700 | `github.com/rabbitmq/amqp091-go` | `examples/bookstore/app/orders`, `examples/bookstore/app/payments-worker` | **Fixed**, `v1.10.0` to `v1.14.0`. GO-2026-6700 appeared while the pass was in progress, which is why the target is v1.14.0 and not v1.13.0. |
| GO-2026-6603, -6610, -6611, -6612, -6617 | `golang.org/x/net` | `examples/bookstore/operator` | **Fixed**, `v0.56.0` to `v0.60.0`. The operator's `go` directive rose `1.25.0` to `1.26.0`, required by that `x/net`. |
| GO-2026-6629 | `golang.org/x/text` | `examples/bookstore/app/catalog`, `examples/bookstore/app/orders`, `examples/bookstore-platform/app/events` | **Fixed**, `v0.39.0` to `v0.41.0` (the operator gets `v0.42.0` through `x/net`). |
| Standard library (net/http, crypto/tls, encoding/asn1, net/url, ...) | Go toolchain | every module | **Fixed**, CI and every Dockerfile builder `1.26.5` to `1.26.10`. |

`govulncheck ./...` (v1.9.0, Go 1.26.10) reported no reachable
vulnerabilities in any of the 11 Go modules on 2026-10-24. Any remaining
govulncheck output on a laptop is standard-library findings against whatever
local toolchain is installed.

**What the standard-library verdict actually describes.** govulncheck's
stdlib result is a statement about the toolchain it ran with, because the Go
standard library is compiled into each binary. It describes the images
readers build only if their builder stage uses the same patch release. Until
2026-10-24 it did not: CI scanned with Go 1.26.5 while the platform `orders`
and `payments-worker` images built on `golang:1.22-alpine` (end of life) and
`catalog` on `golang:1.25-alpine`. The old sentence here ("CI pins Go 1.26.5,
which is at or above every current stdlib fix version") was wrong on both
counts: 1.26.5 was already behind the fixes in 1.26.6 to 1.26.9, and it was
not the toolchain that built the shipped binaries. Now CI (`GO_VERSION` in
`security-scan.yml`) and every Dockerfile builder are `1.26.10`, and the
`go-toolchain-matches-scan` job fails if they drift apart. Trivy's `fs` scan
cannot catch this class: it reads `go.mod`, not the toolchain inside a builder
image. Only a `trivy image` scan of the built image, which reads the Go
version embedded in the binary, would have seen it (section 6).

### 1.2) Secrets: 0

No real credentials or private keys were found in the working tree by Trivy's
secret scanner.

The second, independent scanner is **gitleaks**
([`secret-scan.yml`](.github/workflows/secret-scan.yml)). It runs on every pull
request and nightly over the **full git history**, not just the tip. On
2026-10-24 it scanned the 25 pre-audit commits on `main` and found two hits,
both false positives (a third, in prose added during the audit, was
reworded). Each is allowlisted in [`.gitleaks.toml`](.gitleaks.toml) and pinned
to one rule, one file and one line shape. The DEMO-ONLY demo passwords and the
Stripe-shaped `REPLACE` placeholders produce no finding with the default
rules, so they are not allowlisted. The pipeline's `secrets` job also runs
gitleaks and TruffleHog over every commit (section 8). Local equivalent:
`make scan-secrets`.

> **Correction (2026-10-24).** This section used to say a CI `leak-scan` job
> was a second secret scanner. It was a grep for five fixed strings in
> `full-guide/` (one of them the author's own email domain) and recognised no
> credential format. It is now `host-path-scan`, an authoring-hygiene check,
> and makes no secret-scanning claim.

### 1.3) Misconfigurations: what the registry accepts, and why

The accepted misconfigurations are all in the registry (section 0.2). The
reasoning behind each category is here. The Security tab still lists them,
because `security-scan.yml` runs Trivy without reading the registry.

| Category | Open on `main`, 2026-10-31 | Status | Why |
|---|---:|---|---|
| **Platform RBAC roles** in `platform-base/01-rbac.yaml` | 12 (`KSV-0041` x2, `-0044` x1, `-0045` x3, `-0046` x4, `-0056` x2) | **Accepted, with the risk stated** | `bookstore-platform-admin` is the break-glass role: `*/*/*`, equivalent to `cluster-admin`. Its blast radius is set by the binding (a RoleBinding reaches one namespace, a ClusterRoleBinding the whole cluster) and by the human gate in 13.12, not by the rule. `bookstore-platform-operator` is also a wildcard for reads (`*/*` get/list/watch), which includes every Secret it is bound over. `tenant-admin` is the only non-wildcard one. The roles are introduced in [13.01](full-guide/13-grand-capstone-bookstore-platform/01-bookstore-2-from-toy-to-platform.md). *Corrected 2026-10-31: this row said "about 70". The earlier figure did not match the Security tab, which shows 12 for this file.* |
| **Operator manager role** (`KSV-0056`) | 1 | **Accepted** | Writes the Services of each `BookstoreTenant` it reconciles. No Secrets, no wildcards (header of `operator/config/rbac/role.yaml`, Part 08 ch.05). |
| **Second-tenant Role** (`KSV-0053`, `KSV-0056`) | 2 | **Accepted** | A worked tenant Role, namespaced to `tenant-acme`, granting `pods/exec` and Services so the tenant can debug its own pods (08.04). |
| **Backstage ConfigMap names secret keys** (`KSV-0109`) | 1 | **Accepted** | `bookstore-platform/backstage/app-config.yaml` (chapter [13.11](full-guide/13-grand-capstone-bookstore-platform/11-backstage-developer-portal-idp.md)) lists the Keycloak, GitHub App, Argo CD and PagerDuty secret keys, but every value is an `${ENV_VAR}` reference. External Secrets materialises them from the secret backend at runtime. *Corrected 2026-10-31: this row used to name a different chapter and say the file held an inline OIDC client secret. It does not.* |
| **`KSV-0014` read-only root filesystem** (HIGH) | 15 | **Fixed on the rewrite branch** | The raw manifests, the Kustomize base, the Helm templates and one mesh example ran Postgres, RabbitMQ and the Jobs with a writable root. The branch gives them read-only roots and the `emptyDir` volumes they need, and the runtime gate (section 7) proves the workloads still start. The alerts close when the branch merges. |
| **`KSV-0118` default security context** (HIGH) | 5 | **Fixed on the rewrite branch** | The two Part 01 teaching Pods now carry the full baseline (01.01). |
| **`runAsNonRoot` missing** (`KSV-0012`) | 0 | **Fixed (was 2, accepted)** | The only two Pod specs without `runAsNonRoot` were the Part 00/01 teaching seeds, [`01-catalog-pod.yaml`](full-guide/examples/bookstore/raw-manifests/01-catalog-pod.yaml) and [`02-catalog-pod-sidecar.yaml`](full-guide/examples/bookstore/raw-manifests/02-catalog-pod-sidecar.yaml). Both now carry the full baseline, explained field by field in [01.01](full-guide/01-core-workloads/01-pods.md#baseline). They run in the `bookstore` namespace, which enforces `restricted`. [`check-runasnonroot.py`](.github/scripts/check-runasnonroot.py) checks 49 Pod specs across 33 sources (the raw manifests, the rendered Helm chart and all three Kustomize overlays) with an empty allowlist. |

The remaining `KSV-*` alerts are low or medium. They are not accepted, they
are not yet worked: `KSV-0039` and `KSV-0040` are an artefact of scanning one
file at a time, `KSV-0020` and `KSV-0021` flag a UID or GID of 10000 or less
on images that declare their own (Postgres at 999, for example), and
`KSV-0125` flags images from outside a trusted-registry list. The gate G2 does
not use them: it checks five (section 7).

---

## 2) Terraform: measured with tfsec 1.28.14, now scanned by Trivy

Scanner at the time of the measurement below: `tfsec --no-color --soft-fail`
on two trees, **on 2026-07-27**. CI no longer runs tfsec. The `trivy` job's
`misconfig` scanner already evaluates every Terraform root with the same
`AVD-*` checks, and covers the two roots tfsec never saw
(`terraform/multi-region` and `examples/gke/terraform`). Per-tree local
equivalent: `make scan-terraform`. The table is the 2026-07-27 tfsec
measurement, kept because the triage under it is still correct; the rule IDs
are the same in Trivy.

| Tree | CRITICAL | HIGH | MEDIUM | LOW |
|---|---:|---:|---:|---:|
| `examples/bookstore-platform/terraform` | 3 | 0 | 2 | 0 |
| `examples/bookstore-platform/terraform-account-baseline` | 0 | 0 | 0 | 0 |

On 2026-10-31 the Security tab showed, for Terraform, 12 critical (`AWS-0040`,
`AWS-0041` and `AWS-0104`, four alerts each), 1 high (`GCP-0061`, in
`examples/gke`), 8 medium and 3 low.

> **Read the file column carefully.** The AWS findings are raised against the
> **upstream `terraform-aws-modules/*` source** that the scanner downloads
> (`terraform-aws-modules/eks/aws/main.tf`, `.../vpc/aws/main.tf`), not against
> this repo's own `.tf` files. What this repo controls is the input variables it
> passes, and that is what the acceptances below are about. `AWS-0342` is
> inside the vendored Karpenter submodule, upstream code this repo does not
> configure; it is listed only so the table matches the Security tab.

These are not in the registry because the guide does not suppress them: they
are reported, not gated. A Terraform exception that the guide makes on purpose
is a DEV default, and the next section says so for each.

### 2.1) Critical findings: all documented as intentional

| Rule | File:Line | Status | Why |
|---|---|---|---|
| `AVD-AWS-0040` Public cluster access enabled | `main.tf:70` | **Accepted (DEV default; production override documented)** | `cluster_endpoint_public_access = true` is the default for the DEV example so a reader can `kubectl` from their laptop without a bastion. The variable is gated, and the chapter teaches `cluster_endpoint_public_access = false` for production. |
| `AVD-AWS-0041` Cluster public CIDR `0.0.0.0/0` | `main.tf:71` | **Accepted (DEV default; production override documented)** | Paired with AVD-0040. `cluster_endpoint_public_access_cidrs` defaults to `["0.0.0.0/0"]` for the DEV example. In production, scope it to the operator egress CIDR. Since 2026-10-24 a variable validation refuses this open default when `tags.Environment` is `prod` or `production`, so the override is enforced at plan time and not only taught. |
| `AVD-AWS-0104` Security group egress to internet | `node_groups.tf:247` | **Accepted** | Worker nodes egress to the internet for ECR image pulls and EKS addon delivery. The alternative is a private cluster with VPC endpoints for ECR-API, ECR-DKR and S3, covered in 14.08 (`var.enable_vpc_endpoints = true`). |

### 2.2) Medium finding: tracked

| Rule | File:Line | Status |
|---|---|---|
| `AVD-AWS-0178` VPC Flow Logs not enabled | `main.tf:28` | **Tracked.** Add a `var.enable_vpc_flow_logs = false` default-off variable per the var-gating convention. |

### 2.3) `terraform-account-baseline`: clean

Zero findings at all severity levels on 2026-07-27. The baseline tree is the
account-wide guardrail layer (CloudTrail, GuardDuty, Security Hub, IAM Access
Analyzer). It provisions controls, not workloads, so the surface for
misconfiguration findings is much smaller. No misconfiguration scanner
validates that the controls themselves are correctly scoped; that is a
separate review pass.

During this rewrite none of the Terraform is applied: no cluster is created on
AWS or GCP (ADR 0009). The trees are validated (`terraform validate`, `fmt`)
and scanned, and a chapter that depends on a live cloud cluster cites its
source and says it was not run.

---

## 3) Go vulnerabilities: govulncheck, and the two images

Scanner: `govulncheck ./...` per module, run in CI from
[`security-scan.yml`](.github/workflows/security-scan.yml).

The module list is **discovered** (`find full-guide/examples -name go.mod`,
minus the pipeline's vulnerable fixture), not hardcoded, and a
`discover-go-modules` job fails outright if it finds zero modules. A green scan
over an empty matrix is the failure mode that hid GO-2026-5004. As of
2026-10-31 it discovers **11 modules**; the hardcoded list it replaced covered
7, all in the Platform v2 tree.

Findings surface as a matrix-job failure, one job per module, so the failing
module is named in the job title. They do not produce a SARIF upload:
govulncheck's SARIF output is not wired up, and an earlier version of this
page wrongly claimed it was. Trivy is what populates the Security tab for Go
modules. Local equivalent: `make scan-go`, which uses the same discovery.

The overlap with section 1.1 is the same set of vulnerabilities seen two ways.
Trivy reports any vulnerable dependency, govulncheck reports the ones whose
vulnerable symbols are reachable from the service's own code. That
distinction is what made GO-2026-5004 urgent rather than theoretical, and it
is why the 54 dependency-file alerts in section 1.0 do not fail anything:
govulncheck passes on all 11 modules.

**Images.** The `image-scan` job builds every Dockerfile under
`full-guide/examples` on the runner, scans it with `trivy image` and keeps a
CycloneDX SBOM. It is report-only. The 567 image alerts in section 1.0 are
operating-system packages in base images, and almost all sit in three: the
storefront's nginx base, and the two Python ML images. The storefront moved
from nginx 1.27 to 1.30 on the rewrite branch after the pipeline's first real
run flagged the old base (chapter 07.03). The ML images are the next place to
look. The 12 `DLA-*` alerts on the Platform v2 images are Debian advisories on
the distroless static base; the one opened, `DLA-4867-1`, is a `tzdata` data
update with severity UNKNOWN, fixed by a newer base image. The pipeline's own
`image-scan` stage, which gates, applies `ignore-unfixed`, because a rebuild
cannot fix a CVE nobody has patched.

---

## 4) Standing acceptance principles

Some findings recur on every scan because they are intentional teaching
content. They are documented once here rather than triaged on each scan:

1. **Insecure examples exist only on purpose, marked and confined.** The
   guide no longer shows a root Pod or a wildcard role as a general teaching
   device. A deliberately insecure example appears only in a Part 05 lab or
   the capstone overlay. It opens with `# INSECURE ON PURPOSE: <what it
   shows>. Lab cluster only.`, is preceded by `<!-- gate: insecure-on-purpose
   -->`, and runs in a namespace the lab creates and labels, never `bookstore`
   or `default`. The gates check the marker in both directions. A scanner
   flagging a marked block is the expected result. *This principle used to
   read "permissive examples are flagged as security teaching artifacts" and
   let any chapter keep them.*
2. **DEV defaults are not production defaults.** Several Terraform variables
   default to the demo-friendly value (public cluster endpoint, broad node
   egress) so a reader can apply the tree to a sandbox account and reach the
   cluster. The chapter for each one teaches the production override. A
   scanner flagging the DEV default is correct. What is accepted is that the
   demo and the production path differ on purpose.
3. **"It's only a stub" is not an acceptance reason.** This principle used to
   read "stub services have older pins, they aren't exercised." That reasoning
   is retired. It was used to defer a reachable SQL-injection advisory in
   `examples/bookstore/`, which is not a stub: it is the tree Parts 02 to 08
   tell readers to build and run. Vulnerable pins in any example a reader is
   invited to copy get fixed, not filed. A deliberately old pin that teaches
   something (a chapter demonstrating an upgrade) must say so in the chapter
   and be listed explicitly here.
4. **Acceptances are executable.** An acceptance is an entry in the registry
   (section 0), and the gates fail when an entry is unsound, expired, more than
   12 months out, or no longer matches anything. An acceptance list that can
   only silently grow is not a control.

---

## 5) Who this page is for

* **Readers and reviewers.** It shows that scanning runs on a schedule and on
  every pull request, and that findings are triaged with reasons instead of
  ignored. It also shows where the scanners were wrong or blind, because that
  is where the repo has been wrong before.
* **Contributors.** It lists what is accepted, so a pull request does not
  "fix" an intentional teaching artifact, and what is not, so a new finding is
  not waved through.
* **Maintainers.** When a new scanner version surfaces a new finding, this
  page is where it is triaged: a real fix, or an entry in the registry.

---

## 6) What each scanner does not see

A green scan covers only what the scanner can see. Each control has a blind
spot, and the blind spots are where this repo has actually been wrong.

| Control | Gates? | Does not see |
|---|---|---|
| **Trivy `fs`** (vuln + secret + misconfig) | No (`exit-code: 0`, report-only) | Anything inside a built image: base-image OS packages, and the Go toolchain compiled into a binary. It reads `go.mod`, not the builder image, so it could not have caught the `golang:1.22` builders (section 1.1). It also omits npm/yarn/pnpm devDependencies unless run with `--include-dev-deps`. It reports any vulnerable module, reachable or not, which is why it does not gate. It does not read `.trivyignore.yaml`, so accepted findings still show in the Security tab. |
| **Trivy `image`** + CycloneDX SBOM (`security-scan.yml`) | No (report-only) | Only what the example Dockerfiles build. Images readers pull from elsewhere (Helm chart dependencies, operators, the `kubectl` image the ML pipeline's register and promote steps run) are not scanned. On 2026-10-29 those steps moved from `bitnami/kubectl:1.31.1`, which Docker Hub no longer serves, to a digest-pinned `cgr.dev/chainguard/kubectl:latest-dev`; the new image is not scanned either. |
| **Trivy misconfig on Terraform** | No | Your `*.tfvars` (never committed), so it judges the defaults. That is why the DEV defaults in section 2.1 fire. The EKS and VPC findings are raised against upstream `terraform-aws-modules` source, not this repo's files. It cannot tell whether a control is correctly scoped: it does not know whether an IAM statement is too broad for its purpose. |
| **govulncheck** | **Yes** (the only vulnerability gate for dependencies) | Non-Go code (Python ML images, nginx, npm). Its standard-library verdict is about `GO_VERSION` only; `go-toolchain-matches-scan` ties that to the shipped images. |
| **gitleaks** (`secret-scan.yml`) | **Yes** | Credentials that match no rule (a plain-word demo password is invisible to it), and anything outside git: issues, PR comments, Actions logs, artifacts. It reads history but cannot unpublish it. A file deleted in a later commit, such as the generation specs removed in `d21571d`, is still in history and still public ([ADR 0002](docs/adr/0002-multi-agent-fix-loop.md)). |
| **host-path-scan** | Yes | Not a secret scanner. It catches workstation traces in prose and nothing else. |
| **`runAsNonRoot` acceptance** (`check-runasnonroot.py`) | Yes | Only `runAsNonRoot`, and only in the example trees. The gates below check the rest of the baseline. It still runs. The design (`docs/design/2026-10-29-security-first-rewrite.md`) has G5 replace it. |
| **G2, static gate** | In report mode, except the enforced chapters | Whatever Trivy has no check for (a Rollout, a custom resource, a `List`), which it lists as `not-evaluated`. It fails the run when such a block holds a pod template, unless the block is on the allowlist with a reason. It does not run anything. |
| **G3, admission gate** | In report mode, except the enforced chapters | Custom resources whose CRDs the cluster lacks (`missing-crd`), and whatever only behaves wrongly at runtime. |
| **G4, runtime gate** | Yes | Only the Bookstore, in five forms. It deploys on a plain kind cluster, so it skips any resource whose CRD is missing (a ServiceMonitor, a KEDA ScaledObject) unless that resource runs a container, in which case it fails. It tests that the workloads start, not that they are correct. |
| **`terraform validate`** + lock files | Yes | Whether a plan would succeed against a real account. Validation runs with `-backend=false` and no credentials. |

---

## 7) The gates

The security-first gates ([`security-gates.yml`](.github/workflows/security-gates.yml),
rules in [`docs/security-first-authoring.md`](docs/security-first-authoring.md))
run on real GitHub runners for every pull request that touches `full-guide/`
or the gates themselves.

| Gate | What it checks | Mode |
|---|---|---|
| unit tests | the gate scripts, with Trivy, Helm and kubectl present so no test may skip | always fails the job |
| G1 + G2 | every manifest in the guide and the example trees against Trivy's five core checks (`KSV-0012`, `-0014`, `-0001`, `-0003`, `-0030`), plus a parsed-YAML cross-check | report mode |
| G1 + G3 | a server-side dry run of every manifest into a `restricted` namespace on a kind v0.33.0 cluster; a Pod Security warning fails | report mode |
| G5 | the registry, both ways (section 0) | always fails the job |
| G7 | every output block in a chapter appears, in order, in its lab transcript, and no transcript leaks an address, a home directory or a cloud identifier | always fails the job |
| G4 | the Bookstore deployed five ways (raw manifests, the Helm chart, each Kustomize overlay) into `restricted` namespaces on kind; every workload must reach Ready or Complete | always fails the job |

**Report mode.** Most chapters are not rewritten yet, so most still fail G2 and
G3. A failing chapter is listed in the run summary and does not fail the job
unless it is named in [`.github/security-gates-enforced.txt`](.github/security-gates-enforced.txt).
An enforced chapter that fails any gate, or that no gate reports on, fails the
job; so does a gate that cannot trust itself (exit 2). The list starts with
01.01, 05.02 and 07.03, and a chapter joins it in the pull request that
finishes it.

---

## 8) The pipeline's controls: what a real run has proved

The Bookstore pipeline ([`bookstore-pipeline.yml`](.github/workflows/bookstore-pipeline.yml),
chapter 07.03) runs for each service on every pull request that touches the
services (`bookstore-pipeline-check.yml`). It also runs every scanner against
a deliberately vulnerable fixture, and a scanner that stays quiet there fails
the build.

This section records what GitHub's runners have actually run, as of
2026-10-31, and what is still only read. The pull request runs and three
dispatches of [`bookstore-release.yml`](.github/workflows/bookstore-release.yml)
are the evidence; chapter 07.03 quotes them in blocks its evidence check reads.
The checks on the signed image run from a laptop with public tools, against the
public image.

| Control | Ran on GitHub's runners? | What the run showed |
|---|---|---|
| **CodeQL** (Go, once per Go service) | Yes | The CodeQL CLI (2.27.3) built each service, finalised its database, ran the Go queries and wrote SARIF with upload off. The job counts the results itself and found **0** for every service. Zero results on four small services is a verdict on that code, not a proof that CodeQL sees every class of bug. In the release run's `catalog` leg all 36 queries ran and the count was 0. That job's first run also tried to upload the database, which it has no permission for, retried for nearly two minutes and left an error annotation; the upload is now off. |
| **ZAP baseline (DAST)** | Yes, for `catalog`, `orders` and `storefront` | Each image ran in a Pod on a throwaway kind cluster, in a `restricted` namespace with default-deny networking, and ZAP's passive baseline reported nothing against the service. `payments-worker` has no web surface and is switched off by design. |
| **Harden-Runner** (audit mode) | Yes, as the first step of every job | The agent started and recorded each job's outbound calls. In the DAST job it recorded ZAP's Java process resolving `news.zaproxy.org`, `cfu.zaproxy.org` and `tel.zaproxy.org`. Audit mode blocks none of that, and a move to block mode needs those hosts on the allowlist or ZAP's options set to stop the calls. In the release run it ran in all 13 jobs. The `sign` job's log shows cosign calling Fulcio, Rekor, the timestamp authority, the TUF mirror, GitHub's OIDC endpoint and ghcr.io; the `workflow-hardening` job's shows Scorecard calling OSV, deps.dev, the OpenSSF badge site and others. |
| **zizmor, actionlint, expiry** | Yes | Clean on the pipeline, the pipeline check, and, since 2026-10-31, the gates and release workflows. |
| **Permission ceiling** | Yes, by experiment | A throwaway workflow called the pipeline with `publish: false` and a ceiling of `contents: read` and `actions: read`. GitHub refused to start the run (`startup_failure`), because `sign` is in the called workflow and asks for `packages`, `id-token` and `attestations` write, though it would have been skipped. The same call with those three granted started normally. The ceiling is checked at parse time, skipped jobs included. |
| **OpenSSF Scorecard** | **Yes**, on the second release run | **6.7 / 10** (Scorecard v5.6.0 through action v2.5.0, JSON output, nothing published). Code-Review 0, Branch-Protection 3, Vulnerabilities 0 (49 existing vulnerabilities in the repository's dependencies, not investigated), Fuzzing 0, CII-Best-Practices 0, Contributors 0, Pinned-Dependencies 6, Signed-Releases -1 (no releases), the other ten checks 10. The first release run skipped the step, because its condition said `push` and a release is a dispatch; it now accepts a dispatch from the default branch. One reading, not a trend. |
| **`sign`**: push, cosign signature, SBOM attestation, provenance | **Yes**, for `catalog` | All three dispatches (`catalog` twice, `orders` once) pushed and signed. For the second digest, `cosign verify` with the exact workflow identity passes with an empty credential store and the same command with another branch is refused. The CycloneDX attestation verifies and holds 972 components, `gh attestation verify` passes with the identity pinned, and the package is anonymously pullable. For the `orders` digest, the SBOM holds 971 components and the two verify commands in its promotion PR exit 0 when pasted. Not run: a publishing run in which a gate fails, which leaves nothing pushed by the `if:` of `sign`, and the other two services. |
| **Promotion PR** | **Yes**, three times | The first PR rewrote the whole prod overlay for one pin (143 lines added, 145 removed), had an unfilled body and showed no checks. The pins now live in `overlays/prod/images/`, and the second and third PRs each changed 3 lines in that one file, with a filled body. The second body's `gh attestation verify` pinned only the repository; the third, for `orders`, is the first with the identity pinned. Both were merged by a person pushing the PR's head, with no review, and `main` renders 48 objects with the two promoted digests. |
| **Checks on the promotion PR** | **Yes**, by dispatch, but not on the PR | A PR opened with `GITHUB_TOKEN` gets no checks: GitHub created its five `pull_request` runs with no jobs and left them at `action_required`. A `checks` job with `actions: write` dispatches `example-trees-check.yml` and `security-gates.yml` on the PR's branch, and both passed there on the second and third PRs, the runtime gate for `kustomize-prod` included. Those runs are attached to the commit and the branch's run list, not to the PR: the third PR's Checks tab stayed empty and `gh pr checks` reported none. Closing and reopening the PR as a person, or pushing to its branch as one, ran all five `pull_request` workflows, and they passed. |

G4 (section 7) is the other thing a real run showed. Its first run failed in all
five forms, the next in two, and every failure was a real defect in the
examples, not in the gate:

* **The NetworkPolicies blocked the app's own traffic.** They admitted only
  catalog to postgres and nobody to redis. The runs ended with `orders` and the
  `db-migrate` Job timing out on postgres and `catalog` timing out on redis.
  kind v0.33.0's default CNI enforces NetworkPolicy, which the chapter and the
  manifests had said it did not, so the gap was invisible until now. Fixed in
  all three forms (`allow-data-tier-ingress`); chapter 02.06 still teaches the
  old set.
* **The canary variant cannot run beside the app.** The raw form deployed
  `30-catalog-canary.yaml` next to `10-catalog-deploy.yaml`, which its own header
  forbids, and then next to everything, where only 6 of its 9 stable replicas
  fit the 4 CPU namespace quota. Its header asks for the namespace and the
  ServiceAccounts and nothing else, so the gate now runs it alone, after the
  rest has passed. It is exercised, not skipped.
* **The production overlay's namespace quota was smaller than its own
  replicas.** Its Deployments come to 5.0 CPU of limits against a quota of 4,
  so postgres and the migration Job were refused (`exceeded quota`).
  `overlays/prod` and `values-prod.yaml` now size the quota to about twice
  their steady state.
* **The production overlay pins a registry that does not exist.**
  `registry.example.com/bookstore/<service>:1.0.0` gave `ImagePullBackOff`. The
  CI job now tags the images it built with those names and loads them, so the
  overlay deploys as written.

After those fixes the third run passed all five forms on GitHub's runners.
`raw` reached 13 workloads Ready or Complete in 94 seconds (both snapshot
Pods, every workload, the CronJob run by hand, then the canary alone), and
`helm`, `kustomize-dev`, `kustomize-staging` and `kustomize-prod` reached 9
each in 42 to 48 seconds. The gate also lists, per run, the custom resources it
skipped because a plain kind cluster has no CRD for them (a ServiceMonitor, a
KEDA ScaledObject, a Gateway). None of them runs a container.
