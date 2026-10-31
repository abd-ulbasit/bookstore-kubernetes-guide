# Security-first authoring spec

Every chapter worker reads this file. The reasoning is in the
[design](design/2026-10-29-security-first-rewrite.md); this page holds only
the rules. A chapter, rewritten or new, is done when it meets section 2 and
the gates in section 8 pass.

## 1. The baseline

Every workload carries this in full, from 01.01 onward. 01.01 explains each
field against the threat it answers. Later chapters link back to it and do
not re-explain.

```yaml
spec:
  automountServiceAccountToken: false # true only with a dedicated SA
  securityContext:
    runAsNonRoot: true
    runAsUser: <the numeric UID the image declares>
    runAsGroup: <its GID>
    fsGroup: <its GID>                # only when a volume needs it
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: <image>
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources: {}                   # requests and a memory limit, per 01.03
      volumeMounts:
        - name: tmp
          mountPath: /tmp             # writable paths come from emptyDir
  volumes:
    - name: tmp
      emptyDir: {}
```

- **Images.** Third-party images are pinned by digest from their first
  appearance, with the tag in a comment. The guide's own locally built
  images use the tag the build produced.
- **ServiceAccount.** A workload that calls the API gets its own
  ServiceAccount with least-privilege RBAC. Nothing uses `default`.
- **Namespace.** Pod Security labels at `restricted`. From 02.06 on, a
  default-deny NetworkPolicy plus explicit allows.
- **User namespaces.** `hostUsers: false` joins the baseline only once it is
  verified on kind on Linux and macOS hosts. Until then 05.02 teaches it.
- **Cluster.** 00.07 builds a kind cluster whose default CNI enforces
  NetworkPolicy. It does not yet set `restricted` as the cluster-wide default:
  it runs plain `kind create cluster`, and Pod Security applies per namespace,
  through labels. The cluster-wide default is a follow-up that lands last, after
  every Part complies. Every Part is now enforced, so what remains is the
  change itself: a kind config that mounts an AdmissionConfiguration for the
  PodSecurity plugin, and a check that a bare Pod in a new namespace is refused.

## 2. The chapter contract

- [ ] Every manifest the reader applies is complete and carries the
  baseline. Nothing is "omitted for brevity". A block showing a few fields
  has no `kind:` and reads clearly as a fragment.
- [ ] `## Threats and controls` follows `## Mental model`: a short table of
  the threat, the control this chapter teaches, and where the topic goes
  deeper. Only threats specific to the subject. If there are none, say so in
  one sentence.
- [ ] A hardening field is explained where it first appears.
- [ ] Hands-on uses only the secure form. Where the chapter teaches a
  control, it shows the control working, for example a request that is
  denied. A step that shows a failure is labelled as a deliberate action.
- [ ] Security items sit in the body, not in a Production notes afterthought.
- [ ] The Quick Reference shows secure forms only.
- [ ] Test your understanding has at least one question on the chapter's
  security dimension.
- [ ] Every security claim is demonstrated with output captured in the
  chapter, or cited to an upstream source: Kubernetes docs, the project's
  docs, a CVE or an advisory.
- [ ] Every third-party install labels its namespace first, at the lowest
  Pod Security level the component works under, and sets the chart's
  security values where it exposes them. If privilege is needed only for an
  optional feature, turn the feature off. Any exception goes in the one
  exceptions registry with its reason, its chapter and an expiry within 12
  months.

## 3. Markers

Tools read three HTML comments. Spell them exactly.

**Insecure on purpose.** Only in Part 05 labs and the capstone overlay, and
never in namespace `bookstore` or `default`. The lab creates and labels its
own namespace for the privilege it needs. The gates enforce the chapter half
of this: a marked block outside the `05-security/` chapters fails, and so
does a marked workload in namespace `bookstore`, `default` or none.

````markdown
<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: <what it shows>. Lab cluster only.
apiVersion: v1
kind: Pod
```
````

The marker must be the nearest non-blank line above the fence. The check
runs both ways: a marked block that stops failing (a stale marker) breaks
CI, and so does an unmarked block that fails.

**Output.** `<!-- gate: output -->` above a fence of captured output. Every
line must appear in the lab transcript, in order and consecutively. Mark
lines you left out with a line equal to `# ...`. A block must keep at least
one real line. Any other comment that starts `<!-- gate:` fails, so a
misspelt marker cannot leave output unchecked.

