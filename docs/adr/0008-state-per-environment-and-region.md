# 0008 — One Terraform state per environment and per region

* **Status:** Proposed
* **Date:** 2026-10-24
* **Deciders:** abd-ulbasit (proposed in the 2026-10 security audit pass; not yet implemented)

## Context

[Ch.14.01](../../full-guide/14-eks-in-production-a-to-z/01-terraform-state-in-production.md)
argues the right rule well: **one state per blast-radius unit**. It
rejects workspaces for environment separation and keeps the account
baseline in its own root so a cluster `destroy` can never reach CloudTrail.
Two parts of the example trees do not follow that rule yet:

1. **Environments are not modelled.** `bookstore-platform/terraform/` is a
   single root with one state. "Environment" exists only as an
   `Environment = "dev"` tag in `example.tfvars`, which used to tell
   readers to "just edit variables.tf defaults if you only have one
   environment". No staging or prod configuration exists, so nothing shows
   how a prod apply is kept away from dev state. Promotion is not
   modelled either: the CI template (`.github/workflows/terraform.yml`)
   has one `production` environment and one working directory.
2. **Multi-region shares one state.** `terraform/multi-region/` is one
   root with five static `aws` provider aliases and five count-gated
   `cluster-module` instances. Every region lives in **one** state behind
   **one** lock, applied by **one** `terraform apply`. A bad plan, a provider
   bug or a stuck lock affects every region at once. For an active-active
   design, which exists precisely to survive a regional failure, this
   reintroduces a shared failure domain in the control plane.

Both are structural changes. Each touches the backend, the CI matrix and
the chapter text, and each needs a state migration for anyone who has
already applied. Doing them half-way would leave the guide describing one
layout while shipping another. This ADR records the decision and the
migration so it can be done in one deliberate change.

## Decision

We will give **each (environment, region) pair its own state**, keep
**one code path** per tree, and select the pair at `init` time:

* **Environments, platform tree.** Keep `bookstore-platform/terraform/`
  as one root. Add per-environment inputs next to it:

  ```text
  terraform/
    envs/
      dev.tfvars        dev.s3.tfbackend       # key = bookstore-platform/dev/terraform.tfstate
      prod.tfvars       prod.s3.tfbackend      # key = bookstore-platform/prod/terraform.tfstate
  ```

  `backend-s3.tf` keeps only the settings shared by every environment
  (`use_lockfile`, `encrypt`). Each `*.s3.tfbackend` supplies `bucket`, `key`,
  `region` and `kms_key_id`. Prod should use a **different bucket in a
  different account** where possible, so dev credentials cannot read prod
  state at all. Usage:
  `terraform init -reconfigure -backend-config=envs/prod.s3.tfbackend`, then
  `terraform plan -var-file=envs/prod.tfvars`.
* **Regions, multi-region tree.** Turn `multi-region/` into a
  single-region root that instantiates `cluster-module` **once**, with
  `var.region` driving a single `provider "aws"`. Run it once per region,
  with a backend key per region
  (`bookstore-platform/<env>/<region>/terraform.tfstate`). Anything truly
  global (Route 53 latency records, the Argo CD `ApplicationSet`) gets its
  own small root that *reads* the regional states through
  `terraform_remote_state` or SSM parameters, and never writes them.
* **CI.** The workflow runs a matrix over `(env, region)`. Each leg plans
  with that pair's backend and tfvars and applies through a GitHub
  environment named after the pair (`prod-ap-south-1`), whose reviewers
  and role ARN are scoped to it. Promotion is a later leg depending on an
  earlier one (dev before prod; one region before the rest).

## Consequences

* **Good:** Blast radius matches the stated rule. A broken apply, a stuck
  `.tflock` or a corrupted state affects one environment in one region.
* **Good:** Least privilege becomes possible: the dev role cannot read prod
  state, and each region's apply role can be scoped to that region.
* **Good:** Regional applies can be staged (canary region first), which
  is what multi-region is for.
* **Bad:** More `init` invocations and more backend files, and a reader
  has to understand partial backend configuration.
* **Bad:** Cross-region references become explicit reads
  (`terraform_remote_state`/SSM) instead of in-config references. This is
  intended, but it is more code.
* **Follow-ups:** If envs/regions start to differ in *shape* (not just
  values), move to per-environment root directories calling a versioned
  module. That is the point where Terragrunt or Terramate earns its
  place (ch.14.01's threshold).

## Migration (for a tree that has already been applied)

Do this per tree, in a maintenance window, with the state bucket's
versioning on (it is, via `bootstrap-state.sh`).

**Platform tree → per-environment state.**

1. `terraform state pull > backup-$(date +%F).tfstate` (and keep the S3
   object version ID).
2. Create `envs/dev.s3.tfbackend` pointing at the **new** key, then run
   `terraform init -migrate-state -backend-config=envs/dev.s3.tfbackend`.
   Terraform copies the existing state to the new key.
3. `terraform plan -var-file=envs/dev.tfvars` must show **no changes**.
   Stop if it does not.
4. Only then delete the old key's object (versioning keeps history).
5. Prod is a **new** state: bootstrap a separate bucket (ideally in the
   prod account) and apply fresh. Do not copy dev state into prod.

**Multi-region tree → per-region state.**

1. Back up the shared state as above.
2. For each region R: `terraform init -backend-config=<env>/<R>` in the
   new single-region root (empty state). Then move that region's
   resources, either with `terraform state mv -state=<old> -state-out=<new>
   'module.cluster_<R>[0]' 'module.cluster'` (local state files pulled
   from S3 and pushed back), or, preferably on Terraform >= 1.7, with
   `import` blocks in the new root and `removed { lifecycle { destroy =
   false } }` blocks in the old one, so the move is reviewed as code.
3. `terraform plan` in the new regional root must show no changes, and the
   old root must plan to remove nothing from AWS (`removed` only forgets).
4. Repeat per region. Delete the old root and its provider aliases last.

## Alternatives considered

* **Workspaces per environment.** Same backend, same code, a selected
  workspace decides where an apply lands. Rejected for the reasons in
  ch.14.01: the wrong workspace at apply time is a prod outage, and
  workspaces cannot put prod state in another account.
* **Per-environment root directories now.** Cleaner isolation, but it
  duplicates the root before environments differ in shape. Deferred to the
  follow-up above.
* **Keep multi-region as one root, add `-target` per region.** `-target`
  is an escape hatch, not a layout. It still shares one state and one
  lock, and it plans the other regions anyway.
* **Terragrunt.** Solves the backend duplication well. It adds a tool for
  a guide whose trees are not yet numerous enough to need it.

## References

* [Ch.14.01 — Terraform state in production](../../full-guide/14-eks-in-production-a-to-z/01-terraform-state-in-production.md) (workspaces vs separate roots).
* [ADR 0004](0004-s3-native-state-locking.md) (native S3 locking; a stuck lock is per state).
* `full-guide/examples/bookstore-platform/terraform/multi-region/main.tf` (the current shared-state layout).
* Terraform docs: partial backend configuration (`-backend-config`), `import` and `removed` blocks.
