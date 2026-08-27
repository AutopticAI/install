# 1 public ALB (ui) + 3 internal ALBs (server, vectors, mcp). metrics has no ALB -- vectors
# reaches it directly over Service Connect (see service_discovery.tf).
#
# No ALB module was specified for this design, so these are plain aws_lb/aws_lb_listener/
# aws_lb_target_group resources; the `ecs` module only attaches to a target_group_arn you
# already have (see ecs.tf), it doesn't create the load balancer itself.

resource "aws_lb" "public" {
  name               = "${local.name_prefix}-public"
  internal           = false
  load_balancer_type = "application"
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

resource "aws_lb" "internal_server" {
  name               = "${local.name_prefix}-int-server"
  internal           = true
  load_balancer_type = "application"
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

resource "aws_lb" "internal_mcp" {
  name               = "${local.name_prefix}-int-mcp"
  internal           = true
  load_balancer_type = "application"
  subnets            = module.vpc.private_subnets
  security_groups    = [module.sg_alb["mcp"].id]

  tags = local.tags
}

resource "aws_lb_target_group" "mcp" {
  name        = "${local.name_prefix}-mcp"
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

resource "aws_lb_listener" "internal_mcp_http" {
  load_balancer_arn = aws_lb.internal_mcp.arn
  port              = 7000
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mcp.arn
  }
}
