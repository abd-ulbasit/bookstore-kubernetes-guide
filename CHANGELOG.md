# Changelog

All notable changes to this project will be documented in this file. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `security-gates.yml`: the security-first gates on real GitHub runners. The
  gate unit tests, G1+G2 over the whole guide, G1+G3 against a kind
  v0.33.0 cluster, the registry gate (G5), the lab-evidence gate (G7) and G4,
  the runtime gate, which deploys the Bookstore five ways (raw manifests, the
  Helm chart, each Kustomize overlay) into `restricted` namespaces and waits
  for every workload. Chapter failures are report mode except the chapters
  in `.github/security-gates-enforced.txt`.
- `bookstore-release.yml`: dispatch one service through the reusable
  pipeline with publish on (signing, provenance, SBOM attestation) and open a
  promotion PR. Default branch only.
- ADR 0009: security-first, no unlearning, one exceptions registry (which
  extends ADR 0005), the gates, Kubernetes 1.37 and no clusters on AWS or GCP
  during the rewrite.
- Real working `app/catalog/` Go service (Postgres-backed, instrumented,
  tested, benchmarked) — promotion from the Phase 16 stub.
- `BENCHMARKS.md` with k6 latency results against `catalog/`.

### Changed
- `SECURITY-SCAN.md` is rewritten around the exceptions registry
  (`.trivyignore.yaml` and `security/namespace-exceptions.yaml`). It corrects
  the platform RBAC count, the Backstage entry and the "permissive examples"
  principle, and records what a real pipeline run has and has not proved.
- README says the guide is being rewritten security-first and which chapters
  are done.
