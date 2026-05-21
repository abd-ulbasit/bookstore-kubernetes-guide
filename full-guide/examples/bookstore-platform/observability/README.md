# `observability/` — Phase 13c

Phase 13a does not ship observability manifests. Phase 13c (ch.13.09) adds:

- OpenTelemetry Collector (DaemonSet).
- Tempo (traces).
- Loki (logs).
- Prometheus + ServiceMonitors for the platform services.
- Grafana dashboards (JSON) for the storefront -> catalog -> orders ->
  payments -> outbox -> events -> recommendations request flow.
- Alertmanager routes by tenant + region + severity.

Until then, Part 06 ch.01 - ch.03's observability stack (running against the
v1 Bookstore) is the prerequisite reading.
