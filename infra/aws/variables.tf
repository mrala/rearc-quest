# Inputs shared by every cloud (infra/contract.md): image, image_tag, secret_word,
# replicas, tags. The rest are AWS specific.

variable "image" {
  description = "Image name. On AWS this is also the ECR repository name."
  type        = string
  default     = "quest"
}

variable "image_tag" {
  description = "Image tag to deploy, normally the git SHA. Never \"latest\" (ADR-0004)."
  type        = string

  validation {
    condition     = var.image_tag != "latest" && var.image_tag != ""
    error_message = "Use an explicit tag such as the git short SHA, not \"latest\"."
  }
}

variable "secret_word" {
  description = "Value of the SECRET_WORD env var. Leave empty on the first deploy, read the word from the index page, then set it and apply again (ADR-0005)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "replicas" {
  description = "Number of tasks. Two or more across two AZs, so /loadbalanced shows real balancing."
  type        = number
  default     = 2

  validation {
    condition     = var.replicas >= 1
    error_message = "replicas must be at least 1."
  }
}

variable "tags" {
  description = "Extra tags for every resource, merged with project, managed_by and ttl."
  type        = map(string)
  default     = {}
}

# --- AWS specific ---

variable "region" {
  description = "AWS region. The quest-deployer IAM policy only allows us-east-1 (ADR-0009)."
  type        = string
  default     = "us-east-1"
}

variable "ttl" {
  description = "Date (YYYY-MM-DD) after which the stack should be destroyed, tagged on every resource. Empty omits the tag."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR of the VPC. Two /24 public subnets are carved from it."
  type        = string
  default     = "10.20.0.0/16"
}

variable "cpu" {
  description = "Fargate task CPU units. 256 with 512 MiB is the smallest size (ADR-0008)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 512
}

variable "health_check_path" {
  description = "ALB health-check path. Must be a fast route: / takes about 25 s outside a cloud and /loadbalanced about 5 s (ADR-0003)."
  type        = string
  default     = "/tls"
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 7
}

variable "budget_email" {
  description = "Email for AWS Budget alerts. Empty skips the budget."
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "Monthly limit for the budget. The budget covers the whole account: filtering by the project tag needs the tag activated as a cost allocation tag, which takes a day."
  type        = string
  default     = "10"
}