**Link later.** A chapter that does not exist yet is named in plain text
with `<!-- link-later: 05.05 -->` beside it, never linked. The strict build
passes, and `.github/scripts/check_link_later.py` (run by `make validate-links`
and by the docs workflow) fails a marker whose chapter now exists, so the
reference has to become a link.

## 4. Part 05 and the boundary rule

Part 05 teaches the mechanism and proves it on a lab cluster. Parts 10, 11,
13, 14 and 15 teach running it in production on a cloud. Where both touch a
topic, Part 05 owns the concept and the attack, the later chapter owns the
operations, and each links to the other.

| Part 05 | Production counterpart |
|---|---|
| 05.01 | 10.03, 13.04 |
| 05.03 | 14.12, 15.03 |
| 05.04 | 11.05, 15.05 |
| 05.07 | 11.01 |
| 05.08 | 14.13, 15.10 |

## 5. Lab evidence

- **Lab first.** No lab chapter is written before its lab has run. Every
  command in it comes from a terminal that executed it.
- **Tier.** Tier A is kind on the reader's machine. Tier B is kubeadm on
  Compute Engine, for what kind cannot show truthfully. Each lab chapter
  states its tier at the top and says to run it only against clusters you
  own. Only the declared tier counts as evidence.
- **Header.** What ran, on which tier and versions. For tier B, the cost
  from the billing export, not an estimate. What did not work the first time.
- **Transcripts.** Runs are scripted and recorded. The redacted transcript is
  committed under `full-guide/examples/security-lab/evidence/`, with no
  public IPs, home paths, emails or cloud identifiers.

## 6. DevSecOps in the projects

- **One default tool per job**, implemented in the project. Alternatives get
  a line on when to pick them instead. If two tools share a job on purpose,
  say why.
- **Controls arrive with their concepts.** A tool is first run locally in
  the chapter that introduces it. 07.03 assembles the pipeline, and every
  later chapter adds its stage to that pipeline, not a side example.
- **The pipeline is a reusable workflow** that the guide's own CI runs
  against the example services, so a stage that stops working fails the
  build.

## 7. Style

- Wrap prose at about 78 columns, never above 80.
- No new em dashes. Existing chapter filenames keep their URLs.
- Never invent a version, digest, CVE or number. Take it from captured
  output or an upstream source.
- This is a public repo: no project IDs, billing accounts, public IPs, home
  paths or personal setup details.
- The guide never presents itself as preparation for any test. No test-prep
  framing and no course-outline language.
- Add no example or demo files unless a chapter needs them.

## 8. Gate commands

Run from the repository root with Python 3.12 and PyYAML. `PY=` picks the
interpreter. `SCOPE=` takes chapters or chapter directories relative to
`full-guide/`, for example `SCOPE=01-core-workloads/01-pods.md`.

| Command | Checks | Needs |
|---|---|---|
| `make gates-test` | the gate scripts' unit tests | Trivy, Helm and kubectl, so their tests cannot skip |
| `make gates-static SCOPE=...` | G1, G2: five core checks | Trivy 0.76.1; Helm and kubectl for a whole-guide run |
| `make gates-registry` | G5: the exceptions registry, both ways | Helm and kubectl; Trivy once a scanner entry exists |
| `make gates-admission SCOPE=...` | G1, G3: `restricted` dry-run | kind v0.33.0 cluster, kubectl v1.37.2 |
| `python .github/scripts/gates/evidence_gate.py --chapter C --transcript T` | G7 | the lab transcript |
| `python .github/scripts/check-runasnonroot.py` | existing check | |
| `mkdocs build --strict` | existing check | |

**What G1 extracts.** Every manifest a reader applies: a `yaml` or `yml`
fence (block, flow or JSON style), the body of each shell heredoc, and a
fence such as `json` that is a manifest as a whole. A fence of another
language that still shows a bare `kind:` outside a heredoc, for example a
here-string, is a manifest nobody gated, so it fails. Captured output that
shows a manifest goes under `<!-- gate: output -->`, which exempts it.

**What G2 adds to Trivy.** Trivy reads a null `securityContext` as clean and
takes a pod-level `runAsNonRoot: true` at face value. The gate therefore
also checks the parsed YAML: a null or non-mapping `securityContext`, a
container that sets `runAsNonRoot: false`, and `runAsUser: 0` all fail. Three
control fixtures prove that check still sees each of them. G2 also scans
`full-guide/examples` in a whole-guide run (no `SCOPE`). A scoped run scans
none unless `ALSO=` names them. An `--also` path that is missing, or holds no
YAML manifest, aborts the run.

