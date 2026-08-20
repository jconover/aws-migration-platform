# ---------------------------------------------------------------------------
# The third landing option, alongside EKS and ECS: plain instances.
#
# A migration of any size lands workloads in all three places. Keeping them as
# sibling modules against one VPC, one database and one least-privilege policy
# means moving a workload between them is a configuration change rather than a
# rebuild - which matters, because the first target chosen during discovery is
# often not the right one after the workload has run in AWS for a month.
#
# As with ECS, the RDS ingress rule is declared here rather than inside the rds
# module, so rds does not gain a dependency on a module that already depends
# on it.
# ---------------------------------------------------------------------------

module "ec2_rehost" {
  count  = var.enable_ec2_rehost ? 1 : 0
  source = "../ec2-rehost"

  name               = "${local.name}-rehost"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  alb_subnet_ids     = module.vpc.private_subnet_ids
  internal_alb       = true

  instance_type    = var.ec2_instance_type
  desired_capacity = var.ec2_desired_capacity
  min_size         = var.ec2_desired_capacity
  max_size         = var.ec2_desired_capacity * 3

  container_image = var.ec2_container_image

  database_secret_arn = module.rds.master_user_secret_arn
  database_host       = module.rds.endpoint
  app_policy_arns     = { app = module.app_policy.policy_arn }
  kms_key_arns        = [module.rds.kms_key_arn]

  environment = var.environment
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_ec2" {
  count = var.enable_ec2_rehost ? 1 : 0

  security_group_id            = module.rds.security_group_id
  description                  = "Postgres from rehosted EC2 instances"
  referenced_security_group_id = module.ec2_rehost[0].instances_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
