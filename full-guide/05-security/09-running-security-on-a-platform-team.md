# Running security on a platform team

> The habits that keep Part 05's controls true after the first install: a
> threat model that changes with the system, triage that ends in a record,
> exceptions whose expiry a machine enforces, and a review every new service
> passes. The lab runs the registry's two gates, Trivy and an admission rule,
> and maps the controls to three published references.

**Estimated time:** ~30 min read · ~20 min hands-on (the lab is scripted)
**Prerequisites:** [Part 05 ch.02](02-pod-security.md): the baseline's fields
and the `restricted` level · [Part 05 ch.03](03-supply-chain.md): SBOMs, image
scans and the Trivy ignore file · [Part 05 ch.01](01-authn-authz-rbac.md):
least-privilege RBAC

**You'll know after this:**

- write a threat model entry with a named trigger for its next review
- triage a finding by reachability, and say what a VEX statement records
- read a registry entry's reason and expiry, and show a scanner honouring it
  until that date
- write an admission rule that enforces an expiry on namespace exceptions, and
  say what it cannot check
- map a control to the CIS Kubernetes Benchmark, the NSA and CISA guidance and
  NIST SP 800-190

<!-- tags: security, platform, devsecops, vulnerability-management, exceptions, vex, cis-benchmark, nist-800-190, admission -->

## Why this exists

Parts 00 to 05 teach controls one at a time. Each one closes a path: an
escalation through RBAC, an escape through a Pod field, an image nobody
signed, a request nobody logged. A control does not stay true because it was
installed. A scanner that flags findings nobody reads becomes noise. An
exception granted for one upgrade stays in the cluster for years. A service
that skips review ships without the baseline. Keeping the controls true is the
platform team's job, and it takes most of the hours.

This chapter is the working habit of the DevSecOps role. It keeps four
questions answered for every system the platform runs: what can go wrong with
it, which findings matter today, which exceptions are still justified, and
whether the next service meets the same bar. Each question gets a habit, a
record a reviewer can read, and a check a machine can run. The guide's own
registry is the worked example.

This chapter teaches no attack. Its lab checks the records that keep
exceptions honest. The controls those records depend on are proved in Part 05
ch.00 to ch.05, and the admission chapter, 05.07, covers the policy engines in
depth.
<!-- link-later: 05.07 -->

## Mental model

Four stages, each leaving a record:

- **Model.** A threat model per system, kept beside its code. It names the
  assets, the entry points and the threats that matter, and it is reread when
  the system changes, not once a year.
- **Enforce.** The baseline, admission policy and the pipeline's gates. Each
  control answers a threat the model names.
- **Triage.** Scanner findings, SBOM changes and runtime alerts land in one
  queue. Every item ends in a decision: fix it, mitigate it, or record why it
  does not apply.
- **Except.** A decision that a control should not apply goes into the
  registry, with a reason and an expiry date. When the date passes, the
  decision stops counting and the finding returns to the queue.

The loop runs on every change: a new service, a new dependency, a new image
digest, an entry that has lapsed. Read it as a schedule with owners, not as a
project with an end date.

## Threats and controls

The threats here belong to the platform's practice, not to one container. Each
one is a way the security work quietly stops being true.

