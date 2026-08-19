variable "name" {
  description = "Name prefix for the access roles."
  type        = string
}

variable "trusted_principal_arns" {
  description = <<-EOT
    Principals permitted to assume these roles - normally the account root of an
    identity account, or specific IAM user ARNs during a migration when Identity
    Center is not yet in place. Prefer Identity Center permission sets over this
    module for day-to-day human access; see the module README.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.trusted_principal_arns) > 0
    error_message = "At least one trusted principal is required, or nobody can assume any role."
  }
}

variable "require_mfa" {
  description = "Require MFA to assume any role here. Disable only for automation principals."
  type        = bool
  default     = true
}

variable "break_glass_session_seconds" {
  description = "Maximum break-glass session length. Short by design - it is for incidents, not work."
  type        = number
  default     = 3600

  validation {
    condition     = var.break_glass_session_seconds <= 7200
    error_message = "Break-glass sessions must be 2 hours or less."
  }
}

variable "standard_session_seconds" {
  description = "Maximum session length for the non-emergency roles."
  type        = number
  default     = 14400
}

variable "cloudtrail_log_group_name" {
  description = "CloudWatch log group receiving CloudTrail events. Empty disables break-glass alarming."
  type        = string
  default     = ""
}

variable "alerts_topic_arn" {
  description = "SNS topic notified when the break-glass role is assumed."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
