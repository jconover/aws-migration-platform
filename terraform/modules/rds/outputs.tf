output "endpoint" {
  description = "Instance connection endpoint."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Listening port."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "Initial database name."
  value       = aws_db_instance.this.db_name
}

output "security_group_id" {
  description = "Security group guarding the instance."
  value       = aws_security_group.this.id
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the rotated master credentials."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "kms_key_arn" {
  description = "KMS key encrypting storage, backups and Performance Insights."
  value       = aws_kms_key.this.arn
}

output "instance_arn" {
  description = "Instance ARN, for CloudWatch alarms and IAM conditions."
  value       = aws_db_instance.this.arn
}

output "instance_id" {
  description = "Instance identifier, used as the CloudWatch alarm dimension."
  value       = aws_db_instance.this.identifier
}
