# Account Baseline — Terraform

Per-AWS-account security + compliance services. **Separate state file** from `../terraform/`. **Per-account, NOT per-cluster.**

If you run multiple EKS clusters in the same AWS account, you should run this Terraform **once** for the whole account. If you have three accounts (dev / staging / prod), you run this Terraform once per account.

---

## What's in here

Five gated capabilities; each off by default. Toggle per your compliance posture.

| Variable | Service | Cost (est, small account) | Why |
|---|---|---|---|
| `enable_guardduty` | Amazon GuardDuty + EKS Protection | $1-3/month | Anomaly detection across CloudTrail, VPC Flow Logs, DNS, EKS audit |
| `enable_securityhub` | AWS Security Hub + FSBP + CIS v3 + NIST 800-53 r5 | <$5/month | Findings aggregator across GuardDuty/Config/Inspector |
| `enable_config` | AWS Config recorder + S3 bucket | $15-50/month | Resource configuration history + EKS conformance pack |
| `enable_cloudtrail` | Multi-region CloudTrail trail + S3 bucket | Free for management events; data events extra | Forensic API log |
| `enable_iam_access_analyzer` | IAM Access Analyzer (account scope) | Free | Finds resources accessible outside the account |

**All enabled, all month:** ~$30-100/month. The big number is Config; the others combined are <$10.

---

## Why a separate Terraform tree

- **Different blast radius.** A cluster operator's `terraform apply` should never be one typo away from destroying your CloudTrail audit history. Separate state keeps the IAM permissions distinct.
- **Different cadence.** The cluster tree changes monthly (Kubernetes upgrades, addon bumps, new workload IRSA roles). The account baseline changes yearly (compliance review, new framework standards). Two trees, two cadences.
- **Different lifecycle.** Deleting a cluster doesn't delete CloudTrail. Spinning up a test cluster doesn't disturb Security Hub. The split matches the operational reality.

---

## Usage

```bash
# 1) Configure which services to enable.
cat > my.tfvars <<EOF
region                     = "us-east-1"
account_prefix             = "bookstore-platform"

enable_guardduty           = true
enable_securityhub         = true
enable_config              = true
enable_cloudtrail          = true
enable_iam_access_analyzer = true
EOF

# 2) Plan + apply.
make init
terraform plan -var-file=my.tfvars -out=tfplan
make up

# 3) Verify.
aws guardduty list-detectors --region us-east-1
aws securityhub describe-hub --region us-east-1
aws configservice describe-configuration-recorders --region us-east-1
aws cloudtrail describe-trails --region us-east-1
aws accessanalyzer list-analyzers --region us-east-1
```

---

## What the cost buys you

- **Compliance posture.** Most frameworks (SOC 2, PCI-DSS, HIPAA, FedRAMP) require some combination of Config + CloudTrail + a finding aggregator. Security Hub's FSBP + CIS bundle is the "happy path" for a SOC 2 Type II audit.

- **Forensic timeline.** When an incident happens at 14:03 UTC and your incident-response team asks "who did what, from where, with what credentials", CloudTrail's the answer. GuardDuty's findings sometimes name the attacker's source IP before your team even notices the breach.

- **Drift visibility.** Config records resource-state changes; you can query "show me every change to security group sg-abc123 in the last 90 days" and get an answer in seconds. Without Config, you'd grep CloudTrail logs manually.

- **External-access visibility.** IAM Access Analyzer is the cheapest insurance against accidentally-public S3 buckets. Free. Turn it on.

---

## What this DOESN'T cover

- **Per-cluster security.** Pod Security Standards, NetworkPolicies, Kyverno policies, Falco runtime detection — those live in the **cluster** tree (`../terraform/falco.tf`, `../terraform/kyverno-image-signing.tf`), not here.
- **Per-cluster IAM.** IRSA roles for in-cluster workloads live in `../terraform/iam.tf`. This tree only owns account-level IAM (the Config recorder role).
- **Identity / SSO.** AWS IAM Identity Center, SAML federations, Okta integration — those are organizational concerns separate from this stack.
- **WAF / Shield.** Edge protection lives in front of the ALBs the cluster provisions; configure it as part of your CDN/Edge layer (CloudFront, R53), not here.

---

## Teardown

```bash
make down
```

The S3 buckets for Config + CloudTrail are `force_destroy = false`, so destroy will leave history behind on purpose. To fully clean up:

```bash
aws s3 rm   s3://<config-bucket>     --recursive
aws s3 rb   s3://<config-bucket>
aws s3 rm   s3://<cloudtrail-bucket> --recursive
aws s3 rb   s3://<cloudtrail-bucket>
```

Audit logs are usually a "keep forever" artifact. Think before you `rm -rf`.

---

## Cross-references

- Main cluster tree: `../terraform/`
- Drift detection (cluster-side): `../terraform/drift-check/`
- Velero (cluster-side backup): `../terraform/velero.tf`
- Kyverno image signing (cluster-side admission): `../terraform/kyverno-image-signing.tf`
- Falco runtime detection (cluster-side): `../terraform/falco.tf`
