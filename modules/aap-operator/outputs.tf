output "namespace" {
  value = kubernetes_namespace_v1.aap.metadata[0].name
}

output "controller_url" {
  value = "https://${local.controller_host}"
}

output "hub_url" {
  value = "https://${local.hub_host}"
}

output "eda_url" {
  value = "https://${local.eda_host}"
}

output "controller_name" {
  value = var.controller_name
}
