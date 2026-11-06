terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Remote state in S3 with a DynamoDB lock table (created by infra/bootstrap).
  # Partial configuration: the bucket/table names live in backend.hcl so this
  # file has no account-specific values. Usage:
  #   cp backend.hcl.example backend.hcl   # fill in your bucket
  #   terraform init -backend-config=backend.hcl
  # CI validates with: terraform init -backend=false
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "postpilot"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
