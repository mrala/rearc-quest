# Task execution role: lets ECS pull from ECR and write logs. The app gets no task
# role because it calls no AWS APIs (ADR-0009). The name must start with "quest-"
# and only the AWS-managed execution policy may be attached, or quest-deployer
# is not allowed to create it (infra/aws/bootstrap/quest-deployer-policy.json).
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
