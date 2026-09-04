# Captures ECS deployment, service action, and task state change events into one CloudWatch Logs
# group via EventBridge, so the history outlives the task, the service, and `terraform destroy`.
# `aws ecs describe-services` keeps only a short rolling window, held by the service itself.
#
# Every event pattern this module builds was checked with `aws events test-event-pattern` against
# real ECS events from a live deployment (region, cluster, and service scope; a negative control
# for service scope), not just AWS's documented examples. See ECS-DEPLOYMENT-LOGGING.md, section
# "Point Autoptic at it" onward, for the source events.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  log_group_name = coalesce(var.log_group_name, "/aws/events/ecs/${var.name_prefix}")

  # Constructed as a string, not read from the log group resource, so this also works when
  # create_log_group = false and the log group already exists somewhere else.
  log_group_arn = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}"

  ecs_arn_base = "arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}"

  cluster_arns = var.scope == "cluster" ? [
    for c in coalesce(var.cluster_names, []) : "${local.ecs_arn_base}:cluster/${c}"
  ] : []

  # Trailing slash matters: without it the prefix also matches a cluster named
  # "<name>-something-else" in the same account. Confirmed live with test-event-pattern.
  cluster_service_prefixes = var.scope == "cluster" ? [
    for c in coalesce(var.cluster_names, []) : { prefix = "${local.ecs_arn_base}:service/${c}/" }
  ] : []

  # "ECS Task State Change" carries no service ARN, only `detail.group`, formatted
  # "service:<service-name>" -- the short name, not the ARN. Derived from the last path segment
  # of each service ARN. Confirmed live with test-event-pattern, including a negative control.
  service_groups = var.scope == "service" ? [
    for arn in coalesce(var.service_arns, []) : "service:${element(split("/", arn), length(split("/", arn)) - 1)}"
  ] : []
}

resource "aws_cloudwatch_log_group" "this" {
  count = var.create_log_group ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.retention_in_days
  tags              = var.tags
}

# EventBridge writes to CloudWatch Logs through a resource policy on the log group, not through an
# IAM role on the target. The AWS console creates this policy for you. The CLI, the API, and
# Terraform do not. Without it the rules match, the targets fire, and nothing is ever written --
# with no error surfaced anywhere.
data "aws_iam_policy_document" "events_to_logs" {
  count = var.create_resource_policy ? 1 : 0

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

    resources = ["${local.log_group_arn}:*"]
  }
}

# Scoped to this one log group. CloudWatch Logs allows only 10 resource policies per Region per
# account, capped at 5120 characters each -- in a shared account, prefer one broad
# "/aws/events/*" policy over one per stack (set create_resource_policy = false here).
resource "aws_cloudwatch_log_resource_policy" "this" {
  count = var.create_resource_policy ? 1 : 0

  policy_name     = "${var.name_prefix}-ecs-events-to-cwlogs"
  policy_document = data.aws_iam_policy_document.events_to_logs[0].json
}

# --- scope = "region": one rule, no ARN construction ---

resource "aws_cloudwatch_event_rule" "region" {
  count = var.scope == "region" ? 1 : 0

  name        = "${var.name_prefix}-ecs-events"
  description = "All ECS deployment, service action, and task state change events in this region."

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change", "ECS Service Action", "ECS Task State Change"]
  })
}

resource "aws_cloudwatch_event_target" "region" {
  count = var.scope == "region" ? 1 : 0

  rule      = aws_cloudwatch_event_rule.region[0].name
  target_id = "cloudwatch-logs"
  arn       = local.log_group_arn

  depends_on = [aws_cloudwatch_log_resource_policy.this]
}

# --- scope = "cluster": two rules, because ECS carries the cluster differently per event type ---

resource "aws_cloudwatch_event_rule" "cluster_deployments" {
  count = var.scope == "cluster" ? 1 : 0

  name        = "${var.name_prefix}-ecs-deployments"
  description = "ECS deployment state changes and service actions for the named clusters."

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change", "ECS Service Action"]
    resources     = local.cluster_service_prefixes
  })
}

resource "aws_cloudwatch_event_rule" "cluster_tasks" {
  count = var.scope == "cluster" ? 1 : 0

  name        = "${var.name_prefix}-ecs-tasks"
  description = "ECS task state changes for the named clusters."

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn = local.cluster_arns
    }
  })
}

resource "aws_cloudwatch_event_target" "cluster_deployments" {
  count = var.scope == "cluster" ? 1 : 0

  rule      = aws_cloudwatch_event_rule.cluster_deployments[0].name
  target_id = "cloudwatch-logs"
  arn       = local.log_group_arn

  depends_on = [aws_cloudwatch_log_resource_policy.this]
}

resource "aws_cloudwatch_event_target" "cluster_tasks" {
  count = var.scope == "cluster" ? 1 : 0

  rule      = aws_cloudwatch_event_rule.cluster_tasks[0].name
  target_id = "cloudwatch-logs"
  arn       = local.log_group_arn

  depends_on = [aws_cloudwatch_log_resource_policy.this]
}

# --- scope = "service": two rules, matched on the exact service instead of a cluster prefix ---

resource "aws_cloudwatch_event_rule" "service_deployments" {
  count = var.scope == "service" ? 1 : 0

  name        = "${var.name_prefix}-ecs-deployments"
  description = "ECS deployment state changes and service actions for the named services."

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change", "ECS Service Action"]
    resources     = coalesce(var.service_arns, [])
  })
}

resource "aws_cloudwatch_event_rule" "service_tasks" {
  count = var.scope == "service" ? 1 : 0

  name        = "${var.name_prefix}-ecs-tasks"
  description = "ECS task state changes for the named services."

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      group = local.service_groups
    }
  })
}

resource "aws_cloudwatch_event_target" "service_deployments" {
  count = var.scope == "service" ? 1 : 0

  rule      = aws_cloudwatch_event_rule.service_deployments[0].name
  target_id = "cloudwatch-logs"
  arn       = local.log_group_arn

  depends_on = [aws_cloudwatch_log_resource_policy.this]
}

resource "aws_cloudwatch_event_target" "service_tasks" {
  count = var.scope == "service" ? 1 : 0

  rule      = aws_cloudwatch_event_rule.service_tasks[0].name
  target_id = "cloudwatch-logs"
  arn       = local.log_group_arn

  depends_on = [aws_cloudwatch_log_resource_policy.this]
}
