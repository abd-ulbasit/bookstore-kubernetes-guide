# 08: Audit logs, runtime detection and incident response

> What the attacks from [05.01](01-authn-authz-rbac.md) and
> [05.02](02-pod-security.md) leave behind, and how to read it. Four layers
> answer four different questions: the API server audit log records who asked
> for what, a runtime detector watches what processes do, a scanner reads what
> running specs allow, and a runbook takes a compromised Pod out of service
> without destroying the evidence. The lab runs the attacks, the response,
> Falco and Trivy Operator on lab clusters. The audit log is written out and
> cited. Its run is not in this chapter, and the lab header says why.

**Estimated time:** ~40 min read · ~45 min lab (scripted, lab cluster)
**Prerequisites:** [Part 05 ch.01](01-authn-authz-rbac.md): RBAC decides which
API calls a principal may make · [Part 05 ch.02](02-pod-security.md): the
escapes this chapter records ·
[Part 05 ch.04](04-secrets-and-cluster-hardening.md):
where Secret values live

**You'll know after this:**

- say what each audit level records, and why a Secret is logged without its
  value
- write an audit policy that records the requests an attacker makes
- name what a runtime detector sees that the audit log cannot
- isolate a compromised Pod with a NetworkPolicy and check that it holds
- order the response: isolate, capture, cordon, then rotate

<!-- tags: security, audit, falco, trivy, incident-response, networkpolicy -->

## Why this exists

[05.00](00-the-attackers-view.md) showed what a Pod can reach.
[05.01](01-authn-authz-rbac.md) showed which API calls a stolen identity may
make, and [05.02](02-pod-security.md) showed what a privileged Pod does to the
node. Each of those chapters ended with the attack working. This one asks what
the cluster knows afterwards, who can see it, and what to do in the next
ten minutes.

Two facts shape the answer. The API server sees every request that reaches it,
but it never sees what a process does inside a container after the request
succeeded. A `kubectl exec` is a request and is logged. A file that a process
reads on the node is not. A runtime detector covers that gap in the kernel.

The second fact is about order. Deleting a Pod destroys its process state, its
logs and, for practical purposes, the token the attacker used. Evidence has to
be captured before deletion, and the Pod has to be isolated before anyone
starts reading it. A responder who deletes first loses the case.

## Mental model

Four layers, each answering a question the others cannot:

| Layer | Question it answers | Tool in this chapter | Where its data lives |
|---|---|---|---|
| API audit | Who asked the API for what, and what came back? | the kube-apiserver audit policy | a file on the control-plane node, shipped off the node in production |
| Runtime detection | What did a process do in the kernel? | Falco, with Falcosidekick to fan out alerts | alerts, sent to outputs you configure |
| Posture scan | Which running specs allow more than the baseline? | Trivy Operator | `ConfigAuditReport` and `VulnerabilityReport` objects in the cluster |
| Response | How do I contain a Pod without losing what it did? | a runbook: NetworkPolicy, RBAC, cordon, rotation | the evidence directory the responder keeps |

The API audit layer and the runtime layer see different things. The attack in
[05.02](02-pod-security.md) reads the node's files through a `hostPath` mount.
The API server records that the Pod was created with the mount, and the
`exec` that ran the read. It does not record the read itself. A runtime detector
is the layer that sees a read like that. Neither layer alone tells the whole
story.

## Threats and controls

Every threat here is one that the earlier chapters of this Part create or leave
open. The controls are the four layers above.

