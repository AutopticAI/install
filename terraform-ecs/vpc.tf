module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = local.name_prefix
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i + 2)]

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_support   = true
  enable_dns_hostnames = true # required for Cloud Map private DNS + ALB DNS resolution

  tags = local.tags
}
