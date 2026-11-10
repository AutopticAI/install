# Optional Bedrock Mantle access for GPT-6 Luna. Off by default. See README.md, "Bedrock Mantle access".
module "bedrock_access" {
  source = "./modules/bedrock-access"
  count  = var.bedrock_enable ? 1 : 0

  name_prefix  = local.name_prefix
  tags         = local.tags
  key_age_days = var.bedrock_key_age_days
}
