# `backstage/` — Phase 13c

Phase 13a does not ship Backstage manifests. Phase 13c (ch.13.11) adds:

- Backstage Helm chart install (pinned).
- Scaffolder template for "create a new platform service" (golden path).
- Software catalog seeded from the Argo CD Application list + Crossplane
  XRs (each `BookstoreTenant` shows up as a catalog Component).
- TechDocs config (the platform repo's mkdocs source).
- `catalog-info.yaml` entries for the v1 + v2 services.

Cross-ref Part 11 ch.10 (platform engineering — Backstage introduced) for the
foundations; 13.11 is the deepening + the real scaffolder template.
