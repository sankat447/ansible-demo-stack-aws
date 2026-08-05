terraform {
  # Same S3 backend bucket as the base platform (ai-demo-stack-aws),
  # separate state key so this layer's lifecycle is independent.
  # DO NOT change the bucket — see Rules of Engagement in README.md.
  backend "s3" {
    bucket       = "ai-demo-stack-tfstate"
    key          = "demo/aiops.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    # kubectl applies raw YAML at apply-time, so CRs whose CRDs are
    # installed mid-apply (AutomationController etc.) don't fail at plan.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
