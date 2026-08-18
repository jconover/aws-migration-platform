# ---------------------------------------------------------------------------
# VPC endpoints keep S3/ECR/logs traffic off the NAT gateways. On a migration
# of this size that is both a cost lever and a data-egress control.
# ---------------------------------------------------------------------------

locals {
  interface_endpoints = toset([
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
    "sts",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "elasticloadbalancing",
  ])
}

data "aws_region" "current" {}

resource "aws_security_group" "endpoints" {
  name_prefix = "${var.name}-vpce-"
  description = "Ingress to interface VPC endpoints from inside the VPC"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from within the VPC"
  cidr_ipv4         = aws_vpc.this.cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.private[*].id, [aws_route_table.data.id])

  tags = merge(local.tags, { Name = "${var.name}-s3" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${var.name}-${replace(each.value, ".", "-")}" })
}
