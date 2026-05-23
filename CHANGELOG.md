# Changelog

All notable changes to this project will be documented in this file. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Real working `app/catalog/` Go service (Postgres-backed, instrumented,
  tested, benchmarked) — promotion from the Phase 16 stub.
- `BENCHMARKS.md` with k6 latency results against `catalog/`.

## [1.0.0] — 2026-05-23

First stable cut. The guide, the four example trees, and the build
discipline are all considered durable from this tag forward; subsequent
changes follow semver.

### Added
- **Parts 00–15 / 115 chapters** of the comprehensive zero-to-production
  Kubernetes guide, all anchored on one evolving Bookstore example.
- **Four example trees:**
  - `examples/bookstore/` — canonical, kind/k3d-local (Parts 02–08)
  - `examples/bookstore-platform/` — multi-tenant Platform v2 (Parts 12–13)
  - `examples/bookstore-platform/terraform/` — EKS infrastructure
    (live smoke-tested on EKS 1.35 in `ap-south-1`, ~$0.20 spend)
  - `examples/bookstore-platform/terraform-account-baseline/` —
    account-wide AWS guardrails
- **Phase 16 learning-experience improvements**: per-chapter learning
  metadata, self-assessment exercises with collapsible answers, Go
  service stubs, concept-map + tag-index appendix, MkDocs Material
  site, CI for example trees.
- **GitHub Pages deploy** at <https://abd-ulbasit.github.io/bookstore-kubernetes-guide/>
- **CI quality gates** on every push to `main`:
  - `mkdocs build --strict` (no broken internal links)
  - `mermaid.parse()` against every diagram (mermaid 10.9.1, same as
    production) — catches "Syntax error in text" before deploy
- **Nightly + PR-time CI** on the example trees:
  - `helm lint` and `helm template` count (49 manifests)
  - `kubectl kustomize` overlay counts (45/49/48 for dev/staging/prod)
  - `terraform fmt -check` + `terraform validate` on all three trees
  - `go vet` + `go build` on every Go service
  - Leak-scan for machine paths, real account IDs, real emails
- **Architecture Decision Records** (7) under `docs/adr/`
- **Smoke-test post-mortem** at `docs/lessons-from-smoke-test.md`
- **GitHub Codespaces** dev container at `.devcontainer/`

### Fixed (post-1.0 patch-style fixes that landed in the same week)
- 12 broken mermaid diagrams (`;` parsed as sequence-diagram statement
  terminator, parens in unquoted edge labels, `.` in dotted-edge labels,
  literal `\n` rendering as text).
- 8 misaligned ASCII diagrams (off-by-one box borders).
- Mobile rendering: thin scrollbar visible on overflowing code blocks
  at viewports < 768px (was invisible by default).
- CI `go-services` matrix: `fail-fast: false` + `go.mod` existence check
  so a placeholder service dir (`auth/`) doesn't cancel the other seven.

### Security
- No machine-specific paths, hardcoded account IDs, or real credentials
  in any guide content. Enforced by the `leak-scan` CI job.
- Restricted Pod Security by default everywhere; two documented
  privileged-namespace exceptions for Falco and the Cilium agent
  (see [ADR 0005](docs/adr/0005-restricted-psa-default-with-exceptions.md)).

[Unreleased]: https://github.com/abd-ulbasit/bookstore-kubernetes-guide/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/abd-ulbasit/bookstore-kubernetes-guide/releases/tag/v1.0.0
