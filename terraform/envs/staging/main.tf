# ---------------------------------------------------------------------------
# Staging. Same code as production, smaller and cheaper inputs.
# Differences are deliberate and listed in docs/ARCHITECTURE.md.
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
    key          = "staging/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
    # bucket / region / kms_key_id supplied by -backend-config in CI so the
    # same code initialises against a different account per environment.
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "migration-tracker"
      Environment = "staging"
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
  description = "IAM roles granted cluster-admin."
  type        = list(string)
  default     = []
}

module "platform" {
  source = "../../modules/platform"

  environment = "staging"
  vpc_cidr    = "10.20.0.0/16"

  availability_zone_count = 2
  single_nat_gateway      = true

  kubernetes_version = "1.35"

  node_groups = {
    general = {
      instance_types = ["t3.large"]
      capacity_type  = "SPOT"
      min_size       = 1
      max_size       = 4
      desired_size   = 2
      labels         = { workload = "general" }
    }
  }

  cluster_admin_role_arns = var.cluster_admin_role_arns

  db_instance_class        = "db.t4g.medium"
  db_allocated_storage_gb  = 50
  db_multi_az              = false
  db_backup_retention_days = 7
  db_deletion_protection   = false

  artifact_bucket_name          = var.artifact_bucket_name
  artifact_bucket_force_destroy = true

  # Staging runs all three landing options so a workload can be moved between
  # them during assessment without waiting for new infrastructure.
  enable_ec2_rehost    = true
  ec2_instance_type    = "t3.small"
  ec2_desired_capacity = 1

  github_repository = var.github_repository
  github_deploy_subjects = [
    "repo:${var.github_repository}:environment:staging",
  ]
  # Set to true only if the account has no GitHub OIDC provider yet. Check with:
  #   aws iam list-open-id-connect-providers
  # A second provider for token.actions.githubusercontent.com cannot be created,
  # and apply fails with EntityAlreadyExists.
  create_github_oidc_provider = false
}
