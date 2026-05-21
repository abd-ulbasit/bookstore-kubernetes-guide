# Runbook — restoring a workload via Velero (DATA layer)

> When to reach for this: a whole **tenant namespace** (or a set of
> related namespaces) needs to come back from a Velero backup. Typical
> triggers: a bad `Crossplane` apply deleted a `BookstoreTenant` (with
> `propagationPolicy: Foreground` cascade-deleting all the tenant's
> namespaces); a developer accidentally `kubectl delete namespace
> bookstore-platform-acme-books`; an upgrade orphaned PVs. Velero
> restores BOTH the Kubernetes objects (Deployments, Services,
> ConfigMaps, Secrets) AND the PV data (via CSI VolumeSnapshots).
> Time to mitigate: **5-30 minutes** depending on PV size + object
> count.

## Pre-flight

1. **Confirm a Velero backup of the affected namespace exists.**
   `velero backup get | grep bookstore-platform-${TENANT}`.
2. **Confirm CSI snapshots are in the backup** (PV restore requires
   them). `velero backup describe <BACKUP> --details | grep -A 5 "Persistent Volumes"`.
3. **Confirm the StorageClass referenced by the PVs is still
   present in the target cluster**. A backup taken on `gp3-encrypted`
   restores to a cluster that has the same SC by name; if the cluster
   has migrated to `gp3-encrypted-v2`, the PVC restore will fail.
4. **Confirm the namespace does NOT currently exist** (or has only
   leftover resources Velero will reconcile). If it exists with new
   data, restore will conflict; either delete the namespace first or
   restore to a NEW namespace name with `--namespace-mappings`.

## Alert / trigger

- A `KubeNamespaceDeleted` watch-event alert.
- A page from the platform team: "tenant acme-books namespace is
  gone".
- A capstone DR drill exercise (the monthly script does NOT
  exercise full-namespace restore by default; the quarterly chaos
  game-day does).

## Step 1 — Check (< 60s)

```sh
# Confirm the namespace is missing or empty.
kubectl get namespace bookstore-platform-acme-books
# Error from server (NotFound): namespaces "bookstore-platform-acme-books" not found

# Find a fresh backup.
velero backup get | grep bookstore-platform-acme-books
# NAME                                                        STATUS      ERRORS  WARNINGS  CREATED              EXPIRES
# bookstore-platform-acme-books-daily-2026-05-20-0100         Completed   0       0         2026-05-20 01:00:00  29d
# bookstore-platform-acme-books-daily-2026-05-19-0100         Completed   0       0         2026-05-19 01:00:00  28d

# Pick the most recent COMPLETED backup with 0 errors.
BACKUP=bookstore-platform-acme-books-daily-2026-05-20-0100
```

## Step 2 — Diagnose (< 5 min)

```sh
# Inspect the backup. What's in it?
velero backup describe "$BACKUP" --details
# Look for:
#   Namespaces: [bookstore-platform-acme-books]
#   Resources: 142 (Deployments, Services, ConfigMaps, Secrets,
#              PVCs, NetworkPolicies, ServiceAccounts, Roles,
#              RoleBindings, Argo CD Application, Crossplane XR, ...)
#   Persistent Volumes: ... volumes; provider: ebs.csi.aws.com
#     ...
# Errors:  0
# Warnings: 0

# Confirm the PVs in the backup have CSI snapshots.
velero backup describe "$BACKUP" --details \
  | grep -A 20 "Persistent Volumes"
```

If `Persistent Volumes:` is empty but the namespace had PVCs → the
Velero install does NOT have CSI snapshot enabled. The K8s manifests
will restore but the PV data is lost. Decide: accept-the-loss restore
or recover from CNPG/RDS independently (`data-rollback-postgres-
pitr.md`).

## Step 3 — Mitigate

### 3a. Initiate the restore

```sh
RESTORE=bookstore-platform-acme-books-restore-$(date +%s)

velero restore create "$RESTORE" \
  --from-backup "$BACKUP" \
  --include-namespaces bookstore-platform-acme-books \
  --restore-volumes=true \
  --wait

# Velero outputs:
# Restore request "bookstore-platform-acme-books-restore-1747756800" submitted successfully.
# Waiting for restore to complete. You may safely press ctrl-c to stop the wait, your restore will continue in the background.
# ............................................
# Restore completed with status: Completed. You may check for more information using the commands `velero restore describe ...` and `velero restore logs ...`.
```

Flags:
- `--restore-volumes=true` — restore PV data via CSI snapshots. The
  default if not set; safer to be explicit.
- `--include-namespaces` — comma-separated list. For a multi-namespace
  tenant (e.g. tenants on the v2 platform have a primary + a
  `<tenant>-system` namespace), include both.
- `--existing-resource-policy=update` — for restoring INTO an
  existing namespace (rare; default is to skip). For a "namespace
  was deleted" event, the namespace does not exist; leave default.

### 3b. Verify

