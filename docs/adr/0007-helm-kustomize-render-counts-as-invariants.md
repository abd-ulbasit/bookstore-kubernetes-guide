# 0007 — Helm 49 / Kustomize 45-49-48 as hard CI invariants

* **Status:** Accepted
* **Date:** 2026-05-19
* **Deciders:** abd-ulbasit

## Context

The Bookstore Helm chart and the three Kustomize overlays (dev, staging,
prod) are the most-referenced artifacts in the guide — chapter after
chapter says *"…and now the chart renders 49 objects, see
`helm template`."* If the count changes by accident (a templating bug,
a stray manifest, a `helm.sh/hook` that doesn't render under
`helm template`), every chapter that cites the number is silently wrong.

We needed a tripwire that catches this *before merge*, not after the
guide is published and a reader reports a mismatch.

## Decision

The following counts are **enforced as CI gates** in
`.github/workflows/example-trees-check.yml`:

| Tree | Count | Job |
|---|---|---|
| `helm/bookstore` | 49 distinct `kind:` after `helm template` | `helm-template-count` |
| `kustomize/overlays/dev` | 45 distinct `kind:` after `kubectl kustomize` | `kustomize-counts` |
| `kustomize/overlays/staging` | 49 | `kustomize-counts` |
| `kustomize/overlays/prod` | 48 | `kustomize-counts` |

A `helm lint` job additionally requires `0 chart(s) failed`. The counts
were established when the chart and overlays were first written and
are now considered the canonical surface; changing any of them is a
deliberate decision, not an accident.

## Consequences

* **Good:** A typo in a template that accidentally adds or drops a
  manifest is caught in CI, with a clear error message, before merge.
* **Good:** The guide's prose is now *audit-able* — every "49 objects"
  citation in the markdown is enforceable.
* **Good:** Refactors to the chart that *should* change the count
  (e.g. splitting one resource into two) become a deliberate decision
  + a CI value change in the same PR, instead of silent drift.
* **Bad:** Adding a legitimate new resource requires a coordinated
  edit to the CI file. Acceptable — additions to canonical artifacts
  *should* be deliberate.
* **Bad:** The counts are coupled to the current chart structure.
  A future major refactor will need to update both. Documented in the
  CI file's comments.
* **Follow-up:** Consider extending the invariant set to include
  per-overlay diff snapshots (golden files) for catastrophic regressions
  the count alone misses. Likely overkill — `helm lint` covers most.

## Alternatives considered

* **Snapshot golden files** for the rendered output of every overlay.
  More fragile (whitespace, ordering), more maintenance, marginal
  benefit over the count + lint combination. Considered, deferred.
* **Trust the writer.** What we had before. Rejected once the chart
  hit ~40 manifests — too many for human eyes.

## References

* `.github/workflows/example-trees-check.yml` — `helm-template-count`,
  `kustomize-counts`, `helm-lint` jobs.
* `full-guide/07-delivery/01-packaging-helm.md` (Helm count cited).
* `full-guide/07-delivery/02-packaging-kustomize.md` (overlay counts cited).
