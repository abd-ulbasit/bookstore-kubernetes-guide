# Runbook — restoring an S3 object version (DATA layer)

> When to reach for this: a single S3 object (or a small set) was
> **accidentally deleted or overwritten** in the Bookstore Platform's
> `assets` bucket (book covers, PDFs, customer uploads). The bucket
> has **versioning enabled** (Phase 14-R Terraform sets this on
> creation; verify with the pre-flight), so the old bytes are still
> there — just hidden behind a delete-marker or a newer version. The
> mitigation is **copy the older version back to the current
> position**. Time to mitigate: **2-10 minutes** depending on object
> count.

## Pre-flight

1. **Confirm versioning is enabled** on the bucket. If it is not, the
   old bytes are GONE; this runbook does not apply. (The Bookstore
   Platform's `assets-bucket` Terraform module enables versioning on
   creation; this is a sanity check, not an unusual case.)
   ```sh
   aws s3api get-bucket-versioning --bucket bookstore-platform-assets-${ENV}
   # { "Status": "Enabled", "MFADelete": "Disabled" }
   ```
2. **Identify the affected objects.** A key, a key prefix, or a small
   list. If the blast radius is "the whole bucket", consider
   restoring from the Velero backup of S3 + a separate cross-region
   replica instead.
3. **Confirm no lifecycle rule has tombstoned old versions.** The
   v2 platform's lifecycle rule expires noncurrent versions after
   30 days. If the bad delete is > 30 days old, the old version may
   be gone.
   ```sh
   aws s3api get-bucket-lifecycle-configuration --bucket bookstore-platform-assets-${ENV}
   # Inspect NoncurrentVersionExpiration.NoncurrentDays
   ```

## Alert / trigger

- A customer complaint: "the book cover for ISBN 978-... is broken".
- A monitoring alert: `S3ObjectRequestRate5xx > 1%` (high 5xx on
  asset reads frequently maps to a delete-marker on a hot object).
- A platform engineer's observation after a bad mass-delete script
  ran.

## Step 1 — Check (< 60s)

```sh
BUCKET=bookstore-platform-assets-prod
KEY=acme-books/covers/978-1234567890.jpg

# Is the object MISSING (delete-marker) or OVERWRITTEN (newer version)?
aws s3api head-object --bucket "$BUCKET" --key "$KEY"
# A 404 NoSuchKey -> delete-marker is the current version.
# A 200 -> the current version is the overwrite (NOT what we want).

# List all versions for this key.
aws s3api list-object-versions --bucket "$BUCKET" --prefix "$KEY" \
  --output table \
  --query 'Versions[*].[Key,VersionId,LastModified,Size,IsLatest] | sort_by(@, &[2]) | reverse(@)'
# ┌─────────────────────────────────────┬──────────────────┬──────────────────────────┬────────┬──────────┐
# │ Key                                 │ VersionId        │ LastModified             │ Size   │ IsLatest │
# │ acme-books/covers/978-1234...jpg    │ KuT4...          │ 2026-05-20T13:30:00.000Z │ 145082 │ False    │ <- the one we want
# │ acme-books/covers/978-1234...jpg    │ M7vK...          │ 2026-05-10T09:11:00.000Z │ 145082 │ False    │
# └─────────────────────────────────────┴──────────────────┴──────────────────────────┴────────┴──────────┘

# Are there delete-markers?
aws s3api list-object-versions --bucket "$BUCKET" --prefix "$KEY" \
  --output table \
  --query 'DeleteMarkers[*].[Key,VersionId,LastModified,IsLatest]'
# ┌───────────────────────────────────┬──────────────┬──────────────────────────┬──────────┐
# │ Key                               │ VersionId    │ LastModified             │ IsLatest │
# │ acme-books/covers/978-1234...jpg  │ DEL...       │ 2026-05-20T14:22:13.000Z │ True     │ <- the bad delete
# └───────────────────────────────────┴──────────────┴──────────────────────────┴──────────┘
```

## Step 2 — Diagnose (< 5 min)

If the deletion was a **manual mistake** (one object) — Step 3a's
single-key restore is the right move. If the deletion was a **bad
script** (many objects) — pivot to Step 3b's prefix-level restore.

```sh
# How many delete-markers were created in the window the script ran?
aws s3api list-object-versions --bucket "$BUCKET" --prefix "acme-books/" \
  --output json \
  | jq '.DeleteMarkers | map(select(.LastModified > "2026-05-20T14:20:00Z" and .LastModified < "2026-05-20T14:30:00Z")) | length'
# 4527

# If 4527 - this is a bulk restore. Use Step 3b.
```

## Step 3 — Mitigate

### 3a. Single-object restore — delete the delete-marker

The simplest case: a delete-marker is hiding the previous version.
**Deleting the delete-marker** exposes the previous version as
current.

```sh
DELETE_MARKER_VERSION_ID="DEL..."   # from Step 1
aws s3api delete-object \
  --bucket "$BUCKET" \
  --key "$KEY" \
  --version-id "$DELETE_MARKER_VERSION_ID"
# Now the previous version (KuT4...) is the current.

# Verify.
aws s3api head-object --bucket "$BUCKET" --key "$KEY"
# 200 OK.
```

