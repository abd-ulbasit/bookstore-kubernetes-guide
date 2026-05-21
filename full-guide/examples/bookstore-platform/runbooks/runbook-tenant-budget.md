# Runbook — BookstoreTenantBudgetBreach (P2)

Alert fired because a tenant's month-to-date (MTD) cost crossed 100%
of its declared monthly budget. This is a FinOps event, not a service
outage — but it is a **contract event**: someone owes money or the
tenant is misusing the platform. Execute in order.

## Alert

- **Name:** `BookstoreTenantBudgetBreach`
- **Severity:** `page` (P2 — wakes on-call but is not customer-facing)
- **Source:** `examples/bookstore-platform/cost/budget-alerts.yaml`
- **Query (PromQL):**
  ```promql
  (
    bookstore:cost_mtd:by_tenant
    / on(tenant) bookstore:tenant_monthly_budget
  ) > 1.0
  ```
- **Dashboard:**
  <https://grafana.bookstore-platform.example.com/d/bookstore-platform-cost?var-tenant=${TENANT}>
- **Related early-warning alerts:** `BookstoreTenantBudgetWarn` (80%)
  + `BookstoreTenantBudgetForecastBreach` (projected 120% by EoM).

## Step 1 — Check (< 60s)

```sh
# Re-query the metric directly.
kubectl --context kind-bookstore-platform-${REGION} \
  -n prometheus-system exec -ti prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  "bookstore:cost_mtd:by_tenant{tenant=\"${TENANT}\"} / on(tenant) bookstore:tenant_monthly_budget{tenant=\"${TENANT}\"}"
# If > 1.0, breach is real.

# Cross-reference the budget (sanity: did a PR edit it downward?).
kubectl --context kind-bookstore-platform-${REGION} \
  -n opencost get configmap tenant-budgets -o yaml | grep -A1 "${TENANT}-monthly-budget"
```

**Decision tree:**

- Ratio < 1.0 now → flapping; silence for 1 hour; investigate next day.
- Ratio > 1.0 + budget value correct → continue to Step 2.
- Ratio > 1.0 + budget value wrong (bad PR) → revert; the alert
  clears on next eval. Postmortem the bad PR.

## Step 2 — Diagnose (ordered)

### 2a. Which workload-class drove the spend?

```sh
# Per-class breakdown for this tenant.
kubectl --context kind-bookstore-platform-${REGION} \
  -n prometheus-system exec -ti prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  "topk(5, sum by (class) (
      opencost_pod_total_hourly_cost
        * on (namespace, pod) group_left(class) kube_pod_labels{label_bookstore_platform_example_com_class!=\"\"}
        * on (namespace) group_left() kube_namespace_labels{label_bookstore_platform_example_com_tenant=\"${TENANT}\"}
   ))"
# class="ml" dominant -> training jobs in -ml namespace.
```

### 2b. Has spend trended up or jumped?

Open the cost dashboard's "Cost per tenant — last 30 days" panel:
- **Linear ramp** → organic growth; budget needs review.
- **Step jump** → a new workload landed; identify it.
- **Sustained spike** → a runaway job (training loop, recursive
  CronJob, GPU node stuck on).

### 2c. Any obviously-runaway pods?

```sh
# Pods running >30 days continuously? Often a stuck training job.
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} get pods --sort-by=.status.startTime \
  -o custom-columns=NAME:.metadata.name,AGE:.status.startTime,NODE:.spec.nodeName
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT}-ml get pods,jobs --sort-by=.status.startTime
```

### 2d. GPU nodes used without `class=ml` label?

A pod on a GPU node without `class=ml` shows as unallocated GPU spend.

```sh
kubectl --context kind-bookstore-platform-${REGION} \
  -n bookstore-platform-${TENANT} get pods -o json \
  | jq -r '.items[] | select(.spec.nodeName | test("gpu")) | "\(.metadata.name) \(.metadata.labels)"' \
  | grep -v 'bookstore-platform.example.com/class'
```

## Step 3 — Mitigate (in order, least to most aggressive)

### 3a. Notify the tenant admin

