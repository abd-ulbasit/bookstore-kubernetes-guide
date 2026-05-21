# Phase 16 — Learning Experience Improvements Design

> **Delta-spec** building on Parts 00-15. Six discrete UX improvements to the existing 115-chapter guide. No new chapters; touches existing chapters + adds 2 appendix items + new tooling.

## The 6 deliverables (mapped from user-confirmed review)

1. **Per-chapter learning metadata** (touch all 115 chapters)
2. **Self-assessment exercises** (touch all 115 chapters)
3. ~~Full platform v2 smoke test~~ — DEFERRED (user does this themselves)
4. **Go service stubs** in `examples/bookstore-platform/app/{catalog,orders,payments-worker}/`
5. **Concept map + tag index** as new appendix
6. **MkDocs Material site** with GitHub Pages publishing
7. **CI pipeline** for example trees (nightly + on-PR)

## Canonical formats (every agent uses these)

### Format A — Metadata block (Phase 16-A)
Placement: between the H1 + summary blockquote and the first H2 (`## Why this exists`).

```markdown
# NN.NN — Chapter Title
> One-line summary in blockquote.

**Estimated time:** ~30 min read · ~60 min hands-on
**Prerequisites:** [Part XX ch.YY](../XX-slug/YY-slug.md) — one-phrase reason · [Part AA ch.BB](../AA-slug/BB-slug.md) — one-phrase reason
**You'll know after this:** • outcome 1 · • outcome 2 · • outcome 3 · • outcome 4 · • outcome 5

<!-- tags: tag1, tag2, tag3, tag4, tag5 -->

## Why this exists
…
```

Time estimates: round to 15-min granularity for read time (~15 / ~30 / ~45 / ~60 min); 30-min granularity for hands-on (~30 / ~60 / ~90 / ~120 / half-day).

Prereqs: 2-5 entries; cite specific Part/chapter when the dependency is concrete; "(none — foundational)" if standalone (early Part 00 chapters).

Learning outcomes: 3-5 bullets; each starts with a verb (understand, configure, debug, deploy, choose-between); concrete and testable.

Tags (HTML comment): 3-6 lowercase kebab-case tags from this taxonomy:
- **Topics**: networking, security, storage, scheduling, observability, autoscaling, gitops, helm, kustomize, multi-tenancy, multi-cluster, ml, cost, finops, ci-cd, supply-chain
- **Layers**: foundations, core-objects, cloud, platform-engineering, day-2
- **Tools**: argo-cd, argo-rollouts, karpenter, cilium, istio, vault, eso, opentelemetry, prometheus, falco, velero, crossplane, backstage, terraform, ebs-csi, cnpg, kserve
- **Concepts**: psa-restricted, irsa, slo, secrets-rotation, drift, dr, postmortem
- **Workloads**: stateful, batch, gpu, llm-serving

### Format B — Test your understanding (Phase 16-B)
New H2 between `## Quick Reference` and `## Further reading`.

```markdown
## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **Question text (conceptual).**
   <details><summary>Show answer</summary>

   Answer paragraph (1-3 sentences). Optionally reference a specific anchor: "see §How it works" or "the table at line 247".

   </details>

2. **Scenario question — "you observe X, what's happening and what would you do?"**
   <details><summary>Show answer</summary>

   Answer.

   </details>

3. **Hands-on extension — try this yourself, see what breaks.**
   <details><summary>What you should see</summary>

   Description of the expected behavior + the failure mode if step is skipped.

   </details>
```

3-5 questions per chapter. Mix: 1-2 conceptual (why/what), 1-2 scenario ("what would you do"), 1 hands-on extension. Capstone chapters (Part 12 ch.08, Part 13 ch.12, Part 14 ch.17, Part 15 ch.12) get 5-7 (broader synthesis).

### Format C — Go service stub (Phase 16-D)
Three new directories under `examples/bookstore-platform/app/{catalog,orders,payments-worker}/`. Each contains:

