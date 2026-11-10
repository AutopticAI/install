output "endpoint" {
  description = "Bedrock Mantle base URL for the prompt profile (vars.endpoint)."
  value       = local.endpoint
}

output "model_id" {
  description = "Model ID for the prompt profile (vars.model)."
  value       = local.model_id
}

output "api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret that holds the Bedrock API key."
  value       = aws_secretsmanager_secret.api_key.arn
}

output "api_key_expiration" {
  description = "Date and time (RFC3339) when the Bedrock API key expires."
  value       = aws_iam_service_specific_credential.this.expiration_date
}
