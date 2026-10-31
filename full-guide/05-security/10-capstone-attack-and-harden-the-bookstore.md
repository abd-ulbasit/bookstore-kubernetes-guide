# Capstone: attack and harden the bookstore

> The earlier chapters in this Part each closed one thing. This one chains
> them. A deliberately weakened bookstore runs in one namespace of a kind
> cluster. A foothold inside it borrows an identity, reads a Secret, reaches
> the node's files and the database. Then the same chain runs against the
> hardened bookstore. Where the controls hold, the chain stops. Where they do
> not, the chapter says so.

**Estimated time:** ~30 min read · ~60 min hands-on (the lab is scripted)
**Prerequisites:** [Part 05 ch.00](00-the-attackers-view.md) recon from a
Pod · [ch.01](01-authn-authz-rbac.md) RBAC escalation ·
[ch.02](02-pod-security.md) escapes and `restricted` ·
[ch.03](03-supply-chain.md) image digests ·
[ch.04](04-secrets-and-cluster-hardening.md) Secrets in etcd ·
[ch.07](07-admission-control-and-policy-as-code.md) admission ·
[Part 02 ch.06](../02-networking/06-network-policies.md) NetworkPolicy
**You'll know after this:** • walk a kill chain from a foothold to the
database and name the control that closes each link • show which links a
control closes, and which the cluster's network does not close • produce an
evidence pack of kube-bench output, admission denials and API results • say
which evidence this chapter did not produce, and why

<!-- tags: security, capstone, rbac, pod-security, admission, network-policy -->

## Why this exists

Each earlier chapter in this Part looked at one door. Chapter 00 showed what a
Pod can learn about its neighbours. Chapter 01 showed how a ServiceAccount
turns into more rights than its author meant. Chapter 02 showed the escapes a
Pod spec allows, and chapter 04 showed where a Secret is stored. A real
attacker does not pick one door. They take the first one that opens, then use
what it gives them to open the next.

This capstone runs that chain end to end on the bookstore, the guide's one
running application. It runs against a deliberately weakened copy. The copy is
a Kustomize overlay beside the bookstore base, and each weakness in it is tied
to the chapter that closes it. The table in the lab section is therefore also
a reading list.

The lesson is not that the bookstore is insecure. The base is hardened: its
Pods are `restricted`-compliant, its ServiceAccounts do not mount tokens, and
it defines NetworkPolicies. The overlay removes that hardening in one
namespace, the way a team might under deadline. The chapter attacks it,
hardens it, attacks it again, and records what each attempt produced.

## Mental model

The chain has five links. Each link needs something the previous one gave it,
and a different control breaks each one.

- **A foothold.** A process the attacker controls runs inside the namespace.
  In a real incident this is an application bug. Here, `kubectl exec` into a
  Pod stands in for that bug. The foothold carries the identity of
  `catalog-sa`, the ServiceAccount the catalog runs under.
- **A borrowed identity.** The foothold cannot read Secrets itself, but its
  identity can create Pods, and a Pod can name any ServiceAccount in its
  namespace. So the foothold creates a Pod that runs as `payments-worker-sa`,
  which can read Secrets.
- **The node's files.** The borrowed Pod mounts the node's root with
  `hostPath`. On a kind cluster the node is a container, so this reaches the
  node container's root and not the lab host. The control-plane credentials
  live there.
- **The data at rest.** The database password is a Secret. Whether etcd
  encrypts it decides what a process with the node's files can read without
  asking the API server.
- **The database.** With the password, or without it, the chain reaches
  postgres over the network. Whether the network stops it depends on the
  policies in place and on whether the cluster enforces them.

Supply chain sits underneath all five. A foothold whose image is named by a
tag can run a different image tomorrow, so the chain starts from a pinned
digest or it starts from nothing.

Hardening does not remove a link. It removes the thing the link depends on.
The foothold still exists after hardening. What changes is that its identity
no longer has the right to create a Pod, and its network path no longer
reaches what it should not.

## Threats and controls

