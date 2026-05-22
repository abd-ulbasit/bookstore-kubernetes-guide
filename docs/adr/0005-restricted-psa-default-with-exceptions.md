# 0005 — Restricted Pod Security everywhere, two documented privileged exceptions

* **Status:** Accepted
* **Date:** 2026-05-19
* **Deciders:** abd-ulbasit

## Context

Pod Security Admission (PSA) replaced PodSecurityPolicy in
Kubernetes 1.25. It has three policy levels: `privileged` (no
restrictions), `baseline` (no host-namespace access, no `hostPath`,
no privileged escalation), and `restricted` (everything baseline
restricts plus enforced non-root, dropped Linux capabilities, seccomp).

`restricted` is the right default — it closes the most common
container-escape vectors. But certain *legitimate* workloads cannot
run under `restricted`:

* eBPF-based observability and runtime-defense tools (Falco, Cilium
  agent, Tetragon) need `CAP_BPF` + `CAP_PERFMON` + `CAP_SYS_ADMIN`.
* CNI implementations themselves (Calico, Cilium when used as CNI)
  need host-network access to program node-level routing.

The trap is to relax the default cluster-wide *to accommodate the few*.
That's the policy-rot path: every time some new agent shows up, the
default loosens, and after a year the cluster is back to `privileged`.

## Decision

We will enforce **`restricted` PSA** at the cluster default level and
on every Bookstore namespace. Workloads that legitimately require
elevated privileges live in dedicated, **per-component namespaces**
labelled with the minimum level that workload needs, and **only those
namespaces**. The Terraform tree currently documents exactly two such
namespaces:

| Namespace | Level | Why |
|---|---|---|
| `falco` | `privileged` | Falco eBPF needs CAP_BPF + CAP_PERFMON + CAP_SYS_ADMIN. |
| `kube-system` (Cilium agent, `.tf.example` only) | `privileged` | Cilium-as-CNI needs host-network + bpf-fs access. The .tf.example gating is itself a guardrail (see consequences). |

Every privileged namespace must have a banner-comment in its Terraform
explaining why and citing the upstream issue / docs that demand the
elevation.

## Consequences

* **Good:** The default is safe. Operators who add new workloads
  don't have to remember to opt-in to `restricted` — they're already
  in it.
* **Good:** The list of privileged namespaces is auditable from a
  single `grep` (the leak-scan job in
  `.github/workflows/example-trees-check.yml` partially enforces this).
* **Good:** Each elevation is justified at the source, not in an
  outdated wiki.
* **Bad:** Adding a new privileged workload is a deliberate ceremony
  (new namespace + labels + banner comment). This is correct
  friction — privileged workloads *should* be deliberate.
* **Follow-up:** The Cilium agent `.tf.example` (rather than `.tf`) is
  itself an exception: switching CNI on a live cluster is destructive,
  so we ship it as opt-in. Future work might wrap that switch in a
  `var.enable_cilium_cni = false` default-off variable.

## Alternatives considered

* **Cluster-wide `privileged`.** Easiest, worst — every workload
  inherits the elevation. Rejected.
* **`baseline` default.** Closes the common cases but still allows
  privilege escalation. Rejected; if we're going to draw a line, draw
  the right one.
* **Per-pod SecurityContext alone, no PSA.** Enforcement-as-code is
  easier to bypass than enforcement-as-admission. Rejected.

## References

* `full-guide/05-security/02-pod-security.md`
* `full-guide/examples/bookstore-platform/terraform/falco.tf` (banner comment).
* Kubernetes PSA documentation.
