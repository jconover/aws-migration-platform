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
