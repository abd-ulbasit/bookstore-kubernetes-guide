# 14.02 — EKS cluster lifecycle

> The 14-month standard-support window, the 12-month extended-support
> window with its **$0.50/cluster-hour** (~$365/month surcharge), and the
> three-plane upgrade dance (control plane → managed addons → node
> pools) every team running EKS must rehearse before a version deadline
> bites; the in-place version bump runbook against the Bookstore
> Platform tree; deprecated-API hunting with `kubent`; blue-green
> clusters for the multi-version-skip case.

**Estimated time:** ~30 min read · ~90 min hands-on
**Prerequisites:** [Part 14 ch.01](./01-terraform-state-in-production.md) — remote state required before a version bump · [Part 13 ch.02](../08-day-2-operations/01-cluster-lifecycle.md) — kind cluster upgrade dance you'll now adapt for EKS · [Part 10 ch.02](../10-cloud-and-managed-kubernetes/02-provisioning-and-iac.md) — the bookstore EKS module you'll upgrade

**You'll know after this:** • understand the 14-month standard vs 12-month extended-support windows and the $0.50/cluster-hour surcharge · • execute the three-plane upgrade dance (control plane → managed addons → node pools) in the correct order · • run `kubent` to hunt deprecated APIs before the upgrade · • choose between in-place version bumps and blue-green clusters for multi-version skips · • rehearse the EKS upgrade against the Bookstore Platform tree before a version deadline

<!-- tags: eks, terraform, cloud, day-2, platform-engineering -->

## Why this exists

The bookstore-platform tree at
[`../examples/bookstore-platform/terraform/`](../examples/bookstore-platform/terraform/)
declares `kubernetes_version = "1.37"` in `variables.tf`. That number
isn't a fixed label — it's a deadline. AWS marks each Kubernetes minor
version with two date stamps:

1. **End of standard support** — when AWS stops releasing free patches.
   For 1.37, this is **2027-12-01** (14 months from its EKS release on
   2026-10-01). Up to this date, the EKS control-plane fee is
   $0.10/cluster-hour (~$73/month) — the same rate as every other
   supported version.
2. **End of extended support** — 12 months after standard ends. For
   1.37, this is **2028-12-01**. During extended support, AWS charges
   an **additional $0.50/cluster-hour** on top of the base rate —
   ~$365/month surcharge per cluster (730h × $0.50), on top of the
   normal ~$73. A team running 10 clusters on an end-of-extended
   version pays an extra ~$3,650/month for the privilege.

Past the end of extended support, AWS **auto-upgrades the cluster**
without your consent. The auto-upgrade can happen during any
maintenance window AWS picks; for a team that hasn't tested 1.37→1.38
in staging, this is the production incident. Every team running EKS
hits this deadline, every cluster: once every 14 months to stay out of
extended-support fees, and no later than 26 months (14 standard + 12
extended), when EKS upgrades the control plane for you.

The version bump itself isn't dangerous. The shape of it is:

- **Control plane upgrade** — Terraform changes one variable; AWS does
  the work; cluster stays UP throughout (the API server rolls one
  replica at a time behind a load balancer).
- **Addons upgrade** — EKS does not update an addon after a cluster
  upgrade; Terraform does. The tree looks up each EKS-managed addon
  (vpc-cni, kube-proxy, CoreDNS, EBS-CSI) with the
  `aws_eks_addon_version` data source for the cluster's version, so the
  same apply moves kube-proxy (it has a build per minor) and any other
  addon whose default build for the new minor differs.
- **Node pool upgrade** — Managed node groups roll new EC2 instances
  with the AMI for the new K8s version; Karpenter-provisioned nodes
  auto-rotate via the NodePool's `expireAfter` setting.

What makes this a chapter rather than a bullet point: the **order
matters**, the **version-skew tolerance** matters, the **deprecated-API
hunt** matters, and the **what-if-we-skipped-a-version** decision
matters. This chapter is the runbook against the bookstore-platform
tree.

[Part 08 ch.01](../08-day-2-operations/01-cluster-lifecycle.md)
introduced cluster lifecycle for the self-managed case (kubeadm-style
upgrades); [Part 10 ch.01](../10-cloud-and-managed-kubernetes/01-managed-kubernetes-model.md)
drew the managed-vs-self-managed line. This chapter is the EKS-specific
production-grade upgrade story those two pointed at.

> **In production:** A staging EKS cluster running one version ahead of
> production is the cheapest insurance you can buy. At $73/month for
> the control plane plus minimal node-hours, a staging cluster running
> 1.37 while production runs 1.36 catches the deprecated-API breakage,
> the addon-version surprises, and the upgrade-order mistakes — all
> before the prod deadline forces your hand. A team that skips staging
> learns the lessons in production.

## Mental model

**Three planes to upgrade in strict order — control plane, then EKS-
managed addons, then nodes — with the Kubernetes version-skew policy
governing what's tolerated mid-flight. Skip a step or reverse the
order and the cluster either fails the upgrade or runs in an
unsupported skew configuration.**