| Threat | Control this chapter applies | Where it goes deeper |
|---|---|---|
| A foothold reads a ServiceAccount token and lists what it can do | No Role that lets `catalog-sa` create Pods. The token is still mounted, and its rights are reads of ConfigMaps | [01](01-authn-authz-rbac.md) |
| A Pod names a ServiceAccount its creator does not own and inherits its rights | No `create pods` grant in the namespace. A grant on `pods` is a grant to name any ServiceAccount in it | [01](01-authn-authz-rbac.md) |
| A `hostPath` mount of `/` reads the node's credentials | `restricted` refuses `hostPath` at admission, and the lab shows the refusal | [02](02-pod-security.md) |
| A root Pod with no seccomp filter widens what the kernel accepts | `restricted` refuses `Unconfined` seccomp and any root Pod | [02](02-pod-security.md), [05](05-kernel-isolation.md) |
| A tag moves to a different image between review and run | A digest pin, enforced at admission by a ValidatingAdmissionPolicy | [03](03-supply-chain.md), [07](07-admission-control-and-policy-as-code.md) |
| A Secret is readable in plaintext from etcd and its snapshots | Encryption at rest. Not applied on this cluster, and the lab shows the plaintext | [04](04-secrets-and-cluster-hardening.md) |
| A Pod reaches the database, or the API, across the namespace | A default-deny NetworkPolicy with explicit allows. The lab shows the cluster enforcing it | [Part 02 ch.06](../02-networking/06-network-policies.md), [Part 00 ch.07](../00-foundations/07-local-cluster-setup.md) |
| The control plane is misconfigured in ways the workload cannot see | kube-bench output recorded as evidence. Fixes belong to chapter 06 | <!-- link-later: 05.06 --> chapter 06 |
| The attack leaves no record in the API | The audit log is cited, not run here. It needs a throwaway cluster | <!-- link-later: 05.08 --> chapter 08 |

The first six rows are what this lab runs. The last two are evidence this
chapter names and does not produce, for the reasons in the lab header.

## What a kind node can and cannot show

A kind node is a container. It runs systemd, containerd and the kubelet, and
it shares the lab host's kernel. Four facts follow, and each one limits what
the lab can say.

- **The node's kernel is the host's.** The lab reports the kernel from inside
  the borrowed Pod, and it is the lab host's kernel. An escape that reached
  the kernel would reach the lab host, which is why the lab runs no kernel
  exploit. Its payloads read files and write one marker.
- **The node's files are the node's.** `hostPath: /` in the borrowed Pod shows
  the node container's root filesystem. The lab host's own files are not
  inside that container, so they are not reachable through it. The chapter
  shows the node's `/etc/kubernetes` and its etcd snapshot, both inside the
  node container.
- **The CNI is kindnet.** Kind installs kindnet by default, and this cluster
  runs it. Step 15 shows the cluster enforcing a NetworkPolicy. The lab does
  not isolate which component does the enforcing.
- **Encryption at rest is off.** The Secret's bytes in the etcd snapshot are
  plaintext. Step 7 shows it, and step 15 shows it again after hardening.

Parts 10, 14 and 15 cover operating these controls on managed clusters, where
the node image, the CNI and the API server's flags belong to the provider. The
[managed Kubernetes
model](../10-cloud-and-managed-kubernetes/01-managed-kubernetes-model.md) says
what the provider owns. This chapter teaches the mechanism on a lab cluster
and links to them rather than repeating them.

## Lab: attack, harden, re-attack, evidence

### Lab header

- **Tier A, run on a kind cluster.** The cluster is `kind-sf-pilot`: a single
  node on Kubernetes v1.37.0, with containerd, on a Linux host whose kernel is
  7.0.0 with AppArmor enabled. `kubectl` is v1.37.2. kube-bench is v0.16.0,
  pinned by digest. The attack image is `curlimages/curl:8.22.0`, pinned by
  digest in the hardened Pod. The node already holds that digest, so the
  vulnerable Pod's tag resolves without a fresh pull. This lab has not been
  run on macOS, which has no AppArmor.
- **Script and transcript.**
  [`labs/05-10.sh`](../examples/security-lab/labs/05-10.sh) runs the steps
  below and deletes what it creates. Its recorded output is
  [`evidence/05-10.txt`](../examples/security-lab/evidence/05-10.txt). Run it
  only against a cluster you own. It refuses any kubectl context that is not
  `kind-*`.
- **Namespaces.** Two, both created by the lab. `p05-capstone` holds the
  bookstore and the attack Pods. It is labelled `privileged` during the
  vulnerable phase, because the insecure foothold and the borrowed Pod must be
  admitted, and `restricted` after hardening. `p05-capstone-bench` holds one
  kube-bench Job and is labelled `privileged`, because kube-bench reads the
  node's files and process table. Neither is `bookstore` or `default`.
