# Bookstore threat model

This file is the living threat model for the Bookstore example in this
directory. Chapter 00.08, Security foundations, teaches how to read it and
how to change it. Part 05 chapter 05.00 reads it too, so keep the headings
stable.

- **Scope:** the four services under `app/` (storefront, catalog, orders,
  payments-worker), the manifests under `raw-manifests/`, and the cluster
  the guide builds on.
- **Out of scope for now:** cloud accounts, managed control planes and
  identity providers. The cloud parts (Part 10 onward) add their own rows.
- **Last reviewed:** 2026-10-31.

## How to change this file

- A change to a workload, a namespace label above `restricted`, or a
  suppressed scanner finding changes this file in the same pull request.
- Every threat keeps its ID. To retire a threat, mark it `retired` and give
  the reason. Do not delete the row.
- Each control names the field, RBAC rule or chapter that enforces it, and
  its status says whether the baseline, the cluster or a later chapter
  provides it. A status of `open` means no control exists yet.

## Assets

| ID | Asset | Where it lives |
|----|-------|----------------|
| A1 | Order and customer records | Postgres, `raw-manifests/20-postgres-statefulset.yaml` |
| A2 | Database and broker credentials | Secret, `raw-manifests/16-db-credentials.yaml` |
| A3 | Credentials the payments worker uses to reach its provider | A Secret, not the image |
| A4 | Cluster credentials: kubeconfigs and ServiceAccount tokens | Workstations, CI runners, Pods that mount a token |
| A5 | Declared state: the manifests in Git | This repository |
| A6 | Container images and their digests | The registry, then each node after a pull |
| A7 | Storefront availability | Gateway and storefront Pods |
| A8 | Audit records of API requests | API server audit log, `cluster/audit-policy.yaml` |

## Actors

| ID | Actor | Can reach |
|----|-------|-----------|
| R1 | Anonymous internet client | The Gateway and the public routes behind it |
| R2 | Operator holding a kubeconfig | The API server, and whatever its RBAC allows |
| R3 | CI pipeline | The API server with its own credentials, the registry and Git |
| R4 | Code running in a Pod after a dependency is compromised | The Pod's filesystem, the network it can reach, and the API if a token is mounted |
| R5 | Someone with root on a worker node | The kubelet, the runtime socket and every Pod on that node |
| R6 | Supplier of an upstream image or dependency | Any image pulled into the cluster |

## Trust boundaries

| ID | Boundary | Crossed by |
|----|----------|------------|
| TB1 | Internet to the Gateway | R1 |
| TB2 | Gateway to a Pod in the `bookstore` namespace | R1, after TB1 |
| TB3 | Pod to the API server | R4 with a mounted token, R2 |
| TB4 | Container to the node kernel | R4 |
| TB5 | API server to the kubelet | R2 for exec and logs, R5 |
| TB6 | API server to etcd | R5 on a control-plane node |
| TB7 | CI and workstations to the cluster | R2, R3 |
| TB8 | Registry to the node | R6 |
| TB9 | Namespace to namespace | R4 |
| TB10 | Argo CD on the hub to the API server of a member, with the token the hub holds for it | A compromised hub, or anyone who reads the hub's cluster Secrets |

## Entry points

| ID | Entry point | Baseline or control |
|----|-------------|---------------------|
| EP1 | Gateway HTTP and HTTPS, `raw-manifests/50-ingress.yaml` and `51-gateway.yaml` | Edge controls: open, see D2 |
| EP2 | kube-apiserver, port 6443 | Authentication, RBAC, admission |
| EP3 | Kubelet API, port 10250 | Anonymous auth off, webhook authorization (E5, I3) |
| EP4 | Container runtime socket, only when a Pod mounts it | Refused by `restricted` (E4) |
| EP5 | Image pulls from the registry | Digest pins (T2) |
| EP6 | Git push and CI apply | Review and diff before apply (T3) |
| EP7 | kubeconfig on a workstation or CI runner | Short-lived credentials (S2) |
| EP8 | Pod-to-Pod network, until `raw-manifests/60-networkpolicy.yaml` applies | Default deny (S3) |
| EP9 | The webhook Service, which the API server calls over TLS for every matching write | A ClusterIP Service only, a `caBundle` that pins the serving CA, and a NetworkPolicy for the webhook's namespace (02.06) |

## STRIDE pass

Each row names a threat, the control that answers it, and its status.
Status values: `baseline` (a field that admission or the static gate
enforces), `review` (a baseline field that neither enforces, so a reviewer
checks it), `cluster` (a cluster-level control), `open` (no control in the
guide yet). Part 00 ch.08 names the enforcer of each baseline field.

### Spoofing