The three planes:

- **Plane 1 — the EKS control plane.** kube-apiserver, kube-scheduler,
  kube-controller-manager, etcd. Operated by AWS, but the *version*
  is your decision (set via `kubernetes_version` in the EKS module).
  Upgrade first because nodes can run versions older than the control
  plane (per the Kubernetes version-skew policy), but **never newer**.
- **Plane 2 — EKS-managed addons.** vpc-cni, kube-proxy, CoreDNS,
  EBS-CSI. Each addon has its own compatibility window with K8s
  minor versions; an addon version that worked on 1.36 may not exist
  for 1.37. The tree sets each `addon_version` from an
  `aws_eks_addon_version` lookup (the EKS module runs the one for
  vpc-cni), which returns EKS's default build for the current K8s
  minor; this is almost always right.
- **Plane 3 — nodes.** Managed node groups (the small "system" pool
  in [`../examples/bookstore-platform/terraform/eks.tf`](../examples/bookstore-platform/terraform/eks.tf)
  with its `t3.medium` instances) plus Karpenter-provisioned nodes
  (from
  [`../examples/bookstore-platform/terraform/karpenter-pools.tf`](../examples/bookstore-platform/terraform/karpenter-pools.tf)).
  Managed node groups update their AMI when Terraform re-applies after
  the control plane bump; Karpenter nodes auto-rotate as each node's
  `expireAfter` window (720h ≈ 30 days by default) elapses.

The upgrade order is non-negotiable:

```text
1. control plane  →  2. addons  →  3. managed nodes  →  4. Karpenter nodes
   (terraform           (terraform        (terraform           (organic,
    plan/apply           apply re-          apply triggers      via expireAfter,
    bumps version)       fetches            rolling AMI         OR forced via
                         compatible         bump)               kubectl delete)
                         addon ver)
```

Reverse this and the symptoms vary. Bump nodes first and the new
kubelet may emit calls the old apiserver doesn't understand (the API
that was added in N+1 isn't yet served by N). Bump addons first and
some addon versions require a control-plane API that doesn't exist
yet (e.g., a CRD version). The order minimizes the time anything is
in an unsupported skew.

**Kubernetes version-skew policy** (upstream, as of K8s 1.28+):
kubelet can be up to **3 minor versions older** than kube-apiserver
(N-3). kube-proxy must not be newer than kube-apiserver, may be up to
3 minors older than it, and may be up to 3 minors older or newer than
the kubelet it runs alongside. kube-controller-manager and
kube-scheduler must not be newer than kube-apiserver and may be up to
1 minor older. kubectl stays within ±1 of kube-apiserver. The table
below reflects this current policy; EKS enforces it at node-group
update time.

**Standard support vs extended support** — the cost math (730 hours/month):

| Phase | Duration | Cluster fee | Surcharge | Total |
|---|---|---|---|---|
| Standard support | 14 months from EKS release | $0.10/hr × 730h | $0 | ~$73/month |
| Extended support | 12 months after standard ends | $0.10/hr × 730h | $0.50/hr × 730h | ~$438/month |
| End of extended | — | AWS auto-upgrades | — | — |

For a single dev cluster, an extra ~$365/month surcharge is annoying.
For a fleet of 50 clusters running an end-of-extended version for 6
months, it's over $109,500 — real budget money the FinOps team will
want explained.

**Blue-green clusters for major skips.** Kubernetes only supports
N → N+1 upgrades. If your cluster is on 1.33 (already in extended
support) and the newest standard-support version is 1.37, you cannot
upgrade in place — you must walk through 1.33 → 1.34 → 1.35 → 1.36 →
1.37, four separate apply cycles. The alternative: stand up a fresh
1.37 cluster (blue-green), migrate workloads via Argo CD's
multi-cluster ApplicationSet
([Part 11 ch.06](../11-advanced-production-patterns/06-multi-cluster-and-fleet.md)),
flip DNS, retire the old cluster. Blue-green dodges the version-skip
restriction at the cost of running two clusters during the migration.

The trap to keep in view: **the deprecated-API removal trap**. A
Kubernetes minor can remove APIs that were deprecated several minors
earlier. 1.32 stopped serving `flowcontrol.apiserver.k8s.io/v1beta3`;
1.31 replaced the alpha `resource.k8s.io/v1alpha2` with an
incompatible v1alpha3. The upstream deprecation guide lists no GA or
beta removals after 1.32, but alpha APIs still disappear: 1.36 removed
`scheduling.k8s.io/v1alpha1` (Workload) and the v1alpha1
`WebhookAdmissionConfiguration` admission config, and 1.37 removed
`scheduling.k8s.io/v1alpha2` (Workload, PodGroup).
If a CRD, a Deployment, or a Helm chart in your cluster still
references a removed API, the upgrade succeeds on the control plane
but every subsequent `kubectl apply` of that object fails. `kubent`
(kube-no-trouble) is the tool that catches this BEFORE the bump.

## Diagrams

### Diagram A — the three-plane upgrade order (Mermaid)

