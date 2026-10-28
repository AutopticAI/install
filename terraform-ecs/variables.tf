variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "app" {
  description = "Application name, used as a naming prefix for most resources."
  type        = string
  default     = "autoptic"
}

variable "env" {
  description = "Environment name (e.g. prod, staging). Used in the Cloud Map namespace and resource naming."
  type        = string
}

variable "tenant_short_name" {
  description = <<-EOT
    Lowercase letters/digits only, no hyphens or underscores. Matches the tenant short name
    used when generating config.json (`setup --prepare <tenant_short_name>`). Drives the
    server task role's DynamoDB table / S3 snapshot bucket ARN scoping.
  EOT
  type        = string
}

variable "vpc_cidr" {
  # If you already have other VPCs in this account (e.g. an EKS cluster's own VPC), pick a
  # range that doesn't overlap with them -- two VPCs with the same CIDR can each be created
  # fine on their own, but can never be peered or connected through a Transit Gateway later
  # without hitting a route conflict.
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.1.0.0/16"
}

variable "single_nat_gateway" {
  description = "Use one shared NAT Gateway instead of one per AZ. Default true for cost control; set false for HA."
  type        = bool
  default     = true
}

variable "container_insights" {
  description = "Enable ECS Container Insights on the cluster."
  type        = bool
  default     = false
}

# --- Images ---

variable "server_image" {
  description = "Docker image for the server + scheduler containers."
  type        = string
}

variable "ui_image" {
  description = "Docker image for the ui service."
  type        = string
}

variable "metrics_image" {
  description = "Docker image for the metrics (Qdrant) service."
  type        = string
}

variable "vectors_image" {
  description = "Docker image for the vectors (embedding model) service."
  type        = string
}

variable "mcp_image" {
  description = "Docker image for the mcp service."
  type        = string
  default     = "autoptic/mcp:1.10.0"
}

# --- Sizing (Fargate cpu/memory units) ---

variable "server_cpu" {
  type    = number
  default = 512
}

variable "server_memory" {
  type    = number
  default = 1024
}

variable "ui_cpu" {
  type    = number
  default = 256
}

variable "ui_memory" {
  type    = number
  default = 512
}

variable "metrics_cpu" {
  type    = number
  default = 256
}

variable "metrics_memory" {
  type    = number
  default = 512
}

variable "vectors_cpu" {
  description = "Sized for an ~1.3GB e5-large-v2 model by default. Increase if your model is bigger."
  type        = number
  default     = 1024
}

variable "vectors_memory" {
  type    = number
  default = 4096
}

variable "mcp_cpu" {
  type    = number
  default = 256
}

variable "mcp_memory" {
  type    = number
  default = 512
}

# --- server-specific ---

variable "server_health_path" {
  description = "Health check path on server's port 9999."
  type        = string
  default     = "health"
}

# --- mcp-specific ---

variable "mcp_admin_tools_enabled" {
  type    = bool
  default = false
}

variable "mcp_server_id" {
  description = "Required for the streamable_http transport. A lowercase slug. With mcp 1.10, the default secret dict needs mcp.autoptic.service.<mcp_server_id> with the value of mcp_server_token (README.md, \"Access control\")."
  type        = string
  default     = "local-demo"
}

variable "mcp_server_token" {
  description = "mcp's own outbound service credential to the Autoptic API (x-api-token), NOT the X-MCP-Token clients send. Leave it empty to auto-generate one. Released servers do not register it: add it as mcp.autoptic.service.<mcp_server_id> in the default secret dict (README.md, \"Access control\"). Use mcp 1.10.0 or later."
  type        = string
  default     = ""
  sensitive   = true
}

# --- S3 / config.json ---

variable "deploy_artifacts_bucket_name" {
  description = "Name of the S3 bucket holding config.json. If it already exists from the Copilot-era `aws s3 mb`, import it before applying."
  type        = string
}

variable "config_json_path" {
  description = "Local path to the edited config.json to upload to the deploy-artifacts bucket."
  type        = string
  default     = "./config.json"
}

# --- Deployment event logging (events.tf) ---

variable "ecs_event_log_retention_days" {
  description = <<-EOT
    Retention for the /aws/events/ecs/<app>-<env> log group that holds ECS deployment, service
    action, and task state change events. These are small JSON records, not container logs, so a
    long window is cheap. Set to 0 to keep them forever.
  EOT
  type        = number
  default     = 90
}

# --- Access control ---

variable "auth_enforce" {
  description = "Every API call needs a token. Set false only to opt out. With enforce off, the token and secret APIs answer callers with no token."
  type        = bool
  default     = true
}

variable "auth_observe" {
  description = "Log the auth decision for each call, and refuse no call. Use it to test the tokens before you turn on auth_enforce."
  type        = bool
  default     = false
}

variable "auth_permissions" {
  description = "Limit each token to its scopes. Needs auth_enforce."
  type        = bool
  default     = true

  validation {
    condition     = !var.auth_permissions || var.auth_enforce
    error_message = "auth_permissions = true requires auth_enforce = true."
  }
}

variable "auth_bootstrap_sha_enable" {
  description = "The scheduler and the web app fetch their own tokens with the SHA-256 of config.json."
  type        = bool
  default     = true
}

variable "auth_trusted_proxies" {
  description = "CIDR ranges of the proxies whose X-Forwarded-For header the API trusts. Empty means the VPC range (vpc_cidr), where the load balancers run. Server releases up to 1.217.4 do not read AUTH_TRUSTED_PROXIES: also set auth.trusted_proxies in config.json."
  type        = list(string)
  default     = []
}

variable "ui_role_mapping" {
  description = "Web-app role to API principal mapping, for example \"user=role.operator\". Empty uses the web-app default (admin=role.admin, user=role.viewer)."
  type        = string
  default     = ""
}

# --- Load balancers (alb.tf) ---

variable "alb_idle_timeout" {
  description = <<-EOT
    Idle timeout in seconds for the public and internal-server ALBs. A manual agent run holds one
    request open until the run finishes, through both the public ALB (browser -> ui) and the
    internal-server ALB (ui -> server). An MCP stream on /mcp also stays open with no data for
    long periods. The AWS default of 60s cuts these off with a 504, so this has to be at least the
    longest run on every ALB in that path.
  EOT
  type        = number
  default     = 300
}
