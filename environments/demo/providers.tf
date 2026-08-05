provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "ai-demo-stack-aiops"
      ManagedBy = "terraform"
      StateKey  = "demo/aiops.tfstate"
    }
  }
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}

provider "kubectl" {
  config_path      = pathexpand(var.kubeconfig_path)
  load_config_file = true
  # Server-side apply so re-runs converge instead of conflicting.
  apply_retry_count = 3
}
