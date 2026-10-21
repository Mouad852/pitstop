terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "pitstop-terraform-state-339961046802"
    key            = "eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "pitstop-terraform-locks"
    encrypt        = true
    profile        = "pitstop-eks"
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}
