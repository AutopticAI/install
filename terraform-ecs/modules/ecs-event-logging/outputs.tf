output "log_group_name" {
  description = "The value to give Autoptic's cloudwatchLogs data source."
  value       = local.log_group_name
}

output "log_group_arn" {
  description = "For downstream IAM scoping, if you do not want Resource: \"*\"."
  value       = local.log_group_arn
}

output "rule_names" {
  description = "EventBridge rule names created, for verification and teardown."
  value = compact([
    try(aws_cloudwatch_event_rule.region[0].name, ""),
    try(aws_cloudwatch_event_rule.cluster_deployments[0].name, ""),
    try(aws_cloudwatch_event_rule.cluster_tasks[0].name, ""),
    try(aws_cloudwatch_event_rule.service_deployments[0].name, ""),
    try(aws_cloudwatch_event_rule.service_tasks[0].name, ""),
  ])
}
