terraform {
  # Pinned to a minor range rather than floating. A Terraform upgrade can
  # change plan output in ways that matter, and that should be a deliberate
  # commit rather than whatever the runner happened to install.
  required_version = "~> 1.15"

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

  # Remote state is intentionally NOT configured here.
  #
  # State contains the IAM secret access key in plaintext, so where it lives
  # is a security decision belonging to whoever owns the account, not to a
  # template. Configure it with `-backend-config=backend.hcl` (git-ignored):
  #
  #   bucket         = "my-tfstate"
  #   key            = "nextcloud/terraform.tfstate"
  #   region         = "eu-west-1"
  #   encrypt        = true
  #   use_lockfile   = true
  #
  # Running without a backend keeps state in a local file, which is fine for
  # one person evaluating this and wrong for a team.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "github.com/rthway/nextcloud-private-cloud"
    }
  }
}
