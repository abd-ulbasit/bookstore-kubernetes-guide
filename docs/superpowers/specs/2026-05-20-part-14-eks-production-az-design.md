# Part 14 — "EKS in Production: A-Z" Design

> **Delta-spec** building on the comprehensive Kubernetes guide design
> (`2026-05-19-kubernetes-comprehensive-guide-design.md`), the extension
> design (`2026-05-19-kubernetes-guide-extension-design.md`), and the
> Bookstore Platform v2 spec (`2026-05-20-bookstore-platform-v2-design.md`).
> All three remain in effect; this spec adds **Part 14** and **rounds out the
> Terraform tree** at `examples/bookstore-platform/terraform/`.

## The problem

Parts 00–13 + the Terraform tree teach Kubernetes from zero to a deployed,
multi-tenant, multi-region, ML-powered platform. A live EKS cluster smoke
test (2026-05-20) validated the deploy + Karpenter autoscaling + clean
teardown end-to-end. **But** the smoke test surfaced a clear gap: real-world
EKS production operations involve a layer of discipline that the previous
13 Parts touched on but never made concrete with cloud-specific depth. The
user named the gap directly: "I want to learn kubernetes in production A-Z."

Part 14 closes this gap with 12 chapters that take every production
operational concern the smoke test (and a year of real EKS ops) surface
and turn it into a working chapter + concrete Terraform/manifest artifacts.

## Scope

Two simultaneous deliverables:

1. **Part 14 chapters** (12 new chapters under `full-guide/14-eks-in-production-a-to-z/`)
2. **Terraform-tree expansion** at `examples/bookstore-platform/terraform/`
   covering Tier 1+2+3 from the post-smoke-test assessment.

## What we are NOT doing

- Re-teaching anything that Parts 10–13 already covered. Each Part 14 chapter
  deepens or operationalizes — never restates.
- Replacing the Bookstore Platform v2 reference implementation. The platform
  v2 tree stays; Part 14 builds **on top of** it.
- Adding a new top-level example tree. The Terraform additions live in the
  existing `examples/bookstore-platform/terraform/` (with sub-directories
  for clearly separable concerns like the account-baseline).
- Building production infrastructure for a user to copy-paste without
  reading. Every Terraform addition is var-gated (default OFF for anything
  that costs money) and documented.

## Terraform-tree expansion (Phase 14-R)

Single batched dispatch that adds **all** Tier 1+2+3 items to the existing
Terraform tree. Naming follows the established conventions; no breaking
changes to existing variables/outputs.

### Tier 1 — closes real gaps the smoke test found

1. **CloudWatch log retention** — `cloudwatch_log_group_retention_in_days = 30`
   on the EKS module so cluster control-plane logs don't accumulate forever.
   Var-controlled (default 30). Same retention for the LB controller +
   Karpenter helm-release log groups (created by AWS, not Terraform).
2. **`before_compute = true` on `vpc-cni` addon** — closes the first-boot
   flake where worker nodes come up briefly without CNI. (Optional spec
   finding M-6 from the security review.)
3. **gp3 default StorageClass** — `kubectl_manifest` that creates a
   `gp3-encrypted` StorageClass with the `is-default-class: "true"` annotation
   and removes that annotation from the EKS-bundled `gp2`. Cost: ~20% cheaper
   than gp2 for equivalent perf.
4. **Optional cost-budget alarm** — `var.enable_budget_alarm = false` default;
   when set true, creates `aws_budgets_budget` with email-on-80%-threshold
   via SNS topic. The user supplies `var.budget_alarm_email`.
