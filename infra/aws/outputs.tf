# Outputs required by every cloud (infra/contract.md).
output "url" {
  description = "Base URL of the deployment. The certificate is self-signed, so clients need -k."
  value       = "https://${aws_lb.app.dns_name}"
}

output "lb_hostname" {
  description = "DNS name of the load balancer."
  value       = aws_lb.app.dns_name
}

# AWS specific, used by infra/aws/Makefile.
output "ecr_repository_url" {
  description = "ECR repository the image is pushed to."
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.app.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}
