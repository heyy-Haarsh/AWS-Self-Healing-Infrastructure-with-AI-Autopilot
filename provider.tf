# ============================================================
# provider.tf
# ------------------------------------------------------------
# Tells Terraform which cloud provider to use (AWS) and
# which region to deploy resources in (Mumbai = ap-south-1).
#
# Credentials are NOT written here. They come from AWS CLI:
#   aws configure
# Terraform automatically reads ~/.aws/credentials
# ============================================================

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
