# ---------------------------------------------------------------------------
# Production. Multi-AZ everywhere, private API endpoint, deletion protection on.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    key          = "prod/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "migration-tracker"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

variable "region" {
  description = "Deployment region."
  type        = string
  default     = "us-east-1"
}

variable "artifact_bucket_name" {
  description = "Globally unique artifact bucket name."
  type        = string
}

variable "github_repository" {
  description = "owner/repo allowed to deploy."
  type        = string
}

variable "cluster_admin_role_arns" {
  description = "IAM roles granted cluster-admin. Keep this list short and auditable."
  type        = list(string)
  default     = []
}

variable "cluster_viewer_role_arns" {
  description = "IAM roles granted read-only cluster access, typically the wider engineering group."
  type        = list(string)
  default     = []
}

module "platform" {
  source = "../../modules/platform"

  environment = "prod"
  vpc_cidr    = "10.10.0.0/16"

  availability_zone_count = 3
  single_nat_gateway      = false

  kubernetes_version = "1.35"

  # The API endpoint is private. Operators reach it over the Direct Connect or
  # VPN path established during the network workstream.
  eks_endpoint_public_access = false

  node_groups = {
    general = {
      instance_types = ["m6i.large", "m6a.large"]
      capacity_type  = "ON_DEMAND"
      min_size       = 3
      max_size       = 12
      desired_size   = 3
      disk_size_gb   = 100
      labels         = { workload = "general" }
    }
    burst = {
      instance_types = ["m6i.large", "m6a.large", "m5.large"]
      capacity_type  = "SPOT"
      min_size       = 0
      max_size       = 10
      desired_size   = 0
      labels         = { workload = "burst" }
      taints = [{
        key    = "workload"
        value  = "burst"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  cluster_admin_role_arns  = var.cluster_admin_role_arns
  cluster_viewer_role_arns = var.cluster_viewer_role_arns

  db_instance_class        = "db.m6g.large"
  db_allocated_storage_gb  = 200
  db_multi_az              = true
  db_backup_retention_days = 30
  db_deletion_protection   = true

  artifact_bucket_name          = var.artifact_bucket_name
  artifact_bucket_force_destroy = false

  github_repository = var.github_repository
  github_deploy_subjects = [
    "repo:${var.github_repository}:environment:production",
  ]
  # Staging created the account-level provider; reuse it here.
  create_github_oidc_provider = false
}
