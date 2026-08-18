variable "name" {
  description = "Identifier prefix for the database and its supporting resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the instance."
  type        = string
}

variable "subnet_ids" {
  description = "Isolated data-tier subnet ids. Must span at least two AZs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS requires subnets in at least two availability zones."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups permitted to reach Postgres. Compute identity, not CIDRs."
  type        = list(string)
  default     = []
}

variable "engine_version" {
  description = "Postgres major.minor version."
  type        = string
  default     = "17.4"
}

variable "instance_class" {
  description = "Instance class. Right-size from source-system metrics captured during discovery."
  type        = string
  default     = "db.t4g.medium"
}

variable "allocated_storage_gb" {
  description = "Initial gp3 storage."
  type        = number
  default     = 100
}

variable "max_allocated_storage_gb" {
  description = "Ceiling for storage autoscaling. Set equal to allocated_storage_gb to disable."
  type        = number
  default     = 500
}

variable "database_name" {
  description = "Initial database created on the instance."
  type        = string
  default     = "migration_tracker"
}

variable "master_username" {
  description = "Master user. The password is generated and rotated by Secrets Manager, never stored in state."
  type        = string
  default     = "tracker_admin"
}

variable "multi_az" {
  description = "Run a synchronous standby in a second AZ."
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Automated backup retention. Production migrations should keep at least 14 days."
  type        = number
  default     = 14
}

variable "deletion_protection" {
  description = "Block accidental deletion. Keep true everywhere that holds migrated data."
  type        = bool
  default     = true
}

variable "performance_insights_retention_days" {
  description = "Performance Insights retention in days (7 is the free tier)."
  type        = number
  default     = 7
}

variable "monitoring_interval_seconds" {
  description = "Enhanced monitoring granularity. 0 disables it."
  type        = number
  default     = 60
}

variable "apply_immediately" {
  description = "Apply modifications outside the maintenance window. Useful in staging, risky in production."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
