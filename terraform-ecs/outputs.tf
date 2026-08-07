output "public_alb_dns_name" {
  description = "How to reach ui from outside the VPC."
  value       = aws_lb.public.dns_name
}

output "internal_server_alb_dns_name" {
  value = aws_lb.internal_server.dns_name
}

output "internal_vectors_alb_dns_name" {
  value = aws_lb.internal_vectors.dns_name
}

output "internal_mcp_alb_dns_name" {
  value = aws_lb.internal_mcp.dns_name
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
