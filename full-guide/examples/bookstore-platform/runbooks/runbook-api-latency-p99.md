# Runbook — BookstoreCatalogP99Latency (P1)

Alert fired because catalog p99 latency exceeded 500 ms for 5 minutes
in at least one tenant + region. This page is the **on-call's working
memory** — execute the steps in order; do not skip.

## Alert

- **Name:** `BookstoreCatalogP99Latency`
- **Severity:** `page` (P1)
- **Source:** `examples/bookstore-platform/observability/prometheus-rules.yaml`
- **Query (PromQL):**
  ```promql
  bookstore:http_latency_p99:by_tenant_service{service="catalog"} > 0.5
  ```
- **Dashboard:**
  <https://grafana.bookstore-platform.example.com/d/bookstore-overview?var-service=catalog>
- **Labels (in the page):** `tenant`, `region` — tells you the blast
  radius.

## Step 1 — Check (< 60s)

Confirm the alert is real and current, not a flapping or stale one.

```sh
# Re-query the metric directly (skips the recording rule layer).
kubectl --context kind-bookstore-platform-${REGION} \
  -n prometheus-system exec -ti prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  "histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{service=\"catalog\",tenant=\"${TENANT}\",region=\"${REGION}\"}[5m])))"
# Expected output: a single float. If > 0.5, alert is real.

# Are the catalog pods Running?
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} get pods -l app=catalog -o wide
# All Running 1/1 -> alert real; not deploy-in-progress.
```

**Decision tree:**
- Latency < 500 ms now → flapping; check the alert's `for:` duration
  (5m) is sane; silence for 30 min; investigate next business day.
- Latency > 500 ms + all Pods Running → continue to Step 2.
- Latency > 500 ms + some Pods CrashLoopBackOff → jump to Step 3 (Mitigate),
  scale-up branch.

## Step 2 — Diagnose (ordered)

Localise the cause: DB? CPU? GC? Network? Downstream?

### 2a. CPU / memory saturation

```sh
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} top pods -l app=catalog
# NAME                       CPU(cores)   MEMORY(bytes)
# catalog-7c8d9-abc12        450m         320Mi
# catalog-7c8d9-def34        890m / 1000m 510Mi          <- near CPU limit

# Cross-reference against the resource limits.
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} get pod -l app=catalog -o jsonpath='{.items[*].spec.containers[*].resources}'
```

If CPU usage > 80 % of limit → CPU starvation. Jump to Step 3
(scale-up).

### 2b. Database health

```sh
# Replication lag from the v2 CNPG cluster.
kubectl --context kind-bookstore-platform-${REGION} \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  psql -U postgres -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication;"
# Lag > 30 MB -> replication problem; cross-ref runbook-database-replication-lag.md

# Connection pool exhaustion.
kubectl --context kind-bookstore-platform-${REGION} \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  psql -U postgres -c "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"
# Many 'idle in transaction' -> connection leak in the catalog code.

# Slow queries.
kubectl --context kind-bookstore-platform-${REGION} \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  psql -U postgres -c "SELECT query, total_exec_time, calls FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 5;"
```

### 2c. Downstream calls (search, recommendations)

```sh
# Look at the catalog spans in Tempo for the failing tenant.
# Grafana -> Explore -> Tempo:
#   { service.name = "catalog" && resource.tenant = "${TENANT}" && duration > 500ms }
# What span dominates? If it is a search-svc call -> jump to
# runbook-search-latency.md.
```

### 2d. GC / runtime pauses

```sh
# Pull catalog logs; look for Go GC pause logs.
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} logs -l app=catalog --tail=200 | grep "GC paused"
# > 100ms -> heap pressure; the workload's memory limit needs review.
```

### 2e. Network — Istio sidecar issues

```sh
# Check sidecar restart count.
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} get pods -l app=catalog \
  -o jsonpath='{.items[*].status.containerStatuses[?(@.name=="istio-proxy")].restartCount}'
# > 5 in the last hour -> sidecar instability; jump to runbook-istio-sidecar.md.
```

## Step 3 — Mitigate

The action that stops the bleeding. Run ONE; do not chain mitigations
without re-checking the metric.

### 3a. Scale up (CPU starvation path)

```sh
# Increase catalog replicas. Safety: this hits the tenant's
# ResourceQuota (Crossplane composition stamps 10 CPU / 20 Gi memory).
# Confirm headroom first.
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} describe resourcequota
# Used  CPU: 5 / 10  Memory: 10Gi / 20Gi  -> room to scale
#
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} scale deployment/catalog --replicas=6
# Watch:
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} rollout status deployment/catalog
# Re-check latency in 5 min.
```

### 3b. Rollback (a recent deploy caused it)

```sh
# Check ArgoCD for a recent sync. If a deploy landed within the last
# 30 min and the alert fired AFTER, rollback.
argocd app history bookstore-catalog-${REGION}
# Pick the previous revision.
argocd app rollback bookstore-catalog-${REGION} <REVISION>
# Watch the sync + re-check latency.
```

### 3c. Failover the region (P0 escalation)

If the entire region is degraded AND the latency is causing customer
checkout failures, escalate to P0 and execute the DR runbook:

```sh
# Page the platform team. Open the DR drill script (extended for
# real failover).
bash examples/bookstore-platform/runbooks/dr-drill-script.sh \
  --region ${REGION} \
  --target-region <NEXT-REGION> \
  --dry-run=false
# Customer comm required within 15 min.
```

### Safety check (every mitigation)

After each action, re-query the metric. If latency drops below 500 ms,
the mitigation worked; if not, return to Step 2 and pick the next
branch.

```sh
# Re-query
kubectl --context kind-bookstore-platform-${REGION} \
  -n prometheus-system exec -ti prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  "histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{service=\"catalog\",tenant=\"${TENANT}\",region=\"${REGION}\"}[5m])))"
```

## Step 4 — Communicate

- **P1:** customer comm via Slack `#bookstore-platform-status` within
  1 hour. Subject: "Catalog latency elevated for tenant ${TENANT} in
  ${REGION} — investigating."
- **P0 escalation:** also email tenant primary contact; status-page
  update.

## Step 5 — Postmortem

- Open the template: `examples/bookstore-platform/runbooks/postmortem-template.md`.
- Due within **48 hours** for a P1.
- Action items required + tracked in the platform's GitHub Project
  board.

## Common false positives

- **Cold start spike after deploy.** A new replica's first 60s of
  requests can spike p99. Mitigation: `for: 5m` already covers; if
  flapping, increase to `for: 10m`.
- **One-off slow query from a debug endpoint.** A diagnostic endpoint
  someone called manually. Mitigation: silence the alert for 30 min
  if confirmed; do not change the threshold.
- **Cluster autoscaling churn.** New nodes coming online during a
  scale-up. The Pod startup time spikes latency briefly.

## Related runbooks

- [`runbook-payments-failure-rate.md`](runbook-payments-failure-rate.md) — when the catalog calls flow into payment failures.
- [`runbook-database-replication-lag.md`](runbook-database-replication-lag.md) — when the slow query is at the DB layer.
- [`dr-drill-script.sh`](dr-drill-script.sh) — the regional failover script for the P0 escalation path.

## When this runbook last worked

| Date | Tenant | Region | Resolved by | Notes |
|------|--------|--------|-------------|-------|
| 2026-04-12 | acme-books | us-east | Step 3a (scale to 6) | mid-month traffic spike |
| 2026-03-04 | foo-books  | eu-west | Step 3b (rollback)   | bad query in catalog-1.4.2 |

If this table is older than 90 days, the runbook is **STALE**; rehearse
it at the next chaos game-day before trusting.
