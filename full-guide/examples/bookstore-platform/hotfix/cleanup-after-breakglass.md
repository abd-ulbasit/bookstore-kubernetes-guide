# Runbook — post-incident cleanup after a breakglass session

> When to reach for this: a P0 incident invoked the `breakglass-
> emergency` IAM role (`breakglass-iam-policy.json`). The role is
> time-limited (1 hour TTL via Vault); the credentials auto-rotate at
> expiry. **But** the side effects of what the breakglass user DID
> persist beyond the session. This runbook is the **24-hour cleanup
> checklist** the platform-team must complete BEFORE the postmortem
> is signed off.
>
> The "I used breakglass and forgot to clean up" footgun is a real
> security event — orphaned credentials, undocumented IAM users,
> manually-created resources outside Terraform. This file is the
> defence.

## When this runbook fires

- Any time the `breakglass-emergency` role is assumed via Vault's
  AWS auth method. Vault posts an audit event; the v2 alerting wires
  `VaultBreakglassRoleAssumed` to PagerDuty + `#bookstore-platform-
  audit`. The runbook's clock starts at session start.

## The 24-hour clock

The cleanup is divided into three windows:

1. **Hour 0-1**: while the breakglass session is live, the
   responder works the incident; ALSO captures what they did in a
   running log.
2. **Hour 1-4**: after the session expires (credentials auto-
   rotated), the cleanup-owner runs the audit + rotation steps.
3. **Hour 4-24**: postmortem written; action items filed; CloudTrail
   review completed.

## Step 1 — Capture the session log (during hour 0-1)

While invoking breakglass, the responder runs a side-channel session
log (a Slack thread or a session-recording tool; the v2 platform uses
the `gh-actions/log-session` job):

```text
Slack thread in #bookstore-platform-status:
  HH:MM  assumed breakglass; approver @alice; cleanup-owner @bob
  HH:MM  ran: aws ec2 describe-instances --filter "..."
  HH:MM  ran: aws ec2 terminate-instances --instance-ids i-0abc...
  HH:MM  ran: aws iam create-policy --policy-name <NAME> --policy-document file://emergency.json
  HH:MM  ran: kubectl --kubeconfig /tmp/k.cfg get pods -A
  HH:MM  applied <PATH>/<FILE>.yaml
  HH:MM  session expiring; cleanup runbook starts
```

This thread is the **definitive record** for the postmortem; it's
better than CloudTrail because it captures intent.

## Step 2 — Verify session expiry (hour 1-2)

```sh
# The Vault AWS auth method auto-rotates credentials at TTL expiry.
# Confirm the access-key associated with the breakglass session is
# now disabled.

vault read aws/sts/breakglass-emergency
# Verify there's no active lease for the session.
vault list sys/leases/lookup/aws/sts/breakglass-emergency
# Expect: empty.

# Cross-check the IAM access-key ID from the session log:
aws iam get-access-key-last-used --access-key-id AKIA...
# Should show LastUsedDate before expiry; or AccessKey marked Inactive.
```

If the access key is STILL ACTIVE post-expiry, Vault's auto-rotation
failed → **escalate** to the platform admin; manually disable the
access key.

## Step 3 — Inventory what changed (hour 1-3)

The breakglass session may have created / mutated / deleted:

1. **AWS resources** — EC2 instances, IAM users/policies, S3
   buckets, RDS snapshots, Route 53 records.
2. **Kubernetes resources** — Deployments, ConfigMaps, Secrets,
   CRDs (Crossplane XRs, Argo CD Applications).
3. **Secrets** — credentials, API keys created out-of-band.

### 3a. AWS resources — CloudTrail audit

```sh
# Pull every API call made by the breakglass session.
START="2026-05-20T13:00:00Z"
END="2026-05-20T14:00:00Z"
PRINCIPAL_ARN="arn:aws:sts::123456789012:assumed-role/breakglass-emergency/alice"

aws cloudtrail lookup-events \
  --start-time "$START" --end-time "$END" \
  --lookup-attributes "AttributeKey=UserName,AttributeValue=alice" \
  --output table \
  --query 'Events[*].[EventTime,EventName,Resources[0].ResourceName]'
# Generates a table of every API call. Cross-reference with the
# session log in Step 1; flag any unexpected entries.

# Save to S3 for the postmortem:
aws cloudtrail lookup-events --start-time "$START" --end-time "$END" \
  --lookup-attributes "AttributeKey=UserName,AttributeValue=alice" \
  --output json > /tmp/INC-2026-05-20-001-cloudtrail.json
aws s3 cp /tmp/INC-2026-05-20-001-cloudtrail.json \
  s3://bookstore-platform-audit/incidents/INC-2026-05-20-001/cloudtrail.json
```

