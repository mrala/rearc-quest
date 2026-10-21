resource "aws_ecs_cluster" "app" {
  name = local.name
}

locals {
  # No SECRET_WORD on the first deploy: the word is read from the deployed index
  # page, then set and applied again (ADR-0005). An empty value would still define
  # the variable in the container, so it is left out entirely.
  container_env = var.secret_word == "" ? [] : [
    { name = "SECRET_WORD", value = var.secret_word },
  ]
}

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  # The bundled binaries are x86-64 only (ADR-0001).
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential = true

    portMappings = [{ containerPort = 3000, protocol = "tcp" }]
    environment  = local.container_env

    # Same restrictions the image was tested with locally (ADR-0009). Not yet
    # tested on Fargate. tini is the image entrypoint, so initProcessEnabled stays off.
    readonlyRootFilesystem = true
    linuxParameters        = { capabilities = { drop = ["ALL"] } }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.replicas
  launch_type     = "FARGATE"

  # A task needs a few seconds to start; the health check route itself is fast.
  health_check_grace_period_seconds = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true # no NAT gateway (ADR-0003)
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 3000
  }

  # The target group must be attached to a listener before the service uses it.
  depends_on = [aws_lb_listener.https, aws_lb_listener.http]
}
