# ---------------------------------------------------------------------------
# Optional ECS Fargate service running the same image as the EKS deployment.
#
# The RDS ingress rule lives here rather than inside the rds module: routing it
# through module.rds inputs would make rds depend on ecs, which already depends
# on rds for the endpoint and secret. Declaring the rule at this level keeps the
# dependency graph acyclic.
# ---------------------------------------------------------------------------

module "ecs" {
  count  = var.enable_ecs ? 1 : 0
  source = "../ecs"

  name               = local.name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
  internal_alb       = true

  container_image = var.ecs_container_image
  desired_count   = var.ecs_desired_count
  min_capacity    = var.ecs_desired_count
  max_capacity    = var.ecs_desired_count * 5

  database_secret_arn = module.rds.master_user_secret_arn
  database_host       = module.rds.endpoint
  app_policy_arn      = module.app_policy.policy_arn
  kms_key_arns        = [module.rds.kms_key_arn]

  environment = var.environment
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_ecs" {
  count = var.enable_ecs ? 1 : 0

  security_group_id            = module.rds.security_group_id
  description                  = "Postgres from ECS tasks"
  referenced_security_group_id = module.ecs[0].tasks_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
