# Security Policy

## Supported versions

This project's "released" surface is the live site
<https://abd-ulbasit.github.io/bookstore-kubernetes-guide/> built from
`main`. Older versions of chapters are not separately supported — content
issues are always fixed against `main`.

## Reporting a vulnerability

If you've found something that should not be public, **please don't open a
GitHub issue**. Use one of these private channels instead:

1. **GitHub Private Vulnerability Reporting** —
   [open a private report](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/security/advisories/new)
   on this repo. This is the preferred path; it gives us a structured place
   to track fixes and coordinate disclosure.
2. **Direct email** to the maintainer (address in the GitHub profile).

Either way, please include:

- A clear description of the issue and its impact.
- Steps to reproduce (commands, file paths, line numbers).
- Whether the issue affects the live site, the example trees, the CI
  workflows, or all three.

## What counts as a security issue here

This is a documentation + example-code repo, so the surface is a little
unusual. We treat these as security issues:

- **Real secrets accidentally committed to history** — API keys, tokens,
  certificates, account IDs, anything an attacker could use.
- **Vulnerable patterns documented as best practice** — example code that,
  if copied as-is to production, would create a real exposure (e.g.
  permissive IAM policies, default-allow NetworkPolicies, plaintext Secrets
  without KMS, public S3 buckets).
- **CI workflow injection / privilege issues** — anything in
  `.github/workflows/` that an external contributor could exploit via a
  PR to run code in the repo's context.
- **Example-tree manifests that materially weaken cluster posture** — a
  `restricted` PSA exemption added without justification, a privileged
  container that doesn't need to be, a missing `runAsNonRoot`.

What we *don't* treat as a security issue:

- Educational content that intentionally shows an *anti-pattern* so the
  reader learns what *not* to do (these are always labelled as such).
- Findings against the upstream Kubernetes / AWS / Terraform projects
  themselves — please report those to the relevant upstream.

## Response

We aim to acknowledge a report within **72 hours** and to have an initial
assessment within **7 days**. Fix timelines depend on severity.

For coordinated disclosure: once a fix is merged, the issue will be
acknowledged in [`CHANGELOG.md`](CHANGELOG.md) under the relevant version's
`### Security` section. Credit goes to the reporter unless requested
otherwise.

## Scope notes

- The CI `leak-scan` job at
  [`.github/workflows/example-trees-check.yml`](.github/workflows/example-trees-check.yml)
  greps every guide file for machine paths, real-shaped account IDs, and
  known email/handle patterns. If you find a leak this job missed, that's
  itself a useful finding — please report.
- The Terraform tree at
  `full-guide/examples/bookstore-platform/terraform/` was applied to a
  real AWS account once (smoke test, 2026-05-20) for ~$0.20. The account
  was a sandbox, not production; no real customer data ever touched it.
  Findings about that smoke test live in
  [`docs/lessons-from-smoke-test.md`](docs/lessons-from-smoke-test.md).
