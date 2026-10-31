# 07: Admission control and policy as code

> Admission is the last check before the API server stores an object, and it is
> the one place every create and update passes through. This chapter shows what
> it can refuse that Pod Security cannot: a Service that asks for an external
> IP, a Pod that forgets the baseline, an image nobody signed. It teaches the two
> built-in policy kinds first, then Kyverno as the project's engine, then the
> same rule in Rego for Gatekeeper. Last, the same rules run in CI before any
> manifest reaches a cluster.

**Estimated time:** ~50 min read · ~40 min lab (scripted, shared mode)
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
states each rule once, in a form that CI runs and the cluster enforces, so a
failure shows up in the pull request rather than as a refused deploy.

## Mental model

A request passes through two admission phases, and the phase decides what a
check may do.

1. **Mutating admission** runs first. Built-in plugins, mutating webhooks and
   `MutatingAdmissionPolicy` may change the object. This is where a default
   goes in.
2. **Validating admission** runs second, on the object as it will be stored.
   Pod Security Admission, `ValidatingAdmissionPolicy`, and validating webhooks
   such as Kyverno and Gatekeeper may only accept or refuse. The
   [admission controllers page](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
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
| A tag moves to a different image after review | `ValidatingAdmissionPolicy` requires a digest on every container image | [05.03](03-supply-chain.md) |
| A Pod runs an image nobody signed, under a digest anyone can pin | Kyverno `verifyImages` checks the signature against a key or an identity | [cosign verify](https://docs.sigstore.dev/cosign/verifying/verify/); [05.03](03-supply-chain.md) |
| A workload forgets the seccomp profile | `MutatingAdmissionPolicy` fills in `RuntimeDefault` at admission | [01.01](../01-core-workloads/01-pods.md#baseline) |
| A workload gets the default ServiceAccount token | Set `automountServiceAccountToken: false` in the manifest, and check it in CI; a policy that only changes the field does not remove the volume | [01.01](../01-core-workloads/01-pods.md#baseline) |
| A rule is enforced in the cluster and forgotten in CI, or the reverse | One rule ID, written in Rego, unit-tested, and run by Conftest in CI | [07.03](../07-delivery/03-cicd-pipeline.md) |
| A new rule breaks running workloads on the day it is applied | Kyverno `Audit` first, then `Enforce`, with the report read in between | [11.01](../11-advanced-production-patterns/01-admission-webhooks.md) for webhooks you write yourself |

## Lab: attack, harden, re-attack

### Lab header

- **Tier A, two modes.** The lab runs against a kind cluster that you own, and it
  refuses any other kubectl context. `MODE=shared` runs the steps that need no
  throwaway cluster, on the lab's shared cluster. `MODE=full` creates a throwaway
  cluster, `p05-07`, and runs the registry, the signing, and the Kyverno and
  Gatekeeper installs. The transcript below is a `MODE=shared` run.
- **Script and transcript.**
  [`labs/05-07.sh`](../examples/security-lab/labs/05-07.sh) runs every command
  below and deletes what it creates. Its recorded output is
  [`evidence/05-07.txt`](../examples/security-lab/evidence/05-07.txt). The
  server is Kubernetes v1.37.0, and the client is kubectl v1.37.2.
- **What ran.** Step 0 (the tools), steps 5 and 6 (the attack, the policies, and
  the re-attack), step 13 (the policy checks), step 14 (the policies read back),
  and step 16 (the Kyverno and Gatekeeper charts rendered and checked against
  the cluster without being installed). Step 16 also shows the server refusing
  the two policy objects, because their custom resources are not on this cluster.
- **What did not run.** Steps 1 to 4 (the throwaway cluster, the lab registry,
  the image push, and the signatures), step 7 (the signed Pod), steps 8 to 12
  (the Kyverno install, Audit, Enforce, verifyImages, and Gatekeeper), and step 15
  (the uninstall). The full mode was attempted three times on the lab host. Each
  time the throwaway cluster's control plane did not finish bootstrapping inside
  kubeadm's wait, or the node did not report its boot target in time, so no step
  after cluster creation ran. Those steps are shown below as commands and marked
  not run. Check the charts and the policy fields against their upstream
  documentation before you rely on them.
- **Namespaces.** `p05-07-open` enforces nothing and holds the attacks. The
  shared run creates it, labels it for the policies, and deletes it at the end.
  The full mode also creates `p05-07-signed`, `p05-07-kyverno`, and
  `p05-07-registry`, and installs into `kyverno` and `gatekeeper-system`.
- **Why a throwaway cluster in full mode.** The registry runs on the kind network
  and every node must trust it. containerd reads that trust from its own
  configuration, and only a cluster created with the `config_path` patch in
  [`kind/admission.yaml`](../examples/security-lab/kind/admission.yaml) carries
  it. The shared cluster keeps its default configuration.
- **What did not work the first time.** A new namespace has no `default`
  ServiceAccount for a moment, and the API server refuses Pods in it until the
  controller creates one. The script waits for it. A busybox Pod that runs `sleep`
  as PID 1 ignored the stop signal on the shared cluster, and its namespace stayed
  in `Terminating` for minutes. The final run starts from an empty namespace list.
  The automount policy changed a field and did not remove a volume, which the
  harden section below shows in detail.

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

The attacks run in a namespace with no Pod Security labels and no policy. Start
with the Service. A Service with an `externalIPs` entry answers for that address
on every node, so a tenant who may create Services can take traffic meant for
another address. The
[Service documentation](https://kubernetes.io/docs/concepts/services-networking/service/#external-ips)
describes the field, and the lab does not send traffic to it.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a Service that asks for an external IP. Lab cluster only.
apiVersion: v1
kind: Service
metadata:
  name: catalog-ext
  namespace: p05-07-open
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
  namespace: p05-07-open
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
kubectl -n p05-07-open exec forgetful -- sh -c 'grep Seccomp: /proc/self/status | tr "\t" " "; ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>/dev/null | tr "\n" " "; echo'
kubectl -n p05-07-open get pod forgetful -o jsonpath='{.spec.volumes[*].name}{"\n"}'
```

<!-- gate: output -->

```
Seccomp: 0
ca.crt namespace token 
```

`Seccomp: 0` means the process runs with no filter. The token directory is there,
so the Pod's identity is mounted and ready to use. The Pod's volumes include a
`kube-api-access` volume, which is the projected token. Neither result is a bug.
The API server did what it was asked, and nothing asked for more.

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
  name: p05-07-no-external-ips
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
  name: p05-07-no-external-ips
spec:
  policyName: p05-07-no-external-ips
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        p05-07-lab: "true"
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
  name: p05-07-digest-pinned
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: "object.spec.containers.all(c, c.image.contains('@sha256:'))"
      message: "every container image must be pinned by digest"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: p05-07-digest-pinned
spec:
  policyName: p05-07-digest-pinned
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        p05-07-lab: "true"
```

A digest is not a signature. The rule says which bytes may run, not who made
them. The verifyImages section below deals with that gap.

The second kind of control is a `MutatingAdmissionPolicy`, which is GA in
Kubernetes 1.36. It fills in a default when the author left a field out, and it
does not overwrite a value the author set. The lab uses two. One sets the seccomp
profile to `RuntimeDefault` when the Pod does not set one. The other sets
`automountServiceAccountToken` to `false` when the Pod does not say.

Each policy runs only when a condition holds. `matchConditions` is the guard, and
the mutation is an apply configuration that the API server merges with the
server-side apply strategy. A field the apply configuration does not name is
left alone, and a field it names is set.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: p05-07-default-automount-off
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
  name: p05-07-default-automount-off
spec:
  policyName: p05-07-default-automount-off
  matchResources:
    namespaceSelector:
      matchLabels:
        p05-07-lab: "true"
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: p05-07-default-seccomp
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
  name: p05-07-default-seccomp
spec:
  policyName: p05-07-default-seccomp
  matchResources:
    namespaceSelector:
      matchLabels:
        p05-07-lab: "true"
```

`reinvocationPolicy: IfNeeded` asks for the mutation to run again if a later
mutation changes the Pod. The two policies here do not depend on each other, so
the setting changes nothing in this lab. The
[mutating admission policy page](https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/)
describes it.

A default is a guess the policy makes for every Pod it matches. The seccomp
default is `RuntimeDefault` because the baseline asks for it. The policy does not
judge the workload, and a Pod that needs a different profile must set one, which
the mutation then leaves alone.

Apply the four objects, then label the attacked namespace so the bindings select
it. The labelling is the switch. The namespace did not change, and the policies
started to apply to it.

```sh
kubectl apply -f vap-no-external-ips.yaml -f vap-digest-pinned.yaml -f map-automount-off.yaml -f map-seccomp.yaml
kubectl label namespace p05-07-open p05-07-lab=true
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
  namespace: p05-07-open
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

The refusal names the policy and the binding, and it carries the message the policy
wrote. A reader who meets this error in a cluster can find the rule in one
command, which is the point of naming it.

The digest rule is next. This Pod is complete and passes the `restricted` level.
The only thing wrong with it is the tag, and the digest rule is the control that
refuses it. Nothing else in the Pod is insecure, so it carries no marker:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: tag-only
  namespace: p05-07-open
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
      image: registry.p05-07-registry.svc.cluster.local:5000/bookstore/catalog:lab
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
Error from server (Forbidden): error when creating "tag-only.yaml": pods "tag-only" is forbidden: ValidatingAdmissionPolicy 'p05-07-digest-pinned' with binding 'p05-07-digest-pinned' denied request: every container image must be pinned by digest
```

The image in that Pod is in the lab's registry, which the full mode runs. The
refusal happens before any pull, so the shared run needs no registry for it.

The forgetful Pod, written the same way as before, now comes back with the
policies' defaults. Read the output in two parts. The stored Pod says `false` and
`RuntimeDefault`, and the process reads `Seccomp: 2`, which is a filter. The
token volume is still there:

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a Pod that leaves out the baseline. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: forgetful-2
  namespace: p05-07-open
spec:
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "3600"]
```

```sh
kubectl apply -f forgetful-2.yaml
kubectl -n p05-07-open get pod forgetful-2 -o jsonpath='{.spec.automountServiceAccountToken}{" "}{.spec.securityContext.seccompProfile.type}{"\n"}'
kubectl -n p05-07-open exec forgetful-2 -- sh -c 'grep Seccomp: /proc/self/status | tr "\t" " "; ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>/dev/null | tr "\n" " "; echo'
kubectl -n p05-07-open get pod forgetful-2 -o jsonpath='{.spec.volumes[*].name}{"\n"}'
```

<!-- gate: output -->

```
false RuntimeDefault
# ...
Seccomp: 2
ca.crt namespace token 
```

The volume list shows a `kube-api-access` volume on this Pod, as it did on the
attack Pod. That is the finding of this section. The automount policy changed
the field, and the Pod still carries the projected token volume, so the token is
still mounted. A policy that sets a field does not take back a volume that is
already part of the Pod. The seccomp default worked, because the kubelet reads the
seccomp field from the stored Pod, and the token did not, because the volume is
a separate part of the Pod.

The control that does work for the token is the manifest. A Pod that sets
`automountServiceAccountToken: false` itself never asks for the volume. The
baseline Pod below does exactly that, with the rest of the baseline in full:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: baseline
  namespace: p05-07-open
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
kubectl -n p05-07-open exec baseline -- sh -c 'ls /var/run/secrets/kubernetes.io/serviceaccount 2>&1; echo'
```

<!-- gate: output -->

```
ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
```

Check the stored object and the running process, as the lab does, not the
file in the repository. A reviewer who reads a manifest sees the fields its author
wrote. The shift-left section below is how a repository catches a Pod that
leaves them out, before it is applied.

### Kyverno: the project's engine

The built-in pair covers defaults, shape, and a fixed set of fields. It cannot
read a signature, and it has no way to say where an image came from beyond what
the expression sees. Kyverno is the project's engine for those rules. It runs as
a webhook, so it has to be installed and kept up, which is why it is the second
choice and not the first.

**Not run in this pass.** The steps in this section are the full mode of the
lab. The commands are shown so that a reader can run them against a cluster that
they own. What follows the commands is what the chart renders and what the server
says about the policy objects without the Kyverno CRDs.

The install pins the chart. `features.registryClient.allowInsecure` is set
because the lab registry serves plain HTTP. A production cluster leaves it false,
and serves its registry over TLS. The namespace is labelled `restricted` before
the install, so the chart's Pods must meet that level to run:

```sh
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
helm show chart kyverno/kyverno --version 3.9.2
kubectl create namespace kyverno
kubectl label namespace kyverno pod-security.kubernetes.io/enforce=restricted
helm upgrade --install kyverno kyverno/kyverno --version 3.9.2 --namespace kyverno --wait --timeout 10m --set features.registryClient.allowInsecure=true --set admissionController.replicas=1 --set backgroundController.replicas=1 --set cleanupController.replicas=1 --set reportsController.replicas=1
kubectl -n kyverno get deploy
```

The shared run rendered the same chart with the same values and did not install
it. Its output is the rendered manifest count and the images the chart names:

<!-- gate: output -->

```
80
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

**Not run in this pass.** The privileged Pod below is the attack for this
section. A privileged container holds every capability and sees the node's
devices. Inside a kind node that is still a container, and its kernel is the one
the node shares with the host, so the lab does not run anything that would reach
it. The Pod is admitted, and the policy only reports it. The manifest carries the
baseline everywhere except the one field that is the attack. `SIGNED-DIGEST`
is the same digest as in the next section's Pod:

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a privileged container, which the Kyverno rule refuses. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-node
  namespace: p05-07-kyverno
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
      image: registry.p05-07-registry.svc.cluster.local:5000/bookstore/catalog@sha256:SIGNED-DIGEST
      securityContext:
        privileged: true
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

The policy names the rule with the same ID the Rego rule uses later, so one ID
follows the rule from the cluster to CI:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: p05-07-disallow-privileged
  annotations:
    policies.kyverno.io/title: Disallow privileged containers
    policies.kyverno.io/description: The Bookstore rule BK-POL-001, enforced at admission.
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: no-privileged-containers
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [p05-07-kyverno]
      validate:
        message: "BK-POL-001: privileged containers are not allowed"
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): false
```

The `=(...)` anchors make a field optional: a container with no `securityContext`
passes, and one that sets `privileged` must set it to `false`. The
`validationFailureAction` field is in the 3.9.2 CRD, where it sets the action for
the whole policy.

```sh
kubectl apply -f policy-disallow-privileged.yaml
kubectl apply -f escape-node.yaml
kubectl -n p05-07-kyverno get ephemeralreports,policyreports 2>/dev/null | head -5
```

The expected result is that the Pod is admitted and the report records the
violation. That is what Audit is for. The report is the list of work a team must
do before it can move to Enforce, and a namespace with a long list is not ready.

### Enforce

Switch the same policy to Enforce, and send the same kind of Pod again. Use a new
name:

```sh
kubectl patch clusterpolicy p05-07-disallow-privileged --type merge -p '{"spec":{"validationFailureAction":"Enforce"}}'
kubectl apply -f escape-node-2.yaml
```

`escape-node-2.yaml` is `escape-node.yaml` with its name changed. The expected
result is a refusal from Kyverno with the same rule ID in the message, which is
the rule that CI runs later. Neither result was captured in this pass.

### verifyImages: the signature, not only the digest

The digest rule says which bytes may run. It does not say that someone the team
trusts built them. [05.03](03-supply-chain.md) signs the Bookstore image with a
key. This section makes the cluster check that signature before it admits a Pod.

**Not run in this pass.** The full mode signs a candidate image with a throwaway
key made in its own work directory, and the public half goes into a Secret that
Kyverno reads. Nothing private is committed. The Secret holds only the public key:

```sh
kubectl -n kyverno create secret generic p05-07-cosign-pub --from-file=cosign.pub=cosign.pub
```

The full mode runs the image that its build pushed, as a Pod in `p05-07-signed`.
The manifest carries the baseline in full. In it, `SIGNED-DIGEST` stands for the
digest that step 3 of the script prints, which is the one `cosign` signs. Put
that value in before you apply the file:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: catalog
  namespace: p05-07-signed
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
      image: registry.p05-07-registry.svc.cluster.local:5000/bookstore/catalog@sha256:SIGNED-DIGEST
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

The namespace carries the lab label, so the two digest-and-defaults policies apply
to it. The tampered image is the same Pod with a different digest and the name
`catalog-tampered`. The full mode applies it before the signature rule exists, and
expects the API server to admit it, because its digest is valid and nothing checks
what the digest points to. It then deletes it.

The policy below verifies every image in the namespace that matches the lab's
registry name. The attestor names the key. The policy refuses a Pod whose image has
no signature from that key:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: p05-07-verify-signed-images
  annotations:
    policies.kyverno.io/title: Verify lab image signatures
    policies.kyverno.io/description: Pods in p05-07-signed run only images signed by the lab key.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: signed-by-lab-key
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [p05-07-signed]
      verifyImages:
        - imageReferences:
            - "registry.p05-07-registry.svc.cluster.local:5000/bookstore/*"
          verifyDigest: true
          required: true
          attestors:
            - entries:
                - keys:
                    secret:
                      name: p05-07-cosign-pub
                      namespace: kyverno
```

`required: true` turns an image with no signature into a refusal, rather than a
pass with a warning. `verifyDigest: true` makes Kyverno check that the digest in
the Pod is the digest it verified. The `imageReferences`, `verifyDigest`,
`required`, and `secret` fields are in the 3.9.2 CRD.

The identity here is a key, which is the simplest form a lab can run. A signing
pipeline usually signs keyless and proves an identity instead: the workflow that
signed the image, read from the OIDC token of the CI system. The rule then names
an issuer and a subject rather than a key. That form is shown below and is **not
run** in this lab, because it needs the public Fulcio and Rekor services reachable
from the cluster. [07.03](../07-delivery/03-cicd-pipeline.md) signs that way from CI.

```yaml
# Fragment, not applied: the keyless identity form. Not run in this lab.
verifyImages:
  - imageReferences:
      - "registry.example.com/bookstore/*"
    attestors:
      - entries:
          - keyless:
              issuer: "https://token.actions.githubusercontent.com"
              subject: "https://github.com/<owner>/<repo>/.github/workflows/bookstore-pipeline.yml@refs/heads/master"
```

The expected result is that the signed Pod keeps running and the tampered one is
refused. The message should say that Kyverno could not verify the image, not that
the policy failed, and that distinction matters when you debug a refusal. The rule
worked, and the image failed it. Neither result was captured in this pass.

### Gatekeeper: the same rule in Rego, side by side

Gatekeeper is the other common engine. It takes its rules in Rego, which is also
what OPA runs in the shift-left section below. The full mode installs it beside
Kyverno, writes the same privileged rule, and runs it in dry-run. Dry-run denies
nothing at admission, and it reports objects that already exist, which Kyverno's
Audit mode did for the privileged Pod.

**Not run in this pass.** The install follows the same pattern as Kyverno's: a
restricted label first, then a pinned chart, with one replica so the lab stays
small:

```sh
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts --force-update
kubectl create namespace gatekeeper-system
kubectl label namespace gatekeeper-system pod-security.kubernetes.io/enforce=restricted
helm upgrade --install gatekeeper gatekeeper/gatekeeper --version 3.23.1 --namespace gatekeeper-system --wait --timeout 10m --set replicas=1
```

A `ConstraintTemplate` holds the Rego. The constraint is an instance of it, with
the enforcement action and the scope:

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: p05nopriv
spec:
  crd:
    spec:
      names:
        kind: P05NoPrivileged
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package p05nopriv

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
kind: P05NoPrivileged
metadata:
  name: p05-no-privileged
spec:
  enforcementAction: dryrun
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces: ["p05-07-kyverno"]
```

The rule has two `input_containers` clauses on purpose: a privileged init
container is as dangerous as a privileged app container, and the rule must check
both. The Kyverno pattern above checks `containers` only, so the two rules do not
match exactly. That difference is real, and the shift-left rule below checks both.

The full mode waits for the audit, then reads the constraint's status, which should
list the privileged Pod that Kyverno admitted in Audit mode:

```sh
kubectl apply -f gatekeeper-template.yaml
kubectl apply -f gatekeeper-constraint.yaml
kubectl get p05noprivileged p05-no-privileged -o jsonpath='{.spec.enforcementAction}{" "}{.status.totalViolations}{"\n"}'
kubectl get p05noprivileged p05-no-privileged -o jsonpath='{.status.violations[0].message}{"\n"}'
```

The shared run applied the constraint's manifest to a cluster without the
Gatekeeper CRDs. The server refused it, which is the same answer a reader gets
before installing the chart:

<!-- gate: output -->

```
error: resource mapping not found for name: "p05-no-privileged" namespace: "" from "gatekeeper-constraint.yaml": no matches for kind "P05NoPrivileged" in version "constraints.gatekeeper.sh/v1beta1"
ensure CRDs are installed first
server dry-run exit=1
```

Both engines hold the same rule, under the same ID. Kyverno refuses new privileged
Pods in the namespace, and Gatekeeper reports the one that already runs. Keep both
only while you compare. Two engines enforcing one rule is two places to keep right.

The full mode removes Gatekeeper and its CRDs, and deletes the Pod it reported:

```sh
kubectl delete pod escape-node -n p05-07-kyverno --wait=true
kubectl delete p05noprivileged p05-no-privileged
kubectl delete constrainttemplate p05nopriv
helm uninstall gatekeeper --namespace gatekeeper-system --wait
kubectl get crd -o name | grep 'gatekeeper.sh' | xargs kubectl delete --wait=true
kubectl delete namespace gatekeeper-system --wait=true
```

### Shift left: the same rules in CI

Admission refuses an object after it has been sent. A pipeline can refuse it
before anything is sent, which is faster and easier to read. The Bookstore's
policy is written once, in Rego, under
[`examples/bookstore/policy/`](../examples/bookstore/policy/kubernetes/baseline.rego):

- `kubernetes/baseline.rego` checks Pods, workloads and Services against the
  baseline from [01.01](../01-core-workloads/01-pods.md#baseline), with a rule ID
  on every message: `BK-POL-001` for privileged, through `BK-POL-011` for a
  namespace that is not `restricted`.
- `terraform/namespaces.rego` checks the namespaces a Terraform plan creates or
  changes. The rule is `BK-TF-001`: the namespace must enforce `restricted`.

The rules have unit tests. Each test changes one field of a good input and checks
that the matching rule, and only that one, fires:

```sh
opa test full-guide/examples/bookstore/policy -v | tail -n 1
```

<!-- gate: output -->

```
PASS: 22/22
```

Conftest runs the same rules on files. It checks the rendered production overlay of
the Bookstore, which is what the cluster would receive, and it checks the
Terraform plan of the namespaces, read as JSON:

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

Both pass. A rule that passes everything proves nothing, so the lab also plants a
failure: it sets the namespace's enforce label to `privileged` in a copy of the plan
and runs Conftest on that.

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

The planted fixture is the same file with one label changed. It is also the control
in CI: the pipeline's check workflow runs Conftest on it and fails unless `BK-TF-001`
is reported. A namespace plan that runs through a cloud is a different job, and
[Part 14](../14-eks-in-production-a-to-z/07-infrastructure-cicd-and-drift.md)
covers the production shape of a Terraform pipeline.

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

The Bookstore pipeline has a `policy` job. It runs the unit tests, Conftest on the
rendered overlay, and Conftest on the Terraform plan, and `sign` waits for it like
every other gate. Each step calls `ci/scan.sh`, which runs the tool from a
digest-pinned image, the same way the other scanners do. The check workflow gives
the job a control, so that a Conftest that stops reporting the planted namespace
fails the build.

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
  `kube-api-access` volume, so the token stayed mounted. The volume is a separate
  part of the Pod, and a mutation that changes one field does not remove another
  part. The lab did not trace which admission plugin added the volume, so it cites
  the observed result, not the cause.
- **Matching is by namespace label here.** The bindings select namespaces with a
  label. Labelling a namespace applies the policies to what is created in it
  afterwards, and nothing already running is changed. A rollout that wants the
  running workloads checked uses Audit, which reports them.
- **Kyverno is a webhook.** Its admission controller answers each request, and
  `failurePolicy` decides what a timeout does. `verifyImages` contacts the registry
  for the digest and the signature, so the registry must answer, and the lab's
  registry name resolves inside the cluster through a Service.
- **Gatekeeper audits what exists.** Its audit controller lists the objects the
  constraint matches on an interval, and writes the violations into the
  constraint's status. A `dryrun` constraint denies nothing at admission, and the
  audit still reports.
- **Rego and CEL solve different problems.** CEL is small and fast and runs in the
  server. Rego is a full logic language, which is why it can reason about a whole
  plan or a list of containers with nested conditions, and why it runs in a
  webhook or in CI.

## Production notes

> **In production:** start every new rule in `Audit`, or `warn` for the built-in
> pair, and read the report for a release before switching to `Enforce`. The
> privileged rule above shows the shape of that report.

> **In production:** a webhook policy engine is a dependency of every write in the
> cluster. Run it with at least two replicas, set `failurePolicy` on purpose, and
> exclude the system namespaces from its own rules. Operating a cluster that runs
> it is taught in [Part 10](../10-cloud-and-managed-kubernetes/01-managed-kubernetes-model.md)
> and [Part 14](../14-eks-in-production-a-to-z/07-infrastructure-cicd-and-drift.md).

> **In production:** a rule that must have an exception gets one, with a reason and
> an expiry, in the guide's exceptions registry, not as a dropped match. Kyverno's
> `PolicyException` and a binding's label selector are both ways to make an
> exception; both should be reviewed as code.

> **In production:** verify identity, not only a signature. A key proves that
> someone holding it signed the image. A keyless identity proves which workflow
> built it. The [07.03](../07-delivery/03-cicd-pipeline.md) chapter signs that way,
> and the rule here should check the same identity.

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
        p05-07-lab: "true"
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
  validationFailureAction: Audit   # then Enforce
  rules:
    - name: <rule>
      verifyImages:
        - imageReferences: ["<registry>/*"]
          verifyDigest: true
          required: true
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
   field is absent, and here it is set to `true`, so the mutation never runs. The
   field that decides it is the Pod's own `automountServiceAccountToken`. A
   dedicated ServiceAccount makes `true` acceptable under the baseline, and the
   Rego rule `BK-POL-008` checks that. Even when the field is absent, the lab
   showed that the policy's change does not remove the token volume, so the
   manifest is the control.

   </details>

2. **A tag moves to a new image after review. Which control in this chapter
   refuses the Pod, and does it check who built the image? Which control
   would?**
   <details><summary>Show answer</summary>

   The digest rule, `p05-07-digest-pinned`, refuses a Pod whose image has no
   digest, so a moving tag is refused at admission. It does not check who built
   the image, because a digest names bytes and says nothing about their author.
   The Kyverno `verifyImages` rule checks the signature, and so checks that the
   key or identity it names signed those bytes. That rule was not run in this
   pass.

   </details>

3. **Security question: an attacker pushes an image with a valid digest and no
   signature to a registry the Bookstore's Pods may pull from. Which admission
   control stops it, which does not, and why does the digest rule not stop it?**
   <details><summary>Show answer</summary>

   The digest rule does not stop it, because the image has a digest, and the rule
   only checks that one is present. `verifyImages` with `required: true` stops it
   in a namespace the rule covers, because the image has no signature from the
   named key. The mutating defaults do not stop it either: they set fields on a
   Pod, and they do not look at the image. The gap is that a rule covers only the
   namespaces it selects, so a namespace left out of the rule is open to this
   attack.

   </details>

4. **Why is a rule that is `Audit` in Kyverno and `dryrun` in Gatekeeper not yet
   a control?**
   <details><summary>Show answer</summary>

   Neither refuses anything. Each records the violation and lets the object in, so
   the rule describes what the cluster would do, not what it does. The rule becomes
   a control when it is in `Enforce`, or when CI refuses the manifest before it is
   applied, and the report has been read and the findings fixed or excepted.

   </details>

## Further reading

- [Admission controllers](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/) and the two phases of admission.
- [Validating admission policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) and [mutating admission policy](https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/).
- [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/), the built-in levels from chapter 02.
- [Kyverno documentation](https://kyverno.io/docs/) and [Gatekeeper documentation](https://open-policy-agent.github.io/gatekeeper/website/docs/).
- [OPA policy testing](https://www.openpolicyagent.org/docs/policy-testing) and [Conftest](https://www.conftest.dev/).
- [cosign verify](https://docs.sigstore.dev/cosign/verifying/verify/) for the signature checks in this chapter.
- [05.03](03-supply-chain.md) for the signing and digests this chapter relies on, and [11.01](../11-advanced-production-patterns/01-admission-webhooks.md) for writing a webhook.
