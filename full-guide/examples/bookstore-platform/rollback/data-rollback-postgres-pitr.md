# Runbook — Postgres point-in-time recovery (DATA layer)

> When to reach for this: a Postgres database (orders / catalog / etc.,
> all CNPG-managed on the Bookstore Platform) suffered a **bad data
> mutation** (a UPDATE without a WHERE, an accidental TRUNCATE, an app
> bug that double-charged customers) AND code rollback alone will not
> restore the data. You need to bring the database back to the state
> it had at a specific timestamp **before** the mutation. The
> CloudNativePG (CNPG) operator does this via a `Recovery` CR + base
> backup + WAL replay. Time to mitigate: **15-90 minutes** depending
> on database size + WAL volume. **Plan for downtime on the affected
> tenant.**

## Pre-flight — the brutally-honest preface

PITR is not free; the cost is honesty about three things:

1. **PITR is not zero-downtime.** The bad mutation is in the data
   plane; the only safe way to roll it back is to (a) stop writes,
   (b) stand up a recovered cluster at the target timestamp, (c)
   point the application at the recovered cluster. The application's
   tenant or namespace will be down during (a) → (c). **Customer
   comm is REQUIRED.**
2. **You will lose post-mutation writes.** Any writes accepted between
   the bad mutation and the recovery cut-over are gone unless you
   manually replay them. The orders shipped, the payments captured,
   the search-index updates — all rolled back. The trade-off: a
   smaller blast radius (one mutation gone) for a larger blast
   radius (everything since). Sometimes the trade-off is worth it;
   sometimes the right answer is "manually correct the bad rows".
3. **The schema must match the application's binary.** If you also
   ran a forward migration in the bad release and code-rolled-back,
   the recovered DB will be at the **old** schema; the **new** binary
   needs the **new** schema. If you didn't code-rollback, the new
   binary on the old schema may not start. **The decision order:
   recover DB → match binary to schema (rollback binary if needed) →
   warm the app.**

## Alert / trigger

- **Reactive**: a customer-reported "my last 50 orders disappeared",
  a Grafana panel showing `orders_total` dropped by 30%, a payments
  reconciliation script reporting net-negative orders.
- **Proactive**: a CI job's pre-merge schema-migration smoke caught
  the bug after the migration ran in staging-prod-clone; the
  postmortem decision is "the wrong rows shipped; recover".

## Step 1 — Check (< 5 min)

```sh
# Confirm the CNPG cluster name + namespace.
kubectl -n cnpg-system get clusters
# NAME                                  AGE     INSTANCES   READY   STATUS
# bookstore-platform-cnpg-orders        87d     3           3       Cluster in healthy state
# bookstore-platform-cnpg-catalog       87d     3           3       Cluster in healthy state

# Find a backup that PREDATES the bad mutation.
kubectl -n cnpg-system get backups -l cnpg.io/cluster=bookstore-platform-cnpg-orders
# NAME                                                       AGE     STATUS      CLUSTER                          METHOD
# bookstore-platform-cnpg-orders-2026-05-20-base-1430        24h     completed   bookstore-platform-cnpg-orders   barmanObjectStore
# bookstore-platform-cnpg-orders-2026-05-19-base-1430        48h     completed   bookstore-platform-cnpg-orders   barmanObjectStore

# WAL archive presence (PITR needs continuous WAL).
kubectl -n cnpg-system exec bookstore-platform-cnpg-orders-1 -- \
  pg_basebackup --help | head -1   # sanity-check exec works
kubectl -n cnpg-system get clusters bookstore-platform-cnpg-orders \
  -o jsonpath='{.status.firstRecoverabilityPoint}{"\n"}'
# 2026-05-15T12:00:00Z  <- earliest PITR target

kubectl -n cnpg-system get clusters bookstore-platform-cnpg-orders \
  -o jsonpath='{.status.lastSuccessfulBackup}{"\n"}'
# 2026-05-20T14:30:00Z

# What time WAS the bad mutation?
# Cross-reference application logs, audit log, the user's report.
# Pick a target timestamp ~1 minute BEFORE the bad mutation.
TARGET_TIME="2026-05-20T13:45:00.000000Z"
```

