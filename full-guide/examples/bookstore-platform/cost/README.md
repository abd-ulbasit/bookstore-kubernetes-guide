# `cost/` — Phase 13c

Phase 13a does not ship cost manifests. Phase 13c (ch.13.10) adds:

- OpenCost install (pinned Helm, dedicated ns).
- Per-tenant cost label propagation (the ResourceQuota label flow already
  established in Part 08 ch.04, deepened).
- Grafana cost dashboards (per-tenant, per-region, per-workload-class).
- Budget alerts via Alertmanager.

Cross-ref Part 08 ch.04 (multi-tenancy + cost) and Part 10 ch.06 (cluster
autoscaling cost) for the foundations.