| Threat | Control this chapter teaches | Where it goes deeper |
|---|---|---|
| An attacker uses a stolen identity and leaves no record | An audit policy that records Pod changes, `exec` and RBAC changes with their request body | [Kubernetes audit](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/) |
| The audit log itself leaks a Secret | `Metadata` level for Secrets and ConfigMaps, and for token requests | the same page, on levels |
| A running container reads host files or starts unexpected programs | A runtime detector on the kernel's events | [Falco](https://falco.org/docs/setup/container/) |
| A Pod with privilege sits in the cluster unnoticed | A scanner that re-reads running specs on a schedule | [Trivy Operator](https://github.com/aquasecurity/trivy-operator) |
| A compromised Pod keeps its access after it is found | Isolate, capture, cordon, then revoke and rotate | [15.10](../15-day-to-day-production-ops/10-incident-response-and-on-call.md) for the operating side |
| Evidence is lost when the Pod is deleted | Capture before deletion, and keep the copies off the cluster | this chapter's runbook |

Tetragon also enforces policy in the kernel, by blocking or killing an action
rather than only reporting it. The lab does not run it. Its project describes
itself as "eBPF-based Security Observability and Runtime Enforcement"
([Tetragon docs](https://tetragon.io/docs/)), and the chapter cites it without
a run.

## Lab: attack, harden, re-attack, evidence

### Lab header

- **Tier A, two recordings.** The attack and response steps ran on a one-node
  kind cluster with Kubernetes v1.37.0 and containerd 2.3.4 on Debian 13, on a
  Linux lab host. Falco and Trivy Operator ran on a three-node kind cluster
  with the same versions, on the same host. Both clusters have different names
  from the one this guide uses. kubectl is v1.37.2 and helm is v4.1.4. The
  script is [`labs/05-08.sh`](../examples/security-lab/labs/05-08.sh), run with
  `LAB_MODE=shared` for the first recording and `LAB_MODE=full` for the second.
  Both recordings are in
  [`evidence/05-08.txt`](../examples/security-lab/evidence/05-08.txt), from
  runs on 31 October 2026. The second one ran in 15 invocations, each listed
  in the transcript's header. The versions are Falco 0.45.2 (chart 9.2.2) with
  Falcosidekick 2.32.0, and Trivy Operator 0.36.1 (chart 0.38.1) with Trivy
  0.76.1.
- **Not run.** The audit log steps, the cordon step and Tetragon. The audit
  steps need an API server flag, which means a throwaway cluster, and neither
  recording created one. Cordoning the only node of the one-node cluster would
  stop other workloads from scheduling, so the shared run skips it, and the
  full run did not do the response steps. Nothing in this chapter says the
  audit log recorded anything.
- **Run only against clusters you own.** In shared mode the script refuses any
  context that is not the lab cluster, and refuses to start while its
  namespaces still exist or are terminating. In full mode it refuses any
  context but the one `LAB_CONTEXT` names, which must start with `kind-`. It
  creates `attack` and `app` in shared mode, and `attack`, `app`, `falco` and
  `trivy` in full mode, and deletes them at the end.
- **What did not work the first time.** The throwaway cluster is the first
  problem. Its first kubeadm run timed out: the API server answered about three
  and a half minutes after the manifests were written, because etcd applies took
  150 to 400 ms on a loaded host, and the admin bootstrap ran past kubeadm's
  one-minute default for its first API call. The configuration now raises
  those timeouts
  (see the kind configuration below). Later attempts failed at kind's boot check
  while the host's load average was between 8 and 11 on four CPUs. The first
  shared run also collided with namespaces that were still terminating from
  the run before it, so the script now refuses to start over them.

  The full run had three more problems. The first Falco install, with no node
  pin, was stopped by the script when the control plane's restart count went
  from 89 to 91 in the minutes after the install, and the script removed
  everything it had installed. The cluster's control plane containers had
  restarted 15, 36 and 38 times before the run began, so the cause of that
  restart is not known. The retry pinned Falco to one worker and kept one
  Falcosidekick replica, and no control plane container restarted again in the
  13 invocations after it. The second problem was the first Trivy values,
  which put two settings at the wrong level of the chart; the chart ignored
  them without an error. The third was the first alert list, which went
  through a helper script that readers do not have; `jq` replaced it.
- **A kind node is a container.** Every node in this lab is a container that
  shares the host's kernel. The `hostPath: /` mount in the escape Pod shows
  the node container's root filesystem, not the lab host's. The payloads read
  a hostname, read `/etc/shadow` in that container, and write one marker file
  under `/tmp` in it. The one thing that reaches the host is Falco in the full
  run: its probe is loaded into the host's kernel, which every node shares.
  The lab removes Falco before anything else goes in. The attack Pod is not
  privileged, so it has no access to the host's devices.

### Namespaces, identities and a victim

The lab's app namespace enforces `restricted`. The attack namespace enforces
`privileged`, because the attacks need privilege, and it holds only Pods marked
as insecure on purpose.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: attack
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: Namespace
metadata:
  name: app
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.37
```

The `builder` ServiceAccount stands for a build agent that may create Pods in
the attack namespace. The `ops` ServiceAccount is a dedicated identity that can
read one Secret in the app namespace. The attack in the next section borrows
`ops` through a Pod that `builder` creates.

<!-- gate: insecure-on-purpose -->
```yaml
# INSECURE ON PURPOSE: a build identity that may create and exec into Pods in its namespace, and a dedicated identity that reads one Secret. Lab cluster only.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: builder
  namespace: attack
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ops
  namespace: attack
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: builder
  namespace: attack
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: builder
  namespace: attack
subjects:
  - kind: ServiceAccount
    name: builder
    namespace: attack
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: builder
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: app
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ops-secret-reader
  namespace: app
subjects:
  - kind: ServiceAccount
    name: ops
    namespace: attack
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: secret-reader
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-db
  namespace: app
type: Opaque
stringData:
  password: lab-only-value-not-a-credential
```

The lab keeps each identity's kubeconfig in a scratch `work` directory. The
`builder` kubeconfig carries a token for `builder`, so the commands below run
as that identity.

The lab cluster's DaemonSets in `kube-system` are the networking and proxy
pieces. The quarantine step below depends on which of them enforces
NetworkPolicy, so the lab lists them first:

```bash
kubectl -n kube-system get daemonset -o name
```

<!-- gate: output -->
```text
daemonset.apps/kindnet
daemonset.apps/kube-proxy
```

### Attack: borrow an identity, read a Secret, reach the node

The builder first asks for the Secret directly. RBAC refuses it.

```bash
kubectl --kubeconfig=work/builder.kubeconfig auth whoami
kubectl --kubeconfig=work/builder.kubeconfig get secret app-db -n app
```

<!-- gate: output -->
```text
ATTRIBUTE                                           VALUE
Username                                            system:serviceaccount:attack:builder
UID                                                 9d0f2f91-59f9-40d9-8d30-f70e579a73c7
Groups                                              [system:serviceaccounts system:serviceaccounts:attack system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [JTI=39e889c8-4451-4b5f-a86b-187a19e1775b]
```

<!-- gate: output -->
```text
Error from server (Forbidden): secrets "app-db" is forbidden: User "system:serviceaccount:attack:builder" cannot get resource "secrets" in API group "" in the namespace "p05-08-app"
```

Next the builder creates a Pod that names `ops` as its ServiceAccount.
Creating Pods in a namespace lets the creator name any ServiceAccount in that
namespace, which is the escalation from [05.01](01-authn-authz-rbac.md). The
Pod mounts the node container's root, which is the escape from
[05.02](02-pod-security.md). It is not privileged, so it has no access to the
devices of the machine under the kind node. Both the identity and the mount
are the attack, so the manifest carries the insecure marker.

<!-- gate: insecure-on-purpose -->
```yaml
# INSECURE ON PURPOSE: a Pod that mounts the node container's root and runs as the ops ServiceAccount. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-node
  namespace: attack
spec:
  serviceAccountName: ops
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "1800"]
      volumeMounts:
        - name: node-root
          mountPath: /host
  volumes:
    - name: node-root
      hostPath:
        path: /
        type: Directory
```

The builder runs the Pod, then reads the `ops` token from inside it and builds
a kubeconfig for `ops` from that token. `make_kubeconfig` copies the cluster and
its CA from the lab's kubeconfig, removes the admin credential, and adds the
token. `CTX` is the context name in that kubeconfig:

```bash
make_kubeconfig() {
  cp work/admin.kubeconfig work/$1.kubeconfig
  KUBECONFIG=work/$1.kubeconfig kubectl config unset users.$CTX
  KUBECONFIG=work/$1.kubeconfig kubectl config set-credentials $1 --token="$2"
  KUBECONFIG=work/$1.kubeconfig kubectl config set-context $CTX --user=$1
}
```

The token never leaves the lab's `work` directory.

```bash
kubectl --kubeconfig=work/builder.kubeconfig apply -f escape-node.yaml
kubectl wait --for=condition=Ready pod/escape-node -n attack --timeout=180s
kubectl --kubeconfig=work/builder.kubeconfig exec -n attack escape-node -- \
  sh -c 'test -s /var/run/secrets/kubernetes.io/serviceaccount/token && echo token-file-present'
OPS_TOKEN=$(kubectl --kubeconfig=work/builder.kubeconfig exec -n attack escape-node -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token)
make_kubeconfig ops "$OPS_TOKEN"
kubectl --kubeconfig=work/ops.kubeconfig get secret app-db -n app -o name
```

<!-- gate: output -->
```text
pod/escape-node created
# ...
pod/escape-node condition met
```

<!-- gate: output -->
```text
token-file-present
# ...
secret/app-db
```

The last attack step reads the node container's hostname through the mount and
writes a marker file in its `/tmp`. The lab's objects carry a `p05-08` prefix,
and this chapter drops it. The captured output keeps the prefix, except on the
two namespaces the exceptions registry names, `attack` and `falco`. They appear
under the chapter's names, and the transcript header says so.

```bash
kubectl --kubeconfig=work/builder.kubeconfig exec -n attack escape-node -- \
  sh -c 'cat /host/etc/hostname; touch /host/tmp/marker && echo marker-written'
```

<!-- gate: output -->
```text
sf-pilot-control-plane
marker-written
```

The `hostname` is the kind node's name, as the output shows. The file is in the
node container. Without the audit log, the trail is the `escape-node` Pod in
the attack namespace and whatever the cluster still remembers about it.

### Harden and re-attack: restricted refuses the same escape

The app namespace enforces `restricted`. The same privileged Pod, aimed at it,
is refused by admission. The manifest is marked insecure because it is an
attack, and it is expected to fail. A marked block that stops failing breaks
the gates.

<!-- gate: insecure-on-purpose -->
```yaml
# INSECURE ON PURPOSE: the same privileged Pod, aimed at the restricted namespace, which refuses it. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: escape-app
  namespace: app
spec:
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sleep", "1800"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: node-root
          mountPath: /host
  volumes:
    - name: node-root
      hostPath:
        path: /
        type: Directory
```

```bash
kubectl apply -f escape-app.yaml
kubectl --kubeconfig=work/builder.kubeconfig auth can-i create pods -n app
```

<!-- gate: output -->
```text
Error from server (Forbidden): error when creating "work/escape-app.yaml": pods "escape-app" is forbidden: violates PodSecurity "restricted:v1.37": privileged (container "app" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]), restricted volume types (volume "node-root" uses restricted volume type "hostPath"), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
# ...
no
```

The refusal names each rule the Pod breaks. It is the admission half of the
control. The audit half, which records this refusal as a request with its
status code, is covered in the audit section below, and was not run.

### Respond: isolate, capture, cordon, rotate

This is the runbook. The Pod `escape-node` is the compromised workload. The
responder has already seen it in the attack section, and it is still running,
because nothing has been deleted yet.

**Step 1: isolate the Pod's network.** Label the Pod so a NetworkPolicy selects
it, then apply a policy that allows no ingress and no egress for that label.

```bash
kubectl label pod escape-node -n attack quarantine=true
kubectl exec -n attack escape-node -- nslookup kubernetes.default.svc.cluster.local | expand -t 4
```

<!-- gate: output -->
```text
pod/escape-node labeled
# ...
Server:     10.96.0.10
Address:    10.96.0.10:53

Name:   kubernetes.default.svc.cluster.local
Address: 10.96.0.1


```

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: quarantine
  namespace: attack
spec:
  podSelector:
    matchLabels:
      quarantine: "true"
  policyTypes:
    - Ingress
    - Egress
```

```bash
kubectl apply -f quarantine.yaml
kubectl exec -n attack escape-node -- nslookup kubernetes.default.svc.cluster.local | expand -t 4
```

<!-- gate: output -->
```text
networkpolicy.networking.k8s.io/quarantine created
# ...
command terminated with exit code 1
;; connection timed out; no servers could be reached

```

The lookup worked before the policy and timed out after it. On this lab
cluster the policy is enforced: the lookup worked before it and timed out
after it. The `kube-system` DaemonSets listed above are kindnet and
kube-proxy, and the lab did not test which of them enforces the policy. Check
enforcement on your own cluster before you trust a quarantine. The policy cuts
the network only. It does not revoke the token the attacker already holds, so
the steps below still matter.

**Step 2: capture evidence before anything is deleted.** Copy what the cluster
says about the Pod, its logs and its events into a directory that is not on the
cluster. The logs are taken before the Pod is deleted, because a deleted Pod's
logs go with it.

```bash
kubectl get pod escape-node -n attack -o yaml > evidence/pod.yaml
kubectl describe pod escape-node -n attack > evidence/describe.txt
kubectl logs escape-node -n attack > evidence/logs.txt
kubectl get events -n attack > evidence/events.txt
ls -1 evidence
```

<!-- gate: output -->
```text
describe.txt
events.txt
logs.txt
pod.yaml
```

In production, the audit log for the Pod's requests and the Falco alerts are
part of this capture. The Falco alerts for `escape-node` are in the detection
section, and a responder would save them the same way, with `kubectl logs`.
The audit log was not run here.

**Step 3: cordon the node.** `kubectl cordon <node>` stops the scheduler from
placing new Pods there while the investigation runs. On the lab cluster the
script skips it, because cordoning the only node would block every other
workload. Read the step as the procedure, not as a run.

**Step 4: rotate.** Revoke the access, delete the compromised Pod, rotate the
credentials it could reach, and check that each old credential is refused.

```bash
kubectl delete rolebinding ops-secret-reader -n app
kubectl delete pod escape-node -n attack
kubectl --kubeconfig=work/ops.kubeconfig get secret app-db -n app -o name
kubectl --kubeconfig=work/ops.kubeconfig auth whoami
```

<!-- gate: output -->
```text
rolebinding.rbac.authorization.k8s.io "ops-secret-reader" deleted from p05-08-app namespace
# ...
pod "escape-node" deleted from attack namespace
# ...
error: You must be logged in to the server (Unauthorized)
# ...
error: You must be logged in to the server (Unauthorized)
```

The `ops` token was bound to the Pod. After the RoleBinding was deleted and
the Pod was gone, the API server returned `Unauthorized`, which is an
authentication refusal, not an authorization one. Both steps ran before the
check, so the lab cannot say which one caused the refusal. The token is
refused either way. The Kubernetes documentation on [service account
tokens](https://kubernetes.io/docs/concepts/security/service-accounts/)
describes the bound-token model, and the lab checked its behaviour rather than
quoting that page for it.

The `builder` token was minted for the ServiceAccount, not for a Pod. Deleting
and recreating the ServiceAccount is the rotation step that makes the old
token useless:

```bash
kubectl delete serviceaccount builder -n attack
kubectl apply -f builder-sa.yaml
kubectl --kubeconfig=work/builder.kubeconfig auth whoami
```

<!-- gate: output -->
```text
serviceaccount "builder" deleted from attack namespace
# ...
serviceaccount/builder created
# ...
error: You must be logged in to the server (Unauthorized)
```

Then rotate the value the attacker could read. The database behind it changes
at the same time in a real system, so the rotation is a coordinated change, not
a single patch.

```bash
kubectl patch secret app-db -n app --type merge \
  -p '{"stringData":{"password":"lab-rotated-value"}}'
```

<!-- gate: output -->
```text
# ...
secret/app-db patched
```

**Step 5: do not uncordon.** A node whose root filesystem the Pod reached is not
trusted again by returning it to service. The escape here was a `hostPath: /`
mount, so the node is treated as compromised: drain it, replace it, and rotate
what lived on it, including the kubelet's client certificate and any secret the
node held. The lab does not run this step. Its throwaway cluster is deleted
instead.

### Audit: what the log would show (not run)

The audit steps need a cluster whose API server writes an audit log, which
means an API server flag. The policy below is the one the lab would install.
It was not run on a cluster, so nothing below is evidence. Neither recording
created a throwaway cluster, so no audit flag was set on the clusters they
used.

The policy's rules are checked in order, and the first match sets the level.
Secrets and ConfigMaps are `Metadata`, so the log names who read the Secret
and never holds its value. Token requests are `Metadata` for the same reason.
Pod changes are `Request`, so the log keeps the body, which names the image,
the `hostPath` and the `serviceAccountName`. `exec`, `attach` and
`port-forward` have no request body. The command is in the request URI, which
every level keeps. A WebSocket exec request can be audited with the verb `get`
instead of `create`, depending on the release, so the rule lists both verbs.
RBAC changes are `Request`, so a new binding is visible in full. The
authorizer checks `bind` and `escalate`, but audit events carry the request
verb, so the rule does not list them.

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  - level: Metadata
    resources:
      - group: ""
        resources: ["serviceaccounts/token"]
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["pods"]
  - level: Request
    verbs: ["create", "get"]
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
  - level: Metadata
```

The kube-apiserver reads that file through `--audit-policy-file`, and writes
events to the path given by `--audit-log-path`. Neither flag is optional for
this lab: without the policy file no events are logged ([Kubernetes
audit](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)). kind's
Auditing page sets both flags through `kubeadmConfigPatches` ([kind
auditing](https://kind.sigs.k8s.io/docs/user/auditing/)). The kubeadm
configuration in kind uses the v1beta4 list form for `extraArgs`, which is why
the patch below uses a list. The timeouts are for a slow host. A fast machine
may not need them, and the kubeadm defaults are printed in the node image
(`kubeadm config print init-defaults`).

```yaml
# Fragment: the node section of audit-cluster.yaml. The lab applies that
# complete file, which also carries its kind, apiVersion and name lines.
networking:
  apiServerPort: 36081
nodes:
  - role: control-plane
    image: kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
    extraMounts:
      - hostPath: AUDIT_DIR/audit-policy.yaml
        containerPath: /etc/kubernetes/policies/audit-policy.yaml
        readOnly: true
    kubeadmConfigPatches:
      - |
        apiVersion: kubeadm.k8s.io/v1beta4
        kind: InitConfiguration
        timeouts:
          controlPlaneComponentHealthCheck: 10m
          kubernetesAPICall: 10m
      - |
        apiVersion: kubeadm.k8s.io/v1beta4
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            - name: audit-policy-file
              value: /etc/kubernetes/policies/audit-policy.yaml
            - name: audit-log-path
              value: /var/log/kubernetes/kube-apiserver-audit.log
          extraVolumes:
            - name: audit-policies
              hostPath: /etc/kubernetes/policies
              mountPath: /etc/kubernetes/policies
              readOnly: true
              pathType: DirectoryOrCreate
            - name: audit-logs
              hostPath: /var/log/kubernetes
              mountPath: /var/log/kubernetes
              readOnly: false
              pathType: DirectoryOrCreate
```

Replace `AUDIT_DIR` with the directory that holds `audit-policy.yaml` on the
machine that runs kind. The fragment above is the node section of
[`audit-cluster.yaml`](../examples/security-lab/kind/audit-cluster.yaml), the
complete file the lab applies. Apply that file, not the fragment. The lab copies
the policy and the file to the machine that runs kind before it creates the
cluster.

What the lab would query, once the log exists: the events for the lab's two
namespaces, at the `ResponseComplete` stage so each request appears once. For
each one, the user, the verb, the object, the status code, and for Pod changes
the `serviceAccountName`, the `privileged` flag and any `hostPath`. For
`exec`, the command from the request URI. For token requests, who asked for a
token and for which ServiceAccount. A `403` is a refused request, from RBAC or
from admission, and the audit event carries that status. The lab's query was
written for these fields. It did not run.

### Detection: Falco, with Falcosidekick

Falco watches kernel events on each node and turns them into alerts. It sees
what the audit log does not: a process that opens a file or starts a program
inside a container, on the node itself. Falco needs four capabilities to watch
the kernel with its modern eBPF probe. Its [container setup
page](https://falco.org/docs/setup/container/) names them: `CAP_SYS_PTRACE`,
`CAP_SYS_RESOURCE`, `CAP_BPF` and `CAP_PERFMON`. The chart can run the probe
with those capabilities alone, and its least-privileged setting turns that on.
The DaemonSet still mounts host paths, and the lab does not test a lower Pod
Security level for it, so Falco's namespace is labelled `privileged`. That is
an exception. Its namespace carries the two annotations of the exception
record, a reason and an expiry within twelve months, which
[05.09](09-running-security-on-a-platform-team.md) describes.

The lab's Falco configuration selects the modern eBPF driver and turns on
Falcosidekick with debug logging, which is the only output this lab uses. A
real deployment sends alerts to a SIEM or a paging system instead. The lab
keeps one Falcosidekick replica, to stay light on a shared host.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    pod-security.kubernetes.io/enforce: privileged
  annotations:
    security.example/exception-reason: "Falco driver mounts host paths; the container runs without privilege."
    security.example/exception-expires: "2027-06-30"
```

```yaml
driver:
  kind: modern_ebpf
  modernEbpf:
    leastPrivileged: true
image:
  tag: "0.45.2@sha256:1562a643953f938e02f47319b5214d93a235f11f646d60e9b8a516fd5a64698e"
falcoctl:
  image:
    tag: "0.14.3@sha256:2230fb4802aafe09455b58d38f8f1faedd8f09f042e9a18fffd397e63488c023"
falcosidekick:
  enabled: true
  replicaCount: 1
  image:
    tag: "2.32.0@sha256:1976da72151850aae4436f33a5ed94bdef469f42a9b61c182b4feeb5441fb081"
  config:
    debug: true
```

The full run used a three-node kind cluster on a host that other work shared.
Every node of a kind cluster runs on the host's kernel, so the lab pinned
Falco to one worker, to pull and run one instance, and pinned the lab Pod to
the same worker, so the instance that sees its system calls is also the one
that can name its container. It added these two fragments, with the worker's
name for `WORKER_NODE`. A one-node cluster needs neither.

```yaml
# Fragment: added to the end of falco-values.yaml on the three-node cluster.
nodeSelector:
  kubernetes.io/hostname: WORKER_NODE
```

```yaml
# Fragment: added under spec of escape-node on the three-node cluster.
nodeSelector:
  kubernetes.io/hostname: WORKER_NODE
```

The values pin each image by digest. The full run resolved every tag to its
digest in the registry before it installed anything, and each matched the pin.
The command is the same for each image; the block shows the three Falco
images, then only the digests of Trivy Operator's two, which the chart pulls
from its default registry:

```bash
docker buildx imagetools inspect docker.io/falcosecurity/falco:0.45.2 | grep -E '^(Name|Digest):'
```

<!-- gate: output -->
```text
Name:      docker.io/falcosecurity/falco:0.45.2
Digest:    sha256:1562a643953f938e02f47319b5214d93a235f11f646d60e9b8a516fd5a64698e
# ...
Name:      docker.io/falcosecurity/falcoctl:0.14.3
Digest:    sha256:2230fb4802aafe09455b58d38f8f1faedd8f09f042e9a18fffd397e63488c023
# ...
Name:      docker.io/falcosecurity/falcosidekick:2.32.0
Digest:    sha256:1976da72151850aae4436f33a5ed94bdef469f42a9b61c182b4feeb5441fb081
# ...
Digest:    sha256:05191a514247ae644dd5cc71306a94f44faff0a6a3fa817235911b911ecebcb9
# ...
Digest:    sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c
```

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco --version 9.2.2 \
  --namespace falco -f falco-values.yaml
kubectl get pods -n falco -o wide
kubectl logs -n falco POD -c falco | head -30
```

The lab script does not pass `--wait`. Helm's wait cannot stop for a control
plane that restarts, so the script polls the DaemonSet and checks the control
plane's restart count every ten seconds, and stops if it goes up. `POD` is the
Falco Pod's name from the listing.

<!-- gate: output -->
```text
# ...
NAME: falco
# ...
STATUS: deployed
```

<!-- gate: output -->
```text
NAME                                   READY   STATUS    RESTARTS   AGE   IP             NODE               NOMINATED NODE   READINESS GATES
falco-5pxjc                            2/2     Running   0          54s   10.244.1.72    sf-sched-worker    <none>           <none>
falco-falcosidekick-6fd47bc46f-ndbrq   1/1     Running   0          54s   10.244.2.104   sf-sched-worker2   <none>           <none>
```

<!-- gate: output -->
```text
Sat Oct 31 11:40:40 2026: Falco version: 0.45.2 (x86_64)
# ...
Sat Oct 31 11:40:40 2026: Opening 'syscall' source with modern BPF probe.
Sat Oct 31 11:40:40 2026: One ring buffer every '2' CPUs.
Sat Oct 31 11:40:40 2026: [libs]: Trying to open the right engine!
Sat Oct 31 11:40:40 2026: [libs]: libpman: disabled BPF iterators (not running in the root PID namespace, or failed to determine it)
```

Falco opened its modern eBPF probe with the capabilities-only setting, from
inside a kind node, on the host's 7.0.0-38 kernel. The probe has kernel
requirements, which Falco's [container setup
page](https://falco.org/docs/setup/container/) lists; it opened here, so this
kernel met them. The log says one BPF feature
was off, the iterators, because the container is not in the root PID
namespace. The probe still opened. The first Falco install of the run, which
had no node pin, was stopped by the script when the control plane restarted,
before it printed any of this. The lab header gives that account.

The chart's own check from the earlier run is still the evidence that the
render is least-privileged. The driver block alone is in `falco-driver.yaml`.
Its render has no `privileged: true`, and it adds the four capabilities:

```bash
helm show chart falcosecurity/falco --version 9.2.2 | grep -E '^(version|appVersion)'
helm template falco falcosecurity/falco --version 9.2.2 --namespace falco -f falco-driver.yaml > falco-rendered.yaml
grep -c 'privileged: true' falco-rendered.yaml
grep -A5 'capabilities:' falco-rendered.yaml | head -6
```

<!-- gate: output -->
```text
appVersion: 0.45.2
version: 9.2.2
```

<!-- gate: output -->
```text
0
```

<!-- gate: output -->
```text
            capabilities:
              add:
              - BPF
              - SYS_RESOURCE
              - PERFMON
              - SYS_PTRACE
```

Now the lab fires the detections. It creates `escape-node` from the attack
section on the same worker as Falco, as the build identity does, then runs
three commands in it. The first two use `kubectl exec -it`, which gives the
process a terminal, as a person at a keyboard has. The first reads
`/etc/shadow` in the image. The second runs `chroot /host`, so the same path
now names the node's file. The third has no terminal and reads the node's file
through the `/host` mount, as the attack section did.

```bash
kubectl --kubeconfig=work/builder.kubeconfig apply -f escape-node.yaml
kubectl --kubeconfig=work/builder.kubeconfig exec -it -n attack escape-node -- \
  sh -c 'cat /etc/shadow > /dev/null && echo shadow-read'
kubectl --kubeconfig=work/builder.kubeconfig exec -it -n attack escape-node -- \
  sh -c 'chroot /host cat /etc/shadow > /dev/null && echo node-shadow-read'
kubectl --kubeconfig=work/builder.kubeconfig exec -n attack escape-node -- \
  sh -c 'cat /host/etc/shadow > /dev/null && echo host-path-read'
```

<!-- gate: output -->
```text
shadow-read
# ...
node-shadow-read
# ...
host-path-read
```

All three reads succeeded. The alert list is a `jq` filter over Falco's JSON
log, which keeps the priority, the rule and the command line. The filter is
`alert.jq`:

```text
"\(.priority) | \(.rule) | \(.output_fields["proc.cmdline"])"
```

```bash
kubectl logs -n falco ds/falco -c falco | grep escape-node | jq -r -f alert.jq
```

<!-- gate: output -->
```text
# ...
Notice | Terminal shell in container | sh -c cat /etc/shadow > /dev/null && echo shadow-read
Warning | Read sensitive file untrusted | cat /etc/shadow
Notice | Terminal shell in container | sh -c chroot /host cat /etc/shadow > /dev/null && echo node-shadow-read
Warning | Read sensitive file untrusted | cat /etc/shadow
```

Four alerts name commands the lab typed. The shell rule, "Terminal shell in
container", fired at Notice for each of the two commands that had a terminal.
The rule "Read sensitive file untrusted" fired at Warning for each read whose
path was `/etc/shadow`, the image's file the first time and the node's file
the second. Nothing in the list names the third command, which had no terminal
and opened the file as `/host/etc/shadow`. The probable reason is the file
name, which differs from the one the rule lists, and the missing terminal
explains the missing shell alert. The run did not test either explanation.
The practical reading is that a detection rule is a condition on names and
fields, and a read that arrives by another path is not the one it describes.

The elided lines at the top are three alerts at Critical, from the rule "Drop
and execute new binary in container". Their command lines are `mount -o
ro,bind` of files named `product_name` and `product_uuid` onto paths under
`/sys/class/dmi/id` in the Pod's root filesystem. No lab command typed them.
They appeared each of the three times the Pod started while Falco was
running, before any `exec`. They are noise from this cluster that an untuned
rule set produces, and the lab did not investigate them further.

One of the alerts in full shows what Falco knows about the process:

```bash
kubectl logs -n falco ds/falco -c falco | grep 'Read sensitive file untrusted' | grep escape-node | head -1 | jq .
```

<!-- gate: output -->
```text
{
  "hostname": "sf-sched-worker",
# ...
  "output_fields": {
    "container.id": "14b556d74d4d",
    "container.image.repository": "docker.io/library/busybox",
    "container.image.tag": "b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d",
    "container.name": "app",
    "evt.time": 1793446902701698939,
    "evt.type": "openat",
    "fd.name": "/etc/shadow",
    "k8s.ns.name": "attack",
    "k8s.pod.name": "escape-node",
    "proc.aname[2]": "containerd-shim",
    "proc.aname[3]": null,
    "proc.aname[4]": null,
    "proc.cmdline": "cat /etc/shadow",
    "proc.exepath": "/bin/cat",
    "proc.name": "cat",
    "proc.pname": "sh",
    "proc.tty": 34816,
    "user.loginuid": -1,
    "user.name": "root",
    "user.uid": 0
  },
  "priority": "Warning",
  "rule": "Read sensitive file untrusted",
  "source": "syscall",
  "tags": [
    "T1555",
    "container",
    "filesystem",
    "host",
    "maturity_stable",
    "mitre_credential_access"
  ],
```

The alert names the Pod, its namespace, the container, the image and the
process tree, which is what a responder needs and the audit log cannot give.
The image's tag field holds a hash, because the Pod's image has no tag. The
process ran as `root` with a terminal, and `proc.pname` shows its parent was
the `sh` that `kubectl exec` started.

Falcosidekick is the fan-out. With debug logging on, it prints every event it
receives, which is the check that the alerts left Falco:

```bash
kubectl logs -n falco deploy/falco-falcosidekick | grep -c escape-node
kubectl logs -n falco deploy/falco-falcosidekick | grep -m1 'Sensitive file opened' | cut -c1-120
```

<!-- gate: output -->
```text
7
```

<!-- gate: output -->
```text
2026/10/31 11:41:42 [DEBUG] : Falco's payload : {"uuid":"8ff2e2ee-a0b2-4b2e-b960-37ad66a35c99","output":"11:41:42.701698
```

Seven events named the Pod: the three Critical ones and the four above. That
matches the list, so the third command raised nothing.

Falco is removed before anything else goes in, then the cluster is checked for
what it might leave: the namespace, webhook configurations and cluster-wide
roles.

```bash
helm uninstall falco -n falco
kubectl delete namespace falco
kubectl get namespace falco
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ci falco
kubectl get clusterrole,clusterrolebinding -o name | grep -ci falco
```

<!-- gate: output -->
```text
release "falco" uninstalled
# ...
namespace "falco" deleted
# ...
Error from server (NotFound): namespaces "falco" not found
# ...
0
# ...
0
```

Both `grep -ci` counts are the number of matching lines, so `0` is the count
of objects left. The namespace was still there after `helm uninstall`, because
Helm did not create it, so deleting it is a separate step.

### Continuous scanning: Trivy Operator

Admission checks a Pod when it is created. A scanner checks the Pods that are
already running, on a schedule and after changes. Trivy Operator writes a
`ConfigAuditReport` for each workload's spec and a `VulnerabilityReport` for
each image. The lab installs it after Falco is gone, so that one heavy install
at a time shares the cluster, and points it at the `attack` namespace only.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: trivy
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
```

```yaml
targetNamespaces: attack
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10000
  runAsGroup: 10000
  seccompProfile:
    type: RuntimeDefault
securityContext:
  privileged: false
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
operator:
  scanJobsConcurrentLimit: 1
  sbomGenerationEnabled: false
  exposedSecretScannerEnabled: false
  rbacAssessmentScannerEnabled: false
  infraAssessmentScannerEnabled: false
  clusterComplianceEnabled: false
trivyOperator:
  scanJobPodTemplatePodSecurityContext:
    runAsNonRoot: true
    runAsUser: 10000
    runAsGroup: 10000
    seccompProfile:
      type: RuntimeDefault
image:
  tag: "0.36.1@sha256:05191a514247ae644dd5cc71306a94f44faff0a6a3fa817235911b911ecebcb9"
trivy:
  image:
    tag: "0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c"
```

`targetNamespaces` limits the operator to the lab namespace. The chart's
default is a blank string, which selects all namespaces
([chart values](https://github.com/aquasecurity/trivy-operator)). The
`operator` block turns off the scanners the lab does not read and runs one
scan job at a time. The scan jobs are separate Pods in the operator's
namespace, and their Pod settings come from
`trivyOperator.scanJobPodTemplatePodSecurityContext`. The first version of
this chapter put that key at the top level and the Trivy tag under `trivy.tag`.
The chart reads them under `trivyOperator` and `trivy.image`. Helm does not
reject keys a chart does not use, so the render looked right and the settings
did nothing. Reading `helm show values` found the mistake, and the values
above are the corrected ones.

```bash
helm repo add aqua https://aquasecurity.github.io/helm-charts/
helm install trivy aqua/trivy-operator --version 0.38.1 \
  --namespace trivy -f trivy-values.yaml
kubectl get pods -n trivy
```

<!-- gate: output -->
```text
NAME                                       READY   STATUS     RESTARTS   AGE
scan-vulnerabilityreport-bdd695f4b-fztzx   0/1     Init:0/1   0          14s
trivy-trivy-operator-5b5877ddcb-dvv7t      1/1     Running    0          53s
```

The namespace enforces `restricted`, and both Pods were admitted: the operator
and the first scan job, which was already downloading its database. That is
the proof that the values meet the level, and it replaces the probe Pod below
as the evidence for the operator. The probe still shows what the level
refuses.

The probe from the first recording shows what the level refuses. It is a Pod
that carries the operator's pod settings, applied as a server dry run in a
restricted namespace. The same Pod without `runAsNonRoot` is refused. The
`helm template` count from that recording is not repeated, because it was
taken on the misplaced values.

```bash
kubectl apply -f trivy-ns.yaml
kubectl apply --dry-run=server -f operator-probe.yaml; echo "server dry-run exit=$?"
kubectl apply --dry-run=server -f operator-probe-root.yaml; echo "server dry-run exit=$?"
```

<!-- gate: output -->
```text
namespace/p05-08-trivy created
```

<!-- gate: output -->
```text
pod/operator-probe created (server dry run)
server dry-run exit=0
```

<!-- gate: output -->
```text
Error from server (Forbidden): error when creating "operator-probe-root.yaml": pods "operator-probe" is forbidden: violates PodSecurity "restricted:v1.37": runAsNonRoot != true (pod or container "operator" must set securityContext.runAsNonRoot=true)
server dry-run exit=1
```

The operator wrote a `ConfigAuditReport` for `escape-node` shortly after it
started. The query is a `jsonpath` over the failing checks:

```bash
kubectl get configauditreports -n attack
kubectl get configauditreport pod-escape-node -n attack \
  -o jsonpath='{range .report.checks[?(@.success==false)]}{.checkID} {.severity} {.title}{"\n"}{end}'
```

<!-- gate: output -->
```text
NAME              SCANNER   AGE
pod-escape-node   Trivy     3m32s
```

<!-- gate: output -->
```text
AVD-KSV-0036 MEDIUM Protecting Pod service account tokens
AVD-KSV-0030 LOW Runtime/Default Seccomp profile not set
AVD-KSV-0118 HIGH Default security context configured
AVD-KSV-0118 HIGH Default security context configured
AVD-KSV-0121 HIGH Kubernetes resource with disallowed volumes mounted
AVD-KSV-0014 HIGH Root file system is not read-only
AVD-KSV-0106 LOW Container capabilities must only include NET_BIND_SERVICE
AVD-KSV-0003 LOW Default capabilities: some containers do not drop all
AVD-KSV-0012 MEDIUM Runs as root user
AVD-KSV-0021 LOW Runs with GID <= 10000
AVD-KSV-0018 LOW Memory not limited
AVD-KSV-0001 MEDIUM Can elevate its own privileges
AVD-KSV-0020 LOW Runs with UID <= 10000
AVD-KSV-0016 LOW Memory requests not specified
AVD-KSV-0015 LOW CPU requests not specified
AVD-KSV-0104 MEDIUM Seccomp policies disabled
AVD-KSV-0023 MEDIUM hostPath volumes mounted
AVD-KSV-0004 LOW Default capabilities: some containers do not drop any
AVD-KSV-0011 LOW CPU not limited
```

Nineteen lines, one check ID twice. The ones that match the attack are
AVD-KSV-0023, "hostPath volumes mounted", and AVD-KSV-0121, which names
disallowed volume types: the finding admission refused for `escape-app`, in
another form.
AVD-KSV-0036 flags the ServiceAccount token the Pod mounts, the token the
attack used, and AVD-KSV-0012 and AVD-KSV-0014 flag the root user and the
writable root filesystem. There is no check for a privileged container,
because `escape-node` is not privileged: the privileged Pod was `escape-app`,
which admission refused, so it never existed to scan. The scanner reports on
what is running, so admission and the scanner see different Pods. Read the
report as a list to work through. Most of it is spec fields that the baseline
in [01.01](../01-core-workloads/01-pods.md) sets and this Pod leaves out on
purpose: the user, the read-only root filesystem, capabilities, seccomp and
resources.

The scan job for the image produced a `VulnerabilityReport`:

```bash
kubectl get vulnerabilityreports -n attack -o wide
kubectl get vulnerabilityreport pod-escape-node-app -n attack \
  -o jsonpath='{.report.scanner.name} {.report.scanner.version}{"\n"}{.report.artifact.repository}{"\n"}'
```

<!-- gate: output -->
```text
NAME                  REPOSITORY        TAG       SCANNER   AGE   CRITICAL   HIGH   MEDIUM   LOW   UNKNOWN
pod-escape-node-app   library/busybox   busybox   Trivy     16s   0          0      0        0     0
```

<!-- gate: output -->
```text
Trivy sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c
library/busybox
```

The scan job Pod in the listing above produced the report. It counts none at
any severity for this `busybox` image on the day of the run. That is what the
scanner found, and the run does not show why the count is zero. The scanner's
version field holds the pinned digest and not `0.76.1`; the run does not
explain that either.

Trivy Operator leaves more than Falco does. `helm uninstall` removed the
release and left the operator's CRDs on the cluster, as Helm does for CRDs a
chart installs from its `crds` directory (Helm's documentation is in Further
reading).
The lab deleted the namespace, then the twelve CRDs it listed, then checked
for webhook configurations and cluster roles:

```bash
helm uninstall trivy -n trivy
kubectl delete namespace trivy
kubectl get crd -o name | grep aquasecurity.github.io
kubectl get crd -o name | grep aquasecurity.github.io | xargs kubectl delete
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ci trivy
kubectl get clusterrole,clusterrolebinding -o name | grep -ci trivy
```

<!-- gate: output -->
```text
release "trivy" uninstalled
# ...
namespace "p05-08-trivy" deleted
# ...
customresourcedefinition.apiextensions.k8s.io/clustercompliancereports.aquasecurity.github.io
# ...
customresourcedefinition.apiextensions.k8s.io/vulnerabilityreports.aquasecurity.github.io
# ...
customresourcedefinition.apiextensions.k8s.io "clustercompliancereports.aquasecurity.github.io" deleted
# ...
customresourcedefinition.apiextensions.k8s.io "vulnerabilityreports.aquasecurity.github.io" deleted
# ...
0
# ...
0
```

Neither tool left a webhook configuration or a cluster role. The check for a
webhook configuration is part of every removal, because one whose controller
is gone can block API requests, depending on its failure policy
([11.01](../11-advanced-production-patterns/01-admission-webhooks.md)).

Tetragon, the in-kernel enforcement option, was not run. It would add a second
eBPF agent to the shared kernel and a second privileged namespace to the
exceptions registry, and none of this chapter's claims needs it.

### Clean up

The shared run deletes its namespaces. The full run removed each tool and its
leftovers as it went, in the sections above, and deleted the lab's namespaces
last. The throwaway cluster is deleted when the script created it.

```bash
kubectl delete namespace attack app falco trivy
```

<!-- gate: output -->
```text
# ...
namespace "attack" deleted
namespace "p05-08-app" deleted
namespace "p05-08-trivy" deleted
```

The full run ended with the same deletion for its two namespaces, then looked
for what the two tools could have left on the cluster. No webhook
configuration or CRD remains:

```bash
kubectl delete namespace attack app
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations
kubectl get crd
```

<!-- gate: output -->
```text
namespace "attack" deleted
namespace "p05-08-app" deleted
# ...
No resources found
# ...
No resources found
```

## How it works under the hood

**Audit events come from the request path.** The API server builds an event for
each request as it passes through the handler chain, and writes it at the stages
the policy keeps. `omitStages: [RequestReceived]` drops the first stage, so an
ordinary request is recorded once, after the response. A `ResponseStarted`
stage exists only for long-running requests such as watches, and the policy
keeps it, which is why an `exec` can show two events. The first matching rule
sets the level for a request. A level above `Metadata` copies the request body
into the log, which is why a Secret rule must be `Metadata`: the body of a
Secret write is the Secret.

**The runtime layer sees syscalls, not requests.** A detector attaches to kernel
events for every container on the node. It can see events such as an `open` of a
sensitive file or an `execve` of a shell, whether or not the API server saw a
request. Its evidence is the event stream,
which only the detector's outputs keep. The API server's audit log is the
complementary record for changes to the cluster.

**Bound tokens follow the Pod.** A token minted for a Pod is tied to that
Pod's lifetime, and a token minted for a ServiceAccount is tied to that
account's identity. The lab observed both: deleting the Pod ended the
Pod-bound token's authority, and recreating the ServiceAccount ended the token
that was minted for it. Both refusals were `Unauthorized`. The model is
described in the [service account
documentation](https://kubernetes.io/docs/concepts/security/service-accounts/).

**Admission and audit are different records of one event.** A Pod refused by
Pod Security Admission never exists, so there is no Pod to scan later. Its
refusal is a request, and the audit log records requests. This is why the
admission refusal in the lab and the audit record of it are two different
evidence points.

## Production notes

> **In production:** ship audit logs off the control-plane node as they are
> written, to storage the cluster's operators cannot edit. A log the attacker
> can reach is a log the attacker can clean. Restrict who may read it, because
> `Request` events hold Pod specs and exec commands.

> **In production:** a detector that alerts on everything gets its alerts
> ignored. Tune the rules to the workloads you run, and send the alerts where
> someone is paid to read them. Operating that loop is taught in
> [14.13](../14-eks-in-production-a-to-z/13-runtime-defense-and-container-security.md)
> and in
> [15.10](../15-day-to-day-production-ops/10-incident-response-and-on-call.md).

> **In production:** make the runbook a checklist with the evidence paths
> written in before an incident, not after. Isolation, capture and cordon are
> the steps a responder under pressure skips, and each one is cheap to do first.

## Quick Reference

```yaml
# Audit: secrets by metadata only, pod changes and exec by request.
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["pods", "pods/exec", "pods/attach", "pods/portforward"]
  - level: Metadata
```

```yaml
# Quarantine: select the Pod by label, deny all ingress and egress.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: quarantine
  namespace: attack
spec:
  podSelector:
    matchLabels:
      quarantine: "true"
  policyTypes:
    - Ingress
    - Egress
```

```bash
# Response order: isolate, capture, cordon, then revoke and rotate.
kubectl label pod POD -n NAMESPACE quarantine=true
kubectl get pod POD -n NAMESPACE -o yaml > evidence/pod.yaml
kubectl cordon NODE
kubectl delete pod POD -n NAMESPACE
kubectl delete serviceaccount SA -n NAMESPACE && kubectl apply -f SA.yaml
```

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise;
> the answer is the check.

1. **The audit policy records Secrets at `Metadata`. A teammate proposes
   `RequestResponse` so that a Secret change can be reviewed in full. What
   would the log then hold, and who could read it?**
   <details><summary>Show answer</summary>

   The request and response bodies, which for a Secret are the Secret's data,
   base64 encoded. Anyone who can read the audit log could then read every
   Secret value the cluster ever wrote. `Metadata` still records who changed
   the Secret, when, and with what verb, so the review question is answered
   without the value.

   </details>

2. **The quarantine policy denies all traffic for the labelled Pod. Why is that
   not enough to end the incident?**
   <details><summary>Show answer</summary>

   The policy cuts the network only. The attacker already holds a token, and a
   token is authority that travels with the credential, not with the connection.
   Revoking the RoleBinding, deleting the Pod so its bound token stops working,
   and recreating the ServiceAccount are the steps that end the authority. The
   lab observed the token refusals after those steps.

   </details>

3. **The runbook says capture before deleting. Name one piece of evidence that
   deletion would destroy, and say where a responder would keep the copy.**
   <details><summary>Show answer</summary>

   The Pod's object, including its `hostPath` and `serviceAccountName`, and the
   events that explain its state. Deletion removes both. The responder keeps a
   copy in an evidence directory off the cluster, and the audit log and the
   detector's alerts are kept in their own stores, so they survive the
   deletion.

   </details>

4. **The lab read the node's `/etc/shadow` three ways. Falco alerted for two
   of them and said nothing about the third. What does that tell you about
   relying on a detector alone, and what control closes the gap?**
   <details><summary>Show answer</summary>

   A detection rule is a condition on names and fields, such as a file path or
   a terminal. The two alerted reads used the path the rule lists, and the
   silent one reached the same file as `/host/etc/shadow` with no terminal. A
   detector shows that an event happened, and the absence of an alert is not
   proof that nothing did. The control that closes the gap is the one that
   removes the means: the `hostPath` mount that made the read possible is
   refused at the `restricted` level, as the harden step showed.

   </details>

## Further reading

- Official:
  <https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/>,
  <https://kubernetes.io/docs/concepts/security/service-accounts/>,
  <https://kubernetes.io/docs/concepts/services-networking/network-policies/>,
  and kind's auditing page, <https://kind.sigs.k8s.io/docs/user/auditing/>.
- Falco's container setup and modern eBPF notes,
  <https://falco.org/docs/setup/container/>, and Falcosidekick,
  <https://github.com/falcosecurity/falcosidekick>.
- Trivy Operator, <https://github.com/aquasecurity/trivy-operator>.
- Helm, CRDs in charts,
  <https://helm.sh/docs/chart_best_practices/custom_resource_definitions/>.
- Tetragon, <https://tetragon.io/docs/>, for in-kernel enforcement. Not run
  here.
- Production operation:
  [14.13](../14-eks-in-production-a-to-z/13-runtime-defense-and-container-security.md)
  and
  [15.10](../15-day-to-day-production-ops/10-incident-response-and-on-call.md).