### 3b. AWS resources — Terraform drift check

The breakglass session likely created resources OUTSIDE Terraform.
Run drift detection (Part 14 ch.07) to find them:

```sh
cd examples/bookstore-platform/terraform/clusters/us-east
terraform plan -out=/tmp/post-breakglass.plan
# Inspect the plan. Any "will be DESTROYED" line means the breakglass
# created something Terraform does NOT know about — orphaned
# resource. Decision: import it into TF (preferred) OR delete it.

# Import:
terraform import 'aws_eip.emergency_nat_gateway' eip-0abc1234...
# Delete (only if confirmed safe):
aws ec2 release-address --allocation-id eip-0abc1234...
```

Every breakglass session leaves at least one orphaned-resource issue;
the goal is to bring the world back to "Terraform state = AWS reality"
before declaring cleanup done.

### 3c. Kubernetes resources — Argo CD drift check

```sh
argocd app list -o json \
  | jq '.[] | select(.status.sync.status != "Synced") | .metadata.name'
# Any out-of-sync apps?
# For each: argocd app diff <APP> -- inspect what's different.
# If the diff matches a breakglass action -> document it; either git-
# commit the change (formalise it) or argocd app sync (revert).
```

### 3d. Secrets inventory

If the breakglass session created credentials (a new IAM user, a new
RDS password, a new Vault token):

```sh
# List IAM users created in the window.
aws iam list-users \
  --query 'Users[?CreateDate>=`2026-05-20T13:00:00Z` && CreateDate<=`2026-05-20T14:00:00Z`]'

# For each: was it documented? Is it temporary? If unsure → DELETE.
aws iam delete-access-key --user-name <NAME> --access-key-id AKIA...
aws iam delete-user --user-name <NAME>
```

## Step 4 — Rotate credentials touched by the session (hour 2-3)

ANY secret the breakglass session could have READ is treated as
compromised. The mitigation: rotate.

The Bookstore Platform's secret-rotation triggers via the v2 Vault
rotation cycle (`examples/bookstore-platform/vault/`); rotate the
following:

```sh
# Rotate the RDS master passwords (CNPG operator + Crossplane XR):
kubectl -n cnpg-system annotate cluster bookstore-platform-cnpg-orders \
  cnpg.io/reloadCredentials="$(date +%s)"
# CNPG generates new credentials; updates the Secret + restarts apps.

# Rotate the application Vault tokens (the ESO ClusterSecretStore):
kubectl -n external-secrets rollout restart deployment/external-secrets

# Rotate the Stripe keys + every API key in scope:
# Manual: open the Stripe dashboard → roll keys → update Vault → wait
# for ESO sync.

# Rotate the catalog signing key (Cosign):
kubectl -n bookstore-platform-ci delete secret cosign-private-key
# CI/CD pipeline regenerates on next run from Vault.
```

If the breakglass session accessed S3, rotate any signed-URLs that
were created (cancel CloudFront key-pairs if used). If accessed
Route 53, no rotation needed; DNS is public.

## Step 5 — Confirm IAM policy is restored (hour 3-4)

The breakglass session may have temporarily ATTACHED policies to
roles to do its work; verify those are detached:

```sh
# List policies on every role the session touched.
for role in $(jq -r '.Events[] | select(.EventName | startswith("AttachRolePolicy")) | .Resources[] | select(.ResourceType=="AWS::IAM::Role") | .ResourceName' /tmp/INC-2026-05-20-001-cloudtrail.json | sort -u); do
  echo "Role: $role"
  aws iam list-attached-role-policies --role-name "$role" --output table
done
# Cross-check against the Terraform-managed expected state.
```

Any extra policy → detach, OR commit it to Terraform if it's now
permanent.

## Step 6 — Write the postmortem (hour 4-24)

Open `../runbooks/postmortem-template.md`. Mandatory hotfix +
breakglass sections:

