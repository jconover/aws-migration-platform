# ---------------------------------------------------------------------------
# Human access.
#
# The runbook states that break-glass is "a named IAM role with an EKS access
# entry, MFA, and CloudTrail alerting on assumption". This is that sentence,
# implemented - including the Kubernetes half, which is the part usually
# forgotten. An IAM role with AdministratorAccess still cannot run kubectl
# against an EKS cluster without an access entry, so a break-glass role that
# stops at IAM is not break-glass for the thing most likely to be broken.
# ---------------------------------------------------------------------------

module "human_access" {
  count  = var.enable_human_access_roles ? 1 : 0
  source = "../iam-access"

  name                      = local.name
  trusted_principal_arns    = var.human_access_trusted_principals
  cloudtrail_log_group_name = var.cloudtrail_log_group_name
  alerts_topic_arn          = aws_sns_topic.alerts.arn
  tags                      = local.tags
}

locals {
  # Keyed by access tier, not by role ARN. The ARNs are created in this same
  # apply, so using them as map keys would make the for_each keys unknown at
  # plan time and the plan would fail before reaching AWS.
  human_cluster_access = var.enable_human_access_roles ? {
    break_glass = {
      principal_arn = module.human_access[0].break_glass_role_arn
      policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    }
    platform_engineer = {
      principal_arn = module.human_access[0].platform_engineer_role_arn
      policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
    }
    developer = {
      principal_arn = module.human_access[0].developer_role_arn
      policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
    }
  } : {}
}

resource "aws_eks_access_entry" "humans" {
  for_each = local.human_cluster_access

  cluster_name  = module.eks.cluster_name
  principal_arn = each.value.principal_arn
  type          = "STANDARD"
  tags          = local.tags
}

resource "aws_eks_access_policy_association" "humans" {
  for_each = local.human_cluster_access

  cluster_name  = module.eks.cluster_name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.humans]
}