- The Bookstore NetworkPolicies let the app reach its own data tier. They
  admitted only catalog to postgres and nobody to redis, so orders, the
  migration Job and the catalog cache timed out on a cluster that enforces
  policy (kind v0.33.0's kindnet does). `allow-catalog-to-postgres` becomes
  `allow-data-tier-ingress`; the count stays at 10.
- The Bookstore Ingress moves from the retired ingress-nginx to Traefik, the
  controller Part 02 ch.04 installs. `50-ingress.yaml` (raw, Kustomize base,
  Helm template) is the portable form: class `traefik`, `Prefix` paths, no
  annotation. The services serve `/books` and `/orders` while the UI calls
  `/api/books` and `/api/orders`, so the prefix has to be stripped at the
  edge, and Traefik does that with a Middleware, which is a custom resource.
  It ships as `50-ingress-traefik.yaml`, the Helm value
  `ingress.traefikRewrite.enabled` and the Kustomize component
  `traefik-rewrite`, all off in the default renders. The ADR 0007 counts hold:
  Helm 49, Kustomize 45, 49 and 48. The NetworkPolicy header says kindnet
  enforces policy since kind v0.24.0, and the Helm value
  `networkPolicy.ingressControllerNamespace` defaults to `traefik`.
- The production overlay and `values-prod.yaml` size the namespace quota to
  their own replicas. The dev-shaped quota refused postgres and the
  migration Job.
- **Kubernetes 1.37 is now the target version** (was 1.35, which reaches
  end of life on 2027-02-28). Toolchain pins move with it: kubectl
  1.37.2, Helm 3.22.1, kind v0.33.0 (default node image
  `kindest/node:v1.37.0`, pinned by digest in the binary), k3d v5.9.0
  with `rancher/k3s:v1.37.1-k3s1`, and standalone kustomize v5.8.1.
- EKS Terraform defaults to 1.37 with Karpenter 1.15.1 (the only line
  its compatibility matrix allows on 1.37) and the extra controller IAM
  it needs. Not yet re-run on AWS; the 1.35 smoke test stands as
  history. GKE pins 1.37.1 on the Regular channel.
- The example operator moves to client-go v0.37.2, controller-runtime
  v0.25.2, controller-gen v0.22.0 and envtest 1.37.0.
- Chapter text updated for what 1.36 and 1.37 changed: etcd 3.6+
  (`etcdutl` for snapshot status and restore), IPVS deprecated in favour
  of nftables, native sidecars, SELinuxMount, HPAScaleToZero, removed
  metrics and feature gates, and support windows.

- The prod image pins move out of `overlays/prod/kustomization.yaml` into a
  Kustomize Component, `overlays/prod/images/`, that holds only the `images:`
  list. The first real run of `bookstore-release.yml` ran `kustomize edit set
  image` on the whole overlay and turned a one-line pin into 143 added and 145
  removed lines, which no reviewer could read, in a PR whose merge is the
  production deploy. The prod render is byte-identical (48 objects). The
  promotion job now edits only that file and fails if it changes any other or
  more than 8 lines.
- The promotion PR carries the real owner, repository and digest in its body,
  with a `cosign verify` that matches the signing identity exactly (branch
  included) and a `gh attestation verify`. A PR opened with `GITHUB_TOKEN`
  triggers no workflows, so a new `checks` job dispatches
  `example-trees-check.yml` and `security-gates.yml` on the PR's branch.
- The runtime gate (G4) deploys the prod overlay with its image pins pointed at
  the images it built, so a promoted digest does not break it.
- OpenSSF Scorecard runs on a dispatch from the default branch, not only on a
  push, so the release workflow gets a score.
- The `sast` job no longer tries to upload the CodeQL database. It has no
  `security-events` permission, so the first release run retried the upload
  for nearly two minutes and left an error annotation on a green job.
- Chapter 07.03 (steps 3, 8, 10, 12 and 13) and `evidence/07-03.txt` record
  the first real signing and promotion instead of reading them: the signature,
  SBOM attestation and provenance verified from outside, Scorecard's first
  score (6.7 / 10), what Harden-Runner and CodeQL showed, and the five defects
  the first release run found, including the promotion PR that rewrote 288
  lines. The end of step 12 lists what is still unproven. SECURITY-SCAN.md
  section 8 is updated to match.
- The promotion PR's `gh attestation verify` pins the identity with
  `--cert-identity`, because `--repo` alone accepts any workflow in the
  repository. The workflow header and the PR body now say what GitHub did with
  the bot-opened PR's `pull_request` runs: created them with no jobs and left
  them at `action_required`.
- The prod overlay pins `catalog` and `orders` to the signed digests that
  `bookstore-release.yml` pushed (promotion PRs 10 and 12). `payments-worker`
  and `storefront` still name the placeholder registry.
- The promotion PR body no longer says the dispatched checks "appear below".
  The third release run (`orders`) showed they run and pass on the PR's
  branch but stay out of the PR's own Checks tab. The body now links the
  branch's runs page and says so. The reworded text has not run in Actions.
  Chapter 07.03 and `evidence/07-03.txt` add that run, correct the step 13
  table and the Honesty note to match what each run found, and say what is
  still unproven, including that `main` requires no review or check.
- Part 01 Core workloads (01.02 to 01.08) is rewritten security-first on the
  01.01 baseline, with threats and controls in each chapter and lab evidence
  checked by the evidence gate. The admission gate judges a registered
  namespace at its registered level only for the chapter it names, and
  `01-core-workloads/` joins the enforced list.
- Part 03 Configuration and storage (03.01 to 03.05) is rewritten
  security-first, with the 03.02 lab run on a kind cluster and
  `03-config-and-storage/` joins the enforced list.
- Part 10 Cloud and managed Kubernetes (10.01 to 10.06) is rewritten
  security-first, and `10-cloud-and-managed-kubernetes/` joins the enforced
  list.
- Part 00 Foundations (00.01 to 00.08) is rewritten security-first, with 00.08
  Security foundations and the threat model in `examples/bookstore/THREAT-MODEL.md`;
  `00-foundations/` joins the enforced list.
- Part 02 Networking (02.01 to 02.06) is rewritten security-first, with the
  Ingress and Gateway API chapters on Traefik and `02-networking/` joins the
  enforced list.
- Part 15 Day-to-day production ops (15.01 to 15.12) is rewritten
  security-first, with 15.09 as the home for breakglass, and
  `15-day-to-day-production-ops/` joins the enforced list.
- Part 14 EKS in production (14.01 to 14.17) is rewritten security-first, with threats and controls in each chapter, the Terraform validated offline and nothing run on AWS, and `14-eks-in-production-a-to-z/` joins the enforced list.
- Appendix A to F is rewritten security-first (the kubectl cheat sheet loses
  its exam section), and `appendix/` joins the enforced list.
- Part 06 Production readiness (06.01 to 06.06) is rewritten security-first,
  with the 06.05 PodDisruptionBudget drain run on a three-node kind cluster,
  and `06-production-readiness/` joins the enforced list.
- Part 13 Grand capstone (13.01 to 13.12) is rewritten security-first, with
  threats and controls in each chapter, scoped Crossplane provider RBAC,
  TLS-only Kafka, and `13-grand-capstone-bookstore-platform/` joins the
  enforced list. Heavy stacks were validated with `helm template` and server
  dry runs, and nothing ran on AWS or GCP.
- Part 04 Scheduling (04.01 to 04.03) is rewritten security-first, with real
  labs on a three-node kind cluster, and `04-scheduling/` joins the enforced
  list.
- Part 07 Delivery (07.01, 07.02, 07.04 and 07.05) is rewritten
  security-first, with the Helm, Argo CD and Argo Rollouts runs recorded on
  kind (07.03 landed earlier), and `07-delivery/` joins the enforced list.
- Part 11 Advanced production patterns (11.01 to 11.10) is rewritten
  security-first. The example operator's missing `/convert` route is
  registered and its manager ran on kind, and
  `11-advanced-production-patterns/` joins the enforced list.
- Part 08 Day-2 operations (08.01 to 08.05) is rewritten security-first, with
  the 08.01 drill and the 08.04 quota and tenant refusals run on a three-node
  kind cluster, and `08-day-2-operations/` joins the enforced list.
- Part 05 Security (05.00 to 05.10) is rewritten security-first, from four
  chapters to eleven, with each lab run as attack, harden, re-attack and
  evidence on kind, and `05-security/` joins the enforced list. The full
  Kyverno, Gatekeeper, Falco and Trivy Operator installs are still marked not run.
- Part 09 end-to-end Bookstore (09.01) is rewritten security-first: the core
  Bookstore runs behind Traefik under `restricted` on a kind cluster, with the
  edge answer, a NetworkPolicy refusal and a restricted refusal captured, and
  `09-end-to-end-bookstore/` joins the enforced list.
- Part 12 Kubernetes for machine learning (12.01 to 12.08) is rewritten
  security-first, with the default-deny, Kueue and JobSet runs recorded on a
  kind cluster, GPU behaviour cited and not run, and
  `12-kubernetes-for-machine-learning/` joins the enforced list. The MLflow
  tracker image is built on `python:3.14-slim` (pinned by digest) with MLflow
  3.17.2 and 94 pinned packages, and its Python packages scan clean at
  CRITICAL and HIGH; the training image drops pip as the serving image does.

### Fixed
- Standalone EKS add-ons (kube-proxy, CoreDNS, EBS CSI) now follow
  cluster upgrades through an `aws_eks_addon_version` lookup; with
  `addon_version = null` they stayed on their create-time build.
- The vpc-cni `moved` block now targets `before_compute["vpc-cni"]`.
- The ML pipeline's kubectl image (`bitnami/kubectl:1.31.1`, no longer
  published) is replaced by Chainguard's kubectl image, pinned by digest.