```
catalog/
├── main.go           # ~40 lines: HTTP server on :8080 with /healthz + / route; uses log/slog
├── go.mod            # module github.com/bookstore-platform/catalog; go 1.22
├── Dockerfile        # multi-stage: golang:1.22-alpine build → distroless final, non-root 65532
├── deployment.yaml   # restricted PSA Deployment + Service, image bookstore/catalog:dev
├── service.yaml
├── Makefile          # build / test / image targets
└── README.md         # what this is, why it's a stub, what production would add
```

The stubs satisfy the Part 13-15 chapter references that reference `app/catalog`, `app/orders`, `app/payments-worker`. They are tiny but real — `go build` clean, `docker build` clean, manifest dry-run clean.

### Format D — Concept map appendix (Phase 16-C)
New file: `full-guide/appendix/F-concept-map.md`.

- **Section 1 — The big picture**: one large Mermaid `graph LR` showing concept nodes and "X builds on Y" edges.
- **Section 2 — Tag index**: alphabetical list of every tag with its chapter members (auto-generatable from the `<!-- tags: ... -->` comments).
- **Section 3 — Topic-driven reading paths**: "I want to learn X" → ordered chapter list. Examples: "GitOps end-to-end", "Cost optimization", "Security top-to-bottom", "ML on K8s", "Day-2 ops".

### Format E — MkDocs Material site (Phase 16-E)
- `mkdocs.yml` — material theme, navigation.tabs+sections+expand, search, code highlighting, dark mode toggle
- `requirements.txt` — mkdocs-material + mkdocs-mermaid2-plugin + mkdocs-awesome-pages-plugin + mkdocs-git-revision-date-localized-plugin
- `.github/workflows/docs.yml` — build on push/PR to main, deploy to GitHub Pages on main
- `.pages` files in each Part directory for nav ordering (if needed; otherwise auto-derived from filenames)
- A `docs/index.md` symlink or copy of README.md as the landing page

### Format F — CI pipeline (Phase 16-F)
- `.github/workflows/example-trees-check.yml` — runs nightly (`cron: '0 3 * * *'`) + on PR to `examples/` paths
- Checks (each as a separate job for granular failure):
  1. `helm lint examples/bookstore/helm/bookstore` → 0 failed
  2. `helm template … | grep -c '^kind:'` → 49
  3. `kubectl kustomize examples/bookstore/kustomize/overlays/{dev,staging,prod}` → 45/49/48
  4. `terraform fmt -check + validate` on all 3 trees
  5. `go vet ./... && go build ./...` on each service in `examples/bookstore-platform/app/*/`
  6. Link-checker for relative .md links in `full-guide/`
  7. Mermaid block validator (the Python script from prior phases)
- On any failure: opens a single rolling GitHub issue labeled `nightly-check-failure` (dedup by label, comment with new failures rather than open new issues).

## Hard invariants (must NOT break)

- All 115 chapters' content stays semantically identical; only the front-matter block + the new H2 are added.
- 9-section anatomy → becomes 10-section (with "Test your understanding" inserted between Quick Ref and Further reading). The metadata block is BEFORE the first H2, doesn't count as a section. Capstones (12.08, 13.12, 14.17, 15.12) currently have 10-13 H2s; they'll have 11-14 after the addition.
- Helm 49 / Kustomize 45/49/48 / DB_DSN byte-identical / Terraform fmt+validate clean.
- Existing cross-refs continue to resolve.
- Mermaid blocks remain valid.
- No machine-specific leaks.
- The Go service stubs in `app/{catalog,orders,payments-worker}/` use the same restricted-PSA SC, distroless image, non-root UID 65532, multi-arch Dockerfile pattern as the existing services.

## Phase plan

| Wave | Phases (parallel) |
|------|-------------------|
| **Wave 1** | 16-A1 metadata Parts 00-04 · 16-A2 Parts 05-09 · 16-A3 Parts 10-13 · 16-A4 Parts 14-15 · 16-D Go stubs · 16-E MkDocs · 16-F CI pipeline |
| **Wave 2** | 16-B1 self-assess Parts 00-04 · 16-B2 Parts 05-09 · 16-B3 Parts 10-13 · 16-B4 Parts 14-15 · 16-C concept map (uses tags from Wave 1) |
| **Wave 3** | 16-G final consistency + SHIP_IT audit |

Each agent gets a compact prompt that references this spec by path for the canonical formats.
