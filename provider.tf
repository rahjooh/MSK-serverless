provider "aws" {
  region = var.region

  # Only assume a role when an ARN is provided. In CI we pass an empty string
  # via -var to avoid double-assuming when the workflow already assumed a role.
  assume_role {
    role_arn = (var.assume_role_arn != null && var.assume_role_arn != "") ? var.assume_role_arn : ""
  }

  default_tags {
    tags = var.tags
  }
}

# Secondary provider without default tags for IAM resources that cannot be tagged.
provider "aws" {
  alias  = "untagged"
  region = var.region
}

data "aws_caller_identity" "this" {}
