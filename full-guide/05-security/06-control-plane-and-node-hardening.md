# 06 - Control plane and node hardening

> The API server, the kubelet and etcd each answer requests, and each one's
> settings decide who gets an answer. This chapter reads those settings on a
> running node, probes them from a restricted Pod that holds no token, grants
> a monitoring token only the kubelet's stats, and sorts kube-bench's failures
> into the ones that matter and the ones a kind node cannot pass. It also
> checks a release binary by checksum and signature. The lab changes no flag
> on the cluster it runs on. The flag edits are cited and labelled not run.

**Estimated time:** ~40 min read, ~30 min hands-on (the lab is scripted)

**Prerequisites:**

- [Part 00 ch.04](../00-foundations/04-control-plane-deep-dive.md): the API
  server, etcd and the kubelet
- [05.00](00-the-attackers-view.md): what a Pod learns from the node and its
  kubelet
- [05.01](01-authn-authz-rbac.md): the RBAC bindings that anonymous requests
  meet
- [05.04](04-secrets-and-cluster-hardening.md): what etcd holds, and why its
  client certificates matter

**You'll know after this:**

- explain why an anonymous request gets a 403 from RBAC on one cluster and a
  401 from the authenticator on another
- read the API server, kubelet and etcd settings from a running node
- show that etcd refuses a client that presents no certificate
- grant a token the kubelet's stats endpoint and nothing else, and show where
  that boundary holds
- read kube-bench output, pin its benchmark, and sort its failures into fixes
  and limits
- check a release binary by checksum and by signature

<!-- tags: security, control-plane, kubelet, etcd, kube-bench, supply-chain, day-2 -->

## Why this exists

The control plane is the cluster. [Chapter 02](02-pod-security.md) kept a
container inside its node, and [chapter 01](01-authn-authz-rbac.md) limited
what an identity may do. Neither helps when a component answers the wrong
callers: an API server that serves anonymous requests, a kubelet with a port
open to the network, or an etcd that accepts any connection. These are
settings, chosen once when the cluster was built. A wrong default keeps
running until someone reads it.

This chapter has three jobs. It shows which of these settings are the
defaults, reads what a node actually runs, and closes the ones that are wrong.
The lab runs on the shared cluster, whose flags are not ours to change. So it
proves the side that already holds, and it cites the rest.

## Mental model

Four parts answer for the cluster, and each one decides who may ask by a
setting, not by a rule in a manifest:

- **The API server** authenticates every request. A request with no
  credentials becomes `system:anonymous` in the group
  `system:unauthenticated`, and RBAC then decides what that identity may do.
  With anonymous access on, one permissive binding to the unauthenticated
  group is enough to read the cluster.
- **The kubelet** answers on every node. Its secure port asks for a credential
  and checks it. Its read-only port, when it is turned on, answers without
  one.
- **etcd** holds the state the API server reads and writes. Its client port
  can require a certificate. etcd's own documentation says transport
  authentication is not enabled by default, so a cluster that needs it must
  set it.
- **The binaries and config files** that start all of these are the control
  plane's supply chain. A binary you cannot check is a component you cannot
  trust.

kube-bench reads the flags of the running processes and the config files on
the node, then compares what it finds with a benchmark. It sees the settings.
It cannot say which of them are right for your cluster, so the triage is
yours.

## Threats and controls

| Threat | Control this chapter teaches | Where it goes deeper |
|---|---|---|
| Anonymous requests reach the API server, and one permissive binding to `system:unauthenticated` lets any caller read | `--anonymous-auth=false`, and no binding to the unauthenticated group | [05.01](01-authn-authz-rbac.md) for bindings; the kube-bench triage below for `1.2.1` |
| The kubelet's read-only port serves Pod listings to anyone who can reach the node | `readOnlyPort: 0`, which is the default | [05.00](00-the-attackers-view.md) for a kubelet reached from a Pod |
| A kubelet with anonymous requests on, or with `AlwaysAllow`, serves every endpoint to any caller | Webhook authentication and authorization, with anonymous access off | the kubelet section below |
| A metrics token can reach kubelet endpoints that run commands, because `nodes/proxy` covers them all | Fine-grained kubelet authorization, granting `nodes/stats` and `nodes/pods` only | [05.01](01-authn-authz-rbac.md) for RBAC rules |
| etcd answers any connection, so a Pod on the node network can read its keyspace | `--client-cert-auth=true`, and peer certificates | [05.04](04-secrets-and-cluster-hardening.md) for what etcd holds; [11.08](../11-advanced-production-patterns/08-ha-control-plane-and-etcd.md) for etcd in production |
| A profiling endpoint exposes runtime data from the API server, the scheduler and the controller manager | `--profiling=false` on each component | the kube-bench triage below, checks `1.2.15`, `1.3.2` and `1.4.1` |
| A tampered release binary runs on the control plane | A checksum and a signature, checked before the binary runs | [05.03](03-supply-chain.md) for signed images; [15.03](../15-day-to-day-production-ops/03-image-signing-and-provenance.md) for signing in production |
| A cluster left on an old minor version keeps bugs the release fixed | Upgrades one minor version at a time, cited and not run | [10.01](../10-cloud-and-managed-kubernetes/01-managed-kubernetes-model.md) for a managed control plane |

