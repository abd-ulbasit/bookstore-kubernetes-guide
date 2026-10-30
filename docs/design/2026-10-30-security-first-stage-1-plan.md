# Security-first rewrite, stage 1: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the local gate scripts and the authoring spec, rewrite three
pilot chapters (01.01, 05.02, 07.03), and project the token cost of the
whole rewrite from what those chapters measurably cost.

**Architecture:** Small standalone Python scripts under
`.github/scripts/gates/` share one manifest of extracted chapter YAML. Each
gate proves it can still fail, using a control fixture, before it trusts a
pass. Each pilot chapter runs as its own measured unit: writer, gates,
reviewer, fixes.

**Tech Stack:** Python 3.12 with PyYAML and stdlib `unittest`, Trivy v0.76.1,
kubectl v1.37.2, kind v0.33.0, GitHub Actions.

**Spec:** `docs/design/2026-10-29-security-first-rewrite.md`

## Global Constraints

- Kubernetes target 1.37; kubectl v1.37.2; Helm v3.22.1; kind v0.33.0
  (linux-amd64 sha256
  `aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d`).
- Five core checks: KSV-0012, KSV-0014, KSV-0001, KSV-0003, KSV-0030.
- Insecure marker, exact: `<!-- gate: insecure-on-purpose -->`, followed by
  a block opening `# INSECURE ON PURPOSE: <what it shows>. Lab cluster only.`
- Insecure examples only in Part 05 labs and the capstone overlay, never in
  namespace `bookstore` or `default`.
- Prose wraps at about 78 columns, never above 80 for wrapped prose. No new
  em dashes. Existing chapter filenames keep their URLs.
- Public repo: no project IDs, billing accounts, public IPs, home paths or
  personal setup details. No exam framing or syllabus language.
- Every security claim is demonstrated with captured output or cited to an
  upstream source. Never invent a version, digest, CVE or number.
- Pushing anything needs the owner's say-so. Nothing merges in this stage.

## Review Focus

1. A scanner that silently sees nothing (renamed check IDs, empty results,
   no check bundle) must abort the gate, not pass it.
2. A block Trivy or Pod Security cannot judge (a CRD-wrapped workload such
   as a Rollout, or Helm template syntax) must be reported as not evaluated
   or unparseable, never counted as a pass.
3. A multi-document block mixing a workload with a Role must be judged as a
   workload.
4. A manifest that passes every gate but crashes on a read-only root
   filesystem must be caught by the chapter's runtime step.
5. A Deployment that violates `restricted` returns only a warning and exit
   0 from a server dry-run, so a warning must count as a violation.

---

### Task 0: Branch and record the design

**Files:**
- Modify: `docs/design/2026-10-29-security-first-rewrite.md` (§7.1, §7.2)
- Create: this plan