5. **`make plan-cost`** — Makefile target that runs `terraform plan` and
   pipes through `infracost` (if installed) for a $/month estimate before
   apply. Gracefully degrades if `infracost` not on `$PATH` (prints "install
   infracost from https://infracost.io" and continues).

### Tier 2 — production-shape additions, all var-gated default-off

6. **GitHub Actions example** at `.github/workflows/terraform.yml` (lives
   under the Terraform tree, NOT the project root — this is a sample
   workflow for users to copy to their repo). Plan-on-PR, apply-on-merge,
   uses GitHub OIDC trust to assume an IAM role (no static AWS creds).
7. **VPC endpoints** — `var.enable_vpc_endpoints = false` default; when
   true, creates Interface endpoints for ECR-API, ECR-DKR, STS, EC2,
   CloudWatch-Logs, plus a Gateway endpoint for S3. Cuts NAT data-transfer
   charges for heavy workloads.
8. **Graviton NodePool** — `var.enable_graviton_pool = false` default;
   when true, creates an arm64 Karpenter NodePool with `kubernetes.io/arch:
   arm64` selector + the `al2023@latest-arm64` AMI alias. Honest about the
   image-rebuild discipline this requires.
9. **Argo CD bootstrap** — `var.enable_argocd_bootstrap = false` default;
   when true, installs Argo CD via Helm + applies a root `ApplicationSet`
   that points at the user's GitOps repo. Solves the chicken-and-egg of
   "GitOps needs Argo CD; Argo CD needs to be installed first."
10. **Multi-region scaffolding** — a `multi-region/` sub-directory with a
    `module.tf` that wraps the existing EKS module + VPC module so the
    primary tree can be instantiated 3× (us-east-1, eu-west-1,
    ap-southeast-1, or any region triple). Single-cluster default behavior
    is unchanged. Multi-region full operation is documented + the
    cross-region wiring (CNPG ReplicaCluster + ApplicationSet over Cluster
    generator) is sketched as comments + a TODO list.

### Tier 3 — full A-Z coverage

11. **`account-baseline/`** — separate Terraform tree under
    `examples/bookstore-platform/terraform-account-baseline/` (deliberately
    NOT inside the main tree — account-level posture is a different concern
    from per-cluster infra). Enables: GuardDuty, Security Hub, AWS Config
    with K8s + EKS conformance packs, organization-wide CloudTrail to S3
    with KMS, IAM Access Analyzer. **Strongly var-gated:** every service
    is `var.enable_<SERVICE> = false` default; the README explains the
    cost (~$30-100/month for a small account) and the value (compliance
    + forensic timeline).
12. **Drift detection example** — a `drift-check/` sub-directory containing:
    a) a GitHub Actions workflow that runs `terraform plan -detailed-exitcode`
    nightly and opens a PR if drift detected; b) a sample `atlantis.yaml`
    config showing the same pattern via Atlantis if the user has that;
    c) a one-page `DRIFT.md` runbook ("what to do when drift is detected").

## Part 14 — 12 chapters

### Threading & cross-references

- Each chapter follows the **9-section anatomy** (Title + 1-line summary,
  Why, Mental model, Diagrams Mermaid+ASCII, Hands-on, How it works under
  the hood, Production notes, Quick Reference, Further reading).
- Hands-on uses `examples/bookstore-platform/terraform/` paths.
- Chapter 14.12 follows the capstone shape (Part 12 ch.08 / Part 13 ch.12)
  with extra H2s for "What we did not build" + "Closing the production-A-Z
  thread".
