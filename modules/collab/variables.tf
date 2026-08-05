variable "namespace" {
  type    = string
  default = "aiops-collab"
}

variable "db_host" {
  type      = string
  sensitive = true
}

variable "mattermost_db" {
  type = object({
    database = string
    username = string
    password = string
  })
  sensitive = true
}
