# Runbook — code rollback via Argo Rollouts (CODE layer)

> When to reach for this: a service deployed as an **Argo Rollouts
> `Rollout`** (catalog, payments-gateway, recommendations on the
> Bookstore Platform) is regressing during a canary or after a
> finished rollout. The Argo Rollouts `abort` + `undo` pattern is
> faster than a git rollback because the **stable ReplicaSet is still
> alive** — promoting it back to 100% is a controller-side weight
> change, not a Pod rebuild. Time to mitigate: **< 60 seconds** for
> the abort; **2-3 minutes** total to verify metric recovery.

## The two scenarios

A `Rollout` is in one of two states when this runbook opens:

| State                                     | What's running                                              | Use                  |
|-------------------------------------------|-------------------------------------------------------------|----------------------|
| **Canary in flight** (e.g. setWeight 25%) | stable RS at (100 - canary)%; canary RS at canary%          | `abort`              |
| **Canary fully promoted** (within ~24h)   | canary RS is now stable; the old stable RS is scaled to 0 but its definition is in `.spec.replicaSets[]` (Argo Rollouts keeps the revision history) | `undo`               |

`abort` aborts a **mid-flight** rollout; `undo` rolls back a **finished**
rollout to the previous revision. Both end with a stable ReplicaSet
serving 100% of traffic and the bad ReplicaSet scaled to zero.

## Pre-flight

1. **Confirm it's a Rollout, not a Deployment.** `kubectl get rollout
   -n bookstore-platform-${TENANT}` — if empty, this is the wrong
   runbook (open `code-rollback-argocd.md`).
2. **Confirm Argo CD won't fight you.** Find the Argo CD Application
   that owns this Rollout. If `automated: { selfHeal: true }`, the
   `argo-rollouts` CLI changes will be reverted on the next reconcile.
   Either pause auto-sync (preferred; the Argo CD `app set ...
   --sync-policy none`) **or** git-revert the Rollout's image bump in
   the values file before reconcile lands.
3. **Confirm the bad revision didn't ship a schema migration.** Same
   pre-flight as `code-rollback-argocd.md`'s Step 0.

## Alert / trigger

- The Rollout's **AnalysisRun fired the auto-rollback already**
  (`failed`, `Aborted`). Confirm with `kubectl argo rollouts get
  rollout <NAME>`; if the status is `Degraded` + `AnalysisRunStatus:
  Failed`, the controller already aborted — proceed to Step 1, but
  most of the work is post-incident analysis.
- The AnalysisRun has NOT fired (the threshold was too lax / the metric
  is delayed) — humans must abort. The page is from
  `BookstoreCanaryNotProgressing` or a regression alert.

## Step 1 — Check (< 60s)

```sh
# Where is the Rollout right now?
kubectl argo rollouts get rollout catalog \
  -n bookstore-platform-acme-books

# Sample output (canary in-flight):
# Name:            catalog
# Namespace:       bookstore-platform-acme-books
# Status:          Paused
# Message:         CanaryPauseStep
# Strategy:        Canary
#   Step:          4/8
#   SetWeight:     25
#   ActualWeight:  25
# Images:          ghcr.io/acme/catalog:v1.5.0 (stable)
#                  ghcr.io/acme/catalog:v1.5.1 (canary)
# Replicas:
#   Desired:       6
#   Current:       6
#   Updated:       2
#   Ready:         6
#   Available:     6

# Status: Paused at SetWeight 25 -> the rollout is MID-FLIGHT.

# Sample output (finished, regressing within last 24h):
# Status:        Healthy
# Strategy:      Canary
#   Step:        8/8
#   SetWeight:   100
# Images:        ghcr.io/acme/catalog:v1.5.1 (stable)
```

If `Status: Paused` or `Progressing` → use **`abort`** (Step 3a). If
`Status: Healthy` and you're rolling back a recently-finished rollout
→ use **`undo`** (Step 3b).

## Step 2 — Diagnose (< 2 min)

```sh
# Was an AnalysisRun fired? Did it already abort?
kubectl -n bookstore-platform-acme-books get analysisrun
# NAME                              STATUS       AGE
# catalog-6f8d7c-success-rate-1     Successful   45m
# catalog-6f8d7c-success-rate-2     Failed       12m   <- failure caught
# catalog-6f8d7c-latency-p95-2      Inconclusive 12m

# If the AnalysisRun caught it, the controller already aborted; the
# Rollout's Status is `Degraded` with `AnalysisRunStatus: Failed`.
# Your job becomes the postmortem, not the mitigation.

kubectl argo rollouts status catalog -n bookstore-platform-acme-books
# (`status` watches; exits 0 = Healthy, non-zero = degraded)
```

If the AnalysisRun did **not** fire (false positives masked the
regression; or the alert thresholds were too lax), the human must
abort.

## Step 3 — Mitigate

### 3a. Abort a mid-flight canary

```sh
# This scales the canary RS to 0; the stable RS goes back to 100%.
# It takes effect in seconds because the stable RS Pods are already
# running.
kubectl argo rollouts abort catalog \
  -n bookstore-platform-acme-books
# rollout 'catalog' aborted

# Watch the weight return to stable.
kubectl argo rollouts get rollout catalog \
  -n bookstore-platform-acme-books --watch