- Each chapter ties to prior Parts with **one sentence + relative link**
  (deepen-don't-duplicate discipline established in Parts 10–13).

### Chapter list (delta from Bookstore Platform v2 spec)

#### **14.01 — Production-grade Terraform state**
- The 4 failure modes of local state: laptop loss, two-laptop drift, CI
  runners, audit.
- S3 backend + `use_lockfile = true` (Terraform 1.10+ / AWS provider 6+,
  no DynamoDB needed).
- Bucket bootstrap (chicken-and-egg) via `bootstrap-state.sh`.
- State file hygiene: versioning, encryption (SSE-S3 vs SSE-KMS), lifecycle
  for noncurrent versions, public-access-block.
- `terraform state` commands every operator should know (list, mv, rm,
  import, replace).
- Workspaces (Terraform vs Terragrunt vs separate root modules — when which).
- Cites: Terraform official S3 backend docs + Rosso PK *State management*.

#### **14.02 — EKS cluster lifecycle**
- 14-month standard support + 12-month extended support window.
- The $0.50/cluster-hour extended-support fee math ($360/month per cluster).
- AWS EKS Kubernetes release calendar discipline (refreshed monthly).
- In-place version upgrade process: control plane → addons → managed
  nodes → Karpenter nodes (auto via NodePool `expireAfter`).
- Blue-green cluster pattern for major Kubernetes version jumps.
- Pinned-version Terraform variable + the version-bump runbook.
- Cites: AWS EKS official docs (Kubernetes versions on EKS) + Rosso PK
  *Cluster lifecycle*.

#### **14.03 — EKS add-on management discipline**
- Managed addons (vpc-cni, kube-proxy, CoreDNS, EBS-CSI) vs self-managed
  (everything else).
- The `before_compute = true` first-boot flake — what it is, why it
  matters, when it doesn't.
- Addon version skew tolerance + the conformance window per K8s version.
- IRSA wiring for addons that need cloud-side credentials (EBS-CSI,
  vpc-cni IPv6, Pod Identity Agent).
- `resolve_conflicts_on_update = OVERWRITE` semantics.
- Cites: AWS EKS addon docs + the terraform-aws-modules/eks/aws README.

#### **14.04 — Storage classes & EBS in production**
- gp2 vs gp3: cost (~20% cheaper), perf (3000 IOPS baseline), and the
  burst-credit footgun gp2 carries.
- Setting the default StorageClass via the
  `storageclass.kubernetes.io/is-default-class: "true"` annotation.
- Demoting EKS's bundled `gp2` so it's not the default any more.
- EBS encryption (CMK rotation, AWS-managed vs customer-managed).
- VolumeSnapshot lifecycle (cross-ref Part 03 ch.05) at cloud scale —
  the snapshot-of-snapshot reality and snapshot-bill surprise.
- Cross-AZ EBS: the always-AZ-local fact and how StatefulSet topology
  spread interacts.
- Cites: AWS EBS gp2-vs-gp3 blog + Ibryam KP2e *Stateful Service*.

#### **14.05 — Logging & metrics cost discipline**
- The "CloudWatch ate my budget" story — log groups with infinite
  retention, ingestion at $0.50/GB, storage at $0.03/GB-month.
- `cloudwatch_log_group_retention_in_days = 30` + when to go shorter (7)
  vs longer (90).
- Metrics cardinality control — high-cardinality labels (per-pod, per-tenant,
  per-request-id) explode Prometheus storage cost.
- Loki vs CloudWatch Logs cost trade — Loki is cheaper at scale but
  operationally heavier; CloudWatch is fully-managed but pricey.
- Sampling vs scrubbing vs retention — the three cost levers.
- Cites: AWS CloudWatch pricing docs + Grafana Loki TCO blog + Google SRE
  Book ch.6 *Monitoring*.

#### **14.06 — Cost guardrails**
- The three tiers of cost visibility: AWS Budgets (alarms),
  Cost Explorer (analysis), OpenCost (per-tenant inside the cluster).
- `aws_budgets_budget` Terraform — when to use email vs SNS vs Slack.
- `infracost` in CI (plan + cost diff per PR) — preventing surprise.
- The 80/20 of cost optimization: spot for batch, Graviton for stable,
  right-sizing recommendations from VPA + OpenCost.
- Showback vs chargeback timing — when an org is ready for chargeback.
- Cites: FinOps Foundation framework + AWS Budgets docs + infracost.io.

#### **14.07 — Infrastructure CI/CD + drift detection**
- The 5 patterns: laptop apply, shared Jenkins, GitHub Actions, Atlantis,
  Spacelift. When each wins.
- GitHub Actions OIDC trust for `aws-actions/configure-aws-credentials`
  — no long-lived secrets in CI.
- Plan-on-PR + Apply-on-merge — the gold-standard workflow.
- Drift detection: scheduled `terraform plan -detailed-exitcode`, the
  driftctl tool, AWS Config + custom rules.
- The "console emergency" workflow — when someone changed it via the
  console, how to reconcile.
- Cites: Atlantis docs + driftctl docs + the GitHub Actions OIDC blog.

#### **14.08 — VPC endpoints & egress economics**
- NAT gateway cost math: $0.045/hr + $0.045/GB data-processed. At 1
  TB/month of S3 traffic that's $45 NAT data charges alone.
- Gateway endpoints (S3, DynamoDB) — free, no NAT involvement.
- Interface endpoints (ECR-API, ECR-DKR, STS, CloudWatch-Logs, EC2, KMS,
  SecretsManager) — $0.01/hr per endpoint per AZ + $0.01/GB.
- Break-even math: when do endpoints pay off? (For 3-AZ, ECR + STS + S3
  pay back at ~50 GB/month of NAT traffic.)
- Endpoint policy — restricting endpoint access to specific resources.
- Cites: AWS VPC endpoint docs + the "AWS networking cost" blog.

#### **14.09 — ARM/Graviton on EKS**
- The economics: ~20% cheaper than equivalent x86, same SLA.
- Multi-arch image discipline: `docker buildx build --platform
  linux/amd64,linux/arm64` + the Bookstore Go services' Dockerfile changes.
- Karpenter NodePool with `kubernetes.io/arch: arm64` requirement.
- Where ARM doesn't make sense: NVIDIA CUDA workloads (no Graviton+GPU),
  legacy software with x86-only binaries.
- The mixed-arch cluster pattern: x86 NodePool for legacy + Graviton
  NodePool for greenfield.
- Cites: AWS Graviton docs + the Docker buildx multi-platform docs.

#### **14.10 — GitOps bootstrap on a fresh EKS cluster**
- The chicken-and-egg: GitOps reconciles cluster state; but Argo CD
  itself must be installed first; but Argo CD's own manifests should be
  in a GitOps repo too. How do you bootstrap?
- The App-of-Apps pattern: a single root Application that owns the
  Argo CD installation + every other Application.
- Argo CD self-management — Argo CD reconciles itself after the bootstrap.
- Sealed-secret bootstrap — the same chicken-and-egg, smaller.
- The Crossplane variant: Crossplane CD vs Argo CD CD (when which).
- Cites: Argo CD official docs + the App-of-Apps canonical blog.

#### **14.11 — Multi-region active-active: cloud reality**
- The Part 13 ch.03 picture was kind-simulated; this is the real version.
- Route 53 latency-based routing + health checks + failover routing policies.
- AWS Global Accelerator vs Route 53 — when which (anycast vs DNS).
- ALB per region vs Global Accelerator for unified IP.
- CNPG cross-region streaming replication + the network bandwidth cost.
- Cross-region cluster identity — IRSA across regions, OIDC providers per
  cluster.
- The "real failover" drill — what RTO/RPO numbers are achievable.
- Cites: AWS Route 53 latency routing + Global Accelerator + CNPG docs.

#### **14.12 — Cross-region DR + AWS account baseline + 90-day production-readiness runbook (capstone)**
- Cross-region DR for stateful workloads: backup strategy, S3 cross-region
  replication, CNPG ReplicaCluster real-world tuning, RPO/RTO math.
- AWS account-level security baseline (GuardDuty, Security Hub, AWS Config
  conformance packs for K8s + EKS, organization-wide CloudTrail).
- The 90-day production-readiness runbook — a structured 90-day onboarding
  for a team taking over EKS infrastructure.
- "What we did not build" honest list: chaos engineering at AWS scale,
  cell-based architecture, sovereign-cloud variants, FinOps phase-3
  optimization.
- Closing arc — the through-line of Part 14 + the through-line of the entire guide.
- Cites: AWS GuardDuty/Security Hub docs + Rosso PK *Day 2 operations* +
  Google SRE Book ch.32 *Evolving SRE engagement model*.

## Hard invariants

- Original Bookstore (`examples/bookstore/`) **untouched** by Part 14.
- Parts 00–13 chapters **untouched** (md5-byte-identical).
- Helm 49 / Kustomize 45/49/48 / DB_DSN identical / `helm lint` 0-failed.
- All Tier 1+2+3 Terraform additions are **additive** — existing variables
  keep their defaults, no breaking changes for users with existing state.
- All cost-bearing features are **var-gated default-off**: `enable_budget_alarm`,
  `enable_vpc_endpoints`, `enable_graviton_pool`, `enable_argocd_bootstrap`,
  all of `account-baseline/`.
- New chapters follow the 9-section anatomy; ch.14.12 has the capstone
  shape with extra H2s.
- Mermaid validity; `<UPPERCASE>` placeholders; pinned-Helm everywhere;
  CRD-intrinsic notes on every CRD-backed manifest.
- No machine-specific leaks; no hardcoded AWS account IDs.
- Terraform additions pass `terraform fmt -recursive -check` + `terraform validate`.

## Build methodology

Same as Parts 10–13: each phase is opus implementer → sonnet spec-review
→ sonnet code-quality-review → fix-loop. Continuous, no user check-ins
unless BLOCKED. Final phase (14e) is the independent audit.

## Acceptance

- Phase 14-R: every Tier 1+2+3 item present in the Terraform tree; tree
  passes fmt + validate.
- Phases 14a/b/c: every chapter ships with spec-review APPROVED +
  code-quality-review APPROVED + fix-loop closed.
- Phase 14d: README TOC + appendix B (~30 new terms) + appendix D (Part 14
  section) + 14-check guide-wide consistency re-proof.
- Phase 14e: independent audit verifies every reviewer concern was fixed
  in live files; hard invariants re-proven; SHIP_IT verdict.

---

## ADDENDUM (2026-05-20, mid-build) — 5 new chapters + Tier 4 Terraform

User asked "anything else?" mid-flight. Honest assessment: 5 more topics genuinely belong before "A-Z" is accurate. Total Part 14 = **17 chapters**.

### New chapters (slot between existing 14.11 and the capstone)

**14.12 — Supply chain security in production**
- ECR image scanning (basic + enhanced) — cost vs coverage trade.
- SBOM generation with `syft`; SBOM consumption with `grype` for CVE matching in CI.
- Weekly distroless base-image rebuild discipline — the "you don't patch a container; you replace it" mindset.
- `cosign sign` in CI + Kyverno `ClusterPolicy` enforcing `verifyImages` at admission (the cloud version of Part 05 ch.03).
- Supply-chain attestation: SLSA framework levels 1–4, where most teams realistically land.
- Cites: Sigstore docs + Kyverno verify-images docs + Rosso PK *Supply chain*.

**14.13 — Runtime defense & container security**
- The threat model post-admission: container escape, privilege escalation, lateral movement, cryptojacking.
- **Falco**: rules engine + the canonical syscall rules (writes to system binaries, shell in container, etc.); IRSA + S3 for the audit trail.
- **Tetragon** (Cilium ecosystem): eBPF-based, lower overhead, kernel-event granularity.
- **GuardDuty for EKS Protection**: AWS-managed threat detection that ingests cluster audit logs + EC2 network flows; what it catches that Falco doesn't.
- Real incident walk-through: what a runtime alert flow looks like end-to-end (Falco → SNS → PagerDuty → human triage → kubectl evidence collection → postmortem).
- Cites: Falco docs + Cilium Tetragon docs + AWS GuardDuty for EKS docs.

**14.14 — Backup & restore with Velero**
- Velero install via Helm + IRSA for S3 + the `BackupStorageLocation` + `VolumeSnapshotLocation` config.
- Schedule-based backups (CronJob-style) + on-demand backups.
- Restic / Kopia for PV data (file-level backup when CSI snapshot isn't available).
- Restore drill — actual `velero restore create` against a fresh cluster.
- What Velero CAN'T back up: cloud-side resources (RDS data, S3 buckets, IAM roles); separate strategy required (Part 14.17 covers cross-region DR for these).
- Backup retention math: 7 daily + 4 weekly + 12 monthly = 23 backups; what each costs on S3.
- Cites: Velero docs + Rosso PK *Backup and restore*.

**14.15 — Cilium / eBPF on EKS**
- Why Cilium over VPC-CNI: L7 NetworkPolicy, Hubble observability, kube-proxy replacement, better-than-iptables performance.
- The migration story: EKS clusters created with VPC-CNI; switching requires draining + reconfiguring (not a simple `kubectl apply`).
- Cilium NetworkPolicy beyond L4: HTTP method/path matching, Kafka topic filtering, gRPC method filtering.
- Hubble: real-time cluster networking observability — answers "what just happened between Pod A and Pod B?".
- Cluster Mesh: connecting two Cilium clusters without a service mesh.
- Operational reality: when sticking with VPC-CNI is the right call (AWS-feature compatibility, simpler ops).
- Ships an `examples/bookstore-platform/terraform/cilium-installation.tf.example` — opt-in only because it replaces a default cluster component.
- Cites: Cilium docs + Hubble docs + Isovalent blog.

**14.16 — Developer experience for K8s teams**
- The inner loop problem: code → build → push → deploy → test is too slow at K8s scale.
- **Telepresence** / **Mirrord** — re-route traffic to a developer's laptop process so they can debug against a real cluster.
- **Skaffold** / **Tilt** — file-watcher → rebuild → port-forward, minimizing the build cycle.
- **Devcontainers** + a remote EKS cluster — VS Code dev container talks to a real cluster, but the developer's machine never installs cluster tools.
- The 5-minute onboarding pattern: how a new engineer goes from `git clone` to running production code locally in 5 minutes (Backstage scaffolder + Telepresence + Skaffold pre-configured).
- Cites: Telepresence docs + Tilt docs + Mirrord docs + Devcontainer spec.

### Renumbered capstone

**14.17 — Cross-region DR + AWS account baseline + 90-day production-readiness runbook (capstone)** — content unchanged from previous 14.12; just renumbered.

### Tier 4 Terraform additions (folded into Phase 14-R)

- **Velero installation** — `var.enable_velero = false` default; when true, installs Velero via Helm with IRSA + creates an S3 bucket + `BackupStorageLocation` + sample schedule.
- **Falco installation** — `var.enable_falco = false` default; when true, installs Falco via Helm with rule-set + SNS topic for alerts.
- **Kyverno image-signing ClusterPolicy** — `var.enable_image_signing = false` default; when true, installs Kyverno + applies a `verifyImages` ClusterPolicy in `audit` mode (warns but doesn't block; production swaps to `enforce`).
- **Cilium installation** — NOT a var on the main tree. Lives as `examples/bookstore-platform/terraform/cilium-installation.tf.example` — opt-in only because it requires removing VPC-CNI first. Sample shows the full sequence.

### New build phases

| Phase | Content |
|-------|---------|
| 14-R | Tier 1+2+3+4 Terraform additions (one batched dispatch) |
| 14a | Chapters 14.01–14.04 |
| 14b | Chapters 14.05–14.08 |
| 14c | Chapters 14.09–14.12 (Graviton / GitOps / multi-region / **supply chain**) |
| **14d** | **Chapters 14.13–14.16 (runtime defense / Velero / Cilium / DX) — NEW PHASE** |
| **14e** | **Chapter 14.17 capstone (cross-region DR + account baseline + 90-day runbook) — single-chapter dispatch** |
| 14f | Finalize (README TOC, appendix B+D, intro refresh, 14-check consistency) |
| 14g | Final independent audit + SHIP_IT verdict |

---

## ADDENDUM 2 (2026-05-21) — Part 15 introduced as follow-on

User requested coverage of the day-to-day production operations lifecycle:
PR → CI/CD → merge → GitOps deploy → secrets from Vault → progressive rollout
→ rollback → incident response → on-call → postmortem. After reflection,
this is **a separate coherent arc from Part 14** (which is "EKS-specific
production infrastructure"), so it lands as a NEW Part 15: "Day-to-Day
Production Operations" — 12 chapters at `full-guide/15-day-to-day-production-ops/`.

Part 14 build continues as planned (a→g phases). Part 15 follows.

### Part 15 chapter list

1. **15.01 — The PR-to-production lifecycle** — mental model of how a change flows from dev to prod
2. **15.02 — Application CI/CD pipelines** — GitHub Actions for Bookstore Go services: lint → test → scan → build → cosign sign → push to ECR
3. **15.03 — Image signing and provenance in CI** — cosign keyless signing + SBOM with syft + Kyverno verifyImages cloud version (deepens Part 14 ch.12)
4. **15.04 — Multi-environment promotion** — dev/staging/prod with Argo CD ApplicationSet pattern; promotion gates; per-env values
5. **15.05 — Production secrets: Vault + ESO + rotation** — Terraform-managed Vault, ExternalSecret CRDs, automatic rotation (deepens Part 11 ch.05)
6. **15.06 — Progressive delivery in production** — Argo Rollouts canary + blue-green with metric analysis SLO gates (deepens Part 07 ch.05)
7. **15.07 — Rollback playbook** — code rollback (Argo CD, Helm, Rollouts), data rollback (Postgres PITR, S3 versioning, Velero), config rollback
8. **15.08 — Feature flags and dark launches** — LaunchDarkly/Unleash/Flagsmith patterns; decoupling deploy from release
9. **15.09 — Hotfix workflow + breakglass** — emergency change procedures; breakglass access patterns; when to bypass GitOps and how to clean up after
10. **15.10 — Incident response & on-call** — detection → triage → resolution → postmortem (deepens Part 13 ch.12); PagerDuty integration; severity matrix
11. **15.11 — Day-to-day production operations** — cost reviews; capacity planning; scaling decisions; the weekly/monthly ops cadence
12. **15.12 — Capstone: the first 90 days running production** — synthesis; how a team graduates from "cluster works" to "team owns the platform"

### Project artifacts (new `examples/bookstore-platform/` sub-directories)

- `ci/` — GitHub Actions workflows for the Bookstore Go services (the real app-CI/CD)
- `vault/` — Vault Helm + auth-method + policy + ExternalSecret samples
- `rollback/` — sample rollback runbooks + Argo Rollouts AnalysisTemplate manifests
- `feature-flags/` — Flagsmith/Unleash Helm + SDK integration sample
- `incident/` — PagerDuty integration + incident-channel automation + postmortem template

### Part 15 build phases

- **Phase 15-R** — Terraform tree additions for Vault (var-gated Helm release; Vault Terraform provider config)
- **Phase 15a** — ch.15.01–15.03
- **Phase 15b** — ch.15.04–15.06
- **Phase 15c** — ch.15.07–15.09
- **Phase 15d** — ch.15.10–15.11
- **Phase 15e** — ch.15.12 capstone
- **Phase 15f** — Finalize (README TOC, appendix B/D, intros — total chapter count = 86 + 17 + 12 = **115 chapters**)
- **Phase 15g** — Final cross-Part audit (Parts 14+15 combined) + SHIP_IT verdict
