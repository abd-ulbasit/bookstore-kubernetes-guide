# The Bookstore Guide — Kubernetes from Zero to Production

[![docs](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/actions/workflows/docs.yml/badge.svg?branch=main)](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/actions/workflows/docs.yml)
[![example-trees-check](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/actions/workflows/example-trees-check.yml/badge.svg?branch=main&event=schedule)](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/actions/workflows/example-trees-check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.37-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io)
[![Terraform](https://img.shields.io/badge/terraform-1.10-7B42BC?logo=terraform&logoColor=white)](https://www.terraform.io)
[![Helm](https://img.shields.io/badge/helm-3.22-0F1689?logo=helm&logoColor=white)](https://helm.sh)
[![GitHub last commit](https://img.shields.io/github/last-commit/abd-ulbasit/bookstore-kubernetes-guide?logo=github)](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/commits/main)

**Live site:** **<https://abd-ulbasit.github.io/bookstore-kubernetes-guide/>**

A standalone, hands-on Kubernetes learning guide that takes you from container
fundamentals to running multi-region production platforms across
**16 Parts / 123 chapters**, all anchored on one evolving microservices
application — *Bookstore*. Concepts compound instead of resetting per topic:
every chapter's hands-on section advances the *same* app.

This README is for anyone who lands on the repo on GitHub. The reading
experience is the live site above; everything below is just orientation.

## Status: rewritten security-first

The guide was rewritten so that every manifest it shows is secure from
the first one: a non-root user, a read-only root filesystem, no privilege
escalation, no capabilities and a seccomp profile, in a namespace that
enforces the `restricted` Pod Security level. The reader never learns a
habit that a later chapter reverses. The reasoning is in
[ADR 0009](docs/adr/0009-security-first-guide-and-gates.md), the rules every
chapter follows are in [`docs/security-first-authoring.md`](docs/security-first-authoring.md),
and the targets are Kubernetes 1.37 and kind v0.33.0.

**Done.** Parts 00 to 15 are rewritten and enforced: 123 chapters, from
[00.01 Why Kubernetes](full-guide/00-foundations/01-why-kubernetes.md) to
[15.12 Capstone: the first 90 days](full-guide/15-day-to-day-production-ops/12-capstone-first-90-days.md).
CI fails a pull request that breaks any of them. The list is
[`.github/security-gates-enforced.txt`](.github/security-gates-enforced.txt).
The appendix (A to F) is rewritten too. It holds no manifest for the
manifest gates to judge, so it is not on that list, and the lab-evidence
gate still checks its lab records.

No cluster was created on AWS or GCP during the rewrite. The cloud
chapters in Parts 10 and 14 validate their Terraform offline and mark the
cloud steps as cited, not run.

**Not done.** Parts 16 and 17 are outlines: GKE in production, and the ML
platform on GKE. They hold a plan and no chapters yet. Their labs wait,
because no chapter is written before its lab has run against a real
cluster. Their pages say what has been run so far.

## Try the hands-on, zero setup

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/abd-ulbasit/bookstore-kubernetes-guide?devcontainer_path=.devcontainer%2Fdevcontainer.json)

Clicking the badge spins up a browser-based dev environment with everything
the guide uses pinned to the versions the chapters cite — `kubectl 1.37.2`,
`helm 3.22.1`, `terraform 1.14.8`, `kind 0.33.0`, `k3d 5.9.0`, `go 1.26.10`,
`python 3.12`, `aws-cli`, plus the MkDocs Material toolchain. About 90 seconds
from click to a shell where `kind create cluster` and `helm install bookstore`
both just work. Config: [`.devcontainer/`](.devcontainer/).

## What's inside

| Path | Contents |
|---|---|
| `full-guide/00-foundations/` … `15-day-to-day-production-ops/` | The chapters themselves (123 of them). Each one has a per-chapter learning-metadata block, a self-assessment section with collapsible answers, and runnable hands-on steps that touch the example trees below. |
| `full-guide/appendix/` | A–F: glossary, cheat sheets, reading paths, **concept map + tag index** |
| `full-guide/16-gke-in-production-a-to-z/`, `full-guide/17-ml-platform-on-gke/` | Outlines for the GKE Parts, with no chapters yet. Their labs wait |
| `full-guide/examples/security-lab/` | The lab scripts and the captured transcripts (`evidence/`) that the chapters quote and CI checks |
| `full-guide/examples/bookstore/` | Canonical example tree — runs on **kind/k3d** locally, no cloud needed (Parts 02–08) |
| `full-guide/examples/bookstore-platform/` | Platform v2 — multi-tenant, GitOps, Keycloak + IRSA + Istio (Parts 12–13) |
| `full-guide/examples/bookstore-platform/terraform/` | EKS infrastructure as Terraform — **live-smoke-tested** on AWS EKS 1.35 in `ap-south-1` on 2026-05-20; now defaults to EKS 1.37 with Karpenter 1.15.1, smoke test not yet re-run (Part 14) |
| `full-guide/examples/bookstore-platform/terraform-account-baseline/` | AWS-account-wide guardrails (CloudTrail, Security Hub, GuardDuty, IAM Access Analyzer) |
| [`docs/adr/`](docs/adr/) | Architecture Decision Records — the load-bearing technical decisions, why they were made, and the trade-offs |
| [`docs/lessons-from-smoke-test.md`](docs/lessons-from-smoke-test.md) | Post-mortem of running this guide's Terraform against real EKS — what broke, why, and the five fixes that became Tier-1 defaults |
| `.github/workflows/` | `docs` (builds + deploys the site, validates every mermaid block) + `example-trees-check` (Helm/Kustomize counts, Terraform fmt+validate, host-path hygiene) + `secret-scan` (gitleaks over the full history, every PR) + `link-check` (external URL rot) + `security-scan` (Trivy incl. every Terraform root, govulncheck over every discovered Go module — triage in [`SECURITY-SCAN.md`](SECURITY-SCAN.md)) |

## Reading paths by role

The full 16-Part arc is the recommended path. If you're short on time and
want to read the chapters most relevant to a specific role first:

- **Backend developer joining a Kubernetes team** → Parts 00 (foundations) ·
  01 (core workloads) · 02.01–02.03 (networking basics) · 03 (config &
  storage) · 06.01–06.03 (production-readiness) · 07.01–07.02 (Helm &
  Kustomize). ~30 chapters; gets you "I can ship a service to a cluster
  and understand what's happening."
- **Platform / DevOps engineer** → all of Backend above, then 04
  (scheduling) · 07 (delivery) · 08 (Day-2 ops) · 10 (cloud-managed K8s)
  · 14 (EKS-in-production A-Z). ~60 chapters; gets you the operator's
  view end to end.
- **SRE / on-call engineer** → 01.02 (probes & lifecycle) · 06 entirely
  (production-readiness) · 08 (Day-2 ops) · 14.13 (runtime defense) ·
  14.14 (Velero backups) · all of 15 (day-to-day production ops:
  rollback, feature flags, hotfix, incident response, breakglass).
  ~30 chapters; the chapters that matter at 3 AM.
- **Security engineer** → 05 (security) entirely · 10.03 (cloud identity:
  IRSA / Pod Identity / Workload Identity) · 13.04 (Keycloak + IRSA +
  Istio JWT) · 14.12 (supply chain) · 14.13 (runtime defense / Falco) ·
  14-R Terraform additions (CloudTrail / Security Hub / GuardDuty). ~20
  chapters.
- **Manager evaluating "should our team learn this"** → README.md (this
  file) · [`docs/lessons-from-smoke-test.md`](docs/lessons-from-smoke-test.md)
  · [`docs/adr/`](docs/adr/) · the Part 14.17 capstone. ~6 reads, ~90
  minutes; gives you the depth signal and the operator-grade detail
  without committing to the full arc.

## How to read it

- **Online (recommended):** <https://abd-ulbasit.github.io/bookstore-kubernetes-guide/>
- **In Obsidian / your editor:** clone the repo and open `full-guide/`
- **Locally as a site:** `pip install -r requirements.txt && mkdocs serve`

## How to run the examples

Each chapter's hands-on section gives the exact commands. The two starting
points:

- **Local cluster (Parts 00–11):** `kind create cluster` or
  `k3d cluster create --image rancher/k3s:v1.37.1-k3s1`
- **Live AWS (Part 14):** `cd full-guide/examples/bookstore-platform/terraform && terraform init && terraform apply`
  (costs **~$0.20/hour**, every dollar-bearing variable defaults to off; full
  teardown documented in `terraform/cleanup-pre-destroy.sh`)

## Quality gates

Every commit to `main` runs:

- `mkdocs build --strict` — no broken internal links, no missing nav refs
- **`mermaid.parse()` against every diagram** — catches "Syntax error in text"
  before the site deploys (using the same parser version production renders with)
- Helm/Kustomize/Terraform shape checks (nightly + on PR)
- gitleaks secret scan over the full git history (every PR + nightly)
- External link-check (weekly)
- The security-first gates (`security-gates` workflow): Trivy's core checks on
  every manifest, a dry run into a `restricted` namespace on kind, and a
  runtime check that deploys the Bookstore five ways and waits for every
  workload. See [ADR 0009](docs/adr/0009-security-first-guide-and-gates.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Bug reports and content
corrections welcome via [issues](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/issues);
open-ended questions belong in [Discussions](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/discussions).
For security findings, see [`SECURITY.md`](SECURITY.md) — please don't
open a public issue.

## Changelog

Versioned per [SemVer](https://semver.org/); see [`CHANGELOG.md`](CHANGELOG.md).

## License

MIT — see [`LICENSE`](LICENSE). Both the prose and the example code are MIT.

## Built with

This guide was built using the [Claude Code](https://claude.com/claude-code)
Superpowers skill set: multi-agent spec → plan → implement → review cycles
with continuous quality gates. The methodology is written up in
[ADR 0002](docs/adr/0002-multi-agent-fix-loop.md). The raw specs and plans
that drove the pipeline are no longer carried in the tree — they were
authoring inputs, not reader-facing documentation — but they remain in the
git history for anyone who wants to read them.
