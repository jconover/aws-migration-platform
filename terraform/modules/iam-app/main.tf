# ---------------------------------------------------------------------------
# Least-privilege application permissions.
#
# Every statement below names concrete resource ARNs. There are no wildcards
# on resources, and the only wildcard actions are the read-only S3 list calls
# that AWS does not express any other way. Grants are scoped to:
#   - one S3 prefix inside one bucket
#   - the single Secrets Manager secret holding the database credentials
#   - decrypt-only on the two KMS keys behind those two services
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

variable "name" {
  description = "Policy name prefix."
  type        = string
}

variable "artifact_bucket_arn" {
  description = "ARN of the bucket the application reads and writes."
  type        = string
}

variable "artifact_prefix" {
  description = "Key prefix the application is confined to, without a leading slash."
  type        = string
  default     = "exports"
}

variable "database_secret_arn" {
  description = "Secrets Manager secret holding the database credentials."
  type        = string
}

variable "kms_key_arns" {
  description = "KMS keys the application must decrypt with (RDS and S3 keys)."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to created policies."
  type        = map(string)
  default     = {}
}

data "aws_region" "current" {}

locals {
  tags   = merge(var.tags, { Module = "iam-app" })
  prefix = trim(var.artifact_prefix, "/")
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ListOnlyOwnPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.artifact_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.prefix}/*"]
    }
  }

  statement {
    sid    = "ReadWriteOwnObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${var.artifact_bucket_arn}/${local.prefix}/*"]
  }

  statement {
    sid    = "ReadDatabaseCredentials"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [var.database_secret_arn]
  }

  dynamic "statement" {
    for_each = length(var.kms_key_arns) > 0 ? [1] : []

    content {
      sid    = "DecryptThroughOwningServicesOnly"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey",
      ]
      resources = var.kms_key_arns

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values = [
          "s3.${data.aws_region.current.region}.amazonaws.com",
          "secretsmanager.${data.aws_region.current.region}.amazonaws.com",
        ]
      }
    }
  }
}

resource "aws_iam_policy" "app" {
  name_prefix = "${var.name}-app-"
  description = "Least-privilege runtime permissions for ${var.name}"
  policy      = data.aws_iam_policy_document.app.json
  tags        = local.tags
}

output "policy_arn" {
  description = "ARN of the application policy, to attach to an IRSA or task role."
  value       = aws_iam_policy.app.arn
}

output "policy_json" {
  description = "Rendered policy document, useful for review in pull requests."
  value       = data.aws_iam_policy_document.app.json
}
