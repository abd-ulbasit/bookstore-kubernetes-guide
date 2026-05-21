# `ci/` — application CI/CD for the Bookstore Platform

The GitHub Actions workflows + signing helper that build, test, scan, sign,
push, and open a GitOps PR for the Bookstore Platform's Go services. This is
the **application** CI/CD pipeline — the infrastructure CI/CD (Terraform)
lives one directory up at
[`../terraform/.github/workflows/terraform.yml`](../terraform/.github/workflows/terraform.yml).

> **Honesty note about service names.** This tree's workflows target `app/catalog/`, `app/orders/`, `app/payments-worker/` — the conceptual Bookstore service names used throughout Parts 00-09. The actual `app/` directory currently ships `auth/`, `events/`, `payments-gateway/`, `recommendations/`, `search/` instead. The workflows are the **contract a future build will satisfy**; to run them today, either (a) adapt the `working-directory:` + path filters to one of the existing services, or (b) add stub `catalog/orders/payments-worker` directories with a single `main.go`. The chapter (ch.15.02) discusses this gap explicitly in its Production notes.

Part 15 ch.02 walks through these workflows in prose. Part 15 ch.03 covers
the cosign keyless + Kyverno verification arc that this code is the CI half
of.

## File map

```
ci/
  README.md                                ← you are here
  .github-workflows-catalog.yml            ← catalog service CI/CD
  .github-workflows-orders.yml             ← orders service CI/CD
  .github-workflows-payments-worker.yml    ← payments-worker service CI/CD
  sbom-and-sign.sh                         ← local helper: syft + cosign keyless
```

The `.github-workflows-*` files are **templates**. GitHub Actions executes
workflows from `.github/workflows/<NAME>.yml` in the repo root, so a real
service repo copies (or symlinks) these into that path. The canonical copies
live here because the Bookstore Platform tree owns the wiring; the leading
dot in the filename keeps them from being accidentally picked up by tooling
that walks the repo.

## What each workflow does (1-liners; ch.02 expands)

| Workflow | Service | Notable bits |
| --- | --- | --- |
| `catalog.yml` | catalog (HTTP, read-heavy) | unit + integration (Postgres); race detector on |
| `orders.yml` | orders (HTTP, write path) | + RabbitMQ integration; 70% coverage gate on `main` |
| `payments-worker.yml` | payments-worker (queue consumer) | broker+DB+provider-stub integration; 80% coverage gate (PR + main) |

All three run the same 5-stage DAG:

```
lint-test  →  integration-test  →  scan  →  build-sign-push  →  update-gitops-pr
```

- **lint-test**: golangci-lint + `go vet` + `go test -race`. Module + build
  cache keyed by `go.sum`.
- **integration-test**: `go test -tags=integration` with real service
  containers (Postgres, RabbitMQ where relevant).
- **scan**: Trivy filesystem scan on the Go modules. `--exit-code 1` on
  HIGH/CRITICAL.
- **build-sign-push**: `docker buildx` multi-arch (amd64 + arm64), push by
  digest to ECR, Trivy scan on the pushed digest, syft SBOM, cosign
  **keyless** sign, cosign attest SBOM. Only runs on push to `main`.
- **update-gitops-pr**: opens a PR against `GITOPS_REPO` bumping the dev
  overlay's image digest. Argo CD reconciles when the PR merges. **CI holds
  no cluster credential.**

## How to opt in per-service

1. **Copy the workflow** to the service repo:

   ```sh
   cp ci/.github-workflows-catalog.yml \
      <SERVICE_REPO>/.github/workflows/catalog.yml
   ```

   The `paths:` filters at the top key on `app/<SERVICE>/**` — keep your
   service code at `app/<SERVICE>/` or edit those filters.

2. **Create the ECR repository** with image-tag-immutability enabled and
   scan-on-push on. Pre-creation is mandatory; the workflow does not
   create repositories.

3. **Provision the IAM role** with ECR push permissions scoped to that
   single repository, trusted to your repo + branch via the OIDC provider
   set up by the Phase 14-R terraform workflow.