| ID | Threat | Control | Status | Explained in |
|----|--------|---------|--------|--------------|
| S1 | A Pod calls the API as another identity | Its own ServiceAccount, with `automountServiceAccountToken: false` | review | 01.01, `#baseline-service-account` |
| S2 | A stolen kubeconfig acts as an operator | Authentication at the API server, RBAC, short-lived credentials | cluster | 05.01 |
| S3 | A Pod impersonates another Pod on the network | Default-deny NetworkPolicy, then explicit allows | cluster | 02.06 |
| S7 | A workload logs in to Vault as another workload's identity | Vault Kubernetes auth role bound to one ServiceAccount name and one namespace, with a read-only policy | later | 11.05, section 4 |
| S6 | A Pod copies a label such as `app: storefront` and is trusted as that workload | Mesh authorization by SPIFFE identity from its ServiceAccount, with default-deny at the waypoint | later | 11.04 (`40-authz-default-deny.yaml`); workload X.509 identity 05.01 |
| S8 | The hub holds a token for every member, so one leaked token reaches that member's API | One ServiceAccount per member in its own namespace, a Role in the workload namespace only, and a token that lasts 24 hours | review | 11.06, Fleet credentials |
| S9 | A Pod logs in to the broker with the stock `guest` account, or with a login it was never given | No `guest` account: the broker's only user is the generated login in `db-credentials`, and orders and payments-worker read the URL by `secretKeyRef` | review | 03.02, `#the-broker-login` |

### Tampering

| ID | Threat | Control | Status | Explained in |
|----|--------|---------|--------|--------------|
| T1 | A process rewrites its image or drops a binary | `readOnlyRootFilesystem: true`, with an `emptyDir` at `/tmp` | baseline | 01.01, `#baseline-read-only-root` |
| T2 | An image is replaced under the same tag | Digest pins for third-party images; signing and provenance | review (pins), later (signing) | 01.01, `#baseline-image-digest`; 05.03 |
| T3 | A spec changes outside review | Apply reviewed files from Git, `kubectl diff`, GitOps | cluster | 00.06; 07.04 |
| T4 | Objects in etcd change without the API server | Only the API server holds etcd credentials | cluster | 00.04; [05.06](../../05-security/06-control-plane-and-node-hardening.md) |
| T5 | A webhook configuration is edited, or its backend fails, so a check stops running | RBAC on the webhook configurations, reviewed files applied from Git, a per-webhook `failurePolicy`, and a selector scoped to the app namespace | cluster | 11.01, `#failure-modes-as-attack-surface` |

### Repudiation

| ID | Threat | Control | Status | Explained in |
|----|--------|---------|--------|--------------|
| RP1 | An apply leaves no record of who made it | API server audit policy, `cluster/audit-policy.yaml` | open until 05.08 | [05.08](../../05-security/08-audit-detection-and-incident-response.md) |

### Information disclosure

| ID | Threat | Control | Status | Explained in |
|----|--------|---------|--------|--------------|
| I1 | Secrets are read from etcd, which skips RBAC | Encryption at rest, `cluster/encryption-config.yaml`; etcd reached only by the API server | cluster | 03.02; 05.04 |
| I2 | A broad RBAC grant reads Secrets | One ServiceAccount and one narrow Role per workload | cluster | 05.01 |
| I3 | A caller reads Pod specs or runs commands through the kubelet | Anonymous kubelet auth off, webhook authorization | cluster | [05.06](../../05-security/06-control-plane-and-node-hardening.md) |
| I4 | Application code reads a mounted ServiceAccount token | `automountServiceAccountToken: false` | review | 01.01, `#baseline-service-account` |
| I8 | The database process holds the broker login, so a compromised database container reaches the queue | Postgres takes its three keys one by one with `secretKeyRef`, not `envFrom` | review | 03.02, `#the-broker-login` |
| I6 | A static database password, read from Git or a Secret, stays valid until someone rotates it | Dynamic credentials: Vault mints a lease-bound Postgres role per read, through a `VaultDynamicSecret` generator | later | 11.05, section 5 |
| I5 | A Pod on the network reads the traffic of an edge that policy allows | Strict mTLS between meshed workloads, so plaintext never crosses the pod network | later | 11.04 (`10-peerauthentication-strict-mtls.yaml`); NetworkPolicy 02.06 still applies underneath |
| I7 | Clear etcd traffic: a host on the path reads Secrets off etcd traffic, or a client talks to etcd with no certificate | Peer and client TLS, with client certificates required (`--client-cert-auth`, `--peer-client-cert-auth`); port 2379 reached only from control-plane nodes | cluster | 11.08, `#threats-and-controls`; 05.04; [05.06](../../05-security/06-control-plane-and-node-hardening.md) |

### Denial of service

| ID | Threat | Control | Status | Explained in |
|----|--------|---------|--------|--------------|
| D1 | One Pod exhausts node memory and evicts its neighbours | Requests and a memory limit on every container | review | 01.01, `#baseline-resources`; 01.03 |
| D2 | A flood of traffic overwhelms the storefront | None in the baseline | open | none yet |
| D3 | One client starves the apiserver: a hot-looping controller, a `--kube-api-qps` set far too high, or a bulk `LIST` from one identity | A bounded PriorityLevel per identity with its own fair queue; `429` past the queue; write access to FlowSchema limited to cluster administrators | cluster | 11.03 |

