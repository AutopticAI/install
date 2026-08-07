terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Bootstrap this bucket first (see README.md "Step 0"), then fill in these placeholders
  # before the first `terraform init` -- Copilot never required a state backend at all.
  backend "s3" {
    bucket       = "<YOUR_TERRAFORM_STATE_BUCKET>"
    key          = "autoptic/<ENV_NAME>/terraform.tfstate"
    region       = "<YOUR_AWS_REGION>"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}
