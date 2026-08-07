# Cloud Map namespace used only for the vectors -> metrics hop. Every other service (server, ui,
# mcp) is reached through an ALB instead (see alb.tf) and does not register here.
resource "aws_service_discovery_private_dns_namespace" "this" {
  name = local.namespace_name
  vpc  = module.vpc.vpc_id
  tags = local.tags
}
