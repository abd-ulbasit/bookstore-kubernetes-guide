# Drift Runbook

You got an alert from the nightly drift check. **`terraform plan -refresh-only` shows that real resources no longer match state.** What now?

This runbook walks through the triage. Total time when things are quiet: 5 minutes. Total time when a junior cleared out something important from the console: 30-60 minutes.

---

## Step 1 — Read the diff

The drift issue lists resource **addresses** only. Plan output is never
posted to the issue, because attribute values do not belong in a public
issue. Reproduce the detail locally, with the read-only plan role:

```bash
cd examples/bookstore-platform/terraform
terraform plan -refresh-only -detailed-exitcode
```

Exit codes:
- `0` — no drift. (The alert is stale; close the issue.)
- `1` — plan errored. (Provider auth, network, syntax. Different problem.)
- `2` — drift detected. (This runbook.)

`-refresh-only` compares **state** with **the real cloud** and ignores the
`.tf` files. That is what makes exit code `2` mean drift and not "someone
merged code that has not been applied yet". A plain `terraform plan` mixes
both. Run it only after you understand the drift (Step 3), to see what
reconciling would do.

Two kinds of exit `2` are not a person changing something:

- **AWS-side updates.** An EKS platform-version bump or a managed add-on
  update shows up too. Step 2 covers telling them apart.
- **Runner-local files.** `local_file.kubeconfig` writes
  `./kubeconfig.yaml` next to whoever applied. A fresh CI runner never
  has it, so refresh always reports it deleted. CI and the nightly check
  set `write_kubeconfig = false` for that reason. If you see
  `local_file.kubeconfig[0]` in the issue, state was last written by a
  laptop apply; the next CI apply removes it from state. Locally, with
  the default `write_kubeconfig = true`, the same entry just means you
  deleted the file.

