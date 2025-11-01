provider "aws" {
  region = var.region

  assume_role {
    role_arn = coalesce(var.assume_role_arn, "arn:aws:iam::640168415309:role/MSK-Builder")
    # tags = { AccessScope = "team-x" }  # if your org uses ABAC session tags
  }

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "this" {}