```mermaid
flowchart TB
    pre["Pre-flight<br/>aws eks describe-cluster-versions<br/>kubent (deprecated-API audit)<br/>staging cluster proven on N+1"]
    cp["Plane 1 — Control plane<br/>terraform apply<br/>kubernetes_version: N -> N+1<br/>~15 min, cluster stays UP"]
    ad["Plane 2 — EKS-managed addons<br/>aws_eks_addon_version re-resolves<br/>each default build: kube-proxy<br/>always bumps; vpc-cni, CoreDNS,<br/>EBS-CSI only if EKS's default<br/>build changed"]
    mn["Plane 3a — Managed node groups<br/>terraform apply<br/>rolling AMI replacement<br/>respects PodDisruptionBudgets"]
    kn["Plane 3b — Karpenter nodes<br/>organic rotation via<br/>NodePool.spec.disruption.expireAfter<br/>720h = ~monthly"]
    post["Post-flight<br/>terraform plan (zero-diff)<br/>kubectl get nodes (all on new ver)<br/>SLO dashboards green"]

    pre --> cp --> ad --> mn --> kn --> post

    note1["Order is strict.<br/>Reverse it and you risk<br/>nodes at version > control plane<br/>(unsupported skew)."]
    cp -.-> note1

    note2["expireAfter can be forced:<br/>kubectl delete nodes<br/>-l karpenter.sh/nodepool=general<br/>but lets PDBs guard pods."]
    kn -.-> note2
```

### Diagram B — version-skew tolerance matrix (ASCII)

```text
COMPONENT           SKEW VS APISERVER         WHO ENFORCES        EXAMPLE (apiserver=1.37)
──────────────────  ────────────────────────  ──────────────────  ───────────────────────────────
kube-apiserver      n/a (the reference)       —                   1.37 itself
kube-controller-mgr same minor as apiserver   EKS (managed)       1.37
kube-scheduler      same minor as apiserver   EKS (managed)       1.37
kubelet (nodes)     up to 3 minors BEHIND     kubelet/EKS         1.34-1.37 OK, 1.33 unsupported
kube-proxy          up to 3 minors BEHIND     EKS addon mgr       1.34-1.37; kubelet +/-3 minors
kubectl (client)    +/- 1 minor               you                 1.36-1.38
CRDs (your code)    use deprecated-API audit  you (kubent)        no objects on removed APIs
──────────────────  ────────────────────────  ──────────────────  ───────────────────────────────
EKS practical:
  - Control plane upgrade can run for ~14 days before nodes MUST follow.
  - Beyond 3 minors behind, kubelet refuses to register; new nodes won't
    join until you bump the AMI.
  - The "auto-upgrade at end of extended support" is AWS's safety net,
    not yours. Plan for explicit upgrades.
```

## Hands-on with the Bookstore Platform

### 0. Prerequisites

- The bookstore-platform tree applied; cluster reachable via `kubectl`.
- State backend on S3 (per
  [ch.01](01-terraform-state-in-production.md)) — the upgrade writes
  to state, and a single-laptop apply is the wrong place for that.
- `kubectl` within ±1 minor of the current cluster version.
- `kubent` installed (`brew install doitintl/k8s-tools/kubent` on
  macOS, or download a binary from
  <https://github.com/doitintl/kube-no-trouble/releases>).

The scenario below walks through bumping the bookstore-platform tree
from K8s 1.36 to 1.37, the tree's default (EKS has offered 1.37 in
standard support since 2026-10-01). To rehearse it on a fresh cluster,
apply the tree with `-var kubernetes_version=1.36` first. A cluster
still on 1.35 must go to 1.36 before it can go to 1.37: EKS upgrades
one minor at a time, so run this runbook twice (1.35 → 1.36, then
1.36 → 1.37).

### 1. Read the AWS-side support calendar

```bash
aws eks describe-cluster-versions \
  --query "clusterVersions[].{ver:clusterVersion,status:status,standardEnd:endOfStandardSupportDate,extendedEnd:endOfExtendedSupportDate}" \
  --output table
```

Sample output (the calendar on 2026-10-29, condensed: the CLI prints
full timestamps and sorts the columns by name):

```text
--------------------------------------------------------
|               DescribeClusterVersions                |
+-------+------------------+-------------+-------------+
|  ver  |      status      | standardEnd | extendedEnd |
+-------+------------------+-------------+-------------+
| 1.37  | STANDARD_SUPPORT | 2027-12-01  | 2028-12-01  |
| 1.36  | STANDARD_SUPPORT | 2027-08-02  | 2028-08-02  |
| 1.35  | STANDARD_SUPPORT | 2027-03-27  | 2028-03-27  |
| 1.34  | STANDARD_SUPPORT | 2026-12-02  | 2027-12-02  |
| 1.33  | EXTENDED_SUPPORT | 2026-07-29  | 2027-07-29  |
| 1.32  | EXTENDED_SUPPORT | 2026-03-23  | 2027-03-23  |
| 1.31  | EXTENDED_SUPPORT | 2025-11-26  | 2026-11-26  |
+-------+------------------+-------------+-------------+
```

