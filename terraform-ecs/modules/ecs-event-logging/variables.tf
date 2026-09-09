variable "name_prefix" {
  description = "Prefix for the EventBridge rules and the CloudWatch Logs resource policy. Does not affect the log group name."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch Logs group to write events into. Defaults to /aws/events/ecs/<name_prefix>."
  type        = string
  default     = null
}

variable "retention_in_days" {
  description = "Log group retention, in days. These are small control-plane records, not container logs. Set to 0 to keep them forever."
  type        = number
  default     = 90
}

variable "scope" {
  description = <<-EOT
    Which ECS events to capture:
      "region"  - every ECS event in the region. One rule, no ARN construction. The right
                  default for most people.
      "cluster" - only the clusters named in cluster_names.
      "service" - only the services named in service_arns.
  EOT
  type        = string
  default     = "region"

  validation {
    condition     = contains(["region", "cluster", "service"], var.scope)
    error_message = "scope must be one of: \"region\", \"cluster\", \"service\"."
  }
}

variable "cluster_names" {
  description = "ECS cluster names to capture. Required when scope = \"cluster\". Bare names, not ARNs."
  type        = list(string)
  default     = null
}

variable "service_arns" {
  description = <<-EOT
    Full service ARNs to capture, e.g.
    "arn:aws:ecs:<region>:<account>:service/<cluster>/<service>". Required when scope = "service".
  EOT
  type        = list(string)
  default     = null
}

variable "create_log_group" {
  description = "Set false to write into a log group created elsewhere. Pass its name in log_group_name."
  type        = bool
  default     = true
}

variable "create_resource_policy" {
  description = <<-EOT
    Set false if you are at or near the 10-per-region CloudWatch Logs resource policy quota.
    When false, add the events.amazonaws.com / delivery.logs.amazonaws.com grant for this log
    group to an existing policy yourself -- this module still needs that grant to exist
    somewhere, it just will not create a second one.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the log group this module creates."
  type        = map(string)
  default     = {}
}
