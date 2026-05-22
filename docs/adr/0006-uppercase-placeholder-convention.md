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

The leak-scan job in CI greps for any value matching `[a-z]\.[a-z]`
domains, real account-ID-shaped 12-digit numbers, and known-real
emails/usernames in `full-guide/` content. **Real HTML tags** (lowercase
like `<br/>`, `<details>`) and **heredoc markers** (`<<EOF`, `<<-EOF`)
are explicitly exempted — they're the legitimate language-level uses of
the same character.

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
  remembered when reviewing diffs. The leak-scan regex handles both.
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
* `.github/workflows/example-trees-check.yml` — `leak-scan` job.
