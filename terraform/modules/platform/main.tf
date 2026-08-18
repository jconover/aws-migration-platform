# ---------------------------------------------------------------------------
# The whole environment in one composable unit. envs/staging and envs/prod
# differ only by input values, so a change proven in staging is the same code
# that reaches production.
# ---------------------------------------------------------------------------

locals {
  name = "${var.project}-${var.environment}"

  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Programme   = "aws-migration"
    },
    var.tags,
  )
}

module "vpc" {
  source = "../vpc"

  name                    = local.name
  cidr_block              = var.vpc_cidr
  availability_zone_count = var.availability_zone_count
  single_nat_gateway      = var.single_nat_gateway
  eks_cluster_name        = local.name
  enable_flow_logs        = true
  tags                    = local.tags
}

module "eks" {
  source = "../eks"

  name               = local.name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  endpoint_public_access       = var.eks_endpoint_public_access
  endpoint_public_access_cidrs = var.eks_endpoint_public_access_cidrs

  node_groups              = var.node_groups
  cluster_admin_role_arns  = var.cluster_admin_role_arns
  cluster_viewer_role_arns = var.cluster_viewer_role_arns

  tags = local.tags
}

module "rds" {
  source = "../rds"

  name       = local.name
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.data_subnet_ids

  # Reachability is granted to the cluster's node security group, not a CIDR.
  allowed_security_group_ids = [module.eks.node_security_group_id]

  engine_version        = var.db_engine_version
  instance_class        = var.db_instance_class
  allocated_storage_gb  = var.db_allocated_storage_gb
  multi_az              = var.db_multi_az
  backup_retention_days = var.db_backup_retention_days
  deletion_protection   = var.db_deletion_protection
  apply_immediately     = var.environment != "prod"

  tags = local.tags
}

module "artifacts" {
  source = "../s3"

  bucket_name   = var.artifact_bucket_name
  force_destroy = var.artifact_bucket_force_destroy
  tags          = local.tags
}

module "ecr" {
  source = "../ecr"

  name                = local.name
  pull_principal_arns = [module.eks.node_role_arn]
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Runtime identity: the pod assumes a role scoped to exactly one bucket prefix
# and one secret.
# ---------------------------------------------------------------------------

module "app_policy" {
  source = "../iam-app"

  name                = local.name
  artifact_bucket_arn = module.artifacts.bucket_arn
  artifact_prefix     = "exports"
  database_secret_arn = module.rds.master_user_secret_arn
  kms_key_arns        = [module.rds.kms_key_arn]
  tags                = local.tags
}

module "app_irsa" {
  source = "../irsa"

  name              = "${local.name}-app"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  namespace         = var.kubernetes_namespace
  service_account   = var.kubernetes_service_account
  policy_arns       = [module.app_policy.policy_arn]
  tags              = local.tags
}

# ---------------------------------------------------------------------------
# Deployment identity: GitHub Actions assumes this role. It can push images and
# roll out Kubernetes deployments; it cannot read application data.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "AuthenticateToRegistry"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushAndPullApplicationImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [module.ecr.repository_arn]
  }

  statement {
    sid       = "ReadClusterMetadataForKubeconfig"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }
}

module "github_deploy_role" {
  source = "../github-oidc"

  name                 = "${local.name}-deploy"
  create_oidc_provider = var.create_github_oidc_provider
  github_subjects      = var.github_deploy_subjects
  inline_policies      = { deploy = data.aws_iam_policy_document.deploy.json }
  tags                 = local.tags
}

# The deploy role needs Kubernetes RBAC as well as IAM. An access entry with
# the edit policy scoped to the application namespace lets it roll out a
# Deployment without granting cluster-admin.
resource "aws_eks_access_entry" "deploy" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.github_deploy_role.role_arn
  type          = "STANDARD"
  tags          = local.tags
}

resource "aws_eks_access_policy_association" "deploy" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.github_deploy_role.role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [var.kubernetes_namespace]
  }

  depends_on = [aws_eks_access_entry.deploy]
}
