# Multi-Region Scaffolding

This sub-tree instantiates the Bookstore Platform substrate (VPC + EKS + addons + Karpenter + LB controller) in N regions from a single `terraform apply`. It is **opt-in** — the main `terraform/` tree is single-region by default; you only need this if you're standing up an active-active or active-passive multi-region topology.

---

## What this does

For every region listed in `var.regions`, this stack creates:

- A new VPC (non-overlapping CIDR, see `vpc_cidrs_by_region` defaults).
- An EKS 1.35 cluster with one small managed node group (`system`).
- The full addon set: `vpc-cni` (with `before_compute = true`), `kube-proxy`, `coredns`, `aws-ebs-csi-driver`.
- Karpenter + the `default` EC2NodeClass (matching the main tree).
- The AWS Load Balancer Controller, IRSA-wired.
- A KMS key for secret envelope encryption (one per region — KMS keys are regional).
- CloudWatch log retention pinned to 30 days.

Identical configuration across regions; identical pinned versions. If you bump a version in the main tree, mirror it in `module.tf` here.

---

## What this DOES NOT do

These belong to whoever owns the cross-cluster topology — usually a platform team that's already deployed the substrate and wants to wire the global pieces themselves:

1. **Route 53 Latency-Based Routing.** The main tree creates ALBs per cluster; cross-region traffic routing is a global concern. Wire `aws_route53_record` with `latency_routing_policy { region = "<region>" }` for each per-region ALB DNS name, then point your apex (`api.bookstore.example.com`) at the LBR alias set. Health checks (`aws_route53_health_check`) make the failover automatic.

2. **CNPG cross-region replication.** The CloudNativePG operator supports `spec.replica.source` for asynchronous streaming replication. The pattern: one primary region (write traffic), N replica regions (read-only). When the primary fails, you promote a replica via a CNPG `Cluster.spec.bootstrap.recovery.source` flip. The replica clusters need network reachability to the primary's CNPG endpoint — that's a Transit Gateway peering you stand up out-of-band, NOT in this Terraform.

3. **ApplicationSet over Cluster generator.** One Argo CD instance (running in your "control region") owns the deployment lifecycle of every other cluster. You register the per-region clusters as Argo CD `Secret` objects with `argocd.argoproj.io/secret-type: cluster`; an `ApplicationSet` with `generators: [{ cluster: {} }]` enumerates them and templates one Application per cluster. The Argo CD install lives in the main tree (`enable_argocd_bootstrap = true`); the cluster-registration secrets are typically committed to Git and synced by Argo CD's own root app.

The TODO comments inside `main.tf` mark the exact spots where each of these pieces wires in.

---

## Usage

### Step 0 — who becomes cluster admin

`cluster-module/main.tf` passes `enable_cluster_creator_admin_permissions = true` to the upstream EKS module. **The principal who runs `terraform apply` becomes cluster-admin on every cluster this stack creates** — that's N admin grants, not one.

What this means in practice:

- **Local applies (your laptop).** Your IAM identity becomes admin on all N clusters. Fine for solo dev work; check the cluster names with `aws sts get-caller-identity` before you apply.
- **CI applies (GitHub Actions / Atlantis).** The CI role assumed via OIDC becomes admin on all N clusters. That role's trust policy and inline permissions are now the security boundary — keep it scoped to a specific repo + branch + environment, NOT `repo:org/repo:*`. (`.github/workflows/terraform.yml` in the parent tree has a template for this.)
- **Shared platform team.** Run this Terraform under a role that the **whole platform team** can assume (e.g. via AWS SSO permission set) so admin access is delegated by the SSO group, not by who ran the apply.

If you want to flip this off post-apply: delete the EKS access entry the module creates for `var.cluster_creator_principal_arn`, then re-grant via your normal IRSA + access-entry workflow. There is no way to flip the toggle and have Terraform's plan come out clean — the access entry is what the toggle creates.

### 1. Pick your regions

```hcl
# regions.tfvars
regions = ["us-east-1", "eu-west-1", "ap-southeast-1"]

cluster_name       = "bookstore-platform"
kubernetes_version = "1.35"

vpc_cidrs_by_region = {
  "us-east-1"      = "10.10.0.0/16"
  "eu-west-1"      = "10.20.0.0/16"
  "ap-southeast-1" = "10.30.0.0/16"
}
```

CIDRs **must not overlap** if you plan to peer the VPCs (Transit Gateway, VPC peering, or anything that joins the routing tables). The defaults are non-overlapping `/16`s in the `10.X.0.0/16` band.

### 2. Plan + apply

```bash
terraform init
terraform plan  -var-file=regions.tfvars
terraform apply -var-file=regions.tfvars
```

First apply takes **~22 minutes × N regions**, but they run **in parallel** by default — three regions finish in roughly the time of one. Watch the AWS console for control-plane creation progress per region.

### 3. Configure kubectl

```bash
$(terraform output -json kubeconfig_commands | jq -r '.[]' | while read cmd; do echo "$cmd"; eval "$cmd"; done)

kubectl config get-contexts
# Switch with: kubectl config use-context arn:aws:eks:<REGION>:<ACCT>:cluster/bookstore-platform-<REGION>
```

The `clusters` output is a map keyed by region — convenient for templating into an ApplicationSet, a Terraform module that takes a cluster list, or a doc page.

---

## How the providers are wired

Terraform needs **one statically-declared `provider` block per region**, because providers can't be dynamically generated from a `for_each`. So `main.tf` lists every region we might ever care about and instantiates a module instance gated by `count = contains(var.regions, "...") ? 1 : 0`.

This is verbose by design — Terraform's static-provider model is a deliberate constraint. The cost is some boilerplate; the value is that the provider graph is fully visible to `terraform plan`, which means provider-misconfiguration errors surface at plan time, not apply time.

If you want a region we don't list (e.g. `us-west-2`, `ap-south-1`), add a fourth/fifth provider block + module instance using the existing ones as templates.

---

## Cost note

A 3-region active-active cluster costs roughly **3× the main tree's $180/month** — call it ~$540/month at idle, plus per-region NAT data and the cross-region replication transit. CloudFront in front of the ALB pulls the DNS-routed traffic in cheaper, but transit between regions is still $0.02-0.09/GB depending on path.

The cheapest multi-region topology is **active-standby**: one region with the full workload, others with the cluster substrate up but workload replicas at zero. Karpenter consolidates the standby cluster's nodes to nothing within 30 seconds when there are no pods; you pay only for the control plane + system MNG + NAT.

---

## Bootstrap order (recommended)

1. Stand up this multi-region tree → all clusters are EKS-ready.
2. Set `enable_argocd_bootstrap = true` in **only one cluster** (your control region) via a separate Terraform run or a `argocd-bootstrap.tf` patched in there.
3. Commit cluster-registration `Secret` manifests for every other cluster to your GitOps repo.
4. Argo CD picks them up, registers the clusters, and the `ApplicationSet` templates per-cluster workloads.
5. (Out-of-band, in the cross-region networking module that ISN'T in this tree:) bring up your Transit Gateway, then CNPG can talk across the mesh.
6. Cut DNS over at the Route 53 layer once health checks are passing.

If you can't do step 5 (no Transit Gateway, dev environment), keep step 2 as "ApplicationSet per region with no cross-region state" — each cluster is an island, and you live with that until you grow into the cross-region story.
