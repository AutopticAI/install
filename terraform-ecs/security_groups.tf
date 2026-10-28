# All 5 security groups are created via terraform-aws-modules/security-group/aws. Plain
# aws_vpc_security_group_ingress_rule resources appear further down for the "ALB -> tasks"
# direction — see the comment on module "sg_tasks" for why: only that module's exclusive-rules
# mechanism actually needs disabling. The 3 ALB security groups are sg_alb_public and the 2 in
# module.sg_alb below. The `ingress_rules` map of sg_tasks never references them back, because
# that direction lives in the plain resources. So exclusive rules are safe on these 3. They stay
# on, so Terraform finds and reverts an ingress or egress rule added out of band on them.

module "sg_alb_public" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "6.0.0"

  # The description stays "in front of ui", although this ALB also routes /autoptic-api/ and /mcp.
  # A new description replaces the security group.
  name        = "${local.name_prefix}-alb-public"
  description = "Public ALB in front of ui"
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {
    http = { cidr_ipv4 = "0.0.0.0/0", from_port = 80, to_port = 80 }
  }
  egress_rules = {
    all = { cidr_ipv4 = "0.0.0.0/0", ip_protocol = "-1", from_port = -1, to_port = -1 }
  }

  tags = local.tags
}

# server and vectors each get an internal ALB with the identical security-group shape:
# ingress from sg_tasks on the service's own port, wide-open egress. One for_each module
# replaces near-identical blocks, differing only in name, description, and port. mcp has no
# internal ALB: nothing in this stack calls it, and MCP clients use /mcp on the public ALB.
locals {
  internal_albs = {
    server  = { port = 9999, description = "Internal ALB in front of server (called by ui and mcp)" }
    vectors = { port = 8000, description = "Internal ALB in front of vectors (called by server)" }
  }
}

module "sg_alb" {
  source   = "terraform-aws-modules/security-group/aws"
  version  = "6.0.0"
  for_each = local.internal_albs

  name        = "${local.name_prefix}-alb-${each.key}"
  description = each.value.description
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {
    from_tasks = { referenced_security_group_id = module.sg_tasks.id, from_port = each.value.port, to_port = each.value.port }
  }
  egress_rules = {
    all = { cidr_ipv4 = "0.0.0.0/0", ip_protocol = "-1", from_port = -1, to_port = -1 }
  }

  tags = local.tags
}

module "sg_tasks" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "6.0.0"

  name        = "${local.name_prefix}-tasks"
  description = "Shared security group for all 5 ECS Fargate services"
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {
    # ALB -> task rules live as plain resources below, not here -- sg_alb_server/vectors
    # each already reference sg_tasks.security_group_id for their own ingress (caller -> ALB),
    # so a reverse reference inside this module (ALB -> task) would create a module-to-module
    # dependency cycle (both sides would depend on each other's full module completion).
    #
    # vectors -> metrics, direct Service Connect call, no ALB in between. metrics-6334 is
    # Qdrant's gRPC port (used by server via config.json); metrics-6333 is its REST port (used
    # by vectors' /health check and its QdrantClient(url=...) calls).
    self_metrics_grpc = { referenced_security_group_id = "self", from_port = 6334, to_port = 6334 }
    self_metrics_rest = { referenced_security_group_id = "self", from_port = 6333, to_port = 6333 }
  }
  egress_rules = {
    all = { cidr_ipv4 = "0.0.0.0/0", ip_protocol = "-1", from_port = -1, to_port = -1 }
  }

  # Disabled so the plain aws_vpc_security_group_ingress_rule resources added below aren't
  # revoked as "out of band" on the next apply.
  enable_exclusive_rules = false

  tags = local.tags
}

# ALB -> task ingress, added as plain resources (not inside module "sg_tasks") specifically to
# avoid the module-to-module cycle described above: each of these depends on two already-created
# security groups, but neither security-group module depends back on this resource.
resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb_public" {
  security_group_id            = module.sg_tasks.id
  referenced_security_group_id = module.sg_alb_public.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  tags                         = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb_server" {
  security_group_id            = module.sg_tasks.id
  referenced_security_group_id = module.sg_alb["server"].id
  from_port                    = 9999
  to_port                      = 9999
  ip_protocol                  = "tcp"
  tags                         = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb_vectors" {
  security_group_id            = module.sg_tasks.id
  referenced_security_group_id = module.sg_alb["vectors"].id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
  tags                         = local.tags
}

# The public ALB also reaches server (/autoptic-api/) and mcp (/mcp). The server rule exists
# only when the /autoptic-api/ route exists (see local.public_api_enabled).
resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb_public_server" {
  count = local.public_api_enabled ? 1 : 0

  security_group_id            = module.sg_tasks.id
  referenced_security_group_id = module.sg_alb_public.id
  from_port                    = 9999
  to_port                      = 9999
  ip_protocol                  = "tcp"
  tags                         = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb_public_mcp" {
  security_group_id            = module.sg_tasks.id
  referenced_security_group_id = module.sg_alb_public.id
  from_port                    = 7000
  to_port                      = 7000
  ip_protocol                  = "tcp"
  tags                         = local.tags
}

module "sg_efs" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "6.0.0"

  name        = "${local.name_prefix}-efs"
  description = "EFS mount targets, reachable only from ECS tasks"
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {
    nfs_from_tasks = { referenced_security_group_id = module.sg_tasks.id, from_port = 2049, to_port = 2049 }
  }

  # No egress_rules, intentionally -- exclusive rules stays enabled here (the module default),
  # so this SG ends up with zero egress permissions. NFS is one bidirectional TCP connection;
  # response traffic on an already-accepted inbound connection is stateful and needs no
  # explicit egress rule. This is the tightest-scoped of the 5 security groups here, not an
  # oversight.

  tags = local.tags
}
