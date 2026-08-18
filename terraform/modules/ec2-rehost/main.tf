# ---------------------------------------------------------------------------
# Rehost target: the landing zone for lift-and-shift workloads.
#
# Not every migrated system becomes a container platform tenant. Plenty of
# applications move as-is onto instances, and this module is the target for
# those: an Auto Scaling Group behind a load balancer, with the operational
# affordances a datacentre team expects - SSM shell access, CloudWatch logs and
# metrics - but none of the datacentre habits, notably no SSH and no long-lived
# credentials on disk.
# ---------------------------------------------------------------------------

locals {
  tags = merge(var.tags, { Module = "ec2-rehost", MigrationStrategy = "rehost" })

  ami_id   = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.al2023.value
  registry = split("/", var.container_image)[0]
}

data "aws_region" "current" {}

# Resolving the AMI from the SSM public parameter means a new instance always
# launches on the current patched Amazon Linux 2023 image without a Terraform
# change. Pin var.ami_id to a Packer-built AMI when the workload needs one.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/ec2/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_launch_template" "this" {
  name_prefix            = "${var.name}-"
  image_id               = local.ami_id
  instance_type          = var.instance_type
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.this.arn
  }

  vpc_security_group_ids = [aws_security_group.instances.id]

  # IMDSv2 only. The v1 endpoint is the classic SSRF-to-credential-theft path,
  # and a rehosted application is exactly the kind of code nobody has audited
  # for SSRF recently.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  dynamic "block_device_mappings" {
    for_each = var.data_volume_gb > 0 ? [1] : []

    content {
      device_name = "/dev/xvdb"

      ebs {
        volume_size           = var.data_volume_gb
        volume_type           = "gp3"
        encrypted             = true
        delete_on_termination = false
      }
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    app_name            = var.name
    environment         = var.environment
    region              = data.aws_region.current.region
    database_secret_arn = var.database_secret_arn
    database_host       = var.database_host
    database_name       = var.database_name
    container_image     = var.container_image
    registry            = local.registry
    application_port    = var.application_port
    health_check_path   = var.health_check_path
    log_group           = aws_cloudwatch_log_group.this.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = var.name })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = var.name })
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name_prefix         = "${var.name}-"
  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.this.arn]

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  # ELB health checks, not EC2. An instance that boots but whose application
  # never comes up is not healthy, and only the load balancer knows that.
  health_check_type         = "ELB"
  health_check_grace_period = 300
  default_instance_warmup   = 60
  wait_for_capacity_timeout = "10m"

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  # A new AMI or user-data change rolls the fleet automatically, keeping most
  # of it in service. This is the closest EC2 equivalent of a Kubernetes
  # rolling update, and it is what makes the ASG a deploy target rather than
  # just a capacity pool.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 60
      auto_rollback          = true
    }
    # A launch template change always triggers a refresh; no explicit trigger needed.
  }

  dynamic "tag" {
    for_each = merge(local.tags, { Name = var.name })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}

resource "aws_autoscaling_policy" "cpu" {
  count = var.enable_scaling_policy ? 1 : 0

  name                   = "${var.name}-cpu"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value = 65

    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
  }
}
