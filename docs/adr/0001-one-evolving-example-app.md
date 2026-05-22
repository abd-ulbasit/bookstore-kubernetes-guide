# 0001 — One evolving Bookstore example across all chapters

* **Status:** Accepted
* **Date:** 2026-05-19
* **Deciders:** abd-ulbasit

## Context

Most Kubernetes books restart their example per topic. Chapter 3's
Deployment is a Redis. Chapter 5's StatefulSet is a Postgres. Chapter 9's
Ingress is a never-mentioned-again Nginx. The reader keeps re-introducing
themselves to *unrelated* apps just so each primitive can be demonstrated
in isolation. The consequence: primitives feel like a *checklist of toys*
rather than a system that *grows*. By chapter 30 the reader has built no
real intuition for how Pods, Services, RBAC, ingress, sidecars, and
storage compound into a working production application.

A second consequence: example sprawl. Different examples mean different
images, different namespaces, different cluster-state assumptions. Every
chapter ends up with its own "first, set up X" preamble, which is the
opposite of the *concepts compound* discipline this guide is trying to
teach.

## Decision

We will use **one** worked example application — *Bookstore* — that
evolves continuously across all 16 Parts. Every primitive is introduced
because the Bookstore needs it next, then applied to the Bookstore
immediately. The four example trees (`bookstore/`, `bookstore-platform/`,
`bookstore-platform/terraform/`, `terraform-account-baseline/`) are
versions of the same application at different points along the
zero-to-multi-region-production arc.

## Consequences

* **Good:** A chapter's hands-on output is the *input* of the next
  chapter. The reader's mental model accretes instead of resetting.
* **Good:** Cross-chapter links are real ("the Postgres StatefulSet you
  built in ch.05 — we're about to put a Secret behind it"), not
  decorative.
* **Bad:** Editorial dependency cost: a refactor in ch.03 can ripple to
  ch.20. We mitigate this with [ADR 0007](0007-helm-kustomize-render-counts-as-invariants.md)
  (hard CI invariants on manifest counts).
* **Bad:** Bookstore-specific terminology shows up in primitive
  explanations. Acceptable trade-off — the guide is opinionated on this.
* **Follow-up:** If the guide ever grows past 16 Parts, we'll need a
  decision on whether Bookstore v3 is one app or whether the guide forks
  the example.

## Alternatives considered

* **One example per Part.** Less editorial coupling, but loses the
  through-line. Rejected.
* **Two parallel examples (a "simple" + a "complex").** Reader has to
  swap context mid-chapter. Rejected.

## References

* `docs/superpowers/specs/2026-05-19-kubernetes-comprehensive-guide-design.md`
* `full-guide/README.md` — the guide's home page describes this through-line.
