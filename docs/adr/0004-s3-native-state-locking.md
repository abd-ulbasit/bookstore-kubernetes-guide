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
via the `use_lockfile = true` backend option. It uses S3's conditional-
write semantics (Apr 2024) to acquire the lock as a `.tflock` file
alongside the state object. No DynamoDB, no extra service, no extra
IAM permissions.

## Decision

We will use **`use_lockfile = true`** in every example backend and
runbook. The DynamoDB lock-table pattern is mentioned for historical
context in [ch.14.01](../../full-guide/14-eks-in-production-a-to-z/01-terraform-state-in-production.md)
but is not the recommended path.

Requirements pinned in the example backend:

* Terraform `>= 1.10.0`
* `hashicorp/aws` `>= 5.50.0`
* S3 backend with `encrypt = true` and (optional) `kms_key_id` for
  SSE-KMS.

## Consequences

* **Good:** One AWS service to bootstrap (`bootstrap-state.sh` creates
  the S3 bucket only). One IAM permission surface (S3-only).
* **Good:** Lock-acquire / release semantics are a property of the
  bucket, not a separate table — no orphaned-lock scenarios.
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
