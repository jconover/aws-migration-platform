# ---------------------------------------------------------------------------
# IAM Roles for Service Accounts.
#
# Binds one Kubernetes ServiceAccount to one IAM role. The trust policy pins
# both the subject (namespace + service account) and the audience, so another
# namespace cannot assume this role even inside the same cluster.
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

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider."
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer host without the https:// scheme."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of the service account."
  type        = string
}

variable "service_account" {
  description = "Kubernetes service account name."
  type        = string
}

variable "policy_arns" {
  description = "Customer-managed policy ARNs to attach."
  type        = list(string)
  default     = []
}

variable "inline_policies" {
  description = "Inline policy documents keyed by policy name."
  type        = map(string)
  default     = {}
}

variable "max_session_duration" {
  description = "Maximum session length in seconds."
  type        = number
  default     = 3600
}

variable "tags" {
  description = "Tags applied to the role."
  type        = map(string)
  default     = {}
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix          = "${var.name}-"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = var.max_session_duration
  tags                 = merge(var.tags, { Module = "irsa" })
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
  description = "Role ARN to annotate onto the service account."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Role name."
  value       = aws_iam_role.this.name
}

output "service_account_annotation" {
  description = "Ready-made annotation map for the Kubernetes ServiceAccount."
  value       = { "eks.amazonaws.com/role-arn" = aws_iam_role.this.arn }
}
