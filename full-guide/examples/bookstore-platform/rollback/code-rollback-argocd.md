# Runbook — code rollback via Argo CD (CODE layer)

> When to reach for this: an **Argo CD Application** synced a bad
> manifest revision (a new container image digest, a Helm `values.yaml`
> bump, a Kustomize image-tag patch) and the running workload is
> regressing — error rate, latency, OOMKills, crashloops. The fastest
> safe action is "sync the Application back to a previous revision".
> Time to mitigate: **30 seconds - 2 minutes** for the rollback to
> propagate; total wall-clock with verification: **5-10 minutes**.

## Pre-flight

Confirm **all three** before clicking rollback:

1. **The change was code, not schema.** Run the `migration-rollback-
   check.sh` script (Step 0) — if a Postgres migration shipped with
   the bad release, code rollback alone is insufficient; see
   `data-rollback-postgres-pitr.md` first.
2. **You know the last-known-good revision.** `argocd app history`
   lists revisions; the green one is the target.
3. **Sync mode is appropriate.** Auto-sync ON will fight the rollback
   (it will re-sync to `HEAD`). **Disable auto-sync first** or **pin
   `targetRevision` to a git SHA**.

## Alert / trigger

- A page from `BookstoreCatalogP99Latency`, `BookstorePaymentsErrorRate`,
  `BookstoreOrders5xxRate`, OR a manual decision after a deploy from
  CI's `Deploy succeeded; metrics regressed` Slack message.
- The Argo CD UI shows the Application as `Synced` + `Healthy` on a
  revision that landed in the last 30 minutes — strong signal the
  deploy itself caused the regression.

## Step 0 — Schema-compatibility check (< 60s)

Before rolling code back, confirm the bad release did NOT ship a
forward-only DB migration. If the binary you're rolling back to cannot
read the migrated schema, you'll trade an outage for **data
corruption**.

```sh
# Inspect the last commit's migration diff.
LAST_GOOD=$(argocd app history bookstore-catalog-us-east -o json \
  | jq -r '.[1].revision')                    # the revision BEFORE the current
CURRENT=$(argocd app get bookstore-catalog-us-east -o json \
  | jq -r '.status.sync.revision')

git -C ./bookstore-platform-config diff "$LAST_GOOD..$CURRENT" -- \
  'examples/bookstore-platform/app/*/migrations/*.sql'
# If output is empty -> no migration shipped; safe to code rollback.
# If output shows ADD COLUMN, ADD TABLE, ALTER ... ADD -> the old binary
#   will still read the schema (backwards-compatible); safe to roll
#   back code; the column / table is just unused.
# If output shows DROP COLUMN, DROP TABLE, RENAME, NOT NULL added to
#   an existing column -> NOT safe; stop here.
#   Open data-rollback-postgres-pitr.md.
```

## Step 1 — Check (< 60s)

Confirm the Application is what you think it is.

```sh
# Which revision is it on now?
argocd app get bookstore-catalog-us-east
# Health Status:    Healthy
# Sync Status:      Synced from <CURRENT-GIT-SHA>
# History ID:       42
# Source: ...; Repo: ...; Revision: <CURRENT-GIT-SHA>

# When did the last sync happen?
argocd app history bookstore-catalog-us-east --limit 5
# ID  DATE                      REVISION
# 42  2026-05-20 14:22:13 UTC   d8f3c2a   <- the bad one
# 41  2026-05-20 11:08:51 UTC   a1b2c3d   <- the LAST KNOWN GOOD
# 40  2026-05-19 17:42:09 UTC   9e8d7c6
# 39  2026-05-19 09:31:55 UTC   5a4b3c2
# 38  2026-05-18 13:12:01 UTC   1f2e3d4
```

If history ID 42 landed within the last 30 minutes and the alert fired
**after** that timestamp — strong evidence the deploy caused it.

## Step 2 — Diagnose (< 2 min)

```sh
# What changed in the bad revision?
git -C ./bookstore-platform-config show d8f3c2a --stat
# Look for: image-tag bumps, values.yaml edits, kustomize patches.

# Confirm the image digest the cluster is running.
kubectl -n bookstore-platform-acme-books get deploy catalog \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
# ghcr.io/acme/catalog@sha256:<digest>   <- the bad digest
```

If the bad revision **only** changed app config (a feature flag, a env
var) — consider the feature-flag kill switch FIRST (see
`../feature-flags/README.md`). Flag flip is **faster** than rollback
(<60s vs ~2 min) and lower blast radius.

## Step 3 — Mitigate

### 3a. Disable auto-sync (so the rollback sticks)

