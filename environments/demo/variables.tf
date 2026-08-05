variable "aws_region" {
  description = "Region of the base stack (Aurora, SSM params, state bucket)."
  type        = string
  default     = "us-east-1"
}

variable "kubeconfig_path" {
  description = "Kubeconfig for the existing base cluster. Never provision a cluster from this repo."
  type        = string
  default     = "~/GitHub/ai-demo-stack-aws/environments/demo/ocp-install-dir/ai-demo/auth/kubeconfig"
}

variable "cluster_apps_domain" {
  description = "Apps wildcard domain of the base cluster."
  type        = string
  default     = "apps.ai-demo.iisdemolab.click"
}

variable "gitops_repo_url" {
  description = "This repo's URL — ArgoCD Applications sync from it (lesson L6: only pushed commits take effect)."
  type        = string
  default     = "https://github.com/sankat447/ansible-demo-stack-aws.git"
}

variable "gitops_revision" {
  description = "Git revision ArgoCD tracks."
  type        = string
  default     = "main"
}

# ── Base-stack service addresses (data plane, in-cluster) ──────────────
variable "portkey_endpoint" {
  description = "Portkey AI gateway. ALL LLM calls go through this (lesson L4)."
  type        = string
  default     = "http://portkey.ai-demo.svc:8787"
}

variable "llm_model_name" {
  description = "Model id Portkey routes to for analysis + Lightspeed generation."
  type        = string
  default     = "llama-3-1-8b"
}

variable "aurora_endpoint_ssm_param" {
  type    = string
  default = "/ai-demo/aurora/endpoint"
}

variable "aurora_master_password_ssm_param" {
  type    = string
  default = "/ai-demo/aurora/master-password"
}

variable "aurora_master_username" {
  description = "Master username of the existing Aurora cluster."
  type        = string
  default     = "postgres"
}

# ── AAP ────────────────────────────────────────────────────────────────
variable "aap_channel" {
  description = "OLM channel for the AAP operator. Pinned — no `latest` (rules of engagement)."
  type        = string
  default     = "stable-2.5"
}

variable "aap_starting_csv" {
  description = "Exact CSV to install. Pin for reproducibility; discover with: oc get packagemanifest ansible-automation-platform-operator -o jsonpath='{.status.channels[?(@.name==\"stable-2.5\")].currentCSV}'"
  type        = string
  default     = "aap-operator.v2.5.0-0.1761050204" # verified against this cluster's packagemanifest 2026-08-05
}

variable "aap_admin_password" {
  description = "AAP Controller admin password (Q4 default: base-stack convention)."
  type        = string
  default     = "Demo1234#"
  sensitive   = true
}

# ── Lightspeed ─────────────────────────────────────────────────────────
variable "lightspeed_provider" {
  description = "Playbook-generation backend: 'portkey' (self-hosted llama-3-1-8b via Portkey, Q5 default) or 'redhat' (Content Provider API — requires lightspeed_api_key)."
  type        = string
  default     = "portkey"
  validation {
    condition     = contains(["portkey", "redhat"], var.lightspeed_provider)
    error_message = "lightspeed_provider must be 'portkey' or 'redhat'."
  }
}

variable "lightspeed_api_key" {
  description = "Red Hat Content Provider access key. Only used when lightspeed_provider = 'redhat'; deploy.sh prompts for it."
  type        = string
  default     = ""
  sensitive   = true
}

# ── Event sources (Q6) ─────────────────────────────────────────────────
variable "enable_kafka" {
  description = "Deploy the single-broker demo Kafka (primary lab event source)."
  type        = bool
  default     = true
}

variable "enable_alertmanager_source" {
  type    = bool
  default = true
}

variable "enable_argocd_notifications" {
  type    = bool
  default = true
}
