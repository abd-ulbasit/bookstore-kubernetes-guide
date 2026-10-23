# 0004 — Native S3 state locking, not DynamoDB

* **Status:** Accepted
* **Date:** 2026-05-20
* **Deciders:** abd-ulbasit

## Context

Multi-operator Terraform requires shared, locked state. The canonical
pattern since 2015 has been *S3 backend for state + DynamoDB table for
the lock*. The DynamoDB table costs ~$0.00 in normal use but adds:

* a second AWS service to bootstrap (and to remember to bootstrap),
* a second IAM-permissions surface,
* a separate "lock orphaned, what now?" runbook,
* extra Terraform state-of-the-state to lose if the table is deleted.

Terraform 1.10 (released late 2024) shipped **native S3 state locking**
via the `use_lockfile = true` backend option, as an experimental
feature. It became generally available in Terraform 1.11, and
DynamoDB-based locking is now deprecated. It uses S3's conditional-write
semantics (Apr 2024) to acquire the lock as a `<key>.tflock` object
alongside the state object. No DynamoDB and no extra service. It does
need its own S3 permissions (see *Corrections*).

## Decision

We will use **`use_lockfile = true`** in every example backend and
runbook. The DynamoDB lock-table pattern is mentioned for historical
context in [ch.14.01](../../full-guide/14-eks-in-production-a-to-z/01-terraform-state-in-production.md)
but is not the recommended path.

Requirements pinned in the example backend:

* Terraform `>= 1.11` for GA native locking (`>= 1.10` works with the
  experimental implementation). The S3 backend is built into Terraform
  core, so the `hashicorp/aws` provider version is irrelevant to it.
* S3 backend with `encrypt = true` and (optional) `kms_key_id` for
  SSE-KMS.

## Consequences

* **Good:** One AWS service to bootstrap (`bootstrap-state.sh` creates
  the S3 bucket only). One IAM permission surface (S3-only).
* **Bad:** Orphaned locks still happen. A run that is killed mid-apply
  (cancelled CI job, laptop lid, OOM) leaves `<key>.tflock` behind, and
  every later run fails to acquire the lock until someone confirms
  nothing is running and runs `terraform force-unlock <LOCK_ID>`. The
  lock moved from a DynamoDB item to an S3 object. It did not get
  self-healing.
* **Bad:** The pattern *is* recent. Tutorials, blog posts, even
  HashiCorp's own older docs still show the DynamoDB pattern. New
  readers may import it from elsewhere without knowing. We flag this
  explicitly in the chapter and the README.
* **Follow-up:** Watch the `hashicorp/aws` provider release notes —
  if the conditional-write semantics ever surface a regression, this
  decision needs revisiting.

## Alternatives considered

* **S3 + DynamoDB.** The legacy pattern. More moving parts, no
  technical benefit on Terraform ≥ 1.10. Rejected.
* **Terraform Cloud / Spacelift / Env0.** Adds a vendor +
  product-line dependency to a self-hosted guide. Rejected (but
  recommended for production teams in [ch.14.01](../../full-guide/14-eks-in-production-a-to-z/01-terraform-state-in-production.md)).
* **OpenTofu state encryption + S3.** Compatible — both Tofu and
  Terraform speak the same backend. The decision applies to either.

## References

* `full-guide/examples/bookstore-platform/terraform/backend-s3.tf.example`
* Terraform 1.10 release notes (S3 native locking).
* AWS announcement: S3 conditional writes (Apr 2024).

## Corrections

* **2026-10-24.** Three claims in this ADR were wrong and have been
  fixed above:
  * "no orphaned-lock scenarios". A killed run leaves the `.tflock`
    object, and recovery is `terraform force-unlock`, exactly as with a
    stale DynamoDB item.
  * "no extra IAM permissions". The principal that takes the lock needs
    `s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` on
    `<key>.tflock`, in addition to the state object permissions. This is
    also why the CI template's read-only plan role runs `plan
    -lock=false`: holding a lock means writing an object.
  * "`hashicorp/aws >= 5.50.0`" as a requirement. The S3 backend is part
    of Terraform core; provider versions do not affect it. Native locking
    is GA from Terraform 1.11 (experimental in 1.10).