## [1.0.0] — 2026-05-23

First stable cut. The guide, the four example trees, and the build
discipline are all considered durable from this tag forward; subsequent
changes follow semver.

### Added
- **Parts 00–15 / 115 chapters** of the comprehensive zero-to-production
  Kubernetes guide, all anchored on one evolving Bookstore example.
- **Four example trees:**
  - `examples/bookstore/` — canonical, kind/k3d-local (Parts 02–08)
  - `examples/bookstore-platform/` — multi-tenant Platform v2 (Parts 12–13)
  - `examples/bookstore-platform/terraform/` — EKS infrastructure
    (live smoke-tested on EKS 1.35 in `ap-south-1`, ~$0.20 spend)
  - `examples/bookstore-platform/terraform-account-baseline/` —
    account-wide AWS guardrails
- **Phase 16 learning-experience improvements**: per-chapter learning
  metadata, self-assessment exercises with collapsible answers, Go
  service stubs, concept-map + tag-index appendix, MkDocs Material
  site, CI for example trees.
- **GitHub Pages deploy** at <https://abd-ulbasit.github.io/bookstore-kubernetes-guide/>
- **CI quality gates** on every push to `main`:
  - `mkdocs build --strict` (no broken internal links)
  - `mermaid.parse()` against every diagram (mermaid 10.9.1, same as
    production) — catches "Syntax error in text" before deploy
- **Nightly + PR-time CI** on the example trees:
  - `helm lint` and `helm template` count (49 manifests)
  - `kubectl kustomize` overlay counts (45/49/48 for dev/staging/prod)
  - `terraform fmt -check` + `terraform validate` on all three trees
  - `go vet` + `go build` on every Go service
  - Leak-scan for machine paths, real account IDs, real emails
- **Architecture Decision Records** (7) under `docs/adr/`
- **Smoke-test post-mortem** at `docs/lessons-from-smoke-test.md`
- **GitHub Codespaces** dev container at `.devcontainer/`

### Fixed (post-1.0 patch-style fixes that landed in the same week)
- 12 broken mermaid diagrams (`;` parsed as sequence-diagram statement
  terminator, parens in unquoted edge labels, `.` in dotted-edge labels,
  literal `\n` rendering as text).
- 8 misaligned ASCII diagrams (off-by-one box borders).
- Mobile rendering: thin scrollbar visible on overflowing code blocks
  at viewports < 768px (was invisible by default).
- CI `go-services` matrix: `fail-fast: false` + `go.mod` existence check
  so a placeholder service dir (`auth/`) doesn't cancel the other seven.

### Security
- No machine-specific paths, hardcoded account IDs, or real credentials
  in any guide content. Enforced by the `leak-scan` CI job.
- Restricted Pod Security by default everywhere; two documented
  privileged-namespace exceptions for Falco and the Cilium agent
  (see [ADR 0005](docs/adr/0005-restricted-psa-default-with-exceptions.md)).

[Unreleased]: https://github.com/abd-ulbasit/bookstore-kubernetes-guide/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/abd-ulbasit/bookstore-kubernetes-guide/releases/tag/v1.0.0
