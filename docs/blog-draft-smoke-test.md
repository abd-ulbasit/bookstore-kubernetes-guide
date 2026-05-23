# What a $0.20 EKS smoke test taught me about my own Kubernetes guide

> **Draft post — for dev.to / Medium / personal blog.** Suggested
> title variants below. Roughly 850 words. Ready to publish as-is, or
> trim Section 5's process-discipline list for a shorter cut.

---

I'd been writing a hands-on Kubernetes guide for a few months — 115
chapters, four runnable example trees, the works. The Terraform tree
for the EKS-in-production part was the bit I felt the most uncertain
about. It was clean. It validated. It rendered. It had been reviewed
twice by automated quality gates and a third time by hand. But there's
a particular kind of confidence you don't get from `terraform validate`
— the kind that comes from actually applying the code to a real AWS
account and watching what breaks.

So I did. EKS 1.35 in `ap-south-1` (Mumbai, closest region to me),
Karpenter for node autoscaling, the whole canonical Bookstore
application deployed via Helm, real traffic hit, full clean
`terraform destroy`. **Total cost on the AWS bill: 20 cents.**

The test didn't blow up. The cluster came up, the workload ran,
Karpenter scaled, destroy returned the account to baseline. So in
one sense, the smoke test was "boring" — exactly the outcome you want.

But it surfaced **five separate gaps** that no amount of plan
review would have caught. None of them were exotic. All of them
were the kind of thing that would *quietly* cost a team six months
into operating the same Terraform. I want to walk through them
because the *pattern* matters more than any individual finding.

## 1. CloudWatch logs accumulated forever

The EKS module had every control-plane log type enabled — api, audit,
authenticator, controllerManager, scheduler. What it didn't have was a
retention policy. AWS creates the log group when EKS first writes to it,
with the default retention: *Never Expire*.

On a busy production cluster the audit log stream alone runs 5+ GB/day.
At $0.50/GB-ingest plus $0.03/GB/month, *Never Expire* for a year on
that shape of cluster is **~$270/month for forgotten logs**. The fix
took a single variable: `cloudwatch_log_group_retention_in_days = 30`.

## 2. The vpc-cni first-boot race

The first apply put two of three worker nodes into `NotReady` for a
few seconds because the `vpc-cni` addon was racing the managed node
group. Pods scheduled to those nodes appeared `Pending` with the
delightful description `network plugin is not ready: cni config
uninitialized`. Easy to miss on a 15-minute apply when you're not
watching `kubectl get nodes -w`.

The fix: move `vpc-cni` into `cluster_addons` with `before_compute =
true`, which forces the addon to install *between* the control plane
coming up and the node group launching EC2 instances. Five-line
diff. Cost the next time the team does a fresh-cluster spin: zero
"is the node just slow?" minutes.

## 3. gp2 was the EKS default StorageClass

The Bookstore Postgres came up on a `gp2` PVC. Not catastrophic —
gp2 works fine — but every modern AWS recommendation is `gp3` (about
20% cheaper for equivalent IOPS, plus independent provisioning of
capacity / IOPS / throughput). EKS ships with `gp2` as the default
class out of legacy habit.

Fix: a `kubectl_manifest` resource that creates a `gp3-encrypted`
StorageClass marked default, and strips the `default-class`
annotation from the bundled gp2. Every PVC from then on is encrypted
gp3 without anyone thinking about it.

## 4. No budget alarm

The smoke test deliberately bounded spend by tearing down after 45
minutes. But the Terraform itself had no opinion about cost runaways
— nothing would have shouted if a misconfigured Karpenter NodePool
silently spun up `m5.4xlarge` spot fallbacks for a week.

I added an opt-in `var.enable_budget_alarm = false` that, when set
true, wires up `aws_budgets_budget` → SNS → email at 80% of forecast.
The budget itself is free; the SNS topic is free at any reasonable
email volume. The cost of *not* having it is bounded only by paranoia.

## 5. No cost preview before `apply`

`terraform plan` answers "what will change?" — not "what will it cost?"
For an example tree about to be applied by people who may or may not
have AWS billing literacy, the absence of a "this plan will cost ~$X/mo"
hint is a defensible omission but a real foot-gun.

Fix: a `make plan-cost` target that pipes the plan JSON through
[infracost](https://infracost.io) for per-resource $/month, gracefully
degrading if infracost isn't installed.

---

## The pattern, not the findings

None of these required deep AWS magic. All of them required *running
the thing*. Two of them (1 and 4) were about gaps the cost dimension
of the system — the kind of thing static analysis can't see, because
the trigger is operating-time, not apply-time. Two more (2 and 5)
were race conditions / process omissions that only appear during the
narrow window of "the cluster is being created." One (3) was a quiet
suboptimal default.

The disciplines that came out the other side of this smoke test
have since become standing rules in the example tree:

* **Every cost-bearing resource ships var-gated, default-off.**
  Opt-in is correct friction for things that bill.
* **Cleanup verification is its own script, separate from `terraform
  destroy`.** Destroy succeeds even when AWS LB Controller has left
  load balancers behind (Terraform doesn't know about Kubernetes-
  managed AWS resources).
* **CI counts as the canonical surface.** The Helm chart renders
  exactly 49 manifests; the Kustomize overlays render 45/49/48. Those
  numbers are enforced as CI gates because the smoke test demonstrated
  how easy it is for them to drift silently.

The full guide and the live-smoke-tested Terraform are at
**[github.com/abd-ulbasit/bookstore-kubernetes-guide](https://github.com/abd-ulbasit/bookstore-kubernetes-guide)**.
The post-mortem this article condenses lives at
[`docs/lessons-from-smoke-test.md`](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/blob/main/docs/lessons-from-smoke-test.md);
the architectural decisions in the
[`docs/adr/`](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/tree/main/docs/adr)
directory.

If you've smoke-tested your own infra recently and the test went
*too* clean, I'd be a little suspicious. Twenty cents of EC2 buys a
lot of confidence.

---

## Suggested titles (pick one)

1. **"What a 20-cent EKS smoke test taught me about my own Kubernetes guide"**
2. "I smoke-tested my Kubernetes guide's Terraform against real EKS for $0.20 — here's what broke"
3. "Five production gaps you can only find by actually running your IaC"
4. "The cheapest insurance my Terraform tree ever bought"

## Suggested tags (dev.to / Medium)

`kubernetes` `terraform` `aws` `eks` `devops` `sre` `postmortem` `infrastructure` `cloudcost`

## Suggested cover image

A simple monospace ASCII block: "$0.20 → 5 bugs" against a dark
background. Or, if you have it, a screenshot of the AWS Cost Explorer
chart for the smoke-test day showing the tiny spike.

## Publish checklist

- [ ] Replace `github.com/abd-ulbasit/bookstore-kubernetes-guide` URLs
      with the actual canonical link if you decide to use a custom domain.
- [ ] Post to dev.to with `kubernetes` + `terraform` + `aws` tags.
- [ ] Cross-post to Medium with the canonical link pointing to dev.to.
- [ ] Submit to /r/kubernetes (link only — Reddit's link-only posts
      do better than self-text for technical content).
- [ ] Submit to lobste.rs if you have an account (tagged `devops`,
      `practices`).
- [ ] Submit to Hacker News (Show HN: format works well for
      "I built this" posts; "$X taught me Y" hooks work for the
      Ask HN / submission feed).