- **What did not run.** Three pieces of evidence are not in this run. *Audit
  log:* the API server on `kind-sf-pilot` has no audit policy, and changing
  its flags is not something this lab does on the shared cluster. The audit
  log needs a throwaway cluster built from
  [`kind/audit-cluster.yaml`](../examples/security-lab/kind/audit-cluster.yaml)
  under the lab host's heavy-install lock. That lock was held by other work
  during this session, so no throwaway was built. The audit evidence is cited
  to chapter 08. *Falco and runtime detection:* a Falco install is a heavy
  install, and it belongs to chapter 08. *Kyverno policy reports:* Kyverno is
  not installed on the lab cluster, so the policy evidence here comes from Pod
  Security admission and the ValidatingAdmissionPolicy, both built into the
  API server.

Both privileged namespaces are exceptions to the default that ADR 0005 sets,
which makes `restricted` the default. Each records a reason, an owner and an
expiry no later than 2027-10-31. The registry that chapter 09 keeps is not in
the repository yet, so these rows are recorded here for now <!-- link-later:
05.09 -->.

| Namespace | Reason | Owner | Expiry |
|---|---|---|---|
| `p05-capstone` (vulnerable phase only) | Holds the insecure foothold and borrowed Pod that the chain needs | 05.10 | 2027-10-31 |
| `p05-capstone-bench` | kube-bench needs `hostPID` and `hostPath`, runs once, and is deleted | 05.10 | 2027-10-31 |

The lab also hit four problems on the shared host, and the lab now handles
each of them. Every change below is in the capstone component or the lab
script. The base is unchanged.

- **The migration Job's deadline.** The base gives the migration Job
  `activeDeadlineSeconds: 120`, which includes the time its Pod takes to
  start. On the shared host, postgres took longer, so the Job failed with
  `DeadlineExceeded` and the catalog never became ready. The component raises
  the cap to 900 seconds for the capstone only.
- **Postgres probes.** The base's postgres probes allow one second per check,
  and the liveness probe restarts the container after three misses. Under
  load, the first `initdb` ran long enough to be killed. A restart in the
  middle of `initdb` left a data directory that never created the database, so
  every later start skipped the setup. The component gives postgres more time
  to start and to answer.
- **Redis stays.** The catalog's readiness check dials Redis, so a catalog
  without Redis never becomes ready and never joins its Service. The component
  keeps the Redis Deployment.
- **The migration Job cannot reach postgres under the base's policies.** The
  base allows ingress to postgres only from pods labelled `app: catalog`. The
  migration Job's pods carry `app: db-migrate`, so with the policies in place
  the migration cannot connect. An earlier attempt hit this, and the Job
  waited on a connection that never came. The vulnerable overlay removes the
  base's policies, so the migration runs there. The base has the same gap, and
  the chapter does not fix the base.

### The vulnerable overlay

The vulnerable overlay is the base, the shared component and one weak RBAC
file, plus the policy removals and the namespace label. Each weakness maps to
the chapter that closes it. Every file in the overlay carries the
insecure-on-purpose marker, so the list below matches the files a reader can
open.

| Weakness | Where it lives | Closed by |
|---|---|---|
| The namespace admits privileged Pods (`enforce=privileged`) | `vulnerable/kustomization.yaml` | [02](02-pod-security.md) |
| `catalog-sa` may create Pods in the namespace | `vulnerable/90-weak-rbac.yaml`, Role `catalog-debugger` | [01](01-authn-authz-rbac.md) |
| `payments-worker-sa` may read Secrets | `vulnerable/90-weak-rbac.yaml`, Role `payments-secret-reader` | [01](01-authn-authz-rbac.md) and [04](04-secrets-and-cluster-hardening.md) |
| No NetworkPolicy: a flat network | `vulnerable/kustomization.yaml` removes the base's ten policies | [Part 02 ch.06](../02-networking/06-network-policies.md) |
| The foothold names its image by a tag, and runs as root | The foothold Pod in step 2 | [03](03-supply-chain.md) and [02](02-pod-security.md) |
| No admission rule for image digests | Absent from the vulnerable overlay | [07](07-admission-control-and-policy-as-code.md) |
| Secrets stored in plaintext in etcd | The cluster, not the overlay | [04](04-secrets-and-cluster-hardening.md), cited here, not closed on this cluster |

The weak Roles are plain RBAC, and the file is short. Read it in
[`90-weak-rbac.yaml`](../examples/bookstore/security-lab/vulnerable/90-weak-rbac.yaml).
The base defines the hardened identities, and its ServiceAccounts already set
automount to false.

### Step 1: the vulnerable bookstore, applied as one overlay

