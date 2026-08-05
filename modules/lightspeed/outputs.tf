output "endpoint" {
  description = "Stable in-cluster OpenAI-compatible endpoint for playbook generation."
  value       = "http://lightspeed.${var.namespace}.svc:8080"
}
