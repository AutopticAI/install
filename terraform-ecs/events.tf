# Deployment + task history for the ECS cluster: EventBridge -> CloudWatch Logs.
#
# Why this exists: `aws ecs describe-services` returns only a short, rolling window of service
# events, held by the service itself -- destroy the service and the whole history goes with it.
# Without it, a failed deployment can only be read from `describe-services` and stopped-task
# reasons while the broken task still exists. This module copies the same
# events into a real log group, so the history outlives the task, the service, and the
# `terraform destroy`.
#
# This calls the same module a customer can point at their own clusters -- see
# modules/ecs-event-logging/ and ECS-DEPLOYMENT-LOGGING.md, "Option D". Scoped to "cluster" here
# so this stack captures only the cluster it creates, not the whole region.
module "ecs_event_logging" {
  source = "./modules/ecs-event-logging"

  name_prefix       = local.name_prefix
  retention_in_days = var.ecs_event_log_retention_days

  scope         = "cluster"
  cluster_names = [local.name_prefix]

  tags = local.tags
}
