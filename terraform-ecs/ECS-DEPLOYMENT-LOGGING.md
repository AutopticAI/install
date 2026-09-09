# Capture ECS deployment events for Autoptic

Amazon ECS emits an event every time a deployment starts, a service takes an action, or a task
changes state. Nothing stores them. `aws ecs describe-services` returns only a short rolling
window. The service itself holds that window, so deleting the service deletes the history with
it. A stopped task keeps its `stoppedReason` for a limited time, then loses it.

That is a problem if you want to answer "what changed, and when" after the fact. This is what
Autoptic needs, to line a deployment up against a change in behavior.

The fix is to gateway those events, through EventBridge, into a CloudWatch log group. The events
already flow to EventBridge on the default event bus, whether or not you listen. You are just
giving them somewhere durable to land. Autoptic reads CloudWatch Logs natively, so once the
events sit in a log group, you have nothing further to install.

```
ECS control plane ──▶ EventBridge (default bus) ──▶ rule ──▶ CloudWatch log group ──▶ Autoptic
```

You can set this up in the AWS console, from the CLI, or with Terraform. All four options below
produce the same result.

---

## What you get

Three event types land in the log group. Each answers a different question.

| Event (`detail-type`) | Answers | Key fields in `detail` |
|---|---|---|
| `ECS Deployment State Change` | Did a deployment start, finish, or fail? | `eventName`, `eventType`, `reason`, `deploymentId`, `clusterArn` |
| `ECS Service Action` | Did the service struggle: placement failures, capacity, steady state? | `eventName`, `eventType`, `clusterArn`, `createdAt`, `reason` |
| `ECS Task State Change` | What did individual tasks do, and why did one stop? | `clusterArn`, `taskDefinitionArn`, `lastStatus`, `desiredStatus`, `containers[]`, `group`, and on stop, `stoppedReason` and `stopCode` |

Two fields matter most:

- **`detail.taskDefinitionArn`** on task events. The revision suffix, for example `.../my-app:47`,
  is the identity of what got deployed. Use this field to correlate a behavior change against a
  release.
- **`detail.stoppedReason`** and **`detail.stopCode`** on stopped tasks. This is where the real
  cause of a failed deployment lives: a missing environment variable, an image pull failure, a
  health check that never passed.

Deployment `eventName` values include `SERVICE_DEPLOYMENT_IN_PROGRESS`,
`SERVICE_DEPLOYMENT_COMPLETED`, and `SERVICE_DEPLOYMENT_FAILED`.

AWS documents `SERVICE_DEPLOYMENT_FAILED` as firing when a CloudWatch alarm triggers, or the
deployment circuit breaker detects a failure. If your services have neither, you will not see
this event. Use the task-level `stoppedReason` instead, to infer deployment failure. See
[Amazon ECS service deployment state change events](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs_service_deployment_events.html).

**Sample events.** Trimmed, real events captured from a live deployment, one per `detail-type`:

<details>
<summary><code>ECS Deployment State Change</code></summary>

```json
{
  "detail-type": "ECS Deployment State Change",
  "source": "aws.ecs",
  "resources": ["arn:aws:ecs:us-west-2:025066242351:service/autoptic-test/mcp"],
  "detail": {
    "eventType": "INFO",
    "eventName": "SERVICE_DEPLOYMENT_IN_PROGRESS",
    "clusterArn": "arn:aws:ecs:us-west-2:025066242351:cluster/autoptic-test",
    "deploymentId": "ecs-svc/2757582648257641111",
    "updatedAt": "2026-09-04T17:00:01.714Z",
    "reason": "ECS deployment ecs-svc/2757582648257641111 in progress."
  }
}
```

</details>

<details>
<summary><code>ECS Service Action</code></summary>

```json
{
  "detail-type": "ECS Service Action",
  "source": "aws.ecs",
  "resources": ["arn:aws:ecs:us-west-2:025066242351:service/autoptic-test/mcp"],
  "detail": {
    "eventType": "INFO",
    "eventName": "SERVICE_STEADY_STATE",
    "clusterArn": "arn:aws:ecs:us-west-2:025066242351:cluster/autoptic-test",
    "createdAt": "2026-09-04T17:00:58.249Z"
  }
}
```

