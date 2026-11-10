# Bedrock Mantle access for the Autoptic server, through a long-term Bedrock API key.
#
# The server sends the key as a Bearer token (prompt profile type openai_bedrock). It can sign
# requests with the ECS task role only on bedrock-runtime, not on Bedrock Mantle. Thus this
# module creates an IAM user that owns the key, and puts the key in Secrets Manager. An operator copies the key into the Autoptic
# secret bedrock.token after the apply.
#
# The key value is also in the Terraform state. Keep access to the state bucket tight.

data "aws_caller_identity" "current" {}

locals {
  # GPT-6 Luna on Bedrock Mantle uses the /openai/v1 base path. Other models can use /v1.
  endpoint = "https://bedrock-mantle.${var.region}.api.aws/openai/v1"
  model_id = "openai.gpt-6-luna"
}

resource "aws_iam_user" "this" {
  name = "${var.name_prefix}-bedrock"
  tags = var.tags
}

# Same actions as the AWS managed policy AmazonBedrockMantleInferenceAccess, less web search,
# and limited to one region and this account.
data "aws_iam_policy_document" "mantle" {
  statement {
    sid = "BedrockMantleInference"
    actions = [
      "bedrock-mantle:Get*",
      "bedrock-mantle:List*",
      "bedrock-mantle:CreateInference",
    ]
    resources = ["arn:aws:bedrock-mantle:${var.region}:${data.aws_caller_identity.current.account_id}:project/*"]
  }

  statement {
    sid       = "BedrockMantleCallWithBearerToken"
    actions   = ["bedrock-mantle:CallWithBearerToken"]
    resources = ["*"]
  }

  # The first call to a third-party model (OpenAI) on Bedrock subscribes the account to it in
  # AWS Marketplace. Bedrock Mantle does this on behalf of the caller.
  statement {
    sid = "MarketplaceFromBedrockMantle"
    actions = [
      "aws-marketplace:Subscribe",
      "aws-marketplace:ViewSubscriptions",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:CalledViaLast"
      values   = ["bedrock-mantle.amazonaws.com"]
    }
  }
}

resource "aws_iam_user_policy" "mantle" {
  name   = "bedrock-mantle-inference"
  user   = aws_iam_user.this.name
  policy = data.aws_iam_policy_document.mantle.json
}

resource "aws_iam_service_specific_credential" "this" {
  service_name        = "bedrock.amazonaws.com"
  user_name           = aws_iam_user.this.name
  credential_age_days = var.key_age_days

  depends_on = [aws_iam_user_policy.mantle]
}

resource "aws_secretsmanager_secret" "api_key" {
  name        = "${var.name_prefix}-bedrock-api-key"
  description = "Bedrock API key for Bedrock Mantle. Copy it into the Autoptic secret bedrock.token."
  tags        = var.tags

  # No recovery window: the name is free again at once after a destroy, so bedrock_enable can go
  # off and on. Terraform state still holds the key, so the window adds no protection.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id     = aws_secretsmanager_secret.api_key.id
  secret_string = aws_iam_service_specific_credential.this.service_credential_secret
}
