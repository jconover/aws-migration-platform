output "role_arns" {
  description = "Standing role ARNs by access tier."
  value       = { for tier, role in aws_iam_role.this : tier => role.arn }
}

output "break_glass_role_arn" {
  description = "Emergency administrative role. Assumption is alarmed when CloudTrail is wired up."
  value       = aws_iam_role.break_glass.arn
}

output "platform_engineer_role_arn" {
  description = "Convenience accessor, for granting EKS cluster-admin."
  value       = aws_iam_role.this["platform-engineer"].arn
}

output "developer_role_arn" {
  description = "Convenience accessor, for granting EKS view access."
  value       = aws_iam_role.this["developer"].arn
}

output "assume_commands" {
  description = "How a human actually uses these."
  value = {
    for tier, role in aws_iam_role.this :
    tier => "aws sts assume-role --role-arn ${role.arn} --role-session-name ${tier} --serial-number <mfa-arn> --token-code <code>"
  }
}

output "alarm_enabled" {
  description = "Whether break-glass assumption raises an alarm. False means CloudTrail or the SNS topic was not supplied."
  value       = local.alarm_enabled
}
