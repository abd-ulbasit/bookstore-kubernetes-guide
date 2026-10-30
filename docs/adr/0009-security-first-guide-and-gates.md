# 0009: Security-first guide, no unlearning, one exceptions registry, gates in CI

* **Status:** Accepted
* **Date:** 2026-10-31
* **Deciders:** abd-ulbasit
* **Extends:** [0005](0005-restricted-psa-default-with-exceptions.md)

## Context

The guide taught the easy form first and the hardened form later. A reader
met a Pod that runs as root in Part 01 and learned in Part 05 that it was
wrong. Everything in between was a habit to reverse. A safe form that
arrives late is also easy to skip: the early chapters are the ones people
copy.

CI did not catch this. The scanners in `security-scan.yml` exit 0 on any
finding, and `trivy-action` drops the `severity` filter when it writes
SARIF. No job created or connected to a cluster, so a manifest that breaks
under `restricted` was never admitted anywhere. Accepted findings lived in
the prose of `SECURITY-SCAN.md`, and parts of that prose had gone stale.
ADR 0005 kept the list of privileged namespaces honest for Terraform, but a
namespace created by a chapter or a Helm install fell outside it.

Three more forces shaped the decision.

* **Kubernetes 1.35, which the guide pinned, reaches upstream end of life
  on 2027-02-28**, in the middle of a rewrite of this size. 1.37 is the
  current minor, and several features the security chapters teach changed
  state in 1.36 and 1.37.
* **The repository is public** and every merge to `main` publishes the site.
  Whatever lands must keep the site working and must carry no private
  identifier.
* **The cost of cloud labs.** A cluster on a cloud account costs money and
  can be left running. The owner ruled out clusters on AWS and GCP for the
  length of this rewrite.

## Decision

**We will rewrite the guide security-first, and enforce it with gates that
run on real GitHub runners.** The shape of the change:

1. **No unlearning.** The guide never shows a manifest, command or
   practice in a form it later calls wrong. The first Pod the reader
   writes carries the baseline (non-root user, `readOnlyRootFilesystem`,
   `allowPrivilegeEscalation: false`, all capabilities dropped, the
   `RuntimeDefault` seccomp profile, no automounted ServiceAccount token),
   and so does every later workload. A control that needs concepts the
   reader has not met arrives with them: a NetworkPolicy needs Services
   and labels, so it arrives in Part 02, and the earlier chapters name the
   open risk and where it closes. Adding a control is learning. Reversing
   a habit is unlearning, and only that is forbidden. The rules are in
   `docs/security-first-authoring.md`, and the reasoning in
   `docs/design/2026-10-29-security-first-rewrite.md`.

2. **Insecure examples are marked, confined and checked both ways.** A
   deliberately insecure block appears only in the Part 05 labs and the
   capstone overlay. It opens with `# INSECURE ON PURPOSE: <what it
   shows>. Lab cluster only.`, is preceded in the Markdown by
   `<!-- gate: insecure-on-purpose -->`, and runs in a namespace its lab
   creates and labels, never `bookstore` or `default`. A marked block that
   stops failing breaks CI, and so does an unmarked block that fails.

3. **One registry holds every exception, and it extends ADR 0005.** ADR 0005
   limited privileged namespaces to those named in Terraform. That rule now
   covers every namespace the guide creates, wherever it is created: a
   chapter, a Helm install, a lab. The registry has two files.
   `security/namespace-exceptions.yaml` lists each namespace above
   `restricted` with its level, its reason, an upstream citation where the
   upstream project demands the privilege, the chapter that explains it
   and an expiry date at most 12 months out. `.trivyignore.yaml` lists
   each accepted scanner finding with its paths, a statement and an
   `expired_at` date. A third-party component runs in its own namespace,
   labelled before the install, at the lowest level it works under. An
   inline `trivy:ignore` comment or any other ignore file is a failure.
   `SECURITY-SCAN.md` keeps the reasoning and points at the registry.