- [ ] **Step 1:** Create `security-first/stage-1` from `chore/kubernetes-1.37`
  (from `main` if #5 has merged).
- [ ] **Step 2:** Commit the design and this plan. Do not add
  `full-guide/18-attacking-and-hardening-the-cluster/`.

### Task 1: G1, extract chapter YAML

**Files:**
- Create: `.github/scripts/gates/extract_blocks.py`
- Test: `.github/scripts/gates/test_gates.py`

**Interfaces:**
- Produces: `Block(chapter: str, index: int, line: int, klass: str,
  kinds: list[str], path: str)` where `klass` is `applyable`, `insecure` or
  `unparseable`. `classify(body: str, marked: bool) -> tuple[str, list[str]]`.
  `extract(root: Path, out: Path) -> list[Block]` writes
  `<chapter-with-__>__bNN.yaml` files and `manifest.json` into `out`.
- CLI: `extract_blocks.py --root full-guide --out DIR`.

- [ ] **Step 1: Write the failing tests** (`unittest`, temp dirs):

```python
def test_block_without_kind_is_not_gated(self):        # fragment: no Block
def test_marker_on_preceding_line_classes_insecure(self):
    # classify(POD, marked=True)[0] == "insecure"
def test_helm_template_is_unparseable(self):
    # classify("kind: Pod\nmetadata: {{ .x }}", False)[0] == "unparseable"
def test_multi_doc_reports_all_kinds(self):
    # classify(ROLE + "---\n" + POD, False)[1] == ["Role", "Pod"]
def test_indented_fence_in_list_is_dedented(self):
def test_examples_and_part_18_are_excluded(self):
```

- [ ] **Step 2:** Run `python -m unittest discover -s .github/scripts/gates`.
  Expected: FAIL, module not found.
- [ ] **Step 3:** Implement. Accept ` ```yaml ` and ` ```yml ` fences. Exclude
  `examples/` and `18-*`. The marker counts only on the nearest non-blank
  line above the fence.
- [ ] **Step 4:** Re-run. Expected: PASS. Then run the CLI on `full-guide`:
  expected 167 blocks (the count measured on `28ece01`): 134 from yaml
  fences, 32 from shell heredocs and 1 here-string that fails as an
  unextracted manifest.
- [ ] **Step 5:** Commit.

### Task 2: G2 and the marker half of G5, static gate

**Files:**
- Create: `.github/scripts/gates/static_gate.py`,
  `.github/scripts/gates/fixtures/violating-deployment.yaml`,
  `.github/scripts/gates/fixtures/hardened-deployment.yaml`
- Test: `.github/scripts/gates/test_gates.py`

**Interfaces:**
- Consumes: `manifest.json` and `Block` from Task 1.
- Produces: `CORE = ("KSV-0012", "KSV-0014", "KSV-0001", "KSV-0003",
  "KSV-0030")`; `verdict(block: Block, failed: set[str],
  high_crit: set[str]) -> tuple[str, list[str]]` with status `pass`, `fail`,
  `stale-marker` or `not-evaluated`.
- CLI: `static_gate.py --manifest M --scope CHAPTER [--scope ...]
  [--also PATH ...] [--report OUT.json]`. Exit 0 if every in-scope block
  passes, 1 on any in-scope failure, 2 if the control check fails.
  Out-of-scope results are reported only.

- [ ] **Step 1: Write the failing tests:**

```python
def test_workload_missing_a_core_check_fails(self):
    # verdict(POD_BLOCK, {"KSV-0014"}, set())[0] == "fail"
def test_marked_block_failing_a_core_check_passes(self):
    # verdict(MARKED_POD, {"KSV-0012"}, {"KSV-0012"})[0] == "pass"
def test_marked_block_passing_everything_is_stale(self):
    # verdict(MARKED_POD, set(), set())[0] == "stale-marker"
def test_crd_only_block_is_not_evaluated(self):
    # verdict(ROLLOUT_BLOCK, set(), set())[0] == "not-evaluated"
def test_role_plus_pod_is_judged_as_workload(self):
def test_non_workload_with_high_finding_fails(self):
def test_unparseable_in_scope_fails(self):
def test_real_trivy_flags_violating_and_clears_hardened(self):
    # skipUnless trivy on PATH; asserts all five CORE on the violating
    # fixture and none on the hardened one
```

- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Run `trivy config --quiet --format json` with
  severities LOW to CRITICAL. Copy `violating-deployment.yaml` into every scan
  directory and exit 2 unless it comes back with all five CORE IDs, so a
  renamed check or empty result can never read as a pass. Workload kinds:
  Pod, Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet.
- [ ] **Step 4:** Re-run. Expected: PASS.
- [ ] **Step 5:** Run over all of `full-guide` with no scope. Expected, as
  measured on `28ece01` and on HEAD once G1 reads heredocs and flow-style
  YAML: 39 pass, 33 fail and 95 not-evaluated. G2 sees a workload in 17
  chapters, and 11 of them fail all five core checks (20 of the 26 workload
  blocks do). The "17 of 20" in the design was an ad hoc count that neither
  tree reproduces. Chapters with a `containers:` list that G2 does not count
  are pod-spec fragments with no `kind:` (4, by design) and custom resources
  such as a PyTorchJob or a Rollout (5, listed as not-evaluated). A very
  different number means the gate is wrong; fix it first.
- [ ] **Step 6:** Commit.

### Task 3: G3, admission gate

**Files:**
- Create: `.github/scripts/gates/admission_gate.py`
- Test: `.github/scripts/gates/test_gates.py`

**Interfaces:**
- Consumes: `manifest.json`, both fixtures from Task 2.
- Produces: `classify_output(rc: int, out: str) -> str` returning `pass`,
  `violation`, `missing-crd` or `error`; `retarget(docs: list[dict], ns: str,
  cluster_scoped: set[str]) -> list[dict]`.
- CLI: `admission_gate.py --manifest M --scope CHAPTER [--scope ...]
  [--report OUT.json]`. Uses the ambient kubeconfig. Exit codes as in Task 2.

- [ ] **Step 1: Write the failing tests:**

```python
def test_warning_with_exit_zero_is_a_violation(self):
    # classify_output(0, 'Warning: would violate PodSecurity "restricted:latest"
    #   ...\ndeployment.apps/x created (server dry run)') == "violation"
def test_forbidden_pod_is_a_violation(self):
def test_no_matches_for_kind_is_missing_crd(self):
def test_clean_dry_run_passes(self):
def test_other_nonzero_exit_is_error(self):
def test_retarget_overrides_namespace_and_skips_cluster_scoped(self):
```

- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Create namespace `gate-restricted` labelled
  `pod-security.kubernetes.io/enforce=restricted` and `warn=restricted`.
  Server-side dry-run each applyable block, retargeted. Before trusting any
  result, exit 2 unless the violating fixture classifies as `violation` and
  the hardened one as `pass`. Skip `insecure` blocks. List `missing-crd`
  blocks as not evaluated.
- [ ] **Step 4:** Re-run the unit tests. Expected: PASS.
- [ ] **Step 5:** Create a kind v0.33.0 cluster (default node image) on a
  Docker host. Run the gate over all of `full-guide` using kubectl v1.37.2.
  Expected: the control passes and most pilot-scope blocks report violations.
- [ ] **Step 6:** Commit.

### Task 4: Authoring spec and G7 evidence check

**Files:**
- Create: `docs/security-first-authoring.md`,
  `.github/scripts/gates/evidence_gate.py`
- Modify: `Makefile`
- Test: `.github/scripts/gates/test_gates.py`

**Interfaces:**
- Produces: `output_blocks(md: str) -> list[str]` (fences right after
  `<!-- gate: output -->`); `missing_lines(block: str, transcript: str) ->
  list[str]` (order-preserving; a line equal to `# ...` is an elision);
  `leaks(text: str) -> list[str]`. Make targets `gates-test`, `gates-static`,
  `gates-admission` taking `SCOPE=`.

- [ ] **Step 1: Write the failing tests:**

```python
def test_output_present_in_order_passes(self):
def test_output_lines_out_of_order_are_missing(self):
def test_elision_line_is_allowed(self):
def test_public_ip_home_path_and_email_leak(self):
def test_private_ips_and_metadata_endpoint_do_not_leak(self):
    # 10.244.0.5, 172.18.0.2, 127.0.0.1, 169.254.169.254
```

- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement `evidence_gate.py --chapter C --transcript T`.
- [ ] **Step 4:** Re-run. Expected: PASS.
- [ ] **Step 5:** Write the spec. It is the one file every chapter worker
  reads, under 1,500 words, holding:
  - the baseline (§5.1), and the contract as a checklist (§5.2);
  - the markers, and the boundary rule (§5.6);
  - the lab evidence rule (§5.9);
  - the §5.12 rules;
  - style rules, and the gate commands.

  Add one rule: a chapter that does not exist yet is named in plain text with
  `<!-- link-later: 05.05 -->` beside it, never linked, so the strict build
  passes and a later pass can grep for them.
- [ ] **Step 6:** Commit.

### Task 5: Baseline worklist

- [ ] **Step 1:** Run G1, G2 and G3 over all of `full-guide` and keep the
  reports outside the repo.
- [ ] **Step 2:** Record for Task 9: blocks by class, failures by chapter,
  and how many blocks are `unparseable`, `not-evaluated` or `missing-crd`.

No commit.

### Task 6: Pilot, 01.01 Pods (Sonnet)

**Files:**
- Modify: `full-guide/01-core-workloads/01-pods.md`,
  `full-guide/examples/bookstore/raw-manifests/01-catalog-pod.yaml`,
  `.../02-catalog-pod-sidecar.yaml`, the "frozen" note in
  `full-guide/01-core-workloads/03-resources-and-qos.md`,
  `.github/scripts/check-runasnonroot.py` (empty the allowlist),
  `SECURITY-SCAN.md` §1.3

- [ ] **Step 1:** Rewrite to the contract. 01.01 is where the whole baseline is
  explained field by field, against the threat each field answers. Keep the
  chapter's skeleton and add `## Threats and controls`. Pin `busybox` by
  digest. The hands-on must apply into a namespace enforcing `restricted`.
- [ ] **Step 2:** Runtime check on kind: build and load `bookstore/catalog:dev`,
  apply both seeds, and confirm they reach Ready with a read-only root
  filesystem. Capture real output for the chapter.
- [ ] **Step 3:** Run `make gates-static SCOPE=01-core-workloads/01-pods.md`,
  `gates-admission` with the same scope, `check-runasnonroot.py` and
  `mkdocs build --strict`. Expected: all pass. Record first-pass results
  before fixing anything.
- [ ] **Step 4:** Reviewer (Sonnet) reads only the diff and the spec, checks the
  contract and the anti-goals. Apply confirmed findings.
- [ ] **Step 5:** Commit. Record tokens, first-pass gate results, findings and
  word delta.

### Task 7: Pilot, 05.02 Pod security and container escape (Opus)

**Files:**
- Modify: `full-guide/05-security/02-pod-security.md`
- Create: `full-guide/examples/security-lab/kind/`,
  `full-guide/examples/security-lab/labs/05-02.sh`,
  `full-guide/examples/security-lab/evidence/05-02.txt`

- [ ] **Step 1:** Write and run the lab first (§5.9): attack, harden, re-attack,
  evidence, on kind. Cover `privileged`, `hostPID`, `hostPath: /`, a mounted
  runtime socket, writing a binary into a running container, and user
  namespaces if they run on kind.
- [ ] **Step 2:** Keep every escape inside the kind node container. No payload
  may touch the Docker host. The chapter says plainly that a kind node is a
  container, so these escapes stop there. Host-kernel escapes wait for tier B
  (§5.10), which is out of this stage and is a separate line in the estimate.
- [ ] **Step 3:** Rewrite to the contract, including Pod Security levels and
  modes, the exceptions rule, and the lab header (§5.9). Each attack manifest
  carries the marker and runs in a lab namespace. Output blocks carry
  `<!-- gate: output -->`.
- [ ] **Step 4:** Run `gates-static`, `gates-admission` and `evidence_gate.py`,
  plus the strict build. Expected: all pass, with no `stale-marker`. Record
  first-pass results before fixing anything.
- [ ] **Step 5:** Reviewer (Sonnet) as in Task 6. Apply confirmed findings.
- [ ] **Step 6:** Delete the lab cluster. Commit. Record the same metrics.

### Task 8: Pilot, 07.03 CI/CD pipeline (Sonnet)

**Files:**
- Create: `.github/workflows/bookstore-pipeline.yml` (`on: workflow_call`, with
  a `service` input), `.github/workflows/bookstore-pipeline-check.yml` (the
  caller, on PRs touching `full-guide/examples/bookstore/app/**`),
  `full-guide/examples/bookstore/.pre-commit-config.yaml`,
  `full-guide/examples/bookstore/ci/fixtures/vulnerable/`
- Modify: `full-guide/examples/bookstore/ci/github-actions.yml`,
  `full-guide/07-delivery/03-cicd-pipeline.md`, the gitleaks and Trivy
  allowlists so the fixture does not trip the repo's own scans

**Interfaces:**
- Produces: stage job names `secrets`, `sast`, `sca`, `image-lint`,
  `image-scan`, `sbom`, `sign`, `manifests`, `workflow-hardening`, `dast`.

- [ ] **Step 1:** Replace the template with a thin caller of the reusable
  workflow. Stages, per §5.12:
  - Gitleaks plus TruffleHog verified mode; Semgrep, gosec and CodeQL;
  - govulncheck and Trivy, plus an update bot config; hadolint and Dockle;
  - Trivy image scan; Syft SBOM scanned by Grype and Trivy;
  - cosign keyless with SLSA provenance; KubeLinter, kubesec, Trivy config;
  - zizmor, Harden-Runner, OIDC, scoped tokens, Scorecard;
  - ZAP baseline against the service on a kind cluster.

  Actions are pinned by SHA. Conftest waits for 05.07, Kyverno verification
  for 05.03 and 05.07.
- [ ] **Step 2:** G9 negative job: each scanner runs on the vulnerable fixture
  and the job fails unless it reports the planted issue. Fake secrets must be
  obviously fake and allowlisted by exact path.
- [ ] **Step 3:** Rewrite the chapter to the contract, walking the pipeline
  stage by stage.
- [ ] **Step 4:** Local proof: `actionlint` and `zizmor` clean on both
  workflows; `gates-static` and the strict build pass; each scanner run
  locally against the fixture reports its planted issue. Record first-pass
  results.
- [ ] **Step 5:** Ask the owner before pushing. Once they agree, push the branch
  as a draft PR and let CI run the pipeline. Fix what fails, counting each
  iteration's tokens against this chapter.
- [ ] **Step 6:** Reviewer (Sonnet) as in Task 6. Commit. Record the same
  metrics.

### Task 9: Measure and project

- [ ] **Step 1:** Tabulate per chapter: model, tokens (writer, reviewer, fixes),
  words before and after, first-pass gate results, review findings.
- [ ] **Step 2:** Compute tokens per 1,000 chapter words for each kind of work:
  edit (01.01), restructure plus new writing (05.02), implementation (07.03).
- [ ] **Step 3:** Project the rest as low and high ranges by model tier, using
  the measured word counts:
  - edits: the 109 remaining chapters outside Part 05;
  - restructures: 05.01, 05.03 and 05.04;
  - new chapters: 00.08, 05.00 and 05.05 to 05.10;
  - separate lines for the compliance pass across all Parts, CI wiring of the
    gates, the tier B lab, and the rest of §5.12's stages.

  State what the numbers exclude. Give no dollar figures unless pricing is
  checked first.
- [ ] **Step 4:** Report to the owner with the three chapters to read and a
  recommendation on which model tier the scale-out should use. Stop there.
  Scaling out needs their approval (§7.3).
