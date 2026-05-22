# Architecture Decision Records

This directory captures the **load-bearing** technical decisions that shaped
the guide and the four example trees. Each ADR follows Michael Nygard's
classic format — **Status / Context / Decision / Consequences** — so the
*why* survives well after the conversation that produced it.

**When to write a new one?** When a decision will outlast the conversation it
came from, when reversing it would be expensive, or when a future reader
will inevitably ask *"why isn't this X?"* and we want a short answer to
point at.

## Index

| #    | Title | Status |
|------|-------|--------|
| [0001](0001-one-evolving-example-app.md) | One evolving Bookstore example across all chapters | Accepted |
| [0002](0002-multi-agent-fix-loop.md) | Multi-agent spec → plan → implement → review pipeline | Accepted |
| [0003](0003-mermaid-parse-validation-in-ci.md) | Real `mermaid.parse()` in CI over regex heuristics | Accepted |
| [0004](0004-s3-native-state-locking.md) | Native S3 state locking, not DynamoDB | Accepted |
| [0005](0005-restricted-psa-default-with-exceptions.md) | Restricted PSA everywhere, two documented privileged exceptions | Accepted |
| [0006](0006-uppercase-placeholder-convention.md) | `<UPPERCASE>` for every configurable value | Accepted |
| [0007](0007-helm-kustomize-render-counts-as-invariants.md) | Helm 49 / Kustomize 45-49-48 as hard CI invariants | Accepted |

## Format

Each ADR is short on purpose — long enough to ground a future decision,
short enough that a senior engineer reads all of them in 15 minutes. See
[`_template.md`](_template.md) for the boilerplate. The longer-form
design rationale lives in [`../superpowers/specs/`](../superpowers/specs/);
ADRs reference those when more detail is needed.

## Cross-reference

The build methodology that produced this guide (multi-agent
spec→plan→implement→review dispatch) is documented in [ADR 0002](0002-multi-agent-fix-loop.md);
the **live AWS smoke-test that surfaced the real bugs underlying several
of the decisions below** is documented in
[`../lessons-from-smoke-test.md`](../lessons-from-smoke-test.md).
