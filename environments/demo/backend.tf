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
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.22"
    }
  }
}