Confirm:

- Target version (1.37) is `STANDARD_SUPPORT` (not yet in extended
  support).
- Source version (1.36) has at least 60 days of standard support
  remaining (it runs to 2027-08-02, so you have time to roll back if
  needed).

### 2. Check current cluster + upgrade history

```bash
CLUSTER="$(terraform output -raw cluster_name)"
REGION="$(terraform output -raw region)"

aws eks describe-cluster \
  --name "$CLUSTER" \
  --region "$REGION" \
  --query 'cluster.{version:version,status:status,platformVer:platformVersion}'

aws eks list-updates \
  --name "$CLUSTER" \
  --region "$REGION" \
  --query 'updateIds[*]'

# For each updateId, drill in:
aws eks describe-update --name "$CLUSTER" --region "$REGION" --update-id <ID>
```

Confirm:

- Status is `ACTIVE` (no in-flight update).
- No previous failed `VersionUpdate` lurking.

### 3. Hunt for deprecated APIs with `kubent`

```bash
kubent --cluster --target-version 1.37
```

`kubent` walks every resource in the cluster, every Helm release's
manifests, and any local YAML you point it at, and flags anything
using an API removed in the target version. Output:

```text
__________________________________________________________________________________________
>>> Deprecated APIs removed in 1.37 <<<
------------------------------------------------------------------------------------------
KIND              NAMESPACE     NAME                       API_VERSION                REPLACE_WITH
------------------------------------------------------------------------------------------
(none found)
__________________________________________________________________________________________
```

If `kubent` finds anything, fix it (replace the manifest, bump the
Helm chart) **before** Step 4. A cluster upgraded with deprecated APIs
in flight upgrades fine — but the next `kubectl apply` of any object
on a removed API fails, often in an unrelated CI job hours later.

A clean `kubent` run is necessary, not sufficient. Its newest
versioned rule file is `deprecated-1-32.rego`, so it checks nothing
removed after 1.32. That gap is small for GA and beta APIs (the
upstream deprecation guide lists no removals after 1.32), but it does
not cover the 1.37 changes AWS and the upstream changelog mark as
action required. Check these by hand before the bump:

- **`scheduling.k8s.io/v1alpha2` objects.** 1.37 drops the API, and
  upstream says to delete every v1alpha2 Workload and PodGroup before
  upgrading from 1.36. EKS does not support alpha features, so expect
  to find none.
- **SELinux mounts.** `SELinuxMount` is on by default in 1.37. On
  SELinux-enabled nodes, a Pod can stick in `ContainerCreating` when
  it shares a volume (from a CSI driver with `seLinuxMount: true`)
  with a Pod that uses a different SELinux label,
  `seLinuxChangePolicy` or privilege level. Nodes without SELinux are
  not affected.
- **Custom AMIs and extra kubelet arguments.** The 1.37 kubelet will
  not start with a deprecated cAdvisor flag set (except
  `--housekeeping-interval`), and `eventRecordQPS: 0` now means no
  limit (AWS says to set `5` to keep the old one). EKS-optimized AMIs
  set neither.
- **Dashboards and alerts.** The kubelet no longer exports
  `container_cpu_load_average_10s`, `container_cpu_load_d_average_10s`
  or `container_tasks_state`.
- **Node-log access.** The 1.37 kubelet logs its full configuration at
  startup, so restrict who can read node logs.

The full list is the Kubernetes 1.37 section of AWS's "Kubernetes
versions standard support" release notes, linked from the versions
page under Further reading.

### 4. Edit the version variable

```bash
cd examples/bookstore-platform/terraform
```

Open `variables.tf` and bump:

```hcl
variable "kubernetes_version" {
  description = "EKS Kubernetes minor version. ..."
  type        = string
  default     = "1.37"  # bumped from "1.36"
}
```

Commit the change (one-line diff) and push for review. Treat the
version bump as the code change it is — a PR, a reviewer, a CI
plan check. (If you are rehearsing on a cluster you applied with
`-var kubernetes_version=1.36`, the default already reads `"1.37"`;
drop the `-var` in the next step instead.)

### 5. Plan + review

```bash
terraform plan -out=upgrade-1.37.tfplan
```

The plan should show:

```text
Terraform will perform the following actions:

  # module.eks.aws_eks_cluster.this[0] will be updated in-place
  ~ resource "aws_eks_cluster" "this" {
        id      = "bookstore-platform"
      ~ version = "1.36" -> "1.37"
        # (many unchanged attributes)
    }

  # module.eks.time_sleep.this[0] must be replaced
-/+ resource "time_sleep" "this" {
      ~ triggers = { # forces replacement
          ~ "cluster_version" = "1.36" -> "1.37"
            # (4 unchanged elements hidden)
        }
        # (other attributes not shown)
    }

  # aws_eks_addon.kube_proxy will be updated in-place
  ~ resource "aws_eks_addon" "kube_proxy" {
      ~ addon_version = "v1.36.x-eksbuild.N" -> "v1.37.x-eksbuild.N"
        # (many unchanged attributes)
    }

  # module.eks.aws_eks_addon.before_compute["vpc-cni"] will be updated in-place
  ~ resource "aws_eks_addon" "before_compute" {
      ~ addon_version = "v1.x.y-eksbuild.N" -> (known after apply)
        # (many unchanged attributes)
    }

  # aws_eks_addon.coredns and aws_eks_addon.aws_ebs_csi_driver get the
  # same addon_version update as kube_proxy only if EKS's default build
  # for 1.37 differs from the one for 1.36.
  # ... and the system node group: ~ version = "1.36" -> "1.37"

Plan: 1 to add, N to change, 1 to destroy.
```

