terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.1"
    }
  }

  backend "s3" {
    bucket  = "test-raw-databucket"
    key     = "terraform/cluster/terraform.tfstate"
    region  = "ap-south-1"
    encrypt = true
    # no dynamodb_table
  }
}