The lab applies the vulnerable overlay with one command, then waits for
postgres, the migration Job and the catalog. The `Waiting` line is the rollout
reporting that one catalog Pod is up, and the namespace line at the end is the
label check.

```sh
kubectl apply -k "$overlays/vulnerable"
```

<!-- gate: output -->

```
Waiting for 1 pods to be ready...
partitioned roll out complete: 1 new pods have been updated...
job.batch/db-migrate condition met
deployment "catalog" successfully rolled out
NAME           STATUS   AGE    ENFORCE      WARN
p05-capstone   Active   3m9s   privileged   restricted
```

The namespace now carries `enforce=privileged` and `warn=restricted`. The
`warn` label is what the later admission output reports, so the vulnerable
phase still produces a policy record without refusing anything.

### Step 2: the foothold, a Pod the vulnerable namespace admits

The foothold stands in for a compromised application. It runs as root, with a
writable root filesystem, the catalog ServiceAccount's token mounted, and an
image named by a tag. The marked fields are insecure on purpose, and every
other field is the baseline.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a foothold that stands in for a compromised app. It runs as root with the catalog ServiceAccount token mounted, a writable root filesystem and a tag that can move. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: p05-capstone-foothold
  namespace: p05-capstone
  labels:
    app.kubernetes.io/part-of: bookstore
spec:
  serviceAccountName: catalog-sa
  automountServiceAccountToken: true
  securityContext:
    runAsUser: 0
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: curlimages/curl:8.22.0
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: true
        readOnlyRootFilesystem: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
  restartPolicy: Never
```

The warning line is the `warn` label at work. Admission accepts the Pod and
records the violations.

<!-- gate: output -->

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "curl" must set securityContext.allowPrivilegeEscalation=false), runAsNonRoot != true (pod or container "curl" must set securityContext.runAsNonRoot=true), runAsUser=0 (pod must not set runAsUser=0)
pod/p05-capstone-foothold created
pod/p05-capstone-foothold condition met
```

### Step 3: recon from inside the foothold

The foothold does what chapter 00 showed. It reads its namespace, counts the
service addresses in its environment, resolves postgres, and asks the API
server with its own token what that token may do. The API server answers the
last question through a `SelfSubjectAccessReview`, which any identity may send
about itself. The token file size is printed, and the token itself is not.

<!-- gate: output -->

```
namespace: p05-capstone
token file: 1209 bytes (contents not printed)
Services in the namespace, from env: 6
# ...
Address: <pod-ip>
create pods: "allowed": true
get secrets: "allowed": false
list secrets: "allowed": false
get configmaps: "allowed": false
```

The name line of the lookup is left out of the block, and the transcript keeps
it. `create pods` is allowed, and that is the grant the next step uses.
Reading Secrets and ConfigMaps is refused for this identity.

### Step 4: borrow payments-worker-sa by creating a Pod that names it

The borrowed Pod is the second insecure manifest. It names
`payments-worker-sa` as its identity and mounts the node's root through
`hostPath`. It runs as root with no seccomp filter. Everything else is the
baseline. The foothold posts the Pod to the API from inside, so the create
uses the foothold's own token.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a Pod that borrows payments-worker-sa, mounts the node's root through hostPath, runs as root with no seccomp filter, and keeps a writable root. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: p05-capstone-borrow
  namespace: p05-capstone
  labels:
    app.kubernetes.io/part-of: bookstore
spec:
  serviceAccountName: payments-worker-sa
  automountServiceAccountToken: true
  securityContext:
    runAsUser: 0
    seccompProfile:
      type: Unconfined
  containers:
    - name: curl
      image: curlimages/curl:8.22.0
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: true
        readOnlyRootFilesystem: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
      volumeMounts:
        - name: node-root
          mountPath: /host
  volumes:
    - name: node-root
      hostPath:
        path: /
        type: Directory
  restartPolicy: Never
