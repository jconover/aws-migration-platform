# ---------------------------------------------------------------------------
# Container registry for the application image.
# Immutable tags mean a deployed digest can never be swapped underneath us,
# which is what makes the rollback procedure in docs/RUNBOOK.md trustworthy.
# ---------------------------------------------------------------------------

variable "name" {
  description = "Repository name."
  type        = string
}

variable "image_tag_mutability" {
  description = "IMMUTABLE prevents overwriting a published tag."
  type        = string
  default     = "IMMUTABLE"
}

variable "untagged_expiry_days" {
  description = "Delete untagged images after this many days."
  type        = number
  default     = 7
}

variable "keep_last_images" {
  description = "Number of tagged release images to retain."
  type        = number
  default     = 50
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for image encryption. Empty uses AES256."
  type        = string
  default     = ""
}

variable "pull_principal_arns" {
  description = "IAM principals allowed to pull, typically the EKS node role and ECS execution role."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

locals {
  tags = merge(var.tags, { Module = "ecr" })
}

resource "aws_ecr_repository" "this" {
  name                 = var.name
  image_tag_mutability = var.image_tag_mutability
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = var.kms_key_arn != "" ? "KMS" : "AES256"
    kms_key         = var.kms_key_arn != "" ? var.kms_key_arn : null
  }

  tags = merge(local.tags, { Name = var.name })
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Retain the most recent release images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-", "v"]
          countType     = "imageCountMoreThan"
          countNumber   = var.keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}

data "aws_iam_policy_document" "repository" {
  count = length(var.pull_principal_arns) > 0 ? 1 : 0

  statement {
    sid    = "AllowPullFromComputeRoles"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.pull_principal_arns
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
}

resource "aws_ecr_repository_policy" "this" {
  count = length(var.pull_principal_arns) > 0 ? 1 : 0

  repository = aws_ecr_repository.this.name
  policy     = data.aws_iam_policy_document.repository[0].json
}

output "repository_url" {
  description = "Registry URL used by docker push."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "Repository ARN."
  value       = aws_ecr_repository.this.arn
}

output "repository_name" {
  description = "Repository name."
  value       = aws_ecr_repository.this.name
}
