output "aap_controller_url" {
  value = module.aap.controller_url
}

output "aap_starting_csv" {
  description = "deploy.sh phase 2 approves exactly this CSV's InstallPlan."
  value       = var.aap_starting_csv
}

output "aap_hub_url" {
  value = module.aap.hub_url
}

output "eda_url" {
  value = module.aap.eda_url
}

output "lightspeed_endpoint" {
  description = "In-cluster only — playbooks and notebooks use this."
  value       = module.lightspeed.endpoint
}

output "gitea_url" {
  value = "https://gitea-aiops-collab.${var.cluster_apps_domain}"
}

output "mattermost_url" {
  value = "https://mattermost-aiops-collab.${var.cluster_apps_domain}"
}

output "demo_app_url" {
  value = "https://demo-httpd-aiops-demo-app.${var.cluster_apps_domain}"
}
