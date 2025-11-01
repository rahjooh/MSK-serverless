provider "aws" {
  region = var.region

  assume_role {
    role_arn = var.assume_role_arn != null ? var.assume_role_arn : ""
    # tags = { AccessScope = "team-x" }  # if your org uses ABAC session tags
  }

  default_tags {
    tags = var.tags
  }
}

provider "aws" {
  alias  = "untagged"
  region = var.region

  assume_role {
    role_arn = var.assume_role_arn != null ? var.assume_role_arn : ""
  }
}

data "aws_caller_identity" "this" {}
