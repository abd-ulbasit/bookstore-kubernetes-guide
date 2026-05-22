# Lessons from running this guide's Terraform against real EKS

On **2026-05-20**, the Bookstore Platform v2 Terraform tree at
`full-guide/examples/bookstore-platform/terraform/` was applied to a real
AWS account: **EKS 1.35 in `ap-south-1`** (Mumbai), Karpenter for node
autoscaling, gp3 EBS for storage, CloudTrail + IAM Access Analyzer on
the account baseline. The cluster came up, the canonical Bookstore
application deployed cleanly, Karpenter scaled on demand, and a
`terraform destroy` returned the account to its pre-smoke baseline.
Total spend on the live AWS bill: **~$0.20**.

The smoke test did its job: it surfaced five real gaps that no amount of
`terraform plan` review would have caught. None of them were exotic.
All five were the kind of thing that *will* bite a team a year into
operating the same Terraform — quietly costing money or failing in odd,
hard-to-debug ways. Each one became a Tier-1 fix in the Phase 14-R
review-and-extend pass and now lives in the example tree as the
documented production-ready default.

This page is the post-mortem.

---

## Setup

| | |
|---|---|
| **Region** | `ap-south-1` |
| **Kubernetes version** | 1.35 (EKS-supported, GA) |
| **Cluster shape** | one EKS control plane + one `system` managed node group (t3.medium ×1) + Karpenter for workload nodes |
| **Node-class AMIs** | `AL2023_x86_64_STANDARD`, gp3 root volumes, encrypted |
| **Workload** | full Bookstore Platform v2 (catalog, orders, payments-worker, postgres, redis) via Helm + Kustomize |
| **Test duration** | ~45 minutes apply → workload deploy → traffic generation → destroy |
| **AWS spend** | ~$0.20 (EKS control-plane prorated + ~3 vCPU-hours of t3.small Karpenter nodes + a handful of EBS-hour for PVCs) |

---

## What the smoke test caught

### 1. Control-plane CloudWatch logs accumulated forever

**What happened.** The EKS module was configured with the standard set
of control-plane log types enabled (`api`, `audit`, `authenticator`,
`controllerManager`, `scheduler`) but no retention policy. AWS creates
the log group `/aws/eks/<cluster>/cluster` automatically when the
control plane writes to it, with the default retention: *Never Expire*.

**How it surfaced.** During teardown verification, the cleanup script
flagged the log group as still present after `terraform destroy`
(expected — log groups outlive the cluster on purpose for forensics).
What the script didn't catch is that on a busy cluster the audit log
stream alone can hit several GB/day. At $0.50/GB-ingest + $0.03/GB/month
retention, a year of *Never Expire* on a production-shape cluster is a
real bill — and it accumulates silently.

**Fix in the tree.** A new variable
`cloudwatch_log_group_retention_in_days = 30` (default) on the EKS
module. The EKS module creates the log group and applies the retention.
Production teams who need longer can override; nobody gets *Never
Expire* by accident any more.

**What this would have cost without the fix.** On a 10-node production
cluster running 200 Pods, audit-log volume of ~5 GB/day is realistic.
Five years of *Never Expire* retention = ~9 TB stored = **~$270/month**
purely for forgotten log retention.

---

### 2. `vpc-cni` first-boot race

**What happened.** On the first cluster apply, two of the three worker
nodes spent a few seconds in `NotReady` state before the `vpc-cni`
addon finished installing on them. Visible only because we were
watching `kubectl get nodes -w` during apply — easy to miss in a
plan/apply that takes 15 minutes.

The root cause is the natural race between the managed-node-group
becoming ready (nodes joining the cluster) and the `vpc-cni` addon
being installed by the EKS module. Without the CNI, Pod networking
isn't possible; nodes that join before it lands serve no Pods until
the addon catches up.

**How it surfaced.** Pods scheduled to the un-CNI'd nodes appeared
`Pending` with no clear reason. `kubectl describe node <node>` showed
`network plugin is not ready: cni config uninitialized`. Hidden by the
fact that the `system` node group successfully ran Karpenter + the LB
controller (which tolerate the `CriticalAddonsOnly` taint and don't
care about user Pod networking).

**Fix in the tree.** Move `vpc-cni` into `cluster_addons` in the EKS
module with `before_compute = true`. This guarantees the addon is
installed between the control plane coming up and the managed node
group launching its EC2 instances. Standalone `aws_eks_addon`
resources don't get this ordering for free — the addon and the node
group are concurrent siblings, which is exactly the race we hit.

**What this would have cost without the fix.** Nothing in steady state.
But on every fresh apply (CI cluster spin-up, multi-region rollout, DR
rehearsal), the operator gets to spend 5 minutes deciding whether
"the node is just slow" or "something is broken." Compounds across
teams.

---

### 3. gp2 the EKS default StorageClass

**What happened.** Out of the box, EKS clusters ship with a `gp2`
default StorageClass. The Bookstore Platform's StatefulSets
(`postgres`, `redis`) consequently provisioned `gp2` PVCs without
asking — even though every modern AWS recommendation is to use `gp3`.

`gp3` is roughly 20% cheaper than `gp2` for equivalent IOPS, supports
independent provisioning of capacity / IOPS / throughput, and has been
the AWS default for new EBS volumes (outside the EKS bundled
StorageClass) since 2021.

