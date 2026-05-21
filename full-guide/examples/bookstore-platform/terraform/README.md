# Bookstore Platform — EKS Deploy Tree

This directory provisions the AWS infrastructure the Bookstore Platform v2 runs on. Terraform builds the substrate (VPC, EKS control plane, system node group, Karpenter, LB controller, EBS-CSI, metrics-server); Argo CD takes it from there for application workloads.

You opt in to costs. The user — not this Makefile — runs `make up`. Read all eleven sections before you do.

---

## 1. What this deploys

A single-region EKS cluster, ready for a multi-tenant platform:

- **VPC** — `10.0.0.0/16` across three Availability Zones, with public (`/20`), private (`/20`), and intra (`/22`) subnets per AZ. The intra subnets host EKS control-plane ENIs; they have no NAT egress.
- **EKS cluster** — Kubernetes `1.35`, the control plane logs to CloudWatch, secrets are envelope-encrypted with a customer-managed KMS key. The principal that runs `terraform apply` is granted cluster-admin via an EKS access entry — no `aws-auth` ConfigMap.
- **One small managed node group ("system")** — 2 × `t3.medium` On-Demand, tainted `CriticalAddonsOnly=true:NoSchedule`. Hosts Karpenter, the AWS Load Balancer Controller, CoreDNS, the EBS-CSI controller, metrics-server. Nothing else.
- **Karpenter `1.6.0`** — running in `kube-system`. Two `NodePool` resources: `general` (On-Demand, `c/m/r` families, generation > 4) and `spot` (prefers Spot, falls back to On-Demand, higher `weight` so Karpenter reaches for it first). Consolidation is `WhenEmptyOrUnderutilized` with a 30-second timer. One `EC2NodeClass` (`default`) using the EKS-optimized `al2023@latest` AMI alias.
- **AWS Load Balancer Controller `1.13.0`** — the bridge from `Service type=LoadBalancer` and `Ingress` to ALBs / NLBs. IRSA-scoped to the IAM policy fetched from the upstream `v2.13.0` tag at plan time.
- **EBS-CSI driver, vpc-cni, kube-proxy, CoreDNS** — installed as EKS-managed addons. Versions are pinned implicitly by EKS to the 1.35 default; we override only `configuration_values` (system-pool placement, replica count).
- **metrics-server `3.13.0`** — for `kubectl top` and HPA. Karpenter does not require it.

The Bookstore Platform application workloads (auth, payments, search, ML, observability, …) are **not** installed here. Argo CD bootstraps those after the cluster is up — see `../argocd/`.

---

## 2. Cost estimate

The numbers below are list-price `us-east-1` as of 2026-05; cross-check your region.

| Component                       | Hourly        | Monthly (730 h) |
|---------------------------------|---------------|-----------------|
| EKS control plane (standard support) | $0.10/hr  | ~$73            |
| 2 × `t3.medium` On-Demand       | 2 × $0.0416   | ~$61            |
| NAT Gateway (single, dev)       | $0.045/hr     | ~$33            |
| NAT data processing             | $0.045/GB     | varies          |
| EBS gp3 (3 × 30 GB system roots) | $0.08/GB-mo  | ~$7             |
| CloudWatch logs (5 control-plane log types) | varies | $5-15  |
| **Subtotal (idle)**             |               | **~$180/month, ~$5-8/day** |
| Karpenter workers (on-demand)   | scales with pods | extra |
| Karpenter workers (spot)        | typically 60-80% cheaper than on-demand | extra |
| ALB/NLB per Service             | $0.0225/hr + LCU charges | $16+ each |

**The Spot NodePool is the headline saving.** Steady-state, the platform's stateless tiers (gateway, search, ML inference replicas) all tolerate Spot interruption — Karpenter will pack them onto Spot capacity by default because the Spot NodePool has higher `weight` than `general`.

**Scaling to zero.** Karpenter consolidates nodes that go idle within 30 seconds; if you stop submitting pods, your worker bill drops to zero quickly. The control plane and system node group keep running until `make down`.

