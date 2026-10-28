# 1 public ALB + 2 internal ALBs (server, vectors). metrics has no ALB -- vectors
# reaches it directly over Service Connect (see service_discovery.tf).
#
# The public ALB serves one host with the same paths as the Docker Compose nginx proxy:
#   /                -> ui (the default action of each public listener)
#   /autoptic-api/*  -> server, with the /autoptic-api prefix removed. Only with auth_enforce on.
#                       The bootstrap route under it answers 403 (see public_api_bootstrap_block).
#   /mcp, /mcp/*     -> mcp
# Not /api/: the ui's own backend is under /api (/api/config, /api/v1/...).
#
# No ALB module was specified for this design, so these are plain aws_lb/aws_lb_listener/
# aws_lb_target_group resources; the `ecs` module only attaches to a target_group_arn you
# already have (see ecs.tf), it doesn't create the load balancer itself.
#
# A target group can belong to one load balancer only. So server has one target group for the
# internal-server ALB and one for the public ALB.

resource "aws_lb" "public" {
  name               = "${local.name_prefix}-public"
  internal           = false
  load_balancer_type = "application"
  idle_timeout       = var.alb_idle_timeout
  subnets            = module.vpc.public_subnets
  security_groups    = [module.sg_alb_public.id]

  tags = local.tags
}

resource "aws_lb_target_group" "ui" {
  name        = "${local.name_prefix}-ui"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  # /health is ui's own health check route.
  health_check {
    path    = "/health"
    matcher = "200-399"
  }

  tags = local.tags
}

resource "aws_lb_listener" "public_http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }
}

# The public listeners that get the /autoptic-api/ and /mcp rules below. DNS-TLS-SETUP.md adds
# the HTTPS listener to this map.
locals {
  public_listener_arns = {
    http = aws_lb_listener.public_http.arn
  }
}

resource "aws_lb_target_group" "server_public" {
  count = local.public_api_enabled ? 1 : 0

  name        = "${local.name_prefix}-server-pub"
  port        = 9999
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path    = "/${var.server_health_path}"
    matcher = "200-399"
  }

  tags = local.tags
}

resource "aws_lb_listener_rule" "public_api" {
  for_each = local.public_api_enabled ? local.public_listener_arns : {}

  listener_arn = each.value
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.server_public[0].arn
  }

  condition {
    path_pattern {
      values = ["/autoptic-api/*"]
    }
  }

  # server serves its routes from /, so this rule removes the prefix first.
  # /autoptic-api/story/ep/default becomes /story/ep/default. The query string stays.
  transform {
    type = "url-rewrite"
    url_rewrite_config {
      rewrite {
        regex   = "^/autoptic-api(/.*)$"
        replace = "$1"
      }
    }
  }

  tags = local.tags
}

resource "aws_lb_target_group" "mcp_public" {
  name        = "${local.name_prefix}-mcp-pub"
  port        = 7000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path    = "/health"
    matcher = "200-399"
  }

  tags = local.tags
}

# mcp serves streamable HTTP on /mcp, so the path stays as it is.
resource "aws_lb_listener_rule" "public_mcp" {
  for_each = local.public_listener_arns

  listener_arn = each.value
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mcp_public.arn
  }

  condition {
    path_pattern {
      values = ["/mcp", "/mcp/*"]
    }
  }

  tags = local.tags
}

# The bootstrap route gives role tokens, role.admin among them, to a caller that sends the SHA-256
# of config.json. ui and scheduler use it from inside the VPC only, so the public listeners refuse
# it. server matches its routes on the decoded path, so the regex also matches percent-encoded
# letters (%62ootstrap). README.md ("Access control") gives the way to get role.admin from the VPC.
resource "aws_lb_listener_rule" "public_api_bootstrap_block" {
  for_each = local.public_api_enabled ? local.public_listener_arns : {}

  listener_arn = each.value
  priority     = 5

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }

  condition {
    path_pattern {
      regex_values = ["^/autoptic-api/.*(b|%62)(o|%6[fF])(o|%6[fF])(t|%74)(s|%73)(t|%74)(r|%72)(a|%61)(p|%70).*"]
    }
  }

  tags = local.tags
}

# The ECS services read the public target groups through the listener rules. This puts each rule
# before its service, because AWS refuses a service on a target group that no listener or rule
# uses. A depends_on on the rules delays every data source in module "ecs" (see ecs.tf).
locals {
  server_public_target_group_arn = local.public_api_enabled ? values(aws_lb_listener_rule.public_api)[0].action[0].target_group_arn : null
  mcp_public_target_group_arn    = values(aws_lb_listener_rule.public_mcp)[0].action[0].target_group_arn
}

resource "aws_lb" "internal_server" {
  name               = "${local.name_prefix}-int-server"
  internal           = true
  load_balancer_type = "application"
  idle_timeout       = var.alb_idle_timeout
  subnets            = module.vpc.private_subnets
  security_groups    = [module.sg_alb["server"].id]

  tags = local.tags
}

resource "aws_lb_target_group" "server" {
  name        = "${local.name_prefix}-server"
  port        = 9999
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path    = "/${var.server_health_path}"
    matcher = "200-399"
  }

  tags = local.tags
}

resource "aws_lb_listener" "internal_server_http" {
  load_balancer_arn = aws_lb.internal_server.arn
  port              = 9999
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.server.arn
  }
}

resource "aws_lb" "internal_vectors" {
  name               = "${local.name_prefix}-int-vectors"
  internal           = true
  load_balancer_type = "application"
  subnets            = module.vpc.private_subnets
  security_groups    = [module.sg_alb["vectors"].id]

  tags = local.tags
}

resource "aws_lb_target_group" "vectors" {
  name        = "${local.name_prefix}-vectors"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  # /health is vectors' own health check route.
  health_check {
    path    = "/health"
    matcher = "200-399"
  }

  tags = local.tags
}

resource "aws_lb_listener" "internal_vectors_http" {
  load_balancer_arn = aws_lb.internal_vectors.arn
  port              = 8000
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vectors.arn
  }
}
