# MCP_SERVER_TOKEN is a real bearer secret (clients send it as X-MCP-Token) -- delivered via
# the task definition's `secrets` block (ecs.tf), never as a plain environment variable.
resource "random_password" "mcp_server_token" {
  count   = var.mcp_server_token == "" ? 1 : 0
  length  = 32
  special = false
}

locals {
  mcp_server_token = var.mcp_server_token != "" ? var.mcp_server_token : random_password.mcp_server_token[0].result
}

resource "aws_secretsmanager_secret" "mcp_token" {
  name = "${local.name_prefix}-mcp-server-token"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "mcp_token" {
  secret_id     = aws_secretsmanager_secret.mcp_token.id
  secret_string = local.mcp_server_token
}

# ui crashes on boot with WEBUI_SECRET_KEY unset (open_webui/env.py raises when WEBUI_AUTH is
# true, the default, and WEBUI_SECRET_KEY == ""). The image's own start.sh normally
# auto-generates one into a file next to the app if the env var is absent, but that path isn't
# reliable here -- setting it directly as a secret sidesteps the file-based fallback entirely.
resource "random_password" "ui_webui_secret_key" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "ui_webui_secret_key" {
  name = "${local.name_prefix}-ui-webui-secret-key"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "ui_webui_secret_key" {
  secret_id     = aws_secretsmanager_secret.ui_webui_secret_key.id
  secret_string = random_password.ui_webui_secret_key.result
}
