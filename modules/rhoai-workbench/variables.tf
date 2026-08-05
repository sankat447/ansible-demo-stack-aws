variable "namespace" {
  type    = string
  default = "aiops-notebooks"
}

variable "db_host" {
  type      = string
  sensitive = true
}

variable "vector_db" {
  description = "Credentials for the `aiops` logical DB (pgvector) from modules/aurora-db."
  type = object({
    database = string
    username = string
    password = string
  })
  sensitive = true
}

variable "portkey_endpoint" {
  type = string
}

variable "llm_model_name" {
  type = string
}
