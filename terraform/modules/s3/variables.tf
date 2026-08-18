variable "bucket_name" {
  description = "Globally unique bucket name."
  type        = string
}

variable "versioning_enabled" {
  description = "Keep object versions. Required for the noncurrent-version lifecycle rules below."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for SSE-KMS. Empty falls back to SSE-S3."
  type        = string
  default     = ""
}

variable "noncurrent_version_expiration_days" {
  description = "Delete superseded versions after this many days."
  type        = number
  default     = 90
}

variable "transition_to_ia_days" {
  description = "Move current objects to Standard-IA after this many days. 0 disables the transition."
  type        = number
  default     = 30
}

variable "abort_incomplete_upload_days" {
  description = "Reclaim storage from abandoned multipart uploads."
  type        = number
  default     = 7
}

variable "force_destroy" {
  description = "Allow Terraform to delete a non-empty bucket. Never enable in production."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
