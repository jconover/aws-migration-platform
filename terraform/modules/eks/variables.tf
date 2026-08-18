variable "name" {
  description = "Cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane version. Track N-1 in production; verify support windows with 'aws eks describe-cluster-versions'."
  type        = string
  default     = "1.35"
}

variable "vpc_id" {
  description = "VPC hosting the cluster."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the control plane ENIs and worker nodes."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnets for internet-facing load balancers."
  type        = list(string)
  default     = []
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API publicly. Keep false once the VPN or Direct Connect path is live."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs permitted to reach a public API endpoint. Never leave as 0.0.0.0/0 in production."
  type        = list(string)
  default     = []
}

variable "node_groups" {
  description = "Managed node group definitions keyed by name."
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND")
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size_gb   = optional(number, 50)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
}

variable "cluster_admin_role_arns" {
  description = "IAM role ARNs granted cluster-admin through EKS access entries."
  type        = list(string)
  default     = []
}

variable "cluster_viewer_role_arns" {
  description = "IAM role ARNs granted read-only cluster access."
  type        = list(string)
  default     = []
}

variable "enabled_log_types" {
  description = "Control plane log types shipped to CloudWatch."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "log_retention_days" {
  description = "Retention for control plane logs."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
