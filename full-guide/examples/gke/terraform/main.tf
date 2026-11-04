# A deliberately small, destroy-safe GKE lab.
#
# Design notes that are load-bearing, each one a thing that only surfaces when
# you actually run this rather than write about it:
#
#  1. ZONAL, not regional. The GKE free-tier credit applies only to a zonal or
#     Autopilot cluster; a regional cluster's management fee is not covered.
#  2. deletion_protection = false. The google provider defaults this to TRUE
#     from v5 onward, and with the default `terraform destroy` FAILS. This is
#     the single most common reason a "spin up, tear down" lab quietly becomes
#     a permanent bill.
#  3. Default node pool removed and replaced by a managed one, so node config
#     changes do not force a cluster replacement.
#  4. Logging/monitoring trimmed to SYSTEM_COMPONENTS. The default also ships
#     WORKLOADS, and Cloud Logging ingestion is billed per GiB; a chatty lab
#     cluster can out-spend its own nodes.
#  5. Nodes run as a DEDICATED service account with only the node roles, not
#     as the Compute Engine default service account (which has Editor on the
#     project unless your org disabled that grant).

locals {
  labels = {
    purpose    = "kubernetes-lab"
    managed-by = "terraform"
    teardown   = "expected-daily"
  }
}

resource "google_compute_network" "lab" {
  name                    = "${var.cluster_name}-net"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "lab" {
  name          = "${var.cluster_name}-subnet"
  network       = google_compute_network.lab.id
  region        = var.region
  ip_cidr_range = "10.10.0.0/20"

  # VPC-native clusters need pods and services in secondary ranges. Sizing these
  # too small is a cluster you cannot grow, and they cannot be resized later.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# Node identity. Every node, and any pod that can reach the metadata server
# without Workload Identity, acts as this account. The Compute Engine
# default SA usually holds roles/editor on the whole project, so a node on
# it is one container escape away from project-wide write. This account
# gets the minimum a GKE node needs (write logs and metrics, list metric
# descriptors and time series: roles/container.defaultNodeServiceAccount)
# plus read-only image pulls from Artifact Registry in this project.
# Workloads that need more get it through Workload Identity, never through
# the node.
resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE nodes for ${var.cluster_name} (least privilege)"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/container.defaultNodeServiceAccount",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "lab" {
  name     = var.cluster_name
  location = var.zone

  # Terraform manages the node pool separately, so the cluster is created with a
  # throwaway default pool that is immediately removed. That short-lived pool
  # runs as the Compute Engine default SA; setting node_config here to change
  # it would force a cluster replacement on existing labs, for a pool that
  # exists for a few minutes.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Without this, `terraform destroy` errors out and the cluster stays billable.
  deletion_protection = false

  network    = google_compute_network.lab.id
  subnetwork = google_compute_subnetwork.lab.id

  # Dataplane V2 (Cilium-based). Without it GKE runs kube-proxy with no
  # NetworkPolicy enforcement: policies apply cleanly and block nothing, so
  # every policy from Part 05 would be decoration. It can only be set when the
  # cluster is created.
  datapath_provider = "ADVANCED_DATAPATH"

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Workload Identity is the GCP equivalent of EKS IRSA: pods authenticate as
  # Google service accounts without a static key on disk. It is the
  # GKE-specific concept that carries over to other clouds best.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  # A floor, not a pin. On 2026-10-26 GKE added 1.37.1-gke.1552000 to the
  # Regular channel but kept 1.36.4 as its default for new clusters, so
  # without this a new lab gets 1.36. The provider documents the field as
  # the minimum master version: the channel still auto-upgrades the control
  # plane past it, and the node pool too (auto_upgrade = true). Read
  # master_version for what is running. The exact string avoids the
  # spurious diffs the provider warns about for fuzzy versions; it must be
  # a version the channel still offers (gcloud container get-server-config).
  min_master_version = "1.37.1-gke.1552000"

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  # Cost guard: without this, the cluster autoscaler is off and a runaway
  # workload simply goes Pending rather than silently provisioning nodes.
  # Left off deliberately for a lab; turn it on in the autoscaling chapter.

  # Who can reach the PUBLIC control plane endpoint. The default is the whole
  # internet (health checks answer anonymously, everything else wants
  # credentials) plus every Google Cloud public IP. Nodes and pods reach the
  # control plane over internal addresses, so this does not cut them off.
  # The cost is that you must list your own address in authorized_cidrs.
  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false

    dynamic "cidr_blocks" {
      for_each = var.authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = "admin-${cidr_blocks.key}"
      }
    }
  }

  # Refuse NEW RBAC bindings whose subject is system:authenticated (which on
  # GKE includes anyone with a Google account), system:unauthenticated or
  # system:anonymous. GKE's own default bindings to those groups stay.
  # Existing non-default bindings are not removed by turning this on.
  rbac_binding_config {
    enable_insecure_binding_system_authenticated   = false
    enable_insecure_binding_system_unauthenticated = false
  }

  # Private nodes (no public IP) are opt-in: they need Cloud NAT, which bills.
  # Dynamic, so with private_nodes = false the config is exactly what it was
  # before this variable existed.
  dynamic "private_cluster_config" {
    for_each = var.private_nodes ? [1] : []
    content {
      enable_private_nodes = true
    }
  }

  # Application-layer encryption of Secrets with your own Cloud KMS key.
  # Opt-in: it needs a key you create, the KMS API, and an IAM grant.
  dynamic "database_encryption" {
    for_each = var.secrets_kms_key == "" ? [] : [var.secrets_kms_key]
    content {
      state    = "ENCRYPTED"
      key_name = database_encryption.value
    }
  }

  # Binary Authorization is billed per cluster per hour and does nothing
  # until a policy exists, so it is opt-in. See variables.tf.
  dynamic "binary_authorization" {
    for_each = var.enable_binauthz ? [1] : []
    content {
      evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
    }
  }

  resource_labels = local.labels

  lifecycle {
    ignore_changes = [initial_node_count]
  }

  # Fail before the spend starts. Twice a first apply created this cluster
  # and then failed on something that should have come first: the budget on
  # 2026-09-03, and the node role grants on 2026-11-04 (Cloud Resource
  # Manager API disabled). Both left a billable cluster behind. The NAT is
  # here too: with private_nodes the throwaway default pool has no public IP
  # either, so it needs the NAT as much as the real pool does.
  depends_on = [
    google_project_iam_member.nodes,
    google_billing_budget.lab,
    google_compute_router_nat.nat,
  ]
}

