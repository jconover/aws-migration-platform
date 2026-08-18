variable "name" {
  description = "Name prefix applied to every VPC resource."
  type        = string
}

variable "cidr_block" {
  description = "IPv4 CIDR for the VPC. Must not overlap the on-premises ranges advertised over Direct Connect."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0)) && tonumber(split("/", var.cidr_block)[1]) <= 20
    error_message = "cidr_block must be a valid CIDR of /20 or larger to leave room for subnet growth."
  }
}

variable "availability_zone_count" {
  description = "Number of AZs to span. Three is the default for production-grade EKS and Multi-AZ RDS."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 4
    error_message = "availability_zone_count must be between 2 and 4."
  }
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one per AZ. Cheaper, but a single AZ failure removes egress."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Ship VPC flow logs to CloudWatch for migration traffic analysis and troubleshooting."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for VPC flow logs."
  type        = number
  default     = 30
}

variable "eks_cluster_name" {
  description = "Cluster name used for Kubernetes subnet discovery tags. Empty disables the tags."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