**How it surfaced.** A `kubectl get pvc` after deploy showed
`storageClassName: gp2`. The provisioned `postgres-0` volume was
50 GiB gp2 — at $0.10/GB-month, $5/month — whereas the gp3 equivalent
would have been $4/month for the same shape.

Multiply by a real production application with a dozen PVCs and the
"forgot to change the default" tax adds up.

**Fix in the tree.** A `kubectl_manifest` resource creates a
`gp3-encrypted` StorageClass with the `is-default-class: "true"`
annotation, and removes that annotation from the EKS-bundled `gp2`.
Every PVC in the tree from that point forward gets gp3 by default,
encrypted, with the `Delete` reclaim policy explicitly set.

**What this would have cost without the fix.** On a workload with
500 GiB of EBS provisioned across PVCs, the savings are ~$10/month.
Trivial per cluster; meaningful at fleet scale.

---

### 4. No budget alarm

**What happened.** The smoke test deliberately bounded spend at ~$0.20
by destroying everything after 45 minutes. But the Terraform tree had
no opinion about cost-runaway protection — nothing would have told the
operator if a misconfigured Karpenter NodePool burned $400/day on
m5.4xlarge spot fallbacks.

The smoke test was the *evidence* that cost guardrails were missing
from the example. (The smoke itself didn't cost anything; the gap was
that the *tree* shipped without recommending a guardrail.)

**Fix in the tree.** A `var.enable_budget_alarm = false` default-off
variable that, when set true, provisions:

* an `aws_budgets_budget` for the user-supplied monthly amount
* an SNS topic
* a subscription to `var.budget_alarm_email`
* an SNS topic policy that allows AWS Budgets to publish

When enabled, the operator gets an email at 80% of forecasted spend
and again at 100%. Opt-in by design — the budget itself is free; the
SNS topic is free at any reasonable email volume; only the human
attention is the cost.

**What this would have cost without the fix.** Bounded by paranoia.
The point of the alarm isn't to prevent any specific known cost — it's
to flatten the tail of *unknown* costs (a misconfigured ASG, an open
spot fleet, a forgotten dev cluster). Three teams' worth of EKS
operations stories include at least one "we forgot to destroy and it
cost $N,000" incident. Five-minute fix; high-value backstop.

---

### 5. No way to preview cost before `apply`

**What happened.** `terraform plan` answers "what AWS resources will
change?" — it does not answer "what will those changes cost per
month?" For an example tree that's about to be applied by readers
who may or may not have AWS billing literacy, the absence of a "this
plan will cost ~$X/mo" hint at apply-time is a defensible omission
but a real foot-gun.

**Fix in the tree.** A `make plan-cost` Makefile target that runs
`terraform plan` *and* pipes the plan JSON through
[`infracost`](https://infracost.io) for a per-resource $/month
estimate. Gracefully degrades when `infracost` isn't on `$PATH` —
prints an install hint and continues with the bare plan. No
external account needed for the basic price-sheet mode.

For readers without `infracost` installed, the cost-bearing
resources in the tree (EKS control plane, EBS volumes, NAT gateways,
load balancers) each have a banner comment in their Terraform
explaining the per-hour or per-month cost. Belt-and-braces.

**What this would have cost without the fix.** First-time readers
applying the tree to learn EKS without ever seeing a $/mo number
attached to a `terraform plan`. The single most common "and then
I got a $300 AWS bill" learning moment in the entire Kubernetes-
on-cloud journey. Now there's a one-command preview before any apply.

---

## Process lessons

A few things that became disciplines after the smoke test, beyond the
five specific fixes above:

* **Var-gate every cost-bearing resource, default off.** Every new
  Tier-2/3 addition to the tree (VPC endpoints, GitHub Actions OIDC
  bootstrap, multi-region scaffolding, account-baseline GuardDuty +
  Security Hub) ships behind `var.enable_<feature> = false`. The
  default `terraform apply` provisions nothing the reader didn't
  explicitly opt into.
* **Cleanup verification, not just `terraform destroy`.** The destroy
  command exits successfully even when some resources are left behind
  (e.g. load balancers created by the AWS LB controller in response to
  Service objects — Terraform doesn't know about those because
  Kubernetes provisioned them). A separate `cleanup-verify.sh` walks
  the account post-destroy looking for orphaned LBs, ENIs, and EBS
  volumes tagged with the cluster name, and *fails noisily* if any
  remain. Worth the script.
* **CI counts as the canonical surface.** The Helm chart's 49-object
  count and the Kustomize overlays' 45/49/48-object counts are
  enforced in CI ([ADR 0007](adr/0007-helm-kustomize-render-counts-as-invariants.md))
  precisely because the smoke test demonstrated how *easy* it is for
  manifest count to drift silently. The CI gate is the only way to
  catch it before merge.

---

## What this is not

This is not a horror story. The smoke test went well — apply worked,
the workload came up, traffic flowed, destroy cleaned everything
up. The five findings are exactly the kind of *quiet* issues a
healthy smoke test should surface: things that wouldn't have caused
a fire on day one but would have cost real money or operator
attention by month six.

The total cost of catching all five: 45 minutes of cluster time and
about 20 cents of AWS spend. The cost of *not* catching them: somewhere
between "an irritating Slack thread" and "a budget approval meeting
nobody wanted to have."

It's the cheapest insurance the guide has ever bought.
