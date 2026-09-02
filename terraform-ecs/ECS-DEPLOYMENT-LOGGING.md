# ECS deployment logging

`events.tf` copies every ECS deployment event, service action, and task state change into one
CloudWatch log group. The history then outlives the task, the service, and `terraform destroy`.

## Why this is necessary

`aws ecs describe-services` returns only a short rolling window of service events. The service
holds those events itself. If you delete the service, the history goes with it. A stopped task
keeps its `stoppedReason` for a limited time only.

Every deployment failure in [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) was found by hand, from
`describe-services` output and stopped-task reasons, and only while the broken task still
existed. This log group removes that time limit.

## What Terraform creates

| Resource | Name | Purpose |
| --- | --- | --- |
| `aws_cloudwatch_log_group` | `/aws/events/ecs/<app>-<env>` | Holds the events. |
| `aws_cloudwatch_log_resource_policy` | `<app>-<env>-ecs-events-to-cwlogs` | Lets EventBridge write to the group. |
| `aws_cloudwatch_event_rule` | `<app>-<env>-ecs-deployments` | Deployment state changes and service actions. |
| `aws_cloudwatch_event_rule` | `<app>-<env>-ecs-tasks` | Task state changes. |
| `aws_cloudwatch_event_target` | 2 targets | Sends both rules to the log group. |

Retention is 90 days by default. To change it, set `ecs_event_log_retention_days`.

## Apply it

The rules are part of the main stack. No separate step is necessary.

```bash
terraform apply
```

To apply only the logging, before the cluster exists:

```bash
terraform apply \
  -target=aws_cloudwatch_log_group.ecs_events \
  -target=aws_cloudwatch_log_resource_policy.ecs_events \
  -target=aws_cloudwatch_event_rule.ecs_deployments \
  -target=aws_cloudwatch_event_rule.ecs_tasks \
  -target=aws_cloudwatch_event_target.ecs_deployments_to_logs \
  -target=aws_cloudwatch_event_target.ecs_tasks_to_logs
```

Nothing in `events.tf` refers to `module.ecs`. The cluster and service ARNs are built as strings.
A rule matches only events that arrive after the rule exists. If a rule depends on the cluster,
it always misses the first deployment. That first deployment is the one most worth capturing.

## Watch a deployment live

```bash
aws logs tail "$(terraform output -raw ecs_events_log_group_name)" --follow --format short
```

Then start the deployment in a second terminal:

```bash
aws ecs update-service --cluster <cluster> --service vectors --force-new-deployment
```

## Query recipes

Run these in CloudWatch Logs Insights, against the group named by the
`ecs_events_log_group_name` output.

**Every event for one service, newest first**

```
fields @timestamp, `detail-type`, detail.eventName, detail.reason
| filter resources.0 like /vectors/
| sort @timestamp desc
| limit 100
```

**Why tasks stopped, with the container exit code**

```
fields @timestamp, detail.stoppedReason, detail.containers.0.name, detail.containers.0.exitCode
| filter `detail-type` = "ECS Task State Change" and detail.lastStatus = "STOPPED"
| sort @timestamp desc
| limit 50
```

This is the query that answers "why did the deployment fail". `stoppedReason` and `exitCode` hold
the real cause.

**Errors only, across all 5 services**

```
fields @timestamp, resources.0, detail.eventName, detail.reason
| filter detail.eventType = "ERROR"
| sort @timestamp desc
| limit 50
```

**Deployment timeline**

```
fields @timestamp, resources.0, detail.eventName, detail.reason
| filter `detail-type` = "ECS Deployment State Change"
| sort @timestamp desc
| limit 50
```

Backticks around `detail-type` are necessary. The hyphen makes it an invalid bare field name.

## Four things that break this

**1. A missing resource policy fails silently.** EventBridge writes to CloudWatch Logs through a
resource policy on the log group, not through an IAM role on the target. The AWS console adds
this policy for you. The CLI, the API, and Terraform do not. Without the policy the rules match,
the targets fire, and nothing is written. No error appears anywhere.

**2. Never set `role_arn` on a CloudWatch Logs target.** AWS states this directly. The apply still
succeeds. Delivery stops.

**3. Only 10 resource policies are allowed per Region per account.** This quota is not adjustable.
Each policy holds at most 5120 characters. `events.tf` scopes its policy to one log group. In a
shared account, prefer a single `/aws/events/*` policy over one policy per stack.

**4. `SERVICE_DEPLOYMENT_FAILED` needs the deployment circuit breaker.** AWS sends this event only
for services that have the circuit breaker turned on. No service in `ecs.tf` turns it on, so this
event never arrives today. The rules still capture the task-level `stoppedReason`, which carries
the same information.

To turn the circuit breaker on, add this to a service in `ecs.tf`:

```hcl
deployment_circuit_breaker = {
  enable   = true
  rollback = true
}
```

CAUTION: `rollback = true` makes ECS revert a failed deployment automatically. This changes
deployment behavior, so it is off in this stack until someone decides otherwise.

## Verify the configuration

Confirm that the rules match real events. The AWS API tests a pattern against an event without
any deployment:

```bash
aws events test-event-pattern \
  --event-pattern "$(aws events describe-rule --name <app>-<env>-ecs-tasks --query EventPattern --output text)" \
  --event '{"version":"0","id":"x","detail-type":"ECS Task State Change","source":"aws.ecs","account":"<account>","time":"2026-01-01T00:00:00Z","region":"<region>","resources":["arn:aws:ecs:<region>:<account>:task/<app>-<env>/abc"],"detail":{"clusterArn":"arn:aws:ecs:<region>:<account>:cluster/<app>-<env>","lastStatus":"STOPPED"}}'
```

The result is `true` when the pattern matches.

Confirm that the resource policy exists:

```bash
aws logs describe-resource-policies --query "resourcePolicies[?policyName=='<app>-<env>-ecs-events-to-cwlogs']"
```

If this returns an empty list, EventBridge cannot write, and the log group stays empty.

## Scoping, and why there are two rules

`ECS Deployment State Change` carries no `clusterArn` in its `detail` object. It carries only the
service ARN, in the top-level `resources` array. `ECS Service Action` carries both. So one rule
filters on the `resources` prefix, which is the only expression that scopes both detail-types to
one cluster.

`ECS Task State Change` carries `clusterArn` in `detail`, so the second rule filters on that.

Both rules write to the same log group. One query then covers a whole deployment.

## What these events do not capture

These events come from the ECS control plane. They record state changes only. Three gaps matter:

1. **They do not record who acted.** The events carry no `userIdentity` field. To find out who
   started a deployment, or who deleted a service, use CloudTrail.
2. **They do not record API calls that change no state.** `TagResource`, `DeregisterTaskDefinition`,
   and `PutAccountSetting` never produce a task event or a deployment event.
3. **They do not record rejected API calls.** If a call fails authorization or validation, no
   state changes, so no event arrives. CloudTrail records the attempt, with an `errorCode`.

A full audit needs both sources. CloudTrail answers "who tried what". This log group answers
"what then happened". Neither source answers both.

## The AWS console alternative

The ECS console has a built-in event capture feature. It creates the EventBridge rule and the log
group for you, scoped to one cluster, and adds a query interface with templates. It writes to
`/aws/events/ecs/containerinsights/<clusterName>/performance`. Retention is configurable from 1
day to 10 years. AWS bills it at standard EventBridge and CloudWatch Logs rates.

`events.tf` does the same job in code, which keeps the pipeline in version control and applies it
to every environment.

CAUTION: Do not enable both. Two rules that match the same events write two copies to two log
groups, and AWS charges for both.
