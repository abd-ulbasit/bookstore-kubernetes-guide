# The Bookstore Guide — Kubernetes from Zero to Production

**Live site:** **<https://abd-ulbasit.github.io/bookstore-kubernetes-guide/>**

A standalone, hands-on Kubernetes learning guide that takes you from container
fundamentals to running multi-region production platforms across
**16 Parts / 115 chapters**, all anchored on one evolving microservices
application — *Bookstore*. Concepts compound instead of resetting per topic:
every chapter's hands-on section advances the *same* app.

This README is for anyone who lands on the repo on GitHub. The reading
experience is the live site above; everything below is just orientation.

## Try the hands-on, zero setup

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/abd-ulbasit/bookstore-kubernetes-guide?devcontainer_path=.devcontainer%2Fdevcontainer.json)

Clicking the badge spins up a browser-based dev environment with everything
the guide uses pinned to the versions the chapters cite — `kubectl 1.35.0`,
`helm 3.16.0`, `terraform 1.10.5`, `kind 0.27.0`, `k3d 5.8.3`, `go 1.22`,
`python 3.12`, `aws-cli`, plus the MkDocs Material toolchain. About 90 seconds
from click to a shell where `kind create cluster` and `helm install bookstore`
both just work. Config: [`.devcontainer/`](.devcontainer/).

## What's inside

| Path | Contents |
|---|---|
| `full-guide/00-foundations/` … `15-day-to-day-production-ops/` | The chapters themselves (115 of them). Each one has a per-chapter learning-metadata block, a self-assessment section with collapsible answers, and runnable hands-on steps that touch the example trees below. |
| `full-guide/appendix/` | A–F: glossary, cheat sheets, reading paths, **concept map + tag index** |
| `full-guide/examples/bookstore/` | Canonical example tree — runs on **kind/k3d** locally, no cloud needed (Parts 02–08) |
| `full-guide/examples/bookstore-platform/` | Platform v2 — multi-tenant, GitOps, Keycloak + IRSA + Istio (Parts 12–13) |
| `full-guide/examples/bookstore-platform/terraform/` | EKS infrastructure as Terraform — **live-smoke-tested** on AWS EKS 1.35 in `ap-south-1` (Part 14) |
| `full-guide/examples/bookstore-platform/terraform-account-baseline/` | AWS-account-wide guardrails (CloudTrail, Security Hub, GuardDuty, IAM Access Analyzer) |
| [`docs/adr/`](docs/adr/) | Architecture Decision Records — the load-bearing technical decisions, why they were made, and the trade-offs |
| [`docs/lessons-from-smoke-test.md`](docs/lessons-from-smoke-test.md) | Post-mortem of running this guide's Terraform against real EKS — what broke, why, and the five fixes that became Tier-1 defaults |
| `docs/superpowers/{specs,plans}/` | The design + implementation methodology used to build this guide |
| `.github/workflows/` | `docs` (builds + deploys the site, validates every mermaid block) + `example-trees-check` (Helm/Kustomize counts, Terraform fmt+validate, leak-scan) + `link-check` (external URL rot) |

## How to read it

- **Online (recommended):** <https://abd-ulbasit.github.io/bookstore-kubernetes-guide/>
- **In Obsidian / your editor:** clone the repo and open `full-guide/`
- **Locally as a site:** `pip install -r requirements.txt && mkdocs serve`

## How to run the examples

Each chapter's hands-on section gives the exact commands. The two starting
points:

- **Local cluster (Parts 00–11):** `kind create cluster` or `k3d cluster create`
- **Live AWS (Part 14):** `cd full-guide/examples/bookstore-platform/terraform && terraform init && terraform apply`
  (costs **~$0.20/hour**, every dollar-bearing variable defaults to off; full
  teardown documented in `terraform/cleanup-pre-destroy.sh`)

## Quality gates

Every commit to `main` runs:

- `mkdocs build --strict` — no broken internal links, no missing nav refs
- **`mermaid.parse()` against every diagram** — catches "Syntax error in text"
  before the site deploys (using the same parser version production renders with)
- Helm/Kustomize/Terraform shape checks + leak-scan (nightly + on PR)
- External link-check (weekly)

## License

MIT — see [`LICENSE`](LICENSE). Both the prose and the example code are MIT.

## Built with

This guide was built using the [Claude Code](https://claude.com/claude-code)
Superpowers skill set: multi-agent spec → plan → implement → review cycles
with continuous quality gates. The design docs and plans live under
`docs/superpowers/` if you want to see how the pipeline worked.
