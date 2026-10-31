# 07: Admission control and policy as code

> Admission is the last check before the API server stores an object, and it
> is the one place every create and update passes through. This chapter shows
> what it can refuse that Pod Security cannot: a Service that asks for an
> external IP, a Pod that forgets the baseline, an image nobody signed. It
> teaches the two built-in policy kinds first, then Kyverno as the project's
> engine, then the same rule in Rego for Gatekeeper. Last, the same rules run
> in CI before any manifest reaches a cluster.

**Estimated time:** ~50 min read · ~40 min lab (scripted, shared mode) · ~30 min
more for the engines (full mode)
**Prerequisites:** [Part 05 ch.01](01-authn-authz-rbac.md): RBAC decides who may
ask for a change · [Part 05 ch.02](02-pod-security.md): Pod Security Admission
and the `restricted` level · [Part 05 ch.03](03-supply-chain.md): image digests
and signatures · [Part 01 ch.01](../01-core-workloads/01-pods.md#baseline): the
baseline, field by field

**You'll know after this:**

- place an admission check in the request path, before or after mutation
- write a ValidatingAdmissionPolicy in CEL and bind it to namespaces
- write a MutatingAdmissionPolicy that fills a default, and say what it cannot
  change
- roll a Kyverno rule out in Audit before Enforce, and read the report
- make an admission rule check an image signature, and say what a digest does
  not prove
- write the same rule as Rego for Gatekeeper, and run it in dry-run
- run the policy's unit tests and Conftest in CI, before the cluster sees the
  object

<!-- tags: security, admission, policy-as-code, validating-admission-policy, kyverno, gatekeeper -->

## Why this exists

[Chapter 02](02-pod-security.md) asked what a Pod may do once it runs, and
answered with Pod Security Admission at the `restricted` level. That answers one
question about one kind of object. A real cluster needs more questions answered
at the same door. Which Services may ask for an external IP? Which registry may
a Pod's image come from, and does the image carry a signature from a key the
team controls? Should a Pod that forgets the baseline get it anyway? None of
those is a Pod Security rule, and none of them can wait for a human reviewer.

Admission is where those checks run. Every create and update reaches it after
the caller has been authenticated and authorized, and before the object is
written to etcd. A check there refuses the object, or changes it, for every
client: `kubectl`, a GitOps controller, a CI job, and a token that someone
should not have. [Chapter 01](01-authn-authz-rbac.md) decided who may ask. This
chapter decides what the answer may contain.

Policy as code is the second half. A rule kept as a file can be unit-tested,
reviewed, and run in a pipeline before it reaches the cluster. The Bookstore
keeps one rule ID for each rule. The rule is written in Rego for CI, and the
cluster enforces the same rule in a form it can express, so a failure shows up
in the pull request rather than as a refused deploy.

## Mental model

A request passes through two admission phases, and the phase decides what a
check may do.

1. **Mutating admission** runs first. Built-in plugins, mutating webhooks and
   `MutatingAdmissionPolicy` may change the object. This is where a default
   goes in.
2. **Validating admission** runs second, on the object as it will be stored.
   Pod Security Admission, `ValidatingAdmissionPolicy`, and validating
   webhooks such as Kyverno and Gatekeeper may only accept or refuse. The
   [admission controllers
   page](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
   states the two phases in that order.

Three consequences follow. A validating check sees the defaults that a mutating
check added, so a rule can rely on them. A validating check cannot fix an
object, so a refused object has to be written again by its author. And a
mutation runs on every create it matches, so a mutation that is wrong is wrong
everywhere it matches. The lab below shows a mutation that changes a field and
leaves a volume the Pod already has, which is the limit to remember.

The four mechanisms in this chapter differ in where they run and what they can
change:

| Mechanism | Phase | Written as | Changes the object | Runs |
|---|---|---|---|---|
| `ValidatingAdmissionPolicy` | validating | CEL | no | in the API server |
| `MutatingAdmissionPolicy` | mutating | CEL | yes | in the API server |
| Kyverno `ClusterPolicy` | both | YAML patterns, plus `verifyImages` | yes | in a webhook, which can be down |
| Gatekeeper `ConstraintTemplate` | validating | Rego | no; audit reports objects that already exist | in a webhook, which can be down |

The built-in pair has no webhook to keep running, so it has no endpoint that can
time out. Kyverno covers what the pair cannot: signature checks and rules about
where an image came from. Gatekeeper is the same job written in Rego. The
Bookstore runs Kyverno, so the guide has one engine in production. The lab
installs Gatekeeper beside it to show that the rule ports, then removes it.

## Threats and controls

| Threat | Control this chapter teaches | Where it goes deeper |
|---|---|---|
| A Service asks for an external IP, so traffic meant for another address lands on this workload | `ValidatingAdmissionPolicy` refuses `spec.externalIPs` in labelled namespaces | [Service external IPs](https://kubernetes.io/docs/concepts/services-networking/service/#external-ips) |
| A tag moves to a different image after review | `ValidatingAdmissionPolicy` requires a digest on every third-party image, and refuses the `latest` tag | [05.03](03-supply-chain.md) |
| A Pod runs an image nobody signed, under a digest anyone can pin | Kyverno `verifyImages` checks the signature against a key or an identity | [cosign verify](https://docs.sigstore.dev/cosign/verifying/verify/); [05.03](03-supply-chain.md) |
| A workload forgets the seccomp profile | `MutatingAdmissionPolicy` fills in `RuntimeDefault` at admission | [01.01](../01-core-workloads/01-pods.md#baseline) |
| A workload gets the default ServiceAccount token | Set `automountServiceAccountToken: false` in the manifest, and check it in CI; a policy that only changes the field does not remove the volume | [01.01](../01-core-workloads/01-pods.md#baseline) |
| A rule is enforced in the cluster and forgotten in CI, or the reverse | One rule ID, written in Rego, unit-tested, and run by Conftest in CI | [07.03](../07-delivery/03-cicd-pipeline.md) |
| A new rule breaks running workloads on the day it is applied | Kyverno `Audit` first, then `Enforce`, with the report read in between | [11.01](../11-advanced-production-patterns/01-admission-webhooks.md) for webhooks you write yourself |

## Lab: attack, harden, re-attack

### Lab header

- **Tier A, two modes.** The lab runs against a kind cluster that you own. You
  name its kubectl context in `LAB_CONTEXT`, and the script refuses any other.
  `MODE=shared` runs the steps that install no engine, on one cluster.
  `MODE=full` installs Kyverno and then Gatekeeper on a cluster, one after the
  other, and removes each before the next. The full mode needs a cluster with
  internet access, because the signature checks read ghcr.io and the public
  Sigstore services, and a host with some CPU to spare, as the notes below
  show. The transcript below holds one recording of each mode.
- **Names.** The lab prefixes its objects with `p05-07`, as in `p05-07-open`.
  This chapter drops the prefix in its text, commands and manifests, so the
  namespace is `open`, and the `p05-07-kyverno` namespace is `kyverno-demo`.
  The captured output keeps the lab's names. The two recordings came from two
  lab clusters, with names different from the one this guide uses.
- **Script and transcript.**
  [`labs/05-07.sh`](../examples/security-lab/labs/05-07.sh) runs every command
  below and deletes what it creates. Its recorded output is
  [`evidence/05-07.txt`](../examples/security-lab/evidence/05-07.txt), whose
  header lists the 16 invocations of the full mode and what each one did. Both
  clusters ran a Kubernetes v1.37.0 server, and the client is kubectl v1.37.2.
- **What ran.** In the shared mode: step 0 (the tools), steps 5 and 6 (the
  attack, the policies, and the re-attack), step 12b (the API server's own
  refusal of `privileged: true` with `allowPrivilegeEscalation: false`, in a
  server dry run), step 13 (the policy checks), step 14 (the policies read
  back), and step 16 (the Kyverno and Gatekeeper charts rendered and checked
  against the cluster without being installed). In the full mode: Kyverno
  (chart 3.9.2, app v1.19.2) installed, a privileged Pod admitted in Audit and
  refused in Enforce, a `verifyImages` rule that admitted the Bookstore's signed
  catalog image at its production digest and refused an image with no
  signature, and then Gatekeeper (chart 3.23.1, app v3.23.1) with the same
  privileged rule, reporting in `dryrun` and refusing the same manifest in
  `deny`, and removed.
- **What did not run.** The Kyverno removal, in the form the script now has. It
  was run twice in an earlier form and neither run ended cleanly, and the lab
  removed what was left by hand. The section on removing an engine says what
  went wrong. Nothing else in the full mode is marked not run, and the earlier
  steps that built a throwaway cluster, a lab registry and a lab signing key
  are gone from the script. The full mode never got past cluster creation with
  them, on three attempts, and the Bookstore's own signed image tests the same
  rule against a real signature. The chart fields in the shared mode were
  checked against the pulled 3.9.2 chart, and the full mode ran them.
- **What went wrong in the full mode.** The lab cluster shares a host with other
  work, and its control plane Pods had restarted often before the lab began.
  The script stops when that restart count rises and removes what it installed.
  Seven of the 16 invocations did not run to the end for that reason, or
  because the API server stopped answering. The engines also made it worse:
  the first install, with four Kyverno controllers, never became ready. The
  chapter keeps these failures instead of the one clean run, because they are
  what an engine costs a small cluster.
- **Namespaces.** `open` enforces nothing and holds the attacks. The shared run
  creates it, labels it for the policies, and deletes it at the end. Step 12b
  creates `kyverno-demo` for two dry runs and deletes it. The full mode
  creates `kyverno-demo`, `signed`, `kyverno` and `gatekeeper-system`. The two
  engine namespaces carry the `restricted` Pod Security label, and the charts
  ran under it without an exception.
- **What did not work the first time.** A new namespace has no `default`
  ServiceAccount for a moment, and the API server refuses Pods in it until the
  controller creates one. The script waits for it. A busybox Pod that runs
  `sleep` as PID 1 ignored the stop signal on the lab cluster, and its
  namespace stayed in `Terminating` for minutes. The final run starts from an
  empty namespace list. The automount policy changed a field and did not
  remove a volume, which the harden section below shows in detail. In the full
  mode, Kyverno's default verification type found no signature on a signed
  image, and a busybox image was refused for a lookup timeout and not for a
  missing signature. The `verifyImages` section keeps both.

The versions come first, so that each claim in this header has a captured
source:

<!-- gate: output -->

```
Client Version: v1.37.2
Kustomize Version: v5.8.1
Server Version: v1.37.0
v4.1.4+g05fa379
GitVersion:    v3.1.4
Version: 1.22.0
Conftest: 0.71.1
Terraform v1.14.8
```

### Recon: the open namespace

The attacks run in a namespace with no Pod Security labels and no policy.
Start with the Service. A Service with an `externalIPs` entry answers for that
address on every node, so a tenant who may create Services can take traffic
meant for another address. The [Service
documentation](https://kubernetes.io/docs/concepts/services-networking/service/#external-ips)
describes the field, and the lab does not send traffic to it.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a Service that asks for an external IP. Lab cluster only.
apiVersion: v1
kind: Service
metadata:
  name: catalog-ext
  namespace: open
spec:
  selector:
    app: catalog
  ports:
    - port: 8080
      targetPort: 8080
  externalIPs:
    - 203.0.113.10
```

The address is from a documentation range that no real host should use, and the
lab sends no traffic to it. The API server admits the Service, and it warns that
the field is deprecated:

```sh
kubectl apply -f attack-service.yaml
```

<!-- gate: output -->

```
Warning: spec.externalIPs is deprecated and may no longer be implemented in some clusters
service/catalog-ext created
```

The second attack is a Pod that leaves out the baseline. It has no
`securityContext`, and it does not say whether to mount a ServiceAccount token.
The API server fills in neither, so the Pod runs with the default token and no
seccomp profile.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a Pod that leaves out the baseline. Lab cluster only.
# The default ServiceAccount token is mounted and seccomp is unset.
apiVersion: v1
kind: Pod
metadata:
  name: forgetful
  namespace: open
spec:
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "3600"]
```

The lab reads the Pod's own process status and its token directory. It does not
use the token.

```sh
kubectl apply -f attack-forgetful.yaml
kubectl -n open exec forgetful -- sh -c 'grep Seccomp: /proc/self/status | tr "\t" " "; ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>/dev/null | tr "\n" " "; echo'
kubectl -n open get pod forgetful -o jsonpath='{.spec.volumes[*].name}{"\n"}'
```

<!-- gate: output -->

```
Seccomp: 0
ca.crt namespace token 
# ...
kube-api-access-5z49c
```

`Seccomp: 0` means the process runs with no filter. The token directory is
there, so the Pod's identity is mounted and ready to use. The Pod's volumes
include a `kube-api-access` volume, which is the projected token. Neither
result is a bug. The API server did what it was asked, and nothing asked for
more.

### Harden: a policy the built-in pair can enforce

The first control is a `ValidatingAdmissionPolicy`. It is written in CEL, the
expression language the API server evaluates itself, so it needs no webhook and
no install. A policy holds the rule. A binding decides where the rule applies,
and it is a separate object, so the same policy can be bound to different
namespaces with different actions.

The policy below refuses a Service that sets `externalIPs`, in every namespace
that carries the lab label. The binding's `namespaceSelector` is what makes the
label matter.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: no-external-ips
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["services"]
  validations:
    - expression: "!has(object.spec.externalIPs) || size(object.spec.externalIPs) == 0"
      message: "a Service may not set spec.externalIPs"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: no-external-ips
spec:
  policyName: no-external-ips
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        lab-policies: "true"
```

`failurePolicy: Fail` means that an expression which cannot be evaluated refuses
the request. The alternative, `Ignore`, lets the request through, which is the
wrong default for a rule written to refuse. `validationActions: [Deny]` turns a
failed expression into a refusal. `[Audit]` or `[Warn]` would report it without
refusing.

The second policy is the digest rule. [05.03](03-supply-chain.md) explains why
a mutable tag is unsafe. A digest names the bytes, so the cluster can require
one:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: digest-pinned
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  variables:
    - name: images
      expression: "object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : [])"
  validations:
    - expression: "variables.images.all(c, c.image.contains('@sha256:') || c.image.startsWith('registry.example.com/bookstore/'))"
      message: "BK-POL-009: every third-party image must be pinned by digest"
      reason: Forbidden
    - expression: "variables.images.all(c, !c.image.endsWith(':latest'))"
      message: "BK-POL-009: no image may use the latest tag"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: digest-pinned
spec:
  policyName: digest-pinned
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        lab-policies: "true"
```

The rule follows the baseline rule `BK-POL-009` that CI runs. A third-party
image needs a digest, the `latest` tag is refused, and init containers are
checked as well as app containers. Images under
`registry.example.com/bookstore/` are exempt from the digest, because the
Bookstore builds them and they carry the tag its build produced.

A digest is not a signature. The rule says which bytes may run, not who made
them. The verifyImages section below deals with that gap.

The second kind of control is a `MutatingAdmissionPolicy`, which is GA in
Kubernetes 1.36. It fills in a default when the author left a field out, and
it does not overwrite a value the author set. The lab uses two. One sets the
seccomp profile to `RuntimeDefault` when the Pod does not set one. The other
sets `automountServiceAccountToken` to `false` when the Pod does not say.

Each policy runs only when a condition holds. `matchConditions` is the guard,
and the mutation is an apply configuration that the API server merges with the
server-side apply strategy. A field the apply configuration does not name is
left alone, and a field it names is set.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: default-automount-off
spec:
  failurePolicy: Fail
  reinvocationPolicy: IfNeeded
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  matchConditions:
    - name: automount-unset
      expression: "!has(object.spec.automountServiceAccountToken)"
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >-
          Object{
            spec: Object.spec{
              automountServiceAccountToken: false
            }
          }
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: default-automount-off
spec:
  policyName: default-automount-off
  matchResources:
    namespaceSelector:
      matchLabels:
        lab-policies: "true"
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: default-seccomp
spec:
  failurePolicy: Fail
  reinvocationPolicy: IfNeeded
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  matchConditions:
    - name: seccomp-unset
      expression: "!has(object.spec.securityContext) || !has(object.spec.securityContext.seccompProfile)"
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >-
          Object{
            spec: Object.spec{
              securityContext: Object.spec.securityContext{
                seccompProfile: Object.spec.securityContext.seccompProfile{
                  type: "RuntimeDefault"
                }
              }
            }
          }
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: default-seccomp
spec:
  policyName: default-seccomp
  matchResources:
    namespaceSelector:
      matchLabels:
        lab-policies: "true"
```

`reinvocationPolicy: IfNeeded` asks for the mutation to run again if a later
mutation changes the Pod. The two policies here do not depend on each other,
so the setting changes nothing in this lab. The [mutating admission policy
page](https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/)
describes it.

A default is a guess the policy makes for every Pod it matches. The seccomp
default is `RuntimeDefault` because the baseline asks for it. The policy does
not judge the workload, and a Pod that needs a different profile must set one,
which the mutation then leaves alone.

Apply the four objects, then label the attacked namespace so the bindings select
it. The labelling is the switch. The namespace did not change, and the policies
started to apply to it.

```sh
kubectl apply -f vap-no-external-ips.yaml -f vap-digest-pinned.yaml -f map-automount-off.yaml -f map-seccomp.yaml
kubectl label namespace open lab-policies=true
```

<!-- gate: output -->

```
validatingadmissionpolicy.admissionregistration.k8s.io/p05-07-no-external-ips created
validatingadmissionpolicybinding.admissionregistration.k8s.io/p05-07-no-external-ips created
validatingadmissionpolicy.admissionregistration.k8s.io/p05-07-digest-pinned created
validatingadmissionpolicybinding.admissionregistration.k8s.io/p05-07-digest-pinned created
mutatingadmissionpolicy.admissionregistration.k8s.io/p05-07-default-automount-off created
mutatingadmissionpolicybinding.admissionregistration.k8s.io/p05-07-default-automount-off created
mutatingadmissionpolicy.admissionregistration.k8s.io/p05-07-default-seccomp created
mutatingadmissionpolicybinding.admissionregistration.k8s.io/p05-07-default-seccomp created
# ...
namespace/p05-07-open labeled
```

### Re-attack: the same namespace, now with the policies

Run the Service attack again. A new name is needed, because applying the first
Service unchanged would not reach admission at all.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a Service that asks for an external IP. Lab cluster only.
apiVersion: v1
kind: Service
metadata:
  name: catalog-ext-2
  namespace: open
spec:
  selector:
    app: catalog
  ports:
    - port: 8080
      targetPort: 8080
  externalIPs:
    - 203.0.113.10
```

```sh
kubectl apply -f attack-service-2.yaml
```

<!-- gate: output -->

```
Warning: spec.externalIPs is deprecated and may no longer be implemented in some clusters
Error from server (Forbidden): error when creating "attack-service-2.yaml": services "catalog-ext-2" is forbidden: ValidatingAdmissionPolicy 'p05-07-no-external-ips' with binding 'p05-07-no-external-ips' denied request: a Service may not set spec.externalIPs
```

The refusal names the policy and the binding, and it carries the message the
policy wrote. A reader who meets this error in a cluster can find the rule in
one command, which is the point of naming it.

The digest rule is next. This Pod is complete and passes the `restricted` level.
The only thing wrong with it is the tag, and the digest rule is the control that
refuses it. Nothing else in the Pod is insecure, so it carries no marker:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: tag-only
  namespace: open
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: registry.lab-registry.svc.cluster.local:5000/bookstore/catalog:lab
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 50m, memory: 32Mi}
        limits: {memory: 64Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

```sh
kubectl apply -f tag-only.yaml
```

<!-- gate: output -->

```
Error from server (Forbidden): error when creating "tag-only.yaml": pods "tag-only" is forbidden: ValidatingAdmissionPolicy 'p05-07-digest-pinned' with binding 'p05-07-digest-pinned' denied request: BK-POL-009: every third-party image must be pinned by digest
```

The image in that Pod names a registry that this lab does not run. The refusal
happens before any pull, so the lab needs no registry for it.

The forgetful Pod, written the same way as before, now comes back with the
policies' defaults. Read the output in two parts. The stored Pod says `false`
and `RuntimeDefault`, and the process reads `Seccomp: 2`, which is a filter.
The token volume is still there:

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a Pod that leaves out the baseline. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: forgetful-2
  namespace: open
spec:
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "3600"]
```

```sh
kubectl apply -f forgetful-2.yaml
kubectl -n open get pod forgetful-2 -o jsonpath='{.spec.automountServiceAccountToken}{" "}{.spec.securityContext.seccompProfile.type}{"\n"}'
kubectl -n open exec forgetful-2 -- sh -c 'grep Seccomp: /proc/self/status | tr "\t" " "; ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>/dev/null | tr "\n" " "; echo'
kubectl -n open get pod forgetful-2 -o jsonpath='{.spec.volumes[*].name}{"\n"}'
```

<!-- gate: output -->

```
false RuntimeDefault
# ...
Seccomp: 2
ca.crt namespace token 
# ...
kube-api-access-lwdnx
```

The volume list shows a `kube-api-access` volume on this Pod, as it did on the
attack Pod. That is the finding of this section. The automount policy changed
the field, and the Pod still carries the projected token volume, so the token
is still mounted. A policy that sets a field does not take back a volume that
is already part of the Pod. The seccomp default worked, because the kubelet
reads the seccomp field from the stored Pod, and the token did not, because
the volume is a separate part of the Pod.

The control that does work for the token is the manifest. A Pod that sets
`automountServiceAccountToken: false` itself never asks for the volume. The
baseline Pod below does exactly that, with the rest of the baseline in full:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: baseline
  namespace: open
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 32Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

```sh
kubectl apply -f baseline.yaml
kubectl -n open exec baseline -- sh -c 'ls /var/run/secrets/kubernetes.io/serviceaccount 2>&1; echo'
```

<!-- gate: output -->

```
ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
```

Check the stored object and the running process, as the lab does, not the file
in the repository. A reviewer who reads a manifest sees the fields its author
wrote. The shift-left section below is how a repository catches a Pod that
leaves them out, before it is applied.

### Kyverno: the project's engine

The built-in pair covers defaults, shape, and a fixed set of fields. It cannot
read a signature, and it has no way to say where an image came from beyond what
the expression sees. Kyverno is the project's engine for those rules. It runs as
a webhook, so it has to be installed and kept up, which is why it is the second
choice and not the first.

The install pins the chart, and it labels the namespace `restricted` first, so
the chart's Pods must meet that level to run. The chart's metadata shows what
the pin refers to:

```sh
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
helm show chart kyverno/kyverno --version 3.9.2 | grep -E '^(name|version|appVersion|kubeVersion):'
kubectl create namespace kyverno
kubectl label namespace kyverno pod-security.kubernetes.io/enforce=restricted
```

<!-- gate: output -->

```
appVersion: v1.19.2
kubeVersion: '>=1.25.0-0'
name: kyverno
version: 3.9.2
```

Eight `--set` flags differ from the chart's defaults, and every one of them
makes the install smaller, because the lab host was small and busy:

- `admissionController.replicas=1` and `reportsController.replicas=1`: one
  replica each. The chart warns that one admission controller is not highly
  available, and a lab does not need it to be.
- `backgroundController.enabled=false` and `cleanupController.enabled=false`:
  no background controller, which serves generate and mutate-existing rules, and
  no cleanup controller, which serves TTL cleanup. This chapter uses neither.
- `features.generateValidatingAdmissionPolicy.enabled=false` and
  `features.validatingAdmissionPolicyReports.enabled=false`: the chart switches
  both on, and they add watches on the API server.
- `admissionController.dnsConfig` with `ndots` set to `1`: a name with a dot is
  looked up as written, not after five search suffixes. The lab added it
  because lookups from the admission controller had timed out. It did not cure
  every timeout, as the verifyImages section shows, so treat it as a precaution
  and not as the fix.

```sh
helm upgrade --install kyverno kyverno/kyverno --version 3.9.2 --namespace kyverno \
  --set admissionController.replicas=1 --set reportsController.replicas=1 \
  --set backgroundController.enabled=false --set cleanupController.enabled=false \
  --set features.generateValidatingAdmissionPolicy.enabled=false \
  --set features.validatingAdmissionPolicyReports.enabled=false \
  --set-string 'admissionController.dnsConfig.options[0].name=ndots' \
  --set-string 'admissionController.dnsConfig.options[0].value=1'
kubectl -n kyverno get deploy
```

<!-- gate: output -->

```
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller   1/1     1            1           4m
kyverno-reports-controller     1/1     1            1           4m
```

The lab does not use `helm --wait` for this install. It polls the Deployments
instead, and it checks the restart count of the control plane Pods every ten
seconds, because `--wait` cannot stop for a control plane that is falling over.
The first install ran four controllers, one replica each, with `--wait`. The
admission controller was not ready after seven minutes, and helm gave up:

<!-- gate: output -->

```
Error: resource Deployment/kyverno/kyverno-admission-controller not ready. status: InProgress, message: Available: 0/1
context deadline exceeded

FAILED: the Kyverno install did not finish
```

The reduced install passed in four of the seven times the lab ran it, and the
lab's guard stopped it in the other three because the control plane Pods of the
lab cluster restarted. The transcript keeps all of them. A webhook engine is a
dependency of every write to the API server, and on a cluster that is short of
CPU and disk, installing it was the heaviest step of this chapter.

The step 16 output of the shared run also shows that the 3.9.2 chart still
serves `kyverno.io/v1 ClusterPolicy`, and that its CRD marks the kind
deprecated. The same warning appears on every `kubectl` call that touches a
`ClusterPolicy` in this lab. It names ValidatingPolicy, MutatingPolicy,
GeneratingPolicy and ImageValidatingPolicy as the replacements, and points to a
migration guide at <https://kyverno.io/docs/guides/migration-to-cel/>. This
chapter keeps the `ClusterPolicy` form, because the pinned chart is the one the
lab installs. It uses the fields the same CRD still accepts: the rule-level
`failureAction` under `validate`, and `failureAction` under each `verifyImages`
entry. The policy-level `validationFailureAction` is deprecated in the same CRD.
A rule written for a later Kyverno release moves to one of the policy kinds the
warning names.

The shared run rendered the same chart with its default values and did not
install it. Its output is the rendered manifest count and the images the chart
names:

<!-- gate: output -->

```
80
# ...
1
# ...
image: "ghcr.io/kyverno/readiness-checker:v1.19.2"
image: "reg.kyverno.io/kyverno/background-controller:v1.19.2"
image: "reg.kyverno.io/kyverno/cleanup-controller:v1.19.2"
image: "reg.kyverno.io/kyverno/kyverno-cli:v1.19.2"
```

Those images are referenced by tag, not digest. A production install should pin
them by digest, as [05.03](03-supply-chain.md) pins third-party images. The Rego
rule `BK-POL-009` refuses a third-party image that has no digest, so a Pod built
from this chart would fail it until the tags are pinned.

### Audit before Enforce

A new rule can break workloads that already run. The safe order is Audit first:
the rule is evaluated, the result is recorded, and nothing is refused. Read the
report, fix or excuse what it shows, then switch to Enforce.

The privileged Pod below is the attack for this section. A privileged container
holds every capability and sees the node's devices. Inside a kind node that is
still a container, and its kernel is the one the node shares with the host, so
the lab does not run anything that would reach it. The Pod is admitted, and the
policy only reports it. Its node selector names a label that no node carries,
so the Pod stays Pending and its privileged container never starts, and its
image is never pulled. The image is the Bookstore catalog at the digest the
production overlay pins. The manifest carries the rest of the baseline. The one
field that is the attack is `privileged: true`. The baseline's
`allowPrivilegeEscalation: false` cannot sit beside it, so the field is left
out. The API server refuses that pair before any policy runs, as the dry run
below shows:

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a privileged container, which the Kyverno rule refuses. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-node
  namespace: kyverno-demo
spec:
  nodeSelector:
    lab-never-scheduled: "true"
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: ghcr.io/abd-ulbasit/bookstore-catalog@sha256:eaa26ada0a2e1575026a5e71e74572ed0bfdde80f50012e91a7be28f0de16ced
      securityContext:
        privileged: true
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 50m, memory: 32Mi}
        limits: {memory: 64Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

The API server checks the pair before admission runs. The shared run used
busybox for the image, because a server dry run does not pull it, and it used
a namespace with no Pod Security label:

```sh
kubectl create namespace kyverno-demo
kubectl apply --dry-run=server -f escape-conflict.yaml; echo "server dry-run exit=$?"
kubectl apply --dry-run=server -f escape-node-dryrun.yaml; echo "server dry-run exit=$?"
```

<!-- gate: output -->

```
namespace/p05-07-kyverno created
```

<!-- gate: output -->

```
The Pod "escape-node" is invalid: spec.containers[0].securityContext: Invalid value: {"Capabilities":{"Add":null,"Drop":["ALL"]},"Privileged":true,"SELinuxOptions":null,"WindowsOptions":null,"RunAsUser":null,"RunAsGroup":null,"RunAsNonRoot":null,"ReadOnlyRootFilesystem":true,"AllowPrivilegeEscalation":false,"ProcMount":null,"SeccompProfile":null,"AppArmorProfile":null}: cannot set `allowPrivilegeEscalation` to false and `privileged` to true
server dry-run exit=1
```

<!-- gate: output -->

```
pod/escape-node created (server dry run)
server dry-run exit=0
```

The refusal names both fields, and the second dry run, with the field left
out, is accepted. The policy names the rule with the same ID the Rego rule
uses later, so one ID follows the rule from the cluster to CI:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
  annotations:
    policies.kyverno.io/title: Disallow privileged containers
    policies.kyverno.io/description: The Bookstore rule BK-POL-001, enforced at admission.
spec:
  background: true
  rules:
    - name: no-privileged-containers
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [kyverno-demo]
      validate:
        failureAction: Audit
        message: "BK-POL-001: privileged containers are not allowed"
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): false
```

The `=(...)` anchors make a field optional: a container with no
`securityContext` passes, and one that sets `privileged` must set it to
`false`. The rule sets `failureAction: Audit` under `validate`, so the policy
reports a violation and admits the Pod. The 3.9.2 CRD marks the policy-level
`validationFailureAction` as deprecated in favour of this rule-level field.

```sh
kubectl apply -f policy-disallow-privileged.yaml
kubectl wait --for=condition=Ready clusterpolicy/disallow-privileged --timeout=120s
kubectl apply -f escape-node.yaml
kubectl -n kyverno-demo get pod escape-node -o jsonpath='{.metadata.name} admitted, privileged={.spec.containers[0].securityContext.privileged}{"\n"}'
kubectl -n kyverno-demo get ephemeralreports,policyreports
kubectl -n kyverno-demo get ephemeralreports -o jsonpath='{range .items[*].spec.results[*]}{.policy}{" "}{.rule}{" "}{.result}{" "}{.message}{"\n"}{end}'
```

<!-- gate: output -->

```
escape-node admitted, privileged=true
```

The Pod is admitted, which is what Audit means. The admission controller
recorded the result as an `EphemeralReport` with the source `admission`, one
failure, and the Pod as its owner. Kyverno's reports controller aggregates
those into a `PolicyReport` that lists every result for a namespace. The lab
read the reports 95 seconds after the Pod, and the table lists only the
ephemeral report. The `PolicyReport` had not been written yet, so read the
ephemeral report, which holds the policy, the rule, the result and the message:

<!-- gate: output -->

```
NAME                                                                            SOURCE      GROUP   KIND   OWNER         PASS   FAIL   WARN   ERROR   SKIP   AGE
ephemeralreport.reports.kyverno.io/5bd70a7d-fd29-4bf5-9173-eafd6752cdb8-bxzv9   admission           Pod    escape-node   0      1      0      0       0      95s
```

<!-- gate: output -->

```
p05-07-disallow-privileged no-privileged-containers fail validation error: BK-POL-001: privileged containers are not allowed. rule no-privileged-containers failed at path /spec/containers/0/securityContext/privileged/
```

That is what Audit is for. The report is the list of work a team must do before
it can move to Enforce, and a namespace with a long list is not ready.

### Enforce

Switch the same policy to Enforce, and send the same kind of Pod again. Use a
new name:

```sh
kubectl patch clusterpolicy disallow-privileged --type json -p '[{"op":"replace","path":"/spec/rules/0/validate/failureAction","value":"Enforce"}]'
kubectl apply -f escape-node-2.yaml; echo "apply exit=$?"
```

`escape-node-2.yaml` is `escape-node.yaml` with its name changed. Kyverno
refuses it, with the same rule ID in the message, which is the rule that CI
runs later:

<!-- gate: output -->

```
Error from server: error when creating "escape-node-2.yaml": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/p05-07-kyverno/escape-node-2 was blocked due to the following policies 

p05-07-disallow-privileged:
  no-privileged-containers: 'validation error: BK-POL-001: privileged containers are not allowed. rule no-privileged-containers failed at path /spec/containers/0/securityContext/privileged/'
apply exit=1
```

Kyverno names this webhook `svc-fail`, and the lab saw a request refused when
the webhook could not answer in time, which the verifyImages section keeps. A
rule that refuses everything proves nothing, so the lab also sent a Pod with
`allowPrivilegeEscalation: false` in place of `privileged: true`. The same
engine admitted it, and the namespace holds the Audit Pod and the compliant
one, and not the refused one:

<!-- gate: output -->

```
pod/compliant created

$ kubectl -n p05-07-kyverno get pods -o name
pod/compliant
pod/escape-node
```

### verifyImages: the signature, not only the digest

The digest rule says which bytes may run. It does not say that someone the team
trusts built them. [07.03](../07-delivery/03-cicd-pipeline.md) signs the
Bookstore images keyless from CI, and the identity they are signed as is the
workflow that built them, not a person and not a key. This section makes the
cluster check that identity before it admits a Pod. It uses the image the guide
really publishes, `ghcr.io/abd-ulbasit/bookstore-catalog`, at the digest the
production overlay pins. Read the digest from the rendered overlay, and check
the signature from your workstation first, with the identity from 07.03:

```sh
kubectl kustomize full-guide/examples/bookstore/kustomize/overlays/prod | grep -o 'ghcr.io/abd-ulbasit/bookstore-catalog@sha256:[0-9a-f]*' | sort -u
IMAGE=ghcr.io/abd-ulbasit/bookstore-catalog@sha256:eaa26ada0a2e1575026a5e71e74572ed0bfdde80f50012e91a7be28f0de16ced
ID=https://github.com/abd-ulbasit/bookstore-kubernetes-guide/.github/workflows/bookstore-pipeline.yml@refs/heads/main
DOCKER_CONFIG=$(mktemp -d) cosign verify --certificate-identity "$ID" --certificate-oidc-issuer https://token.actions.githubusercontent.com "$IMAGE" >/dev/null 2>verify.err; echo "cosign verify exit=$?"; grep -E '^(Verification for|  - )' verify.err
```

<!-- gate: output -->

```
ghcr.io/abd-ulbasit/bookstore-catalog@sha256:eaa26ada0a2e1575026a5e71e74572ed0bfdde80f50012e91a7be28f0de16ced
# ...
cosign verify exit=0
Verification for ghcr.io/abd-ulbasit/bookstore-catalog@sha256:eaa26ada0a2e1575026a5e71e74572ed0bfdde80f50012e91a7be28f0de16ced --
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

The policy below makes the cluster ask the same question. It covers every image
in the namespace `signed`, and it names the issuer and the subject that
07.03 verifies:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-signed-images
  annotations:
    policies.kyverno.io/title: Verify image signatures
    policies.kyverno.io/description: Pods in signed run only images that the Bookstore pipeline signed.
spec:
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: signed-by-the-pipeline
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [signed]
      verifyImages:
        - imageReferences:
            - "*"
          type: SigstoreBundle
          verifyDigest: true
          required: true
          failureAction: Enforce
          attestors:
            - entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "https://github.com/abd-ulbasit/bookstore-kubernetes-guide/.github/workflows/bookstore-pipeline.yml@refs/heads/main"
                    rekor:
                      url: https://rekor.sigstore.dev
```

`required: true` turns an image with no matching signature into a refusal,
rather than a pass with a warning. `verifyDigest: true` makes Kyverno check that
the digest in the Pod is the digest it verified, and `imageReferences: ["*"]`
puts every image in the namespace under the rule. The `issuer` and `subject`
are matched as written, so the subject is the whole string, branch included,
just as in 07.03: a signature made by the same workflow on another branch does
not match. The `rekor` block names the public transparency log, and the check
of the log entry stays on, because the pipeline's signature has an entry in it.
The fields are in the 3.9.2 CRD, and the [verify-images
overview](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/overview/)
describes them.

`type: SigstoreBundle` is not decoration. The CRD lists three types, `Cosign`,
`SigstoreBundle` and `Notary`, and says `Cosign` is the default. The lab's
first run that reached the registry used the default, and Kyverno found nothing
to verify on the image that the workstation had just verified:

<!-- gate: output -->

```
  signed-by-the-pipeline: 'failed to verify image ghcr.io/abd-ulbasit/bookstore-catalog@sha256:eaa26ada0a2e1575026a5e71e74572ed0bfdde80f50012e91a7be28f0de16ced: .attestors[0].entries[0].keyless: no signatures found'
```

With `type: SigstoreBundle` the same image, in the same namespace, verified. The
lab does not trace why the default type missed it. It cites the two results,
and it leaves the choice of type to the pipeline that signs: check how yours
stores its signatures before you write the rule.

The Pod below is the Bookstore catalog with the full baseline and the digest.
It carries the same node selector as before, so it is admitted and stays
Pending, and the image is never pulled:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: catalog
  namespace: signed
spec:
  nodeSelector:
    lab-never-scheduled: "true"
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: ghcr.io/abd-ulbasit/bookstore-catalog@sha256:eaa26ada0a2e1575026a5e71e74572ed0bfdde80f50012e91a7be28f0de16ced
      ports:
        - containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 50m, memory: 32Mi}
        limits: {memory: 64Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

```sh
kubectl create namespace signed
kubectl apply -f policy-verify-signed.yaml
kubectl wait --for=condition=Ready clusterpolicy/verify-signed-images --timeout=120s
kubectl apply -f catalog-signed.yaml
kubectl -n signed get pod catalog -o jsonpath='{.metadata.annotations.kyverno\.io/verify-images}{"\n"}'
```

The Pod is admitted, and Kyverno records its decision on the object in an
annotation:

<!-- gate: output -->

```
pod/catalog created

$ kubectl -n p05-07-signed get pod catalog -o jsonpath='{.metadata.annotations.kyverno\.io/verify-images}{"\n"}'
{"ghcr.io/abd-ulbasit/bookstore-catalog@sha256:eaa26ada0a2e1575026a5e71e74572ed0bfdde80f50012e91a7be28f0de16ced":"pass"}
```

Now the image nobody on the pipeline signed. The lab needed an image that a
cluster can reach and that carries no signature under any identity. It reads one
from the cluster: the init container image of Kyverno's own admission
controller, at the digest the node pulled. `cosign verify` with a pattern that
accepts every identity finds nothing to verify:

```sh
kubectl -n kyverno get pod -l app.kubernetes.io/component=admission-controller -o jsonpath='{.items[0].status.initContainerStatuses[0].imageID}{"\n"}'
DOCKER_CONFIG=$(mktemp -d) cosign verify --certificate-identity-regexp '.*' --certificate-oidc-issuer-regexp '.*' reg.kyverno.io/kyverno/kyvernopre@sha256:27f3cc52e628559b56d08363b85316819802086c9808606914f7805a244148f4 >/dev/null 2>verify-unsigned.err; echo "cosign verify exit=$?"; head -n 1 verify-unsigned.err
```

<!-- gate: output -->

```
reg.kyverno.io/kyverno/kyvernopre@sha256:27f3cc52e628559b56d08363b85316819802086c9808606914f7805a244148f4
# ...
cosign verify exit=10
Error: no signatures found
```

The Pod is the catalog Pod with that image. It has a digest, which is all the
digest rule asks for, and the rest of the baseline is the same:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: unsigned
  namespace: signed
spec:
  nodeSelector:
    lab-never-scheduled: "true"
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: reg.kyverno.io/kyverno/kyvernopre@sha256:27f3cc52e628559b56d08363b85316819802086c9808606914f7805a244148f4
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 50m, memory: 32Mi}
        limits: {memory: 64Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

```sh
kubectl apply -f unsigned.yaml; echo "apply exit=$?"
kubectl -n signed get pods -o name
```

Kyverno refuses it. The message says that it could not verify the image, and
that no matching signature exists. The rule worked, and the image failed it,
which is the distinction to look for when you debug a refusal:

<!-- gate: output -->

```
Error from server: error when creating "unsigned.yaml": admission webhook "mutate.kyverno.svc-fail" denied the request: 

resource Pod/p05-07-signed/unsigned was blocked due to the following policies 

p05-07-verify-signed-images:
  signed-by-the-pipeline: 'failed to verify image reg.kyverno.io/kyverno/kyvernopre@sha256:27f3cc52e628559b56d08363b85316819802086c9808606914f7805a244148f4: .attestors[0].entries[0].keyless: sigstore bundle verification failed: no matching signatures found'
apply exit=1

$ kubectl -n p05-07-signed get pods -o name
pod/catalog
```

That is the control the chapter set out to show. A digest alone would have
admitted both Pods. The signature rule admitted the one the pipeline built and
refused the one it did not.

Two earlier runs of this step are worth keeping, because they refused a Pod for
a reason that proves nothing about signatures. The first used busybox, pinned by
digest, as the unsigned image. Kyverno refused it, and the reason it gave was a
lookup that timed out, not a missing signature:

<!-- gate: output -->

```
  signed-by-the-pipeline: 'failed to verify image docker.io/busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662: .attestors[0].entries[0].keyless: Get "https://index.docker.io/v2/": dial tcp: lookup index.docker.io: i/o timeout'
```

The lookup kept timing out for Docker Hub names, with and without the `ndots`
option, while names on ghcr.io and reg.kyverno.io resolved in the later runs.
The lab did not find the cause, and it is why the lab dropped busybox for this
step. An earlier run, before the `ndots` option, showed what a webhook that
cannot finish does. The signed Pod hit the webhook's 30 second limit, and the
API server refused the Pod instead of admitting it:

<!-- gate: output -->

```
Error from server (InternalError): error when creating "catalog-signed.yaml": Internal error occurred: failed calling webhook "mutate.kyverno.svc-fail": failed to call webhook: Post "https://kyverno-svc.kyverno.svc:443/mutate/fail?timeout=30s": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
```

That refusal is the failure policy at work. It is the safe direction for a
security control, and it is also how a slow registry or a slow resolver stops a
deploy, so the production notes below say to plan for it.

The identity here is a workflow, which is the form a pipeline can keep without
holding a key. A rule that names a key instead is also possible: `keys` in
place of `keyless`, with the public key in a Secret. This chapter does not run
that form. The keyless form is what [07.03](../07-delivery/03-cicd-pipeline.md)
produces, so it is the form the cluster should check.

The rule starts in Enforce with no Audit run before it. The `signed` namespace
is new, and it holds only the Pods the lab creates, so no running workload
exists for an Audit report to find. A rule that could refuse running workloads
starts in Audit, as the privileged rule does.

### Gatekeeper: the same rule in Rego, side by side

Gatekeeper is the other common engine. It takes its rules in Rego, which is also
what OPA runs in the shift-left section below. The lab removes Kyverno first,
then installs Gatekeeper, writes the same privileged rule, and runs it in
dry-run and then in deny. Dry-run denies nothing at admission, and it reports
objects that already exist, which Kyverno's Audit mode did for the privileged
Pod. The lab keeps that Pod, so Gatekeeper finds it.

The install follows the same pattern as Kyverno's: a restricted label first,
then a pinned chart, with one replica so the lab stays small:

```sh
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts --force-update
helm show chart gatekeeper/gatekeeper --version 3.23.1 | grep -E '^(name|version|appVersion|kubeVersion):'
kubectl create namespace gatekeeper-system
kubectl label namespace gatekeeper-system pod-security.kubernetes.io/enforce=restricted
helm upgrade --install gatekeeper gatekeeper/gatekeeper --version 3.23.1 --namespace gatekeeper-system --set replicas=1
kubectl -n gatekeeper-system get deploy
```

<!-- gate: output -->

```
appVersion: v3.23.1
name: gatekeeper
version: 3.23.1
```

<!-- gate: output -->

```
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
gatekeeper-audit                1/1     1            1           2m30s
gatekeeper-controller-manager   1/1     1            1           2m30s
```

The chart installed under the `restricted` label with no exception. A
`ConstraintTemplate` holds the Rego. The constraint is an instance of it, with
the enforcement action and the scope:

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: noprivileged
spec:
  crd:
    spec:
      names:
        kind: NoPrivileged
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package noprivileged

        violation[{"msg": msg}] {
          c := input_containers[_]
          c.securityContext.privileged == true
          msg := sprintf("BK-POL-001 container %v runs privileged", [c.name])
        }

        input_containers[c] {
          c := input.review.object.spec.containers[_]
        }

        input_containers[c] {
          c := input.review.object.spec.initContainers[_]
        }
```

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: NoPrivileged
metadata:
  name: no-privileged
spec:
  enforcementAction: dryrun
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces: ["kyverno-demo"]
```

The rule has two `input_containers` clauses on purpose: a privileged init
container is as dangerous as a privileged app container, and the rule must
check both. The Kyverno pattern above checks `containers` only, so the two
rules do not match exactly. That difference is real, and the shift-left rule
below checks both.

The audit lists what already exists, so it reports the Pod that Kyverno
admitted in Audit mode. The lab waits for the audit, reads the constraint's
status, and then sends the same Pod that Kyverno refused, still in dry-run:

```sh
kubectl apply -f gatekeeper-template.yaml
kubectl wait --for=condition=Established crd/noprivileged.constraints.gatekeeper.sh --timeout=120s
kubectl apply -f gatekeeper-constraint.yaml
kubectl get noprivileged no-privileged -o jsonpath='{.spec.enforcementAction}{" "}{.status.totalViolations}{"\n"}'
kubectl get noprivileged no-privileged -o jsonpath='{.status.violations[0].message}{"\n"}'
kubectl apply -f escape-node-2.yaml
kubectl delete pod escape-node-2 -n kyverno-demo --wait=true
```

<!-- gate: output -->

```
dryrun 1
# ...
BK-POL-001 container app runs privileged
# ...
pod/escape-node-2 created
```

Dry-run found the one Pod and admitted the new one, as it should: it denies
nothing. Now switch the constraint to `deny` and send the same file again,
which is the manifest Kyverno refused in the Enforce section:

```sh
kubectl patch noprivileged no-privileged --type merge -p '{"spec":{"enforcementAction":"deny"}}'
kubectl apply -f escape-node-2.yaml; echo "apply exit=$?"
```

Gatekeeper refuses it with the same rule ID:

<!-- gate: output -->

```
Error from server (Forbidden): error when creating "escape-node-2.yaml": admission webhook "validation.gatekeeper.sh" denied the request: [p05-no-privileged] BK-POL-001 container app runs privileged
apply exit=1
```

The shared run applied the constraint's manifest to a cluster without the
Gatekeeper CRDs. kubectl could not map the kind, so it refused the manifest
before any request reached the server. A reader gets the same answer before
installing the chart:

<!-- gate: output -->

```
error: resource mapping not found for name: "p05-no-privileged" namespace: "" from "gatekeeper-constraint.yaml": no matches for kind "P05NoPrivileged" in version "constraints.gatekeeper.sh/v1beta1"
ensure CRDs are installed first
server dry-run exit=1
```

Both engines hold the same rule, under the same ID. Kyverno refused the
privileged Pod in Enforce, and Gatekeeper refused the same manifest in `deny`,
after reporting the one that already existed in `dryrun`. Keep both only while
you compare. Two engines enforcing one rule is two places to keep right.

### Removing an engine

An engine that is removed in the wrong order can leave the cluster worse than
before. The webhook configurations are cluster objects, and each one points at
a Service in the engine's namespace. If the Service goes and the configuration
stays, every request the configuration matches fails or waits for its timeout.
The lab removes Gatekeeper in an order that leaves nothing, and checks:

```sh
kubectl delete noprivileged no-privileged
kubectl delete constrainttemplate noprivileged
helm uninstall gatekeeper --namespace gatekeeper-system --wait --timeout 4m
kubectl delete namespace gatekeeper-system --wait=true
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -iE 'gatekeeper' | xargs kubectl delete --ignore-not-found
kubectl get crd -o name | grep -E 'gatekeeper\.sh' | xargs kubectl delete --wait=true
kubectl get clusterrole,clusterrolebinding -o name | grep -iE 'gatekeeper' | xargs kubectl delete --ignore-not-found
kubectl delete namespace kyverno-demo --wait=true
kubectl get crd -o name | grep -cE 'kyverno\.io|wgpolicyk8s\.io|gatekeeper\.sh'
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ciE 'kyverno|gatekeeper'
kubectl get clusterrole,clusterrolebinding -o name | grep -ciE 'kyverno|gatekeeper'
kubectl get namespace -o name | grep -cE 'namespace/(kyverno|gatekeeper-system|p05-07-)'
```

<!-- gate: output -->

```
release "gatekeeper" uninstalled
# ...
namespace "gatekeeper-system" deleted
# ...
namespace "p05-07-kyverno" deleted

## nothing of either engine remains
$ kubectl get crd -o name | grep -cE 'kyverno\.io|wgpolicyk8s\.io|gatekeeper\.sh'
0

$ kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ciE 'kyverno|gatekeeper'
0

$ kubectl get clusterrole,clusterrolebinding -o name | grep -ciE 'kyverno|gatekeeper'
0

$ kubectl get namespace -o name | grep -cE 'namespace/(kyverno|gatekeeper-system|p05-07-)'
0
```

The last four commands count what is left, and the counts are only worth
trusting when each `kubectl` call succeeded, because a failed `grep -c` prints
`0` too. The lab learned that in its Kyverno removal. The first removal used
the plain order that the Gatekeeper chart tolerates: `helm uninstall --wait`,
then the webhook configurations, then the CRDs, then the namespace. Kyverno's
chart runs a pre-delete Job, and the Job had not finished when helm gave up:

<!-- gate: output -->

```
Error: resource Job/kyverno/kyverno-scale-to-zero not ready. status: InProgress, message: Job in progress
context deadline exceeded
```

The lab then deleted the webhook configurations while the Kyverno controllers
were still running, and the controllers wrote them back. After the namespace
went, the count of Kyverno webhook configurations was not zero:

<!-- gate: output -->

```
$ kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ci kyverno
8
```

Eight webhook configurations pointed at a Service that no longer existed. The
lab removed them by hand, and rewrote the step so that the namespace goes
before the configurations, the chart's hook is skipped, and the step fails if
anything is left. A second removal of Kyverno was then cut short, because the
API server of the lab cluster stopped answering while it ran, and every check
in it failed. The lab removed Kyverno by hand again, in the safe order. **The
rewritten Kyverno removal was not run to the end.** The order it uses ran for
Gatekeeper, as above, and not for Kyverno.

### Shift left: the same rules in CI

Admission refuses an object after it has been sent. A pipeline can refuse it
before anything is sent, which is faster and easier to read. The Bookstore's
policy is written once, in Rego, under
[`examples/bookstore/policy/`](../examples/bookstore/policy/kubernetes/baseline.rego):

- `kubernetes/baseline.rego` checks Pods, workloads and Services against the
  baseline from [01.01](../01-core-workloads/01-pods.md#baseline), with a rule
  ID on every message: `BK-POL-001` for privileged, through `BK-POL-011` for a
  namespace that is not `restricted`. A namespace below `restricted` passes
  only with the two exception annotations that
  [05.09](09-running-security-on-a-platform-team.md) describes.
- `terraform/namespaces.rego` checks the namespaces a Terraform plan creates or
  changes. The rule is `BK-TF-001`: the namespace must enforce `restricted`.

The rules have unit tests. Each test changes one field of a good input and
checks that the matching rule, and only that one, fires:

```sh
opa test full-guide/examples/bookstore/policy -v | tail -n 1
```

<!-- gate: output -->

```
PASS: 24/24
```

Conftest runs the same rules on files. It checks the rendered production
overlay of the Bookstore, which is what the cluster would receive, and it
checks the Terraform plan of the namespaces, read as JSON:

```sh
kubectl kustomize full-guide/examples/bookstore/kustomize/overlays/prod > prod-overlay.yaml
conftest test --policy full-guide/examples/bookstore/policy --all-namespaces prod-overlay.yaml
conftest test --policy full-guide/examples/bookstore/policy --all-namespaces full-guide/examples/bookstore/policy/terraform/plan.json
```

<!-- gate: output -->

```
672 tests, 672 passed, 0 warnings, 0 failures, 0 exceptions
# ...
14 tests, 14 passed, 0 warnings, 0 failures, 0 exceptions
```

Both pass. A rule that passes everything proves nothing, so the lab also
plants a failure: it sets the namespace's enforce label to `privileged` in a
copy of the plan and runs Conftest on that.

```sh
jq '(.resource_changes[0].change.after.metadata[0].labels["pod-security.kubernetes.io/enforce"]) = "privileged"' full-guide/examples/bookstore/policy/terraform/plan.json > planted-plan.json
conftest test --policy full-guide/examples/bookstore/policy --all-namespaces planted-plan.json; echo "planted plan exit=$?"
```

<!-- gate: output -->

```
FAIL - planted-plan.json - bookstore.terraform - BK-TF-001 kubernetes_namespace_v1.bookstore enforces "privileged", not restricted
14 tests, 13 passed, 0 warnings, 1 failure, 0 exceptions
planted plan exit=1
```

The plan is captured from a real `terraform plan` with the Kubernetes provider,
which is the only provider in the file. It needs no cloud account, because the
provider reads the kubeconfig it is given. The provider version is pinned in
`main.tf`, and its checksums are in the lock file beside it:

```sh
terraform init
terraform plan -out=tfplan
terraform show -json tfplan > plan.json
```

The planted fixture is the same file with one label changed. It is also the
control in CI: the pipeline's check workflow runs Conftest on it and fails
unless `BK-TF-001` is reported. A namespace plan that runs through a cloud is
a different job, and [Part
14](../14-eks-in-production-a-to-z/07-infrastructure-cicd-and-drift.md) covers
the production shape of a Terraform pipeline.

Finally, the lab lists the policies it created, to show what the cluster would
hold:

```sh
kubectl get validatingadmissionpolicy,mutatingadmissionpolicy -o name | grep p05-07 | sort
```

<!-- gate: output -->

```
mutatingadmissionpolicy.admissionregistration.k8s.io/p05-07-default-automount-off
mutatingadmissionpolicy.admissionregistration.k8s.io/p05-07-default-seccomp
validatingadmissionpolicy.admissionregistration.k8s.io/p05-07-digest-pinned
validatingadmissionpolicy.admissionregistration.k8s.io/p05-07-no-external-ips
```

### What CI runs, and what it does not

The Bookstore pipeline has a `policy` job. It runs the unit tests, Conftest on
the rendered overlay, and Conftest on the Terraform plan, and `sign` waits for
it like every other gate. Each step calls `ci/scan.sh`, which runs the tool
from a digest-pinned image, the same way the other scanners do. The check
workflow gives the job a control, so that a Conftest that stops reporting the
planted namespace fails the build.

The scanner commands ran on a Linux Docker host while this chapter was written.
The job itself has not run on GitHub Actions, so it is read, not run, until a
pipeline run on the repository shows it.

## How it works under the hood

- **CEL runs in the API server.** A `ValidatingAdmissionPolicy` is compiled when
  it is created and evaluated for each matching request, with a cost limit so a
  slow expression cannot stall the server. There is no call out to a webhook.
  `object` is the new object, `oldObject` the stored one on an update, and
  `params` the value a binding supplies.
- **A mutation is a merge.** An apply configuration is merged with server-side
  apply, so it sets the fields it names and leaves the rest. The upstream page
  warns that an apply configuration may not change atomic structs, maps or
  arrays, because values it does not name can be lost. The policies here set
  single fields for that reason, and they leave a whole list or map alone.
- **A volume is not a field.** The lab's automount policy set
  `automountServiceAccountToken` to `false`, and the Pod still had its
  `kube-api-access` volume, so the token stayed mounted. The volume is a
  separate part of the Pod, and a mutation that changes one field does not
  remove another part. The lab did not trace which admission plugin added the
  volume, so it cites the observed result, not the cause.
- **Matching is by namespace label here.** The bindings select namespaces with a
  label. Labelling a namespace applies the policies to what is created in it
  afterwards, and nothing already running is changed. A rollout that wants the
  running workloads checked uses Audit, which reports them.
- **Kyverno is a webhook.** Its admission controller answers each request, and
  `failurePolicy` decides what a timeout does. `verifyImages` contacts the
  registry for the digest and the signature, and the Sigstore services for the
  log entry, from inside the admission controller's Pod. Those lookups run
  while the API server waits, so a slow resolver or a slow registry becomes a
  refused Pod once the webhook's 30 seconds are used, as the lab saw.
- **Gatekeeper audits what exists.** Its audit controller lists the objects
  the constraint matches on an interval, and writes the violations into the
  constraint's status. A `dryrun` constraint denies nothing at admission, and
  the audit still reports.
- **Rego and CEL solve different problems.** CEL is small and fast and runs in
  the server. Rego is a full logic language, which is why it can reason about
  a whole plan or a list of containers with nested conditions, and why it runs
  in a webhook or in CI.

## Production notes

> **In production:** start every new rule in `Audit`, or `warn` for the built-in
> pair, and read the report for a release before switching to `Enforce`. The
> privileged rule above shows the shape of that report.

> **In production:** a webhook policy engine is a dependency of every write in
> the cluster. Run it with at least two replicas, set `failurePolicy` on
> purpose, and exclude the system namespaces from its own rules. Operating a
> cluster that runs it is taught in [Part
> 10](../10-cloud-and-managed-kubernetes/01-managed-kubernetes-model.md) and
> [Part
> 14](../14-eks-in-production-a-to-z/07-infrastructure-cicd-and-drift.md).

> **In production:** a rule that must have an exception gets one, with a
> reason and an expiry, as the exception record in
> [05.09](09-running-security-on-a-platform-team.md), two annotations on the
> Namespace, not as a dropped match. Kyverno's `PolicyException` and a
> binding's label selector are both ways to make an exception; both should be
> reviewed as code.

> **In production:** verify identity, not only a signature. A key proves that
> someone holding it signed the image. A keyless identity proves which
> workflow built it. The [07.03](../07-delivery/03-cicd-pipeline.md) chapter
> signs that way, and the rule here checks the same identity, branch included.

> **In production:** remove a policy engine in an order that leaves no webhook
> behind. Delete the policies, then the engine's namespace, so that its
> controllers stop, and only then the webhook configurations, the CRDs and the
> cluster roles. A controller that is still running writes its webhook
> configurations back, and a configuration that outlives its Service makes the
> requests it matches fail or wait. Count what is left, and check that the
> count came from a `kubectl` call that succeeded.

> **In production:** a webhook engine adds load to the API server. In this lab
> the control plane Pods restarted during installs, on a cluster that was short
> of CPU and disk, and the lab does not know how much of that the engines
> caused. Size the control plane for the engine, install it at a quiet time, and
> watch the restart count of the control plane Pods while you do.

## Quick Reference

```yaml
# ValidatingAdmissionPolicy: refuse what the expression rejects
spec:
  failurePolicy: Fail
  validations:
    - expression: "object.spec.containers.all(c, c.image.contains('@sha256:'))"
      reason: Forbidden
---
# Binding: where the policy applies, and what happens on a failure
spec:
  policyName: <policy>
  validationActions: [Deny]        # or [Audit], [Warn]
  matchResources:
    namespaceSelector:
      matchLabels:
        lab-policies: "true"
```

```yaml
# MutatingAdmissionPolicy: a default, only when the field is unset
spec:
  matchConditions:
    - name: seccomp-unset
      expression: "!has(object.spec.securityContext) || !has(object.spec.securityContext.seccompProfile)"
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: "Object{spec: Object.spec{securityContext: Object.spec.securityContext{seccompProfile: Object.spec.securityContext.seccompProfile{type: \"RuntimeDefault\"}}}}"
```

```yaml
# The token: set it in the manifest. A policy that changes the field does not
# remove a volume the Pod already has.
spec:
  automountServiceAccountToken: false
```

```yaml
# Kyverno: report first, then refuse
spec:
  rules:
    - name: <rule>
      validate:
        failureAction: Audit   # then Enforce
    - name: <image rule>
      verifyImages:
        - imageReferences: ["<registry>/*"]
          type: SigstoreBundle   # match the type to how the pipeline signs
          verifyDigest: true
          required: true
          failureAction: Audit   # then Enforce
          attestors:
            - entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "<the workflow identity, branch included>"
                    rekor:
                      url: https://rekor.sigstore.dev
```

```sh
# Shift left: the same rules, before anything is applied
opa test <policy-dir> -v
conftest test --policy <policy-dir> --all-namespaces <rendered.yaml>
```

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise;
> the answer is the check.

1. **A Pod in a namespace labelled for the policies sets
   `automountServiceAccountToken: true` and names a ServiceAccount called
   `catalog`. The `MutatingAdmissionPolicy` for the token is bound to the
   namespace. Does the Pod keep the token mounted, and which field decides it?**
   <details><summary>Show answer</summary>

   Yes, it keeps the token. The policy's `matchConditions` only fire when the
   field is absent, and here it is set to `true`, so the mutation never runs.
   The field that decides it is the Pod's own `automountServiceAccountToken`.
   A dedicated ServiceAccount makes `true` acceptable under the baseline, and
   the Rego rule `BK-POL-008` checks that. Even when the field is absent, the
   lab showed that the policy's change does not remove the token volume, so
   the manifest is the control.

   </details>

2. **A tag moves to a new image after review. Which control in this chapter
   refuses the Pod, and does it check who built the image? Which control
   would?**
   <details><summary>Show answer</summary>

   The digest rule, `digest-pinned`, refuses a Pod whose image has no
   digest, so a moving tag is refused at admission. It does not check who built
   the image, because a digest names bytes and says nothing about their author.
   The Kyverno `verifyImages` rule checks the signature, and so checks that the
   key or identity it names signed those bytes. The lab ran that rule: it
   admitted the pipeline's digest and refused an image with no signature.

   </details>

3. **Security question: an attacker pushes an image with a valid digest and no
   signature to a registry the Bookstore's Pods may pull from. Which admission
   control stops it, which does not, and why does the digest rule not stop it?**
   <details><summary>Show answer</summary>

   The digest rule does not stop it, because the image has a digest, and the
   rule only checks that one is present. `verifyImages` with `required: true`
   stops it in a namespace the rule covers, because the image has no signature
   from the named key. The mutating defaults do not stop it either: they set
   fields on a Pod, and they do not look at the image. The gap is that a rule
   covers only the namespaces it selects, so a namespace left out of the rule
   is open to this attack.

   </details>

4. **Why is a rule that is `Audit` in Kyverno and `dryrun` in Gatekeeper not yet
   a control?**
   <details><summary>Show answer</summary>

   Neither refuses anything. Each records the violation and lets the object
   in, so the rule describes what the cluster would do, not what it does. The
   rule becomes a control when it is in `Enforce`, or when CI refuses the
   manifest before it is applied, and the report has been read and the
   findings fixed or excepted.

   </details>

## Further reading

- [Admission
  controllers](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
  and the two phases of admission.
- [Validating admission
  policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
  and [mutating admission
  policy](https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/).
- [Pod Security
  Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/),
  the built-in levels from chapter 02.
- [Kyverno documentation](https://kyverno.io/docs/) and [Gatekeeper
  documentation](https://open-policy-agent.github.io/gatekeeper/website/docs/).
- [OPA policy testing](https://www.openpolicyagent.org/docs/policy-testing)
  and [Conftest](https://www.conftest.dev/).
- [cosign verify](https://docs.sigstore.dev/cosign/verifying/verify/) for the
  signature checks in this chapter.
- [05.03](03-supply-chain.md) for the signing and digests this chapter relies
  on, and [11.01](../11-advanced-production-patterns/01-admission-webhooks.md)
  for writing a webhook.