The add-on versions come from `data.aws_eks_addon_version.default` in
`addons.tf`, keyed on `module.eks.cluster_version`, and from the EKS
module's own lookup for vpc-cni. Each asks for EKS's default build for
the new version, so the version bump alone moves every add-on whose
default build changed. kube-proxy always moves, because EKS ships
separate kube-proxy builds for each Kubernetes minor. vpc-cni always
shows an update with `(known after apply)`: the module's lookup reads
the cluster resource that this plan changes, so Terraform defers it to
apply. The apply then sets EKS's default for 1.37, which can be the
build already running (in us-east-1 on 2026-10-29 the vpc-cni default
for both 1.36 and 1.37 was v1.22.4-eksbuild.8). Expect the OIDC
provider's `thumbprint_list` to show `(known after apply)` for the same
reason: the module re-reads the cluster's TLS certificate during apply.

The one replacement is `module.eks.time_sleep.this[0]`, a timer from
the `hashicorp/time` provider. The module uses it to wait
`dataplane_wait_duration` (30 seconds by default) between the control
plane and the node groups, and its `triggers` include the cluster
version, so every version bump re-creates it. It is harmless:
replacing it touches no AWS resource and costs a 30-second wait.

If the plan destroys anything else, **stop and investigate**. Apart
from that timer, a proper version bump is purely in-place changes (the
EKS API supports in-place version upgrades).

### 6. Apply — control plane first

```bash
terraform apply upgrade-1.37.tfplan
```

The control-plane upgrade takes 10-20 minutes. Throughout this
window:

- The cluster API endpoint stays UP. There's a 30-60 second window
  where one apiserver replica is being replaced; `kubectl` retries
  smooth over it.
- Pods keep running. Workloads don't notice the control plane
  rolling.
- Karpenter keeps provisioning. (Karpenter talks to the apiserver
  for NodeClaim CRDs; the apiserver-rolling window may pause it
  briefly, but it resumes.)

Monitor in another terminal:

```bash
watch -n 5 'aws eks describe-cluster \
  --name $CLUSTER --region $REGION \
  --query "cluster.{version:version,status:status,update:status}"'
```

Status moves `ACTIVE` → `UPDATING` → `ACTIVE`. Version updates to
`1.37` when complete.

### 7. Verify addons followed

```bash
kubectl get pods -n kube-system -o wide
aws eks list-addons --cluster-name "$CLUSTER" --region "$REGION"

for addon in vpc-cni kube-proxy coredns aws-ebs-csi-driver; do
  echo "=== $addon ==="
  aws eks describe-addon \
    --cluster-name "$CLUSTER" --region "$REGION" \
    --addon-name "$addon" \
    --query 'addon.{ver:addonVersion,status:status}'
done
```

Each addon should be `ACTIVE` with a version compatible with 1.37.
The bookstore tree resolves every `addon_version` to EKS's default
build for the cluster's version (the `aws_eks_addon_version` lookups
above), so each one should now report the default for 1.37.

### 8. Verify managed node group bumped

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,VER:.status.nodeInfo.kubeletVersion,AGE:.metadata.creationTimestamp

aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" --region "$REGION" \
  --nodegroup-name "system" \
  --query 'nodegroup.{status:status,ver:version,releaseVer:releaseVersion}'
```

The system pool's nodes should be running kubelet 1.37 with a fresh
AMI. The module rolled them one-by-one during apply.

### 9. Let Karpenter nodes drain organically (or force)

Karpenter-provisioned nodes still run on the 1.36 AMI immediately
after apply. They rotate as `expireAfter` elapses (720h = 30 days by
default). To force the rotation:

```bash
# Force-rotate ALL Karpenter nodes. Karpenter respects PDBs during drain.
kubectl delete nodes -l karpenter.sh/nodepool=general
kubectl delete nodes -l karpenter.sh/nodepool=spot
```

Or, less aggressive, drain one at a time:

```bash
NODE=$(kubectl get nodes -l karpenter.sh/nodepool=general -o name | head -1)
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
kubectl delete "$NODE"
# Karpenter provisions a replacement on the new AMI; verify it joined.
```

### 10. Post-flight verification

```bash
# Zero-diff plan.
terraform plan -detailed-exitcode
# Exit code 0 = no drift, 1 = error, 2 = drift detected.

