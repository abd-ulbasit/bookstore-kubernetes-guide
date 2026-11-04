# Cloud NAT for private nodes. Nothing here exists unless private_nodes = true.
#
# Nodes with no public IP cannot reach Docker Hub or any other external
# registry on their own, and verify.sh pulls nginx, curl and busybox from
# there; Google says private nodes need Cloud NAT to pull from an external
# registry, so expect ImagePullBackOff without it. Cloud NAT is priced per
# VM per hour, per GiB processed, and per external IP the gateway uses,
# which is why it is behind a variable that defaults to off.

resource "google_compute_router" "nat" {
  count = var.private_nodes ? 1 : 0

  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.lab.id
}

resource "google_compute_router_nat" "nat" {
  count = var.private_nodes ? 1 : 0

  name   = "${var.cluster_name}-nat"
  region = var.region
  router = google_compute_router.nat[0].name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
