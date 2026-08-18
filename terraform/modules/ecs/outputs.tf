output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "task_definition_family" {
  description = "Task definition family, used by the deploy workflow."
  value       = aws_ecs_task_definition.this.family
}

output "task_execution_role_arn" {
  description = "Execution role ARN."
  value       = aws_iam_role.execution.arn
}

output "task_role_arn" {
  description = "Task role ARN carrying application permissions."
  value       = aws_iam_role.task.arn
}

output "load_balancer_dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.this.dns_name
}

output "tasks_security_group_id" {
  description = "Security group attached to task ENIs; allow this on RDS."
  value       = aws_security_group.tasks.id
}