# All nodes on the new version.
kubectl get nodes -o custom-columns=NAME:.metadata.name,VER:.status.nodeInfo.kubeletVersion

# SLO dashboards green (whatever your team uses — Prometheus/Grafana
# from Part 13 ch.09).
```

Done. The cluster is now on 1.37. Repeat the runbook for 1.38 once
`aws eks describe-cluster-versions` lists it as `STANDARD_SUPPORT`.

## How it works under the hood

**The EKS control-plane upgrade.** AWS runs the K8s control plane in
its own VPC (you only see the API endpoint). When you set
`kubernetes_version = "1.37"` in Terraform and apply, AWS receives
an `UpdateClusterVersion` API call. Internally, AWS rolls one
apiserver replica at a time behind the cluster's load balancer; the
controller-manager and scheduler upgrade alongside; etcd upgrades
last (with snapshots taken before each step). This is the same
discipline a self-managed kubeadm cluster needs
([Part 08 ch.01](../08-day-2-operations/01-cluster-lifecycle.md)),
just opaque — you don't watch the steps, you watch the status field.

**Why addons need bumping.** Each EKS-managed addon ships as a
versioned bundle (the addon catalog is region-scoped; `aws eks
describe-addon-versions --addon-name vpc-cni --kubernetes-version 1.37`
shows what's available). The addon's container image talks to the K8s
apiserver via the K8s API. APIs change between minors — fields move
from `v1beta1` to `v1`, RBAC subjects rename, new fields appear. An
addon built for 1.36 may not understand a 1.37 API, or may use an API
that 1.37 removed. The `aws_eks_addon_version` data source (with
`most_recent = false`) picks the version EKS has certified as the
default for the target minor, and it re-runs on every plan against
the cluster's current version. A bare `addon_version = null` on a
standalone `aws_eks_addon` does not do this: the AWS provider treats
the argument as optional and computed, so null keeps whatever build is
installed, and the addon would stay on its old-minor build after the
control plane moves. (In the EKS module's `cluster_addons`, where
vpc-cni lives, a null falls through to the module's own lookup.)

**Managed node group AMI updates.** EKS bakes an EKS-optimized AMI
for each K8s minor (per architecture, per OS family — AL2023,
Bottlerocket, Windows). The AMI ID is keyed off the K8s minor. When
you bump `kubernetes_version`, the EKS module passes the new version
to the node group (the tree sets no AMI ID or release version for it),
and EKS rolls the group onto the latest AMI release for that version.
The roll is one-at-a-time: cordon the old node, drain it (respecting
PodDisruptionBudgets), terminate the EC2 instance, ASG provisions a
replacement with the new AMI, wait for the new node `Ready`, repeat.
For the bookstore-platform's two-node system pool, the roll takes ~10
minutes.

**Karpenter's `expireAfter`.** The `NodePool` CR has a
`spec.disruption.expireAfter` field (default `720h` ≈ 30 days). When
a node reaches that age, Karpenter drains it and replaces it with a
new one — using the current AMI alias (e.g.,
`al2023@latest`), which auto-resolves to the latest AMI for the
cluster's current K8s minor. So a Karpenter-provisioned node born
under 1.36 will, when it expires, be replaced with an EC2 instance
running the 1.37 AMI — no manual intervention required.

**Blue-green cluster pattern.** For multi-version skips (1.33 →
1.37), the runbook is:

1. Stand up a fresh 1.37 cluster (a new Terraform tree, a new state,
   a new VPC ideally — though peering or shared VPC is OK if your
   discipline is high).
2. Replicate workloads via Argo CD ApplicationSet
   ([Part 11 ch.06](../11-advanced-production-patterns/06-multi-cluster-and-fleet.md))
   — same Application, two cluster targets.
3. Migrate stateful data — CNPG replica clusters, S3 cross-region
   replication, etc. ([Part 13 ch.03](../13-grand-capstone-bookstore-platform/03-multi-region-active-active.md)
   built the cross-region pattern; cross-cluster-same-region is the
   same shape).
4. Validate workloads on the new cluster (canary traffic, smoke
   tests).
5. Cut DNS or service-mesh traffic over to the new cluster.
6. Drain + delete the old cluster.

Blue-green dodges the N→N+1 restriction and de-risks the upgrade
(rollback = flip DNS back), at the cost of running two clusters
during the migration window — usually 1-2 weeks.

**Auto-upgrade at end of extended support.** AWS publishes the dates
in its release calendar and, if your account runs the version, posts
an AWS Health Dashboard notice about 12 months after the version's
EKS release, at least 60 days before standard support ends. After end
of extended support, EKS can upgrade the control plane at any time
and sends no notice first. The auto-upgrade covers only the control
plane and respects the same N→N+1 rule (a cluster still on 1.31 when
its extended support ends on 2026-11-26 gets upgraded to 1.32, not
directly to whatever current is). You can't opt out; you can only
beat AWS to the punch with an explicit upgrade.

## Production notes

> **In production:** Bump cadence is quarterly. New K8s minors land
> roughly every 4 months; AWS ships its EKS variant about 5-6 weeks
> later (1.37: 2026-08-26 upstream, 2026-10-01 on EKS; 1.36:
> 2026-04-22, then 2026-06-02); standard support is 14 months. A
> quarterly bump cadence keeps you on a version with 6+ months of
> standard support left and never drifts into extended-support fees.
> Faster (bumping the day a new version lands) invites
> untested-API-change bugs; slower invites the surcharge.

> **In production:** Always test in staging first. A staging EKS
> cluster running one version ahead of production catches the
> deprecated-API removal trap, the addon-version incompatibilities,
> and the workload-specific surprises (an Operator that depends on
> a removed API; a Helm chart that hard-codes a `v1beta1` reference).
> The staging cluster's control plane fee is $73/month — round-off
> error against the cost of a botched production upgrade.

> **In production:** AWS Budget alarms on the extended-support
> surcharge. Phase 14-R shipped `enable_budget_alarm = true` with a
> threshold that catches the ~$365/month surcharge surprise. Set the threshold
> to "current monthly spend × 1.2" so a single cluster slipping into
> extended support trips the alarm within hours of the deadline. The
> bookstore-platform tree's `cost-budgets.tf` is the reference; Part 14
> ch.06 ("Cost guardrails") covers the end-to-end FinOps discipline.

> **In production:** Skip-version upgrades don't exist. You walk
> through every intermediate minor or you go blue-green. The trap is
> the team that lets a cluster sit on 1.33 for two years, then tries
> to "just bump to 1.37" — they're committed to four separate apply
> cycles, each one a chance for a workload incompatibility. Stay
> current; the operational cost of frequent small bumps is far less
> than the cost of one giant catch-up.

> **In production:** `kubent` runs in CI, not just before upgrades.
> Add `kubent --target-version $((current+1))` to your nightly
> drift-detection job (covered in Phase 14b ch.07). The day someone
> commits a manifest that uses a soon-to-be-removed API, CI fails
> and you fix it months before the deadline.

> **In production:** PodDisruptionBudgets matter during node-pool
> rolls. A pool with no PDBs gets rolled fast and ungracefully; the
> module drains each node, which evicts pods, which (without a PDB)
> can take a service below quorum. The bookstore-platform's
> stateful workloads (CNPG primary, Strimzi Zookeeper) should have
> PDBs of `minAvailable: <quorum>` set in their Helm charts.

> **In production:** The "we forgot about it" failure mode is the
> single most common EKS upgrade incident. A team set up the cluster
> two years ago, the engineer who built it left, nobody knows what
> "extended support" means, and one morning AWS auto-upgrades the
> cluster from 1.31 → 1.32 (one version, at the end-of-extended-
> support event) and breaks the CNI's compatibility. AWS auto-upgrades
> one version per extended-support-end event; it does not chain
> multiple versions unattended in a single event. The defense: a
> recurring calendar event titled "EKS upgrade due" set 60 days before
> the standard-support end date of each cluster's version. The
> bookstore-platform README's §3 Version Policy is the template.

## Quick Reference

```bash
# Check AWS-side support calendar.
aws eks describe-cluster-versions \
  --query "clusterVersions[].{ver:clusterVersion,status:status,standardEnd:endOfStandardSupportDate}" \
  --output table