The operating system under each node has its own hardening: services, file
permissions and kernel parameters. That is cited in
[Further reading](#further-reading), because the lab runs on a container and
cannot show a host's settings.

## The lab: the shared cluster, read and probed

> **Lab 05.06 (tier A).** Ran on the shared kind cluster `sf-pilot`. The node
> runs Kubernetes v1.37.0 (`kindest/node:v1.37.0`) with containerd 2.3.4 on
> Debian 13. kubectl is v1.37.2 on the workstation, and kube-bench is v0.16.0,
> pinned by its index digest. The script is
> [`labs/05-06.sh`](../examples/security-lab/labs/05-06.sh) and the recorded
> runs are in
> [`evidence/05-06.txt`](../examples/security-lab/evidence/05-06.txt). **Run
> it only against a kind cluster you own.** The script refuses any context
> that is not `kind-*`. It creates three `p05-` namespaces and a few
> cluster-scoped objects named `p05-06-*`, and deletes them when it finishes.
> It changes no flag on the node. A kind node is a container on the machine
> that runs kind, and it shares that machine's kernel. The probes run from a
> Pod on the node network or through kubectl, and nothing here reaches a cloud
> or runs a kernel exploit.

What did not work the first time, kept in the transcript rather than tidied
away:

- kube-bench first ran with every capability dropped. It then printed
  `permission denied` for root-owned files under `/etc/systemd`. Dropping
  `ALL` also removes the root user's right to read files whose permission bits
  deny it. The fix adds back `DAC_READ_SEARCH`, the one capability this job
  needs.
- The first fine-grained run kept `/pods` at 403 after a `nodes/pods` grant.
  The kubelet caches its authorization decisions. The kubelet configuration
  reference gives the defaults: 30 seconds for a denial and 5 minutes for an
  allow. The script now waits 35 seconds after each grant and 310 seconds
  after the broad grant is removed.
- The lab was first meant to run on a throwaway cluster, so it could edit the
  flags. The lab host could not bring up a new control plane during this run,
  even with no patches, so those steps did not run. See
  [What the lab did not run](#6-what-the-lab-did-not-run).

### 1. The settings the node runs with

The lab reads three files from the node. `$NODE` is the node's name from
`kubectl get nodes`.

```sh
docker exec $NODE grep -n -E '^readOnlyPort|^  anonymous:|enabled: |^  mode: ' /var/lib/kubelet/config.yaml
docker exec $NODE grep -n -E 'kube-apiserver$|anonymous|profiling|authorization-mode' /etc/kubernetes/manifests/kube-apiserver.yaml
docker exec $NODE grep -n -E 'client-cert-auth|listen-client-urls' /etc/kubernetes/manifests/etcd.yaml
```

<!-- gate: output -->
```text
3:  anonymous:
4:    enabled: false
7:    enabled: true
11:  mode: Webhook
7:    component: kube-apiserver
9:  name: kube-apiserver
14:    - kube-apiserver
17:    - --authorization-mode=Node,RBAC
55:    name: kube-apiserver
17:    - --client-cert-auth=true
# ...
28:    - --peer-client-cert-auth=true
```

Read the kubelet lines first. Line 4 is the kubelet's anonymous setting, and
it is `false`. Line 7 is the webhook's own `enabled: true`, which the same
pattern also matches. Line 11 is the authorization mode, `Webhook`. The file
has no `readOnlyPort` line, so the default of `0` applies. The API server's
manifest sets `--authorization-mode=Node,RBAC` and has no `--anonymous-auth`
flag, so the default applies, and that default is `true`. The etcd manifest
sets `--client-cert-auth=true` and `--peer-client-cert-auth=true`. The line
that lists etcd's listen addresses is left out of the block above.

### 2. kube-bench, first with no benchmark named, then pinned

kube-bench picks a benchmark from the Kubernetes version it detects. Its
version map in release v0.16.0 ends at Kubernetes 1.34: `1.32`, `1.33` and
`1.34` all map to `cis-1.12`, and nothing covers 1.35 to 1.37. A 1.37 cluster
therefore has no entry to match.

The first run leaves the benchmark to kube-bench, as the upstream Job does.
The Job cannot reach the API server, so kube-bench warns that it did not
detect the version and assumes a default. The run completes, but the totals
differ from the pinned run, and the lines this lab prints do not name the
benchmark it used. An unnamed benchmark is a benchmark you did not choose.

The job below carries the pinned benchmark in its `args`. The first run used
the same Job with that line removed. The lab script's `wait_job` helper polls
the Job until it completes, fails or times out.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: p05-kube-bench
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-bench
  namespace: p05-kube-bench
automountServiceAccountToken: false
```

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a diagnostic Job that reads the node's process table and config files as root, so it needs hostPID, hostPath and root. Lab cluster only.
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench
  namespace: p05-kube-bench
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-bench
    spec:
      serviceAccountName: kube-bench
      automountServiceAccountToken: false
      restartPolicy: Never
      hostPID: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: kube-bench
          image: docker.io/aquasec/kube-bench@sha256:75506f222d1eb6ce2a751a5533bdc0a3b54c898e2e49e7751d0ee22cfb862679  # aquasec/kube-bench:v0.16.0
          command: ["kube-bench"]
          args: ["run", "--benchmark", "cis-1.12"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              add: ["DAC_READ_SEARCH"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: var-lib-cni
              mountPath: /var/lib/cni
              readOnly: true
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: var-lib-kube-scheduler
              mountPath: /var/lib/kube-scheduler
              readOnly: true
            - name: var-lib-kube-controller-manager
              mountPath: /var/lib/kube-controller-manager
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: lib-systemd
              mountPath: /lib/systemd/
              readOnly: true
            - name: srv-kubernetes
              mountPath: /srv/kubernetes/
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: usr-bin
              mountPath: /usr/local/mount-from-host/bin
              readOnly: true
            - name: etc-cni-netd
              mountPath: /etc/cni/net.d/
              readOnly: true
            - name: opt-cni-bin
              mountPath: /opt/cni/bin/
              readOnly: true
      volumes:
        - name: tmp
          emptyDir: {}
        - name: var-lib-cni
          hostPath:
            path: /var/lib/cni
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: var-lib-kube-scheduler
          hostPath:
            path: /var/lib/kube-scheduler
        - name: var-lib-kube-controller-manager
          hostPath:
            path: /var/lib/kube-controller-manager
        - name: etc-systemd
          hostPath:
            path: /etc/systemd
        - name: lib-systemd
          hostPath:
            path: /lib/systemd
        - name: srv-kubernetes
          hostPath:
            path: /srv/kubernetes
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
        - name: usr-bin
          hostPath:
            path: /usr/bin
        - name: etc-cni-netd
          hostPath:
            path: /etc/cni/net.d
        - name: opt-cni-bin
          hostPath:
            path: /opt/cni/bin
```

The Job runs as root. The image declares no user, and the files it reads on
the node belong to root. The `hostPID` setting lets it see the node's
processes, and the `hostPath` volumes let it read the node's config. The
baseline forbids both, so the namespace is labelled `privileged`, and the Job
carries the marker. It still drops every capability, adds back only
`DAC_READ_SEARCH`, and mounts the root filesystem read-only.

```sh
kubectl apply -f kube-bench-auto.yaml
wait_job; echo "job status: $? (0 complete, 1 failed, 2 timed out)"
kubectl -n p05-kube-bench logs job/kube-bench > kb-auto.txt
head -n 2 kb-auto.txt
grep -A4 '^== Summary total' kb-auto.txt
kubectl -n p05-kube-bench delete job kube-bench --wait=true
kubectl apply -f kube-bench.yaml
wait_job; echo "job status: $?"
kubectl -n p05-kube-bench logs job/kube-bench > kb-run.txt
grep -A4 '^== Summary total' kb-run.txt
grep -E '^== Summary (master|etcd|controlplane|node|policies)' -A4 kb-run.txt
grep -E '^\[FAIL\]' kb-run.txt
grep -E '^\[(PASS|FAIL|WARN|INFO)\] (1\.2\.1|1\.2\.15|2\.2|4\.2\.1|4\.2\.2|4\.2\.4) ' kb-run.txt
kubectl -n p05-kube-bench delete job kube-bench --wait=true
```

<!-- gate: output -->
```text
job status: 0 (0 complete, 1 failed, 2 timed out)
Warning: Kubernetes version was not auto-detected because kubectl could not connect to the Kubernetes server. This may be because the kubeconfig information is missing or has credentials that do not match the server. Assuming default version 1.18
Warning: Kubernetes version was not auto-detected because kubectl could not connect to the Kubernetes server. This may be because the kubeconfig information is missing or has credentials that do not match the server. Assuming default version 1.18
== Summary total ==
69 checks PASS
12 checks FAIL
41 checks WARN
0 checks INFO
```

<!-- gate: output -->
```text
job status: 0
== Summary total ==
63 checks PASS
12 checks FAIL
56 checks WARN
0 checks INFO
== Summary master ==
39 checks PASS
10 checks FAIL
11 checks WARN
0 checks INFO
# ...
[FAIL] 1.1.12 Ensure that the etcd data directory ownership is set to etcd:etcd (Automated)
[FAIL] 1.2.5 Ensure that the --kubelet-certificate-authority argument is set as appropriate (Automated)
[FAIL] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
[FAIL] 1.2.16 Ensure that the --audit-log-path argument is set (Automated)
[FAIL] 1.2.17 Ensure that the --audit-log-maxage argument is set to 30 or as appropriate (Automated)
[FAIL] 1.2.18 Ensure that the --audit-log-maxbackup argument is set to 10 or as appropriate (Automated)
[FAIL] 1.2.19 Ensure that the --audit-log-maxsize argument is set to 100 or as appropriate (Automated)
[FAIL] 1.2.30 Ensure that the --service-account-extend-token-expiration parameter is set to false (Automated)
[FAIL] 1.3.2 Ensure that the --profiling argument is set to false (Automated)
[FAIL] 1.4.1 Ensure that the --profiling argument is set to false (Automated)
[FAIL] 4.1.1 Ensure that the kubelet service file permissions are set to 600 or more restrictive (Automated)
[FAIL] 4.1.9 If the kubelet config.yaml configuration file is being used validate permissions set to 600 or more restrictive (Automated)
[WARN] 1.2.1 Ensure that the --anonymous-auth argument is set to false (Manual)
[FAIL] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
[PASS] 2.2 Ensure that the --client-cert-auth argument is set to true (Automated)
[PASS] 4.2.1 Ensure that the --anonymous-auth argument is set to false (Automated)
[PASS] 4.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow (Automated)
[PASS] 4.2.4 Verify that if defined, the --read-only-port argument is set to 0 (Manual)
```

Pinned to `cis-1.12`, the run reports 63 checks passed, 12 failed and 56
warned. A manual check can still pass when kube-bench can read the value from
the node, as `4.2.4` does. A manual check it cannot read is a WARN, as `1.2.1`
is. The checks that matter most here are these:

- `[WARN] 1.2.1`: the API server's anonymous setting is manual in the
  benchmark, so kube-bench cannot read a value and warns. Section 3 shows the
  answer that matters: anonymous requests get 403 from RBAC.
- `[PASS] 2.2`, `[PASS] 4.2.1`, `[PASS] 4.2.2` and `[PASS] 4.2.4`: client
  certificates on etcd, anonymous kubelet access off, no `AlwaysAllow`, and a
  read-only port of 0. These are the kubelet and etcd settings from section 1.

The twelve failures sort into fixes and limits:

| Check | What it says | Verdict on this node |
|---|---|---|
| `1.2.15`, `1.3.2`, `1.4.1` | `--profiling` is not `false` on the API server, the controller manager and the scheduler | Fix. The flag is absent, and kube-bench reads that as profiling on. Set `--profiling=false` on each. Not run here. |
| `1.2.5` | `--kubelet-certificate-authority` is not set | Fix, with a prerequisite. Without it the API server does not verify the kubelet's serving certificate. The fix needs kubelet serving certificates from a CA. The lab did not set that up. Cited, not run. |
| `1.2.16` to `1.2.19` | No audit log path, age, backup or size | Fix, and it belongs to the audit policy. The API server's flags set no audit log path. <!-- link-later: 05.08 --> Chapter 05.08 covers the policy and its flags. |
| `1.2.30` | The service account token expiry extension is not set to `false` | Fix. It is a token-lifetime setting, and [05.00](00-the-attackers-view.md) showed what a token can do. Not run here. |
| `1.1.12` | The etcd data directory is not owned by `etcd:etcd` | Limit on this node. etcd runs as a static Pod here, and the check expects a dedicated owner for the data directory. Changing it is a kubeadm change, not run. |
| `4.1.1`, `4.1.9` | The kubelet service file and its config file are not `600` or stricter | Limit on a kind node, because the files sit inside the node container. On a host they are permissions to set. Cited, not run, under node OS hardening. |

The node passes `4.2.1` and `4.2.4` because its kubelet config already
disables anonymous access and leaves the read-only port at its default of 0. A
node rebuilt with different settings can fail those same checks.

### 3. Attack from a Pod with no token

The probe is a restricted Pod with no ServiceAccount token. It stands for a
Pod an attacker already controls. It reads the cluster CA from a ConfigMap, so
its requests to the API server verify the server's certificate. The kubelet
and etcd probes skip server verification, because those certificates are not
signed by the CA the probe mounts. The point of those probes is what the node
answers.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: p05-attack
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: probe
  namespace: p05-attack
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: p05-attack
spec:
  serviceAccountName: probe
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777  # curlimages/curl:8.22.0
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cluster-ca
          mountPath: /etc/cluster-ca
          readOnly: true
  volumes:
    - name: tmp
      emptyDir: {}
    - name: cluster-ca
      configMap:
        name: kube-root-ca.crt
```

```sh
kubectl apply -f probe.yaml
kubectl -n p05-attack wait --for=condition=Ready pod/probe --timeout=180s
kubectl auth can-i get pods --as=system:anonymous --as-group=system:unauthenticated
kubectl exec -n p05-attack probe -- sh -c 'curl -s -o /dev/null -w "anonymous, secrets in kube-system: %{http_code}\n" --cacert /etc/cluster-ca/ca.crt https://kubernetes.default.svc/api/v1/namespaces/kube-system/secrets'
kubectl exec -n p05-attack probe -- sh -c 'curl -s -o /dev/null -w "anonymous, pods in all namespaces: %{http_code}\n" --cacert /etc/cluster-ca/ca.crt https://kubernetes.default.svc/api/v1/pods'
kubectl exec -n p05-attack probe -- env NODE_IP=$NODE_IP sh -c 'curl -s -o /dev/null -w "kubelet read-only port 10255: %{http_code}\n" --max-time 5 http://$NODE_IP:10255/pods; echo "exit code: $?"'
kubectl exec -n p05-attack probe -- env NODE_IP=$NODE_IP sh -c 'curl -sk -o /dev/null -w "kubelet 10250, anonymous: %{http_code}\n" --max-time 5 https://$NODE_IP:10250/pods'
kubectl exec -n p05-attack probe -- env NODE_IP=$NODE_IP sh -c 'curl -sSk --max-time 5 https://$NODE_IP:2379/version 2>&1; echo "exit code: $?"'
kubectl exec -n p05-attack probe -- env NODE_IP=$NODE_IP sh -c 'curl -sSk --max-time 5 -H "Content-Type: application/json" -d "{\"key\":\"L3JlZ2lzdHJ5L25hbWVzcGFjZXMva3ViZS1zeXN0ZW0=\"}" https://$NODE_IP:2379/v3/kv/range 2>&1; echo "exit code: $?"'
```

<!-- gate: output -->
```text
Error from server (Forbidden): selfsubjectaccessreviews.authorization.k8s.io is forbidden: User "system:anonymous" cannot create resource "selfsubjectaccessreviews" in API group "authorization.k8s.io" at the cluster scope
anonymous, secrets in kube-system: 403
anonymous, pods in all namespaces: 403
# ...
kubelet read-only port 10255: 000
exit code: 7
kubelet 10250, anonymous: 401
# ...
curl: (55) OpenSSL SSL_read: OpenSSL/3.5.8: error:0A00045C:SSL routines::tlsv13 alert certificate required, errno 0
exit code: 55
curl: (55) OpenSSL SSL_read: OpenSSL/3.5.8: error:0A00045C:SSL routines::tlsv13 alert certificate required, errno 0
exit code: 55
```

Three things are visible here. The anonymous API requests reach RBAC and stop
there, with a 403. The `kubectl auth can-i` call fails, because an anonymous
identity may not create a SelfSubjectAccessReview, so the caller cannot even
ask what it may do. The kubelet's read-only port is closed, so curl gets no
connection, which is exit code 7 and status `000`. The kubelet's secure port
answers an anonymous request with 401, which is the authenticator refusing it
before any authorization happens. That is the stronger answer: a 403 means the
request got past authentication and was refused by authorization.

etcd refuses the TLS handshake, because the client sends no certificate. The
alert is `certificate required`, and curl exits with 55. The etcd
documentation describes the same refusal: requests that do not supply a valid
client certificate fail.

The lab does not create a binding that grants `view` to
`system:unauthenticated`. On a shared cluster, such a binding would apply to
every caller until someone removed it. Its effect follows from the RBAC rules:
with the binding in place, the probe's 403 for `pods` would become a 200, with
no credential at all. That is reasoned from the rules, and it is not run.

### 4. Fine-grained kubelet authorization

With webhook authorization, every kubelet request becomes a
SubjectAccessReview. The kubelet asks the API server whether the caller may
use a subresource of `nodes`. Since Kubernetes v1.36 this is stable and
enabled by default, under the `KubeletFineGrainedAuthz` gate. The mapping is
what the reader needs:

- `/stats/*` checks `nodes/stats`.
- `/pods` checks `nodes/pods`, or falls back to `nodes/proxy`.
- Every other endpoint checks `nodes/proxy`, including `/containerLogs`.

`nodes/proxy` is the broad one. The kubelet's authentication and authorization
page warns that it grants every other kubelet API, including the ones that run
commands in containers on the node.

The monitoring agent below holds a dedicated token, and it is the one Pod in
this section that mounts one. The baseline allows that only with a dedicated
ServiceAccount, which this Pod has.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: p05-kubelet-authz
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: stats-agent
  namespace: p05-kubelet-authz
automountServiceAccountToken: true
---
apiVersion: v1
kind: Pod
metadata:
  name: stats-agent
  namespace: p05-kubelet-authz
spec:
  serviceAccountName: stats-agent
  automountServiceAccountToken: true
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777  # curlimages/curl:8.22.0
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: p05-06-node-stats
rules:
  - apiGroups: [""]
    resources: ["nodes/stats"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: p05-06-node-stats
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: p05-06-node-stats
subjects:
  - kind: ServiceAccount
    name: stats-agent
    namespace: p05-kubelet-authz
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: p05-06-node-pods
rules:
  - apiGroups: [""]
    resources: ["nodes/pods"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: p05-06-node-pods
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: p05-06-node-pods
subjects:
  - kind: ServiceAccount
    name: stats-agent
    namespace: p05-kubelet-authz
```

The next block is the broad grant, and the lab applies it for one check. It is
the one object in this chapter that is deliberately broad, and it is not a
pattern to copy. The static gate flags it as a high finding, KSV-0047, which
reads "do not allow privilege escalation from node proxy". The block therefore
carries the insecure marker. The gate's stale check keeps that honest: the
marker is valid only while the finding holds.

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a ClusterRole that grants nodes/proxy, which reaches every kubelet endpoint, for one check. Lab cluster only.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: p05-06-node-proxy
rules:
  - apiGroups: [""]
    resources: ["nodes/proxy"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: p05-06-node-proxy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: p05-06-node-proxy
subjects:
  - kind: ServiceAccount
    name: stats-agent
    namespace: p05-kubelet-authz
```

```sh
kubectl apply -f stats-agent.yaml
kubectl apply -f node-stats.yaml
kubectl -n p05-kubelet-authz wait --for=condition=Ready pod/stats-agent --timeout=180s
kubectl exec -n p05-kubelet-authz stats-agent -- env NODE_IP=$NODE_IP sh -c 'T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); for p in /stats/summary /pods /containerLogs/p05-kubelet-authz/none/none; do curl -sk -o /dev/null -w "$p, nodes/stats only: %{http_code}\n" -H "Authorization: Bearer $T" --max-time 5 https://$NODE_IP:10250$p; done'
kubectl apply -f node-pods.yaml
sleep 35
kubectl exec -n p05-kubelet-authz stats-agent -- env NODE_IP=$NODE_IP sh -c 'T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); for p in /stats/summary /pods /containerLogs/p05-kubelet-authz/none/none; do curl -sk -o /dev/null -w "$p, with nodes/pods added: %{http_code}\n" -H "Authorization: Bearer $T" --max-time 5 https://$NODE_IP:10250$p; done'
kubectl apply -f node-proxy.yaml
sleep 35
kubectl exec -n p05-kubelet-authz stats-agent -- env NODE_IP=$NODE_IP sh -c 'T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -o /dev/null -w "/containerLogs, with the broad nodes/proxy grant: %{http_code}\n" -H "Authorization: Bearer $T" --max-time 5 https://$NODE_IP:10250/containerLogs/p05-kubelet-authz/none/none'
kubectl delete clusterrolebinding p05-06-node-proxy clusterrole p05-06-node-proxy --ignore-not-found
sleep 310
kubectl exec -n p05-kubelet-authz stats-agent -- env NODE_IP=$NODE_IP sh -c 'T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -o /dev/null -w "/containerLogs, after the broad grant is removed: %{http_code}\n" -H "Authorization: Bearer $T" --max-time 5 https://$NODE_IP:10250/containerLogs/p05-kubelet-authz/none/none'
```

<!-- gate: output -->
```text
/stats/summary, nodes/stats only: 200
/pods, nodes/stats only: 403
/containerLogs/p05-kubelet-authz/none/none, nodes/stats only: 403
# ...
/stats/summary, with nodes/pods added: 200
/pods, with nodes/pods added: 200
/containerLogs/p05-kubelet-authz/none/none, with nodes/pods added: 403
# ...
/containerLogs, with the broad nodes/proxy grant: 404
# ...
/containerLogs, after the broad grant is removed: 403
```

Read the table as the mapping predicts. With `nodes/stats` alone, the token
reads `/stats/summary` and nothing else. Adding `nodes/pods` opens `/pods` and
no other endpoint. The broad grant turns `/containerLogs` from 403 into 404.
The 404 means the request passed authorization and reached the handler, which
found no container named `none`. The lab did not run a command in any
container. The lab waited 310 seconds before the last probe. The kubelet may
keep an allowed decision for up to 5 minutes, so that wait makes the final 403
a fair test of the removal.

Both waits are the cache at work. A grant shows up on the kubelet only after
any cached denial expires, and a revocation shows up only after any cached
allow expires.

### 5. The kubectl binary, by checksum and by signature

The workstation's kubectl is checked against the release path for its own
version and platform. The Kubernetes install page gives the checksum file, and
the signing page gives the signature and certificate files and a cosign
command.

```sh
kubectl version --client -o yaml | grep gitVersion
os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m); [ "$arch" = x86_64 ] && arch=amd64
ver=$(kubectl version --client -o yaml | awk '/gitVersion/{print $2; exit}')
echo "release path: https://dl.k8s.io/release/$ver/bin/$os/$arch/"
cp "$(command -v kubectl)" kubectl
curl -sSfL -o kubectl.sha256 "https://dl.k8s.io/release/$ver/bin/$os/$arch/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | shasum -a 256 -c
curl -sSfL -o kubectl.sig "https://dl.k8s.io/release/$ver/bin/$os/$arch/kubectl.sig"
curl -sSfL -o kubectl.cert "https://dl.k8s.io/release/$ver/bin/$os/$arch/kubectl.cert"
cosign verify-blob kubectl --signature kubectl.sig --certificate kubectl.cert --certificate-identity "$KREL_IDENTITY" --certificate-oidc-issuer https://accounts.google.com
```

<!-- gate: output -->
```text
  gitVersion: v1.37.2
release path: https://dl.k8s.io/release/v1.37.2/bin/darwin/arm64/
kubectl: OK
Flag --signature has been deprecated, please use --bundle to provide a signature
Flag --certificate has been deprecated, please use --bundle with --trusted-root to provide the public certificate
Verified OK
```

The checksum matches, and the signature verifies against the release identity
and issuer that the signing page names. The signing page notes that cosign 2.0
requires both options, so the check names who must have signed the binary. The
installed cosign prints deprecation notices for `--signature` and
`--certificate`, and it still verifies. The signing page uses those flags. A
newer workflow should follow the cosign notice and use `--bundle`.

The lab checks the workstation's binary, not the node's. The same two steps
apply to `kube-apiserver` and `kubelet` from the same release path, and the
lab did not run them on the node.

### 6. What the lab did not run

These are cited and labelled not run. None of them is evidence in this
chapter.

- **The flag edits.** Setting `--anonymous-auth=false`, `--profiling=false`,
  `readOnlyPort: 0`, the kubelet's anonymous and authorization settings, and
  `--client-cert-auth=true` on a node that starts without them needs a cluster
  built with those settings. The lab host could not bring up a fresh kind
  cluster during this run. A plain cluster with no patches failed in the same
  kubeadm wait, on a host whose load was near 8 on 4 CPUs. The shared cluster
  already runs the secure side, so the before-and-after kube-bench comparison,
  the re-attack after hardening, and an open read-only port are not shown
  here. The settings are cited to the
  [kube-apiserver](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
  and [kubelet
  configuration](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
  references.
- **A real kubeadm upgrade.** The kubeadm upgrade page says to move one minor
  version at a time, and it supports 1.36.x to 1.37.x and patch releases
  within 1.37. The page's command sequence (plan, apply, drain, upgrade the
  kubelet, uncordon) was read, not run.
- **Node OS hardening.** The securing-a-cluster page covers the cluster's own
  surfaces and links the Linux node guidance separately. It was read, not run
  on a host.
- **Verifying the node's binaries.** The lab checked the workstation's kubectl
  only.

## How it works under the hood

**Anonymous requests.** The API server's authenticator labels a request that
no other authenticator accepts as `system:anonymous`, in the group
`system:unauthenticated`. Anonymous access is enabled by default when the
authorization mode is anything other than `AlwaysAllow`. With `AlwaysAllow`,
it is off by default. Setting `--anonymous-auth=false` makes the authenticator
refuse anonymous requests, so they fail with a 401 before RBAC is consulted.

**The kubelet's two ports.** The secure port runs the authenticator on each
request, then asks the API server for a decision through the webhook. The
read-only port has no authentication. Its `readOnlyPort` setting defaults to
`0`, which turns it off.

**Authorization caching.** The kubelet caches each webhook decision for the
configured time. The defaults in its configuration reference are 5 minutes for
an allow and 30 seconds for a denial. That cache is why the lab waits before
it probes after each RBAC change.

**etcd's client port.** With `--client-cert-auth=true`, etcd completes the TLS
handshake only when the client presents a certificate signed by its trusted
CA. A client without one gets the `certificate required` alert, which the lab
saw.

**How kube-bench reads a node.** Run with `hostPID`, it lists each
control-plane process and reads its command-line flags, which is how it learns
the API server's settings. It reads the kubelet and etcd config files through
the `hostPath` mounts. The benchmark decides which checks apply. The version
map decides which benchmark that is when none is named, and the map in v0.16.0
stops at 1.34. kube-bench's `cfg` directory also carries managed-service
benchmarks such as `eks` and `gke`, which apply to a managed control plane
where the flags are not yours to set.

**Keyless signatures.** A keyless signature ties a binary to an identity and
an issuer, not to a key you hold. The certificate in the `.cert` file names
the identity that signed, and cosign checks that name against the one you
pass. Checking the identity is what makes a keyless check meaningful.

## Production notes

- A managed control plane has no flags you can set. Read the provider's
  settings, run the managed benchmark profile, and read the provider's upgrade
  notes.
  [10.01](../10-cloud-and-managed-kubernetes/01-managed-kubernetes-model.md)
  explains what the provider runs for you.
- etcd in production is a high-availability and backup problem as well as a
  TLS one.
  [11.08](../11-advanced-production-patterns/08-ha-control-plane-and-etcd.md)
  covers that side.
- Every namespace above `restricted` needs an entry in the guide's exceptions
  registry, with its reason, its chapter and an expiry date within 12 months.
  The `p05-kube-bench` namespace is labelled `privileged`, so it needs one.
- Signed images and provenance are [05.03](03-supply-chain.md) here and
  [15.03](../15-day-to-day-production-ops/03-image-signing-and-provenance.md) in
  production.

## Quick Reference

The secure forms only. Each line is a setting from the sections above.

```sh
# API server: no anonymous requests, no profiling endpoint, RBAC after Node
kube-apiserver --anonymous-auth=false --profiling=false --authorization-mode=Node,RBAC
```

```yaml
# KubeletConfiguration: no read-only port, no anonymous requests, webhook authorization
readOnlyPort: 0
authentication:
  anonymous:
    enabled: false
authorization:
  mode: Webhook
```

```yaml
# etcd: a client must present a certificate, and so must a peer
- --client-cert-auth=true
- --peer-client-cert-auth=true
```

```yaml
# A monitoring token: the kubelet's stats endpoint and nothing else
rules:
  - apiGroups: [""]
    resources: ["nodes/stats"]
    verbs: ["get"]
```

```sh
# The benchmark is named, so the totals mean what they say
kube-bench run --benchmark cis-1.12
```

## Test your understanding

1. **An anonymous request to `/api/v1/pods` returns 403 on this cluster. What
   single change would turn that into a 200, and why does the 403 not already
   protect the cluster against it?**
   <details><summary>Show answer</summary>

   A ClusterRoleBinding that grants `view` to the group
   `system:unauthenticated`. The request passes the authenticator as
   `system:anonymous`, so RBAC is the only gate, and RBAC refuses it only
   because no such binding exists. One permissive binding removes the gate,
   which is why `--anonymous-auth=false` is a second, independent control.

   </details>

2. **A kubelet grant was applied, and a probe made straight after it still
   returned 403. Why, and what does the lab's 35-second wait do?**
   <details><summary>Show answer</summary>

   The kubelet caches a denial for 30 seconds, so the probe read the old
   decision. Nothing about the RBAC object was wrong. The wait lets the cached
   denial expire before the probe runs.

   </details>

3. **kube-bench fails check `1.2.15` on this node. What is the fix, and what
   does the fix leave open?**
   <details><summary>Show answer</summary>

   Set `--profiling=false` on the API server, the controller manager and the
   scheduler. The check reads an absent flag as profiling on. The fix does not
   touch the kubelet or etcd settings, which the same benchmark checks
   separately. On this node they already pass, but a rebuilt node can fail
   them.

   </details>

4. **Why does the kube-bench Job drop every capability and then add
   `DAC_READ_SEARCH` back?**
   <details><summary>Show answer</summary>

   The Job runs as root, but reading a file whose permission bits deny the
   reader is a separate right. Dropping every capability removed that right,
   and the first run failed with `permission denied`. `DAC_READ_SEARCH` gives
   back the read access and nothing more. The Job still cannot write to the
   node.

   </details>

5. **The `p05-kube-bench` namespace is labelled `privileged`. What makes that
   acceptable here, and what does it still require?**
   <details><summary>Show answer</summary>

   The job needs `hostPID` and `hostPath` to read the node, which the baseline
   forbids, and the lab creates the namespace and deletes it when it finishes.
   It still needs an entry in the exceptions registry with its reason, this
   chapter, and an expiry date within 12 months. A `privileged` namespace with
   no entry is a finding, not a lab.

   </details>

## Further reading

- Kubernetes:
  [Authenticating](https://kubernetes.io/docs/reference/access-authn-authz/authentication/),
  for the anonymous user, its group and the `--anonymous-auth` default.
- Kubernetes: [Kubelet authentication and
  authorization](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/),
  for the fine-grained mapping, the `nodes/proxy` warning, and the feature
  state.
- Kubernetes: [Kubelet configuration
  reference](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/),
  for the defaults of `readOnlyPort`, anonymous access, authorization and the
  webhook cache times.
- Kubernetes: [kube-apiserver
  reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/),
  for the `--anonymous-auth` default.
- Kubernetes: [Securing a
  cluster](https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/),
  which covers the kubelet, etcd and the Linux node guidance.
- Kubernetes: [Static
  Pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/),
  for the directory the kubelet scans for control-plane manifests.
- Kubernetes: [Verify signed
  artifacts](https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/),
  for the cosign identity, issuer and file names used in section 5.
- Kubernetes: [Install kubectl on
  Linux](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/), for
  the checksum file and the check command.
- Kubernetes: [Upgrading kubeadm
  clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/),
  for the one-minor-version rule. Not run.
- etcd: [Security model](https://etcd.io/docs/v3.5/op-guide/security/), for
  the client certificate flags and the refusal.
- kube-bench:
  [aquasecurity/kube-bench](https://github.com/aquasecurity/kube-bench), for
  the benchmark files and the version map used in v0.16.0.