### 3a-alt. Single-object restore — copy an older version to current

For an OVERWRITE (no delete-marker; newer version replaced the good
version), copy the old version to the current key:

```sh
GOOD_VERSION_ID="KuT4..."
aws s3api copy-object \
  --bucket "$BUCKET" \
  --key "$KEY" \
  --copy-source "$BUCKET/$KEY?versionId=$GOOD_VERSION_ID"
# Creates a NEW version that is byte-identical to the GOOD_VERSION,
# making it current. The bad-overwrite version is kept as a non-
# current version (forensic value).
```

### 3b. Bulk restore — undelete a prefix

For a delete script that nuked many objects, the simplest tool is the
AWS CLI loop (or the `s3-pit-restore` open-source tool). The shape:

```sh
DELETE_AFTER="2026-05-20T14:20:00Z"
DELETE_BEFORE="2026-05-20T14:30:00Z"
PREFIX="acme-books/"

aws s3api list-object-versions \
  --bucket "$BUCKET" \
  --prefix "$PREFIX" \
  --output json \
  | jq --arg AFTER "$DELETE_AFTER" --arg BEFORE "$DELETE_BEFORE" '
      .DeleteMarkers
      | map(select(.LastModified > $AFTER and .LastModified < $BEFORE and .IsLatest == true))
    ' \
  | jq -r '.[] | "\(.Key)\t\(.VersionId)"' \
  | while IFS=$'\t' read -r key vid; do
      echo "Restoring: $key"
      aws s3api delete-object --bucket "$BUCKET" --key "$key" --version-id "$vid"
    done

# This deletes every delete-marker the script created in the window,
# exposing the previous (good) versions. Pre-validate with --dry-run
# (the AWS CLI does not have --dry-run for delete-object; pipe to
# `tee /tmp/plan.txt` first and inspect before piping to the loop).
```

> For > 10K objects: write a Lambda or use the `s3-pit-restore` Python
> tool (it parallelises across many objects; the loop above is
> serial). Bookstore Platform's `examples/bookstore-platform/rollback/
> scripts/s3-undelete.py` is a starter (NOT included in this phase;
> production-ready).

### 3c. Verify

```sh
aws s3api head-object --bucket "$BUCKET" --key "$KEY"
# 200 OK with the restored Size.

# Front-end smoke test (the catalog API serves the asset).
curl -I "https://api.bookstore-platform.example.com/v1/covers/978-1234567890.jpg"
# HTTP/2 200
# content-type: image/jpeg
# content-length: 145082
```

## Step 4 — Communicate

- **P1** for a single-customer-impact restore: Slack
  `#bookstore-platform-status`.
- **P0** for a bulk restore (many customers affected): customer comm
  within 15 min via the v2 status page + tenant primary contact.

## Step 5 — Postmortem

S3 deletion postmortems often have a "human ran the wrong script"
root cause. The corrective action items:

- **Add MFA Delete to the bucket?** Stops accidental deletes (the
  delete requires an MFA token in the API call). Trade-off: rotating
  MFA tokens in CI is painful. The v2 default: MFA Delete OFF in dev
  + staging, ON in prod for the `assets` bucket (the biggest blast
  radius).
- **Add S3 Object Lock (compliance mode)?** Makes objects literally
  undeletable for a fixed retention. Useful for legal-hold data;
  not appropriate for cover-image churn.
- **Two-person rule on bulk-delete scripts?** A bash-script with an
  `aws s3 rm --recursive` got merged via a one-person PR. Action
  item: require dual approval on PRs to `scripts/s3-*-delete.sh`.

## Common false starts

- **The delete-marker is from BEFORE the bad event.** A stale delete-
  marker from a legitimate earlier delete. Re-validate by `head-
  object` on the version you're about to expose — confirm the
  `LastModified` predates the bad event.
- **The bucket has KMS encryption + the IAM role doesn't have
  `kms:Decrypt`.** The `copy-object` will fail with `AccessDenied`.
  Add the role's IAM policy or use the breakglass role
  (`../hotfix/breakglass-iam-policy.json`).
- **The previous version is older than the lifecycle-noncurrent-
  expiration window.** The previous version expired. Restore from
  cross-region replication target if configured; otherwise the data
  is gone.

## Related runbooks

- [`data-rollback-velero.md`](data-rollback-velero.md) — if the
  affected data is in a PVC, not S3.
- [`data-rollback-postgres-pitr.md`](data-rollback-postgres-pitr.md) —
  if the data is in Postgres.
- [`../hotfix/breakglass-iam-policy.json`](../hotfix/breakglass-iam-policy.json) —
  if the standard IAM role lacks permissions for the restore (rare;
  invoke breakglass).

## When this runbook last worked

| Date       | Bucket                                | Resolved by               | Notes |
|------------|---------------------------------------|---------------------------|-------|
| 2026-04-26 | bookstore-platform-assets-prod        | Step 3a (single object)   | accidental UI delete; one cover restored |
| 2026-03-08 | bookstore-platform-assets-staging     | Step 3b (4500 objects)    | bad cleanup script in CI; 5 min restore |

> Stale after **90 days** without exercise.
