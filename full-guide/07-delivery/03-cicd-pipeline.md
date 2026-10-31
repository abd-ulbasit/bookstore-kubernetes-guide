# 03 — CI/CD pipeline

> The **CI vs CD split** (CI proves an artifact good; CD makes the cluster
> match Git) and the ten stages that do the proving: secrets, SAST,
> dependency scan, image lint, image scan, SBOM, signing, manifest analysis,
> workflow hardening and DAST. One reusable GitHub Actions workflow runs them
> for each Bookstore service, a deliberately vulnerable fixture proves every
> scanner can still fail, and a last job commits the signed digests into the
> kustomize overlay so Argo CD ([ch.04](04-gitops-argocd.md)) deploys them.
> "**CI builds, CD deploys, Git is the trigger.**"

**Estimated time:** ~40 min read · ~120 min hands-on
**Prerequisites:** [Part 01 ch.01](../01-core-workloads/01-pods.md#baseline): the baseline the DAST stage runs under · [Part 05 ch.03](../05-security/03-supply-chain.md): scan, sign, verify; CI is where these get enforced · [Part 07 ch.02](02-packaging-kustomize.md): the overlays CI bumps digests in · [Part 00 ch.02](../00-foundations/02-containers-and-images.md): tags vs immutable digests
**You'll know after this:** • split CI (proves the artifact good) from CD (makes the cluster match Git) · • run the ten pipeline stages in order and say what each one catches and misses · • prove a scanner can still fail, so a clean result means something · • sign an image keyless, with the SBOM and provenance attached to its digest · • protect the pipeline itself: pinned actions, scoped tokens, a workflow linter · • bump kustomize overlay digests from a workflow and let Argo CD deploy them

<!-- tags: ci-cd, gitops, supply-chain, platform-engineering, security, devsecops -->

## Why this exists

[ch.01](01-packaging-helm.md) and [ch.02](02-packaging-kustomize.md) made the
Bookstore **packageable**. [Part 05 ch.03](../05-security/03-supply-chain.md)
made an image **trustworthy**: a scan, an SBOM, a keyless signature, and a
Kyverno policy that would require a digest and a verified signature. That
policy ships in **Audit**, because the guide's own `bookstore/<SVC>:dev`
images are tag-based and unsigned, and Enforce would blackhole the cluster.

Two gaps remain:

1. **Who runs build, scan, sign and push, the same way every time?** By hand
   on a laptop that is "works on my machine": unpinned tools, no record,
   secrets in shell history. **CI** is an automated, audited pipeline that
   takes source and **proves an artifact good**.
2. **How does a good artifact become a running Pod without a human typing
   `kubectl apply`?** That is **CD**: the cluster is continuously made to
   match Git. The **seam** between them is a **commit**: CI's last act bumps
   the deployment source, and [ch.04](04-gitops-argocd.md)'s Argo CD
   reconciles it.

CI is also the most privileged thing near your code. It reads the source,
holds a registry token, mints signing identities and decides what ships;
whoever owns the pipeline owns every image it produces. So the pipeline here
is something to **defend** as well as something that defends: it scans the
code, the images and the manifests, and it scans the workflow files that run
it. What it hands the cluster is a digest, a signature, an SBOM and a
provenance statement, which is what an Enforce policy needs to check. Turning
Enforce on is a separate decision, taken where the policy lives (05.07
<!-- link-later: 05.07 -->).

## Mental model

**CI and CD are two machines joined by Git, not one script.**

- **CI = "is this artifact good?"** Input: source. Output: an **immutable,
  signed image referenced by digest** plus evidence (scan reports, SBOM,
  signature in Rekor). CI **never touches the cluster**; its last step writes
  the new digest into **Git**.
- **CD = "does the cluster match Git?"** An in-cluster controller
  ([ch.04](04-gitops-argocd.md)'s Argo CD) renders the overlay, diffs and
  reconciles, triggered by **the commit CI made**.
- **The artifact is pinned by content, not by name.** `bookstore/catalog:dev`
  is a *mutable pointer*; `…@sha256:<HASH>` **is** the content, because the
  registry and the kubelet verify the bytes hash to exactly that. CI signs the
  *digest*; CD deploys the *digest*.
- **The pipeline is a set of gates that fail closed, and a gate that finds
  nothing is not a gate that works.** A scanner with renamed rules, a database
  that failed to load or a target path that moved reports "clean" just as
  happily. So each scanner also runs against a deliberately vulnerable
  [fixture](../examples/bookstore/ci/fixtures/vulnerable/README.md) and must
  report what was planted there. The signing job waits for every other job,
  so a signed digest is one whose whole run was green. Two jobs only report:
  Harden-Runner in audit mode and Scorecard stop nothing.
- **Prefer no long-lived secret.** Cosign **keyless** trades a short-lived
  OIDC token for a certificate that lives minutes; the registry push uses the
  run's own token, not a stored PAT. A fork PR gets neither.

The trap: a pipeline that *deploys by reaching into the cluster* (a
`kubectl apply` with a long-lived kubeconfig secret) couples CI to CD, makes
cluster state un-auditable and hands every job cluster-admin-shaped
credentials. **Push to Git, let the cluster pull**, as in
[ch.04](04-gitops-argocd.md).

## Threats and controls

A pipeline turns source into a running workload, so each stage answers a way
that step can go wrong. The last four rows are about the pipeline itself.

| Threat | Control taught here | Goes deeper |
|---|---|---|
| A credential is committed and lives in history | Gitleaks and TruffleHog verified mode read every commit in CI, and Gitleaks also runs in pre-commit; keyless OIDC, so there is little to leak | [03.02](../03-config-and-storage/02-secrets.md), [15.05](../15-day-to-day-production-ops/05-production-secrets-vault-eso.md) |
| Your own code carries an injection or a weak primitive | Semgrep with the Bookstore's rules, gosec, CodeQL | [15.02](../15-day-to-day-production-ops/02-application-cicd-pipelines.md) |
| A dependency you ship or call is vulnerable | govulncheck (what you call), Trivy (what you ship), Dependabot (the fix) | [05.03](../05-security/03-supply-chain.md) |
| The image runs as root, hides a secret or sits on an end-of-life base | hadolint, Dockle, Trivy on the image | [05.03](../05-security/03-supply-chain.md), [00.02](../00-foundations/02-containers-and-images.md) |
| Nobody can say what is inside an image when a CVE lands | A Syft SBOM, scanned by Grype and Trivy | [05.03](../05-security/03-supply-chain.md) |
| The image in the registry is not the one CI built, or is one that failed a gate | Push once, and only after every other job passed; sign the digest keyless; attach SLSA provenance | [15.03](../15-day-to-day-production-ops/03-image-signing-and-provenance.md) |
| A manifest asks for more than the baseline allows | KubeLinter, kubesec and Trivy config on the rendered overlay | [01.01](../01-core-workloads/01-pods.md#baseline), policy as code in 05.07 <!-- link-later: 05.07 --> |
| The running service leaks through its responses | ZAP baseline against it on a throwaway kind cluster | [15.02](../15-day-to-day-production-ops/02-application-cicd-pipelines.md) |
| The pipeline is the attack: an injectable expression, a tag that moves, a token that can do too much | SHA-pinned actions, per-job `permissions`, zizmor and actionlint fail the build. Harden-Runner (audit mode) and Scorecard only report | [15.02](../15-day-to-day-production-ops/02-application-cicd-pipelines.md) |
| A scanner goes quiet and every build passes | A control per scanner against the vulnerable fixture | this chapter |
| An accepted exception outlives its reason | Every exception carries a date; Trivy enforces its own, and an expiry check enforces the rest | this chapter |
| CI holds a cluster credential | CI proposes a PR; the in-cluster controller applies it | [07.04](04-gitops-argocd.md) |

This chapter makes the signatures and the evidence. It does not make the
cluster ask for them: checking a signature at admission (Kyverno
`verifyImages`, with the identity from step 8) is a separate control that
arrives with 05.07 <!-- link-later: 05.07 -->. The Audit policy from 05.03
reports a Pod whose image is unsigned and blocks nothing. So what you can rely
on after this chapter is that a signed digest came from this workflow with
every gate green. It is not a guarantee that an unsigned image cannot run.

## Diagrams

### The pipeline for one service, then the seam (Mermaid)

The reusable workflow `.github/workflows/bookstore-pipeline.yml` runs the
stages below for one service, plus a `build-test` job (`go build`, `go vet`,
`go test`) that is not a security stage. `manifests`, `workflow-hardening`
and `dast` run beside the chain. `sign` waits for all of them, so one red job
anywhere means nothing is pushed and nothing is signed. The dashed boundary is
the CI/CD seam: CI ends at a **commit**, and the cluster's Argo CD
([ch.04](04-gitops-argocd.md)) pulls from there.

```mermaid
flowchart TD
    push["git push / pull request<br/>(the trigger)"]
    bt["build-test<br/>go build, vet, test"]
    secrets["secrets<br/>Gitleaks + TruffleHog verified,<br/>every commit"]
    sast["sast<br/>Semgrep, gosec, CodeQL"]
    sca["sca<br/>govulncheck, Trivy"]
    lint["image-lint<br/>hadolint, build once, Dockle"]
    scan["image-scan<br/>Trivy on the tar"]
    sbom["sbom<br/>Syft -&gt; Grype + Trivy"]
    side["manifests, workflow-hardening, dast<br/>KubeLinter, zizmor, expiry, ZAP on kind"]
    sign["sign (push to main only)<br/>needs every job above green<br/>push, cosign keyless,<br/>SBOM + SLSA provenance"]
    fail["FAIL the build<br/>nothing pushed, nothing signed"]
    bump["bump-manifests<br/>kustomize edit set image<br/>-&gt; promotion PR"]
    git[("Git repo<br/>kustomize/overlays/prod<br/>(PR merged by a human)")]
    argo["Argo CD in-cluster<br/>detects commit -&gt; diff<br/>-&gt; sync -&gt; reconcile"]

    push --> bt & secrets & sast & sca & lint & side
    lint --> scan & sbom
    bt & secrets & sast & sca & scan & sbom & side -- "all pass, or skipped on purpose" --> sign
    bt & secrets & sast & sca & scan & sbom & side -- "any finding" --> fail
    sign --> bump --> git
    git -. "CI/CD seam: CI proposes, human merges, CD pulls" .-> argo
```

### Environment promotion (ASCII)

```
 build once  ──►  ONE signed digest  ──►  promoted, never rebuilt
      ├─ overlays/dev      latest main digest   (auto-sync, ch.04)
      ├─ overlays/staging  same digest, prod shape at half scale
      └─ overlays/prod     SAME digest, written by `kustomize edit set
                           image` in a PR (a human merges it)
 Promotion = a reviewed COMMIT moving a digest between overlays, not a
 rebuild: a rebuild is a different artifact, bits you never tested.
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).** You need
Docker; the last stage also needs a kind cluster and the image from
[Part 00 ch.02](../00-foundations/02-containers-and-images.md). The output
below was recorded on one Linux machine and is committed as
[`evidence/07-03.txt`](../examples/security-lab/evidence/07-03.txt).
Vulnerability counts drift as the databases move, and ZAP's crawl can see a
response one time more or less; the verdict lines do not.

The pipeline is two workflow files and one script:

- `.github/workflows/bookstore-pipeline.yml` is the reusable workflow: one
  job per stage, for one service. The stage names below are its job names.
- [`ci/github-actions.yml`](../examples/bookstore/ci/github-actions.yml) is
  the thin caller a Bookstore repo copies. It fans out over the four services
  and adds `bump-manifests`. GitHub only runs workflows from
  `.github/workflows/`, so a real repo copies both files there.
- [`ci/scan.sh`](../examples/bookstore/ci/scan.sh) runs one scanner from a
  container image **pinned by digest**. The workflow calls it and so do you,
  so the command on your laptop is the command in CI.

> **Honesty note.** The guide's own pull-request CI runs four things that no
> laptop can: CodeQL, the ZAP baseline on a kind cluster, Harden-Runner in
> audit mode, and the permission ceiling. Each is reported where it appears
> below. Push, keyless signing, the SBOM attestation, provenance, the
> promotion PR and Scorecard need a registry, GitHub's OIDC token or the
> default branch. The release workflow `bookstore-release.yml` is how they run,
> and it has not been dispatched yet, so they are real, valid steps that this
> chapter **reads, not runs**, and the `if:` that lets `sign` run is read the
> same way. Dependabot is not run either. Every other stage runs below.
> `<OWNER>` stands for your GitHub user or organization.

### 0. The scanner runner

```sh
scan=examples/bookstore/ci/scan.sh
mkdir -p scan-out
```

Every stage is `$scan TOOL TARGET`. Exit 0 means clean and the script prints
one line saying so; the scanner's own output lands in `scan-reports/`.
`$scan --expect ID TOOL TARGET` is a **control**: it passes only if the
scanner flags the target *and* its report contains `ID`. Each stage ends with
a control against the
[`vulnerable` fixture](../examples/bookstore/ci/fixtures/vulnerable/README.md),
a service that is broken on purpose. Those steps are labelled **deliberate**.

### 1. Pre-commit: the cheapest gate, on your machine

The first reader of a change is your own laptop. Three hooks (Gitleaks,
hadolint, gosec) in
`examples/bookstore/.pre-commit-config.yaml`
run before a commit exists, so a leaked token never reaches history, which a
force-push cannot fully clean. Two hooks run the pinned scanner images; gosec
builds at its pinned version.

```sh
pip install -q pre-commit==4.7.0
rm -rf /tmp/bookstore
cp -R examples/bookstore /tmp/bookstore && rm -rf /tmp/bookstore/ci/fixtures   # stands in for your repo
(cd /tmp/bookstore && git init -q && git add -A && pre-commit run --all-files)
```

<!-- gate: output -->

```text
gitleaks.................................................................Passed
hadolint.................................................................Passed
gosec....................................................................Passed
```

**Deliberate.** Stage a file that holds a token-shaped string, built at
run time so this page holds no token. The hook fails, and installed as a
commit hook it would stop the commit:

```sh
(cd /tmp/bookstore \
  && printf 'GITHUB_TOKEN=ghp_%s\n' "$(printf 'NOTAREALTOKEN%.0s' 1 2 3)" > .env \
  && git add .env && pre-commit run gitleaks)
rm -rf /tmp/bookstore
```

<!-- gate: output -->

```text
gitleaks.................................................................Failed
- hook id: gitleaks
- exit code: 1
# ...
RuleID:      github-pat
# ...
File:        .env
```

A hook is a convenience, not a gate. It does nothing until someone runs
`pre-commit install`, and `git commit --no-verify` skips it. The gate is the
`secrets` job in the next step, which runs on the server and not on the
author's machine.

### 2. `secrets`: Gitleaks and TruffleHog

A secret in Git is a secret in every clone, and deleting the file does not
unpublish it ([Part 03 ch.02](../03-config-and-storage/02-secrets.md)). Two
scanners, because they fail differently. **Gitleaks** matches the *shape* of a
credential, so it catches a token the day it is committed, live or not.
**TruffleHog's verified mode** asks the issuing service whether the
credential still works and reports only live ones, so it can fail a build
with almost no false positives. It stays quiet about a key already revoked.

Each runs in two modes. The first reads the **files on disk**, which suits the
code in front of you:

```sh
$scan gitleaks examples/bookstore/app
$scan trufflehog examples/bookstore/app
```

<!-- gate: output -->

```text
scan.sh: gitleaks clean on examples/bookstore/app
scan.sh: trufflehog clean on examples/bookstore/app
```

**Deliberate.** The fixture holds two fake tokens. Without the repo's
allowlist Gitleaks refuses it. TruffleHog in verified mode does not, because a
fake token never verifies:

```sh
$scan gitleaks examples/bookstore/ci/fixtures/vulnerable; echo "exit $?"
jq -r '.[] | "\(.RuleID) \(.File)"' scan-reports/gitleaks.json
$scan trufflehog examples/bookstore/ci/fixtures/vulnerable
```

<!-- gate: output -->

```text
scan.sh: gitleaks flagged examples/bookstore/ci/fixtures/vulnerable (exit 1, report scan-reports/gitleaks.json)
exit 1
github-pat examples/bookstore/ci/fixtures/vulnerable/config.env
scan.sh: trufflehog clean on examples/bookstore/ci/fixtures/vulnerable
```

So the TruffleHog control turns verification off, to show the detectors still
match:

```sh
$scan --expect github-pat gitleaks examples/bookstore/ci/fixtures/vulnerable
$scan --expect Github trufflehog examples/bookstore/ci/fixtures/vulnerable
```

<!-- gate: output -->

```text
scan.sh: control ok, gitleaks reported github-pat on examples/bookstore/ci/fixtures/vulnerable
scan.sh: control ok, trufflehog reported Github on examples/bookstore/ci/fixtures/vulnerable
```

The second mode, `gitleaks-history` and `trufflehog-history`, reads **every
commit**. The files on disk cannot show a token that one commit added and the
next deleted, and that token is still in every clone. The pipeline's `secrets`
job checks out with `fetch-depth: 0` so there is a history to read, and runs
only these two. Here is the case they exist for. `make-history.sh` builds a
throwaway repository whose first commit holds two fake tokens, assembled at
run time, and whose second commit deletes them:

```sh
examples/bookstore/ci/fixtures/make-history.sh scan-out/history
$scan gitleaks scan-out/history
$scan gitleaks-history scan-out/history; echo "exit $?"
```

<!-- gate: output -->

```text
scan.sh: gitleaks clean on scan-out/history
scan.sh: gitleaks-history flagged scan-out/history (exit 1, report scan-reports/gitleaks-history.json)
exit 1
```

**Deliberate.** `gitleaks` passed and `gitleaks-history` failed on the same
repository: that gap is the point. TruffleHog's history mode is quiet here for
the reason it was quiet above, since a fake token never verifies, so its
control turns verification off:

```sh
$scan trufflehog-history scan-out/history
$scan --expect github-pat gitleaks-history scan-out/history
$scan --expect Github trufflehog-history scan-out/history
```

<!-- gate: output -->

```text
scan.sh: trufflehog-history clean on scan-out/history
scan.sh: control ok, gitleaks-history reported github-pat on scan-out/history
scan.sh: control ok, trufflehog-history reported Github on scan-out/history
```

### 3. `sast`: Semgrep, gosec and CodeQL

Static analysis reads source for patterns that become bugs. **Semgrep** runs
the Bookstore's own rules,
[`ci/semgrep/bookstore.yml`](../examples/bookstore/ci/semgrep/bookstore.yml),
local files that need no network or account. **gosec** knows Go's pitfalls
(weak hashes, shell calls, missing server timeouts). **CodeQL** follows data
across functions, which the other two cannot; it runs only on GitHub's
runners, and the job counts its SARIF so a fork PR still gets the gate. It
has run there for each Go service (CodeQL CLI 2.27.3) and reported no results.

```sh
$scan semgrep examples/bookstore/app
$scan gosec examples/bookstore/app/catalog
```

<!-- gate: output -->

```text
scan.sh: semgrep clean on examples/bookstore/app
scan.sh: gosec clean on examples/bookstore/app/catalog
```

**Deliberate.** Both must flag the fixture, and name the planted rule:

```sh
$scan --expect bookstore-sql-string-concat semgrep examples/bookstore/ci/fixtures/vulnerable
$scan --expect G202 gosec examples/bookstore/ci/fixtures/vulnerable
jq -r '.Issues[] | "\(.rule_id) \(.details)"' scan-reports/gosec.json | sort -u
```

<!-- gate: output -->

```text
scan.sh: control ok, semgrep reported bookstore-sql-string-concat on examples/bookstore/ci/fixtures/vulnerable
scan.sh: control ok, gosec reported G202 on examples/bookstore/ci/fixtures/vulnerable
# ...
G202 SQL string concatenation
G204 Subprocess launched with a potential tainted input or cmd arguments
G401 Use of weak cryptographic primitive
```

### 4. `sca`: govulncheck and Trivy

A dependency is a stranger's code you ship. **govulncheck** reports only
vulnerabilities your code can reach ("do I call it?"). **Trivy** lists every
vulnerable module in `go.mod` ("do I ship it?"). Dependabot
([`ci/dependabot.yml`](../examples/bookstore/ci/dependabot.yml); how it works:
the
[GitHub docs](https://docs.github.com/en/code-security/dependabot/dependabot-version-updates/about-dependabot-version-updates))
opens the pull request that moves the version, and the pipeline runs on that
PR. This chapter does not run it.

```sh
$scan govulncheck examples/bookstore/app/catalog
$scan trivy-fs examples/bookstore/app/catalog
```

<!-- gate: output -->

```text
scan.sh: govulncheck clean on examples/bookstore/app/catalog
scan.sh: trivy-fs clean on examples/bookstore/app/catalog
```

**Deliberate.** The fixture pins `x/text` v0.3.6 and calls into it. The
control also shows what *reachable* means: govulncheck names the call.

```sh
$scan --expect GO-2021-0113 govulncheck examples/bookstore/ci/fixtures/vulnerable
grep -E 'GO-2021-0113|calls language' scan-reports/govulncheck.txt | head -4
$scan --expect CVE-2021-38561 trivy-fs examples/bookstore/ci/fixtures/vulnerable
```

<!-- gate: output -->

```text
scan.sh: control ok, govulncheck reported GO-2021-0113 on examples/bookstore/ci/fixtures/vulnerable
      #1: main.go:21:45: vulnerable.main calls language.ParseAcceptLanguage
Vulnerability #2: GO-2021-0113
  More info: https://pkg.go.dev/vuln/GO-2021-0113
      #1: main.go:21:45: vulnerable.main calls language.ParseAcceptLanguage
scan.sh: control ok, trivy-fs reported CVE-2021-38561 on examples/bookstore/ci/fixtures/vulnerable
```

### 5. `image-lint`: hadolint, then Dockle

**hadolint** reads the Dockerfile before anything is built. Then the image is
built **once, as a tar**, and every later stage reads that tar, so the image
you scan is the image you sign. **Dockle** reads the built image: the user it
runs as, credential-looking names in its environment, setuid files.

```sh
docker build -q -t bookstore/catalog:dev examples/bookstore/app/catalog >/dev/null
docker save -o scan-out/catalog.tar bookstore/catalog:dev
$scan hadolint examples/bookstore/app/catalog/Dockerfile
$scan dockle scan-out/catalog.tar
```

<!-- gate: output -->

```text
scan.sh: hadolint clean on examples/bookstore/app/catalog/Dockerfile
scan.sh: dockle clean on scan-out/catalog.tar
```

**Deliberate.** Build the fixture image the same way and let both flag it:

```sh
docker build -q -t bookstore/vulnerable:fixture -f examples/bookstore/ci/fixtures/vulnerable/vulnerable.Dockerfile examples/bookstore/ci/fixtures/vulnerable >/dev/null
docker save -o scan-out/vulnerable.tar bookstore/vulnerable:fixture
$scan --expect DL3002 hadolint examples/bookstore/ci/fixtures/vulnerable/vulnerable.Dockerfile
$scan --expect CIS-DI-0001 dockle scan-out/vulnerable.tar
```

<!-- gate: output -->

```text
scan.sh: control ok, hadolint reported DL3002 on examples/bookstore/ci/fixtures/vulnerable/vulnerable.Dockerfile
scan.sh: control ok, dockle reported CIS-DI-0001 on scan-out/vulnerable.tar
```

### 6. `image-scan`: Trivy on the image

The distroless Go images carry almost no packages, so the scan is normally
clean by construction. That minimal base **is** a supply-chain control: what
is not in the image cannot be vulnerable. `ignore-unfixed` is on, for the
reason under [How it works](#how-it-works-under-the-hood).

```sh
$scan trivy-image scan-out/catalog.tar
```

<!-- gate: output -->

```text
scan.sh: trivy-image clean on scan-out/catalog.tar
```

**Deliberate.** The fixture's base is an end-of-life Alpine:

```sh
$scan --expect CVE-2022-37434 trivy-image scan-out/vulnerable.tar
```

<!-- gate: output -->

```text
scan.sh: control ok, trivy-image reported CVE-2022-37434 on scan-out/vulnerable.tar
```

### 7. `sbom`: Syft, then Grype and Trivy

An SBOM answers "what is inside this digest?" long after the build, the
question you get the day a new CVE lands. **Syft** writes a CycloneDX
inventory; **Grype** and **Trivy** each scan it. Two scanners on purpose: they
read different vulnerability data, and where they disagree is worth a look.

```sh
$scan syft scan-out/catalog.tar
$scan grype scan-reports/sbom.cdx.json
$scan trivy-sbom scan-reports/sbom.cdx.json
```

<!-- gate: output -->

```text
scan.sh: syft clean on scan-out/catalog.tar
scan.sh: grype clean on scan-reports/sbom.cdx.json
scan.sh: trivy-sbom clean on scan-reports/sbom.cdx.json
```

**Deliberate.** The fixture's inventory, scanned by both:

```sh
$scan syft scan-out/vulnerable.tar
$scan --expect CVE-2021-38561 grype scan-reports/sbom.cdx.json
$scan --expect CVE-2021-38561 trivy-sbom scan-reports/sbom.cdx.json
```

<!-- gate: output -->

```text
scan.sh: syft clean on scan-out/vulnerable.tar
scan.sh: control ok, grype reported CVE-2021-38561 on scan-reports/sbom.cdx.json
scan.sh: control ok, trivy-sbom reported CVE-2021-38561 on scan-reports/sbom.cdx.json
```

### 8. `sign`: push, keyless signature, SBOM, provenance (read, not run)

This job runs only on a push to `main`, and only when **every other job**
passed. It loads the tar, pushes it, **reads the digest the registry computed**
and signs that digest. `actions/attest-build-provenance` then adds a **SLSA
provenance** statement for the same digest.

"Every other job" is the whole `needs` list: `build-test`, `secrets`, `sast`,
`sca`, `image-lint`, `image-scan`, `sbom`, `manifests`, `workflow-hardening`
and `dast`. GitHub skips a job whose `needs` include a skipped job unless its
`if` says otherwise
([`needs`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds)),
and four of these are skipped on purpose: `secrets`, `manifests` and
`workflow-hardening` look at the whole repository, so only one leg of the
matrix runs them, and `dast` is off for `payments-worker`, which has no web
surface. So `sign` opens with `always()` and then asks for the result itself:
`success` from the six jobs that always run, and `success` or `skipped` from
those four. A failed job, a cancelled one, or one skipped because `image-lint`
failed all leave the image unpushed and unsigned. An earlier version waited
for the two image scans only, so a build that failed Gitleaks, Semgrep or the
ZAP baseline was still pushed and signed.

One boundary remains. The repository-wide jobs run on the `catalog` leg, and
the other legs' `sign` jobs do not wait for them. If one of those jobs fails,
the other services' digests can still be signed, but the `pipeline` run is red
and `bump-manifests`, which needs every leg, opens no promotion PR. A signature
says that service's own gates passed. The promotion PR says all of them did.

```sh
cosign sign --yes "$REF"                                       # REF = image@sha256:<DIGEST>
cosign attest --yes --type cyclonedx --predicate sbom.cdx.json "$REF"
```

The job alone asks for `id-token: write`. What a *consumer* runs, and what
05.07 <!-- link-later: 05.07 --> turns into an admission rule, checks the
identity, not just the signature
([`cosign verify`](https://docs.sigstore.dev/cosign/verifying/verify/)):

```sh
cosign verify \
  --certificate-identity 'https://github.com/<OWNER>/<REPO>/.github/workflows/bookstore-pipeline.yml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/<OWNER>/bookstore-catalog@sha256:<DIGEST>
```

The identity is the whole string, branch included, and it is matched exactly
rather than as a pattern. The branch matters because the `if:` that guards
`sign` lives in the workflow file: anyone who can push a branch can add a
caller that passes `publish: true`, and its signature would name
`@refs/heads/<their-branch>`. A match that stops at the file name accepts it.
This one does not. It is also only as strong as who can write to `main`; see
the Production notes. The identity names the reusable workflow's file because
that job requests the token.

This is the one stage with no run here; its first proof is the first CI run
on a repo with a registry.

### 9. `manifests`: KubeLinter, kubesec, Trivy config

Three readers of the **rendered** production overlay, because that is what
Argo CD applies. They overlap on purpose: KubeLinter checks shape, kubesec
scores Pod specs, and Trivy config checks its misconfiguration library, whose
five core checks are the baseline from
[Part 01 ch.01](../01-core-workloads/01-pods.md#baseline). Conftest policies
join them with 05.07 <!-- link-later: 05.07 -->.

```sh
kubectl kustomize examples/bookstore/kustomize/overlays/prod > scan-reports/prod-overlay.yaml
$scan kube-linter scan-reports/prod-overlay.yaml
$scan kubesec scan-reports/prod-overlay.yaml
$scan trivy-config scan-reports/prod-overlay.yaml
```

<!-- gate: output -->

```text
scan.sh: kube-linter clean on scan-reports/prod-overlay.yaml
scan.sh: kubesec clean on scan-reports/prod-overlay.yaml
scan.sh: trivy-config clean on scan-reports/prod-overlay.yaml
```

**Deliberate.** A privileged Pod with a host mount and a `latest` tag:

```sh
$scan --expect KSV-0017 trivy-config examples/bookstore/ci/fixtures/vulnerable/deployment.json
$scan --expect privileged-container kube-linter examples/bookstore/ci/fixtures/vulnerable/deployment.json
$scan --expect Privileged kubesec examples/bookstore/ci/fixtures/vulnerable/deployment.json
```

<!-- gate: output -->

```text
scan.sh: control ok, trivy-config reported KSV-0017 on examples/bookstore/ci/fixtures/vulnerable/deployment.json
scan.sh: control ok, kube-linter reported privileged-container on examples/bookstore/ci/fixtures/vulnerable/deployment.json
scan.sh: control ok, kubesec reported Privileged on examples/bookstore/ci/fixtures/vulnerable/deployment.json
```

### 10. `workflow-hardening`: zizmor, actionlint, expiry, Harden-Runner, Scorecard

The pipeline holds a registry token and a signing identity, so its own YAML
is a target. **zizmor** finds injectable `${{ }}` expressions, unpinned
actions and over-broad permissions; **actionlint** finds mistakes that make a
workflow misbehave. The third check reads the pipeline's own exception lists:
every accepted finding carries a `Revisit by` date, and the check fails when a
date has passed, when an entry has none, or when it finds no entries at all.
Step 13 says why it is needed. All three run from the repository root, above
`full-guide/`.

```sh
cd ..
scan=full-guide/examples/bookstore/ci/scan.sh
$scan zizmor ".github/workflows/bookstore-pipeline.yml .github/workflows/bookstore-pipeline-check.yml"
$scan actionlint ".github/workflows/bookstore-pipeline.yml .github/workflows/bookstore-pipeline-check.yml"
$scan expiry "full-guide/examples/bookstore/ci/zap/baseline.conf full-guide/examples/bookstore/ci/kube-linter.yaml"
```

<!-- gate: output -->

```text
scan.sh: zizmor clean on .github/workflows/bookstore-pipeline.yml .github/workflows/bookstore-pipeline-check.yml
scan.sh: actionlint clean on .github/workflows/bookstore-pipeline.yml .github/workflows/bookstore-pipeline-check.yml
scan.sh: expiry clean on full-guide/examples/bookstore/ci/zap/baseline.conf full-guide/examples/bookstore/ci/kube-linter.yaml
```

**Deliberate.** The fixture's workflow pastes a PR title into a shell script
on a privileged trigger, and its exception list has one entry whose date
passed in 2020 and one with no date:

```sh
$scan --expect template-injection zizmor full-guide/examples/bookstore/ci/fixtures/vulnerable/bad-workflow.yml
$scan --expect 'potentially untrusted' actionlint full-guide/examples/bookstore/ci/fixtures/vulnerable/bad-workflow.yml
$scan --expect 'lapsed on 2020-01-01' expiry full-guide/examples/bookstore/ci/fixtures/vulnerable/exceptions.conf
$scan --expect 'no Revisit by DATE' expiry full-guide/examples/bookstore/ci/fixtures/vulnerable/exceptions.conf
```

<!-- gate: output -->

```text
scan.sh: control ok, zizmor reported template-injection on full-guide/examples/bookstore/ci/fixtures/vulnerable/bad-workflow.yml
scan.sh: control ok, actionlint reported potentially untrusted on full-guide/examples/bookstore/ci/fixtures/vulnerable/bad-workflow.yml
scan.sh: control ok, expiry reported lapsed on 2020-01-01 on full-guide/examples/bookstore/ci/fixtures/vulnerable/exceptions.conf
scan.sh: control ok, expiry reported no Revisit by DATE on full-guide/examples/bookstore/ci/fixtures/vulnerable/exceptions.conf
```

Two more tools sit in the pipeline's jobs, and neither gates the build.
Harden-Runner has run in the guide's own CI. Scorecard has not, because it
runs only on the default branch. What is said about both of them here comes
from their documentation, except where it says a run showed it.

- **Harden-Runner** is the first step of every job, in `egress-policy: audit`.
  Per its [documentation](https://docs.stepsecurity.io/harden-runner), audit
  mode logs outbound traffic without blocking it, and each job links to the
  resulting insights. The one thing it blocks in audit mode is StepSecurity's
  list of domains tied to active supply-chain attacks. So a compromised step
  that sends the job's token to any other host gets through, and you find out
  afterwards, if you look. What limits the damage a stolen token can do is
  the narrow `permissions` and the SHA pins, not this. Its `block` mode
  refuses every host that is not in `allowed-endpoints`, and that list has to
  come from recorded runs of your own jobs. A run showed why: in the ZAP job
  the audit log recorded ZAP's Java process resolving `news.zaproxy.org`,
  `cfu.zaproxy.org` and `tel.zaproxy.org`, hosts a block-mode list would have
  to carry or ZAP's own options would have to switch off. The pipeline ships
  in `audit`; once you have a few green runs, the switch is:

  ```yaml
  - uses: step-security/harden-runner@<SHA> # <release>
    with:
      egress-policy: block
      allowed-endpoints: >
        <each host:port the audit runs recorded>
  ```

- **Scorecard** grades the repository's habits (branch protection, pinned
  dependencies, token permissions; the list of
  [checks](https://github.com/ossf/scorecard#scorecard-checks)) and runs on
  the default branch only. It produces a score and fails nothing.

Go back into `full-guide/` and reset the variable for the last stage:

```sh
cd full-guide
scan=examples/bookstore/ci/scan.sh
```

### 11. `dast`: the ZAP baseline on a throwaway cluster

Everything so far read files. **DAST** reads a running service. The ZAP
*baseline* crawls the URL and reads the responses for missing or leaky
headers; it sends no attack traffic, so it is safe on every PR. The pipeline
starts the image on a kind cluster, in a namespace that enforces Pod Security
`restricted` and denies all traffic by default, with the baseline from
[Part 01 ch.01](../01-core-workloads/01-pods.md#baseline). Do the same with
the catalog Pod from that chapter. The scan needs no allow rule, because a
port-forward is carried by the kubelet into the Pod, not across the Pod
network, so the default-deny policy leaves it alone:

```sh
kubectl create namespace dast
kubectl label namespace dast pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
kubectl apply --namespace dast -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
kubectl create serviceaccount catalog-sa --namespace dast
kind load docker-image bookstore/catalog:dev --name bookstore
kubectl apply --namespace dast -f examples/bookstore/raw-manifests/01-catalog-pod.yaml
kubectl wait --namespace dast --for=condition=Ready pod/catalog --timeout=90s
```

<!-- gate: output -->

```text
namespace/dast created
namespace/dast labeled
networkpolicy.networking.k8s.io/default-deny created
serviceaccount/catalog-sa created
Image: "bookstore/catalog:dev" with ID "sha256:ed20b252119884dbb2d045629c2333e6c2d48c9660d98b0ed2ea5518cec66be2" not yet present on node "bookstore-control-plane", loading...
pod/catalog created
pod/catalog condition met
```

Scan it through a port-forward, which takes a moment to start answering, so
`curl` retries until it does. The run is clean, yet the report is not
empty: the baseline raised three rules on the catalog, and
[`ci/zap/baseline.conf`](../examples/bookstore/ci/zap/baseline.conf) lists
each as INFO with a reason and a revisit date (see the table below). Any rule
not listed still fails the build.

```sh
kubectl --namespace dast port-forward pod/catalog 8080:8080 >/dev/null &
curl --silent --fail --retry 15 --retry-delay 1 --retry-all-errors --output /dev/null http://127.0.0.1:8080/books
$scan zap http://127.0.0.1:8080/books
grep -E '^(FAIL-NEW|WARN-NEW|INFO)' scan-reports/zap.log
```

<!-- gate: output -->

```text
scan.sh: zap clean on http://127.0.0.1:8080/books
INFO: X-Content-Type-Options Header Missing [10021] x 1 
INFO: Storable and Cacheable Content [10049] x 4 
INFO: Cross-Origin-Resource-Policy Header Missing or Invalid [90004] x 1 
FAIL-NEW: 0     FAIL-INPROG: 0  WARN-NEW: 0     WARN-INPROG: 0  INFO: 3 IGNORE: 0       PASS: 65
```

**Deliberate.** The fixture serves a session cookie without `HttpOnly`. Run
it and point the same scan at it:

```sh
docker run -d --name fixture -p 127.0.0.1:18080:8080 bookstore/vulnerable:fixture >/dev/null
curl --silent --fail --retry 15 --retry-delay 1 --retry-all-errors --output /dev/null http://127.0.0.1:18080/books
$scan --expect 10010 zap http://127.0.0.1:18080/books
grep -E '^(FAIL-NEW|WARN-NEW|INFO)' scan-reports/zap.log
docker rm -f fixture >/dev/null
```

<!-- gate: output -->

```text
scan.sh: control ok, zap reported 10010 on http://127.0.0.1:18080/books
INFO: Missing Anti-clickjacking Header [10020] x 1 
INFO: X-Content-Type-Options Header Missing [10021] x 1 
INFO: Content Security Policy (CSP) Header Not Set [10038] x 1 
INFO: Storable and Cacheable Content [10049] x 3 
INFO: Permissions Policy Header Not Set [10063] x 1 
INFO: Cross-Origin-Embedder-Policy Header Missing or Invalid [90004] x 3 
WARN-NEW: Cookie No HttpOnly Flag [10010] x 1 
WARN-NEW: Cookie without SameSite Attribute [10054] x 1 
WARN-NEW: Session Management Response Identified [10112] x 1 
FAIL-NEW: 0     FAIL-INPROG: 0  WARN-NEW: 3     WARN-INPROG: 0  INFO: 6 IGNORE: 0       PASS: 59
```

### 12. The seam: from signed digest to Git (local approximation)

`bump-manifests` is the only job that writes to Git, and it writes a **pull
request**, not a push. You can run what it does against a placeholder digest
(it needs the standalone `kustomize` binary):

```sh
cd examples/bookstore/kustomize/overlays/prod
kustomize edit set image \
  bookstore/catalog=ghcr.io/<OWNER>/bookstore-catalog@sha256:0000000000000000000000000000000000000000000000000000000000000000
git diff kustomization.yaml     # THIS diff is what Argo CD would sync
git checkout -- kustomization.yaml
cd ../../../../..               # back to full-guide/
```

That edit and a merge are the whole "deploy". CI holds no cluster
credential. The job installs kustomize from a pinned release **and checks its
sha256**, then opens the PR with `peter-evans/create-pull-request`. Require a
review by branch protection, or the bot can merge its own promotion.

### 13. What the first run found

A pipeline that is green on day one has usually been tuned to be. This one was
run first and then dispositioned. Each decision is written down with its
reason, and each one that accepts a risk carries a date:

| Stage | First-run finding | Disposition |
|---|---|---|
| `image-scan`, `sbom` | The storefront's `nginx:1.27-alpine` base carried many fixable HIGH and CRITICAL CVEs | **Fixed**: base moved to `nginx:1.30-alpine`, pinned by digest |
| `image-scan`, `sbom` | `nginx:1.30-alpine` still shipped curl and libcurl, and Grype listed several curl CVEs that Trivy did not | **Fixed**: the Dockerfile removes both, since nothing depends on them |
| `image-scan`, `sbom` | A CRITICAL in brotli-libs, fixed by Alpine but not yet in the nginx image | Accepted until 2026-11-30 in `ci/trivyignore.yaml` and `ci/grype.yaml`; Trivy fails again on that date |
| `image-lint` | Dockle read `KEY_SHA512` in nginx's build script as a secret | Accepted in `scan.sh`: it is the checksum of nginx's public key |
| `manifests` | KubeLinter: `no-anti-affinity` on orders, `job-ttl-seconds-after-finished` on the cleanup CronJob | Excluded in `ci/kube-linter.yaml`: availability and operations, not the baseline |
| `dast` | Nine ZAP rules across catalog, orders and storefront | Accepted as INFO in `ci/zap/baseline.conf` |

Dates are enforced in two ways, and only two. Trivy honors `expired_at` itself,
so the brotli-libs entry stops applying on its date and the build goes red
again. The ZAP list and the KubeLinter exclusions have no expiry of their own,
and a bare `Revisit by` comment would let an INFO rule stay INFO for ever. So
the `expiry` check from step 10 reads those dates and fails the build the day
after one passes, and it fails an entry that has no date. Grype's ignore rule
has no date either; it is the same finding as Trivy's, and both files say to
delete the two entries together. Any rule not listed still fails the build.

### 14. How the guide's CI runs it

`.github/workflows/bookstore-pipeline-check.yml` calls the reusable workflow
on every PR that touches the services, the `ci/` directory or the pipeline
itself, once per service. Beside it, a matrix of **controls** runs every
scanner above through `scan.sh --expect` against the fixture. Both halves
matter: the first says the services are clean, the second says "clean" can
still be believed.

## How it works under the hood

- **CI's job is evidence, not deployment.** Each stage emits a verifiable
  fact: an exit code, a scan report, an SBOM, a **Rekor** entry (the signature
  in an append-only public log) and a **SLSA provenance** statement (who built
  it, from what, how). An admission policy can then decide trust on its own.
  The cluster never sees CI; it sees the registry and Git.
- **The registry computes the digest.** A push uploads layers and a manifest,
  and the registry returns `sha256:<hash over the manifest>`. It changes only
  if the bytes change. Cosign signs *that string*, and a kubelet pulling
  `name@sha256:…` re-verifies the bytes against it.
- **Scan first, push after.** The image is built once as a tar and every
  stage reads that tar. Only `sign` pushes, and `sign` waits for every other
  job, so an image that fails any gate (the secret, SAST, dependency, manifest
  and DAST jobs as well as the two image scans) is never pushed. The earlier
  version of this workflow pushed first and scanned the pushed digest, which
  left a pullable vulnerable image behind on every failed run. The price: the
  digest exists only after the push, so signature and SBOM bind to the
  registry's manifest of the *same layers and config* that were scanned, not
  to bytes scanned one for one.
- **`ignore-unfixed` is a taught tradeoff, and its cost is not paid by
  anything here.** It drops CVEs with no upstream fix. A rebuild cannot
  remediate those, so gating on them blocks every build for nothing. But the
  scan runs when an image is built, and **this pipeline never looks at a
  published image again**: a fix that lands after the push does not flag the
  digest already in `overlays/prod`. Two things narrow the gap. Dependabot
  checks each base image weekly and opens a pull request when it moves, and
  the pipeline runs on that PR. And the SBOM that `sbom` keeps for 90 days answers "is this digest
  affected?" on the day a CVE lands. Rescanning what is deployed, on a
  schedule, belongs with vulnerability management (05.09
  <!-- link-later: 05.09 -->). Set `ignore-unfixed` to `false` for the
  stricter gate.
- **Keyless signing has no key.** The platform mints a short-lived **OIDC**
  token naming the workflow identity. Cosign sends it to **Fulcio**, which
  issues a certificate that lives about ten minutes for a fresh key, then the
  key is discarded. Cosign signs the digest and records signature and
  certificate in **Rekor**. Verification checks the signature, the certificate
  identity against the *expected* workflow and issuer, and the Rekor entry.
  A fork PR cannot get a usable token, hence `publish` runs only on a push to
  `main`.
- **An action tag is a pointer anyone with write access can move.** In March
  2026 the version tags of a widely used scanner action were force-pushed to
  malicious commits (GHSA-69fq-xp46-6x23); only a commit SHA was safe. Every
  `uses:` here is a full SHA with the release in a comment, and Dependabot,
  not a human, moves the pin. GitHub's hardening guide gives the same advice.
- **Permissions are narrowed twice.** The reusable workflow starts from
  `permissions: {}` and each job asks for what it needs; the caller's job sets
  the ceiling, and GitHub checks it even for skipped jobs. `id-token: write`
  therefore exists only on `sign`. A throwaway workflow showed the check: it
  called this pipeline with `publish: false` and a ceiling of `contents: read`
  and `actions: read`, and GitHub refused to start the run
  (`startup_failure`) because `sign`, though skipped, asks for more. The same
  call with `packages`, `id-token` and `attestations` write started normally.
- **No layer cache in the publishing workflow.** A cache restored from an
  earlier run is input no reviewer saw, and zizmor's `cache-poisoning` audit
  warns about cache reads in release workflows. The build starts cold and is
  a minute or two slower.

## Production notes

> **In production: CI must never hold cluster credentials.** The common
> anti-pattern is a `kubectl apply` or `helm upgrade` step with a long-lived
> kubeconfig secret. CI's last step is a **commit**; a pull-based controller
> ([ch.04](04-gitops-argocd.md)) alone applies. If you must push, use a
> short-lived, namespace-scoped, OIDC-federated credential, never a static
> admin kubeconfig.

> **In production: protect `main`.** The signing identity in step 8 ends in
> `@refs/heads/main`, so whoever can push to `main` can sign, and whoever can
> merge the promotion PR can deploy. Require a review and the pipeline's
> checks with a ruleset on `main`, and keep the number of people who can bypass
> it small. Scorecard reports whether you have.

## Quick Reference

```sh
scan=examples/bookstore/ci/scan.sh       # from full-guide/; pinned images, Docker only
mkdir -p scan-out
$scan gitleaks examples/bookstore/app    # secrets in the files (trufflehog: same arguments)
$scan gitleaks-history .                 # secrets in EVERY commit; run at a git repo root (trufflehog-history: same)
$scan semgrep  examples/bookstore/app    # SAST (gosec, govulncheck: per Go module)
$scan trivy-fs examples/bookstore/app/catalog                 # dependencies
docker build -t bookstore/catalog:dev examples/bookstore/app/catalog
docker save -o scan-out/catalog.tar bookstore/catalog:dev
$scan dockle scan-out/catalog.tar        # image lint (hadolint: the Dockerfile)
$scan trivy-image scan-out/catalog.tar   # image scan, exit 1 on HIGH/CRITICAL
$scan syft scan-out/catalog.tar && $scan grype scan-reports/sbom.cdx.json
# $scan --expect ID TOOL TARGET runs a control: it must flag the target AND name ID
```

The CI to GitOps seam, as `bump-manifests` runs it (placeholder digest):

```sh
cd examples/bookstore/kustomize/overlays/prod
kustomize edit set image bookstore/catalog=ghcr.io/<OWNER>/bookstore-catalog@sha256:<DIGEST>
git add kustomization.yaml && git commit -m "ci: bump catalog digest"   # Argo CD (ch.04) syncs this
```

The shape of a Bookstore repo's caller (full file:
[`ci/github-actions.yml`](../examples/bookstore/ci/github-actions.yml)):

```yaml
name: bookstore-ci
on: { push: { branches: [main] }, pull_request: { branches: [main] } }
permissions: {}
jobs:
  pipeline:                       # the stages, once per service
    strategy: { matrix: { service: [catalog, orders, payments-worker, storefront] } }
    permissions: { contents: read, actions: read, packages: write, id-token: write, attestations: write }
    uses: ./.github/workflows/bookstore-pipeline.yml
    with: { service: "${{ matrix.service }}", publish: "${{ github.event_name == 'push' }}" }
  bump-manifests:                 # THE SEAM: digests into the overlay, as a PR
    needs: pipeline
    if: github.event_name == 'push'
    permissions: { contents: write, pull-requests: write }
    # download digest-* -> pinned, checksum-verified kustomize -> edit set image -> PR
```

Checklist:

- [ ] Every gating stage fails the build, and each scanner has a **control**
      that fails if it stops finding the planted issue; Harden-Runner in
      audit mode and Scorecard only report
- [ ] The secret scanners read **every commit** (`fetch-depth: 0`), not only
      the files on disk
- [ ] `sign` **waits for every other job**, with `always()` and an explicit
      check of each result, so a skipped job on purpose is not a failure
- [ ] Scan the built tar first; **push by digest** only after every gate passes
- [ ] **Cosign keyless** signature, SBOM and provenance on the pushed digest;
      no long-lived key or stored PAT; publish skipped on fork PRs
- [ ] Every `uses:` is a **commit SHA**; `permissions: {}` at the top, scoped
      per job; zizmor and actionlint clean; Harden-Runner on every job,
      moved from `audit` to `block` once its allowlist is recorded
- [ ] Every accepted exception has a **date that something enforces**
      (Trivy's `expired_at`, or the `expiry` check)
- [ ] `cosign verify` names the **exact identity, branch included**
- [ ] CI holds **no cluster credential**; its last step is a **pull request**
      that bumps the kustomize `images:` digest
- [ ] Promotion = the **same digest** moved overlay to overlay by reviewed
      commit; **never a rebuild**

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **The chapter insists "CI builds, CD deploys, Git is the trigger." Restate
   that as three actions the CI pipeline does and three it does *not* do.**
   <details><summary>Show answer</summary>

   **CI does**: (1) build and test the source, (2) scan, sign and push the
   image *by digest*, (3) commit the new digest into the GitOps source
   (`kustomize edit set image`). **CI does not**: (1) hold a kubeconfig or any
   cluster credential, (2) run `kubectl apply` or `helm upgrade`, (3) decide
   when to deploy; the commit triggers CD. The boundary moves from "every CI
   job has prod's keys" to "CI can open a PR; the in-cluster controller
   applies it".

   </details>

2. **A junior engineer asks "where is the private key?" about the keyless
   signature. Give the one-sentence answer, and say what you verify instead.**
   <details><summary>Show answer</summary>

   There is none: Fulcio issues a certificate that lives about ten minutes for
   a key that exists only for that run, and signature, certificate and
   identity go into the Rekor log. You verify the *identity*: the certificate
   must name this repository's pipeline workflow on `main` and the GitHub OIDC
   issuer (`cosign verify --certificate-identity … --certificate-oidc-issuer
   https://token.actions.githubusercontent.com`). A valid signature from any
   other identity, or from the same workflow on another branch, is not
   trusted.

   </details>

3. **Hands-on extension: run `$scan trufflehog` on the fixture directory, then
   `$scan --expect Github trufflehog` on it. Why does the first pass while the
   second reports a secret, and which result tells you the scanner works?**
   <details><summary>What you should see</summary>

   Verified mode asks GitHub whether each token is live. The fixture's tokens
   are fake, so none verifies and the first run is clean, exactly as on a real
   repo whose old tokens are revoked. The control turns verification off, so
   the detectors report the pattern. Only the control shows the scanner still
   *sees*; a clean verified run cannot tell "nothing live" from "scanner
   broken", which is why the pipeline runs both.

   </details>

4. **A scan job has been green for months. Name two ways it could be green
   because the scanner is blind, and the check this chapter uses against
   both.**
   <details><summary>Show answer</summary>

   A renamed or removed rule ID (the scanner reports other findings, or none),
   and a target that moved or is empty (it reads nothing and reports clean).
   The check is the control: run the scanner on the vulnerable fixture and
   require a non-zero exit *and* the planted rule ID in the report. `scan.sh
   --expect ID` does this, so a quiet, crashed or renamed scanner fails the
   control instead of passing the real services by saying nothing.

   </details>

5. **Promotion from staging to prod is "moving the same digest between
   overlays, never a rebuild." Why is rebuilding for prod a bad pattern?**
   <details><summary>Show answer</summary>

   A rebuild produces a *different* image (layer timestamps, dependency
   resolution if the build is not perfectly reproducible). Staging's tests and
   every scan ran against image A, and prod would run image B, so you have no
   evidence that prod's bits passed your gates or carry your signature.
   **Build once, scan once, sign once, promote the artifact.**

   </details>

6. **A pull request adds a token in its first commit and deletes it in its
   second. A scan of the checked-out files is green. Which job fails, what
   does that do to the image, and what must still be done about the token?**
   <details><summary>Show answer</summary>

   The `secrets` job fails, because it checks out the full history
   (`fetch-depth: 0`) and runs `gitleaks-history` and `trufflehog-history`,
   which read every commit; the files on disk no longer hold the token, but
   the first commit does. Since `sign` waits for every other job, a red
   `secrets` job means nothing is pushed or signed from that run. The scan
   does not undo the exposure: the token is in every clone of the branch, so
   revoke it first. Deleting it from the tree does not unpublish it.

   </details>

7. **`sign` lists ten jobs under `needs` and begins its `if:` with
   `always()`. Without `always()`, which builds would never be signed, and
   which failure would `always()` alone let through if the explicit result
   checks were left out?**
   <details><summary>Show answer</summary>

   Without `always()`, `sign` is skipped whenever any needed job is skipped.
   `secrets`, `manifests` and `workflow-hardening` are skipped on every leg but
   one, and `dast` is skipped for `payments-worker`, so those services would
   never be signed. With `always()` and no result checks, `sign` would run
   after a failed `sast` or `dast` job too, which is the original bug: a build
   that failed a gate would still be pushed and signed. The explicit checks ask
   for `success` from the jobs that always run and `success` or `skipped` from
   the four that may be skipped.

   </details>

## Further reading

- **Davis, _Bootstrapping Microservices with Docker, Kubernetes, and
  Terraform_ (Manning, 2021), ch.7–8, automated testing and the continuous
  delivery pipeline.** The narrative this chapter's pipeline follows, from
  commit to running service.
- **Rosso et al., _Production Kubernetes_, ch.15, Software Supply Chain.**
  Build, scan, sign and admit as a production pipeline, and where the CI
  artifact meets the admission policy.
- Official and project docs: GitHub Actions security hardening
  <https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions>,
  Sigstore Cosign keyless
  <https://docs.sigstore.dev/cosign/signing/overview/>, SLSA provenance
  <https://slsa.dev/spec/v1.0/provenance>, TruffleHog
  <https://github.com/trufflesecurity/trufflehog>, govulncheck
  <https://go.dev/doc/security/vuln/>, the ZAP baseline scan
  <https://www.zaproxy.org/docs/docker/baseline-scan/>, zizmor
  <https://docs.zizmor.sh/>, StepSecurity Harden-Runner
  <https://docs.stepsecurity.io/harden-runner>, OpenSSF Scorecard
  <https://github.com/ossf/scorecard>, GitHub's `needs` reference for jobs
  that depend on skipped jobs
  <https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds>,
  `cosign verify` <https://docs.sigstore.dev/cosign/verifying/verify/>, and
  the Kubernetes image reference
  (digests vs tags, pull policy)
  <https://kubernetes.io/docs/concepts/containers/images/>.
