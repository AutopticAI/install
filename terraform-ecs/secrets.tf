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
