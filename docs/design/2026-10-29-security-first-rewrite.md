# Security-first rewrite of the guide: design

* **Status:** Draft, revised after an independent builder review, awaiting
  the owner's approval
* **Date:** 2026-10-29
* **Measured against:** `28ece01` (main after PR #4)

Chapter references use the guide's own form: `05.02` is Part 05,
chapter 02.

## 1. Why

The guide teaches Kubernetes with workloads it later calls unsafe, then
fixes them in Part 05. Measured on `28ece01`:

* The YAML blocks in chapter prose contain 24 Pod-bearing workloads. 23
  of them, spread over 13 chapters, lack at least one of the four
  settings the `restricted` Pod Security Standard requires:
  `runAsNonRoot: true`, `allowPrivilegeEscalation: false`,
  `capabilities.drop: ["ALL"]`, and a seccomp profile.
* 8 of those workloads name the `bookstore` namespace, which
  `raw-manifests/00-namespace.yaml` labels `enforce: restricted`. 7 of
  the 8 lack those settings, so applied as shown, admission rejects
  their Pods. A Deployment is accepted with only a warning; its
  ReplicaSet then cannot create a single Pod.
* Trivy agrees. Of the 20 chapter files holding a workload, 17 fail all
  five core checks (table in §6). The examples tree is mostly hardened
  since PR #4: 51 of its 64 workload files pass all five. Of the 13
  that do not, 12 fail only KSV-0014 (writable root filesystem:
  Postgres, RabbitMQ, the migration Job, the cleanup CronJob and the
  mesh sidecar template), and one is a teaching seed.
* The two Part 00/01 teaching seeds run as root by design.
  `check-runasnonroot.py` allowlists them, `SECURITY-SCAN.md` §1.3
  accepts them, and 05.02 teaches hardening as "a deliberate
  increment".
* Chapters install about 55 third-party components. 14 of them need
  the `privileged` level as installed: CNI and CSI drivers, eBPF tools,
  the GPU stack, node-exporter, Velero's node agent, ingress-nginx for
  its host ports, JupyterHub, kube-bench and Chaos Mesh. No chapter in
  Parts 00 to 09 labels the namespace of a component it installs, so
  those run under the built-in default, which is `privileged`.
* The guide's ingress controller is retired upstream. The ingress-nginx
  README announces its retirement, with best-effort maintenance only
  until March 2026.

So a reader learns the insecure form first and is told to unlearn it 23
chapters later. The prose and the reference tree disagree about what a
correct manifest looks like.

**Audience.** People preparing for or working in Kubernetes, platform
engineering and DevSecOps roles, and practitioners who want one guide
that covers the whole security surface. The guide is not exam
preparation and never presents itself as such.

## 2. The governing principle: no unlearning

The guide never shows a manifest, command or practice in a form it later
calls wrong.

Two consequences follow.

1. **Secure from the first manifest.** The first Pod the reader writes
   carries the baseline in §5.1, and so does every later workload.
2. **Controls arrive with their concepts and stay on.** Some controls
   need ideas the reader has not met yet. A NetworkPolicy needs Services
   and labels, so it arrives in Part 02. From the chapter that teaches a
   control onward, every example uses it. Until then, the earlier
   chapter names the open risk and where it closes ("Pods in this
   namespace can reach each other freely; 02.06 closes that"). Adding a
   control is learning. Reversing a habit is unlearning, and only that
   is forbidden.

## 3. Goals, non-goals, anti-goals

**Goals**

1. Every manifest a reader is told to apply, inline or under
   `examples/`, passes the gates in §6. The only exceptions are the
   registered ones in §5.4 and the marked attack examples in §5.3.
2. Every third-party component the reader installs runs in a namespace
   whose Pod Security level is `restricted`, or is registered with a
   reason (§5.4).
3. Every chapter treats the security of its subject as part of the
   subject (the contract in §5.2).
4. Part 05 becomes the deep security Part: attack, harden, re-attack,
   show the evidence, across the whole surface in the coverage map
   (§5.8).
5. Every security topic has exactly one home where it is taught in
   depth. Other chapters link there.
6. CI enforces all of this, so it cannot quietly rot.
7. The example projects implement the DevSecOps practices the guide
   teaches (§5.12). Each practice lands in the bookstore's repo,
   pipeline or cluster in the chapter that teaches it, and the guide's
   CI runs it, so readers get a working secure delivery pipeline, not a
   description of one.

**Non-goals**

* Exam framing, exam weights or syllabus language anywhere.
* Renumbering or restructuring Parts.
* Changing the bookstore's architecture (ADR 0001). The vulnerable
  overlay in §5.10 is an overlay, not a fork.
* A tool catalogue. A tool appears when a lab uses it.
* Commercial tools as requirements. Free and open-source tools are the
  defaults; commercial ones (Snyk, SonarQube, Docker Scout) get a line
  on when they are worth paying for.
* Clouds the guide does not already cover.
* Attacking anything except the reader's own lab cluster.

**Anti-goals.** Any of these is a failure even with CI green.

* Prose that still says "for now we'll run as root" or "we'll lock this
  down later".
* A threats table pasted into every chapter with generic advice such as
  "use RBAC".
* Security claims nobody demonstrated or cited: invented CVE IDs, wrong
  GA versions, unmeasured numbers.
* Hardened manifests that pass every scanner and crash at runtime.
* Part 05 re-teaching what Parts 10, 11, 13, 14 and 15 already teach.
* Chapters padded with YAML noise. Added words have to earn their place.
* Real cloud identifiers (project IDs, billing accounts, IP addresses)
  in this public repo.
* Broken URLs for existing chapters.
* A live site that is broken between merges.
* A practice taught but not implemented in the projects, or two tools
  implemented for the same job without a stated reason.

## 4. Constraints

* **Public repo.** Lab write-ups use placeholders for every identifier.
* **Every merge to main is published.** `docs.yml` deploys the site on
  every push to main that touches `full-guide/`.
* **CI that must stay green:**
  * `docs.yml` (`mkdocs build --strict`, Mermaid parse);
  * `link-check.yml`;
  * `example-trees-check.yml`: Helm and Kustomize render counts are
    invariants under ADR 0007, so a manifest change that moves a count
    updates the invariant in the same commit;
  * `security-scan.yml` (Trivy, govulncheck);
  * `secret-scan.yml` (gitleaks over the full history).
* **What CI does not do today.** No job creates or connects to a
  cluster. Trivy never fails a build: every step uses exit code 0, and
  trivy-action drops the `severity` filter when it writes SARIF. Every
  accepted finding except the two seeds is accepted only in the prose
  of `SECURITY-SCAN.md`, and parts of that prose are stale. One accepted
  path does not exist, and the "~70" platform RBAC findings are 17 in
  the Security tab.
* **House style.** Prose wraps at about 78 columns (p50 70, p75 76,
  p90 80). Chapters keep the existing section skeleton: Why this exists,
  Mental model, Diagrams, Hands-on with the Bookstore, topic sections,
  How it works under the hood, Production notes, Quick Reference, Test
  your understanding, Further reading.
* **URLs.** About 290 links point into Part 05's existing files, and
  mkdocs has no redirect plugin, so existing chapter files keep their
  names.
* **CONTRIBUTING** pushes back on single-PR multi-chapter rewrites. §7.6
  says how this project handles that.
* **Lab cost.** Every cloud lab has a bounded cost and a scripted
  teardown, as `examples/gke` does.

## 5. Decided structure

### 5.0 Target version and toolchain

The rewrite targets **Kubernetes 1.37**, set in Phase 0 before any
chapter changes. The reasoning:

* 1.37 is the current minor (v1.37.2, 2026-10-28).
* 1.35, which the guide pins today, reaches upstream end of life on
  2027-02-28, likely in the middle of this rewrite.
* EKS offers 1.37 in standard support. GKE's Regular channel offers
  1.37.1, though new Regular clusters still default to 1.36 unless a
  version is set.
* Several security features this rewrite teaches changed state in 1.36
  and 1.37. User namespaces, MutatingAdmissionPolicy and fine-grained
  kubelet authorization are GA in 1.36. Pod certificates and
  ClusterTrustBundles are on by default in 1.37.
* The local toolchain is already behind. The devcontainer pins kind
  v0.27.0, whose default node image is 1.32, which reached end of life on
  2026-02-28.

Phase 0 therefore pins:

* kind v0.33.0 with `kindest/node:v1.37.0` by digest;
* kubectl 1.37 in the devcontainer and CI;
* EKS 1.37 in the Terraform;
* an explicit 1.37 version for GKE instead of the channel default.

Every version-gated claim is checked against the release notes of the
pinned patch.

**kind is the one verified local cluster.** k3d appears in 10 files and
gives a single command beyond 00.07. It also differs where Part 05
needs it: a single-server k3d cluster stores state in SQLite, not etcd.
00.07 keeps one sentence noting that other local distributions exist
and that the guide verifies on kind only.

### 5.1 The baseline

Every workload carries this, in full, from 01.01 onward:

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

* **User namespaces.** If the builder verifies that user namespaces run
  on the reader's kind cluster on both Linux and macOS hosts,
  `hostUsers: false` joins the baseline. Otherwise 05.02 teaches it.
* **ServiceAccount.** A workload that calls the API gets its own
  ServiceAccount with least-privilege RBAC. Nothing uses `default`.
* **Images.** Third-party images are pinned by digest from their first
  appearance, with the tag in a comment. The guide's own images, built
  and loaded locally, use the tag the build produced. 05.03 explains why
  production promotes by digest, and 15.04 already shows how. A local
  tag is a different context, not a wrong habit.
* **Namespace.** Pod Security Admission labels at `restricted`, as
  `00-namespace.yaml` already does. From 02.06 on, a default-deny
  NetworkPolicy plus explicit allows.
* **Cluster** (00.07). The reader's first cluster enforces NetworkPolicy
  and sets `restricted` as the cluster-wide Pod Security default.
  * **NetworkPolicy needs no CNI swap.** kind's own kindnetd has
    enforced NetworkPolicy since kind v0.24.0. 02.06's statements that
    it does not are stale, and its Calico swap goes away. kindnetd's
    policy controller fails open if it cannot start, so 02.06 teaches
    the reader to prove enforcement with a connection that must be
    denied.
  * **The default is set the documented way:** an AdmissionConfiguration
    mounted into the control-plane node with `extraMounts`, and wired to
    the API server with `kubeadmConfigPatches`. System namespaces are
    exempted.
  * **It lands last.** The cluster-wide default lands only after every
    Part complies with it (§7.4).

### 5.2 The chapter contract

Every chapter, rewritten or new, meets all of these:

1. Every manifest the reader is told to apply is complete and carries
   the baseline. Nothing is "omitted for brevity". A block that shows
   only a few fields has no `kind:` and reads clearly as a fragment.
2. A `## Threats and controls` section follows `## Mental model`. It is
   a short table: the threat, the control this chapter teaches, and
   where the topic is covered in depth. Only threats specific to this
   subject go in. A chapter with nothing specific says so in one
   sentence rather than inventing rows.
3. A hardening field is explained where it first appears. 01.01
   explains the whole baseline; later chapters link back.
4. Hands-on uses only the secure form. Where the chapter teaches a
   control, it shows the control working, for example with a request
   that is denied. A step that shows a failure exists to teach the
   control and is labelled as a deliberate action.
5. Security items move out of Production notes into the body. They are
   not an afterthought list.
6. The Quick Reference shows secure forms only.
7. Test your understanding includes at least one question on the
   chapter's security dimension.
8. Every security claim is either demonstrated with output captured in
   the chapter, or cited to an upstream source: Kubernetes docs, the
   project's own docs, or a CVE or advisory.
9. Every third-party install labels its namespace first and sets the
   chart's security values where the chart exposes them (§5.4).

### 5.3 Deliberately insecure examples

These appear only in Part 05 attack labs and the capstone overlay. Each
one:

* opens with the YAML comment `# INSECURE ON PURPOSE: <what it shows>.
  Lab cluster only.`;
* is preceded in the Markdown by `<!-- gate: insecure-on-purpose -->`,
  which the gates read;
* runs in a namespace its lab creates and labels for the privilege it
  needs. Never `bookstore`, never `default`.

The check is bidirectional. A marked block that stops failing breaks CI,
and so does an unmarked block that fails.

### 5.4 Third-party components and the exceptions registry

**Third-party components follow the principle too.**

* Each runs in its own namespace, labelled before the install.
* The label is the lowest Pod Security level the component works under.
* Where a component needs privilege only for an optional feature, the
  chapter turns the feature off. For example, an ingress controller
  reached through a NodePort port mapping needs no host ports.

**The ingress controller.** ingress-nginx is replaced by a maintained
controller. 02.04 still teaches the Ingress API, and 02.05 makes Gateway
API the recommended path.

**One registry holds every exception.** It is a single file, and each
entry records:

* what is excepted: a namespace above `restricted`, or a scanner finding
  with its paths;
* the reason, with an upstream citation where privilege is demanded
  upstream;
* the chapter that explains it;
* an expiry date no more than 12 months out.

**Two consequences:**

* ADR 0009 extends ADR 0005's exception rule from Terraform to every
  namespace the guide creates, wherever it is created. kube-bench and
  other node-level security tools count as system components under this
  rule: they run in their own namespace with the access they audit, and
  the lab removes them afterwards.
* The scanner half of the registry is Trivy's `.trivyignore.yaml`. In
  Trivy v0.76.1, each entry there takes `paths`, a `statement` and an
  `expired_at` date. The feature is still marked experimental, so G5
  (§6) does not trust Trivy alone to enforce it.

`SECURITY-SCAN.md` keeps the reasoning and points at the registry. It
stops being the list.

### 5.5 Part 00

* **New 00.08, Security foundations.** Covers:
  * the bookstore's threat model: assets, actors, trust boundaries and
    entry points;
  * a STRIDE pass;
  * the Kubernetes threat matrix as a map of attacker goals;
  * the baseline as the answer to specific threats;
  * how the guide marks insecure examples and registers exceptions.

  It is appended after 00.07 so existing URLs stay put, and 00.07
  points forward to it.
* **00.02.** Minimal bases, a numeric non-root `USER`, multi-stage
  builds, no secrets in layers, first contact with an image scanner.
* **00.03 to 00.05.** Each component's attack surface: the API server
  as the front door, etcd holding every Secret, the kubelet API, the
  container runtime socket.
* **00.06.** Its Pod example carries the baseline.
* **00.07.** The secure cluster configuration from §5.0 and §5.1.

### 5.6 Part 05

Part 05 grows from four chapters to eleven. An older outline for a
separate attack-and-harden Part supplies topics only: it is a 1,400-word
plan with no prose, labs or captured output. It is never committed, and
its directory goes away when Part 05 lands. Every new chapter below is
new writing.

| # | Chapter | Built from | Lab tier |
|---|---|---|---|
| 00 | The attacker's view: recon from a compromised Pod and from the network | new | A |
| 01 | Authentication, authorization and RBAC, including escalation paths | old 05.01, plus new | A |
| 02 | Pod security and container escape, user namespaces, immutability | old 05.02, plus new | A, B for host-kernel escapes |
| 03 | Supply chain security, including static analysis of manifests | old 05.03, plus new | A |
| 04 | Secrets at rest and in use | secrets half of old 05.04, plus new | A |
| 05 | Kernel isolation: seccomp, AppArmor, SELinux, sandboxed runtimes | new | B |
| 06 | Control plane and node hardening, kube-bench, binaries and upgrades | cluster half of old 05.04, plus new | B |
| 07 | Admission control and policy as code | new | A |
| 08 | Audit logs, runtime detection and incident response | new | A for audit, B for Falco (§5.10) |
| 09 | Running security on a platform team | new | none |
| 10 | Capstone: attack and harden the bookstore | new | B, A where possible |

* **Numbering.** The new first chapter is numbered 00, so 01 to 04 keep
  their files and URLs. `04-secrets-and-cluster-hardening.md` keeps its
  filename although its title becomes "Secrets at rest and in use".
  Every reference to 05.04 that meant cluster hardening is repointed to
  05.06.
* **Lab rhythm.** Each lab chapter goes attack, harden, re-attack,
  evidence. The evidence is what kube-bench, the audit log or the API
  server now reports.
* **05.07** teaches both ValidatingAdmissionPolicy and
  MutatingAdmissionPolicy (GA in 1.36) before Kyverno and Gatekeeper.
* **05.09 is for the DevSecOps role.** It covers threat modelling as a
  habit, vulnerability management (triage, SLAs, VEX), exceptions with
  an expiry date (the guide's own registry is the worked example),
  mapping controls to the CIS Kubernetes Benchmark, the NSA/CISA
  hardening guidance and NIST SP 800-190, and a security review
  checklist for new services.
* **Boundary rule.** Part 05 teaches the mechanism and proves it on a
  lab cluster. Parts 10, 11, 13, 14 and 15 teach running it in
  production on a cloud. Where both touch a topic, Part 05 owns the
  concept and the attack, the later chapter owns the operations, and
  each links to the other. The known pairs:

  | Part 05 | Production counterpart |
  |---|---|
  | 05.01 | 10.03, 13.04 |
  | 05.03 | 14.12, 15.03 |
  | 05.04 | 11.05, 15.05 |
  | 05.07 | 11.01 |
  | 05.08 | 14.13, 15.10 |

### 5.7 The rest of the guide: known changes

These are the changes visible now. The gate worklist from §7.1 adds the
rest.

* **01.** The baseline in every workload.
  * 01.03: limits as a denial-of-service control.
  * 01.06: node agents that need privilege, and the registry.
  * 01.07: least-privilege ServiceAccounts, and `ttlSecondsAfterFinished`.
* **02.**
  * 02.01: the flat network named as a threat.
  * 02.04: a maintained ingress controller replaces ingress-nginx; TLS.
  * 02.05: Gateway API as the recommended path; TLS.
  * 02.06: default deny, egress control, blocking the cloud metadata
    endpoint, proving enforcement. No CNI swap.
* **03.** No secrets in ConfigMaps; Secrets are encoded, not encrypted;
  files over environment variables; immutable Secrets; `emptyDir` for
  writable paths; the danger of `hostPath`; encrypted volumes.
* **04.** Dedicated nodes for sensitive workloads; PriorityClass abuse.
* **06.** Secrets and personal data in logs; exposed metrics endpoints;
  autoscaling as a cost attack; node-exporter's privilege, registered.
* **07.**
  * Helm charts with secure defaults, and chart provenance.
  * The pipeline as the most privileged system in the company.
  * Argo CD RBAC, SSO, repository credentials and blast radius.
* **08.**
  * Upgrades as security work.
  * Backups contain Secrets.
  * `kubectl debug` profiles.
  * Hard versus soft multi-tenancy.
  * Operator RBAC.
  * The cluster-lifecycle skeleton's 1.30 node image moves to the pinned
    version.
* **09.** The composed system passes every gate.
* **10.** Cloud IAM, workload identity, private endpoints, the metadata
  service.
* **11.**
  * Webhook failure modes as attack surface.
  * Operator RBAC markers.
  * API Priority and Fairness as a DoS defence.
  * Mesh mTLS and authorization policy.
  * Fleet credentials.
  * etcd TLS and encryption.
* **12.**
  * GPU stack privileges, registered.
  * Notebooks as remote code execution by design.
  * Model artifact deserialization (pickle versus safetensors).
  * Authentication on serving endpoints.
* **13 to 15.** Already heavy on production security. Audit them for
  the baseline, the registry and the boundary rule.
* **16 and 17.** Their labs are not written yet, and they will be
  written under this contract from the start.
* **Appendix.** The YAML conventions use the baseline.

### 5.8 Coverage map

Each topic has one home. Other chapters link to it.

| Topic | Home |
|---|---|
| Threat modelling, attacker goals | 00.08, 05.00 |
| The workload baseline | 01.01 |
| Image hardening | 00.02 |
| API authentication (x509, OIDC, ServiceAccount tokens, anonymous) | 05.01 |
| Workload X.509 identity (Pod certificates, ClusterTrustBundles) | 05.01, 11.04 |
| RBAC least privilege and escalation paths | 05.01 |
| ServiceAccount token handling | 01.01, 05.01 |
| Pod Security Standards and Admission, exceptions | 05.02 |
| Container escape vectors, user namespaces, immutability | 05.02 |
| seccomp, AppArmor, SELinux, Security Profiles Operator | 05.05 |
| Sandboxed runtimes and RuntimeClass | 05.05 |
| Network segmentation, default deny, egress, metadata endpoint | 02.06 |
| TLS at the edge, certificate management | 02.04, 02.05 |
| Service-to-service mTLS and identity | 11.04 |
| Secrets basics: encoding is not encryption, RBAC, files over env | 03.02 |
| Encryption at rest, KMS | 05.04 |
| External secret stores, rotation | 11.05, 15.05 |
| API server, etcd and kubelet hardening; CIS checks | 05.06 |
| Node OS hardening, binary verification, upgrades, CVE response | 05.06, 08.01 |
| Admission policy as code (ValidatingAdmissionPolicy, MutatingAdmissionPolicy, Kyverno, Gatekeeper) | 05.07 |
| Writing admission webhooks | 11.01 |
| Scanning, SBOMs, signing, provenance, admission verification | 05.03, 14.12, 15.03 |
| Manifest and IaC static analysis | 05.03, 14.07 |
| CI/CD pipeline security (OIDC, SHA pinning, scoped tokens) | 07.03, 15.02 |
| GitOps controller security | 07.04 |
| Third-party components: privilege, values, exceptions | 05.02, 05.09 |
| Audit logging | 05.08 |
| Runtime detection (Falco, Tetragon) | 05.08, 14.13 |
| Responding to a compromised workload | 05.08, 15.10 |
| Multi-tenancy isolation, quotas | 08.04 |
| Denial of service: limits, quotas, API Priority and Fairness | 01.03, 08.04, 11.03 |
| Cloud IAM and workload identity | 10.03 |
| Cluster network exposure, private endpoints | 10.04 |
| Backup security | 08.02, 14.14 |
| Debugging without weakening controls | 08.03 |
| Operator and controller RBAC | 08.05, 11.02 |
| Breakglass access | 15.09 |
| Secrets and personal data in logs | 06.02 |
| Edge WAF and rate limiting | 13.07 |
| ML workloads: notebooks, model artifacts, GPU stack privileges, serving auth | Part 12 |
| Security as a programme: vulnerability management, exceptions, compliance mapping | 05.09 |
| SAST, DAST, secret detection, CI hardening, posture management (full table in §5.12) | 07.03, 15.02, 05.09 |

### 5.8.1 Where the maps stand

The two maps above (§5.8 and §5.12) are the design. This list records, as of
2026-10-31, where the guide and its trees fall short of them, so a reader does
not take a row for a control that runs. A row not listed here is taught in the
chapter it names, and is either run or labelled cited.

* **API authentication.** 05.01 runs anonymous requests and a bad token on kind.
  Structured OIDC configuration is a cited fragment, not run.
* **Workload X.509 identity.** 05.01 runs Pod certificates and a
  ClusterTrustBundle on kind with a lab signer. No mesh consumes them.
* **Encryption at rest, KMS.** 05.04 runs a `secretbox` provider. The KMS v2
  wiring, rotation and failure mode are cited from the upstream page, not run.
* **seccomp, AppArmor, SELinux, SPO, sandboxed runtimes.** 05.05 runs seccomp.
  AppArmor needs a host filesystem that the kind lab lacks. The SELinux label,
  the RuntimeClass and the Security Profiles Operator objects are shown as
  fragments or manifests and are cited, not run.
* **Node OS hardening, binary verification, upgrades, CVE response.** The
  runtime-patching rule is in 00.05 and the CVE procedure in 08.01 (narrated,
  not run). Node OS hardening is cited and taught nowhere.
* **Policy as code and image verification at admission.** 05.07 runs the
  built-in ValidatingAdmissionPolicy and MutatingAdmissionPolicy. The Kyverno
  install, Audit, Enforce, `verifyImages` and Gatekeeper steps did not run
  (the full mode failed three times), and the engine taught is the
  `ClusterPolicy` kind that the chart's CRD marks deprecated. The Bookstore
  ships its Kyverno policy off, and its only `verifyImages` rule is a commented
  sketch, so no signature is checked in the bookstore cluster.
* **Audit logging.** 05.08 runs the audit policy on a throwaway kind cluster and
  reads the log.
* **Runtime detection.** 05.08 renders the Falco chart and does not install it.
  Tetragon is cited, with no TracingPolicy anywhere. The platform Terraform
  installs Falco off by default, with no Falcosidekick and a priority floor that
  keeps the shell rule off.
* **TLS at the edge, certificate management.** 02.04 and 02.05 use a self-signed
  Secret. The cert-manager `Issuer` and `Certificate` objects are written out,
  not run, in 11.01 and 13.07.
* **Signing, provenance, VEX.** 05.03 step 7b runs a `not_affected` statement
  that suppresses a finding in Trivy. The pipeline passes no VEX file to Trivy
  or Grype.
* **Manifest and IaC static analysis; IaC scanning.** 05.03 lints Kubernetes
  manifests. `trivy config` on Terraform runs by hand in 10.02. The Terraform
  pipeline in 14.07 runs no IaC scanner. Checkov appears nowhere in the guide.
* **Policy as code in CI.** Conftest runs in the Bookstore pipeline on the
  rendered overlay and on a committed example plan file, not on a plan of the
  platform tree.
* **CI/CD hardening, SAST, DAST.** The Bookstore pipeline (07.03) runs them for
  the four services in its matrix. The platform services' workflows (15.02) run
  lint, Trivy, buildx, cosign, Syft and provenance, and call no reusable
  pipeline. The operator, the ML images and four platform services have no CI
  template. DAST is the ZAP baseline only: there is no API scan.
* **Image scanning.** Trivy writes JSON. No SARIF is produced or uploaded for
  the image scan.
* **Dockerfile and image lint.** hadolint is taught in 00.02. Dockle is taught
  only in 07.03.
* **Cluster posture.** kube-bench (05.06) and Trivy Operator (05.08) are lab
  steps. Neither is deployed by the Bookstore tree.
* **Cloud posture.** Prowler is cited for AWS and not run. There is no GCP
  equivalent in the guide.
* **Secrets management.** ESO with Vault is taught in 11.05 and 15.05. SOPS is a
  comparison bullet with no example in any tree.
* **Vulnerability management.** Dependency-Track is cited. The Bookstore
  uploads its SBOM as an artifact and never rescans a published image.
* **Compliance as code.** 05.09 maps the guide's controls to published
  references. Nothing in CI maps a gate result to a control.
* **ML and LLM security.** Serving contains a pickle with the baseline and
  stamps a SHA-256. No model scanner runs and the predictor still loads with
  `joblib`.
* **Threat modelling.** 05.00 reads the model's rows by hand. No gate reads the
  file.

### 5.9 Lab evidence

Part 05's labs follow the rule Parts 16 and 17 already state.

* **Lab first.** No lab chapter is written before its lab has run. Every
  command in it comes from a terminal that executed it.
* **Header.** Each lab chapter opens with a header stating:
  * what ran, on which tier and versions;
  * for tier B, the cost from the billing export, not an estimate;
  * what did not work the first time.
* **Transcripts.** Lab runs are scripted and recorded. The redacted
  transcript is committed next to the lab, under
  `examples/security-lab/evidence/`. A check (G7) confirms that every
  output block in a lab chapter appears verbatim in its transcript.
  That is how anyone, not just the author, can vouch for the output.
* **Tier A in CI.** Tier A lab scripts also run in CI on kind, wherever
  their runtime allows.
* **Where evidence comes from.** Only the tier the chapter declares
  counts. Output from another distribution does not.

### 5.10 Labs

* **Tier A: kind on the reader's machine.** Configs live in
  `examples/security-lab/kind/`.
* **Tier B: not run during this rewrite.** The owner ruled out clusters
  on AWS or GCP for now. kind is built with kubeadm and its nodes share
  the Linux host's kernel, so kube-bench, audit logs, encryption at rest,
  AppArmor and Falco are tried on tier A first. What kind cannot show
  truthfully (a real `kubeadm upgrade`, a sandboxed runtime it will not
  run) is cited to upstream and labelled as not run. A chapter never
  implies it ran. A kubeadm lab on cloud VMs can be added later.
* **Falco runs on a Linux host.** Falco's docs say Docker Desktop for Mac
  does not work, so the lab states that it needs a Linux Docker host.
* **Encryption at rest on kind has no documented recipe.** The builder
  proves one in the lab before 05.04 teaches it.
* **Every lab chapter** states its tier at the top.
* **Capstone.** Built on a deliberately vulnerable Kustomize overlay of
  the bookstore at `examples/bookstore/security-lab/vulnerable/`. Each
  weakness is tied to the chapter that closes it. Kubernetes Goat is
  optional further practice, if it is still maintained.
* **Every lab says plainly:** run this only against clusters you own.

### 5.11 Seeds and records

* **Seeds.** The two seeds are hardened. `check-runasnonroot.py` is
  replaced by G5. Its allowlist exempts whole files and checks only
  `runAsNonRoot`, over a narrow set of sources.
* **"Frozen" chapters.** 01.01 and 01.03 tell the reader the seeds are
  frozen snapshots. Both are rewritten.
* **ADR 0009** records:
  * security-first;
  * no unlearning;
  * the marker convention;
  * the registry and its extension of ADR 0005;
  * the gates;
  * the 1.37 target.
* **SECURITY-SCAN.md** is rewritten around the registry, and its stale
  entries are corrected.
* **Front matter.** `README.md`, `about.md` and `CHANGELOG.md` describe
  the guide as security-first.

### 5.12 DevSecOps in the projects

The bookstore and the platform are where the practices live, not just
where they are described. The rules:

* **One default tool per job, implemented.** Each practice has one
  tool wired into the projects. Alternatives get a line on when to pick
  them instead. Where two tools share a job on purpose, the reason is
  stated (for example, two SBOM scanners disagreeing is the lesson).
* **Controls arrive with their concepts** (§2). A tool is first run
  locally in the chapter that introduces it. 07.03 assembles the
  project's pipeline, and every later chapter adds its stage to that
  pipeline rather than a side example.
* **The pipeline is a reusable workflow** that the guide's own CI runs
  against the example services (G9), so a stage that stops working
  fails the build.

| Practice | Implemented with | Taught in | Lands in |
|---|---|---|---|
| Threat modelling | STRIDE; a living threat model file | 00.08, 05.00 | the bookstore repo |
| Pre-commit checks | pre-commit with Gitleaks, hadolint, gosec | 07.03 | the bookstore repo |
| Secret detection | Gitleaks (pre-commit, CI); TruffleHog verified mode as the CI gate | 03.02, 07.03 | pipeline |
| SAST | Semgrep with custom rules, gosec; CodeQL for deep data flow | 07.03 | pipeline |
| SCA and reachability | govulncheck, Trivy; Renovate or Dependabot for update PRs | 05.03, 07.03 | pipeline |
| Dockerfile and image lint | hadolint before the build, Dockle after it | 00.02 (hadolint), 07.03 (Dockle) | pipeline |
| Image scanning | Trivy (severity, exit code, ignore-unfixed); JSON output, no SARIF | 05.03 | pipeline |
| SBOM | Syft (CycloneDX), scanned by Grype and Trivy | 05.03 | pipeline, attached to the image |
| Signing and provenance | cosign keyless, SLSA provenance, attestations; VEX for findings that do not apply | 05.03, 15.03 | pipeline, registry |
| Manifest static analysis | KubeLinter, kubesec, Trivy config | 05.03 | pipeline |
| IaC scanning | Trivy config, run by hand; Checkov is not used | 10.02, 14.07 | not in the Terraform pipeline (§5.8.1) |
| Policy as code in CI | OPA with Conftest on manifests and Terraform plans, with Rego unit tests | 05.07, 14.07 | a `policy/` tree run in CI |
| Policy as code at admission | Kyverno in the project; OPA Gatekeeper side by side in the lab; ValidatingAdmissionPolicy | 05.07 | bookstore cluster |
| Image verification at admission | Kyverno verifyImages against the cosign identities | 05.03, 05.07 | bookstore cluster |
| CI/CD hardening | Actions OIDC, SHA pinning, scoped tokens, zizmor, Harden-Runner, OpenSSF Scorecard | 07.03, 15.02 | the project's workflows |
| DAST | OWASP ZAP baseline and API scans against an ephemeral kind environment | 07.03, 15.02 | pipeline |
| Secrets management | External Secrets Operator with Vault; SOPS for secrets kept in Git | 11.05, 15.05 | platform |
| Cluster posture | kube-bench; Trivy Operator for continuous in-cluster scanning | 05.06, 05.08 | bookstore cluster |
| Cloud posture | Prowler (AWS and GCP) | 05.09, 14.17 | account baseline |
| Runtime detection and response | Falco with Falcosidekick; Tetragon for enforcement | 05.08, 14.13 | bookstore cluster |
| Vulnerability management | Dependency-Track fed by the SBOMs; triage, SLAs, the exceptions registry | 05.09 | platform |
| Compliance as code | control mapping, with the gates' output as evidence | 05.09 | repo docs and CI artifacts |
| ML and LLM security | model artifact scanning and safe formats; OWASP Top 10 for LLM applications on serving endpoints | Part 12 | ML examples |

The exact versions, which update bot, and where each stage sits in the
pipeline are left to the builder (§8).

## 6. Quality gates

The gates are built before any content changes. Their first run on main
produces the worklist.

* **G1, extraction.** Every fenced `yaml` block containing `kind:` in
  `full-guide/**/*.md` outside `examples/` is extracted and keyed by
  chapter and block index. Each block is classed as applyable or
  insecure-on-purpose (the marker). Fragments without `kind:` are not
  gated.
* **G2, static.** Trivy config runs over applyable blocks and over
  `examples/`. It must report zero HIGH or CRITICAL misconfigurations
  outside the registry, and these five checks must pass on every
  workload:

  | Check | Finding |
  |---|---|
  | KSV-0012 | Runs as root |
  | KSV-0014 | Root filesystem not read-only |
  | KSV-0001 | Privilege escalation allowed |
  | KSV-0003 | Capabilities not dropped |
  | KSV-0030 | No seccomp profile |

  G2 runs as its own step with a non-zero exit code and table output.
  The SARIF upload step stays as it is, because trivy-action drops the
  severity filter there. Vulnerabilities stay with govulncheck and the
  image scan; G2 is about configuration.
* **G3, admission.** CI creates a kind cluster at the pinned version,
  and a namespace labelled `enforce=restricted` and `warn=restricted`.
  It server-side dry-runs every applyable block. Any error, or any
  PodSecurity warning, fails the gate.
  * **Why warnings count.** On Kubernetes 1.35 (k3s v1.35.5), a
    violating Deployment returned only a warning and `created (server
    dry run)`, while a violating bare Pod was Forbidden.
  * **Third-party installs.** For each chart a chapter installs, the
    rendered templates, with the chapter's values, are dry-run into a
    namespace at the level registered for that component.
* **G4, runtime.** CI deploys `raw-manifests`, the rendered Helm chart
  and each Kustomize overlay to kind. It waits for every workload to
  reach Ready, or Complete for Jobs. This is the gate that catches
  read-only root filesystems breaking Postgres and RabbitMQ.
  Chapter-only workloads that exist in no example are run on a real
  cluster during the rewrite, with the evidence in the PR description.
* **G5, markers and registry.** Two bidirectional checks:
  * every insecure-on-purpose marker (§5.3);
  * the registry (§5.4). Every namespace label above `restricted`, and
    every suppressed finding, has an entry. Every entry still matches
    something and carries a reason and an unexpired date.

  G5 replaces `check-runasnonroot.py`.
* **G6, existing gates.** These stay:
  * `mkdocs build --strict`;
  * Mermaid parse;
  * links;
  * render-count invariants;
  * govulncheck;
  * gitleaks;
  * line width.
* **G7, claims and evidence.** Contract item 8, plus the transcript
  match in §5.9. A redaction check fails on IP addresses and cloud
  identifiers in committed transcripts.
* **G8, review.** Once G1 to G7 pass, a reviewer reads only the diff and
  the authoring spec. It checks the diff against the chapter contract
  and the anti-goals.
* **G9, the projects' pipeline runs.** From the moment 07.03 lands, the
  guide's CI calls the example services' reusable pipeline on every PR
  that touches them. Each stage in §5.12 must run and pass, and a
  deliberately vulnerable fixture proves each scanner still catches what
  it is there to catch.

## 7. Process

### 7.1 Phase 0: version and gates

1. Retarget the toolchain to 1.37 (§5.0).
2. Build G1, G2, G3 and G7 as local scripts, with the marker half of G5,
   and run them on main. The failures become the worklist.
3. After the pilot, wire the gates into CI in report mode, add G4, and
   stand up the registry with today's accepted findings. This keeps the
   estimate from depending on CI work that may change.

### 7.2 Phase 1: spec and foundations

Write `docs/security-first-authoring.md`. Every worker reads this one
file, and it holds:

* the baseline;
* the chapter contract as a checklist;
* the marker convention;
* the registry rules;
* the boundary rule;
* the style rules.

00.08 follows after the pilot, with the rest of Part 00.

### 7.3 Pilot

Three chapters, chosen to cover the range:

| Chapter | What it tests |
|---|---|
| 01.01 Pods | Introduces the baseline; rewrites a seed |
| 05.02 Pod security and container escape | A restructure, new writing, an attack lab with evidence |
| 07.03 CI/CD pipeline | Implementing DevSecOps practices in the project, with the pipeline running in CI (G9) |

For each, measure:

* tokens per chapter, split by kind of work (rewrite, restructure, new);
* the first-pass gate pass rate;
* review findings;
* the change in word count.

Project the total for the remaining chapters from those numbers.

Then the owner reads the three chapters and approves their voice and
depth before anything scales. If the projection is out of line, adjust
first, not later: tighter contexts, or a smaller model for mechanical
changes.

### 7.4 Order, and keeping the live site working

The invariant: **every merge to main leaves the published guide working
end to end.** The order follows from it.

1. **Compliance pass.** After the pilot, one mechanical pass across all
   Parts. It brings every manifest into compliance, labels every
   third-party namespace, and fills the registry. Prose is left alone
   except where a manifest change forces it. The guide then works on a
   restricted-by-default cluster before any chapter says so.
2. **The flip.** 00.07 switches to the restricted cluster default, in
   the same change as 02.06 dropping the CNI swap.
3. **Prose rewrite, Part by Part:**
   1. Parts 00 and 01.
   2. Part 05. It comes early because `mkdocs build --strict` fails on
      links to files that do not exist yet, so every link target has to
      exist before other chapters point at it.
   3. Parts 02, 03 and 04.
   4. Parts 06 to 09.
   5. Parts 10 to 15.
   6. The appendix.
   7. Parts 16 and 17, when their labs are written.

As each Part lands, its gates switch from report mode to blocking, so a
finished Part cannot regress. While the rewrite runs, the README says
which Parts are done.

### 7.5 Token discipline

* **Narrow context.** Each worker gets five things: the spec, its
  module's one-page brief, its chapter, the example files it touches, and
  its gate output. Never the whole guide. Cost grows with calls times
  context size, so one long agent across a module costs more than one
  short agent per chapter, and cannot hold the module in context anyway.
* **Edit, don't regenerate.** Full rewrites are only for the
  restructured Part 05 chapters.
* **Scripts before models.** Scripts run G1 to G7 before any model
  reviews anything, and reviews read only the diff.
* **Match the model to the work.** The strongest model writes new
  chapters and restructures. A smaller one does the compliance pass and
  other mechanical manifest hardening.

### 7.6 Pull requests

* One tracking issue.
* One PR for the compliance pass in each Part, then one PR per Part for
  the prose, with one commit per chapter so each change stays reviewable
  on its own. Part 05 may need two PRs.
* This departs from CONTRIBUTING's one-chapter preference. The owner's
  approval of this design is the agreement to do it.

## 8. Left to the builder

* Exact chapter titles, and the order inside Part 05 beyond §5.6.
* The numeric UID and GID for each image, and which paths each one
  needs writable.
* Which system namespaces need exempting from the cluster-wide
  `restricted` default on kind.
* Whether user namespaces run on kind on both Linux and macOS (§5.1).
* Which maintained ingress controller and Gateway API implementation
  replace ingress-nginx. Prefer ones that run under `restricted`.
* For each third-party chart, the values that reach its lowest workable
  level.
* How G3 renders chart installs from chapter commands.
* The tier B Terraform, its machine sizes and its cost figures, taken
  from current pricing pages.
* The encryption-at-rest recipe on kind (§5.10).
* Diagrams.
* Word budgets per chapter, set from the pilot.
* Whether Kubernetes Goat is still maintained.

## 9. Who decided what

**The owner decided:**

* a full security-first rewrite rather than an added pass or a separate
  security Part;
* coverage of every security topic;
* no exam framing;
* the overall shape in §5: security foundations in Part 00, every
  chapter rewritten, Part 05 as the deep attack-and-defend Part, no Part
  renumbering;
* gates before review, and a pilot before scaling;
* upgrading the guide to Kubernetes 1.37 (§5.0), done first as its own
  change;
* DevSecOps practices taught and implemented in the example projects,
  with the pipeline proven in CI (§5.12, G9);
* lab infrastructure: no clusters on AWS or GCP during this rewrite.
  Local clusters and CI runners are the lab. Parts 10, 13, 14 and 15 are
  validated and cited rather than run, and the labs in Parts 16 and 17
  wait;
* the writing setup, chosen after a blind three-way trial on 05.02: Haiku
  writes and fixes, Sonnet reviews, one reviewer per 3 or 4 chapters, and
  each module gets a one-page brief its chapter writers read (§7.5).

**Calls made in this document, open to the owner's veto:**

* The "controls arrive with their concepts" reading of no unlearning
  (§2).
* kind as the only verified local cluster (§5.0).
* Local images by tag, third-party images by digest (§5.1).
* A cluster-wide `restricted` default from 00.07 with kindnetd, landing
  after the compliance pass (§5.1, §7.4).
* Third-party components under the principle, one exceptions registry
  with expiry dates, and ADR 0005 extended beyond Terraform (§5.4).
* Replacing ingress-nginx (§5.4).
* The `## Threats and controls` section (§5.2).
* Numbering the new Part 05 opener as 00, and keeping the 05.04
  filename (§5.6).
* Appending 00.08 rather than inserting it (§5.5).
* Committed lab transcripts as evidence (§5.9).
* Lab tiers, with tier B on Compute Engine and Falco on tier B (§5.10).
* A capstone built on a vulnerable bookstore overlay (§5.10).
* PodSecurity warnings failing G3 (§6).
* The pilot chapters (§7.3), with 07.03 replacing 07.04 so the pilot
  measures the cost of implementing practices, not only describing them.
* One default tool per practice, open-source first, and the tool
  choices in the §5.12 table.
* Per-Part publishing behind the working-site invariant (§7.4), and PR
  granularity (§7.6).
* This document's location, `docs/design/`.