- **Why was breakglass needed?** "The standard role couldn't do X"
  is a process gap; the action item is "add X to the standard role's
  policy" if X is repeatable.
- **What was the blast radius of the breakglass session?** Lift
  directly from the CloudTrail JSON saved in Step 3a.
- **Did the session do ONLY what it needed to?** If the responder
  ran ad-hoc `aws ec2 describe-*` commands or browsed S3 for
  reconnaissance, that's NOT in-scope for the incident; mention it.
- **Cleanup-owner sign-off**: the cleanup-owner certifies in the
  postmortem that Steps 2-5 are complete.

## Step 7 — Update the alerting (action item, post-postmortem)

If the breakglass was needed for a SPECIFIC blocker (e.g. "the
standard platform-engineer role lacks `iam:UpdateAssumeRolePolicy`
on the IRSA roles"), open a Terraform PR that adds the permission to
the standard role. The goal: the **next** time this happens, the
standard role is enough; breakglass stays unused.

This is the discipline that prevents "breakglass becomes normal" —
every invocation results in a permanent fix that makes the NEXT
invocation unnecessary. After 6-12 months of disciplined
breakglass→fix cycles, the rate of breakglass use should approach
zero.

## Footguns

### "I forgot to rotate Stripe keys"

The breakglass policy allows `s3:*` on the bookstore-platform
buckets, which includes the bucket where CI puts a temporary Stripe
key during a deploy. If the responder read that key (even
incidentally), the key is now compromised. Step 4 is non-negotiable
even if the responder claims "I didn't touch Stripe".

### "I created a temporary IAM user and left it"

Step 3d catches this. The temporary user persists across the session
expiry (the user is NOT tied to the role's TTL). Always delete
temporary users in cleanup; if you forget, an auditor finds it 6
months later and the postmortem-debt is much heavier.

### "Cleanup is just a formality"

The cleanup-owner is named in the hotfix declaration (Step 1 of
`HOTFIX-RUNBOOK.md`). If the postmortem ships without the cleanup
sign-off, the postmortem is **incomplete** and the action items
don't track until cleanup is done. The platform-team's quarterly
review tracks postmortem-completion rate; an incomplete one counts
against it.

### "We renewed the breakglass instead of cleaning up"

A common anti-pattern: the responder renews the breakglass session
(takes a SECOND 1-hour TTL) "just in case" without doing the
cleanup. This is treated as a SEPARATE incident:
- The renewal posts to `#bookstore-platform-audit` and pages a
  platform-admin.
- The admin asks: "what's the renewal justification?"
- If no good answer → the renewal is denied and the session ends.

## Quick reference

```sh
# (After the breakglass session ends — hour 1)
vault list sys/leases/lookup/aws/sts/breakglass-emergency   # empty?
aws iam get-access-key-last-used --access-key-id AKIA...    # inactive?

# (Hour 1-3)
aws cloudtrail lookup-events --lookup-attributes UserName,alice ... > /tmp/cloudtrail.json
terraform plan                                              # drift?
argocd app list --refresh                                   # drift?
aws iam list-users --query ...                              # any new?

# (Hour 2-3)
kubectl -n cnpg-system annotate ... cnpg.io/reloadCredentials=...
kubectl -n external-secrets rollout restart deployment/external-secrets
# Rotate API keys outside cluster (Stripe, GitHub PATs, ...).

# (Hour 4-24)
# Postmortem template with breakglass sections.
# Action item: Terraform PR if a standard role gap was exposed.
```

## Related runbooks

- [`HOTFIX-RUNBOOK.md`](HOTFIX-RUNBOOK.md) — the emergency change
  procedure that may have invoked breakglass.
- [`breakglass-iam-policy.json`](breakglass-iam-policy.json) — the
  IAM permissions of the role.
- [`../runbooks/postmortem-template.md`](../runbooks/postmortem-template.md) —
  the postmortem template.

## When this runbook last worked

| Date       | Session                      | Resolved by                       | Notes |
|------------|------------------------------|-----------------------------------|-------|
| 2026-03-15 | INC-2026-03-15-001 IRSA lockout | Steps 1-7; PR-fix to standard role | breakglass needed iam:UpdateAssumeRolePolicy; added permanently |

> Stale after **90 days** without exercise. The quarterly chaos
> game-day SHOULD include a dry-run breakglass exercise.
