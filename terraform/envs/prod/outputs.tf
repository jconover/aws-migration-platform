output "cluster_name" {
  value       = module.platform.cluster_name
  description = "EKS cluster name."
}

output "ecr_repository_url" {
  value       = module.platform.ecr_repository_url
  description = "Image registry URL."
}

output "database_endpoint" {
  value       = module.platform.database_endpoint
  description = "RDS endpoint."
}

output "database_secret_arn" {
  value       = module.platform.database_secret_arn
  description = "Secrets Manager ARN for database credentials."
}

output "artifact_bucket_name" {
  value       = module.platform.artifact_bucket_name
  description = "Artifact bucket."
}

output "app_role_arn" {
  value       = module.platform.app_role_arn
  description = "IRSA role for the application service account."
}

output "github_deploy_role_arn" {
  value       = module.platform.github_deploy_role_arn
  description = "Deployment role for GitHub Actions."
}

output "alerts_topic_arn" {
  value       = module.platform.alerts_topic_arn
  description = "SNS topic for alarms and pipeline failures."
}

output "region" {
  value       = var.region
  description = "Deployment region, for CLI invocations."
}

output "ecs_cluster_name" {
  value       = module.platform.ecs_cluster_name
  description = "ECS cluster name when the Fargate target is enabled, else null."
}

output "ecs_service_name" {
  value       = module.platform.ecs_service_name
  description = "ECS service name when the Fargate target is enabled, else null."
}

output "ecs_task_definition_family" {
  value       = module.platform.ecs_task_definition_family
  description = "Task definition family for the ECS deploy workflow."
}

output "ec2_autoscaling_group_name" {
  value       = module.platform.ec2_autoscaling_group_name
  description = "ASG name when the EC2 rehost target is enabled, else null."
}

output "ec2_load_balancer_dns_name" {
  value       = module.platform.ec2_load_balancer_dns_name
  description = "Rehost target load balancer DNS name."
}