4. **The gates are code, and each one is checked in CI.**

   | Gate | What it does | Where it runs |
   |---|---|---|
   | G1 | extracts every manifest a reader applies | `extract_blocks.py` |
   | G2 | Trivy's five core checks plus a parsed-YAML check, on chapters and example trees | `static` job |
   | G3 | server-side dry run into a `restricted` namespace; a PodSecurity warning fails | `admission` job, on kind |
   | G4 | deploys the Bookstore five ways into `restricted` namespaces and waits for every workload | `runtime` jobs, on kind |
   | G5 | the registry, both ways: every exception is used, every use has an entry, nothing has expired | `registry` job |
   | G7 | every output block in a chapter appears in its lab transcript | `evidence` job |
   | G9 | the Bookstore delivery pipeline runs against the example services | `bookstore-pipeline-check.yml` |

   The chapter gates (G2, G3) run in report mode while the rewrite is in
   progress. A chapter that fails is listed in the run summary and does not
   fail the job, unless it is named in `.github/security-gates-enforced.txt`.
   A chapter is added to that list in the pull request that finishes it, so
   it cannot regress. A gate that cannot trust itself exits 2 and always
   fails the job. The unit tests, the registry, the evidence check and the
   runtime gate never run in report mode.

5. **Target Kubernetes 1.37.** The toolchain is pinned to kind v0.33.0 with
   the `kindest/node` 1.37.0 image by digest, kubectl 1.37.2 and Helm
   3.22.1. kind is the one local cluster the guide verifies on. Every
   version-gated claim is checked against the release notes of the pinned
   patch.

6. **No clusters on AWS or GCP during this rewrite.** Local kind clusters,
   the author's own hardware and CI runners are the lab. A chapter whose
   subject kind cannot show truthfully cites the upstream source and says it
   was not run. It never implies it ran. This is a rule about spending, not
   about CI: a throwaway kind cluster on a GitHub runner costs nothing and
   is how G3 and G4 work. The Terraform trees stay validated but are not
   applied.

## Consequences

* **Good:** the first manifest a reader copies is a safe one. A regression
  in a finished chapter fails the pull request that causes it.
* **Good:** the list of exceptions is one place, machine-checked, and every
  entry expires. A stale entry is a CI failure, not a stale paragraph.
* **Good:** the gates run on real runners, so the numbers in the guide do not
  depend on one laptop.
* **Bad:** every chapter is longer. The baseline adds a block of
  `securityContext` fields where the old form had none, and a chapter may not
  hide that behind "omitted for brevity".
* **Bad:** the gates cost CI time. The runtime gate builds four images and
  starts one kind cluster per deployment form, and G3 starts another.
* **Bad:** report mode means a red chapter does not turn the PR red. The
  enforced list is how that is kept honest, and it is only as good as the
  habit of extending it.
* **Follow-ups:**
  * The cluster-wide `restricted` default lands last, after every Part
    complies (chapter 00.07).
  * `hostUsers: false` joins the baseline only when it is verified on kind
    on Linux and macOS hosts.
  * The pipeline's signing, provenance and promotion steps are proven by
    dispatching `bookstore-release.yml` on `main`, not by a pull request.
  * Revisit the no-cloud rule when the rewrite ends. A kubeadm lab on cloud
    VMs can then be added, with a bounded cost and a scripted teardown.

## Alternatives considered

* **Keep the guide as it was and add a security Part.** The two Parts that
  teach the insecure form first would still be the ones people copy.
* **A hardening appendix.** Rejected for the same reason, and because an
  appendix is where exceptions go to be forgotten.
* **Fail the build on any chapter that fails a gate, from day one.** The
  pull request would stay red until the last chapter was rewritten, and a
  red PR gets ignored. Report mode with an enforced list gives the guard
  without the noise.
* **Trust Trivy's own `.trivyignore.yaml` handling.** Trivy v0.76.1 marks
  the feature experimental and does not load the file by itself, so G5
  reads it and applies only sound, unexpired entries.
* **Tier B labs on a cloud account.** Ruled out for this rewrite; see the
  decision above.
* **Keep Kubernetes 1.35.** It reaches end of life during the rewrite.

## References

* `docs/security-first-authoring.md`: the rules every chapter follows.
* `docs/design/2026-10-29-security-first-rewrite.md`: the design and its
  reasoning.
* `.github/workflows/security-gates.yml` and
  `.github/security-gates-enforced.txt`.
* [ADR 0005](0005-restricted-psa-default-with-exceptions.md), which this
  extends.
* Kubernetes documentation: Pod Security Standards and Pod Security
  Admission.
