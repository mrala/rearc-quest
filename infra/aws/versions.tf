terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # 6.23.0 is the first provider release that accepts `aws login` credentials
    # (ADR-0004). Local state only: the S3 backend did not accept them.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.23.0, < 7.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Credentials come from the environment (AWS_PROFILE=quest-deployer), never from
# this file. The profile is a scoped IAM user, not root (ADR-0009).
provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      { project = "quest", managed_by = "terraform" },
      var.ttl == "" ? {} : { ttl = var.ttl },
      var.tags,
    )
  }
}
