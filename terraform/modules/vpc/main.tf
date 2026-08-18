# ---------------------------------------------------------------------------
# Network foundation: a three-tier VPC sized for a phased datacentre migration.
#
# Address plan (derived from var.cidr_block, assumed /16):
#   public   /20 per AZ  - load balancers, NAT gateways, bastion-free by design
#   private  /20 per AZ  - EKS nodes and pods
#   data     /24 per AZ  - RDS subnet group, isolated with no egress route
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # newbits=4 carves /20s out of a /16 for the routable tiers.
  public_subnets  = [for index in range(var.availability_zone_count) : cidrsubnet(var.cidr_block, 4, index)]
  private_subnets = [for index in range(var.availability_zone_count) : cidrsubnet(var.cidr_block, 4, index + 4)]

  # The data tier is deliberately small and carved from the far end of the range.
  data_subnets = [for index in range(var.availability_zone_count) : cidrsubnet(var.cidr_block, 8, index + 240)]

  nat_gateway_count = var.single_nat_gateway ? 1 : var.availability_zone_count

  eks_tags_enabled = var.eks_cluster_name != ""

  tags = merge(var.tags, { Module = "vpc" })
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name })
}

# ---------------------------------------------------------------------------
# Public tier
# ---------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "public" {
  count = var.availability_zone_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(
    local.tags,
    { Name = "${var.name}-public-${local.azs[count.index]}", Tier = "public" },
    local.eks_tags_enabled ? {
      "kubernetes.io/role/elb"                        = "1"
      "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    } : {}
  )
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Private tier (egress via NAT)
# ---------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(local.tags, { Name = "${var.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_subnet" "private" {
  count = var.availability_zone_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(
    local.tags,
    { Name = "${var.name}-private-${local.azs[count.index]}", Tier = "private" },
    local.eks_tags_enabled ? {
      "kubernetes.io/role/internal-elb"               = "1"
      "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    } : {}
  )
}

resource "aws_route_table" "private" {
  count = var.availability_zone_count

  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

resource "aws_route" "private_nat" {
  count = var.availability_zone_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# Data tier: no default route, reachable only from inside the VPC.
# ---------------------------------------------------------------------------

resource "aws_subnet" "data" {
  count = var.availability_zone_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.data_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, { Name = "${var.name}-data-${local.azs[count.index]}", Tier = "data" })
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-data" })
}

resource "aws_route_table_association" "data" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}
