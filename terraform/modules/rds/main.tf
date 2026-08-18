# ---------------------------------------------------------------------------
# Postgres in the isolated data tier.
#
# Design decisions worth knowing during a migration:
#   - The instance has no public route. Reachability is granted by security
#     group reference from the compute tier, never by CIDR.
#   - The master password is generated and held by Secrets Manager
#     (manage_master_user_password), so it never lands in Terraform state.
#   - rds.force_ssl is pinned on, so an unencrypted client fails loudly in
#     staging rather than silently in production.
# ---------------------------------------------------------------------------

locals {
  tags = merge(var.tags, { Module = "rds" })

  major_version = split(".", var.engine_version)[0]
}

resource "aws_kms_key" "this" {
  description             = "Encryption at rest for the ${var.name} Postgres instance"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = merge(local.tags, { Name = "${var.name}-rds" })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}-rds"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_db_subnet_group" "this" {
  name_prefix = "${var.name}-"
  subnet_ids  = var.subnet_ids
  description = "Isolated data-tier subnets for ${var.name}"
  tags        = merge(local.tags, { Name = "${var.name}" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-rds-"
  description = "Postgres access for ${var.name}"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "${var.name}-rds" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_compute" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "Postgres from ${each.value}"
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-pg${local.major_version}-"
  family      = "postgres${local.major_version}"
  description = "Hardened defaults for ${var.name}"
  tags        = local.tags

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "monitoring_assume" {
  count = var.monitoring_interval_seconds > 0 ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  count = var.monitoring_interval_seconds > 0 ? 1 : 0

  name_prefix        = "${var.name}-rds-mon-"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.monitoring_interval_seconds > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier_prefix = "${var.name}-"

  engine                      = "postgres"
  engine_version              = var.engine_version
  allow_major_version_upgrade = false
  auto_minor_version_upgrade  = true

  instance_class        = var.instance_class
  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.this.arn

  db_name                       = var.database_name
  username                      = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.this.key_id

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  port                   = 5432

  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot   = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  performance_insights_enabled          = true
  performance_insights_retention_period = var.performance_insights_retention_days
  performance_insights_kms_key_id       = aws_kms_key.this.arn
  monitoring_interval                   = var.monitoring_interval_seconds
  monitoring_role_arn                   = var.monitoring_interval_seconds > 0 ? aws_iam_role.monitoring[0].arn : null
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  apply_immediately = var.apply_immediately

  tags = merge(local.tags, { Name = var.name })

  # The snapshot name embeds a timestamp, which would otherwise force a diff on
  # every plan. Storage grows via autoscaling and must not be reverted.
  lifecycle {
    ignore_changes = [final_snapshot_identifier, allocated_storage]
  }
}
