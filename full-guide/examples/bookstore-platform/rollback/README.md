# Bookstore Platform — rollback runbooks

Sample runbooks for the **three rollback layers** introduced in Part 15
ch.07. Each file follows the **Alert / Check / Diagnose / Mitigate /
Postmortem** structure of the Part 13 ch.12 runbooks
(`../runbooks/runbook-*.md`). Use the **decision tree** below to pick
the right layer — the wrong layer turns a 5-minute mitigation into a
4-hour outage.

## The decision tree — which rollback do I need?

```text
SYMPTOM                                                  LAYER          RUNBOOK
─────────────────────────────────────────────────────    ──────────     ──────────────────────────────────
P99 latency spike right after a deploy                   CODE           code-rollback-argocd.md       OR
  AND no schema change in the bad release                CODE           code-rollback-rollouts.md     OR
                                                         CODE           code-rollback-helm.md
─────────────────────────────────────────────────────    ──────────     ──────────────────────────────────
Error rate spike right after a deploy                    CODE           code-rollback-rollouts.md
  AND Argo Rollouts is in `Paused` / pre-promotion                      (the abort+undo path; auto-rollback
                                                                         already fired if AnalysisRun
                                                                         caught the regression)
─────────────────────────────────────────────────────    ──────────     ──────────────────────────────────
Order rows corrupted; a bad migration overwrote          DATA           data-rollback-postgres-pitr.md
  customer data; revenue-impacting                                      (CNPG `Recovery` CR; reach for
                                                                         this only when code rollback
                                                                         alone is INSUFFICIENT)
─────────────────────────────────────────────────────    ──────────     ──────────────────────────────────
A customer accidentally deleted / overwrote an           DATA           data-rollback-s3-versioning.md
  uploaded book cover or PDF in the S3 assets bucket
─────────────────────────────────────────────────────    ──────────     ──────────────────────────────────
A whole namespace's workloads + PVs need to come         DATA           data-rollback-velero.md
  back from yesterday's backup (e.g. tenant
  namespace was deleted by a bad Crossplane apply)
─────────────────────────────────────────────────────    ──────────     ──────────────────────────────────
A config change broke the cluster (HPA bug, bad          CONFIG         config-rollback-argocd-app.md
  NetworkPolicy, broken Ingress); the change was
  shipped via a PR + Argo CD Application sync
─────────────────────────────────────────────────────    ──────────     ──────────────────────────────────
A code rollback ALONE would leave the DB in an           CODE+DATA      code-rollback-argocd.md +
  inconsistent state (the bad release ran a forward                     data-rollback-postgres-pitr.md
  migration that the rolled-back binary cannot read)                    (see the "migration rollback
                                                                         footgun" in ch.15.07)
```

## The three layers

| Layer | What it rolls back | Tool | Typical RTO |
|-------|--------------------|------|-------------|
| **Code** | The binary that's serving traffic | Argo CD `app rollback`, Argo Rollouts `abort` + `undo`, Helm `rollback` | **30 seconds - 5 minutes** |
| **Data** | A bad mutation in Postgres / S3 / a whole tenant namespace | CNPG `Recovery` CR, S3 object versioning, Velero `restore` | **5 minutes - 4 hours** |
| **Config** | A bad PR to a Helm values file, a Kustomize overlay, a `Crossplane` XR | Argo CD app sync against a `git revert` PR | **2 - 10 minutes** |

## The runbooks

### Code rollback (three flavours; pick by tool you ship with)

- [`code-rollback-argocd.md`](code-rollback-argocd.md) — when the app
  is deployed by **Argo CD** with Helm/Kustomize as a "raw" application
  (no Rollout CR; no Helm release tracked).
- [`code-rollback-rollouts.md`](code-rollback-rollouts.md) — when the
  app is deployed via an **Argo Rollouts `Rollout`** with canary +
  AnalysisRun (the Bookstore Platform's default for catalog +
  payments-gateway).
- [`code-rollback-helm.md`](code-rollback-helm.md) — when the app is a
  **Helm release** managed outside Argo CD (e.g. an addon, or a third-
  party chart on the cluster's platform-base path).

### Data rollback

- [`data-rollback-postgres-pitr.md`](data-rollback-postgres-pitr.md) —
  Postgres point-in-time recovery via a **CNPG `Recovery` cluster** to
  a target timestamp (the orders / catalog DBs).
- [`data-rollback-s3-versioning.md`](data-rollback-s3-versioning.md) —
  restore a deleted / overwritten **S3 object** via versioning (the
  Bookstore's `assets` bucket).
- [`data-rollback-velero.md`](data-rollback-velero.md) — restore a
  whole namespace (workloads + PVs) via **Velero**.

### Config rollback

- [`config-rollback-argocd-app.md`](config-rollback-argocd-app.md) —
  `git revert` the bad PR + `argocd app sync` (the GitOps spine of
  every config change).

## Pre-flight (every rollback)

Before clicking the rollback button, three checks:

1. **Is rollback even safe?** A code rollback that hits a forward-only
   schema migration is a database corruption event. The schema-
   compatibility check is in `data-rollback-postgres-pitr.md`'s
   "before you rollback code" section.
2. **What's the blast radius?** A single tenant? A region? Cluster-
   wide? The blast radius determines whether you take downtime (safer)
   or stay live (faster).
3. **Who needs to know?** Always notify `#bookstore-platform-status`
   before starting; customer comm if P0 / P1.

## See also

- [Part 15 ch.07 — Rollback playbook](../../../15-day-to-day-production-ops/07-rollback-playbook.md)
  — the full chapter that introduces these runbooks.
- [`../runbooks/`](../runbooks/) — alert runbooks (the trigger that
  often opens a rollback runbook).
- [`../runbooks/postmortem-template.md`](../runbooks/postmortem-template.md)
  — every rollback closes with a postmortem; this is the template.
- [Part 08 ch.02 — backup and DR](../../../08-day-2-operations/02-backup-and-dr.md)
  — the backup discipline the data rollbacks depend on.
