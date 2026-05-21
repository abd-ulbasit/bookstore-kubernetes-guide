# Bookstore Platform v2 — Grand Capstone Design

> **Delta-spec** building on the comprehensive Kubernetes guide design
> (`2026-05-19-kubernetes-comprehensive-guide-design.md`) and the extension
> design (`2026-05-19-kubernetes-guide-extension-design.md`). Both remain
> in effect; this spec adds **Part 13** and **restructures Part 09**.

## The problem

The original guide (Parts 00-09) closed with `09-end-to-end-bookstore/` — appropriate as
the cap to Parts 00-09. The extension added Parts 10/11/12 strictly
additively, leaving `09-end-to-end-bookstore/` structurally mid-guide ("capstone" no
longer caps). Two things have to happen:

1. **Reposition** the original capstone to remove the "this is the end"
   implication.
2. **Add a real, larger capstone** that ties EVERY Part together with a
   production-shape project — not another toy threadable through chapters,
   but the genuine multi-tenant, multi-region, ML-powered platform a
   real-world team would build.

## What we are NOT doing

- We are **not** rewriting the original Bookstore. It stays exactly as it is
  (49-object app, Helm/Kustomize/Argo CD, `examples/bookstore/`). The
  platform v2 is a **separate** worked reference (`examples/bookstore-platform/`).
- We are **not** changing the chapter anatomy, the hard invariants, or the
  build methodology. Same 9-section anatomy, same review pipeline, same
  PSA-restricted / Helm-pinned / CRD-intrinsic-note discipline, same Mermaid
  rules.
- We are **not** replacing any existing chapter content. Part 09's chapters
  stay byte-identical; only the **directory name** changes, plus every
  cross-link to it (mechanical update) and any **prose self-reference** as
  "this capstone" softened to "this end-to-end walkthrough" (small, scoped).
- We are **not** branching the guide. Part 13 is additive on top of the
  finished Parts 00-12.

## Restructure (Phase R, small)

- **Rename:** `full-guide/09-end-to-end-bookstore/` → `full-guide/09-end-to-end-bookstore/`.
  This name is descriptive (what the directory actually does: brings the
  original Bookstore up end-to-end across Parts 00-09) without claiming to
  be THE capstone.
- **Cross-link updates** in: `README.md`, every chapter under Parts 00-12,
  `appendix/A-D-*.md`, the `docs/superpowers/specs/` + `plans/` docs that
  reference Part 09, and the `examples/bookstore/**` trees where chapter
  cross-refs exist (rare but real).
- **Prose self-references** inside the renamed directory's chapters: where
  the prose says "this capstone" it becomes "this end-to-end walkthrough" or
  "this Bookstore v1 walkthrough", soft enough to preserve the meaning
  without falsely claiming finality. Documented exceptions only where the
  word "capstone" is in the chapter's H1 (rare; we keep that and let the
  context disambiguate via Part 13's H1s).
- **No content changes** beyond the rename, link updates, and ≤5 word
  prose softenings.
- **Hard invariants re-proven** after the rename (helm 49 / kustomize
  45/49/48 / DB_DSN identical / Mermaid valid / no broken links).

## Part 13 — "Grand Capstone: Bookstore Platform v2" (12 chapters)

### Threading the example

The platform v2 lives at `full-guide/examples/bookstore-platform/`. It is
**not** a refactor of `examples/bookstore/`; it is a sibling reference
implementation, deliberately separate so:
- The original Bookstore stays available as the small, threadable example
  for Parts 00-12 (the hard invariants 49/45/49/48 stay).
- The platform v2 can be much larger without breaking those counts.
- Readers can compare the v1 and v2 side-by-side.

Concretely, `examples/bookstore-platform/` contains its own:
- `app/` — extended services (the v1 four + new: `auth/`, `search/`,
  `payments-gateway/`, `recommendations/` (KServe), `events/` (Kafka
  consumers), `tenant-controller/` (Crossplane + Backstage scaffolder hooks)).
- `clusters/` — multi-region cluster definitions (kind-based for local
  reproduction; documented cloud equivalents).
- `helm/` and `kustomize/` (tenant-templated).
- `argocd/` — ApplicationSet per region.
- `crossplane/` — XRDs + Compositions for "create a tenant".
- `backstage/` — scaffolder template + tech-docs config.
- `runbooks/` — day-2 runbooks and game-day scripts.

### Chapter list (delta from extension design)

Each chapter follows the established 9-section anatomy (Title +
one-line summary · Why · Mental model · Diagrams (Mermaid + ASCII) ·
Hands-on with the Bookstore Platform · How it works under the hood ·
Production notes · Quick Reference · Further reading). Hands-on uses
`examples/bookstore-platform/` paths.