If `firstRecoverabilityPoint` is AFTER your target timestamp → you
cannot PITR to that point (the base backup + WAL is gone). Fallback:
the older base backup is in cold storage; manually restore the dump
(see `data-rollback-velero.md`'s S3-restore section) — a much longer
recovery.

## Step 2 — Diagnose (< 10 min)

```sh
# Locate the exact bad mutation in the WAL.
kubectl -n cnpg-system exec bookstore-platform-cnpg-orders-1 -- \
  psql -U postgres -d orders -c "
    SELECT relname, n_tup_del, n_tup_upd
    FROM pg_stat_all_tables
    WHERE relname IN ('orders', 'order_items', 'payments')
    ORDER BY n_tup_del + n_tup_upd DESC;
  "
# orders | 12345 | 67890   <- bad mutation visible

# pg_audit / row-level audit trigger (the v2 platform-base ships one)
kubectl -n cnpg-system exec bookstore-platform-cnpg-orders-1 -- \
  psql -U postgres -d orders -c "
    SELECT row_to_json(audit.log) FROM audit.log
    WHERE table_name='orders' AND action='DELETE'
    AND action_tstamp_tx > '2026-05-20 13:40:00+00'
    ORDER BY action_tstamp_tx ASC LIMIT 5;
  "
# {"action_tstamp_tx":"2026-05-20T13:44:18Z", ... }   <- bad mutation at 13:44:18
# Target time: 1 minute BEFORE -> 13:43:00.000000Z
```

## Step 3 — Mitigate

### 3a. Stop writes to the affected DB

```sh
# Scale the affected application to 0 (catalog or orders depending on
# which DB is affected). This prevents NEW bad data while the
# Recovery cluster is built.
kubectl -n bookstore-platform-acme-books scale deployment/orders --replicas=0
kubectl -n bookstore-platform-acme-books scale deployment/api-gateway --replicas=0   # if it talks to orders directly

# Status-page entry: "orders service in maintenance for tenant acme-books"
```

> Skipping this step means writes go to a soon-to-be-discarded
> cluster. They are lost. Don't skip.

### 3b. Apply the CNPG Recovery CR

```sh
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: bookstore-platform-cnpg-orders-recovered
  namespace: cnpg-system
spec:
  instances: 3
  primaryUpdateStrategy: unsupervised
  storage:
    size: 100Gi
    storageClass: gp3-encrypted
  bootstrap:
    recovery:
      source: bookstore-platform-cnpg-orders-cold
      recoveryTarget:
        # Exclusive: stop AT (not including) the target time.
        targetTime: "2026-05-20 13:43:00.000000+00"
        # OR by transaction ID:
        # targetXID: "12345678"
        # OR by named restore point:
        # targetName: "before-bad-migration"
  externalClusters:
    - name: bookstore-platform-cnpg-orders-cold
      barmanObjectStore:
        destinationPath: s3://bookstore-platform-cnpg-backups/orders
        s3Credentials:
          accessKeyId:    { name: cnpg-backup-creds, key: ACCESS_KEY_ID }
          secretAccessKey:{ name: cnpg-backup-creds, key: SECRET_ACCESS_KEY }
        wal: { compression: gzip }
EOF

# Watch the recovery cluster build.
kubectl -n cnpg-system get clusters bookstore-platform-cnpg-orders-recovered -w
# NAME                                              INSTANCES   READY   STATUS
# bookstore-platform-cnpg-orders-recovered          1           0       Setting up primary
# ...
# bookstore-platform-cnpg-orders-recovered          3           3       Cluster in healthy state
```

The wall-clock here is **DB-size-dependent**:
- < 10 GB: ~5 minutes.
- 100 GB: ~30 minutes.
- 1 TB: ~3+ hours.

WAL replay is the slow phase. Monitor:

```sh
kubectl -n cnpg-system logs bookstore-platform-cnpg-orders-recovered-1 \
  --tail=20 | grep "restored"
# 2026-05-20T15:01:42 LOG:  restored log file "000000010000004500000023" from archive
# ...
```

### 3c. Spot-check the recovered data

```sh
# Connect to the recovered cluster.
kubectl -n cnpg-system port-forward svc/bookstore-platform-cnpg-orders-recovered-rw 5432:5432 &

PGPASSWORD=$(kubectl -n cnpg-system get secret bookstore-platform-cnpg-orders-recovered-superuser \
  -o jsonpath='{.data.password}' | base64 -d)

psql -h 127.0.0.1 -U postgres -d orders -c "
  SELECT count(*) FROM orders WHERE tenant='acme-books';
"
# Should match the pre-mutation count.

psql -h 127.0.0.1 -U postgres -d orders -c "
  SELECT max(created_at) FROM orders;
"
# Latest order timestamp; should be < target_time.

kill %1   # stop port-forward
```

### 3d. Cut over the application to the recovered cluster

Two strategies:

**Strategy A — repoint** (faster; ~2 min). Update the orders
ExternalSecret + the orders `DB_HOST` env var to point at
`bookstore-platform-cnpg-orders-recovered-rw.cnpg-system`. Roll the
Deployment. The recovered cluster is now the orders DB.

```sh
# Patch the orders Deployment env (or update the ConfigMap; depends
# on the Bookstore's DB_HOST source).
kubectl -n bookstore-platform-acme-books set env deployment/orders \
  DB_HOST=bookstore-platform-cnpg-orders-recovered-rw.cnpg-system.svc.cluster.local
kubectl -n bookstore-platform-acme-books scale deployment/orders --replicas=3

# Verify reads + writes work
kubectl -n bookstore-platform-acme-books logs -l app=orders --tail=20
```

**Strategy B — rename** (safer; ~10 min). Delete the bad cluster,
rename the recovered cluster to take its name + service. The
application's existing DB_HOST keeps working.

```sh
# 1. Backup the bad cluster (for forensics).
kubectl -n cnpg-system get cluster bookstore-platform-cnpg-orders \
  -o yaml > /tmp/bad-cluster-snapshot.yaml

# 2. Delete the bad cluster.
kubectl -n cnpg-system delete cluster bookstore-platform-cnpg-orders --wait=true

# 3. Apply a NEW Cluster YAML named bookstore-platform-cnpg-orders
#    that recovers from the recovered cluster (no app change needed).
#    See CNPG docs; this is a multi-minute manual step.
```

Strategy A is the default for the Bookstore Platform; B is the
choice for clusters where the application's DB_HOST is hard-coded
in many places.

### 3e. Re-enable application traffic

```sh
kubectl -n bookstore-platform-acme-books scale deployment/orders --replicas=3
kubectl -n bookstore-platform-acme-books scale deployment/api-gateway --replicas=3
# Watch readiness probes turn green; metric: orders/s back to baseline.
```

## Step 4 — Communicate

PITR is almost always **P0** (data loss event). Customer comm:

- **Status page** at the start of Step 3a (downtime begins).
- **Tenant primary contact** by phone or direct Slack DM. The honest
  message: "We are recovering data to a point 15 minutes before a
  bad mutation. Writes made after that point are lost. We will share
  a list of those writes in the postmortem."
- **Status page** at the end of Step 3e (service restored).
- **`#bookstore-platform-status` updates** every 15 minutes during
  the recovery.

## Step 5 — Postmortem

PITR-postmortems are dense; the template has extra sections:

- **What was the bad mutation?** The SQL, the binary version that
  ran it, the input that triggered it.
- **Why did CI not catch it?** Almost always: missing migration test,
  missing data-validation test, missing schema-constraint.
- **How much data was lost in the recovery?** The list of rows
  written between (target_time, mutation_time). The team OWES the
  customer this list.
- **Why did the bad mutation reach prod?** A migration without a
  dry-run? An app bug? A direct DBA `psql` session? The fix is
  often process (`no production psql without two-person-rule`) more
  than code.

## Common false starts

- **Wrong target_time.** Too early → unnecessary data loss; too late
  → the bad mutation is included. **Always verify with Step 2's
  audit query** and use `targetTime` with a 1-minute buffer BEFORE
  the bad mutation.
- **Forgot to stop writes.** Step 3a is skipped; new orders go to the
  about-to-be-discarded cluster. **Customer reports double-billing in
  the postmortem** because the recovered cluster lost the new write
  but Stripe captured the charge. Customer-trust event.
- **Cut over before the recovery is healthy.** Step 3b's `Cluster in
  healthy state` is REQUIRED before Step 3d. Cutting over to a
  recovering cluster gives `connection refused` outages.
- **Recovered cluster's storage is too small.** The recovered cluster
  was sized for the active set; WAL replay needs the full historical
  volume. **Default**: size the Recovery cluster's PVC at 2× the
  original cluster's `storage.size`.

## Related runbooks

- [`code-rollback-argocd.md`](code-rollback-argocd.md) — if the bad
  mutation rode in with a code release; rollback the code FIRST so
  the recovered DB matches the binary's schema.
- [`data-rollback-velero.md`](data-rollback-velero.md) — if the
  affected workload is the whole tenant namespace (PVs + workloads
  together), Velero's restore is simpler than rebuilding from CNPG
  base backup.
- [Part 08 ch.02 — backup and DR](../../../08-day-2-operations/02-backup-and-dr.md) —
  the backup discipline this runbook depends on (the cluster MUST
  be backing up its WAL + base; if it's not, this runbook is moot).
- [Part 13 ch.03 — multi-region active-active](../../../13-grand-capstone-bookstore-platform/03-multi-region-active-active.md) —
  the cross-region replication shape that, in a multi-region
  outage, is a different recovery story.

## When this runbook last worked

| Date       | Cluster                                    | Resolved by              | Notes |
|------------|--------------------------------------------|--------------------------|-------|
| 2026-04-09 | bookstore-platform-cnpg-orders             | Step 3 + Strategy A     | bad migration drop_column; 45 min total; 14 orders lost |
| 2026-02-18 | bookstore-platform-cnpg-catalog            | Step 3 + Strategy A     | rogue TRUNCATE from manual psql session; 90 min total |

> Stale after **90 days** without exercise. The monthly DR drill in
> `../runbooks/dr-drill-script.sh` SHOULD exercise this runbook
> quarterly (the WAL-replay verification step).
