################################################################################
# example.tfvars — copy to a private file (NOT committed, see .gitignore) and
# override the values that matter for your account/region. Then:
#
#   terraform plan  -var-file=my.tfvars
#   terraform apply -var-file=my.tfvars
#
# Or just edit variables.tf defaults if you only have one environment.
################################################################################

# REQUIRED: pick an AWS region close to your users.
region = "us-east-1"

# Cluster name doubles as the Karpenter discovery tag and the IAM role prefix.
# Must be unique per AWS account+region.
cluster_name = "bookstore-platform"

# Pinned Kubernetes version. The standard-support window for 1.35 ends
# 2027-03-27 — see README §3 for the bump procedure.
kubernetes_version = "1.35"

# Network sizing. 3 AZ + /16 VPC is overkill for dev but matches production.
az_count = 3
vpc_cidr = "10.0.0.0/16"

# Cost knob: single NAT saves ~$33/month per omitted NAT. Flip to false in
# production so a single-AZ NAT failure doesn't take down the cluster.
single_nat_gateway = true

# Endpoint exposure. Leave public + 0.0.0.0/0 for dev; lock down for prod.
cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

# System node group — tiny, hosts Karpenter / LB controller / CoreDNS / etc.
# Application pods land on Karpenter-provisioned nodes.
system_node_instance_types = ["t3.medium"]
system_node_desired_size   = 2
system_node_min_size       = 2
system_node_max_size       = 4

# Karpenter NodePools.
enable_spot_pool = true # Set false for steady-state production workloads.

# Extras.
enable_lb_controller  = true
enable_metrics_server = true

# Tags applied on top of locals.common_tags.
tags = {
  Owner       = "platform-team"
  Environment = "dev"
  CostCenter  = "engineering"
}