---

## 3. Version policy

Kubernetes `1.35` is the pinned target. AWS marked it standard support on 2026-04-18; standard support ends **2027-03-27**. Past that date the cluster shifts to extended support, which carries an additional $0.50/hr surcharge per cluster. Don't get caught.

**Check current support windows:**

```bash
aws eks describe-cluster-versions \
  --query "clusterVersions[].{version:clusterVersion,status:status,endOfStandardSupport:endOfStandardSupportDate}" \
  --output table
```

**Bump procedure (when 1.36 hits standard support):**

1. Read the upstream Kubernetes 1.36 changelog and the EKS release notes for any deprecations that affect the cluster's add-ons or your workloads.
2. Set `kubernetes_version = "1.36"` in `variables.tf` (or via `-var`).
3. `terraform plan` — you should see a single in-place change on `module.eks.aws_eks_cluster.this`. No node-group destroy/create.
4. `terraform apply`. EKS performs a rolling control-plane upgrade in place (≈20 minutes).
5. For the managed `system` node group, `terraform apply` triggers a rolling AMI bump — the module replaces nodes one at a time, respecting PDBs. Karpenter-provisioned nodes will be replaced naturally as `expireAfter: 720h` fires (or you can `kubectl delete nodes -l karpenter.sh/nodepool` to force it).
6. Re-run `make plan` to confirm zero diff; commit.

Do not skip versions. EKS only supports N → N+1 upgrades.

---

## 4. Prerequisites

- An AWS account with permission to create VPCs, EKS clusters, IAM roles, KMS keys, SQS queues, and EC2 instances. The principal you run Terraform as becomes the cluster admin, so make it your real working identity, not a throwaway service role.
- AWS CLI v2 configured: `aws sts get-caller-identity` must return the expected account.
- Terraform `>= 1.9.0, < 2.0.0` — `.terraform-version` pins `1.10.5` for `tfenv` / `asdf` users.
- `kubectl` (any version within ±1 minor of `1.35`).
- `helm` `>= 3.13`.
- `jq` — the cleanup scripts use it heavily.
- Outbound network egress for `terraform init` (HashiCorp registry + GitHub Releases for module sources).

---

## 5. Quick start

```bash
# 1) Copy and edit the variables file (region, cluster name, tags).
cp example.tfvars my.tfvars
$EDITOR my.tfvars

# 2) Initialize providers + modules (~1 min).
make init

# 3) See the plan.
terraform plan -var-file=my.tfvars -out=tfplan

# 4) Apply. The Makefile target prompts y/N and warns about cost.
make up
#   …or, if you used a tfvars file:
# terraform apply -var-file=my.tfvars

# 5) Verify.
terraform output kubeconfig_command
```

First apply takes **18 to 22 minutes**: VPC ≈ 3 min, EKS control plane ≈ 10 min, system node group + addons ≈ 5 min, Karpenter + LB controller ≈ 2 min.

If `terraform apply` fails mid-way and you want to retry: it's safe to re-run. The module set is idempotent on partial state.

---

## 6. Connecting kubectl

Two options, pick one:

**Option A — merge into your local kubeconfig (recommended for human use):**

```bash
$(terraform output -raw kubeconfig_command)
# This prints: aws eks update-kubeconfig --region <REGION> --name bookstore-platform

kubectl config use-context arn:aws:eks:<REGION>:<ACCOUNT>:cluster/bookstore-platform
kubectl get nodes
```

**Option B — use the standalone kubeconfig.yaml Terraform wrote:**

```bash
export KUBECONFIG=./kubeconfig.yaml
kubectl get nodes
```

The cleanup scripts auto-detect `./kubeconfig.yaml`. They prefer it over `~/.kube/config` so they always target the right cluster.

---

## 7. Karpenter autoscaling

