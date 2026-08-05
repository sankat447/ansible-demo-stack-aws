variable "aurora_endpoint_ssm_param" {
  type = string
}

variable "aurora_master_password_ssm_param" {
  type = string
}

variable "aurora_master_username" {
  type = string
}

variable "databases" {
  description = "Logical databases to ensure in the EXISTING Aurora cluster (never a new cluster). Key = db name; owner role is <name>_app."
  type = map(object({
    extensions = optional(list(string), [])
  }))
}

variable "psql_image" {
  description = "Image for the in-cluster bootstrap Job. Pin a digest at first deploy (see LESSONS_LEARNED)."
  type        = string
  default     = "quay.io/sclorg/postgresql-15-c9s:c9s"
}