```sh
argocd app set bookstore-catalog-us-east --sync-policy none
# Application 'bookstore-catalog-us-east' updated
```

> If you skip this and the Application has `automated: { selfHeal: true }`,
> Argo CD will *immediately* re-sync to `HEAD` and undo your rollback.

### 3b. Roll back the Application

```sh
# Option A — Argo CD CLI
argocd app rollback bookstore-catalog-us-east 41    # the LAST KNOWN GOOD history ID
# Rolling back application 'bookstore-catalog-us-east' to history 41 (revision a1b2c3d)
# Waiting for app to reach 'Synced'...
# Application 'bookstore-catalog-us-east' health is 'Healthy'

# Option B — Argo CD UI
# 1. Open the Application.
# 2. Click History and Rollback.
# 3. Select revision 41; click Rollback.
# 4. Confirm; watch the diff turn green.
```

### 3c. Verify the new state

```sh
# What is it running now?
argocd app get bookstore-catalog-us-east
# Sync Status:      Synced from a1b2c3d
# Health Status:    Healthy

# The Pods are running the good digest?
kubectl -n bookstore-platform-acme-books get pods -l app=catalog \
  -o jsonpath='{.items[*].spec.containers[*].image}{"\n"}'
# ghcr.io/acme/catalog@sha256:<GOOD-digest>

# The metric recovered?
kubectl -n prometheus-system exec -ti prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  'histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{service="catalog"}[5m])))'
# Expect: drops below 0.5 within 2-3 minutes.
```

### 3d. Re-enable auto-sync ONLY after the bad commit is reverted in git

```sh
# Open a PR that git-reverts d8f3c2a; merge it; THEN:
argocd app set bookstore-catalog-us-east --sync-policy automated
# Without this, auto-sync re-applies the bad revision on the next
# reconciliation loop.
```

## Step 4 — Communicate

- **P1:** Slack `#bookstore-platform-status` within 1 hour:
  > Catalog regression detected after deploy d8f3c2a in us-east;
  > rolled back to a1b2c3d at HH:MM UTC; metrics recovered;
  > investigating root cause.
- **P0:** above + tenant contact + status-page entry.

## Step 5 — Postmortem

Open `../runbooks/postmortem-template.md`. Within 48h for P0 / P1.
Mandatory action items for any rollback:

- **Why did CI pass but production fail?** A test gap → action item:
  add the missing test.
- **Why did Argo Rollouts NOT auto-rollback?** Either there's no
  Rollout (just a Deployment), or the AnalysisTemplate threshold was
  not strict enough → action item: tune the threshold or convert to
  Rollout.
- **Was the auto-sync footgun encountered?** If so → action item:
  document the "disable auto-sync first" step in the team runbook.

## Common false starts

- **`argocd app rollback` reports success but Pods don't change.**
  Auto-sync re-applied. Disable auto-sync (Step 3a) then retry.
- **Image digest pinning.** The values file references
  `image.digest = sha256:abcd...`. If Step 3b doesn't pull the old
  digest, check whether the digest is in the bad revision's values
  (Helm) or kustomization (image-tag patch). Rollback restores the
  values; the controller pulls the old image.
- **Helm CRDs in the chart.** `argocd app rollback` does NOT delete /
  downgrade Helm CRDs (Argo CD treats them as cluster-scoped, hands-
  off). If the bad release added an incompatible CRD field, see
  `code-rollback-helm.md` and consider a manual CRD-level fix.

## Related runbooks

- [`code-rollback-rollouts.md`](code-rollback-rollouts.md) — if the
  app is an Argo Rollout (most Bookstore Platform services).
- [`code-rollback-helm.md`](code-rollback-helm.md) — if the bad change
  was inside a raw Helm release outside Argo CD.
- [`data-rollback-postgres-pitr.md`](data-rollback-postgres-pitr.md) —
  if Step 0 reveals an incompatible schema change.
- [`config-rollback-argocd-app.md`](config-rollback-argocd-app.md) —
  if the bad change was config-only (a values.yaml edit, not an
  image bump). Same tool, different "is rollback needed?" question.

## When this runbook last worked

| Date       | App                       | Region   | Resolved by                  | Notes |
|------------|---------------------------|----------|------------------------------|-------|
| 2026-05-01 | bookstore-catalog-us-east | us-east  | Step 3b (rollback to id 38)  | bad image digest; cold-start CPU spike |
| 2026-04-14 | bookstore-orders-eu-west  | eu-west  | Step 3b (rollback to id 27)  | values.yaml: HPA min-replicas dropped 4→1 |

> Stale after **90 days** without exercise. Re-rehearse in the next
> chaos game-day (see Part 13 ch.12).
