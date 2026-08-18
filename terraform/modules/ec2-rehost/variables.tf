variable "name" {
  description = "Name prefix for the rehosted workload."
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the instances."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets running the instances."
  type        = list(string)
}

variable "alb_subnet_ids" {
  description = "Subnets for the load balancer. Private when internal_alb is true."
  type        = list(string)
}

variable "internal_alb" {
  description = "Keep the load balancer off the internet."
  type        = bool
  default     = true
}

variable "ami_id" {
  description = "AMI to launch. Empty resolves the latest Amazon Linux 2023 by SSM parameter."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "Instance type. Right-size from source-system metrics after cutover, not before."
  type        = string
  default     = "t3.medium"
}

variable "min_size" {
  description = "Minimum instances."
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Maximum instances."
  type        = number
  default     = 6
}

variable "desired_capacity" {
  description = "Starting instance count."
  type        = number
  default     = 2
}

variable "root_volume_gb" {
  description = "Root EBS volume size."
  type        = number
  default     = 30
}

variable "data_volume_gb" {
  description = "Additional encrypted data volume. 0 disables it."
  type        = number
  default     = 0
}

variable "application_port" {
  description = "Port the application listens on."
  type        = number
  default     = 8000
}

variable "health_check_path" {
  description = "ALB health check path."
  type        = string
  default     = "/healthz"
}

variable "allowed_client_cidrs" {
  description = "CIDRs permitted to reach the load balancer."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "database_secret_arn" {
  description = "Secrets Manager secret holding database credentials."
  type        = string
}

variable "database_host" {
  description = "RDS endpoint the application connects to."
  type        = string
}

variable "database_name" {
  description = "Database name."
  type        = string
  default     = "migration_tracker"
}

variable "app_policy_arn" {
  description = "Least-privilege application policy attached to the instance role."
  type        = string
  default     = ""
}

variable "kms_key_arns" {
  description = "KMS keys the instance must decrypt to read the secret."
  type        = list(string)
  default     = []
}

variable "container_image" {
  description = "Image the instance runs. Rehosted workloads often still ship as containers on a VM."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch retention for instance logs."
  type        = number
  default     = 30
}

variable "enable_scaling_policy" {
  description = "Attach a CPU target-tracking scaling policy."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