```sh
kubectl --context kind-bookstore-platform-${REGION} \
  get tenant.bookstore-platform.example.com ${TENANT} \
  -o jsonpath='{.spec.admin.email}{"\n"}'
# Slack: #bookstore-platform-finops + DM tenant admin.
```

Name the breach, the MTD value, the budget, the dominant workload-class,
and the action required in the next 24 hours.

### 3b. Freeze new resource creation in their namespace

Apply the platform's Kyverno-enforced budget freeze:

```sh
kubectl --context kind-bookstore-platform-${REGION} \
  annotate namespace bookstore-platform-${TENANT} \
  bookstore-platform.example.com/budget-frozen=true \
  --overwrite

# The Kyverno ClusterPolicy `deny-create-on-budget-freeze` then:
#   - rejects new Pods, Deployments, Jobs, CronJobs, StatefulSets
#   - allows updates (so on-call can scale down existing workloads)
#   - allows deletes always
```

**Existing workloads keep running** — this is showback, not a hard
kill. Hard-kill is a contract decision, not a default.

### 3c. Bill the tenant (chargeback) or upgrade their tier

FinOps team's decision, not on-call's:

- **Chargeback:** tenant pays the over-budget; remove freeze.
- **Upgrade tier:** edit both `tenant-budgets` ConfigMap and the
  `bookstore:tenant_monthly_budget` recording rule in
  `examples/bookstore-platform/cost/budget-alerts.yaml`; PR + FinOps
  approval; `argocd app sync bookstore-platform-cost`. Alert auto-clears.
- **Strict showback:** keep freeze on; tenant scales down before EoM.

### Safety check

Re-query after 3a + 3b. Budget ratio drops slowly (existing workloads
keep running); track the **rate of change** instead:

```sh
kubectl --context kind-bookstore-platform-${REGION} \
  -n prometheus-system exec -ti prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  "deriv(bookstore:cost_per_hour:by_tenant{tenant=\"${TENANT}\"}[1h])"
# Negative -> mitigation working; positive -> tenant has not scaled down.
```

## Step 4 — Communicate

- **P2 (default):** `#bookstore-platform-finops` within 4 hours;
  DM tenant admin within 1 hour.
- **P1 escalation** (strict-showback contract + tenant refuses to
  scale down): page FinOps lead + platform lead; freeze stays;
  no status-page update (internal billing event).

## Step 5 — Postmortem

- Template: `examples/bookstore-platform/runbooks/postmortem-template.md`.
- Due within **5 business days** for a P2 budget breach (no SLO
  burning — planning postmortem, not fire postmortem).
- Action items required:
  - **Forecast:** did `BookstoreTenantBudgetForecastBreach` fire earlier? If not, why?
  - **Budget:** right-sized for tenant tier?
  - **Workload:** if runaway, who owns the fix?
  - **Policy:** is the Kyverno freeze working as designed?
- Tracked in the platform's GitHub Project board (`finops` label).

## Common false positives

- **First-of-month wobble.** Day 1-2 UTC: `MTD / day_of_month()`
  ratio is volatile. The `for: 30m` usually catches it; if not,
  silence for 1 hour.
- **OpenCost backfill.** After exporter restart, per-hour series
  re-emits with a small lag; MTD briefly inflates. Cross-check via
  dashboard panel; silence for 30 min if confirmed.
- **ConfigMap edited downward.** Someone PR'd a smaller budget for
  a tier-downgrade without scaling the tenant's workloads.

## Related runbooks

- [`runbook-api-latency-p99.md`](runbook-api-latency-p99.md) — when
  scale-down fixes the breach but spikes latency.
- [`runbook-database-replication-lag.md`](runbook-database-replication-lag.md) —
  CNPG cluster size is often a top cost driver.
- [`postmortem-template.md`](postmortem-template.md) — the planning
  postmortem template for P2 budget events.

## When this runbook last worked

| Date | Tenant | Resolved by | Notes |
|------|--------|-------------|-------|
| 2026-04-22 | foo-books  | Step 3c (tier upgrade) | Q2 growth, $500 -> $1500/mo |
| 2026-03-18 | acme-books | Step 3b (freeze + scale-down) | runaway ML training |

If older than 90 days, this runbook is **STALE**; rehearse at the
next FinOps review.
