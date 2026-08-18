variable "name" {
  description = "Cluster and service name prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the service."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets running the tasks."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnets for the load balancer."
  type        = list(string)
}

variable "internal_alb" {
  description = "Place the load balancer on private subnets instead."
  type        = bool
  default     = true
}

variable "container_image" {
  description = "Fully qualified image reference, ideally pinned by digest."
  type        = string
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 8000
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Baseline task count."
  type        = number
  default     = 3
}

variable "min_capacity" {
  description = "Autoscaling floor."
  type        = number
  default     = 3
}

variable "max_capacity" {
  description = "Autoscaling ceiling."
  type        = number
  default     = 20
}

variable "database_secret_arn" {
  description = "Secrets Manager secret injected as DB_USERNAME and DB_PASSWORD."
  type        = string
}

variable "database_host" {
  description = "RDS endpoint hostname."
  type        = string
}

variable "database_name" {
  description = "Database name."
  type        = string
  default     = "migration_tracker"
}

variable "app_policy_arn" {
  description = "Least-privilege policy attached to the task role."
  type        = string
}

variable "kms_key_arns" {
  description = "KMS keys the execution role must decrypt to read the secret."
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "Environment name injected as APP_ENVIRONMENT."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch retention for task logs."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