- **13.01 — Bookstore 2.0: from toy to platform.** The brief: gap analysis
  between v1 and v2 (single-tenant → multi-tenant; single-region →
  multi-region active-active; toy auth → real OIDC + IRSA; toy payments →
  real outbox + Stripe sandbox; rule-based recommender → real ML loop).
  The target architecture. The reading order. What "production-shape" means
  in this context (PSA-restricted carried; signed-images via cosign;
  per-tenant cost; SLOs that actually trigger). Cites: Rosso PK *Cluster
  Patterns* + Ibryam KP2e *Service Discovery / Sidecar*.

- **13.02 — Tenancy model and onboarding via Crossplane.** A bookstore
  owner is a "tenant" — concretely: a namespace + Kueue queue + per-tenant
  Postgres logical DB + per-tenant S3 bucket + IRSA role + Argo Workflow
  scaffold. Crossplane Composition `BookstoreTenant` (deliberately the
  same name as Part 11 ch.02's operator example, with the chapter making
  the operator-vs-Composition tradeoff explicit). Backstage scaffolder
  hook for the developer UX. Tenant deletion semantics (the deliberate-leak
  pattern from Part 11 ch.02 reused honestly). Cites: Crossplane v2 docs +
  Backstage scaffolder docs.

- **13.03 — Multi-region active-active.** Three regions (us-east, eu-west,
  ap-southeast — kind-simulated locally with 2-3 worker nodes per kind
  cluster (laptop-friendly default = 2; real cloud parity = 3); cloud
  equivalents documented). CloudNativePG cross-region replicas with
  read-routing per region. Argo CD ApplicationSet over a Cluster
  generator. Latency-based DNS at the edge. Failure modes: split-brain,
  asymmetric latency, region-loss failover. The DR drill (10-minute
  scripted). Cites: KP2e *Stateful Service* + CloudNativePG docs +
  DNS-failover patterns.

- **13.04 — Real auth: Keycloak OIDC + IRSA + Istio JWT validation.** Replace
  the toy JWT in v1 with Keycloak: realm-per-tenant; client + role mapping;
  Istio EnvoyFilter or RequestAuthentication for JWT validation at the
  ingress; ServiceAccount → IAM via IRSA for cloud-side calls. The "OIDC
  for humans, IRSA for workloads" split. Token-rotation, refresh, JWKS
  caching. Cites: Keycloak docs + Istio security docs + AWS IRSA blog.

- **13.05 — Search and product discovery.** Meilisearch (or OpenSearch
  — chapter picks one and documents the other) on K8s. Postgres → search
  index via Debezium CDC (the outbox-pattern foundation from 13.06).
  Relevance tuning. Per-tenant index isolation. Cross-region replication
  strategy. Cites: Meilisearch K8s docs + Debezium docs + Ibryam KP2e *Event
  Sourcing*.

- **13.06 — Payments and event sourcing.** Stripe sandbox integration; the
  outbox pattern (Postgres `events` table + a publisher worker → Kafka);
  the idempotent payments-worker (replaces v1's RabbitMQ-only path —
  RabbitMQ stays in v1; v2 moves to Kafka for replayability). Webhook
  receiver (signed Stripe webhooks). Reconciliation job. Saga compensation.
  Cites: Ibryam KP2e *Event Sourcing* + Stripe webhook docs + Strimzi
  Kafka operator.

- **13.07 — Edge: Istio Gateway + Coraza WAF + per-tenant rate limiting.**
  Gateway API at the edge. Coraza WAF (ModSecurity-compatible) deployed
  as an EnvoyFilter or Istio AuthorizationPolicy chain. Per-tenant rate
  limit via Envoy local rate limiter or rate-limit service. Cross-region
  edge identity (same JWT, different region affinity). Bot detection.
  Cites: Istio Gateway API docs + Coraza docs + Envoy rate-limit docs.

- **13.08 — Real ML loop: training → registry → serving → drift → retrain.**
  This is the chapter that closes the recommendations subthread to its
  fullest extent. Argo Workflows nightly retrain (X3c, deepened); MLflow
  tracking + registry (introduced honestly — the X3c stamp ConfigMap was
  the kind-runnable proxy); KServe with serverless mode + traffic-split
  model canary (X3b ch.06 deepened); Alibi-Detect drift detection + an
  Argo Events EventSource that triggers retrain on drift breach. Cites:
  KServe + MLflow + Alibi-Detect docs + Google MLOps article.

