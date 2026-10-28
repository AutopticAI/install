output "public_alb_dns_name" {
  description = "How to reach the stack from outside the VPC: ui at /, the API at /autoptic-api/, mcp at /mcp."
  value       = aws_lb.public.dns_name
}

output "api_url" {
  description = "The API through the public ALB, over HTTP. After DNS-TLS-SETUP.md, use https://<domain>/autoptic-api/. Null when auth_enforce is off, because the API then stays internal."
  value       = local.public_api_enabled ? "http://${aws_lb.public.dns_name}/autoptic-api/" : null
}

output "mcp_url" {
  description = "The MCP endpoint for MCP clients, through the public ALB, over HTTP. After DNS-TLS-SETUP.md, use https://<domain>/mcp."
  value       = "http://${aws_lb.public.dns_name}/mcp"
}

output "internal_server_alb_dns_name" {
  value = aws_lb.internal_server.dns_name
}

output "internal_vectors_alb_dns_name" {
  value = aws_lb.internal_vectors.dns_name
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_cluster_arn" {
  value = module.ecs.cluster_arn
}

output "service_discovery_namespace_name" {
  description = "e.g. prod.autoptic.local -- used only by the vectors -> metrics hop."
  value       = aws_service_discovery_private_dns_namespace.this.name
}

output "deploy_artifacts_bucket_name" {
  value = module.deploy_artifacts.s3_bucket_id
}

output "efs_file_system_id" {
  value = aws_efs_file_system.this.id
}

output "mcp_secret_arn" {
  value = aws_secretsmanager_secret.mcp_token.arn
}

output "ecs_events_log_group_name" {
  description = "Log group holding ECS deployment, service action, and task state change events. Query it with the Logs Insights recipes in ECS-DEPLOYMENT-LOGGING.md."
  value       = module.ecs_event_logging.log_group_name
}

output "ecs_events_log_group_arn" {
  value = module.ecs_event_logging.log_group_arn
}