```

Pod creation checks the `create` verb on Pods. It does not ask whether the
caller may act as the ServiceAccount named in the spec, and the catalog
identity does not need to hold any extra right for that. So the create
succeeds.

<!-- gate: output -->

```
create the borrowing Pod: HTTP 201
pod/p05-capstone-borrow condition met
payments-worker-sa
```

### Step 5: the borrowed identity reads the database Secret

The borrowed Pod's token belongs to `payments-worker-sa`, and that
ServiceAccount's Role can read Secrets. The lab reads `db-credentials` and
prints the length of the decoded password, not the password.

<!-- gate: output -->

```
secret read as payments-worker-sa: 1 key(s) found
POSTGRES_PASSWORD decoded: 11 bytes (value not printed)
```

### Step 6: escape to the node through hostPath

The borrowed Pod's mount is the node container's root. From there the
kubelet's files and the control plane's kubeconfig are readable by root. The
lab prints only the names in `admin.conf`, never its keys. The kernel line is
the host's kernel, as the node section above predicts.

<!-- gate: output -->

```
kernel seen in the Pod: 7.0.0-38-generic
node hostname: sf-pilot-control-plane
kubelet and control-plane files: admin.conf controller-manager.conf kubelet.conf manifests pki scheduler.conf super-admin.conf 
admin.conf names: name: sf-pilot name: kubernetes-admin@sf-pilot - name: kubernetes-admin 
marker written in the node
marker in the node container: /tmp/p05-capstone-escape-marker
```

The marker file is written inside the node container, under `/tmp`, and the
lab removes it at the end. The payload read and wrote nothing outside the node
container.

### Step 7: the Secret at rest in the node

The node container holds the etcd data directory, so a process with the node's
root can read the snapshot file without the API server. The lab checks two
things in that file. The `k8s:enc:` prefix marks an encrypted value, so a zero
count means no encrypted values are stored. The password string shows that the
Secret's bytes are present in plaintext. The count is not specific to this
run: the same demo string sits in the Secrets of other bookstore namespaces on
this cluster, and any match proves the point.

<!-- gate: output -->

```
k8s:enc: prefix matches: 0
plaintext password matches: 35
```

This cluster stores Secrets without encryption. Chapter 04 teaches the
EncryptionConfiguration that closes this, and the lab does not apply it here,
because the API server's flags belong to the shared cluster.

### Step 8: reach postgres from the foothold, in a namespace with no NetworkPolicy

The vulnerable overlay removes the base's NetworkPolicies, so the namespace
has none. The foothold connects to postgres over TCP. The probe reports the
connect time, not the exit code. A telnet-style request waits for the server
to send something, so curl always ends with exit 28 once the connect succeeds.
A connect time above zero is what shows the connection was made.

```sh
kubectl -n p05-capstone get networkpolicy
kubectl -n p05-capstone exec p05-capstone-foothold -- sh -c 'curl ... telnet://postgres.p05-capstone.svc.cluster.local:5432'
```

<!-- gate: output -->

```
No resources found in p05-capstone namespace.
curl: (28) Time-out
postgres:5432 TCP connect time: 0.302018
```

The connection succeeded. Nothing in the namespace stops a Pod from reaching
the database, which is the flat network this overlay is meant to show.

### Step 9: which image ran, by digest

The foothold's image is named by a tag. The digest the node actually ran is in
the Pod's status, and that is the value a reviewer should record.

<!-- gate: output -->

```
curlimages/curl:8.22.0
docker.io/curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777
```

The digest matches the one chapter 00 pins for the same image, so the node is
running the image this Part already verified.

### Step 10: kube-bench, the control plane and the node

kube-bench reads the control plane's configuration and the node's files, and
reports each CIS check as `PASS`, `FAIL`, `WARN` or `INFO`. It runs once, as a
Job in `p05-capstone-bench`. The Job's namespace is labelled privileged, and
the Job is marked insecure because it needs `hostPID` and host paths. The
`policies` target is left out, because it needs API credentials that the Job
does not mount.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: kube-bench reads the control plane's files and process table, so it needs hostPID and hostPath. It runs once. Lab cluster only.
apiVersion: v1
kind: Namespace
metadata:
  name: p05-capstone-bench
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench
  namespace: p05-capstone-bench
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: bookstore
    spec:
      restartPolicy: Never
      hostPID: true
      automountServiceAccountToken: false
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: kube-bench
          image: aquasec/kube-bench@sha256:75506f222d1eb6ce2a751a5533bdc0a3b54c898e2e49e7751d0ee22cfb862679  # aquasec/kube-bench:v0.16.0
          imagePullPolicy: IfNotPresent
          command: ["kube-bench", "run", "--targets", "master,etcd,node"]
          securityContext:
            allowPrivilegeEscalation: false
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
          volumeMounts:
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: usr-bin
              mountPath: /usr/local/mount-from-host/bin
              readOnly: true
      volumes:
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: etc-systemd
          hostPath:
            path: /etc/systemd
        - name: usr-bin
          hostPath:
            path: /usr/bin
```

The lab loads the kube-bench image onto the node first. That command prints
one line from the image loader, which reports a content digest it could not
find. The image was already on the node, so the Job ran, and the line is kept
in the transcript as it printed.

