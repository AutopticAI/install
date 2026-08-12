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
  default     = "autoptic/mcp:latest"
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
  description = "Health check path on server's port 9999. Confirmed from the Kubernetes Helm chart's probes (values.yaml api.livenessProbe/readinessProbe)."
  type        = string
  default     = "health"
}

# --- mcp-specific ---

variable "mcp_admin_tools_enabled" {
  type    = bool
  default = false
}

variable "mcp_server_id" {
  description = "Required for the streamable_http transport. Must match a key suffix in the external token registry -- see mcp-server-id-env-var in the vault for context."
  type        = string
  default     = "local-demo"
}

variable "mcp_server_token" {
  description = "mcp's own outbound service credential to api-v2 (x-api-token), NOT the X-MCP-Token clients send. Must match a real mcp.autoptic.service.<mcp_server_id> secret already stored in api-v2 -- leaving this empty auto-generates a random value that will not match anything and silently breaks mcp's outbound auth."
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
