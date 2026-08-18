output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle for kubeconfig."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group attached to the control plane."
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "EKS-managed security group shared by cluster and nodes."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN backing IRSA."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer host without the scheme."
  value       = local.oidc_host
}

output "node_role_arn" {
  description = "IAM role assumed by worker nodes."
  value       = aws_iam_role.node.arn
}

output "cluster_arn" {
  description = "Cluster ARN, for IAM resource conditions."
  value       = aws_eks_cluster.this.arn
}

output "kms_key_arn" {
  description = "KMS key encrypting Kubernetes secrets."
  value       = aws_kms_key.eks.arn
}
