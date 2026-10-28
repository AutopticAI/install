locals {
  name_prefix = "${var.app}-${var.env}"

  # Cloud Map namespace used only for the vectors -> metrics hop (see service_discovery.tf)
  namespace_name = "${var.env}.${var.app}.local"

  tags = {
    App       = var.app
    Env       = var.env
    ManagedBy = "terraform"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  auth_trusted_proxies = length(var.auth_trusted_proxies) > 0 ? var.auth_trusted_proxies : [var.vpc_cidr]

  # The public /autoptic-api/ route exists only with auth_enforce on. With enforce off, the API
  # answers callers that send no token, so it stays on the internal-server ALB only.
  public_api_enabled = var.auth_enforce
}
