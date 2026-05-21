# Runbook — rolling back a config change via Argo CD (CONFIG layer)

> When to reach for this: a **config change** (a Helm values edit, a
> Kustomize patch, an Argo CD `Application` field, a `NetworkPolicy`,
> a `ResourceQuota`, a Crossplane `Composition`) shipped through the
> normal GitOps flow and broke production. The change passed CI, was
> reviewed, was merged — the bug is in the config itself, not in a
> binary. Rollback is **`git revert` + Argo CD sync**. Time to
> mitigate: **2-10 minutes** (the PR review for the revert is the
> bottleneck; the sync itself is seconds).

## Pre-flight

1. **Confirm the change is in git, not direct-applied.** If someone
   `kubectl edit`-ed a manifest, the change is not in git; Argo CD
   sees DRIFT, not a "rollback" target. The fix is `argocd app sync`
   to discard the drift, NOT git-revert.
2. **Confirm the bad change is on `main` / `prod`.** If the change
   is on a feature branch that Argo CD does NOT track, revert is not
   needed; revert the branch only if the bug is "I merged it to the
   wrong place".
3. **Confirm you can write to the repo right now.** Repo locked? CI
   failing on every push? You may need to use the **hotfix /
   breakglass workflow** (`../hotfix/HOTFIX-RUNBOOK.md`) to bypass
   the normal merge gate.

## Alert / trigger

- A page from an alert that fired **after** a recent PR merge:
  `IngressControllerErrors5xx`, `NetworkPolicyBlocksTraffic`,
  `HPAOscillating`, `PodEvictedQuotaExceeded`.
- A platform engineer's observation: "I merged the NetworkPolicy
  PR and now catalog can't reach Postgres".
- A Crossplane controller error: `XR.acmebooks: composition revision
  N invalid; resource provisioning blocked`.

## Step 1 — Check (< 60s)

```sh
# Find the bad PR.
git -C ./bookstore-platform-config log --oneline -n 5 main
# d8f3c2a (HEAD -> main, origin/main) fix(catalog): add NetworkPolicy egress to s3
# a1b2c3d feat(catalog): tighten ResourceQuota cpu limit                 <- the bad one
# 9e8d7c6 chore(deps): bump kustomize plugin version
# 5a4b3c2 fix(orders): add HPA targetCPU 70 -> 80
# 1f2e3d4 ...

# Look at what changed in the bad PR.
git -C ./bookstore-platform-config show a1b2c3d --stat
# kustomize/overlays/prod/resourcequota-catalog.yaml | 6 +++---

git -C ./bookstore-platform-config show a1b2c3d
# - cpu: "10"
# + cpu: "2"        <- the bug: cpu cap too low; catalog scales then evicts
```

## Step 2 — Diagnose (< 5 min)

Confirm the failure mode matches the bad change:

```sh
# Pods being evicted because of the new quota?
kubectl -n bookstore-platform-acme-books get events \
  --field-selector reason=Evicted \
  --sort-by='.lastTimestamp' | head -5

# OR: ResourceQuota Used vs Hard.
kubectl -n bookstore-platform-acme-books describe resourcequota
# Used  cpu: 2     Hard: 2           <- the bug
```

A clean match between the bad-PR diff and the symptom is the
strongest evidence the PR is the cause.

## Step 3 — Mitigate

### 3a. Open a `git revert` PR

```sh
cd ./bookstore-platform-config
git checkout -b revert-resourcequota-cpu-cap
git revert a1b2c3d
# Auto-committed: "Revert \"feat(catalog): tighten ResourceQuota cpu limit\""

git push origin revert-resourcequota-cpu-cap
gh pr create --title "Revert: catalog ResourceQuota cpu cap" \
  --body "Reverts a1b2c3d; this change caused ResourceQuotaExceeded evictions in prod. Postmortem: <link>"
```

For a P0, the revert PR can bypass normal review via the **hotfix
workflow** (`../hotfix/HOTFIX-RUNBOOK.md`). For a P1, expedited review
(< 5 min) is the discipline.

