terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
  }

  # Partial configuration: bucket/key/region come from backend.hcl
  #   terraform init -backend-config=backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.region

  # Guard rail: refuse to run against any account other than the intended one.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project     = "platform-blueprint"
      Environment = local.environment
      ManagedBy   = "terraform"
      Repository  = "github.com/RatulSikder97/platform-blueprint"
    }
  }
}
