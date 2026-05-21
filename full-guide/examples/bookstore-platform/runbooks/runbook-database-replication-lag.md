# Runbook — BookstoreCNPGReplicationLag (P1)

CNPG replication lag exceeded 30 seconds for 5 minutes. The standby
region's view of writes is stale; a regional failover NOW would lose
data.

## Alert

- **Name:** `BookstoreCNPGReplicationLag`
- **Severity:** `page` (P1)
- **Source:** `examples/bookstore-platform/observability/prometheus-rules.yaml`
- **Query (PromQL):**
  ```promql
  cnpg_pg_replication_lag > 30
  ```
- **Dashboard:**
  <https://grafana.bookstore-platform.example.com/d/cnpg-overview>

## Step 1 — Check (< 60s)

```sh
# Is the alert real?
kubectl --context kind-bookstore-platform-${REGION} \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  psql -U postgres -c "
    SELECT application_name,
           pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
           extract(epoch from (now() - reply_time))::int AS lag_seconds
    FROM pg_stat_replication;
  "
# application_name    lag_bytes   lag_seconds
# eu-west-replica     128 MB      45             <- > 30s = alert real

# Are both CNPG clusters healthy?
kubectl --context kind-bookstore-platform-${REGION} \
  -n cnpg-system get cluster
kubectl --context kind-bookstore-platform-eu-west \
  -n cnpg-system get cluster
```

**Decision tree:**
- Lag < 30 s now → flapping; silence + investigate.
- Lag > 30 s, both clusters healthy → continue to Step 2.
- Lag > 30 s, replica cluster degraded → Step 3 (Mitigate).

## Step 2 — Diagnose (ordered)

### 2a. Network latency between regions

```sh
# Run a quick latency probe from the primary's pod to the replica's
# replication endpoint.
kubectl --context kind-bookstore-platform-${REGION} \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  curl -s -o /dev/null -w "%{time_total}s\n" \
  https://cnpg-eu-west.bookstore-platform.example.com:5432
# > 200ms RTT cross-region = expected for transatlantic; > 1s = network
# issue; jump to 3a.
```

### 2b. Replica I/O saturation

```sh
kubectl --context kind-bookstore-platform-eu-west \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  iostat -x 1 5
# Watch %util on the data disk. > 90 % sustained = I/O bottleneck;
# the replica cannot keep up with WAL replay.
```

### 2c. Long-running query on the replica

```sh
kubectl --context kind-bookstore-platform-eu-west \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  psql -U postgres -c "
    SELECT pid, state, query_start, query FROM pg_stat_activity
    WHERE state='active' AND now() - query_start > interval '1 minute';
  "
# A read query on the replica can block WAL replay if it locks rows
# WAL replay wants to update. The PG `hot_standby_feedback` setting
# determines who wins; v2 defaults to feedback=on (replica's query
# wins, primary's vacuum waits).
```

### 2d. Primary write spike

```sh
# Is the primary writing more than usual?
kubectl --context kind-bookstore-platform-${REGION} \
  -n prometheus-system exec -ti prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  "rate(cnpg_pg_stat_bgwriter_wal_bytes_total[5m])"
# A 10x spike = a batch job. Jump to 3c (throttle the batch).
```

### 2e. WAL retention

```sh
# Has the primary moved past the replica's slot?
kubectl --context kind-bookstore-platform-${REGION} \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  psql -U postgres -c "SELECT slot_name, restart_lsn, confirmed_flush_lsn, active FROM pg_replication_slots;"
# active = false on a slot = the replica disconnected; reconnect
# needed. CNPG should handle this; if not, kick the replica's pod.
```

## Step 3 — Mitigate

### 3a. Cross-region network issue

```sh
# Likely network-side; communicate to networking team; the platform
# response is to NOT failover (the replica is too far behind).
# Page the on-call networking SRE.
# Block any planned failovers until the alert clears.
```

### 3b. Restart the replica (replica-side stuck)

```sh
# Trigger a restart of the replica's primary pod (CNPG promotes/
# demotes as needed).
kubectl --context kind-bookstore-platform-eu-west \
  -n cnpg-system delete pod bookstore-platform-cnpg-1
# CNPG re-creates; replication resumes.
```

### 3c. Throttle a primary write spike

```sh
# If 2d shows a batch job, throttle it. Common culprits:
# - search reindex job (jump to runbook-search-reindex.md)
# - Debezium snapshot (the outbox-table snapshot)
# - a bulk-import script

# Pause Debezium connector (if it's the cause):
kubectl --context kind-bookstore-platform-${REGION} \
  -n debezium exec debezium-connect-0 -- \
  curl -s -X PUT http://localhost:8083/connectors/bookstore-outbox/pause
# Resume once the lag drops.
```

### 3d. Failover to a different replica (if multi-replica)

If we have a third replica in a third region, fail over to that one
(do not fail over to the lagging replica). DR script:

```sh
bash examples/bookstore-platform/runbooks/dr-drill-script.sh \
  --region ${REGION} \
  --target-region <HEALTHY-REPLICA-REGION>
```

### Safety check

```sh
# Re-query the lag.
kubectl --context kind-bookstore-platform-${REGION} \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  psql -U postgres -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication;"
# Falling = working; not falling = back to Step 2.
```

## Step 4 — Communicate

- **P1:** announce in `#bookstore-platform-status` within 1 hour.
  Customers are not directly affected (writes still succeed on
  primary); the comm is to inform the team that a failover is
  **not safe** until this clears.
- **P0 escalation:** if the lag prevents a planned failover during a
  separate incident.

## Step 5 — Postmortem

- Required within 48 hours.
- Template: `examples/bookstore-platform/runbooks/postmortem-template.md`.
- Special section: was the RPO target breached? (For us, > 5 min lag
  = RPO breach.)

## Common false positives

- **Maintenance window.** CNPG runs a scheduled `VACUUM` on Sundays
  at 02:00 UTC; lag can spike to 60 s briefly. The alert's `for: 5m`
  filters most of these; if not, expand to `for: 10m`.
- **WAL archiving slow.** A slow S3 endpoint can delay WAL archiving;
  CNPG sometimes reports this as lag (it isn't, exactly). Mitigation:
  ensure S3 endpoint resolves correctly; the chapter's
  `endpoint-url: s3.us-east-1.amazonaws.com` is the regional endpoint
  (cross-region writes through a global endpoint add ~50ms).

## Related runbooks

- [`runbook-api-latency-p99.md`](runbook-api-latency-p99.md) — when the lag manifests as slow API queries.
- [`runbook-payments-failure-rate.md`](runbook-payments-failure-rate.md) — when the outbox publisher stalls due to lag.
- [`dr-drill-script.sh`](dr-drill-script.sh) — DO NOT run during this alert.

## When this runbook last worked

| Date | Region | Lag peak | Cause | Resolved by |
|------|--------|----------|-------|-------------|
| 2026-04-15 | eu-west | 4m | Sunday VACUUM | self-resolved in 12m |
| 2026-02-09 | ap-southeast | 8m | network blip | Step 3b (replica restart) |
| 2026-01-20 | eu-west | 25m | Debezium snapshot run | Step 3c (pause connector) |

If older than 90 days, **STALE**; rehearse before trusting.
