variable "namespace" {
  type    = string
  default = "aap"
}

variable "channel" {
  description = "OLM channel — pinned, never 'latest'."
  type        = string
}

variable "starting_csv" {
  description = "Exact operator CSV to install (reproducibility)."
  type        = string
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "db_host" {
  type      = string
  sensitive = true
}

variable "db_credentials" {
  description = "Map with keys aap, hub, eda → { database, username, password } from modules/aurora-db."
  type = map(object({
    database = string
    username = string
    password = string
  }))
  sensitive = true
}

variable "cluster_apps_domain" {
  type = string
}

variable "controller_name" {
  type    = string
  default = "aap-controller"
}

variable "hub_name" {
  type    = string
  default = "aap-hub"
}

variable "eda_name" {
  type    = string
  default = "aap-eda"
}

variable "hub_storage_class" {
  description = "RWX storage class for Automation Hub content (base stack provides efs-sc). Lesson L3: never mutate an existing SC."
  type        = string
  default     = "efs-sc"
}