- **13.09 — Observability: OpenTelemetry traces + Loki logs + Prometheus
  metrics + Grafana dashboards + alerts.** Replace per-app logging with
  OpenTelemetry SDK in each app + OTel Collector DaemonSet → Tempo
  (traces) + Loki (logs) + Prometheus (metrics, deepening Part 06).
  Per-tenant Grafana dashboards (Grafana org-per-tenant or
  variable-driven). Alertmanager routing by tenant + region + severity.
  The full request flow (storefront → Istio gateway → catalog → orders →
  payments → Stripe webhook → outbox → events → recommendations) traced
  end-to-end. Cites: OpenTelemetry docs + Grafana Tempo/Loki/Prometheus.

- **13.10 — Cost: OpenCost per-tenant, per-cluster, per-region.** OpenCost
  install (pinned Helm, dedicated ns). Namespace = tenant = cost center
  (Part 08 ch.04 deepened). Per-tenant showback dashboard. Budget alerts
  via Alertmanager. The right unit-of-cost reporting at the platform-team
  level (per-region, per-cluster, per-workload-class — training vs
  inference vs storefront). Honest about cloud-billing-source-of-truth
  reconciliation. Cites: OpenCost docs + FinOps Foundation framework.

- **13.11 — Developer portal: Backstage scaffolder + service catalog +
  tech docs.** Backstage as the developer's entry-point. Scaffolder
  template creates a new microservice from a golden path (skeleton repo
  + Helm chart + Argo CD Application + on-call rotation registration).
  Software catalog seeded from the Argo CD Application list + Crossplane
  XRs. Tech docs from the bookstore-platform repo via the `mkdocs`
  technique. Cites: Backstage docs + the Spotify "Backstage Adoption"
  case study + Crossplane v2 Backstage integration.

- **13.12 — Day 2: runbook + on-call + DR drill + chaos drill + game-day.**
  The most-grown-up chapter. A real runbook (the page an on-call engineer
  opens at 3am). An on-call playbook (rotations, escalation, postmortem
  template). The 30-minute DR drill (region failure, scripted; what
  recovers automatically, what requires human action). A monthly chaos
  game-day script (Chaos Mesh fault scenarios run against `bookstore-platform`,
  not the v1 Bookstore — the v2 has redundancy that the v1 does not).
  Postmortem culture. Cites: Rosso PK *Day 2 Operations* + Google SRE
  Book chapter 14 (Managing Incidents) + the Chaos Mesh game-day pattern.

## Hard invariants Part 13 must preserve

- Original 50-chapter invariants intact: Helm 49 / Kustomize 45/49/48 /
  DB_DSN byte-identical / 9-section anatomy / Mermaid valid /
  PSA-restricted enforced / bootstrap chain in v1 Bookstore hands-on /
  CRD-intrinsic note pattern / Helm-pinned installs / no machine leaks.
- New `examples/bookstore-platform/` does NOT touch any file in
  `examples/bookstore/`. It is a separate sibling tree.
- New chapters use the same 9-section anatomy.
- Mermaid same rules; ASCII diagrams used for matrices/tables where the
  Mermaid would be redundant.
- All system installs (Keycloak, Meilisearch, Strimzi, Stripe webhook
  receiver, OpenTelemetry, Tempo, Loki, OpenCost, Backstage) via pinned
  Helm + own namespaces.
- All CRD-backed manifests carry the "no matches for kind X until CRDs
  installed" header (precedent across the guide).
- ML pods land in `bookstore-platform-ml` ns (PSA `enforce: restricted`),
  mirroring the X3a/b/c pattern; non-ML pods land in
  `bookstore-platform-<TENANT>` namespaces (PSA `enforce: restricted` per
  tenant).
- No fabricated metrics, costs, or training numbers. Where the chapter
  needs to show a number, it's a labeled illustrative value or a real
  reproducible local one.

## Build methodology

Same as the extension: each sub-phase is opus implementer → sonnet
spec-review → sonnet code-quality-review → fix-loop. Continuous, no
user check-ins, per user mandate. The user invokes interruption only.

## Acceptance

- Phase R: 09 directory renamed, ≤ 40 cross-links updated, prose
  self-references softened ≤ 5 places, hard invariants re-proven.
- Phase 13a-c: each of 12 chapters DONE + spec-reviewed + code-quality-
  reviewed + fix-loop closed. `examples/bookstore-platform/` reference
  implementation exists, kind-bootable end-to-end (or honestly marked
  where cloud is required).
- Phase 13d: README TOC for Part 13, appendix B (~30 new terms),
  appendix D (Part 13 further reading), guide-wide consistency re-proof
  (helm/kustomize counts + link graph + mermaid valid + no leaks).
- Phase 13e: independent audit verifies every reviewer concern of Phase
  13 was fixed in the live files; hard invariants re-proven; SHIP_IT
  verdict.