<!-- gate: output -->

```
Command Output: ctr: content digest sha256:2048e9b04537706e57a25bca4f39bab86e347aec9cf1d7a86071a289cd240777: not found
namespace/p05-capstone-bench created
job.batch/kube-bench created
job.batch/kube-bench condition met
== Summary master ==
43 checks PASS
11 checks FAIL
11 checks WARN
0 checks INFO
== Summary etcd ==
7 checks PASS
0 checks FAIL
0 checks WARN
0 checks INFO
== Summary node ==
19 checks PASS
1 checks FAIL
3 checks WARN
0 checks INFO
== Summary total ==
69 checks PASS
12 checks FAIL
14 checks WARN
0 checks INFO
12
```

The 12 at the end is the count of `[FAIL]` lines. Those checks are about the
control plane and the node's files, not the workload, so they do not change
when the workload is hardened. Chapter 06 owns the flags that would close
them.

### Step 11: harden

Hardening removes the two insecure Pods and the weak Roles, then applies the
hardened overlay. The hardened overlay has the same base and the same
component, and it adds one admission policy and keeps the base's
NetworkPolicies. The base already gives `catalog-sa` nothing beyond reading a
ConfigMap, and it already sets automount to false on every ServiceAccount.

```sh
kubectl -n p05-capstone delete pod p05-capstone-foothold p05-capstone-borrow --ignore-not-found --wait=true
kubectl apply -k "$overlays/hardened"
```

<!-- gate: output -->

```
NAME           STATUS   AGE     ENFORCE      WARN
p05-capstone   Active   5m31s   restricted   restricted
NAME                                                                                VALIDATIONS   PARAMKIND   AGE
validatingadmissionpolicy.admissionregistration.k8s.io/p05-capstone-digest-pinned   1             <unset>     4s

NAME                                                                                       POLICYNAME                   PARAMREF   AGE
validatingadmissionpolicybinding.admissionregistration.k8s.io/p05-capstone-digest-pinned   p05-capstone-digest-pinned   <unset>    4s
```

The namespace is now `enforce=restricted`. The admission policy is a
ValidatingAdmissionPolicy and a binding that scopes it to `p05-capstone`. Pod
Security admission already refuses `hostPath`, `Unconfined` seccomp and root.
The policy adds the rule Pod Security does not check: a third-party image must
be pinned by digest. The guide's own images (`bookstore/...`) are exempt,
because the local build produced their tags, and chapter 07.03 is where they
get a digest in the pipeline.

```yaml
# A third-party image in p05-capstone must be pinned by digest. The guide's
# own locally built images (bookstore/...) are exempt: the build produced
# their tags, and chapter 07.03 is where they get a digest in the pipeline.
#
# PodSecurity restricted does not look at image references, so this rule is
# the one the namespace needs in addition. Chapter 07 covers why admission is
# ordered this way, and 05.03 covers why a tag can move.
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: p05-capstone-digest-pinned
  labels:
    app.kubernetes.io/part-of: bookstore
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c, c.image.contains('@sha256:') ||
        c.image.startsWith('bookstore/')) &&
        (!has(object.spec.initContainers) ||
        object.spec.initContainers.all(c, c.image.contains('@sha256:') ||
        c.image.startsWith('bookstore/')))
      message: "p05-capstone: every third-party image must be pinned by digest (05.03)."
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: p05-capstone-digest-pinned
  labels:
    app.kubernetes.io/part-of: bookstore
spec:
  policyName: p05-capstone-digest-pinned
  validationActions: [Deny, Audit]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: p05-capstone
```

### Step 12: re-attack. The insecure foothold is refused at admission

The same insecure foothold is applied again. The namespace is now
`enforce=restricted`, and Pod Security admission refuses the Pod with each
violation listed.

<!-- gate: output -->

```
Error from server (Forbidden): error when creating "foothold-vulnerable.yaml": pods "p05-capstone-foothold" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "curl" must set securityContext.allowPrivilegeEscalation=false), runAsNonRoot != true (pod or container "curl" must set securityContext.runAsNonRoot=true), runAsUser=0 (pod must not set runAsUser=0)
```

### Step 13: re-attack. The hardened foothold is admitted, and its identity and network are both limited

The hardened foothold is `restricted`-compliant. It runs as UID 65534 with
`RuntimeDefault` seccomp, no capabilities, a read-only root and an `emptyDir`
for `/tmp`. It asks for the catalog token, because a Pod is allowed to ask for
one, and that is why RBAC and the network have to be right. It carries no
marker, because it passes. A marker on a passing block is a stale marker, and
the gate fails it.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: p05-capstone-foothold
  namespace: p05-capstone
  labels:
    app.kubernetes.io/part-of: bookstore
