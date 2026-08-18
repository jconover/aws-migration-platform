# ---------------------------------------------------------------------------
# GitHub Actions -> AWS trust via OIDC.
#
# This module is the reason no AWS access keys exist anywhere in the repository
# or in GitHub secrets. Actions presents a short-lived OIDC token; STS exchanges
# it for credentials that expire with the job.
#
# The trust policy pins the subject claim, so only the named repository and only
# the named refs/environments can assume the role. A fork, a pull request from a
# fork, or a different branch presents a different `sub` and is rejected by STS.
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
  description = "Role name prefix."
  type        = string
}

variable "create_oidc_provider" {
  description = "Create the account-level GitHub OIDC provider. Set false when another stack owns it."
  type        = bool
  default     = true
}

variable "github_subjects" {
  description = <<-EOT
    Exact `sub` claims permitted to assume the role, for example:
      repo:my-org/migration-tracker:environment:production
      repo:my-org/migration-tracker:ref:refs/heads/main
    Avoid `repo:org/repo:*`, which would let any branch or fork PR assume it.
  EOT
  type        = list(string)

  validation {
    condition     = alltrue([for subject in var.github_subjects : !endswith(subject, ":*")])
    error_message = "Wildcard subjects ending in ':*' are not permitted; pin refs or environments explicitly."
  }
}

variable "policy_arns" {
  description = "Managed policy ARNs attached to the role."
  type        = list(string)
  default     = []
}

variable "inline_policies" {
  description = "Inline policy documents keyed by name."
  type        = map(string)
  default     = {}
}

variable "max_session_duration" {
  description = "Maximum credential lifetime in seconds."
  type        = number
  default     = 3600
}

variable "tags" {
  description = "Tags applied to created resources."
  type        = map(string)
  default     = {}
}

locals {
  tags          = merge(var.tags, { Module = "github-oidc" })
  provider_host = "token.actions.githubusercontent.com"
  provider_arn  = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://${local.provider_host}"
  client_id_list = ["sts.amazonaws.com"]
  tags           = local.tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://${local.provider_host}"
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.provider_host}:sub"
      values   = var.github_subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix          = "${var.name}-"
  description          = "GitHub Actions deployment role for ${var.name}"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = var.max_session_duration
  tags                 = local.tags
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  for_each = var.inline_policies

  name   = each.key
  role   = aws_iam_role.this.id
  policy = each.value
}

output "role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.this.arn
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN."
  value       = local.provider_arn
}
