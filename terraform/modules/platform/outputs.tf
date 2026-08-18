output "vpc_id" {
  description = "VPC id."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets hosting compute."
  value       = module.vpc.private_subnet_ids
}

output "data_subnet_ids" {
  description = "Isolated subnets hosting RDS."
  value       = module.vpc.data_subnet_ids
}

output "cluster_name" {
  description = "EKS cluster name. Feed to 'aws eks update-kubeconfig --name'."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "ecr_repository_url" {
  description = "Image registry URL."
  value       = module.ecr.repository_url
}

output "database_endpoint" {
  description = "RDS endpoint hostname."
  value       = module.rds.endpoint
}

output "database_secret_arn" {
  description = "Secrets Manager ARN holding the database credentials."
  value       = module.rds.master_user_secret_arn
}

output "artifact_bucket_name" {
  description = "Artifact bucket name."
  value       = module.artifacts.bucket_name
}

output "app_role_arn" {
  description = "IRSA role ARN to annotate on the application ServiceAccount."
  value       = module.app_irsa.role_arn
}

output "github_deploy_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN GitHub variable for this environment."
  value       = module.github_deploy_role.role_arn
}

output "alerts_topic_arn" {
  description = "SNS topic receiving infrastructure alarms and pipeline failures."
  value       = aws_sns_topic.alerts.arn
}

output "app_policy_json" {
  description = "Rendered least-privilege application policy, for review in pull requests."
  value       = module.app_policy.policy_json
}

output "ecs_cluster_name" {
  description = "ECS cluster name when the ECS path is enabled."
  value       = var.enable_ecs ? module.ecs[0].cluster_name : null
}

output "ecs_service_name" {
  description = "ECS service name when the ECS path is enabled."
  value       = var.enable_ecs ? module.ecs[0].service_name : null
}

output "ecs_load_balancer_dns_name" {
  description = "ECS load balancer DNS name."
  value       = var.enable_ecs ? module.ecs[0].load_balancer_dns_name : null
}

output "ecs_task_definition_family" {
  description = "Task definition family for the deploy workflow."
  value       = var.enable_ecs ? module.ecs[0].task_definition_family : null
}