4. **Set the GitHub repo secrets and variables** below.

5. **Configure branch protection** on `main`:
   - Require status checks: `lint-test`, `integration-test`, `scan`
   - Require a review (for staging/prod GitOps PRs — see Part 15 ch.04)
   - Restrict who can push directly (admins only; everyone else opens PRs)
   Note: `build-sign-push` and `update-gitops-pr` jobs run only on push-to-main and should NOT be required PR checks — requiring them would block every PR. Only the PR-triggered jobs (`lint-test`, `integration-test`, `scan`) belong in the required-checks list.

## Required GitHub secrets and variables

Set under **Settings → Secrets and variables → Actions** on the SERVICE
repo (not the GitOps repo):

### Secrets (encrypted)

| Name | Purpose |
| --- | --- |
| `AWS_ROLE_ARN_ECR` | IAM role ARN with ECR push perms for this service's repo |
| `GITOPS_PR_TOKEN` | Fine-grained PAT (or GitHub App token) with `contents: write` + `pull-requests: write` on the GitOps repo only |

Do NOT store: AWS access keys (use OIDC instead), `kubeconfig`s,
cluster certs, Argo CD admin tokens. The architecture deliberately leaves
CI with no cluster reach.

### Variables (plain text)

| Name | Purpose |
| --- | --- |
| `AWS_REGION` | e.g. `ap-south-1` — must match the ECR registry's region |
| `ECR_REGISTRY` | e.g. `AWS_ACCOUNT_ID.dkr.ecr.AWS_REGION.amazonaws.com` |
| `GITOPS_REPO` | e.g. `GITHUB_ORG/bookstore-gitops` (separate from the app repo) |

## The local helper script

`sbom-and-sign.sh` mirrors the build-sign-push job's syft + cosign steps so
you can:

- Dry-run the signing flow on your laptop before pushing a CI change.
- Sign an ad-hoc image (a hotfix release tag, an out-of-band rebuild).
- Regenerate an SBOM after a cache-hit rebuild produced the same digest.

```sh
./sbom-and-sign.sh catalog \
  'AWS_ACCOUNT_ID.dkr.ecr.AWS_REGION.amazonaws.com/bookstore/catalog@sha256:abc...'
```

Important honesty point: **a laptop-driven signing uses the operator's
interactive OIDC identity, not the workflow's**. Kyverno's `verifyImages`
rule in production gates on the *workflow* identity (the exact ref pattern
of your `main` branch CI). A local sign is real, but it admits as a
different subject — your laptop, not the CI. The script comment block
explains this in detail.

## Where this fits in the bigger picture

Forward references to chapters owned by parallel phases (plain text — they
do not exist yet at the time this file ships):

- **Part 15 ch.04** (multi-env promotion) — how the digest gets promoted
  from `dev` → `staging` → `prod` via ApplicationSet + reviewed PRs.
- **Part 15 ch.05** (Vault + ESO + rotation) — how the runtime secrets that
  the image consumes are sourced from Vault, not baked in.
- **Part 15 ch.06** (progressive delivery in prod) — what happens after
  Argo CD syncs: a metric-gated canary via Argo Rollouts.
- **Part 15 ch.07** (rollback playbook) — `git revert` the GitOps PR, or
  `argocd app rollback`; when to use which.

Backward references (these chapters exist):

- **Part 07 ch.03** (CI/CD pipeline) — the original Bookstore v1 workflow
  this deepens with multi-arch, ECR, integration suites, GitOps PR seam.
- **Part 07 ch.04** (GitOps with Argo CD) — what the merged PR triggers.
- **Part 05 ch.03** (supply chain: SBOM + cosign) — the conceptual basis
  for the signing flow here.
- **Part 14 ch.07** (Phase 14b's CI/CD + drift) — the *infrastructure* side
  of the same pattern, in Terraform.
- **Part 14 ch.12** (Kyverno verifyImages in cloud) — the cluster-side
  verification of the keyless signatures produced here.
