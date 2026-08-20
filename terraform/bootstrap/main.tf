# ---------------------------------------------------------------------------
# One-time bootstrap: the S3 bucket that holds every other stack's state.
#
# Run this once per account with local state, then commit the generated
# backend settings. Terraform 1.10+ locks state with a native S3 lock file
# (`use_lockfile`), so no DynamoDB table is required.
#
#   terraform -chdir=terraform/bootstrap init
#   terraform -chdir=terraform/bootstrap apply
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "migration-tracker"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

variable "region" {
  description = "Region hosting the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform state bucket."
  type        = string
}

resource "aws_kms_key" "state" {
  description             = "Encrypts Terraform state"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "state" {
  name          = "alias/terraform-state"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  # State is the one thing that must never be casually destroyed.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "state" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

output "state_bucket_name" {
  description = "State bucket name, for -backend-config."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  description = "KMS key encrypting state, for -backend-config."
  value       = aws_kms_key.state.arn
}

# The environment stacks already declare their own backend blocks with the key
# set (staging/terraform.tfstate, prod/terraform.tfstate). Only bucket, region
# and kms_key_id are supplied at init time, so the same code can initialise
# against a different account per environment. These are those commands, ready
# to paste - nothing here needs editing.
output "init_commands" {
  description = "Ready-to-run terraform init for each environment."
  value       = <<-EOT

    staging:
      terraform -chdir=../envs/staging init \
        -backend-config="bucket=${aws_s3_bucket.state.id}" \
        -backend-config="region=${var.region}" \
        -backend-config="kms_key_id=${aws_kms_key.state.arn}"

    prod:
      terraform -chdir=../envs/prod init \
        -backend-config="bucket=${aws_s3_bucket.state.id}" \
        -backend-config="region=${var.region}" \
        -backend-config="kms_key_id=${aws_kms_key.state.arn}"
  EOT
}
