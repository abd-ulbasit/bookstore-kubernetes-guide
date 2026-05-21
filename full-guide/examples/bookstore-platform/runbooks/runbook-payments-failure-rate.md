# Runbook — BookstorePaymentsFailureRate (P1)

Payments-gateway 5xx rate exceeded 5 % for 5 minutes. The platform is
taking real money; this alert affects revenue + tenant trust.

## Alert

- **Name:** `BookstorePaymentsFailureRate`
- **Severity:** `page` (P1)
- **Source:** `examples/bookstore-platform/observability/prometheus-rules.yaml`
- **Query (PromQL):**
  ```promql
  bookstore:http_error_rate:by_tenant_service{service="payments-gateway"} > 0.05
  ```
- **Dashboard:**
  <https://grafana.bookstore-platform.example.com/d/bookstore-overview?var-service=payments-gateway>

## Step 1 — Check (< 60s)

```sh
# Is the alert real? Re-query.
kubectl --context kind-bookstore-platform-${REGION} \
  -n prometheus-system exec -ti prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  "sum(rate(http_requests_total{service=\"payments-gateway\",code=~\"5..\"}[5m])) / sum(rate(http_requests_total{service=\"payments-gateway\"}[5m]))"
# Expected: a float in [0, 1]. > 0.05 = alert real.

# Are payment Pods Running?
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} get pods -l app=payments-gateway
```

**Decision tree:**
- Rate < 5 % now → flapping; silence + investigate next day.
- Rate > 5 %, Pods Running → continue to Step 2.
- Rate > 5 %, Pods CrashLoop → jump to Step 3 (Mitigate).

## Step 2 — Diagnose (ordered)

### 2a. Is Stripe up?

```sh
# Stripe's own status page is the upstream source of truth.
curl -s https://status.stripe.com/api/v2/status.json | jq -r .status.description
# "All Systems Operational" -> Stripe is fine; the problem is ours.
# "Partial Outage" -> Stripe-side; coordinate with Stripe support; we wait.
```

If Stripe-side: this becomes a P2 (we cannot mitigate); update
`#bookstore-platform-status`; the customer-side comm: "payment provider
delays may affect new orders."

### 2b. What error code dominates?

```sh
# Pull the last 100 payments-gateway error logs from Loki.
# Grafana -> Explore -> Loki:
#   {service="payments-gateway"} | json | level="error" | line_format "{{.code}} {{.error}}"

# 502/503 from Stripe -> outage (jump to 2a).
# 401/403 from Stripe -> API key revoked or rotated (jump to 2c).
# 429 from Stripe -> we are rate-limited (jump to 2d).
# 5xx in our own code -> bug; jump to 3b (rollback).
```

### 2c. Stripe API key health

```sh
# The Stripe key is rotated via ESO (Part 13 ch.06's ExternalSecret).
# Check the secret was materialised recently.
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} get externalsecret stripe-api-key \
  -o jsonpath='{.status.refreshTime}'
# Within the last hour = expected. Stale (> 24h) = ESO is broken.

# Confirm the key works by making one curl call.
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} exec -ti deploy/payments-gateway -- \
  curl -s -u "$STRIPE_API_KEY:" https://api.stripe.com/v1/balance | jq .object
# "balance" -> key works
# "invalid_request_error" -> key is bad; rotate via ESO + Stripe dashboard
```

### 2d. Are we being rate-limited?

```sh
# Stripe rate-limit logs.
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} logs -l app=payments-gateway --tail=200 | \
  grep "429"
# Many -> we are sending more than Stripe's per-second budget. Likely
# cause: a Kafka backlog flushing into payments-worker faster than
# Stripe's 100/s limit. Jump to 3c (throttle).
```

### 2e. Outbox + Kafka health

```sh
# The outbox-publisher reads from PG, publishes to Kafka, and the
# payments-worker consumes. A stuck publisher = no payments.
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} get deploy outbox-publisher
kubectl --context kind-bookstore-platform-${REGION} \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  psql -U postgres -d bookstore -c "SELECT count(*) FROM payments_outbox WHERE published_at IS NULL;"
# Many unpublished -> publisher is stuck.
```

## Step 3 — Mitigate

### 3a. Stripe outage (Stripe-side)

- No code mitigation. Communicate; wait for Stripe.
- If > 30 min, switch to the disaster fallback: queue payments locally
  (outbox keeps them; payments-worker retries when Stripe recovers).
- Mark relevant orders as `payment_pending`; customer comm: "we are
  retrying your payment; you will be charged once before X."

### 3b. Rollback our deploy

```sh
# Same as the catalog runbook.
argocd app history bookstore-payments-gateway-${REGION}
argocd app rollback bookstore-payments-gateway-${REGION} <REVISION>
```

### 3c. Throttle (Stripe 429s)

```sh
# Reduce the payments-worker concurrency.
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} patch deploy payments-worker \
  -p '{"spec":{"replicas":1}}'
# Reduces parallelism from 3 to 1; consumption slows to ~33 % of
# previous. The Kafka backlog drains over hours; Stripe stops 429ing.
```

### 3d. Rotate the Stripe API key

```sh
# Stripe dashboard -> Developers -> API Keys -> Rotate.
# Then trigger ESO sync.
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} annotate externalsecret stripe-api-key \
  force-sync="$(date +%s)" --overwrite
# Wait 30s; the Secret reflects the new key; payments-gateway pods
# do not need restart (ESO + the SDK refresh).
```

### Safety check

After each mitigation, re-query the error rate. Falling = working;
not falling = back to Step 2.

## Step 4 — Communicate

- **P1:** customer + tenant comm via Slack within 1 hour. Subject:
  "Payments failure rate elevated for ${TENANT} in ${REGION} —
  investigating." Include the customer-facing impact (e.g. "new
  orders may fail; orders that already paid are not affected").
- **P0 escalation:** if > 50 % of customers see payment failures
  cluster-wide.

## Step 5 — Postmortem

- Required within 48 hours for any P1.
- Template: `examples/bookstore-platform/runbooks/postmortem-template.md`.
- Special section: revenue impact (USD lost during the incident).
- Action items: each must have an owner + ticket + due date.

## Common false positives

- **Test webhook from Stripe.** Stripe occasionally sends test events
  that the webhook-receiver can mis-handle. Mitigation: filter
  test events in the webhook handler.
- **Test cards triggering 4xx.** A QA team running test card flows
  can spike the 4xx rate (NOT 5xx). The alert filters on 5xx; if
  this fires, look at the request bodies in Loki for `card_decline`
  reasons.

## Related runbooks

- [`runbook-api-latency-p99.md`](runbook-api-latency-p99.md) — when the latency spike comes from payments calls.
- [`runbook-database-replication-lag.md`](runbook-database-replication-lag.md) — the outbox table lives in CNPG.

## When this runbook last worked

| Date | Tenant | Region | Cause | Resolved by |
|------|--------|--------|-------|-------------|
| 2026-04-22 | acme-books | us-east | Stripe partial outage | Step 3a (wait) |
| 2026-02-18 | foo-books  | eu-west | 429s from a backlog flush | Step 3c (throttle to 1 replica) |
| 2026-01-30 | acme-books | us-east | bad deploy | Step 3b (rollback) |

If older than 90 days, **STALE**; rehearse before trusting.
