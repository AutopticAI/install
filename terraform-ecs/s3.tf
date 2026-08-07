module "deploy_artifacts" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.15.3"

  bucket = var.deploy_artifacts_bucket_name

  versioning = {
    enabled = true
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  tags = local.tags
}

# The s3-bucket module manages the bucket itself, not arbitrary object uploads.
# config.json's full journey: generated locally -> edited for this env -> uploaded here ->
# copied onto EFS by server's init sidecar (ecs.tf) -> read by server/scheduler from EFS.
resource "aws_s3_object" "config_json" {
  bucket = module.deploy_artifacts.s3_bucket_id
  key    = "config.json"
  source = var.config_json_path
  etag   = filemd5(var.config_json_path)
}