**How it works.** When the kube-scheduler can't fit a pod on existing nodes, the pod stays `Pending`. Karpenter watches `Pending` pods, picks a minimum-cost instance type that satisfies all `requirements` (architecture, OS, capacity-type, taints, resource requests), launches that EC2 instance directly via the EC2 API (no Auto Scaling Group), waits for it to join the cluster, and schedules the pod onto it. No middle-tier. No 10-minute ASG cooldown.

When pods drain off a node, Karpenter's consolidation reaper (running every 30 seconds, per the NodePool config) checks whether the cluster's workloads would still fit if the node went away. If they would, the node gets cordoned and deleted.

**Test it:**

```bash
# Submit 50 replicas of a CPU-hungry pod. Karpenter will provision new nodes.
kubectl create deployment karpenter-demo \
  --image=public.ecr.aws/eks-distro/kubernetes/pause:3.10 \
  --replicas=50

kubectl set resources deployment/karpenter-demo --requests=cpu=500m

# Watch nodes appear (typically ~60 seconds from pod submission).
watch kubectl get nodes -l karpenter.sh/nodepool

# Tear down — consolidation removes the nodes within ~30 seconds of the
# last pod evicting.
kubectl delete deployment karpenter-demo
watch kubectl get nodes -l karpenter.sh/nodepool
```

**Inspecting decisions.** `kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter` is your friend. Karpenter's structured logs name every node it provisions, why, and what cost band it picked.

---

## 8. Teardown

Always teardown via `make full-cleanup`. It runs:

1. **`cleanup-pre-destroy.sh`** — drains `Service type=LoadBalancer` (so the LB controller removes its ALBs/NLBs), drains `PersistentVolumeClaim` (so EBS-CSI deletes the EBS volumes), scales the Karpenter controller to zero, cordons and deletes Karpenter-managed nodes, deletes the `NodePool` and `EC2NodeClass`.
2. **`terraform destroy`** — tears down everything in Terraform state.
3. **`cleanup-verify.sh`** — runs through 11 AWS-CLI checks. Exits 0 only when all are clean.

```bash
make full-cleanup
```

Why this order matters: `terraform destroy` knows about VPCs and node groups but not about the EC2 instances Karpenter created, the EBS volumes the CSI driver created, or the ALBs the LB controller created. Without the pre-destroy drain, the VPC delete will hang on dependent ENIs, you'll get half-destroyed state, and you'll be left chasing orphans manually.

If you really do want to skip the drain (because the cluster is already partially gone, say), `make down` works on its own — `cleanup-pre-destroy.sh` exits 0 gracefully if it can't reach the API server.

---

## 9. What happens if cleanup fails

Common failure modes and the manual escape hatch for each:

- **`terraform destroy` hangs on the VPC.** Almost always an LB controller ENI you didn't drain. Run `cleanup-pre-destroy.sh` again, then retry destroy. If the controller is already deleted, find the orphan ENI: `aws ec2 describe-network-interfaces --filters "Name=description,Values='ELB *'" --query 'NetworkInterfaces[].NetworkInterfaceId'` and `aws ec2 delete-network-interface --network-interface-id eni-xxx`.
- **Orphan NLB / ALB.** `make verify-cleanup` will name them. Delete with `aws elbv2 delete-load-balancer --load-balancer-arn <ARN>` (or `aws elb delete-load-balancer --load-balancer-name <NAME>` for classic).
- **Orphan EBS volume in `available` state.** `aws ec2 delete-volume --volume-id vol-xxx`. If it's `in-use`, find the instance: `aws ec2 describe-volumes --volume-ids vol-xxx --query 'Volumes[].Attachments'` and terminate that instance first.
- **Orphan EC2 instance tagged with the cluster.** Karpenter usually catches these via the interruption-queue, but if its controller was already gone: `aws ec2 terminate-instances --instance-ids i-xxx`.
- **Stuck NAT gateway in `deleting` state.** Normal — takes 1-5 minutes. Re-run `make verify-cleanup` until it clears.
- **IAM role with the cluster prefix.** `aws iam list-attached-role-policies --role-name <NAME>`, detach each, `aws iam delete-role --role-name <NAME>`.
- **KMS alias still present.** Expected. The encryption key is in a 7-30 day pending-delete window; the alias detaches but lingers. Safe to ignore, or `aws kms delete-alias --alias-name alias/eks/<CLUSTER>-...`.
- **Log group still present.** Terraform doesn't delete `/aws/eks/<CLUSTER>/*` log groups by default. Delete with `aws logs delete-log-group --log-group-name /aws/eks/<CLUSTER>/cluster`.