</details>

<details>
<summary><code>ECS Task State Change</code></summary>

```json
{
  "detail-type": "ECS Task State Change",
  "source": "aws.ecs",
  "resources": ["arn:aws:ecs:us-west-2:025066242351:task/autoptic-test/14fb0529267b42c58f411ea814184102"],
  "detail": {
    "clusterArn": "arn:aws:ecs:us-west-2:025066242351:cluster/autoptic-test",
    "group": "service:mcp",
    "lastStatus": "PROVISIONING",
    "desiredStatus": "RUNNING",
    "taskDefinitionArn": "arn:aws:ecs:us-west-2:025066242351:task-definition/mcp:7",
    "startedBy": "ecs-svc/2757582648257641111",
    "containers": [
      {
        "name": "mcp",
        "image": "autoptic/mcp:latest",
        "lastStatus": "PENDING"
      }
    ]
  }
}
```

`detail.group` carries the short service name as `service:<name>` — this is the field the
`service` scope below matches on for task events, since task events carry no service ARN.

</details>

No task stopped abnormally during this capture, so `stoppedReason` and `stopCode` are not shown
above. `detail.containers[].exitCode` is real and populated: the same capture showed `exitCode: 0`
on a container that exited normally. AWS's documented schema does not list it, but it is present
in practice, at least for a normal exit; treat a nonzero value as similarly reliable rather than
confirmed separately.

---

## Before you start

Three decisions and one check.

**1. How much do you want to capture?**

| Scope | Use when |
|---|---|
| Whole region | You want every ECS deployment in the account visible. Simplest: one rule, no ARN construction. Start here unless you have a reason not to. |
| One cluster | You run several clusters, and only some are in scope. |
| One service | Narrow pilot, or a noisy cluster where only one service matters. |

All three scopes are available in the console (Option B), from the CLI (Option C), and in the
Terraform module (Option D) through the `scope` input.

**2. What should the log group be called?**

Nothing depends on the name except the configuration you give Autoptic. Use whatever your naming
standard requires. Without one, `/aws/events/ecs/<your-app>-<env>` is a reasonable default and
matches the AWS convention for EventBridge targets.

**3. How long do you want to keep it?**

These are small JSON control-plane records, not container logs: a tiny fraction of what your
application logging produces. AWS does not charge for events published to the default event bus
by AWS services. The cost here is CloudWatch Logs ingestion and storage, at standard rates. See
[CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/). 90 days is a sensible start.

**Check: how many CloudWatch Logs resource policies do you already have?**

```bash
aws logs describe-resource-policies --query 'length(resourcePolicies)'
```

EventBridge writes to a log group through a resource policy on the log group, and AWS allows only
**10 of these per Region per account**. The quota is not adjustable. If the count returns 8 or
more, do not create another. Add the grant to an existing policy instead, typically a broad one
covering `/aws/events/*`, and skip the policy-creation step below. On the Terraform module (Option
D), set `create_resource_policy = false` and add the grant to your existing policy yourself.

---

## Option A — AWS console, built-in (fastest)

CloudWatch Container Insights has this built in. It creates the EventBridge rule and the log
group for you. The console labels differ from an earlier AWS blog post about this feature;
these steps are confirmed against the console as it exists today.

