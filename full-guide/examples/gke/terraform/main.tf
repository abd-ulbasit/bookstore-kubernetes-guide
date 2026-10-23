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
# gets the minimum a GKE node needs (logs, metrics, metadata:
# roles/container.defaultNodeServiceAccount) plus read-only image pulls
# from Artifact Registry in this project. Workloads that need more get it
# through Workload Identity, never through the node.
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

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Workload Identity is the GCP equivalent of EKS IRSA: pods authenticate as
  # Google service accounts without a static key on disk. This is the single
  # most transferable GKE-specific concept for a platform interview.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  # Cost guard: without this, the cluster autoscaler is off and a runaway
  # workload simply goes Pending rather than silently provisioning nodes.
  # Left off deliberately for a lab; turn it on in the autoscaling chapter.

  resource_labels = local.labels

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

resource "google_container_node_pool" "primary" {
  name     = "${var.cluster_name}-pool"
  cluster  = google_container_cluster.lab.id
  location = var.zone

  node_count = var.node_count

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

    labels = local.labels

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Nodes must not boot before their account can write logs and pull images.
  depends_on = [google_project_iam_member.nodes]
}
