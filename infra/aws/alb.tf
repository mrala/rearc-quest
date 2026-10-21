resource "aws_lb" "app" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # Must not block `terraform destroy` (ADR-0007).
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "app" {
  name        = "${local.name}-app"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip" # Fargate (awsvpc). Use "instance" if ADR-0001 falls back to ECS on EC2.
  vpc_id      = aws_vpc.main.id

  # Fewer seconds waiting for in-flight requests when a task stops (ADR-0007).
  deregistration_delay = 30

  # Every route execs a binary. "/" takes about 25 s and "/loadbalanced" about 5 s
  # outside a cloud, so the check uses a fast route (ADR-0003).
  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.alb.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