When in doubt, re-run `make verify-cleanup`. It enumerates every check.

---

## 10. Production hardening checklist

This deploy is dev-grade. To move it to production, walk this list:

- **NAT gateway** — `single_nat_gateway = false`. Multi-AZ NAT removes a single-zone failure mode (and costs ~$66/month extra).
- **API endpoint** — `cluster_endpoint_public_access = false`, or lock `cluster_endpoint_public_access_cidrs` to your office/VPN egress range. Public + `0.0.0.0/0` is a footgun; if your IAM ever leaks, the attacker can directly hit the API server.
- **System node group sizing** — `t3.medium` is enough for the controllers we host. If you add more cluster-critical workloads (Prometheus, Fluent Bit, OPA Gatekeeper, …), bump to `m6i.large` or larger.
- **EKS audit logs** — already on. Set a CloudWatch retention policy: `aws logs put-retention-policy --log-group-name /aws/eks/<CLUSTER>/cluster --retention-in-days 90`.
- **KMS key rotation** — the EKS module enables automatic rotation on the cluster encryption key by default. Confirm with `aws kms describe-key --key-id <KEY> --query 'KeyMetadata.KeyRotationStatus'`.
- **Budget alarms** — `aws budgets create-budget --account-id <ID> --budget '{"BudgetName":"bookstore-platform","BudgetType":"COST","BudgetLimit":{"Amount":"500","Unit":"USD"},"TimeUnit":"MONTHLY"}'`.
- **Karpenter sanity bounds** — `karpenter_general_cpu_limit` / `karpenter_general_memory_limit` in variables.tf. Don't trust your HPAs not to runaway.
- **Container image scanning** — turn on ECR image scanning on push (`aws ecr put-image-scanning-configuration --repository-name <REPO> --image-scanning-configuration scanOnPush=true`).
- **Pod Security** — apply the `restricted` Pod Security Standard at the namespace level for everything except `kube-system`.
- **Backup / DR** — Velero or AWS Backup for EBS-backed PVCs; etcd snapshots come "free" with EKS (managed automatically).

---

## 11. Optional / opt-in features (Phase 14 additions)

Every feature below is **var-gated and OFF by default**. The base deploy doesn't include any of them; flip the flag to opt in.

### Encryption philosophy (KMS choice across this tree)

The tree uses two different KMS strategies depending on the artifact's blast radius and lifetime:

- **AWS-managed keys (`alias/aws/sns`, `alias/aws/s3`)** for short-lived signal queues — Budget alert SNS topics, Falco alert SNS topics. The data is ephemeral (alert payload, immediately consumed), the blast radius if the key were compromised is low (an attacker could decrypt a notification they could already get from the source). AWS-managed keys are free, get automatic rotation, and require zero key-policy maintenance from you.
- **Customer-managed CMKs** for long-lived data buckets — CloudTrail logs, AWS Config history, Velero backups, EKS Secrets envelope encryption. The data is forensically valuable years after creation; the key policy is the chokepoint that controls who can read it. A CMK gives you an explicit allow-list of principals, custom rotation schedules, and the ability to deny decrypt by removing yourself from the key policy in an incident.

Tier 1+ feature additions that create new resources should follow this rule: if it's a signal/notification path, AWS-managed key is fine; if it's audit/backup/secrets, create a CMK + alias.


### CloudWatch log retention