### 3b. Merge

Once merged, Argo CD's auto-sync (if enabled) picks up the change in
< 60s (the default reconciliation interval).

```sh
# If auto-sync is OFF (rare for prod), force a sync.
argocd app sync bookstore-platform-tenant-acme-books \
  --prune \
  --force
# Watch:
argocd app get bookstore-platform-tenant-acme-books
# Sync Status: Synced from <revert-SHA>
# Health Status: Healthy
```

### 3c. Verify

```sh
# Quota restored?
kubectl -n bookstore-platform-acme-books describe resourcequota
# Used  cpu: 2     Hard: 10          <- old quota back

# Evictions stopped?
kubectl -n bookstore-platform-acme-books get events \
  --field-selector reason=Evicted \
  --sort-by='.lastTimestamp' | head -5
# (no recent evictions)

# All Pods Running?
kubectl -n bookstore-platform-acme-books get pods
```

## Step 4 — Communicate

Same as the code-rollback runbooks. Config rollbacks tend to be P1 +
shorter (no data loss), but the **comm discipline is identical**.

## Step 5 — Postmortem

Config-rollback postmortems are the most-instructive because the bug
landed despite CI + review:

- **Why did CI pass?** A config change with no test. Action item:
  add a CI test for the broken behaviour (e.g. a `kubectl apply
  --dry-run=server` + a Kyverno policy check that the
  ResourceQuota is sane).
- **Why did review miss it?** The PR's blast radius wasn't obvious to
  the reviewer. Action item: tag config PRs as `risk: high` when
  they touch quotas, network policies, or admission rules; require
  2 reviewers + 1 platform-team reviewer.
- **Why was Argo CD's "Compare" diff not read carefully?** Argo CD's
  pre-sync diff is the LAST gate. Action item: add a pre-sync
  webhook (Argo CD `SyncWindow` or a Notification) that posts the
  diff to Slack for human review on prod syncs.

## Common false starts

- **Argo CD auto-sync OFF and forgotten.** Step 3b's `argocd app
  sync` is required. Without it, the revert sits in git but doesn't
  reach the cluster.
- **The bad change updated a `ClusterRole` or other cluster-scoped
  resource.** Reverting in git doesn't immediately undo the cluster-
  scoped change (Argo CD treats those as out-of-scope for the
  Application). Manual `kubectl apply` of the old YAML on the
  cluster, then sync.
- **The bad change updated a `Crossplane Composition`.** The
  Composition is versioned; reverting in git creates a NEW revision.
  The XRs already provisioned reference the OLD revision and won't
  re-reconcile to the new one without an explicit `kubectl patch`
  bumping the `compositionRevisionRef`. For Composition rollbacks,
  see the Crossplane docs + the v2 `examples/bookstore-platform/
  crossplane/` README.
- **The Helm chart's CRDs were touched.** Helm does not roll back
  CRDs. `kubectl apply` the old CRD manifest by hand.

## Related runbooks

- [`code-rollback-argocd.md`](code-rollback-argocd.md) — if the bad
  change was an image-tag bump (a code change, not a config change).
  Same tool, different "what to inspect" question.
- [`code-rollback-helm.md`](code-rollback-helm.md) — if the
  change was a `helm upgrade` outside Argo CD.
- [`../hotfix/HOTFIX-RUNBOOK.md`](../hotfix/HOTFIX-RUNBOOK.md) — if
  branch protection or CI failures block the revert PR.

## When this runbook last worked

| Date       | Repo / path                              | Resolved by         | Notes |
|------------|------------------------------------------|---------------------|-------|
| 2026-05-03 | overlays/prod/resourcequota-catalog.yaml | Step 3 (git revert) | quota cap too low; evictions |
| 2026-04-19 | crossplane/composition-bookstore.yaml    | Step 3 + Composition revision bump | bad RDS instance class size |

> Stale after **90 days** without exercise.
