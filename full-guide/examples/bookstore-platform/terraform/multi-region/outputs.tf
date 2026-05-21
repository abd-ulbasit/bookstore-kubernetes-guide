################################################################################
# outputs.tf — surface the per-region cluster identity + kubeconfig recipe.
#
# These maps are keyed by region so downstream consumers (Route 53 records,
# ApplicationSet cluster registration, observability dashboards) can iterate.
################################################################################

output "clusters" {
  description = "Per-region cluster summary: region, name, endpoint, OIDC issuer, VPC ID, CIDR, kubeconfig command. Returns an empty map for regions not in var.regions."
  value = merge(
    contains(var.regions, "us-east-1") ? {
      "us-east-1" = {
        region            = module.cluster_us_east_1[0].region
        cluster_name      = module.cluster_us_east_1[0].cluster_name
        cluster_endpoint  = module.cluster_us_east_1[0].cluster_endpoint
        oidc_provider_arn = module.cluster_us_east_1[0].cluster_oidc_provider_arn
        oidc_issuer_url   = module.cluster_us_east_1[0].cluster_oidc_issuer_url
        vpc_id            = module.cluster_us_east_1[0].vpc_id
        vpc_cidr_block    = module.cluster_us_east_1[0].vpc_cidr_block
        kubeconfig        = module.cluster_us_east_1[0].kubeconfig_command
      }
    } : {},
    contains(var.regions, "eu-west-1") ? {
      "eu-west-1" = {
        region            = module.cluster_eu_west_1[0].region
        cluster_name      = module.cluster_eu_west_1[0].cluster_name
        cluster_endpoint  = module.cluster_eu_west_1[0].cluster_endpoint
        oidc_provider_arn = module.cluster_eu_west_1[0].cluster_oidc_provider_arn
        oidc_issuer_url   = module.cluster_eu_west_1[0].cluster_oidc_issuer_url
        vpc_id            = module.cluster_eu_west_1[0].vpc_id
        vpc_cidr_block    = module.cluster_eu_west_1[0].vpc_cidr_block
        kubeconfig        = module.cluster_eu_west_1[0].kubeconfig_command
      }
    } : {},
    contains(var.regions, "ap-southeast-1") ? {
      "ap-southeast-1" = {
        region            = module.cluster_ap_southeast_1[0].region
        cluster_name      = module.cluster_ap_southeast_1[0].cluster_name
        cluster_endpoint  = module.cluster_ap_southeast_1[0].cluster_endpoint
        oidc_provider_arn = module.cluster_ap_southeast_1[0].cluster_oidc_provider_arn
        oidc_issuer_url   = module.cluster_ap_southeast_1[0].cluster_oidc_issuer_url
        vpc_id            = module.cluster_ap_southeast_1[0].vpc_id
        vpc_cidr_block    = module.cluster_ap_southeast_1[0].vpc_cidr_block
        kubeconfig        = module.cluster_ap_southeast_1[0].kubeconfig_command
      }
    } : {},
    contains(var.regions, "us-west-2") ? {
      "us-west-2" = {
        region            = module.cluster_us_west_2[0].region
        cluster_name      = module.cluster_us_west_2[0].cluster_name
        cluster_endpoint  = module.cluster_us_west_2[0].cluster_endpoint
        oidc_provider_arn = module.cluster_us_west_2[0].cluster_oidc_provider_arn
        oidc_issuer_url   = module.cluster_us_west_2[0].cluster_oidc_issuer_url
        vpc_id            = module.cluster_us_west_2[0].vpc_id
        vpc_cidr_block    = module.cluster_us_west_2[0].vpc_cidr_block
        kubeconfig        = module.cluster_us_west_2[0].kubeconfig_command
      }
    } : {},
    contains(var.regions, "ap-south-1") ? {
      "ap-south-1" = {
        region            = module.cluster_ap_south_1[0].region
        cluster_name      = module.cluster_ap_south_1[0].cluster_name
        cluster_endpoint  = module.cluster_ap_south_1[0].cluster_endpoint
        oidc_provider_arn = module.cluster_ap_south_1[0].cluster_oidc_provider_arn
        oidc_issuer_url   = module.cluster_ap_south_1[0].cluster_oidc_issuer_url
        vpc_id            = module.cluster_ap_south_1[0].vpc_id
        vpc_cidr_block    = module.cluster_ap_south_1[0].vpc_cidr_block
        kubeconfig        = module.cluster_ap_south_1[0].kubeconfig_command
      }
    } : {},
  )
  sensitive = false
}

output "kubeconfig_commands" {
  description = "Shell-friendly list of `aws eks update-kubeconfig` commands, one per region."
  value = concat(
    contains(var.regions, "us-east-1") ? [module.cluster_us_east_1[0].kubeconfig_command] : [],
    contains(var.regions, "eu-west-1") ? [module.cluster_eu_west_1[0].kubeconfig_command] : [],
    contains(var.regions, "ap-southeast-1") ? [module.cluster_ap_southeast_1[0].kubeconfig_command] : [],
    contains(var.regions, "us-west-2") ? [module.cluster_us_west_2[0].kubeconfig_command] : [],
    contains(var.regions, "ap-south-1") ? [module.cluster_ap_south_1[0].kubeconfig_command] : [],
  )
}
