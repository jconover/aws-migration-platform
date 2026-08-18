variable "environment" {
  description = "Environment name, used in every resource name and tag."
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be staging or prod."
  }
}

variable "project" {
  description = "Project slug used as a name prefix."
  type        = string
  default     = "migration-tracker"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must not collide with on-premises ranges or the other environment."
  type        = string
}

variable "availability_zone_count" {
  description = "Number of AZs to span."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "Share one NAT gateway. Acceptable in staging, not in production."
  type        = bool
  default     = false
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.35"
}

variable "eks_endpoint_public_access" {
  description = "Expose the Kubernetes API publicly."
  type        = bool
  default     = false
}

variable "eks_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach a public API endpoint."
  type        = list(string)
  default     = []
}

variable "node_groups" {
  description = "Managed node group definitions."
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND")
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size_gb   = optional(number, 50)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
}

variable "cluster_admin_role_arns" {
  description = "IAM roles granted cluster-admin."
  type        = list(string)
  default     = []
}

variable "cluster_viewer_role_arns" {
  description = "IAM roles granted read-only cluster access."
  type        = list(string)
  default     = []
}

variable "db_engine_version" {
  description = "Postgres version."
  type        = string
  default     = "17.4"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
}

variable "db_allocated_storage_gb" {
  description = "Initial storage."
  type        = number
  default     = 100
}

variable "db_multi_az" {
  description = "Run a standby in a second AZ."
  type        = bool
  default     = true
}

variable "db_backup_retention_days" {
  description = "Automated backup retention."
  type        = number
  default     = 14
}

variable "db_deletion_protection" {
  description = "Block accidental database deletion."
  type        = bool
  default     = true
}

variable "artifact_bucket_name" {
  description = "Globally unique artifact bucket name."
  type        = string
}

variable "artifact_bucket_force_destroy" {
  description = "Allow deleting a non-empty artifact bucket."
  type        = bool
  default     = false
}

variable "kubernetes_namespace" {
  description = "Namespace the workload runs in."
  type        = string
  default     = "migration-tracker"
}

variable "kubernetes_service_account" {
  description = "Service account bound to the application IAM role."
  type        = string
  default     = "migration-tracker"
}

variable "github_repository" {
  description = "owner/repo permitted to assume the deployment role."
  type        = string
}

variable "github_deploy_subjects" {
  description = "Exact OIDC subject claims permitted to deploy this environment."
  type        = list(string)
}

variable "create_github_oidc_provider" {
  description = "Create the account-level GitHub OIDC provider here. Only one stack per account may own it."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags merged into the defaults."
  type        = map(string)
  default     = {}
}

variable "enable_ecs" {
  description = "Also provision an ECS Fargate service alongside EKS. See docs/ARCHITECTURE.md for the trade-off."
  type        = bool
  default     = false
}

variable "ecs_container_image" {
  description = "Image the ECS service starts with. CI publishes later revisions."
  type        = string
  default     = "public.ecr.aws/docker/library/nginx:alpine"
}

variable "ecs_desired_count" {
  description = "Baseline ECS task count."
  type        = number
  default     = 2
}
