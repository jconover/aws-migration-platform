# ---------------------------------------------------------------------------
# Human access to the migrated estate.
#
# Four assumable roles, no IAM users, no access keys. During a migration the
# access model is usually the last thing anyone designs and the first thing
# auditors ask about, so it is worth being explicit:
#
#   break-glass       full admin, MFA, short sessions, alarms when used
#   platform-engineer day-to-day infrastructure work
#   developer         read-only plus cluster view
#   auditor           read-only plus security audit, no data access
#
# Roles rather than users because a role produces short-lived credentials that
# expire on their own. An IAM user's access key is valid until somebody
# remembers to rotate it, which on a migration nobody does.
#
# Identity Center is the better answer once it exists. This module is for the
# window before that, or for accounts that will never join an organisation.
# ---------------------------------------------------------------------------

locals {
  tags = merge(var.tags, { Module = "iam-access" })

  roles = {
    "platform-engineer" = {
      description = "Day-to-day infrastructure work on the migrated estate"
      policies    = ["arn:aws:iam::aws:policy/PowerUserAccess"]
      session     = var.standard_session_seconds
    }
    "developer" = {
      description = "Read-only across AWS, with cluster view access granted separately"
      policies    = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      session     = var.standard_session_seconds
    }
    "auditor" = {
      description = "Read-only plus security configuration review"
      policies = [
        "arn:aws:iam::aws:policy/ReadOnlyAccess",
        "arn:aws:iam::aws:policy/SecurityAudit",
      ]
      session = var.standard_session_seconds
    }
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }

    dynamic "condition" {
      for_each = var.require_mfa ? [1] : []

      content {
        test     = "Bool"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }

    # An MFA token minted hours ago is not evidence of presence now.
    dynamic "condition" {
      for_each = var.require_mfa ? [1] : []

      content {
        test     = "NumericLessThan"
        variable = "aws:MultiFactorAuthAge"
        values   = ["3600"]
      }
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.roles

  name                 = "${var.name}-${each.key}"
  description          = each.value.description
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = each.value.session
  tags                 = merge(local.tags, { AccessTier = each.key })
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = merge([
    for role, config in local.roles : {
      for policy in config.policies : "${role}:${basename(policy)}" => {
        role   = role
        policy = policy
      }
    }
  ]...)

  role       = aws_iam_role.this[each.value.role].name
  policy_arn = each.value.policy
}

# Nobody should be reading application data by hand. Denying it explicitly on
# every standing role means an engineer who needs it has to break glass, which
# is visible, rather than doing it quietly with credentials they already hold.
data "aws_iam_policy_document" "deny_data_access" {
  statement {
    sid    = "DenyReadingApplicationSecrets"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "rds-data:ExecuteStatement",
      "rds-data:BatchExecuteStatement",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deny_data_access" {
  name_prefix = "${var.name}-deny-data-"
  description = "Standing roles cannot read application secrets; break glass instead"
  policy      = data.aws_iam_policy_document.deny_data_access.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "deny_data_access" {
  for_each = local.roles

  role       = aws_iam_role.this[each.key].name
  policy_arn = aws_iam_policy.deny_data_access.arn
}

# ---------------------------------------------------------------------------
# Break-glass. Separate from the loop above because its trust policy, session
# length and alarming all differ, and because collapsing it into the same
# pattern is how it quietly becomes an ordinary role.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "break_glass_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }

    condition {
      test     = "NumericLessThan"
      variable = "aws:MultiFactorAuthAge"
      values   = ["900"]
    }
  }
}

resource "aws_iam_role" "break_glass" {
  name                 = "${var.name}-break-glass"
  description          = "Emergency administrative access. Assumption is alarmed."
  assume_role_policy   = data.aws_iam_policy_document.break_glass_assume.json
  max_session_duration = var.break_glass_session_seconds
  tags                 = merge(local.tags, { AccessTier = "break-glass" })
}

resource "aws_iam_role_policy_attachment" "break_glass" {
  role       = aws_iam_role.break_glass.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---------------------------------------------------------------------------
# Alarm on use. An emergency role nobody is told about is just admin access.
# ---------------------------------------------------------------------------

locals {
  alarm_enabled = var.cloudtrail_log_group_name != "" && var.alerts_topic_arn != ""
}

resource "aws_cloudwatch_log_metric_filter" "break_glass" {
  count = local.alarm_enabled ? 1 : 0

  name           = "${var.name}-break-glass-assumed"
  log_group_name = var.cloudtrail_log_group_name
  pattern        = "{ $.eventName = \"AssumeRole\" && $.requestParameters.roleArn = \"${aws_iam_role.break_glass.arn}\" }"

  metric_transformation {
    name          = "BreakGlassAssumed"
    namespace     = "Migration/Access"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "break_glass" {
  count = local.alarm_enabled ? 1 : 0

  alarm_name          = "${var.name}-break-glass-assumed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "BreakGlassAssumed"
  namespace           = "Migration/Access"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "The break-glass role was assumed. Expected during an incident; investigate otherwise."
  alarm_actions       = [var.alerts_topic_arn]
  treat_missing_data  = "notBreaching"
  tags                = local.tags
}