resource "google_container_node_pool" "primary" {
  name     = "${var.cluster_name}-pool"
  cluster  = google_container_cluster.lab.id
  location = var.zone

  node_count = var.node_count

  # No public IP on the nodes when private_nodes is set (see nat.tf).
  dynamic "network_config" {
    for_each = var.private_nodes ? [1] : []
    content {
      enable_private_nodes = true
    }
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = 50
    disk_type    = "pd-standard"

    # Spot nodes are much cheaper and can be reclaimed with 30 seconds notice.
    # Handling that is a lab exercise, not a problem.
    spot = var.use_spot

    # Least privilege comes from the SERVICE ACCOUNT, not the scope. Access
    # scopes are a legacy, coarse filter; Google's guidance is the broad
    # cloud-platform scope plus a minimal-IAM service account, which is what
    # this is. (An earlier comment said "least privilege" here while the
    # pool ran as the default compute SA, which is the opposite.)
    service_account = google_service_account.nodes.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Shielded nodes are on by default; Secure Boot is not. It checks the
    # signatures of the boot components (bootloader, kernel) at boot. On
    # Container-Optimized OS it does not change kernel module loading, which
    # that image controls separately.
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = local.labels

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Nodes must not boot before their account can write logs and pull images,
  # nor, with private_nodes, before the NAT that lets them pull anything.
  depends_on = [
    google_project_iam_member.nodes,
    google_compute_router_nat.nat,
  ]
}