### Elevation of privilege

| ID | Threat | Control | Status | Explained in |
|----|--------|---------|--------|--------------|
| E1 | A process runs as root and reaches host resources | `runAsNonRoot: true`, UID 65532 in the catalog image | baseline | 01.01, `#baseline-run-as` |
| E2 | A setuid binary gains privileges | `allowPrivilegeEscalation: false` | baseline | 01.01, `#baseline-privilege-escalation` |
| E3 | A capability or syscall reaches the kernel | `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault` | baseline | 01.01, `#baseline-capabilities`, `#baseline-seccomp` |
| E4 | A Pod asks for host namespaces, privileged mode or a `hostPath` | Pod Security Admission at `restricted` on the namespace | baseline | 01.01, `#baseline-namespace`; 05.02 |
| E5 | An unpatched runtime lets a container escape, as with CVE-2024-21626 | A patched containerd and runc on every node | cluster | [05.06](../../05-security/06-control-plane-and-node-hardening.md) |
| E6 | An RBAC grant lets a workload create a privileged Pod | Narrow RBAC, and `restricted` on the namespace | cluster | 05.01; 05.02 |
| E7 | A mutation adds privilege the Pod did not ask for | A mutating webhook sets only restrictive fields, and only when absent; a validating check runs after it | review | 11.01, `#mental-model` |
| E9 | The chaos daemon runs privileged on every node, so a compromised daemon reaches the node. The controller can also delete Pods outside the workload under test | The daemon alone is privileged, in its own namespace enforced at `privileged` with audit and warn at `restricted`, and registered; the controller is namespace-scoped (`clusterScoped: false`); optional features are off | review | 11.07, `#threats-and-controls` |
| E10 | The provider's ServiceAccount holds more rights than the recipe needs, so a compromised provider, or a bad change to the recipe, reaches objects in every namespace | RBAC named to the kinds the recipe writes; the `bind` verb on the built-in `view` ClusterRole only; no `cluster-admin` binding; a requester Role limited to the request namespace | cluster | 11.10, `#threats-and-controls` |
| E8 | A controller's own RBAC grant lets a compromised operator act beyond its reconcile loop | Markers grant only the verbs the reconcile path calls, no delete and no wildcard; the generated role is read before it ships | review | 11.02, RBAC markers |

## Attacker goals

The rows follow the tactics of the MITRE ATT&CK for Containers matrix. The
guide uses it as a map of goals, not as a checklist of techniques.

| Goal (tactic) | How it could show up in the Bookstore | Threats |
|---------------|----------------------------------------|---------|
| Initial Access | A route exposed at the Gateway, or a vulnerable dependency in an image | EP1, R6, T2 |
| Execution | A new workload or a shell started in a Pod (deploy-container, T1610) | T1, E3 |
| Persistence | A dropped binary, or a changed spec that survives a restart | T1, T3 |
| Privilege Escalation | Root in a container, a setuid binary, a capability, a privileged Pod, or escape to the host (escape-to-host, T1611) | E1 to E5 |
| Stealth | A change that leaves no audit record or avoids review | RP1, T3 |
| Defense Impairment | A policy, gate or NetworkPolicy switched off | T3, S3, E4 |
| Credential Access | A Secret, a mounted token or etcd read directly | I1, I2, I4, I6, S2, S7, S8 |
| Discovery | Listing Pods or reaching the kubelet from inside the cluster | I3, S1 |
| Lateral Movement | Pod to Pod, or namespace to namespace | S3, TB9 |
| Impact | Corrupted or deleted records, exhausted resources | A1, D1, D2 |

## Insecure examples and exceptions

- **Insecure on purpose.** None in this file. The guide's rule: insecure
  examples appear only in Part 05 labs and the capstone overlay, and never
  in the `bookstore` or `default` namespace. The gates enforce it.
- **Exceptions.** A namespace above `restricted`, or a suppressed scanner
  finding, needs an entry in the registry before it merges. The registry is
  `security/namespace-exceptions.yaml` for namespaces and `.trivyignore.yaml`
  for scanner findings. Each entry records what is excepted, the reason with an
  upstream citation, the chapter that explains it, and an expiry no more than 12
  months out. `make gates-registry` fails an entry whose expiry has passed.
- **Not an exception.** `.github/scripts/gates/not-evaluated.allow` lists
  manifests that no scanner could judge. It records gate blind spots. It
  does not grant policy exceptions.

## Open items

- D2: no edge rate limiting in the baseline.
- RP1: audit records wait for 05.08.
- E9: the chart exposes no container-level security fields for the Chaos Mesh controller and dashboard in 2.8.7, so `allowPrivilegeEscalation`, dropped capabilities and `runAsNonRoot` are not set (11.07).