`cloudwatch_log_group_retention_in_days` (default `30`). The EKS module creates `/aws/eks/<cluster>/cluster`; this attribute caps how long the audit/api/scheduler logs live. Cost ~$0.03/GB-month — small enough you'll never notice on a sane retention, large enough to ruin your day at infinite retention. Bump to `90` for ops debugging or `365`/`3653` for compliance.

### Cost-budget alarm

```hcl
enable_budget_alarm = true
monthly_budget_usd  = 100
budget_alarm_email  = "platform-team@example.com"
```

Creates an `aws_budgets_budget` + KMS-encrypted SNS topic + email subscription. Fires at 80% forecast and 100% actual. AWS Budgets is free for the first 2 budgets per account. **Caveat:** AWS sends a confirmation link to the email; nothing flows until the subscriber clicks it.

### VPC endpoints

```hcl
enable_vpc_endpoints = true
```

Adds an S3 gateway endpoint (free) + interface endpoints for `ecr.api`, `ecr.dkr`, `sts`, `ec2`, `logs`, `kms` (~$0.01/hr per AZ each, plus $0.01/GB data). Break-even vs NAT: around 50 GB/month of pulled images + AWS API traffic. Long-lived clusters almost always pay off.

### Graviton (arm64) NodePool

```hcl
enable_graviton_pool = true
```

Adds a Karpenter NodePool that requires `arm64` and picks from c7g/m7g/r7g families. 20-40% cheaper than equivalent x86 with no perf penalty for most stateless workloads. **Container images must be multi-arch or arm64-only** — verify with `docker manifest inspect <image>` before enabling.

### Argo CD bootstrap

```hcl
enable_argocd_bootstrap = true
argocd_repo_url         = "https://github.com/your-org/platform-gitops"
argocd_root_app_path    = "argocd/apps"
```

Installs Argo CD `7.7.x` + creates a root `Application` (App-of-Apps pattern) that points at the given repo+path. After apply: port-forward `argo-cd-server`, log in as `admin` with the password from `kubectl -n argocd get secret argocd-initial-admin-secret`. The chicken-and-egg is solved here: Terraform brings up the controller; Argo CD takes it from there.

### Velero backups

```hcl
enable_velero = true
velero_backup_bucket = ""  # auto-named when empty
```

Creates a versioned + KMS-encrypted S3 bucket, an IRSA role for Velero with S3 + EBS snapshot perms, the Velero `7.2.x` Helm release in its own `velero` namespace, and a daily Schedule with 30-day retention. Drill: `velero backup create test --include-namespaces test-ns && velero restore create --from-backup test`. Document the runbook with your team before relying on it.

### Falco runtime detection

```hcl
enable_falco = true
falco_alert_email = "security@example.com"  # optional
```

Installs Falco `4.13.x` with the modern eBPF driver. **PSA exception:** Falco's daemonset needs `CAP_BPF + CAP_PERFMON + CAP_SYS_ADMIN` to attach kernel eBPF programs — its namespace (`falco`) runs `pod-security.kubernetes.io/enforce: privileged`. This is the only privileged namespace in the entire tree, documented in `falco.tf`. Output is JSON on stdout (picked up by your log shipper). Optional SNS topic + email subscription.

### Kyverno image-signing policy

```hcl
enable_image_signing          = true
image_signing_keyless_issuer  = "https://token.actions.githubusercontent.com"
image_signing_keyless_subject = "https://github.com/your-org/.+"
```

Installs Kyverno `3.3.x` + a `ClusterPolicy` named `require-signed-images` that uses cosign keyless verification. **Default `validationFailureAction: Audit`** — warns in PolicyReports but does NOT block Pod creation. Run for 2-4 weeks, fix every flagged image, THEN flip to `Enforce`. Excluded namespaces: `kube-system`, `kyverno`, `falco`, `velero`, `argocd`, `bookstore-platform-system`.

### Vault + ESO for production secrets

```hcl
enable_vault            = true
enable_external_secrets = true
vault_replicas          = 3       # 1 for dev, 3 for production, 5 for very-large
vault_storage_size      = "10Gi"  # per-replica Raft PVC
```