**How G2 reads the example trees.** A file is unparseable only if YAML itself
cannot read it, so `{{ }}` inside a string (Argo, Prometheus, Backstage) is
fine and the failure names the line. Raw files under a Helm chart's
`templates/` are not YAML until rendered, so G2 skips them and scans the
chart as `helm template` renders it, once with the default values and once
for each `values-*.yaml`. It builds each Kustomize overlay with
`kubectl kustomize` (a base or a component is covered through the overlays
that use it) and judges the result. A chart or overlay that fails to render is
a failure, and a missing `helm` or `kubectl` aborts the run, because skipping
what it renders would let it pass unread.

**What G5 checks.** Two files hold every exception, and `make gates-registry`
checks each against the tree in both directions. `.trivyignore.yaml` holds
scanner findings: `id`, `paths`, `statement` and `expired_at`.
`security/namespace-exceptions.yaml` holds namespaces above `restricted`:
`namespace`, `level`, `reason`, `upstream`, `chapter` and `expires`. An entry
needs a reason and a date that is still ahead and no more than 12 months out.
Every `pod-security.kubernetes.io/{enforce,audit,warn}` label set to
`baseline` or `privileged`, in a chapter or an example tree, needs an entry
at that level, and every entry must still be in use. A scanner entry must
still match a finding when Trivy runs without the ignore file. Trivy v0.76.1
does not load `.trivyignore.yaml` on its own, so `make gates-static` reads it
and drops a finding only for a sound, unexpired entry; an unsound entry
grants nothing. An inline `trivy:ignore` comment, or any other Trivy ignore
file, is a failure: the registry is the only place to accept a finding. The
control fixtures are checked before any entry applies, so no entry can blind
the gate. Write a label where the gate can attach it to a namespace: in a
Namespace manifest, a `kubectl label` command or a Terraform namespace.

**What G3 refuses.** G3 creates the `gate-restricted` namespace, so it runs
only against a kubectl context that starts with `kind-`. Any other context
needs `ALLOW_CONTEXT=NAME`. It prints the context before it writes.

**A registered namespace is judged at its registered level.** A block whose
namespaced documents all name one namespace, which has a sound entry in
`security/namespace-exceptions.yaml` that names the block's own chapter, is
dry-run in `gate-baseline` or `gate-privileged` instead, and a clean result is
reported as `registered`. Everything else stays at `restricted` and fails as
before: the same namespace used from another chapter, a workload that breaks
the registered level (a privileged Pod in a `baseline` namespace), an
unregistered namespace, an expired or unsound entry, a namespace registered
twice, and a block that also reaches another namespace or none. Keep an
excepted agent in a block of its own.

The five core checks are KSV-0012, KSV-0014, KSV-0001, KSV-0003 and
KSV-0030.

### Exit codes

Each script exits 0 for a pass, 1 for an in-scope failure and 2 when it
could not trust itself. The 1 and 2 split holds only when you run the
scripts directly. `make` cannot carry it: GNU Make exits 2 for any failed
recipe, whatever the script returned, and shows the script's own code only
in its `Error 1` or `Error 2` line. Read that line, or run the script
yourself, to tell a failure from an abort.

Exit 2 means "there was nothing to check, or the check cannot be trusted":

- a control fixture was not seen, or the cluster does not enforce Pod
  Security;
- a `SCOPE` or an `--also` path matched nothing, or the guide held no
  manifest at all (the extractor itself exits 2);
- no in-scope block was judged: every one was `not-evaluated` (G2), or
  skipped or `missing-crd` (G3);
- G3 was pointed at a context that is not a kind cluster.

Exit 1 means an in-scope block fails, has a stale marker, breaks the marker
rules in section 3, or is one no scanner could judge yet holds a pod
template and is not on the allowlist.

A block no scanner could judge is never a pass. `not-evaluated` (static) is a
kind Trivy has no check for, such as a Rollout, a PyTorchJob, a `List` or a
`PodTemplate`, or a file Trivy returned nothing for. `missing-crd` (admission)
is a custom resource the cluster lacks. A removed or wrong `apiVersion` on a
built-in kind, or on a group the cluster serves, is an `error` instead. Both
are listed. When such a block holds a pod template, the pod template went
unread, so the run fails unless the block is on the allowlist,
`.github/scripts/gates/not-evaluated.allow`. Each line there reads
`chapter | what | reason`, and the PR must say how the block was checked
instead.
