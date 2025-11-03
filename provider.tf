provider "aws" {
  region = var.region

  # Only include assume_role when a non-empty ARN is provided to avoid
  # double-assuming in CI (where credentials are already assumed).
  dynamic "assume_role" {
    for_each = (var.assume_role_arn != null && var.assume_role_arn != "") ? [var.assume_role_arn] : []
    content {
      role_arn = assume_role.value
    }
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
