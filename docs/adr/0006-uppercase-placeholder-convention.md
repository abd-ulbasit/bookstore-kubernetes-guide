# 0006 — `<UPPERCASE>` for every configurable value

* **Status:** Accepted
* **Date:** 2026-05-19
* **Deciders:** abd-ulbasit

## Context

Hands-on examples contain values the reader must substitute: account
IDs, region names, hostnames, image registries, secret keys, S3 bucket
names. There are several conventions in the wild:

* `your-account-id-here`
* `123456789012`
* `${ACCOUNT_ID}`
* `# REPLACE ME`
* `<ACCOUNT-ID>`

Each has failure modes. Plausible-looking dummy values (`123456789012`)
get copy-pasted into production by accident. Shell-variable syntax
(`${ACCOUNT_ID}`) is real syntax in YAML+kustomize and gets evaluated
when the reader didn't intend it. Comment-only markers (`# REPLACE ME`)
are easy to miss in a 200-line manifest.

A consistent visual marker matters: if the reader sees the *same shape*
every time, their eye learns to find substitutions.

## Decision

We will use **`<UPPERCASE-WITH-DASHES>`** as the universal placeholder
shape across the guide and every example tree:

* `<AWS-ACCOUNT-ID>` not `123456789012`
* `<REGION>` not `us-east-1`
* `<REGISTRY-URL>` not `myregistry.example.com`
* `<KEYCLOAK-CLIENT-SECRET>` not `s3cr3t`

Nothing in CI enforces the convention mechanically (see *Corrections*
below); it is a review-time rule. **Real HTML tags** (lowercase like
`<br/>`, `<details>`) and **heredoc markers** (`<<EOF`, `<<-EOF`) are the
legitimate language-level uses of the same character and are not
placeholders.

## Consequences

* **Good:** A grep for `<[A-Z]` in any manifest yields every value the
  reader must substitute. The reader's substitution discipline becomes
  mechanical.
* **Good:** It's syntactically *invalid* in YAML/HCL/JSON — manifests
  with `<UPPERCASE>` placeholders refuse to apply, which is the right
  failure mode (loud).
* **Bad:** Some tools (older `kubectl apply -f`) emit confusing errors
  on unresolved `<…>` instead of "this looks like a placeholder."
  Worth it.
* **Bad:** Two exemptions (real lowercase HTML, `<<EOF`) need to be
  remembered when reviewing diffs.
* **Follow-up:** A pre-commit hook that catches accidental real-value
  leaks (e.g. an actual 12-digit account ID slipping in) would be a
  worthwhile next step.

## Alternatives considered

* **Plausible dummy values** (`123456789012`, `acme.io`). Get
  copy-pasted into production. Rejected.
* **Shell-variable interpolation** (`${ACCOUNT_ID}`). Real syntax in
  several formats — evaluates when not intended. Rejected.
* **Comment markers only** (`# REPLACE ME`). Easy to miss. Rejected.

## References

* `full-guide/appendix/B-glossary.md` — the placeholder convention.
* `.github/workflows/secret-scan.yml` — gitleaks over the full history.
* `.github/workflows/example-trees-check.yml` — `host-path-scan` job.

## Corrections

* **2026-10-24.** This ADR used to say the CI `leak-scan` job grepped for
  domain-shaped values, 12-digit account IDs and known-real emails. It
  never did: it grepped `full-guide/` for five fixed strings (a home
  directory prefix, a container-runtime path, two identifiers and a
  phrase). That job is now `host-path-scan` (workstation traces only) and
  real secret scanning is gitleaks in `secret-scan.yml`. Neither checks
  account-ID-shaped numbers; the pre-commit follow-up above still stands.
