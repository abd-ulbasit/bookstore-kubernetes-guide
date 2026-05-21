# Bookstore Platform v2 — Grand Capstone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Spec: `docs/superpowers/specs/2026-05-20-bookstore-platform-v2-design.md`.

**Goal:** Restructure 09-end-to-end-bookstore → 09-end-to-end-bookstore, then build Part 13 (Grand Capstone — Bookstore Platform v2) as a 12-chapter production-shape reference implementation.

**Architecture:** Same proven pipeline (opus implementer → sonnet spec-review → sonnet code-quality-review → fix-loop). Continuous; no user check-ins. Each sub-phase ships its own chapters + extends `examples/bookstore-platform/`.

**Tech Stack (across Part 13):** Crossplane v2 + Backstage + Keycloak + Istio Ambient + Coraza WAF + Meilisearch + Debezium + Strimzi Kafka + Stripe sandbox + KServe + MLflow + Alibi-Detect + OpenTelemetry + Tempo + Loki + Prometheus + Grafana + OpenCost + ApplicationSet + Chaos Mesh + CloudNativePG.

---

## Phase R — Restructure (small, foundational)

**Files touched:** every `.md` referencing `09-end-to-end-bookstore/`, the directory itself, the spec/plan docs.

- [ ] R.1: `git mv full-guide/09-end-to-end-bookstore full-guide/09-end-to-end-bookstore` (no git here — use `mv`).
- [ ] R.2: Update `full-guide/README.md` TOC line for Part 09 (name + 1-line summary).
- [ ] R.3: Update `full-guide/appendix/{A-kubectl-cheatsheet,B-glossary,C-yaml-and-api-conventions,D-further-reading,E-learning-paths}.md` where they reference Part 09.
- [ ] R.4: For each `.md` file under `full-guide/{00..12}-*/` and `full-guide/examples/bookstore/**/*.md`, find every `09-end-to-end-bookstore/` reference (relative path, may also appear as `../09-end-to-end-bookstore/` etc.) and update to `09-end-to-end-bookstore/`.
- [ ] R.5: For each `.md` file INSIDE `09-end-to-end-bookstore/`, soften self-references "this capstone" → "this end-to-end walkthrough" or "this Bookstore v1 walkthrough" (≤ 5 places; keep H1 if it contains "capstone" — the H1 disambiguates by context once Part 13 lands).
- [ ] R.6: Update `docs/superpowers/specs/2026-05-19-kubernetes-comprehensive-guide-design.md` and `plans/2026-05-19-kubernetes-comprehensive-guide.md` where they reference `09-end-to-end-bookstore/`.
- [ ] R.7: Re-prove hard invariants: `helm lint`, helm template (49), `kubectl kustomize` overlays (45/49/48), DB_DSN unique, mermaid valid, link graph 0 broken.

---

## Phase 13a — Foundations (ch.01-04 + scaffold)

Same anatomy as existing chapters (Title + summary · Why · Mental model · Diagrams (Mermaid + ASCII) · Hands-on with the Bookstore Platform · How it works under the hood · Production notes · Quick Reference · Further reading).

### Task 13a.1 — Author 13.01 + 13.02 + 13.03 + 13.04
- [ ] Implementer opus dispatch: 4 chapters + scaffold `examples/bookstore-platform/{clusters,app,helm,kustomize,argocd,crossplane}/` skeleton + a minimal "Bookstore Platform v2 README" linking everything.
- [ ] Spec-review sonnet dispatch: independent verification of 9-section anatomy, content coverage, Mermaid validity, link resolution, PSA-restricted compliance, pinned-Helm installs, CRD-intrinsic notes.
- [ ] Code-quality-review sonnet dispatch: prose voice / depth / cohesion with the rest of the guide, YAML craft, no machine leaks, the v1 → v2 narrative actually lands.
- [ ] Fix-loop until both reviews APPROVED.

### Hard invariants Phase 13a must preserve
- Original Bookstore (`examples/bookstore/`) **untouched**.
- Helm 49 / Kustomize 45/49/48 / DB_DSN byte-identical.
- New `examples/bookstore-platform/` is a sibling tree, not a fork of `examples/bookstore/`.
- New ML pods (the recommender from 13.08 onwards) target a new ns `bookstore-platform-ml` (PSA `enforce: restricted`); per-tenant non-ML pods target `bookstore-platform-<TENANT>` (PSA `enforce: restricted`).
- System installs (Keycloak, ESO, Crossplane, Backstage, etc.) pinned Helm, own ns.
- CRD-backed manifests in `examples/bookstore-platform/**` carry the documented intrinsic note.

---

## Phase 13b — Capabilities (ch.05-08 + extend reference impl)

### Task 13b.1 — Author 13.05 + 13.06 + 13.07 + 13.08
- [ ] Implementer dispatch: 4 chapters + extend `examples/bookstore-platform/app/` with `search/`, `payments-gateway/`, `events/`, `recommendations/` services + the Stripe-webhook receiver + the Debezium connector + Meilisearch StatefulSet + Coraza WAF EnvoyFilter + Strimzi Kafka cluster + KServe + MLflow tracking server + Alibi-Detect drift detector.
- [ ] Spec-review + code-quality-review + fix-loop.