```sh
# Check the restore's status.
velero restore describe "$RESTORE"
# Phase: Completed
# Total items to be restored: 142
# Items restored: 142
# Errors: 0
# Warnings: 0
# Status: Completed
# (Volume restore handled by VolumeSnapshotter)

# Are the Pods coming up?
kubectl -n bookstore-platform-acme-books get pods
# NAME                      READY   STATUS    RESTARTS  AGE
# catalog-7c8d9-abc12       1/1     Running   0         2m
# orders-7c8d9-def34        1/1     Running   0         2m
# ...

# PVCs bound?
kubectl -n bookstore-platform-acme-books get pvc
# NAME                STATUS   VOLUME                                     CAPACITY  AGE
# catalog-data        Bound    pvc-...                                    10Gi      2m
# orders-data         Bound    pvc-...                                    50Gi      2m
# (CSI VolumeSnapshots restored as new PVs)
```

### 3c. Reconcile with Argo CD

The restore put back the **Argo CD Application** CR for the tenant.
Argo CD now sees an Application pointing at the tenant's repo path.
Verify it's syncing:

```sh
argocd app get bookstore-platform-tenant-acme-books
# Sync Status:    Synced from <SHA>
# Health Status:  Healthy
```

If the restored Application is `OutOfSync` (the Helm/Kustomize source
of truth moved between backup-time and restore-time) — let Argo CD
sync to HEAD (the source-of-truth wins; not the backup). The
backup's value is the **PV data**, not the application manifests
(those live in git anyway).

### 3d. Reconcile with Crossplane

If the tenant has a `BookstoreTenant` Crossplane XR backed by an AWS
resource (e.g. an RDS, an S3 bucket per-tenant), the XR is restored;
Crossplane's controller will RECONCILE — meaning it will adopt the
existing AWS resources (which were NOT deleted; the K8s namespace
delete didn't cascade across cloud boundaries) and re-attach
ownership.

If for some reason the AWS resources WERE deleted (`Foreground`
propagation + a Composition with `deletionPolicy: Delete`), the XR
will re-CREATE them — but the data is gone. For RDS this is a
`data-rollback-postgres-pitr.md` follow-up; for S3 the bucket data
is the backup's problem (S3 versioning + cross-region replication if
the team wired it).

## Step 4 — Communicate

Velero-restore events are **P0**: an entire tenant was down. Comm:

- **Status page** at Step 1 (we know the namespace is gone) and Step
  3b (service restored).
- **Tenant primary contact** within 15 minutes. Honest message: "We
  detected a namespace deletion at HH:MM; we are restoring from
  yesterday's backup. Estimated time-to-recovery: 30 minutes. Data
  loss: writes between yesterday-01:00 and the deletion event are
  gone."

## Step 5 — Postmortem

Velero-restore postmortems are usually **process** postmortems:

- **What deleted the namespace?** A user's `kubectl delete ns`? A
  bad Crossplane apply? A controller bug?
- **Was the deletion preventable?** A PSA-style admission policy
  that forbids namespace deletion without an annotation? A `Validating
  WebhookConfiguration` that gates deletes? An RBAC change?
- **What was the data loss window?** The time between Velero's last
  backup and the deletion. v2 schedules daily Velero backups + 6-
  hourly snapshots for prod tenants; the data loss for the prod-
  tier was <6h.
- **Action item: monthly DR drill should include a namespace-restore
  exercise.** If it didn't, the team got the runbook right the first
  time at 3am — a luxury that doesn't last.

## Common false starts

- **`velero restore` is `InProgress` for 60+ minutes.** Either a
  VolumeSnapshot is restoring (10s of GB → minutes), or the restore
  is stuck on a PV the controller can't reattach. Check
  `velero restore logs <RESTORE>` for the stuck object.
- **`PVC pending` after restore.** The original PV's StorageClass
  doesn't exist on the restore cluster. Either create the SC or
  override with the Velero `--storage-class-mapping` flag at restore
  time.
- **Argo CD didn't restore.** The Application CR lived OUTSIDE the
  tenant namespace (in `argocd-system`). Make sure the backup
  INCLUDES the `argocd-system` namespace for the per-tenant
  Application objects, or rely on Argo CD ApplicationSet to recreate
  them (the v2 default; Application CRs auto-regenerate from the
  ApplicationSet generator).
- **A controller (cert-manager, ESO, kyverno) refuses the restore.**
  Webhook validating-admission rejects an object the restore tries
  to recreate (e.g. ESO refuses to reconcile a `SecretStore` until
  IRSA is ready). Velero retries; the controller eventually settles.
  If not — restore in `--include-resources` slices: namespace + RBAC
  first, then Deployments, then everything.

## Related runbooks

- [`data-rollback-postgres-pitr.md`](data-rollback-postgres-pitr.md) —
  if the data loss is in Postgres data, not at K8s-object level.
- [`data-rollback-s3-versioning.md`](data-rollback-s3-versioning.md) —
  if the data is in S3.
- [`code-rollback-argocd.md`](code-rollback-argocd.md) — if the
  ArgoCD Application restore is the bigger issue (the workload is
  syncing the wrong revision after restore).

## When this runbook last worked

| Date       | Namespace                                  | Resolved by                       | Notes |
|------------|--------------------------------------------|-----------------------------------|-------|
| 2026-03-21 | bookstore-platform-acme-books              | Step 3a (full restore from daily) | bad Crossplane apply with Foreground; 12 min total |
| 2026-01-12 | bookstore-platform-foo-books               | Step 3a + Step 3c reconcile       | accidental `kubectl delete ns`; ArgoCD reconciled |

> Stale after **90 days** without exercise. The quarterly chaos game-
> day MUST exercise this (Velero restore is the #1 untested capability
> across platform teams).