| Threat | Control this chapter teaches | Where it goes deeper |
|---|---|---|
| A threat model no longer matches the system | A short model per system, with reread triggers written into it | STRIDE and the threat matrix, Part 00 ch.08 <!-- link-later: 00.08 --> |
| A finding is fixed, or ignored, with no recorded reason | A triage decision per finding, and VEX where a product statement applies | [OpenVEX specification](https://github.com/openvex/spec/blob/main/OPENVEX-SPEC.md) |
| An exception outlives the reason it was granted | An expiry date on every registry entry, enforced by the scanner or by the expiry stage | The registry, below |
| A namespace is lowered below `restricted` with no record | An admission rule that refuses a lower level without a reason and an expiry within 365 days | [ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) |
| A new service ships without the baseline, the gates or an owner | A review checklist, and one complete reference workload that passes it | [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) |
| Controls are claimed against a benchmark and never mapped to it | A control map to CIS, NSA and CISA, and to NIST SP 800-190 | The control mapping, below |

## Threat modelling as a habit

The method is STRIDE, which Part 00 ch.08 teaches in full
<!-- link-later: 00.08 -->. This section is the habit around it: when a model is
reread, where it lives, and what an entry looks like.

A model is out of date as soon as one of these changes. Write the list into
the model file, so the next reviewer sees it:

- an entry point: an ingress path, a port, a new upstream the service calls;
- an identity: a ServiceAccount, a role binding, or a cloud identity it uses;
- a secret or a data store it reads;
- a base image, a dependency, or a language runtime version;
- a registry entry that names this service;
- an incident, or a finding the model did not name.

The model stays small. The table below is an example model for the storefront,
the guide's static site, in the shape the review uses. It describes the
intended controls. The gates and admission are what check them.

| Threat (STRIDE) | Control | Checked by |
|---|---|---|
| Tampering: a changed image reaches the cluster (T) | Image pinned by digest, built and signed by the pipeline | The pipeline gates in [ch.03](03-supply-chain.md); admission in 05.07 <!-- link-later: 05.07 --> |
| Tampering: the running container's files are changed (T) | `readOnlyRootFilesystem: true`, with writes only to an `emptyDir` | The baseline in [01.01](../01-core-workloads/01-pods.md#baseline) |
| Elevation: a vulnerable package in the base image is used (E) | Image scan at the pipeline gate; a dated registry entry for any accepted finding | Trivy in the pipeline, and the registry below |
| Disclosure: a compromised process reads the API with a default token (I) | `automountServiceAccountToken: false` and a dedicated ServiceAccount | [ch.01](01-authn-authz-rbac.md) and the baseline |
| Denial of service: a process exhausts its node (D) | Requests and a memory limit | [01.03](../01-core-workloads/03-resources-and-qos.md) |

## Vulnerability management

A scanner finding is an input to a decision. It is not a decision. Three
things turn one into a record: triage, a window, and, where it applies, a VEX
statement.

### Triage

Ask these questions in order, and write the answers down:

1. **Is the package in the artifact that runs?** The SBOM from
   [ch.03](03-supply-chain.md) answers this for each image. A package used
   only at build time does not ship, and a scan of the final image says so.
2. **Is the vulnerable code reachable from this service?** A package can be
   present while the vulnerable function is never called. A scanner cannot
   answer this. A person reading the code or the call path can.
3. **Is there a fixed version, and can the base image take it?** Often the
   upstream fix is in a newer base image, so the answer is a dated wait. Where
   no fix exists, the question becomes what limits the damage.
4. **What already stops the exploit?** The baseline can make a finding
   unreachable in practice even when the package is present: a read-only root,
   no privilege escalation, dropped capabilities. Record which control does
   the work.

Only the first question belongs to a scanner. The other three need a person,
and their answers belong in the record, not in someone's memory.

### Windows

A triage decision has an end. This guide sets no table of severities with
fixed day counts, because a window depends on how exposed the service is. Pick
windows per class of service, write them into the registry's rules, and check
each one with a machine.

The guide's own numbers show the shape. On its first run, on 2026-10-30, the
pipeline flagged a critical finding in the storefront image's `brotli-libs`
package. Alpine had a fix, and the nginx base image did not carry it yet. The
finding went into the Trivy ignore file with a statement and an expiry of
2026-11-30, one month out. After that date the gate fails again until the base
is rebuilt or the entry is renewed on purpose.

### VEX

A VEX document states, for one product and one vulnerability, whether the
product is affected. The OpenVEX specification defines four statuses:
`not_affected`, `affected`, `fixed` and `under_investigation`. A
`not_affected` statement must say why, with one of five justifications:
`component_not_present`, `vulnerable_code_not_present`,
`vulnerable_code_not_in_execute_path`,
`vulnerable_code_cannot_be_controlled_by_adversary` or
`inline_mitigations_already_exist` ([OpenVEX
specification](https://github.com/openvex/spec/blob/main/OPENVEX-SPEC.md)).

A Trivy ignore entry says "ignore this". A VEX statement says why, in a field
a tool can check, so a later scan can read it. This guide's pipeline records
its decisions as ignore entries. The lab does not run a VEX scan: a
hand-written SBOM gave Trivy no results to suppress, so the VEX step is cited,
not run. See the lab header.

### Dependency-Track, fed by the SBOMs

Each image build produces a CycloneDX SBOM. The pipeline's `syft` stage writes
one to `/out/sbom.cdx.json`
([`ci/scan.sh`](../examples/bookstore/ci/scan.sh)). Dependency-Track ([project
docs](https://docs.dependencytrack.org/)) consumes CycloneDX SBOMs and
monitors the components across versions of every project, so a new advisory
reaches the triage queue without a rebuild. It gives the portfolio view that a
single-image scan does not.

It needs an API server and a database, which this lab does not run. It is
cited, not run. The platform's job is to send every image's SBOM to it at
build time, and to triage what it raises with the four questions above.

## Exceptions with an expiry date

An exception is a recorded decision that a control does not apply here. Every
exception carries three things: the reason, the chapter that explains the
control, and an expiry date no more than 12 months out. ADR 0005 in the
repository's `docs/adr` names the risk. A default relaxed for a few workloads
drifts until the whole cluster runs `privileged`. An expiry date makes the
decision come back on purpose.

### This repository's registry

The design asks for one file. The repository has four, one per scanner, and
the pipeline reads them together.

| File | Scanner | Who enforces its dates |
|---|---|---|
| `full-guide/examples/bookstore/ci/trivyignore.yaml` | Trivy | Trivy, through each entry's `expired_at` |
| `full-guide/examples/bookstore/ci/grype.yaml` | Grype | No date of its own. Its header says the Trivy entry's date brings the gate back, and the two are deleted together |
| `full-guide/examples/bookstore/ci/kube-linter.yaml` | KubeLinter | The `expiry` stage of `ci/scan.sh`, which reads a `Revisit by` date beside each entry |
| `full-guide/examples/bookstore/ci/zap/baseline.conf` | ZAP | The same `expiry` stage |

Namespace exceptions are not in these four files. Their record is the
Namespace itself: two annotations, `security.example/exception-reason` and
`security.example/exception-expires`. The admission rule in the hands-on, and
the Rego rules `BK-POL-011` and `BK-TF-001` in
[05.07](07-admission-control-and-policy-as-code.md), read the same two
annotations. A chapter that records a namespace exception uses them and points
here.

### An entry, and how Trivy reads its date

An entry names the scanner's own finding ID. A CVE goes under `vulnerabilities`.
A misconfiguration check, such as KSV-0017, goes under `misconfigurations`, with
the file it applies to in `paths`:

```yaml
vulnerabilities:
  - id: <CVE ID>
    statement: "<what is true here, and why the finding is accepted>"
    expired_at: 2026-11-30
misconfigurations:
  - id: <check ID, for example KSV-0017>
    paths:
      - <file the check reads>
    statement: "<what is true here, and why the check is accepted>"
    expired_at: 2026-11-30
```

Trivy reads this YAML form only when it is named with `--ignorefile`, because
[Trivy's filtering
guide](https://trivy.dev/docs/latest/guide/configuration/filtering/) marks it
experimental. Its warning says the format may change without backwards
compatibility. That is one reason the expiry stage below also checks the
dates.

Trivy stops honouring an entry on its `expired_at` date, and the finding
returns to the gate. The entry says what is true and when the decision ends.
Renewal is a deliberate edit with a new date, never a silent extension. Part 1
of the hands-on shows Trivy honouring an entry before its date and reporting
the finding after it.

### Namespace exceptions: a rule the admission layer enforces

A namespace below `restricted` is an exception. Its record is two annotations
on the Namespace: a reason, and an expiry date. The admission rule in the
hands-on refuses a namespace below `restricted` unless both annotations are
present and the expiry falls within 365 days of the namespace's creation. A
namespace with no enforce label counts as below `restricted`. Pod Security
Admission uses `privileged` for a namespace with no label, unless the
cluster's admission configuration sets another default, so the rule refuses
that case too.

The Rego rules that CI runs, `BK-POL-011` for manifests and `BK-TF-001` for
Terraform plans, check the same record. They check that both annotations are
present. Only the admission rule checks the window, because a manifest carries
no creation time.

The rule cannot check today's date. In this Kubernetes version, a
ValidatingAdmissionPolicy's CEL has no clock: the expression that names `now`
is refused by the API server. So the rule measures the window from
`metadata.creationTimestamp`, which the API server sets before validating
admission runs. Two consequences follow. On creation the window is exact. On
update the window still counts from the original creation, so an exception
cannot be pushed beyond a year from when it was first made.

An expiry that has passed is not removed by admission, because admission
cannot see the date. A scheduled check has to find lapsed records, and the
expiry stage above is the pattern for it.

## Hands-on: the registry on two gates

### Lab header

- **Tier A, partly run.** Part 1 and Part 1b need only Trivy 0.76.1 and no
  cluster. Part 2 runs on a lab kind cluster, a node on Kubernetes v1.37.0, with
  kubectl v1.37.2. The output below came from a lab cluster with a different
  name from the one this guide uses.
- **Script and transcript.**
  [`labs/05-09.sh`](../examples/security-lab/labs/05-09.sh) runs every step
  below. Its recorded output is
  [`evidence/05-09.txt`](../examples/security-lab/evidence/05-09.txt).
- **Cleanup.** The script creates only namespaces whose names carry the lab's
  `p05-09-` prefix, and one cluster-scoped policy, and it deletes them.
  Namespace removal is slow on a busy control plane, so the script requests
  the deletions and does not wait for them. Before a run it waits, for up to
  five minutes, for leftovers from an earlier run to finish terminating.
- **A kind node is a container.** It runs on the machine that runs kind and
  shares that machine's kernel. This lab creates namespaces and two
  cluster-scoped admission objects. It runs no Pod, so no payload runs. The
  one Pod-shaped object is a server dry run, which is never created.
- **What did not work the first time.** The policy would not compile. This
  Kubernetes version has no `now` in CEL, and the server said so. Comparing
  the expiry string with the creation timestamp failed until the timestamp was
  wrapped in `timestamp()`, so the rule refused a namespace it should admit.
  The lab cluster's control plane then became unstable: the controller manager
  restarted and lost its leader lease, API calls timed out, and namespaces
  stayed `Terminating`. One namespace apply timed out, so the privileged-Pod
  step was refused for a missing `default` ServiceAccount, not by PodSecurity.
  The script now waits for that ServiceAccount before the step.

### Part 1: a scanner honours an entry until its date

The lab writes one manifest with a known finding, a privileged container,
which Trivy's check KSV-0017 reports. The manifest is a fixture, so it is not
applied to any cluster:

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a privileged container for the Trivy check. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: exception-demo
  namespace: demo
spec:
  containers:
    - name: app
      image: example.invalid/app@sha256:0000000000000000000000000000000000000000000000000000000000000000
      securityContext:
        privileged: true
```

With no entry, the scan reports the finding once. The first output line is the
scanner's version, so the reader can see what ran:

```bash
trivy --version | head -1
trivy config --quiet --format json --ignorefile "" exception-demo.yaml | grep -c '"ID": "KSV-0017"'
```

<!-- gate: output -->
```
Version: 0.76.1
# ...
1
```

The lab writes two entries that name the check and its file. One has a date
still ahead, and the other a date already past:

```yaml
misconfigurations:
  - id: KSV-0017
    paths:
      - exception-demo.yaml
    statement: "Demo entry: privileged container excepted for the registry worked example."
    expired_at: 2027-04-29
```

With the entry still in force, the same count drops to zero:

```bash
trivy config --quiet --format json --ignorefile ignore-future.yaml exception-demo.yaml | grep -c '"ID": "KSV-0017"'
```

<!-- gate: output -->
```
0
```

The second entry differs only in its date, `expired_at: 2026-10-01`, which is
already past. The finding comes back:

```bash
trivy config --quiet --format json --ignorefile ignore-expired.yaml exception-demo.yaml | grep -c '"ID": "KSV-0017"'
```

<!-- gate: output -->
```
1
```

### Part 1b: the repository's own expiry stage

CI runs the bookstore's `expiry` stage on the two lists that Trivy cannot
date. Run it the same way from the repository root:

```bash
(cd "$REPO" && REPORT_DIR="$work/reports-ci" bash full-guide/examples/bookstore/ci/scan.sh expiry "full-guide/examples/bookstore/ci/zap/baseline.conf full-guide/examples/bookstore/ci/kube-linter.yaml"; echo "exit=$?")
```

<!-- gate: output -->
```
scan.sh: expiry clean on full-guide/examples/bookstore/ci/zap/baseline.conf full-guide/examples/bookstore/ci/kube-linter.yaml
exit=0
```

The stage reads each entry's `Revisit by` date and compares it with today's
UTC date. To see it fail, the lab gives it a copy of an exceptions file whose
date is in the past. The copy is a fixture:

```yaml
checks:
  exclude:
    # Demo entry for chapter 05.09. Revisit by 2020-01-01.
    - no-anti-affinity
```

<!-- gate: output -->
```
scan.sh: expiry flagged exceptions.conf (exit 1, report reports/expiry.txt)
exit=1
exceptions.conf:4: lapsed on 2020-01-01 (today is 2026-10-31):     - no-anti-affinity
```

The failure is deliberate. The stage exits 1 and names the line.

### Part 2: the admission rule, and a new service

Part 2 runs on the cluster. The first manifest is the rule itself: a
ValidatingAdmissionPolicy and its binding. The policy's match condition limits
the rule to namespaces whose names begin with `p05-09-`, so it cannot affect
any other namespace on a lab cluster.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: exception-expiry
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["namespaces"]
  matchConditions:
    - name: demo-namespaces-only
      expression: "object.metadata.name.startsWith('p05-09-')"
  variables:
    - name: level
      expression: >-
        has(object.metadata.labels) &&
        'pod-security.kubernetes.io/enforce' in object.metadata.labels ?
        object.metadata.labels['pod-security.kubernetes.io/enforce'] : ''
    - name: notes
      expression: >-
        has(object.metadata.annotations) ? object.metadata.annotations : {}
  validations:
    - expression: >-
        variables.level == 'restricted' ||
        ('security.example/exception-reason' in variables.notes &&
         'security.example/exception-expires' in variables.notes &&
         timestamp(variables.notes['security.example/exception-expires'] + 'T00:00:00Z') > timestamp(object.metadata.creationTimestamp) &&
         timestamp(variables.notes['security.example/exception-expires'] + 'T00:00:00Z') <= timestamp(object.metadata.creationTimestamp) + duration('8760h'))
      message: "a namespace below restricted needs a reason and an expiry within 365 days"
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: exception-expiry
spec:
  policyName: exception-expiry
  validationActions: ["Deny"]
```

The lab first clears any `*` namespace an earlier run left, then
applies the policy. Applying it prints the two objects it creates:

<!-- gate: output -->
```
none left
```

<!-- gate: output -->
```
validatingadmissionpolicy.admissionregistration.k8s.io/p05-09-exception-expiry created
validatingadmissionpolicybinding.admissionregistration.k8s.io/p05-09-exception-expiry created
```

The lab then waits until a server dry run shows the binding refuse a namespace
that carries no record. Then it applies five namespaces. Three of them are
refused by design: one has no reason and no expiry, one has no enforce label,
and one has an expiry more than 365 days out. Each namespace that is admitted is
labelled at the same level for enforce, audit and warn, as
[ch.02](02-pod-security.md) requires for every namespace the guide creates.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: restricted
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.37
---
apiVersion: v1
kind: Namespace
metadata:
  name: no-expiry
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/warn-version: v1.37
---
apiVersion: v1
kind: Namespace
metadata:
  name: exception
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/warn-version: v1.37
  annotations:
    security.example/exception-reason: "Demo record: stands in for a registry entry. See chapter 05.09."
    security.example/exception-expires: "2027-06-30"
---
apiVersion: v1
kind: Namespace
metadata:
  name: unlabelled
---
apiVersion: v1
kind: Namespace
metadata:
  name: unlabelled
---
apiVersion: v1
kind: Namespace
metadata:
  name: too-long
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/warn-version: v1.37
  annotations:
    security.example/exception-reason: "Demo record with an expiry more than 365 days out."
    security.example/exception-expires: "2028-01-01"
```

The wait for enforcement, which ran before the namespaces were applied,
printed:

<!-- gate: output -->
```
binding enforced after about 2 second(s)
```

<!-- gate: output -->
```
namespace/p05-09-restricted created
namespace/p05-09-exception created
Error from server (Invalid): error when creating "namespaces.yaml": namespaces "p05-09-no-expiry" is forbidden: ValidatingAdmissionPolicy 'p05-09-exception-expiry' with binding 'p05-09-exception-expiry' denied request: a namespace below restricted needs a reason and an expiry within 365 days
Error from server (Invalid): error when creating "namespaces.yaml": namespaces "p05-09-unlabelled" is forbidden: ValidatingAdmissionPolicy 'p05-09-exception-expiry' with binding 'p05-09-exception-expiry' denied request: a namespace below restricted needs a reason and an expiry within 365 days
Error from server (Invalid): error when creating "namespaces.yaml": namespaces "p05-09-too-long" is forbidden: ValidatingAdmissionPolicy 'p05-09-exception-expiry' with binding 'p05-09-exception-expiry' denied request: a namespace below restricted needs a reason and an expiry within 365 days
```

**Deliberate refusals.** The two errors above are the admission rule working.
The namespaces named in them are refused on purpose.

The next step lists which namespaces exist. The two refused names are absent.

<!-- gate: output -->
```
NAME                STATUS   AGE   ENFORCE
p05-09-restricted   Active   1s    restricted
p05-09-exception    Active   1s    baseline
```

Next the lab creates a service namespace at `restricted`, the level every
workload namespace in the guide uses. It then server dry-runs a complete
catalog Deployment in it. The Deployment carries the baseline in full. The
image is the guide's own build tag, which the
[baseline](../01-core-workloads/01-pods.md#baseline) allows, and it runs as
the UID the image declares.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: service
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.37
```

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: catalog
  namespace: service
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
  namespace: service
  labels:
    app.kubernetes.io/name: catalog
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: catalog
  template:
    metadata:
      labels:
        app.kubernetes.io/name: catalog
    spec:
      serviceAccountName: catalog
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: bookstore/catalog:dev
          ports:
            - containerPort: 8080
              name: http
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 128Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

<!-- gate: output -->
```
namespace/p05-09-service created
```

The Deployment is then checked by a server dry run, which creates nothing:

<!-- gate: output -->
```
serviceaccount/catalog created (server dry run)
deployment.apps/catalog created (server dry run)
```

The namespace's `default` ServiceAccount is created by a controller shortly
after the namespace. The lab waits for it before the next step, and the wait
prints its name:

<!-- gate: output -->
```
serviceaccount/default
```

**Deliberate failure.** The last Part 2 step asks the admission layer for a
privileged Pod in the same namespace. It is meant to be refused, and the
refusal names every PodSecurity field the Pod gets wrong:

<!-- gate: output -->
```
Error from server (Forbidden): pods "catalog-privileged" is forbidden: violates PodSecurity "restricted:v1.37": privileged (container "catalog-privileged" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "catalog-privileged" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "catalog-privileged" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "catalog-privileged" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "catalog-privileged" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

The lab then deletes what it created: the namespaces, and the policy and its
binding.

<!-- gate: output -->
```
namespace "p05-09-restricted" deleted
namespace "p05-09-exception" deleted
namespace "p05-09-service" deleted
```

Then the binding and the policy:

<!-- gate: output -->
```
validatingadmissionpolicybinding.admissionregistration.k8s.io "p05-09-exception-expiry" deleted
```

<!-- gate: output -->
```
validatingadmissionpolicy.admissionregistration.k8s.io "p05-09-exception-expiry" deleted
```

## Control mapping

Each published reference states its own controls. This section maps the
guide's controls to them, and says what each reference does not cover.

### CIS Kubernetes Benchmark

The section numbers below come from the `cis-1.12` profile in kube-bench
v0.16.0, which 05.06 <!-- link-later: 05.06 --> runs against the lab cluster.
CIS publishes a newer Kubernetes benchmark, which its site lists as version
2.1.0 at the time of checking. Its numbering may differ, so map against the
version your audit uses. Every policy in the `cis-1.12` profile is marked
"(Manual)", which means kube-bench does not check it. The platform evidences
each row another way: admission, the gates, or a dated review.

| CIS 1.12 | Control, abridged | Where this guide teaches it |
|---|---|---|
| 5.1.2 | Minimize access to secrets | [ch.01](01-authn-authz-rbac.md), path F |
| 5.1.3 | Minimize wildcard use in Roles and ClusterRoles | [ch.01](01-authn-authz-rbac.md) |
| 5.1.4 | Minimize access to create pods | [ch.01](01-authn-authz-rbac.md), path A |
| 5.1.5 | Ensure default service accounts are not actively used | The [baseline](../01-core-workloads/01-pods.md#baseline), with a dedicated ServiceAccount |
| 5.1.6 | Ensure service account tokens are only mounted where necessary | The baseline's `automountServiceAccountToken: false` |
| 5.1.8 | Limit use of the Bind, Impersonate and Escalate permissions | [ch.01](01-authn-authz-rbac.md), paths B, C and D |
| 5.1.10 | Minimize access to the proxy sub-resource of nodes | [ch.01](01-authn-authz-rbac.md), path E |
| 5.1.11 | Minimize access to the approval sub-resource of CSRs | [ch.01](01-authn-authz-rbac.md), path G |
| 5.2.2 | Minimize the admission of privileged containers | [ch.02](02-pod-security.md) and PodSecurity `restricted` |
| 5.2.3 | Minimize the admission of containers sharing the host PID namespace | [ch.02](02-pod-security.md) |
| 5.2.5 | Minimize the admission of containers sharing the host network namespace | [ch.02](02-pod-security.md) |
| 5.2.7 | Minimize the admission of root containers | The baseline's `runAsNonRoot` |
| 5.2.11 | Minimize the admission of HostPath volumes | [ch.02](02-pod-security.md) |
| 5.3.2 | Ensure that all Namespaces have NetworkPolicies defined | Part 02 ch.06, the default-deny policy <!-- link-later: 02.06 --> |
| 5.4.1 | Prefer Secrets as files over Secrets as environment variables | [ch.04](04-secrets-and-cluster-hardening.md) |
| 5.6.2 | Ensure the seccomp profile is set in Pod definitions | The baseline's `seccompProfile`, and [ch.05](05-kernel-isolation.md) |
| 5.6.4 | The default namespace should not be used | The guide's rule: no workload runs in `default` |

Read the CIS table as a checklist of questions for the platform, not as proof.
Each row names a control and where it is taught. The platform's evidence is
the admission result or the gate result for that control.

### NSA and CISA Kubernetes Hardening Guidance

The [Kubernetes Hardening
Guidance](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF),
published by NSA and CISA as version 1.2 in August 2022, groups its advice by
topic. The topics map onto this Part as follows.

| Topic | Where this Part covers it |
|---|---|
| Pod security | [ch.02](02-pod-security.md) and [ch.05](05-kernel-isolation.md) |
| Network separation | Part 02 ch.06 <!-- link-later: 02.06 --> |
| Authentication and authorization | [ch.01](01-authn-authz-rbac.md) |
| Secrets | [ch.04](04-secrets-and-cluster-hardening.md) |
| Audit logging and threat detection | Part 05 ch.08 <!-- link-later: 05.08 --> |
| Upgrades and supply chain | [ch.03](03-supply-chain.md) and Part 05 ch.06 <!-- link-later: 05.06 --> |

### NIST SP 800-190

[NIST SP 800-190](https://csrc.nist.gov/pubs/sp/800/190/final), *Application
Container Security Guide*, published in September 2017, groups container risk
into five categories: image, registry, orchestrator, container and host
operating system. The guide's chapters cover them as follows.

| Category | Where this guide covers it |
|---|---|
| Image | [ch.03](03-supply-chain.md): scans, SBOMs, digests and signing |
| Registry | [ch.03](03-supply-chain.md) and the signing chapter in Part 15 <!-- link-later: 15.03 --> |
| Orchestrator | [ch.01](01-authn-authz-rbac.md) for identity, and admission in 05.07 <!-- link-later: 05.07 --> |
| Container | [ch.02](02-pod-security.md), [ch.04](04-secrets-and-cluster-hardening.md) and [ch.05](05-kernel-isolation.md) |
| Host operating system | [ch.05](05-kernel-isolation.md) and the node chapter, 05.06 <!-- link-later: 05.06 --> |

## Security review checklist for new services

Use this checklist before a new service gets a namespace. Each line names the
control, the chapter that teaches it, and what evidence the reviewer reads.

- [ ] **A threat model entry**, with its reread triggers written in (this
      chapter). Evidence: the model file in the service's repository.
- [ ] **A dedicated ServiceAccount**, `automountServiceAccountToken: false`,
      and RBAC that names only the verbs the service uses
      ([ch.01](01-authn-authz-rbac.md)). Evidence: `kubectl auth can-i --list`
      for that ServiceAccount.
- [ ] **A namespace at `restricted`** for enforce, audit and warn, at the same
      version ([ch.02](02-pod-security.md)). Evidence: the namespace labels.
- [ ] **The baseline on every Pod**: a numeric non-root UID, `seccompProfile`
      `RuntimeDefault`, a read-only root, dropped capabilities, and requests
      with a memory limit ([01.01](../01-core-workloads/01-pods.md#baseline)
      and [01.03](../01-core-workloads/03-resources-and-qos.md)). Evidence: a
      server dry run in the namespace.
- [ ] **An image pinned by digest**, or the guide's own build tag, with its
      SBOM and scan attached in the pipeline ([ch.03](03-supply-chain.md)).
      Evidence: the pipeline's gate results.
- [ ] **A default-deny NetworkPolicy**, with explicit allows (Part 02 ch.06
  <!-- link-later: 02.06 -->). Evidence: the policy in the rendered manifests.
- [ ] **Secrets from a store and mounted as files**, not environment variables
      ([ch.04](04-secrets-and-cluster-hardening.md)). Evidence: the Pod spec.
- [ ] **A registry entry for every accepted finding or exception**, with a
      reason, the owner chapter, and an expiry within 12 months. Evidence: the
      registry files and the expiry stage's output.
- [ ] **An owner** who reads the service's findings queue and its runtime
      alerts (Part 05 ch.08 <!-- link-later: 05.08 -->). Evidence: the owner
      field in the model file.

## Cited, not run

Nothing in this guide runs on AWS or GCP, so the items below are cited, and
the chapter does not show their output.

- **Prowler** ([project](https://github.com/prowler-cloud/prowler)) checks
  cloud accounts, and its providers include AWS, GCP, Azure and Kubernetes.
  Not run. Account baselines on managed clouds are covered in Part 14 and Part
  15.
- **Dependency-Track**, described above. Not run: it needs an API server and a
  database.
- **A VEX scan** that suppresses a finding with a `not_affected` statement.
  Not run: a hand-written SBOM gave Trivy no results. The specification is
  cited above.
- **A clock-based expiry check in the admission layer.** A policy engine with a
  clock in its expression language could refuse a lapsed exception at admission.
  The engines in this guide are not used for it, and the lab did not test one.
  Not run.

## How it works under the hood

Four mechanisms in this chapter are easy to misread.

- **Trivy's ignore file.** Trivy reads the ignore file on each scan. An entry
  with `expired_at` applies until that date has passed. Trivy's filtering
  guide still marks the YAML form experimental, which is one reason the expiry
  stage exists: one scanner's date is not the only check.
- **The expiry stage.** `scan.sh expiry` reads each file line by line. A
  `Revisit by YYYY-MM-DD` comment, on the entry or directly above it, carries
  the date. A date before today's UTC date fails the stage. An entry with no
  date fails it. A file with no entries fails it too, so an empty check cannot
  pass silently.
- **The clock in admission.** During validating admission, the API server has
  set `metadata.creationTimestamp` before the policy runs, so the window is
  measured from it. The lab's admission step tests the window: an exception
  inside 365 days is admitted, and one beyond it is refused. CEL in this version
  has no current-time variable, so the policy cannot compare an expiry with
  today.
- **Namespace termination.** A deleted namespace stays `Terminating` until its
  controllers remove its content and the `kubernetes` finalizer. A stalled
  controller manager therefore holds the name, and that is why the script
  waits for leftovers before it starts.

## Production notes

- **Registry and expiry.** Keep the lists in the repository. Run the expiry
  stage on every pull request. Run a scheduled job against each cluster for
  namespace exceptions, since admission cannot see the date. Part 15 ch.10
  covers the on-call side when a finding becomes an incident ([incident
  response](../15-day-to-day-production-ops/10-incident-response-and-on-call.md)).
- **Identity and secrets.** The cloud identity that a service assumes is
  covered in [Part 10
  ch.03](../10-cloud-and-managed-kubernetes/03-cloud-identity.md). Secrets at
  scale are covered in [Part 11
  ch.05](../11-advanced-production-patterns/05-secrets-at-scale.md).
- **Supply chain at scale.** The provenance and signing pipeline runs in [Part
  14 ch.12](../14-eks-in-production-a-to-z/12-supply-chain-security.md) and
  [Part 15
  ch.03](../15-day-to-day-production-ops/03-image-signing-and-provenance.md).
- **Runtime detection.** [Part 14
  ch.13](../14-eks-in-production-a-to-z/13-runtime-defense-and-container-security.md)
  covers detection in production.

## Quick Reference

The secure forms only. Each block is a fragment, and the hands-on above shows
the complete manifests.

```yaml
# ci/trivyignore.yaml: a reason, and a date that Trivy enforces
vulnerabilities:
  - id: <scanner finding ID>
    statement: "<what is true here, and why the finding is accepted>"
    expired_at: <YYYY-MM-DD, no more than 12 months out>
# a namespace below restricted: the two annotations the admission rule checks
metadata:
  annotations:
    security.example/exception-reason: "<why this namespace is an exception>"
    security.example/exception-expires: "<YYYY-MM-DD, within 365 days of creation>"
```

| Question | Command |
|---|---|
| Would this namespace admit the Pod? | `kubectl apply --dry-run=server -f pod.yaml` |
| Does Trivy still honour an entry? | `trivy config --ignorefile <file> <path>` |
| Which registry lists have lapsed? | `REPORT_DIR=<dir> bash full-guide/examples/bookstore/ci/scan.sh expiry <files>` |
| Which namespaces are exceptions? | `kubectl get ns -L pod-security.kubernetes.io/enforce` |

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise;
> the answer is the check.

1. **Trivy honoured the entry in Part 1 with a date 180 days out, and reported
   the finding with a date 30 days back. What decides which result you see?**
   <details><summary>Show answer</summary>

   The scan date. The two entries differ only in `expired_at`. Trivy compares
   that date with the day the scan runs, so the entry dated 30 days back no
   longer suppresses the finding. Renewal is an edit to the file with a new
   date.

   </details>

2. **Why does the admission rule measure the window from `creationTimestamp`
   instead of from the current time? What does that leave unchecked?**
   <details><summary>Show answer</summary>

   This Kubernetes version's CEL has no clock. The server refused the
   expression that named `now`. The creation timestamp is available during
   validation, so the window is measured from it. It leaves unchecked whether
   an expiry has already passed. Only a scheduled check, or a scanner that
   reads the date, can catch that.

   </details>

3. **A teammate says the admission rule proves the exception is still valid
   today. What do you say?**
   <details><summary>Show answer</summary>

   It proves the record was well formed when it was created: a reason is
   present and the expiry is within the allowed window. Validity today needs a
   clock check. This is the security question the registry exists to keep
   open.

   </details>

4. **A row in the CIS table is marked "(Manual)". What does that mean for the
   platform?**
   <details><summary>Show answer</summary>

   kube-bench does not check the row automatically, so a clean kube-bench run
   says nothing about it. The platform must evidence the control another way,
   through admission, a gate, or a dated review.

   </details>

5. **`grype.yaml` has no expiry date of its own. Why is that acceptable, and
   what must change together?**
   <details><summary>Show answer</summary>

   Grype's ignore rules have no date field. The file's header ties the entry
   to the Trivy entry for the same finding, so Trivy's `expired_at` brings the
   gate back on the same day. Delete both entries together, or the gate keeps
   passing on one scanner and failing on the other.

   </details>

## Further reading

- [Validating Admission
  Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/):
  the policy, binding and CEL variables used in Part 2.
- [Common Expression Language in
  Kubernetes](https://kubernetes.io/docs/reference/using-api/cel/): the
  expression language and its functions.
- [Pod Security
  Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/):
  the `baseline` and `restricted` levels the namespaces use.
- [OpenVEX
  specification](https://github.com/openvex/spec/blob/main/OPENVEX-SPEC.md):
  the statuses and justifications for `not_affected`.
- [Dependency-Track documentation](https://docs.dependencytrack.org/): the
  component inventory that the SBOMs feed.
- [kube-bench](https://github.com/aquasecurity/kube-bench) and the [CIS
  Kubernetes Benchmarks](https://www.cisecurity.org/benchmark/kubernetes).
- [Kubernetes Hardening
  Guidance](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF),
  NSA and CISA, version 1.2.
- [NIST SP 800-190](https://csrc.nist.gov/pubs/sp/800/190/final), *Application
  Container Security Guide*.
- [Prowler](https://github.com/prowler-cloud/prowler): cited, not run.
