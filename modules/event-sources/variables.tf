variable "namespace" {
  type    = string
  default = "aiops-events"
}

variable "enable_alertmanager_source" {
  type = bool
}