1. Open the [CloudWatch console](https://console.aws.amazon.com/cloudwatch/).
2. Choose **Infrastructure Monitoring → Container Insights**.
3. In the **Performance dashboard views** panel, on the left, choose **Clusters**, then pick
   your cluster under **Filters**.
4. Expand **More dashboard views**, near the bottom of that same left panel.
5. Choose **Lifecycle events**, then choose **Configure lifecycle events**.

**The trade-off:** you do not choose the log group name. It writes to
`/aws/events/ecs/containerinsights/<clusterName>/performance` — confirmed live, exactly as this
doc guessed.

**Confirmed live, in this pass, on a real deployment:** both `ECS Deployment State Change` and
`ECS Task State Change` land in that log group. This overturns an earlier caution in this doc —
AWS's Container Insights lifecycle-events documentation lists only container instance, task, and
service-action events, not deployment events by name, but the real behavior includes them.

**A real gap found in this pass, not previously documented:** the console does **not** attach
the CloudWatch Logs resource policy for this log group. This contradicts an earlier version of
this doc, which credited Option A (and Option B) with doing that automatically. Confirmed live:
after choosing "Configure lifecycle events," the rule and the target were both created and
correctly configured, but zero events arrived — the exact silent-failure mode described in
[Troubleshooting](#troubleshooting). Adding the resource policy by hand (the same statement
shown in [Option C](#option-c--aws-cli)'s step 2, with this log group's ARN) fixed it
immediately; events landed within seconds of the next deployment. Do this check right after
enabling Option A, every time:

```bash
aws logs describe-resource-policies --query "resourcePolicies[?policyName=='ecs-events-to-cwlogs']"
```

An empty result means you need to add the policy yourself, exactly as under Option C.

Give Autoptic that log group name, and you are done. Skip to
[Point Autoptic at it](#point-autoptic-at-it).

---

## Option B — AWS console, your own rule

Use this when you want to choose the log group name or the scope. It has a real advantage over
the CLI and Terraform paths: **the console attaches the CloudWatch Logs resource policy for
you**, which is the step most often missed elsewhere.

**Create the log group**

1. CloudWatch console → **Logs → Log groups → Create log group**.
2. Name it per your standard. Set retention.

**Create the rule**

3. Open the [EventBridge console](https://console.aws.amazon.com/events/) → **Rules → Create
   rule**.
4. Name the rule. Leave the event bus as **default**: ECS publishes there.
5. Rule type: **Rule with an event pattern**.
6. Event source: **AWS events or EventBridge partner events**.
7. Under event pattern, choose **AWS services → Amazon Elastic Container Service (ECS)**, then
   select the event types you want. To capture all three at once, use the custom pattern below
   instead of the guided picker.
8. Target: **CloudWatch log group**, and select the group you created.
9. Create the rule. Do **not** attach an IAM role to the target — see
   [Troubleshooting](#troubleshooting).

Console labels shift between AWS releases. This walkthrough has not been re-checked against the
current console in this pass; if a step does not match what you see, the AWS EventBridge console
docs are the fallback.

**Event patterns**

Whole region, all three event types. Confirmed live, against real events of all three types, with
`aws events test-event-pattern`:

```json
{
  "source": ["aws.ecs"],
  "detail-type": [
    "ECS Deployment State Change",
    "ECS Service Action",
    "ECS Task State Change"
  ]
}
```

Scoped to one or more clusters, **one rule** is enough. All three event types carry `clusterArn`
in `detail` — confirmed live, twice, on two different clusters, both with
`aws events test-event-pattern` and by real delivery through an applied rule:

```json
{
  "source": ["aws.ecs"],
  "detail-type": [
    "ECS Deployment State Change",
    "ECS Service Action",
    "ECS Task State Change"
  ],
  "detail": { "clusterArn": ["arn:aws:ecs:<region>:<account>:cluster/<cluster>"] }
}
```

List more than one `clusterArn` to cover more than one cluster with the same rule.

**History, since this contradicts what an earlier version of this doc said twice:** the original
doc claimed `ECS Deployment State Change` carries no `clusterArn`, and justified a two-rule split
on that basis (one rule matching a service-ARN prefix, one matching `clusterArn`). A first
correction, earlier in this same effort, kept the two-rule split but fixed the stated reason. A
second, later test — applying the real Terraform module against a second live cluster, not just
checking the pattern — confirmed `clusterArn` is present on every event type in practice, not an
edge case, so the whole two-rule split was unnecessary for cluster scope. The module now builds
one rule for this scope.

Narrow to one or more specific services instead of a whole cluster by matching the exact service
ARNs, with no prefix needed, and by matching task events on `detail.group`
(`"service:<name>"`, not the ARN — this is the only field task events carry that identifies the
service):

```json
{
  "source": ["aws.ecs"],
  "detail-type": ["ECS Deployment State Change", "ECS Service Action"],
  "resources": ["arn:aws:ecs:<region>:<account>:service/<cluster>/<service>"]
}
```

```json
{
  "source": ["aws.ecs"],
  "detail-type": ["ECS Task State Change"],
  "detail": { "group": ["service:<service>"] }
}
```

Both the region-wide pattern and the service-scoped pair above were confirmed live in this pass,
with `aws events test-event-pattern` against real captured events, including a negative control
for the service match (a pattern for one service must not match another service's task event —
confirmed it does not).

---

## Option C — AWS CLI

Portable to CloudFormation, CDK, or Pulumi: the same four API calls, in any order.

```bash
LOG_GROUP="/your/standard/ecs-events"
RULE_NAME="ecs-deployment-events"
REGION="us-east-1"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# 1. Log group
aws logs create-log-group --log-group-name "$LOG_GROUP"
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 90

# 2. Resource policy. EventBridge cannot write without this, and will not tell you so.
#    Skip this if you are adding the grant to an existing policy instead (see "Before you start").
aws logs put-resource-policy \
  --policy-name "ecs-events-to-cwlogs" \
  --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": ["events.amazonaws.com", "delivery.logs.amazonaws.com"] },
    "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
    "Resource": "arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}:*"
  }]
}
JSON
)"

# 3. Rule
aws events put-rule \
  --name "$RULE_NAME" \
  --event-pattern '{"source":["aws.ecs"],"detail-type":["ECS Deployment State Change","ECS Service Action","ECS Task State Change"]}'

# 4. Target. Note there is no --role-arn here, on purpose.
aws events put-targets \
  --rule "$RULE_NAME" \
  --targets "Id=cloudwatch-logs,Arn=arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}"
```

These four commands have not been run verbatim end to end in this pass — the Terraform path
(Option D) was exercised live instead, against the same four underlying API calls. If the
heredoc-based resource policy document does not survive your shell's quoting, build the JSON in a
file first and pass `--policy-document file://policy.json`.

The `:*` suffix on the resource policy's `Resource` matters. The policy must cover the log streams
inside the group, not only the group itself.

---

## Option D — Terraform

Use this if you manage infrastructure with Terraform. The module works against any ECS cluster,
whether or not Autoptic's own install created it.

```hcl
module "ecs_event_logging" {
  source = "github.com/AutopticAI/install//terraform-ecs/modules/ecs-event-logging"

  name_prefix       = "acme-prod"                  # names the EventBridge rules
  log_group_name    = "/acme/platform/ecs-events"  # your naming standard
  retention_in_days = 90

  scope         = "cluster"       # "region" | "cluster" | "service"
  cluster_names = ["acme-prod"]
}
```

```bash
terraform init && terraform apply
```

**Inputs**

| Input | Default | Notes |
|---|---|---|
| `name_prefix` | — | Names the EventBridge rules and the resource policy. Does not affect the log group name. |
| `log_group_name` | `/aws/events/ecs/<name_prefix>` | Use your own standard. Nothing depends on this name except the configuration you give Autoptic. |
| `retention_in_days` | `90` | `0` keeps events forever. These are small control-plane records, not container logs. |
| `scope` | `"region"` | `region` captures every ECS event in the region: simplest, and the right default for most people. `cluster` and `service` narrow it. |
| `cluster_names` | `null` | Required when `scope = "cluster"`. Bare cluster names, not ARNs. |
| `service_arns` | `null` | Required when `scope = "service"`. Full service ARNs. |
| `create_log_group` | `true` | Set `false` if you create log groups centrally and are passing in an existing one. |
| `create_resource_policy` | `true` | Set `false` if you are near the 10-per-region quota and are adding the grant to an existing policy. |

**Outputs**

| Output | Use |
|---|---|
| `log_group_name` | The value to give Autoptic's `cloudwatchLogs` data source. |
| `log_group_arn` | For downstream IAM scoping, if you do not want `Resource: "*"`. |
| `rule_names` | For verification and teardown. |

**Scope note.** `scope = "region"` and `scope = "cluster"` each build a single rule: every ECS
event carries `clusterArn` in `detail`, confirmed live on two separate clusters, so cluster scope
needs no split. `scope = "service"` still builds two rules, because ECS has no single field that
identifies one service across all three event types — task events carry `group`
(`"service:<name>"`) in `detail`; deployment and service-action events carry the service ARN in
the top-level `resources` array instead. The module handles that split for you. All three scopes'
event patterns are the same ones shown under Option B, and were confirmed live the same way —
region and cluster scope by a real applied module against a real cluster, service scope by
`aws events test-event-pattern` against real captured events.

**Applying before the cluster exists.** An EventBridge rule matches only events that arrive after
the rule exists. On a fresh environment, put the rules in place before the first deployment, or
you miss the deployment most worth capturing. The module references no ECS resources, so apply it
first, either in its own configuration or as its own root module. No `-target` is needed.

**If you are also deploying Autoptic with our ECS stack:** that stack calls this same module for
its own cluster, with `scope = "cluster"` fixed to the cluster it creates. Set
`create_resource_policy = false` on one of the two if you run both in the same region and are
near the quota.

---

## Verify it works

**1. Force a deployment and watch.** This is the test that actually proves it.

```bash
aws logs tail "/your/standard/ecs-events" --follow --format short
```

On Option D: `aws logs tail "$(terraform output -raw ecs_events_log_group_name)" --follow --format short`

In a second terminal:

```bash
aws ecs update-service --cluster <cluster> --service <service> --force-new-deployment
```

Records should appear within a few seconds. This pass ran that exact test against a live ECS
cluster: 41 events landed across all three `detail-type`s within about a minute of a fresh
5-service deployment.

**2. Nothing appeared? Check the resource policy first.** This accounts for most failures.

```bash
aws logs describe-resource-policies --query "resourcePolicies[?policyName=='ecs-events-to-cwlogs']"
```

An empty result means EventBridge cannot write to the group. The rule still matches, and the
target still fires. Nothing is written, and no error appears anywhere.

**3. Still nothing? Test the pattern itself.**

```bash
PATTERN=$(aws events describe-rule --name "$RULE_NAME" --query EventPattern --output text)
EVENT='{"version":"0","id":"x","detail-type":"ECS Task State Change","source":"aws.ecs","account":"'"$ACCOUNT"'","time":"2026-01-01T00:00:00Z","region":"'"$REGION"'","resources":["arn:aws:ecs:'"$REGION"':'"$ACCOUNT"':task/<cluster>/abc"],"detail":{"clusterArn":"arn:aws:ecs:'"$REGION"':'"$ACCOUNT"':cluster/<cluster>","lastStatus":"STOPPED"}}'

aws events test-event-pattern --event-pattern "$PATTERN" --event "$EVENT"
```

A result of `true` means the pattern matches, and the problem is downstream.

---

## Point Autoptic at it

**1. Grant Autoptic read access.** Add these to the IAM policy Autoptic uses. See the
[AWS integration guide](../../server/doc/integrations/aws.md) for the full policy, and for
instance-profile, AssumeRole, and access-key options.

```json
{
  "Sid": "CloudWatchLogs",
  "Effect": "Allow",
  "Action": ["logs:DescribeLogGroups", "logs:StartQuery", "logs:GetQueryResults"],
  "Resource": "*"
}
```

Autoptic never needs write access.

**2. Add the data source** to your environment's `where[]`:

```json
{
  "name": "ecs_deploy_events",
  "type": "cloudwatchLogs",
  "vars": {
    "AwsRegion": "<region>",
    "window": "300s",
    "use_iam": true
  }
}
```

Multi-account setups can use the same `aws_organization` block supported on every AWS data source
type: see the AWS integration guide.

**Not confirmed in this pass:** whether a `cloudwatchLogs` data source pointed at this log group
returns these events with usable field access into `detail.*`, including whether the hyphen in
`detail-type` needs the same backtick treatment inside Autoptic's own PQL that it needs in
CloudWatch Logs Insights. The IAM actions and the `where[]` shape are sourced from
`server/doc/integrations/aws.md`; the end-to-end read was not exercised against this specific log
group in this pass.

---

## Query recipes

Run these in CloudWatch Logs Insights, against your log group. Backticks around `detail-type` are
required — the hyphen makes it an invalid bare field name.

**Deployment timeline**

```
fields @timestamp, resources.0, detail.eventName, detail.reason
| filter `detail-type` = "ECS Deployment State Change"
| sort @timestamp desc
| limit 50
```

**Why tasks stopped**

```
fields @timestamp, detail.stoppedReason, detail.stopCode, detail.taskDefinitionArn, detail.containers.0.exitCode
| filter `detail-type` = "ECS Task State Change" and detail.lastStatus = "STOPPED"
| sort @timestamp desc
| limit 50
```

This is the query that answers "why did the deployment fail." `exitCode` is confirmed present on
real container records in this pass, though only on a normal exit (value `0`) — no task stopped
abnormally during the capture window, so a nonzero value was not directly observed.

**Errors only**

```
fields @timestamp, resources.0, detail.eventName, detail.reason
| filter detail.eventType = "ERROR"
| sort @timestamp desc
| limit 50
```

**Everything for one service**

```
fields @timestamp, `detail-type`, detail.eventName, detail.reason
| filter resources.0 like /<service-name>/
| sort @timestamp desc
| limit 100
```

---

## Troubleshooting

**A missing resource policy fails silently.** EventBridge writes to CloudWatch Logs through a
resource policy on the log group, not an IAM role on the target. The console adds it for you. The
CLI, the API, and Terraform do not. Without it, the rules match, the targets fire, nothing is
written, and no error surfaces anywhere. This is the most common way this integration ends up
"configured" but dead. Confirmed present and correct on a live deployment in this pass.

**Never set a role ARN on a CloudWatch Logs target.** AWS is explicit about this. Setting one does
not fail the apply. Delivery just stops.

**Only 10 resource policies per Region per account, 5120 characters each.** Not adjustable. In a
shared account, prefer one broad `/aws/events/*` policy over one per stack.

**Do not enable two capture paths at once.** If you turn on Container Insights lifecycle events
(Option A) and also create your own rule (Options B through D) matching the same events, both
write. You store two copies, and AWS bills for both.

**Cross-account or centralized event bus.** These instructions assume the default event bus, in
the same account and region as the cluster. To route events to a central bus in another account,
you need a bus-to-bus forwarding rule. Talk to us: that setup is out of scope here.

**Removing it.** Delete the rule or rules (one for region or cluster scope, two for service
scope), targets first, then the log group. The resource policy is
account-wide: leave it if anything else relies on it. Under Option D, `terraform destroy` removes
all of it, including the log group and its history. Export anything you want to keep first.

---

## What this does not capture

These events come from the ECS control plane and record state changes only. Three gaps matter:

1. **They do not record who acted.** There is no `userIdentity` field. To find out who started a
   deployment or deleted a service, use CloudTrail.
2. **They do not record API calls that change no state.** `TagResource`,
   `DeregisterTaskDefinition`, and `PutAccountSetting` produce no task or deployment event.
3. **They do not record rejected API calls.** A call that fails authorization or validation
   changes nothing, so no event arrives. CloudTrail records the attempt, with an `errorCode`.

A full picture needs both. CloudTrail answers "who tried what." This log group answers "what then
happened." Autoptic reads CloudTrail too, through the `cloudtrail` data source type: add it
alongside this one if attribution matters to you.
