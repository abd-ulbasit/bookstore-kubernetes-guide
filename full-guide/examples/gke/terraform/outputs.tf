output "cluster_name" {
  value = google_container_cluster.lab.name
}

output "location" {
  value = google_container_cluster.lab.location
}

output "kubectl_config_command" {
  description = "Run this to point kubectl at the lab cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.lab.name} --zone ${var.zone} --project ${var.project_id}"
}

output "teardown_reminder" {
  value = "terraform destroy when done. Nodes bill per second while the cluster is up."
}
