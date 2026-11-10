variable "name_prefix" {
  description = "Prefix for the IAM user and the Secrets Manager secret, for example autoptic-prod."
  type        = string
}

variable "tags" {
  description = "Tags for the IAM user and the secret."
  type        = map(string)
  default     = {}
}

variable "region" {
  description = "AWS region of the Bedrock Mantle endpoint. Bedrock Mantle serves GPT-6 Luna only in us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "key_age_days" {
  description = "Number of days until the Bedrock API key expires. Replace the key before this date."
  type        = number
  default     = 90
  nullable    = false

  validation {
    condition     = var.key_age_days >= 1 && var.key_age_days <= 36600
    error_message = "key_age_days must be from 1 to 36600."
  }
}
