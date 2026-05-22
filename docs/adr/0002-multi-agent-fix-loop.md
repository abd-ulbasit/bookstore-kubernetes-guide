# 0002 — Multi-agent spec → plan → implement → review pipeline

* **Status:** Accepted
* **Date:** 2026-05-19
* **Deciders:** abd-ulbasit

## Context

A 115-chapter guide with four runnable example trees is, in software
terms, a fairly large repository. Built linearly by a single hand it
would have suffered the usual problems: late chapters drift from early
chapters, invariants quietly relax, and quality declines as fatigue sets
in. We needed a build methodology that could produce a 100-chapter
artifact while keeping the discipline at chapter 100 indistinguishable
from chapter 1.

## Decision

We will use a **multi-agent dispatch pipeline** for every phase of the
build, with strict role separation:

* **Spec** — the human author defines the deliverable shape, the
  invariants to preserve, and the surface to deepen vs. duplicate.
* **Plan** — a spec-bound planning subagent decomposes the spec into
  bite-sized tasks and writes the implementation plan.
* **Implementer** — a fresh subagent (no inherited context) implements
  each task, committing test-first when applicable.
* **Spec reviewer** — verifies the implementation matches the spec, not
  more, not less.
* **Code-quality reviewer** — independent senior-engineer pass on the
  same diff: clarity, edge cases, idiom, security.
* **Fix-loop** — implementer addresses reviewer findings; reviewers
  re-review until both approve.

Specs live under `docs/superpowers/specs/`, plans under
`docs/superpowers/plans/`. Every Part of the guide was produced by one
or more dispatches of this pipeline.

## Consequences

* **Good:** Every chapter passes two independent reviews before merge.
  Quality at ch.100 mirrors quality at ch.1.
* **Good:** Subagents are stateless per-task, so failures or drifts don't
  cross-contaminate. The pipeline is observable and rerunnable.
* **Good:** The spec/plan trail is itself useful documentation — a
  hiring or contributing reader can see *how* the artifact was built.
* **Bad:** Higher token + time cost than a single-agent build. The
  trade is structural quality vs. raw throughput.
* **Bad:** Spec quality is the bottleneck. A weak spec produces weak
  output regardless of how rigorous the reviewers are.
* **Follow-up:** The pipeline is documented but not yet generalised as
  a reusable tool. If we build a second large guide, extracting the
  pipeline into a separate repo would be worth it.

## Alternatives considered

* **Single-agent linear write.** Faster, but quality drift is
  inevitable past ~30 chapters.
* **Pair-agent (implementer + one reviewer).** Loses the spec-compliance
  vs. code-quality separation; reviewers end up doing both jobs
  half-well.

## References

* `docs/superpowers/specs/` — every Part has a spec doc.
* `docs/superpowers/plans/` — paired implementation plans.