Look at the **resource addresses** in the diff ("Objects have changed
outside of Terraform"). Group them by:

1. **Deleted outside Terraform** — in state, gone from AWS. A normal plan would re-create it.
2. **Unmanaged** — exists in AWS but not in state or `.tf`. `-refresh-only` cannot see these; that is `driftctl`'s job (Part 14 ch.07).
3. **Modified** — attribute drift on an existing resource.

Each group has a different remediation.

---

## Step 2 — Find the culprit

The fastest signal: look at the **resource type**.

- **`aws_iam_role`, `aws_iam_role_policy_attachment`** — someone hand-attached a policy in the console.
- **`aws_security_group_rule`, `aws_security_group`** — usually a console-edit to "fix" an outage by opening a port. Investigate even if the change is technically benign.
- **`kubectl_manifest.<name>` (StorageClass / NodePool / EC2NodeClass)** — someone `kubectl applied` against the cluster.
- **`aws_eks_addon.<name>`** — EKS auto-updated an addon (rare; only happens on managed addons set to `AUTO`).
- **`module.eks.aws_eks_cluster.this`** — somebody changed cluster-version, logging, or endpoint config from the console.
- **`module.vpc.*`** — usually safe (someone added a tag from a different tool).

Then check the **CloudTrail event** that did it.

```bash
# Find every console action against the resource in the last 24h.
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=<RESOURCE_NAME> \
  --max-results 50 \
  --start-time "$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)"
```

(If you don't have CloudTrail enabled — `../terraform-account-baseline/cloudtrail.tf` — turn it on. This is exactly the question CloudTrail answers.)

---

## Step 3 — Reconcile

Four flavors, depending on what happened.

### 3a — The change is good. Roll it forward into Terraform.

Most common. Someone opened a port in the console because the docs were stale; now you want that change in code.

1. Edit the `.tf` file to express the desired state (the way it is now in AWS).
2. `terraform plan` — should show zero diff.
3. Commit + open a PR. CI re-runs the plan; merge when green.
4. Record the accepted values in state: `terraform apply -refresh-only`, with the apply role. Since the code already matches, the post-merge plan has no changes and the apply job does not run, so state keeps the old values and the nightly `-refresh-only` check would keep reporting the same drift.

### 3b — The change is bad. Roll it back via Terraform.

Less common but more important. Someone removed a security control "because it was blocking a test".

1. Do NOT immediately `terraform apply` the rollback — that might disrupt the test the person was running.
2. Reach out to the human (CloudTrail tells you who).
3. Once aligned, `terraform apply`. Terraform restores the original state.

### 3c — Something is being destroyed that shouldn't be.

You see a destroy line you don't recognize. **STOP**. Don't apply.

This usually means:
- Someone deleted a `.tf` file or a resource block in code without an explicit `terraform state rm` first.
- Or someone (or some tool) imported a resource that's now showing up as drift.

The remediation depends on the cause:
- If the `.tf` file got removed by accident, restore it from git history. Done.
- If a resource SHOULD be unmanaged: `terraform state rm <ADDR>`. Now Terraform forgets about it; the resource lives on in AWS.
- If a resource was just renamed: use a `moved` block (Terraform 1.1+) to migrate the state without touching AWS.

### 3d — Something is being created that already exists.

Often: someone manually created a resource (`aws_iam_role`, `aws_s3_bucket`) and added it to `.tf` later without importing. Terraform sees the resource in your code, doesn't see it in state, and proposes to create it — which will fail with "EntityAlreadyExists".

The fix: import the existing resource.

```bash
terraform import 'aws_iam_role.example' role-name
# or, modern preferred:
# Add an `import` block in code, then `terraform plan -generate-config-out=imports.tf`
```

After the import, `terraform plan` should show zero diff (or only attribute drift you can reconcile via 3a/3b).

---

## Step 4 — Close the loop

After remediation:

1. Re-run `terraform plan -refresh-only -detailed-exitcode`. Confirm exit code 0.
2. Update the nightly drift alert's GitHub issue with the root cause + the fix.
3. **If the drift was caused by a human console action**, decide:
    - Is the console action documented anywhere? If not, document it.
    - Could the action have been done through Terraform? If yes, why wasn't it?
    - Does the IAM role used to take the action need narrower permissions?
4. **If the drift was caused by a tool** (auto-rotation, EKS managed addon updates, AWS service migrations), decide:
    - Should Terraform stop managing that attribute? Use `lifecycle.ignore_changes`.
    - Or should the tool be configured differently? (Often the tool is right; the `.tf` is wrong.)

---

## Common ignore_changes patterns

Some attributes change out-of-band by design. Ignore them rather than fight them:

```hcl
resource "aws_eks_addon" "vpc_cni" {
  # …
  lifecycle {
    ignore_changes = [
      # EKS-managed version updates flow in via the EKS plane, not us.
      addon_version,
    ]
  }
}

resource "aws_autoscaling_group" "karpenter_pool" {
  # …
  lifecycle {
    ignore_changes = [
      # Karpenter manipulates desired_capacity directly; if you let TF
      # reconcile it, you'll fight Karpenter forever.
      desired_capacity,
    ]
  }
}
```

When in doubt, **start strict** (no ignore_changes) and add them as you find drift you can't or won't fix. A drift alert that's noise gets ignored; an ignore_changes that hides a real issue is worse.

---

## When to escalate

- **Drift on a resource you've never seen.** Find the owner of the resource (tags, CloudTrail) and ask.
- **Drift in a way that looks like a compromised credential** (new IAM users, new keys, security-group rules with sweeping 0.0.0.0/0 ingress on database ports). Treat as an incident. GuardDuty almost certainly already alerted; if not, file a P0.
- **Drift in `module.eks.aws_eks_cluster.this`** that changes `cluster_role_arn`, `cluster_security_group_id`, or any endpoint settings. Don't apply. Read the change carefully; this is the cluster's lifeline.

---

## Related runbooks

- **Cluster teardown failure**: see `../cleanup-verify.sh` and the main README §9.
- **Karpenter nodes won't drain**: see Part 10 ch.06.
- **Argo CD sync errors**: see Part 12 ch.04.
