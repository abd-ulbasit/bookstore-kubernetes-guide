################################################################################
# vpc-endpoints.tf — optional VPC endpoints to keep east-west traffic off NAT.
#
# Default OFF. Enable with `enable_vpc_endpoints = true`.
#
# Cost math (rule of thumb):
#   - S3 gateway endpoint: free.
#   - Interface endpoints: ~$0.01/hr × per AZ × number of services + $0.01/GB
#     data processed.
#   - NAT alternative: $0.045/hr per NAT + $0.045/GB data processed.
#
#   Break-even is around 50 GB/month of NAT data. Pulling 5 GB of ECR images
#   per cluster reboot adds up fast; cross-AZ DataDog/observability exports do
#   too. For a long-lived cluster, endpoints almost always pay off.
#
# Endpoints created when enabled:
#   - com.amazonaws.<region>.s3 (gateway)
#   - com.amazonaws.<region>.ecr.api    (image pull metadata)
#   - com.amazonaws.<region>.ecr.dkr    (image pull data plane)
#   - com.amazonaws.<region>.sts        (IRSA assume-role traffic)
#   - com.amazonaws.<region>.ec2        (Karpenter EC2 API calls)
#   - com.amazonaws.<region>.logs       (CloudWatch log push)
#   - com.amazonaws.<region>.kms        (envelope-encryption operations)
################################################################################

locals {
  vpc_endpoint_interface_services = [
    "ecr.api",
    "ecr.dkr",
    "sts",
    "ec2",
    "logs",
    "kms",
  ]
}

################################################################################
# Endpoint security group — allows 443 from inside the VPC. No egress lockdown
# needed; this SG is only attached to ENIs the endpoint service creates.
################################################################################
resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_vpc_endpoints ? 1 : 0

  name        = "${local.name_prefix}-vpc-endpoints"
  description = "443/tcp from VPC for interface VPC endpoints (ECR/STS/EC2/Logs/KMS)."
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    description = "Endpoint responses (stateful return traffic)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc-endpoints"
  })
}

################################################################################
# S3 gateway endpoint — free. Associated with the private + intra route tables
# so traffic to s3.<region>.amazonaws.com bypasses NAT entirely.
################################################################################
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.intra_route_table_ids)

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-s3-gw"
  })
}

################################################################################
# Interface endpoints — one per service per AZ. Private DNS makes the AWS SDK
# automatically prefer the endpoint over the public service URL.
################################################################################
resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_vpc_endpoints ? toset(local.vpc_endpoint_interface_services) : toset([])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-${replace(each.value, ".", "-")}"
  })
}
