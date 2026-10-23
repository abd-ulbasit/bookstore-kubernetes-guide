################################################################################
# kubeconfig.tf — write a self-contained kubeconfig.yaml to the working
# directory after the cluster comes up. The cleanup scripts use this directly
# (KUBECONFIG=./kubeconfig.yaml) so they work without `aws eks update-kubeconfig`.
#
# The kubeconfig uses the AWS CLI v1/v2 `aws eks get-token` exec plugin (the
# same one `aws eks update-kubeconfig` writes). This requires the AWS CLI to
# be on the operator's PATH when they `kubectl` against the cluster — which
# they need anyway to install the cluster.
#
# Laptop only. var.write_kubeconfig (default true) gates it; CI and the
# drift check set it false. The file lives in the working directory of
# whoever applied, so on a fresh CI runner it is always missing: refresh
# then drops it from state, every plan re-creates it (no plan is ever
# empty), and `plan -refresh-only` reports it as drift every night.
################################################################################

locals {
  kubeconfig_yaml = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = module.eks.cluster_name

    clusters = [
      {
        name = module.eks.cluster_name
        cluster = {
          server                     = module.eks.cluster_endpoint
          certificate-authority-data = module.eks.cluster_certificate_authority_data
        }
      },
    ]

    contexts = [
      {
        name = module.eks.cluster_name
        context = {
          cluster = module.eks.cluster_name
          user    = module.eks.cluster_name
        }
      },
    ]

    users = [
      {
        name = module.eks.cluster_name
        user = {
          exec = {
            apiVersion         = "client.authentication.k8s.io/v1beta1"
            command            = "aws"
            args               = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
            interactiveMode    = "IfAvailable"
            provideClusterInfo = false
          }
        }
      },
    ]
  })
}

resource "local_file" "kubeconfig" {
  count = var.write_kubeconfig ? 1 : 0

  content              = local.kubeconfig_yaml
  filename             = "${path.module}/kubeconfig.yaml"
  file_permission      = "0600"
  directory_permission = "0755"

  depends_on = [
    module.eks,
  ]
}