Installs HashiCorp Vault `0.30.x` (app version 1.18.x) as a 3-replica Raft cluster + External Secrets Operator `0.10.x` as the bridge from Vault values into K8s Secrets. Vault auto-unseals via an AWS KMS CMK (no manual Shamir-key drama on pod restart). Forward-ref: **Part 15 ch.15.05** walks the end-to-end wiring — `ClusterSecretStore` CR pointing at Vault, `ExternalSecret` CRs in app namespaces, rotation semantics, and the Vault-policy-per-K8s-role pattern.

**When to enable:**
- You have static credentials (DB passwords, API keys, signing keys) living in `kubectl create secret`-managed `Secret` objects today and want them rotated automatically.
- You want a single audit trail for who-read-what-secret-when (Vault's audit log).
- You need dynamic secrets (per-lease database credentials, short-lived AWS STS sessions via Vault's AWS engine) — a K8s Secret can't do this.

**HA vs non-HA tradeoff:**
- `vault_replicas = 3` (default): production. Raft quorum = 2 — survives one pod loss without losing service. 3x EBS volumes, 3x pod resources.
- `vault_replicas = 1`: dev/smoke-test. No quorum, no Raft consensus, restarts cause a brief window of "sealed, waiting on KMS unseal". Cheaper, simpler, do not use for anything you'd cry over losing.

**Cost (HA mode, ap-south-1):**
- 3x Vault pods on existing Karpenter/system nodes (no extra EC2 bill).
- 3x EBS gp3 volumes at `vault_storage_size` (~$0.80/month for 10Gi each).
- 1x KMS CMK for unseal (~$1/month + a few cents in API calls).
- ESO controller pods (~free; runs as 2 small replicas).
- **Total: ~$4-5/month additive over the base cluster.**

**KMS key safety:** the unseal CMK has `prevent_destroy = true` in `vault.tf`. Losing the key = losing your sealed data. Document the key ARN (`terraform output vault_kms_key_arn`) in your DR runbook before a real workload depends on Vault.

**TLS posture (intra-cluster plaintext by default):** the Vault Helm release ships with `global.tlsDisable = true` and the Raft listener with `tls_disable = 1`. Vault traffic is plaintext on the wire; the encryption boundary is the cluster mesh (Istio / Cilium WireGuard) plus the ClusterIP-only Service that keeps the API off public networks. To expose Vault via Ingress or an NLB, you must flip both knobs in lockstep — provision a server cert via cert-manager, mount it through `server.extraVolumes`, set `global.tlsDisable = false`, and add `tls_cert_file` / `tls_key_file` to the listener block. The TLS POSTURE banner at the top of `vault.tf` walks the exact change set. Until that's wired, leave the defaults alone — they're internally consistent, and mismatching them puts the pod into a CrashLoop.

**`disable_mlock = true`:** `disable_mlock = true` is set in the Vault HCL config because Kubernetes' kubelet doesn't swap pod memory anyway, and enabling mlock would require `CAP_IPC_LOCK` (incompatible with PSA `restricted`, which drops all capabilities). This is HashiCorp's documented K8s-hardening guidance — there's nothing for mlock to lock against in a non-swap pod environment.

**`enable_vault` vs `enable_external_secrets` (independent flags):** these two booleans control separate add-ons; the typical combinations are: (a) **both true** — Vault as ESO's backend store (the most powerful setup, dynamic secrets + rotation + audit, the default for the Bookstore Platform); (b) **Vault true, ESO false** — Vault accessed directly via SDK/CLI from pods (rare in K8s, usually only for `vault` CLI bootstrap workflows); (c) **Vault false, ESO true** — ESO connects to AWS Secrets Manager / SSM Parameter Store / GCP Secret Manager / Azure Key Vault etc. (simpler, no self-hosted secret store to operate). The `vault.tf` and `external-secrets.tf` files are decoupled — flipping one flag doesn't move the other.

**Fully destroying Vault (KMS lifecycle dance):** `terraform destroy` will FAIL on the unseal CMK because of `lifecycle { prevent_destroy = true }` in `vault.tf`. This is intentional — losing the unseal CMK loses Vault's sealed data forever. To do a full destroy: (1) edit `vault.tf` to comment out the `lifecycle { prevent_destroy = true }` block on `aws_kms_key.vault_unseal`; (2) `terraform apply` to remove the lifecycle protection (no other change); (3) `terraform destroy` proceeds normally; (4) note the CMK still enters a 30-day deletion window in AWS — cancel via `aws kms cancel-key-deletion` if you change your mind within the window.

**What this Terraform does NOT install (intentionally):**
- `ClusterSecretStore` CRs — these are user-namespace concerns + Argo CD's job. Part 15 ch.15.05 has the manifests.
- Vault policies, K8s auth method config, role bindings — bootstrapped by an out-of-band `vault` CLI run after first apply (also covered in ch.15.05).
- Vault file audit device — the audit PVC is mounted but `vault audit enable file path=/vault/audit/audit.log` must be run after init+unseal (one of the first ops bootstrap commands, documented in ch.15.05 and as an inline `auditStorage` comment in `vault.tf`).
- The Vault CSI provider — we use ESO instead (one controller per cluster, no per-pod webhook overhead).

### Cilium CNI (replaces VPC-CNI) — `.tf.example` only

`cilium-installation.tf.example` is shipped as `.tf.example` because switching CNIs is a major operational change. Rename to `.tf` ONLY after reading the file's top-of-file warning, draining nodes, and testing in staging. PSA exception again (Cilium needs `NET_ADMIN + BPF + SYS_ADMIN`).

### GitHub Actions workflow

`.github/workflows/terraform.yml` is a template: copy to your real repo, set `secrets.AWS_ROLE_ARN` and `vars.AWS_REGION`. Uses OIDC (no long-lived access keys). Plans on PR; applies on push-to-main.

### Nightly drift detection

`drift-check/nightly-drift.yml` runs `terraform plan -detailed-exitcode` at 03:00 UTC. Exit code 2 (drift) → opens an issue. Companion `drift-check/atlantis.yaml.example` for Atlantis users. `drift-check/DRIFT.md` is the runbook for "I got a drift alert, what do I do?".

### Multi-region scaffolding

`multi-region/` is a separate sub-directory that wraps the cluster-substrate into a module and instantiates it once per region in `var.regions`. Route 53 LBR, CNPG cross-region replication, and ApplicationSet generators are intentionally LEFT AS TODO comments in `multi-region/main.tf` — see `multi-region/README.md` for the wiring story.

### Account-baseline (separate tree)

`../terraform-account-baseline/` is a sibling tree (separate state!) for per-account services: GuardDuty, Security Hub, Config, CloudTrail, IAM Access Analyzer. Each is gated by its own variable; all default OFF. ~$30-100/month with everything on (Config is the bulk).

### infracost integration

`make plan-cost` produces a `terraform plan` + an `infracost breakdown`. Falls back to a plain plan if infracost isn't installed (`brew install infracost`).

---

## 12. Cross-references

- **Part 10 ch.01** — EKS architecture deep dive. Reads the same control-plane / node-group story this README skims.
- **Part 10 ch.06** — Karpenter chapter. NodePool/EC2NodeClass semantics, consolidation policies, disruption budgets — everything `karpenter-pools.tf` actually configures.
- **Part 13 ch.03** — Multi-region. This deploy is single-region; the multi-region chapter walks the topology delta (Route53 latency routing, replicated state, cross-region failover drills).
- **Part 13 ch.13.10** — Cost. The OpenCost / CloudCost story this deploy can feed. Karpenter's tagging is set up to attribute spend by `NodePool` and pool label (`bookstore-platform.example.com/pool`).
- **`../argocd/`** — Argo CD bootstrap; the application workloads that run on top of this cluster.
- **`../platform-base/`** — namespace + RBAC + PSA + NetworkPolicy baselines applied by Argo CD before any tenant workload lands.