spec:
  serviceAccountName: catalog-sa
  automountServiceAccountToken: true
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777  # curlimages/curl:8.22.0
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
  restartPolicy: Never
```

The lab then asks the question two ways. From inside the foothold, its own API
call times out. The base's default-deny policy denies the Pod's egress, and
nothing allows it to reach the API server, so the request never arrives. That
is the network answering, before RBAC is asked anything. From the operator's
side, `kubectl auth can-i` and a server-side dry run, both impersonating
`catalog-sa`, show what RBAC would allow. The dry run is refused, because
`apply` reads the object before it creates it, and this identity cannot read
Pods.

<!-- gate: output -->

```
pod/p05-capstone-foothold created
pod/p05-capstone-foothold condition met
curl: (28) Connection timed out after 5001 milliseconds
API from the foothold: HTTP 000, curl exit 28
no
no
no
Error from server (Forbidden): error when retrieving current configuration of:
Resource: "/v1, Resource=pods", GroupVersionKind: "/v1, Kind=Pod"
Name: "p05-capstone-borrow", Namespace: "p05-capstone"
from server for: "borrow.yaml": pods "p05-capstone-borrow" is forbidden: User "system:serviceaccount:p05-capstone:catalog-sa" cannot get resource "pods" in API group "" in the namespace "p05-capstone"
```

### Step 14: re-attack. The tag-only image is refused by the digest policy

The same hardened Pod, with the image named by its tag instead of its digest,
is refused by the policy. Pod Security passes it, so the refusal comes from
the rule Pod Security does not have.

<!-- gate: output -->

```
The pods "p05-capstone-foothold-tag" is invalid: : ValidatingAdmissionPolicy 'p05-capstone-digest-pinned' with binding 'p05-capstone-digest-pinned' denied request: p05-capstone: every third-party image must be pinned by digest (05.03).
```

### Step 15: re-attack. The network and the node, after hardening

The same two probes run again, now with the base's default-deny policy in
place. The default-deny selects every Pod in the namespace for both ingress
and egress, and the foothold is not on any allow list. The TCP connect time is
zero, so the connection was never made. The etcd check runs again too, and the
plaintext is still there, because hardening did not change the cluster's
encryption.

```sh
kubectl -n p05-capstone get netpol default-deny-all -o jsonpath='{.spec.podSelector} {.spec.policyTypes}'
```

<!-- gate: output -->

```
{} ["Ingress","Egress"]
curl: (28) Connection timed out after 5002 milliseconds
postgres:5432 TCP connect time: 0.000000
plaintext password matches: 36
```

The two results together are the lesson of the lab. In the vulnerable
namespace, the foothold reached postgres. Hardening did not change the
foothold, the Secret or the database. It added NetworkPolicies, and the
connection now fails. The same policy also stops the foothold's own API call.
The cluster enforces the policy, which is the one link here that a workload's
own settings cannot close. Encryption at rest is a property of the cluster's
flags, and this cluster's flags did not change.

### Step 16: clean up everything the lab created

The cleanup removes both namespaces, the admission policy and its binding, and
the marker file. It prints the count of `p05-capstone` namespaces that remain.

<!-- gate: output -->

```
namespace "p05-capstone" deleted
namespace "p05-capstone-bench" deleted
validatingadmissionpolicybinding.admissionregistration.k8s.io "p05-capstone-digest-pinned" deleted
validatingadmissionpolicy.admissionregistration.k8s.io "p05-capstone-digest-pinned" deleted
p05-capstone namespaces left: 0
```

### Evidence pack

The evidence this run produced, and where each piece sits in the transcript:

| Evidence | What it shows | Where |
|---|---|---|
| Pod Security warnings, vulnerable phase | The insecure Pods were admitted, and the warnings recorded every violation | Steps 1 and 2 |
| kube-bench summary | 69 checks pass, 12 fail and 14 warn on the control plane and the node | Step 10 |
| Pod Security denial | The insecure foothold was refused under `restricted` | Step 12 |
| RBAC decisions | The catalog identity may create Pods but may not read Secrets, and the dry run of the borrow is forbidden | Steps 3 and 13 |
| Admission denial | The tag-only image was refused by the digest rule | Step 14 |
| Image digest | The digest the node ran, for the record | Step 9 |
| etcd snapshot | Plaintext in the snapshot, before and after hardening | Steps 7 and 15 |
| Network reach | The connection succeeded in the flat namespace and failed under default-deny | Steps 8 and 15 |
| API egress | The hardened foothold's own API call timed out under default-deny | Step 13 |
| Audit log | Not produced by this run. See the lab header | Chapter 08 |

## How it works under the hood

A request to create a Pod passes three checks in a fixed order. The API server
authenticates the caller, authorises the request against RBAC, and then runs
admission: the built-in Pod Security admission and the validating admission
policies. The order decides what a refusal means. The borrowed Pod in step 4
was authorised, because `catalog-sa` may create Pods, and then admitted,
because the vulnerable namespace is `privileged`. The borrow attempt in step
13 was a server-side dry run that the operator sent as the catalog identity,
and RBAC refused it before admission ran. The foothold's own request never
reached the API server, because the policy blocked its egress.

A `SelfSubjectAccessReview` asks the API server what the caller may do, and it
answers for the caller only. That is how the foothold learned its rights in
step 3, without any extra permission. It needs the caller to reach the API
server, and in the hardened namespace the policy prevents that.

Pod Security admission reads the namespace labels when a Pod is created. It
does not look at a Pod again once it runs, and a label change does not evict
the Pods already running. So the insecure Pods keep running after the
namespace is hardened unless the lab deletes them, which step 11 does before
it applies the hardened overlay.

NetworkPolicy works on labels. A policy selects Pods by label, and it lists
the peers each direction allows. The base's `default-deny-all` selects every
Pod and allows nothing by itself. The allow rules admit only the labels they
name, so a Pod whose labels no allow rule names is denied in both directions.
The foothold's labels are not among them, which is why its call to the API
server and its connection to postgres both fail.

## Production notes

- **Identity.** On a managed cluster the foothold's identity is a cloud IAM
  role as well as a ServiceAccount, and borrowing a Pod's identity can reach
  the cloud account. The mechanism here is the same, and the blast radius is
  larger. See [Part 10
  ch.03](../10-cloud-and-managed-kubernetes/03-cloud-identity.md) and [Part 13
  ch.04](../13-grand-capstone-bookstore-platform/04-real-auth-keycloak-irsa-istio-jwt.md).
- **Supply chain.** Digest pinning here is the enforced rule. In production
  the same rule sits behind a signature check. See [Part 14
  ch.12](../14-eks-in-production-a-to-z/12-supply-chain-security.md) and [Part
  15
  ch.03](../15-day-to-day-production-ops/03-image-signing-and-provenance.md).
- **Secrets.** On a cloud the Secret's value comes from a secret manager, and
  it does not sit in etcd as the base's demo Secret does. See [Part 11
  ch.05](../11-advanced-production-patterns/05-secrets-at-scale.md) and [Part
  15
  ch.05](../15-day-to-day-production-ops/05-production-secrets-vault-eso.md).
- **Detection.** The audit log and runtime detection are the evidence this lab
  did not produce. See [Part 14
  ch.13](../14-eks-in-production-a-to-z/13-runtime-defense-and-container-security.md)
  and [Part 15
  ch.10](../15-day-to-day-production-ops/10-incident-response-and-on-call.md).
- **Exceptions.** The two privileged namespaces expire within 12 months. The
  registry that records them is chapter 09's, and the expiry is the reason it
  exists.

## Quick Reference

```yaml
# spec: the hardened foothold's Pod Security settings
spec:
  automountServiceAccountToken: true   # the token is needed; RBAC limits it
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - image: curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777  # curlimages/curl:8.22.0
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
```

```sh
# Ask whether an identity may act, without becoming it.
kubectl auth can-i create pods --as=system:serviceaccount:p05-capstone:catalog-sa -n p05-capstone
```

## Test your understanding

1. The hardened foothold still mounts the catalog token. Name the control
   that stops it creating a Pod, and say which chapter teaches it.
2. The hardened foothold's own call to the API server timed out in step 13.
   Name the control that caused it, and say why RBAC was not the first
   check that refused it.
3. A reviewer asks why the borrowed Pod in step 4 was admitted when the
   namespace was labelled `privileged`. Answer in terms of what admission
   checks and what it does not.
4. The digest policy exempts `bookstore/...` images. Say why that exemption is
   acceptable here, and what would make it unsafe.

## Further reading

- [Kubernetes: Pod Security admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [Kubernetes: ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
- [Kubernetes: Encrypting Secret data at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [Kubernetes: Network policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [kube-bench](https://github.com/aquasecurity/kube-bench)
