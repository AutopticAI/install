# Deployment + task history for the ECS cluster: EventBridge -> CloudWatch Logs.
#
# Why this exists: `aws ecs describe-services` returns only a short, rolling window of service
# events, held by the service itself -- destroy the service and the whole history goes with it.
# Every deployment failure on this project so far (IAM on the wrong role, a missing env var, an
# EFS uid mismatch, a stale image) was reconstructed by hand from `describe-services` plus
# stopped-task reasons, and only while the broken task still existed. These two rules copy the
# same events into a real log group, so the history outlives the task, the service, and the
# `terraform destroy`.
#
# Ordering note: nothing here references module.ecs. The cluster and service ARNs are built as
# strings from the same local.name_prefix that names the cluster, so the rules can be created
# *before* the cluster exists. An EventBridge rule only matches events that arrive after it is in
# place. If a rule depends on the cluster, it always misses the first deployment -- which is
# exactly the deployment worth capturing on a fresh apply.

data "aws_partition" "current" {}

locals {
  ecs_events_log_group_name = "/aws/events/ecs/${local.name_prefix}"

  ecs_arn_base = "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}"

  ecs_cluster_arn = "${local.ecs_arn_base}:cluster/${local.name_prefix}"

  # Trailing slash matters: it stops the prefix from also matching a cluster named
  # "<name_prefix>-something-else" in the same account.
  ecs_service_arn_prefix = "${local.ecs_arn_base}:service/${local.name_prefix}/"
}

resource "aws_cloudwatch_log_group" "ecs_events" {
  name              = local.ecs_events_log_group_name
  retention_in_days = var.ecs_event_log_retention_days
}

# EventBridge writes to CloudWatch Logs through a resource policy on the log group, not through
# an IAM role on the target. The AWS console creates this policy for you. The CLI, the API, and
# Terraform do not. Without it the rules match, the targets fire, and nothing is ever written,
# with no error surfaced anywhere. That silent-success failure mode is the single most common way
# this integration is "configured" but dead.
data "aws_iam_policy_document" "ecs_events_to_logs" {
  statement {
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "events.amazonaws.com",
        "delivery.logs.amazonaws.com",
      ]
    }

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    # aws_cloudwatch_log_group.arn has the API's ":*" suffix stripped, so append it here -- the
    # policy has to cover the log streams inside the group, not just the group itself.
    resources = ["${aws_cloudwatch_log_group.ecs_events.arn}:*"]
  }
}

# Scoped to this one log group rather than the "/aws/events/*" wildcard in the AWS example.
# CloudWatch Logs allows only 10 resource policies per Region per account and caps each at 5120
# characters, so in a shared account prefer one broad "/aws/events/*" policy over one per stack.
resource "aws_cloudwatch_log_resource_policy" "ecs_events" {
  policy_name     = "${local.name_prefix}-ecs-events-to-cwlogs"
  policy_document = data.aws_iam_policy_document.ecs_events_to_logs.json
}

# Rule 1: service-level events.
#
# "ECS Deployment State Change" carries no clusterArn in its detail -- only the service ARN, in
# the top-level `resources` array. "ECS Service Action" carries both. Filtering on the `resources`
# prefix is therefore the only expression that scopes *both* detail-types to this cluster in a
# single rule.
resource "aws_cloudwatch_event_rule" "ecs_deployments" {
  name        = "${local.name_prefix}-ecs-deployments"
  description = "ECS deployment state changes and service actions for the ${local.name_prefix} cluster."

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change", "ECS Service Action"]
    resources     = [{ prefix = local.ecs_service_arn_prefix }]
  })
}

# Rule 2: task-level events. This is the one that carries `stoppedReason` and each container's
# `exitCode` -- the fields that actually say why a deployment failed.
resource "aws_cloudwatch_event_rule" "ecs_tasks" {
  name        = "${local.name_prefix}-ecs-tasks"
  description = "ECS task state changes for the ${local.name_prefix} cluster."

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn = [local.ecs_cluster_arn]
    }
  })
}

# Both rules land in the same log group so one Logs Insights query covers a whole deployment.
#
# No role_arn on either target: AWS is explicit that a CloudWatch Logs target must not set one.
# Setting it does not fail the apply -- delivery just stops.
resource "aws_cloudwatch_event_target" "ecs_deployments_to_logs" {
  rule      = aws_cloudwatch_event_rule.ecs_deployments.name
  target_id = "cloudwatch-logs"
  arn       = aws_cloudwatch_log_group.ecs_events.arn

  depends_on = [aws_cloudwatch_log_resource_policy.ecs_events]
}

resource "aws_cloudwatch_event_target" "ecs_tasks_to_logs" {
  rule      = aws_cloudwatch_event_rule.ecs_tasks.name
  target_id = "cloudwatch-logs"
  arn       = aws_cloudwatch_log_group.ecs_events.arn

  depends_on = [aws_cloudwatch_log_resource_policy.ecs_events]
}
