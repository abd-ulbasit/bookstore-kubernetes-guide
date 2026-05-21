# `helm/` — platform Helm chart

Phase 13a does not ship a Helm chart for the platform itself — the
platform-base is shipped via Kustomize (`../kustomize/`) because the
cluster-scoped objects (ClusterRoles, PriorityClasses, namespaces) compose
better with Kustomize's commonLabels than with chart templating at this
layer.

Phase 13b (ch.13.05 - 13.08) ships:

- `helm/bookstore-platform/` — umbrella chart wrapping the per-service
  charts (search, payments-gateway, events, recommendations), parameterised
  by tenant.

The v1 Bookstore chart at [`../../bookstore/helm/bookstore/`](../../bookstore/helm/bookstore/)
remains untouched (49-object render invariant).
