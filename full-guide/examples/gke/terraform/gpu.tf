# GPU node pool for the Part 17 ML platform labs.
#
# Separate from the CPU pool on purpose, and autoscaled from ZERO so the pool can
# exist permanently while costing nothing until a GPU workload actually lands.
# That matters more here than anywhere else in this repo: a forgotten L4 is an
# order of magnitude more expensive than a forgotten e2-standard-2.
#
# QUOTA, checked 2026-09-03 on this project: asia-south1 has NVIDIA_L4_GPUS = 1 and
# PREEMPTIBLE_NVIDIA_L4_GPUS = 1. That is enough for labs G1, G2, G3, G5, G6 and G7.
# G4 (multi-node distributed training) and a 2-node G8 need a quota increase first.
#
# g2-standard-4 carries one NVIDIA L4 (24 GB). L4 is the right lab GPU: it serves
# a 7B model at fp16 with room for a KV cache, and it is the cheapest GPU on GCP
# that does. Note L4 does NOT support MIG, so the GPU-sharing lab uses
# time-slicing rather than partitioning; A100 and H100 are the MIG-capable parts.

variable "enable_gpu_pool" {
  description = "Create the GPU node pool. Leave false until you have GPU quota."
  type        = bool
  default     = false
}

variable "gpu_machine_type" {
  description = "g2-standard-4 is 1x L4 / 4 vCPU / 16 GB."
  type        = string
  default     = "g2-standard-4"
}

variable "gpu_max_nodes" {
  description = "Ceiling for the autoscaler. Your asia-south1 L4 quota is 1, so 1 is the max that can actually schedule. Raising this without raising quota gives you Pending nodes, not more GPUs."
  type        = number
  default     = 1
}

resource "google_container_node_pool" "gpu" {
  count = var.enable_gpu_pool ? 1 : 0

  name     = "${var.cluster_name}-gpu"
  cluster  = google_container_cluster.lab.id
  location = var.zone

  # Scale to zero when idle. initial_node_count must be 0 to match.
  initial_node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = var.gpu_max_nodes
  }

  node_config {
    machine_type = var.gpu_machine_type
    disk_size_gb = 100 # model artefacts are large; 50 GB fills fast
    disk_type    = "pd-balanced"

    # Spot for cost. A preempted GPU node is itself lab G8.
    spot = var.use_spot

    guest_accelerator {
      type  = "nvidia-l4"
      count = 1

      # Let GKE install and manage the driver. Doing this by hand via the
      # NVIDIA GPU Operator is lab G1's alternative path, and knowing that
      # GKE offers both is the interview-relevant part.
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = merge(local.labels, {
      workload = "gpu"
    })

    # GKE taints GPU nodes automatically with nvidia.com/gpu=present:NoSchedule.
    # Declaring it explicitly keeps Terraform from fighting that default and
    # documents why a CPU pod will never land here.
    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
