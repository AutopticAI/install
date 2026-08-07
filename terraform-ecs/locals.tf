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