# Status:          Degraded
# Message:         RolloutAborted: Rollout aborted update to revision 8
#   SetWeight:     0      <- canary scaled to 0
#   ActualWeight:  0
# Images:          ghcr.io/acme/catalog:v1.5.0 (stable)
#                  ghcr.io/acme/catalog:v1.5.1 (canary; replicas=0)

# To clear the Degraded state and resume normal operation:
kubectl argo rollouts retry rollout catalog \
  -n bookstore-platform-acme-books   # only AFTER you have a fix
```

> **`abort` keeps `.spec.template` set to the bad image.** Until you
> fix the upstream values file (the Argo CD source of truth) and
> sync, the controller may try the rollout again. Disable auto-sync
> on the Argo CD Application or git-revert the image-bump PR.

### 3b. Undo a finished canary

```sh
# Roll back to the previous ReplicaSet revision.
kubectl argo rollouts undo catalog \
  -n bookstore-platform-acme-books
# rollout 'catalog' rolled back to revision 7

# Verify
kubectl argo rollouts get rollout catalog \
  -n bookstore-platform-acme-books
# Status:    Healthy
# Step:      8/8 (the new "head" is the old revision 7)
# Images:    ghcr.io/acme/catalog:v1.5.0 (stable)

# To roll back to a specific revision (instead of "previous"):
kubectl argo rollouts undo catalog \
  -n bookstore-platform-acme-books \
  --to-revision=6
```

> `undo` is exposed by the Argo Rollouts kubectl plugin and writes to
> `.spec.template` to point at the chosen revision's ReplicaSet spec.
> The CRD's `.spec.template` is now **drifted** from the Git source of
> truth — Argo CD will see the diff and (depending on auto-sync)
> revert. **Git-revert the bad commit + push** to make the rollback
> durable; only then re-enable auto-sync.

### 3c. Verify

```sh
# Pods are stable's image only?
kubectl -n bookstore-platform-acme-books get pods -l app=catalog \
  -o jsonpath='{.items[*].spec.containers[*].image}{"\n"}'
# All on ghcr.io/acme/catalog:v1.5.0

# Metric recovery (the bookstore catalog 5xx + p99 pair):
kubectl -n prometheus-system exec -ti prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  'sum(rate(http_requests_total{service="catalog",code=~"5.."}[5m])) / sum(rate(http_requests_total{service="catalog"}[5m]))'
# Expect: drops below 0.01 within 2 minutes.
```

## Step 4 — Communicate

Same as `code-rollback-argocd.md` Step 4. P1 within 1h; P0 within 15
min.

## Step 5 — Postmortem

Mandatory questions for an Argo Rollouts postmortem:

- **Was an AnalysisRun configured?** If not → action item: add one
  (every Rollout SHOULD have a success-rate + latency gate; the
  Bookstore Platform's template is in
  `examples/bookstore-platform/argocd/rollouts/analysistemplate-*.yaml`).
- **Did the AnalysisRun catch it?** If yes, the system worked; if no
  → action item: tune the threshold (the bad release "passed"
  analysis with a 5% error rate because the threshold was 10%).
- **Was the canary step duration long enough?** A 30-second canary
  step ramps too fast for slow regressions to surface. Common fix:
  add an explicit `pause: { duration: 5m }` between weight steps.
- **Was the cold-start spike masked as a regression?** New canary Pods
  spike latency in their first 60s. If the AnalysisRun queried that
  window, it false-positive'd. Fix: add a `pause:` BEFORE the first
  analysis step.

## Common false starts

- **`kubectl argo rollouts abort` succeeded but traffic still hits
  v1.5.1.** The Service selector is `app=catalog` (no `rollouts-pod-
  template-hash` discriminator) — the stable RS Pods are receiving
  traffic too, **but only after the canary RS scaled to 0**. Watch
  `kubectl argo rollouts get rollout` until `SetWeight: 0` AND
  `Available: <stable replicas>`.
- **`undo` did not change anything.** The Rollout has no previous
  revision in its history (it's the first deployment) — there's
  nothing to undo. Use the Argo CD git-revert path instead.
- **Argo CD re-syncs the bad image after `abort`/`undo`.** Auto-sync
  fighting the rollback. Disable Argo CD auto-sync OR (better) merge
  a git-revert PR so the Argo CD source-of-truth matches the cluster
  state.

## Related runbooks

- [`code-rollback-argocd.md`](code-rollback-argocd.md) — if the app is
  a raw Deployment (not a Rollout).
- [`code-rollback-helm.md`](code-rollback-helm.md) — if the Rollout
  ships inside a Helm chart on the platform-base path.
- [`config-rollback-argocd-app.md`](config-rollback-argocd-app.md) —
  if the bad change was a values.yaml edit (not an image bump).

## When this runbook last worked

| Date       | Rollout                       | Region   | Resolved by                | Notes |
|------------|-------------------------------|----------|----------------------------|-------|
| 2026-05-04 | catalog                       | us-east  | Step 3a (`abort` at 25%)   | new index missing in DB; AnalysisRun caught it |
| 2026-04-22 | payments-gateway              | eu-west  | Step 3b (`undo --to=14`)   | regression surfaced 6h after promotion; manual undo |

> Stale after **90 days** without exercise.