# Check current cluster.
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.{version:version,status:status}'

# Deprecated-API hunt.
kubent --cluster --target-version 1.37

# The actual upgrade — edit variables.tf, then:
terraform plan -out=upgrade.tfplan
terraform apply upgrade.tfplan

# Force-rotate Karpenter nodes (respects PDBs).
kubectl delete nodes -l karpenter.sh/nodepool=general

# Post-flight verification.
terraform plan -detailed-exitcode  # exit 0 = no drift
kubectl get nodes -o custom-columns=NAME:.metadata.name,VER:.status.nodeInfo.kubeletVersion
```

Version-bump 6-step runbook:

1. Read `aws eks describe-cluster-versions`; confirm target is standard.
2. Run `kubent --target-version <N+1>`; resolve all findings.
3. Edit `variables.tf` → `kubernetes_version = "<N+1>"`.
4. `terraform plan` → verify in-place changes only, apart from the
   module's `time_sleep` timer.
5. `terraform apply` → wait ~15 min for control plane + addons + managed nodes.
6. Force-rotate Karpenter nodes (`kubectl delete nodes -l ...`) or let
   `expireAfter` do it organically.

Pre-upgrade checklist (the bump is safe when all five are yes):

- [ ] Aware of the extended-support fee math — your AWS budget covers
      it if you slip.
- [ ] Staging cluster on N+1 ran for 2+ weeks without incident.
- [ ] `kubent --target-version <N+1>` returns zero findings against
      the production cluster + the GitOps repo.
- [ ] AMI bump for the managed node group is planned and PDBs are in
      place for stateful workloads.
- [ ] Karpenter NodePool `expireAfter` is set; you've decided whether
      to force-rotate or let it happen organically.

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **Why is the three-plane upgrade order (control plane → addons → nodes) non-negotiable?**
   <details><summary>Show answer</summary>

   The Kubernetes version-skew policy allows kubelet to be **older** than apiserver (up to 3 minors behind) but **never newer**. Bumping nodes first would put kubelet ahead of the control plane and into an unsupported skew. Bumping addons first can fail because the addon's compatible version may need a control-plane API that doesn't exist yet on the older version. The order minimizes the window of unsupported skew.

   </details>

2. **You inherit a cluster on EKS 1.33, whose standard support ended on 2026-07-29. Finance says the budget alarm has doubled since then. What's happening, and what do you do?**
   <details><summary>Show answer</summary>

   The cluster slipped into extended support on 2026-07-29, so AWS is billing the $0.50/cluster-hour surcharge (~$365/month per cluster) on top of the normal $0.10/hr. The fix is an explicit upgrade chain through every intermediate minor (1.33 → 1.34 → 1.35 → 1.36 → 1.37), or stand up a fresh blue-green cluster on 1.37 and migrate with Argo CD ApplicationSet, then retire the old one. Skipping minors is not supported; the discipline going forward is a quarterly bump cadence so you never slip into extended support again.

   </details>

3. **A team disables EKS-managed addons and pins specific versions in Terraform (`addon_version = "v1.20.0-eksbuild.1"`) to "avoid surprises." Six months later they upgrade the control plane to 1.37 and the cluster won't apply addon changes. Why?**
   <details><summary>Show answer</summary>

   Pinning `addon_version` bypasses the tree's `aws_eks_addon_version` lookup, so the add-on never follows the control plane; EKS itself does not update an add-on after a cluster upgrade. The pinned v1.20.0 was built for an older K8s minor and isn't certified for 1.37, and nothing flags it: with the pin unchanged, Terraform plans no change for that add-on, so the cluster runs 1.37 with an add-on build outside its compatibility table. The chapter's pattern (`addon_version` from an `aws_eks_addon_version` lookup for the cluster's version, with `most_recent = false`) picks the default version that's certified for the current K8s minor, which is almost always what you want; explicit pins are reserved for the cases where you genuinely need to test a specific version in staging.

   </details>

4. **What does `kubent --target-version 1.37` actually catch that `terraform plan` won't, and why is it the load-bearing pre-flight step?**
   <details><summary>Show answer</summary>

   `kubent` walks every resource in the cluster + every Helm release's manifests + any local YAML, and flags anything using an API removed in the target version. Terraform plan only sees what Terraform manages — Helm charts deployed by Argo CD, hand-applied CRDs, and Operator-installed resources are invisible to it. A cluster with deprecated APIs upgrades fine but the next `kubectl apply` of any object on a removed API fails — often hours later in an unrelated CI job, which makes the root cause hard to find.

   </details>

5. **Hands-on extension — in a staging cluster, set the managed node group's `force_update_version = false` and try a control-plane bump while a Pod with no PDB has `terminationGracePeriodSeconds: 3600`. Observe.**
   <details><summary>What you should see</summary>

   The control-plane bump succeeds. The node-group AMI rolling phase stalls at that node for up to 1 hour while the long grace period elapses — a single un-PDB'd pod with a long grace period can hold an entire node-group roll. PodDisruptionBudgets are what bound this; without them, your upgrade window grows unpredictably. The lesson: stateful workloads (CNPG primary, Kafka brokers) need PDBs of `minAvailable: <quorum>` set in their Helm charts before any upgrade runbook.

   </details>

## Further reading

- **AWS EKS — Kubernetes versions on EKS**
  <https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html>;
  the authoritative source for the standard/extended support calendar,
  versioning policy, and AWS's upgrade-related guarantees.
- **AWS EKS — Update a cluster**
  <https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html>;
  the official upgrade runbook, including AWS console + CLI walkthroughs.
- **AWS EKS: Update an Amazon EKS add-on**
  <https://docs.aws.amazon.com/eks/latest/userguide/updating-an-add-on.html>;
  states that EKS does not update an add-on after a cluster upgrade,
  which is why the tree looks each add-on version up per cluster
  version.
- **AWS EKS extended support pricing**
  <https://aws.amazon.com/eks/pricing/>; the $0.50/cluster-hour
  surcharge math this chapter cites.
- **kubent (kube-no-trouble)**
  <https://github.com/doitintl/kube-no-trouble>; the deprecated-API
  detector this chapter's pre-flight depends on.
- **Kubernetes version-skew policy**
  <https://kubernetes.io/releases/version-skew-policy/>; the upstream
  policy that bounds what's safe during the upgrade window.
- **Rosso et al., *Production Kubernetes* ch.5 — Cluster Operations**;
  the discipline of cluster-lifecycle planning this chapter applies
  at the EKS-specific layer.
- **AWS blog — Best practices for upgrading EKS clusters**
  <https://aws.amazon.com/blogs/containers/best-practices-for-upgrading-amazon-eks-clusters/>;
  the canonical AWS-team blog covering blue-green and in-place patterns.
