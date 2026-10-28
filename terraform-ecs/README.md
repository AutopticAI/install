# Autoptic on ECS Fargate — plain Terraform (no AWS Copilot)

This is the plain-Terraform equivalent of `../copilot-ecs/`. Same 4 original services
(`server`, `ui`, `metrics`, `vectors`) plus a 5th, `mcp`, and a different internal topology:
every service sits behind its own load balancer instead of relying on Cloud Map/Service Connect
for everything. See [Design notes](#design-notes-whats-different-from-copilot-ecs) at the bottom
for what changed and why.

Built from four published modules — `terraform-aws-modules/vpc`, `.../ecs`, `.../s3-bucket`,
`.../security-group` — plus plain `aws_lb`/`aws_efs_*`/`aws_secretsmanager_*`/`aws_service_discovery_*`
resources for the pieces those modules don't cover.

## Prerequisites

- Terraform >= 1.10.
- AWS CLI configured with credentials that can create VPCs, ECS clusters, IAM roles, EFS, ALBs,
  Secrets Manager secrets, and (for state locking) S3 buckets.
- Docker installed locally (only used to generate `config.json` — nothing else runs locally).
- The [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  installed, if you want to debug into running containers later via `aws ecs execute-command`.

## Step 0: Bootstrap a Terraform state backend

Copilot never required this — CloudFormation stores its own state. Plain Terraform needs
somewhere to put `terraform.tfstate`, and that somewhere has to exist *before* `terraform init`
can use it.

```bash
BUCKET="<YOUR_TERRAFORM_STATE_BUCKET>"   # must be globally unique
REGION="<YOUR_AWS_REGION>"

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Fill in the resulting bucket name, region, and an environment-specific `key` in `versions.tf`'s
`backend "s3"` block before continuing.

## Step 1: Generate `config.json`

```bash
docker run --rm autoptic/server:latest setup --prepare <TENANT_SHORT_NAME> > config.json
```

Same as the Copilot version — tenant short name is lowercase letters/digits only, no hyphens.
The command's own diagnostic output ends up wrapped in a `"messages"` key at the top of the
generated file — delete that key, it isn't part of the real config schema (see
`../copilot-ecs/config.json.example` for the actual expected shape).

## Step 2: First `terraform apply` — infrastructure only

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in real values
terraform init
terraform apply -target=module.vpc -target=module.ecs -target=module.metrics \
  -target=aws_lb.internal_server -target=aws_lb.internal_vectors \
  -target=aws_lb.public
```

`config.json` needs the internal ALBs' DNS names, which don't exist until this first apply
finishes — this mirrors Copilot's own two-phase flow (`env deploy` first, then read the real
Cloud Map namespace name before finishing `config.json`), not a Terraform-specific wrinkle. If
this step fails partway through, retry the apply directly — see `TROUBLESHOOTING.md` before
retrying with `terraform destroy` or `-replace`.

## Step 3: Edit `config.json` for this environment

| Field | Local/EC2 value | This setup's value |
|---|---|---|
| `aws.profile` | `"default"` | `""` (empty — falls through to the ECS task role) |
| `server.ui` | `http://localhost:8080` | `http://<public ALB DNS>` — from `terraform output public_alb_dns_name` |
| `vector.embed_url` | `http://localhost:8000` | `http://<internal-vectors ALB DNS>:8000` — from `terraform output internal_vectors_alb_dns_name` |
| `pql.command` | e.g. `/root/pql` | `/server/pql` — wherever the Dockerfile bakes the `pql` binary |

Set `vector.qdrant_host` to the bare name `metrics` (`qdrant_port` stays `6334`). `server` has a
client-only Service Connect membership (`ecs.tf`'s `server.service_connect_configuration`) purely
so it can resolve this bare name for its own direct Qdrant gRPC client — this is a separate
connection from `vectors`' own internal Qdrant client, and from `vectors → metrics` (§ below).

> **If you do need a service in this mesh to reach `metrics` or `vectors`, use the bare name
> (`metrics`, `vectors`), not `metrics.<env>.<app>.local` / `vectors.<env>.<app>.local`.** ECS
> Service Connect resolves only the bare alias name, and only from a task that is itself in the
> same Service Connect mesh (`service_connect_configuration.enabled = true` on that service). See
> `TROUBLESHOOTING.md` if a service still can't reach another after setting the bare name.

`ui`'s `AUTOPTIC_SERVER_URL` and `mcp`'s `AUTOPTIC_API_BASE_URL` are set automatically by
`ecs.tf` from `aws_lb.internal_server.dns_name` — nothing to edit by hand for those two, since
they go through an ALB (real DNS), not Service Connect.

## Step 4: Re-apply with the real `config.json`

```bash
terraform apply
```

This is a full apply, no `-target` — it creates everything Step 2 skipped (security group
rules, the S3 upload, the Secrets Manager secrets, EFS mount targets) and uploads the finished
`config.json`. One `terraform apply` replaces Copilot's sequential `copilot svc deploy` calls;
order is handled by Terraform's dependency graph, not manual sequencing.

The `init` containers of `server` and `ui` carry the etag of `config.json` (`CONFIG_JSON_ETAG`).
Thus each change to `config.json` gives both tasks a new task definition revision, and ECS
restarts `server`, `scheduler` and `ui` with the new file. The same applies to later edits of
`config.json`: edit the file, then run `terraform apply`.

Run `terraform plan` immediately after — it should report **no changes**. If it doesn't, resolve
that drift before moving on; see `TROUBLESHOOTING.md` for common causes.

## Access control

Access control is on by default. The `server` task runs two setup containers before `server` and
`scheduler` start. `setup_run` creates the DynamoDB tables and the S3 snapshot bucket when they are
missing. Then `rbac_mint` runs. It mints the role and machine tokens, and it logs their ids only.
The `ui` task has its own `init` container that pulls `config.json`, because the web app needs the
file to fetch its tokens through bootstrap.

### Upgrading an existing install

CAUTION: Give each API client a named token before you apply this template to an existing install.
This template turns on `auth_enforce` and `auth_permissions`, and a call with no token gets `401`.

To keep access control off, set `auth_enforce = false` and `auth_permissions = false` in
`terraform.tfvars`. Then the public ALB has no `/autoptic-api/` route.

### Get the `role.admin` token

The bootstrap route gives the `role.admin` token to a caller that sends the SHA-256 of
`config.json`. The public ALB refuses this route, so send the request from inside the VPC.

1. Calculate the SHA-256 of the `config.json` that Terraform uploaded:

   ```bash
   sha256sum config.json
   ```

2. Open AWS CloudShell in a VPC environment. Use this VPC, one private subnet, and the security
   group `<app>-<env>-tasks`.
3. Send the request to the internal-server ALB (`terraform output internal_server_alb_dns_name`):

   ```bash
   curl -s -X POST "http://<internal_server_alb_dns_name>:9999/story/ep/default/auth/bootstrap/credential" \
     -H 'Content-Type: application/json' \
     -d '{"bootstrap_sha":"<sha256>","principal_id":"role.admin"}'
   ```

   The answer is `{"principal_id":"role.admin","token":"<token>"}`.

CAUTION: Keep each copy of `config.json` as safe as the `role.admin` token. Its SHA-256 is the
proof for bootstrap. Copies are in the deploy bucket (each version), on EFS, and on the computer
that ran Terraform.

### MCP keys for mcp 1.10

Released servers do not register the MCP keys. Add both in the web app, under Utils, Secrets, in
the `default` secret dict:

| Key | Value |
|---|---|
| `mcp.autoptic.service.<mcp_server_id>` | The value of the Secrets Manager secret in `terraform output mcp_secret_arn` |
| `mcp.autoptic.server` | A new random value, for example from `openssl rand -hex 32`. MCP clients send it as `X-MCP-Token`. |

To read the first value, run this command:

```bash
aws secretsmanager get-secret-value --secret-id "$(terraform output -raw mcp_secret_arn)" \
  --query SecretString --output text
```

### Trusted proxies

`auth_trusted_proxies` defaults to the VPC range (`vpc_cidr`), where the load balancers run.
Server releases up to 1.217.4 do not read `AUTH_TRUSTED_PROXIES`. With such a release, also set
`auth.trusted_proxies` in `config.json`.

The docs page "Access control" has the steps for admins and for upgrades.

## Public routes

The public ALB serves one host with the same paths as the Docker Compose nginx proxy:

| Path | Service | Note |
|---|---|---|
| `/` | `ui` | The default action of the listener. |
| `/autoptic-api/` | `server` | The ALB removes the `/autoptic-api` prefix. Only with `auth_enforce = true`. The bootstrap route answers `403`. |
| `/mcp` | `mcp` | MCP clients connect here. |

The API does not use `/api/`, because the web app has its own backend under `/api`.

With `auth_enforce = false`, the API answers callers that send no token. Thus Terraform does not
create the `/autoptic-api/` route, and the API stays on the internal-server ALB.

`mcp` has no internal ALB. Nothing in the stack calls `mcp`, so `/mcp` on the public ALB is its
only entry.

To get the two URLs, run these commands:

```bash
terraform output api_url   # http://<public ALB DNS>/autoptic-api/
terraform output mcp_url   # http://<public ALB DNS>/mcp
```

CAUTION: Add HTTPS before people use these routes in production. Each call sends a named token,
and the default listener is plain HTTP. See `DNS-TLS-SETUP.md`.

The ALB closes a request that sends no data for `alb_idle_timeout` seconds (default 300). Long
agent runs and MCP streams need this value. The AWS default of 60 seconds is too short.

## Verifying

```bash
terraform output public_alb_dns_name   # curl this — should load ui
```

Check the public routes. With `auth_enforce = true`, the API refuses a call with no token:

```bash
ALB=$(terraform output -raw public_alb_dns_name)
curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/autoptic-api/health"            # 200
curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/autoptic-api/story/ep/default/auth/whoami"  # 401
curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/mcp"                             # 405 for a GET
```

Check every service's health, not just `ui`'s:

```bash
for svc in server ui metrics vectors mcp; do
  aws ecs describe-services --cluster <cluster_name> --services "$svc" \
    --query 'services[0].{Name:serviceName,Running:runningCount,Rollout:deployments[0].rolloutState}'
done
```

For the 4 load-balanced services (`server`, `ui`, `vectors`, `mcp` — not `metrics`, which has no
ALB by design), also check target health directly. `server` has a second target group,
`server-pub`, for the public ALB. It exists only with `auth_enforce = true`:

```bash
for tg in server server-pub ui vectors mcp-pub; do
  arn=$(aws elbv2 describe-target-groups --names "<name_prefix>-$tg" --query 'TargetGroups[0].TargetGroupArn' --output text)
  aws elbv2 describe-target-health --target-group-arn "$arn" --query 'TargetHealthDescriptions[].TargetHealth.State'
done
```

All five should be `rolloutState: COMPLETED` with `healthy` targets. If any aren't, start with
`aws ecs describe-services ... --query 'services[0].events[0:5]'` and the service's CloudWatch
log group (`/aws/ecs/<service>/<container>`) — see `TROUBLESHOOTING.md` for common failure modes.

`describe-services` only keeps a short rolling window of events, and loses them entirely when a
service is recreated. `events.tf` mirrors the same deployment, service-action, and task events
into `/aws/events/ecs/<app>-<env>`, which survives both — see
[ECS-DEPLOYMENT-LOGGING.md](./ECS-DEPLOYMENT-LOGGING.md) for the query recipes. To watch a
deployment as it happens:

```bash
aws logs tail "$(terraform output -raw ecs_events_log_group_name)" --follow --format short
```

## Tearing down

```bash
terraform destroy
```

EFS with data and a versioned S3 bucket with objects will block a plain destroy unless emptied
first — same caveat `../copilot-ecs/TEARDOWN.md` calls out for the Copilot version.
The app's own self-provisioned DynamoDB tables and S3 snapshot bucket (created by the `setup_run`
container at runtime, not by Terraform) still need separate manual cleanup either way. A soft-deleted Secrets
Manager secret name stays reserved for a 30-day recovery window unless you
`aws secretsmanager delete-secret --force-delete-without-recovery` it — relevant if you plan to
`destroy` and re-`apply` under the same `env` name soon after.

## Custom domain + HTTPS

See `DNS-TLS-SETUP.md` for connecting a Route 53 domain and adding a validated HTTPS listener to
the public ALB. Treat it as a follow-up once the base HTTP deployment above is confirmed working
— the public ALB only gets an HTTP listener by default, matching Copilot's own default.

## Design notes: what's different from `copilot-ecs`

1. **Every service is fronted by a load balancer**, not just `ui`. Internal ALBs mediate
   `ui → server`, `server → vectors`, and `mcp → server` (`mcp`'s own outbound call). The public
   ALB serves `ui`, the API (`/autoptic-api/`), and `mcp` (`/mcp`) on one host, like the Docker
   Compose nginx proxy. `mcp` has no internal ALB, because nothing in the stack calls it.
   `vectors → metrics` and `server → metrics` stay on Service Connect, with no ALB in front of
   `metrics` — `server` has a client-only Service Connect membership just to resolve `metrics`'
   bare name for its direct Qdrant client, and publishes no alias of its own.
2. **`mcp` is a 5th service**, added here alongside the original 4 (`server`, `ui`, `metrics`,
   `vectors`).
3. **NAT Gateway + private subnets**, instead of Copilot's no-NAT/public-subnet default — since
   every task is now fronted by an ALB anyway, private subnets are the more natural fit.