### Hard invariants Phase 13b must preserve
- Same as 13a, plus:
- Real Stripe sandbox key handling (use ESO or Sealed Secrets pattern; never bake the test key in plaintext outside a labeled illustrative comment).
- Outbox pattern actually works: the chapter must show the Postgres `events` table, the publisher worker, and the Kafka topic consistency (idempotent producer pattern).
- Coraza WAF rules actually load (the chapter's hands-on includes a working request and a blocked request with the rule that blocked it).
- KServe canary actually splits traffic (the chapter shows the % split and a curl loop hitting both versions).
- MLflow registry actually receives the model from the Argo Workflow `register` step (replaces the X3c ConfigMap stamp with a real registry call — the X3c stamp pattern is recalled honestly).

---

## Phase 13c — Operations (ch.09-12 + finalize reference impl)

### Task 13c.1 — Author 13.09 + 13.10 + 13.11 + 13.12
- [ ] Implementer dispatch: 4 chapters + extend `examples/bookstore-platform/` with `observability/` (OTel Collector DaemonSet + Tempo + Loki + Prom + Grafana dashboards JSON) + `cost/` (OpenCost) + `backstage/` (scaffolder template + catalog-info.yaml + mkdocs config) + `runbooks/` (runbook.md + on-call.md + dr-drill.md + chaos-gameday.md).
- [ ] Spec-review + code-quality-review + fix-loop.

### Hard invariants Phase 13c must preserve
- End-to-end OTel trace actually traverses storefront → catalog → orders → payments → outbox → events → recommendations (chapter shows the trace in Tempo with span names matching the service names).
- OpenCost dashboards show real per-tenant data (chapter explains how the labels flow through; if the local-kind data is illustrative, marks it).
- Backstage scaffolder template actually generates a working scaffold (the chapter's hands-on lists the generated files and walks one through).
- Runbook is a real runbook — page-able, ordered diagnostics, links to dashboards, escalation steps.

---

## Phase 13d — Finalize (README TOC + appendix B/D + consistency pass)

### Task 13d.1 — Mechanical finalization
- [ ] Append Part 13 TOC section to `README.md` in the established style (Part heading + 12 chapter lines).
- [ ] Append ~30 new glossary terms to `appendix/B-glossary.md` (Keycloak, OIDC, IRSA-deepened, JWKS, Meilisearch, Debezium, CDC, Outbox pattern, Saga compensation, Coraza, WAF, ModSecurity, OpenTelemetry, OTel Collector, Tempo, Loki, MLflow, Alibi-Detect, OpenCost, FinOps Foundation, Backstage scaffolder, Software Catalog, tech docs, golden path, paved road, runbook, DR drill, chaos game-day, ApplicationSet generators, Strimzi).
- [ ] Append Part 13 to `appendix/D-further-reading.md` with: official docs URLs (Keycloak, Crossplane, Backstage, KServe, MLflow, Alibi-Detect, OpenCost, OpenTelemetry, Coraza, Meilisearch, Strimzi, Debezium) + book secondaries (Rosso PK Day-2 + Multi-region + Cost; Ibryam KP2e Event Sourcing + Saga) + 3-5 standout articles (Google SRE Book ch.14, FinOps Foundation phases, the Backstage adoption case study, the Spotify scaffolder talk).
- [ ] Run the 14-check guide-wide consistency pass (helm 49 / kustomize 45/49/48 / DB_DSN / mermaid validity / 9-anatomy / leak scan / link graph / pinned-Helm / overlays/prod caveat / bootstrap chain / PSA-restricted / CRD-intrinsic / Go vet / Docker build).

---

## Phase 13e — Final independent audit

### Task 13e.1 — Audit
- [ ] Dispatch independent audit subagent (opus) with the full mandate:
  - Concern resolution ledger: every Phase 13 reviewer concern verified in live files.
  - Hard invariants re-proven independently (run every consistency-pass command, not just trust prior reports).
  - Spot-check 5 random Part 13 chapters for anatomy + voice + links + Mermaid validity.
  - Verify the v1 → v2 narrative threads (read the 13.01 brief and the 13.12 day-2 ending; do they bookend honestly?).
  - SHIP_IT | SHIP_WITH_NOTES | DO_NOT_SHIP verdict with reasoning.
- [ ] If audit returns SHIP_WITH_NOTES with actionable findings: dispatch a final fix-loop. Then re-audit. Loop until SHIP_IT.

---

## Acceptance for the entire Part 13 build
- Phase R passes hard-invariant re-proof.
- Phases 13a/b/c each have all 12 chapters spec-reviewed + code-quality-reviewed + fix-loop closed.
- Phase 13d passes the 14-check consistency pass.
- Phase 13e final audit returns SHIP_IT (or SHIP_WITH_NOTES with notes the user accepts).
- Final report to user.
