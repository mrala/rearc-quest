resource "aws_ecr_repository" "app" {
  name = var.image

  # Tags are the git SHA plus "-dirty" for uncommitted builds, and the same dirty
  # tag is pushed repeatedly, so tags must be mutable.
  image_tag_mutability = "MUTABLE"

  # Images are rebuildable, so they must not block `terraform destroy` (ADR-0007).
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 5 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
}
