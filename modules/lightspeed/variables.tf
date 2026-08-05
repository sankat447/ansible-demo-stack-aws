variable "namespace" {
  description = "Deploy alongside AAP so the generator job templates reach it as lightspeed.<ns>.svc."
  type        = string
}

variable "provider_choice" {
  description = "'portkey' (self-hosted llama via the base stack's Portkey gateway) or 'redhat' (Content Provider API)."
  type        = string
}

variable "api_key" {
  description = "Red Hat Content Provider key — only for provider_choice = 'redhat'."
  type        = string
  sensitive   = true
  default     = ""
}

variable "portkey_endpoint" {
  type = string
}

variable "model_name" {
  type = string
}

variable "redhat_endpoint" {
  description = "Red Hat Ansible Lightspeed content provider endpoint."
  type        = string
  default     = "https://c.ai.ansible.redhat.com"
}

variable "proxy_image" {
  # Pinned to a real date-stamped tag (registry.access has no simple
  # version tags for this image; verified via /v2/.../tags/list).
  type    = string
  default = "registry.access.redhat.com/ubi9/nginx-124:1-1756913337"
}
