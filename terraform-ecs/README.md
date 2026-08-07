# Autoptic on ECS Fargate — plain Terraform (no AWS Copilot)

This is the plain-Terraform equivalent of `../copilot-ecs/`. Same 4 original services
(`server`, `ui`, `metrics`, `vectors`) plus a 5th, `mcp`, and a different internal topology:
every service sits behind its own load balancer instead of relying on Cloud Map/Service Connect
for everything. See [Design notes](#design-notes-whats-different-from-copilot-ecs) at the bottom
for what changed and why.

Built from four published modules — `terraform-aws-modules/vpc`, `.../ecs`, `.../s3-bucket`,
`.../security-group` — plus plain `aws_lb`/`aws_efs_*`/`aws_secretsmanager_*`/`aws_service_discovery_*`
resources for the pieces those modules don't cover.

**This install has been run end to end against a real AWS account** — every step below,
including the errors called out inline and in `TROUBLESHOOTING.md`, reflects what actually
happened, not a paper design.

## Prerequisites

- Terraform >= 1.10.
- AWS CLI configured with credentials that can create VPCs, ECS clusters, IAM roles, EFS, ALBs,
  Secrets Manager secrets, and (for state locking) S3 buckets.
- Docker installed locally (only used to generate `config.json` — nothing else runs locally).
- The [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  installed, if you want to debug into running containers later via `aws ecs execute-command`
  (see `TROUBLESHOOTING.md` — this is how the Service Connect DNS issue below got root-caused).

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
terraform apply -target=module.vpc -target=module.ecs \
  -target=aws_lb.internal_server -target=aws_lb.internal_vectors \
  -target=aws_lb.internal_mcp -target=aws_lb.public
```

`config.json` needs the internal ALBs' DNS names, which don't exist until this first apply
finishes — this mirrors Copilot's own two-phase flow (`env deploy` first, then read the real
Cloud Map namespace name before finishing `config.json`), not a Terraform-specific wrinkle. The
`-target` list above is exactly what was used for the real run this guide is based on; expect at
least one retry — see "`-target` retries and the orphaned-secret loop" in `TROUBLESHOOTING.md`
before you hit it blind.

## Step 3: Edit `config.json` for this environment

| Field | Local/EC2 value | This setup's value |
|---|---|---|
| `aws.profile` | `"default"` | `""` (empty — falls through to the ECS task role) |
| `server.ui` | `http://localhost:8080` | `http://<public ALB DNS>` — from `terraform output public_alb_dns_name` |
| `vector.embed_url` | `http://localhost:8000` | `http://<internal-vectors ALB DNS>:8000` — from `terraform output internal_vectors_alb_dns_name` |
| `pql.command` | e.g. `/root/pql` | `/server/pql` — wherever the Dockerfile bakes the `pql` binary |

`vector.qdrant_host`/`qdrant_port` are left as Copilot's original example values. `server` has no
Service Connect configuration in this design at all (confirmed: `vectors` is the only caller of
`metrics`), so there is no live path for `server` to reach `metrics` directly under any hostname
— if these fields turn out to matter for some `server` code path not exercised in this install,
treat that as a design question to raise, not a value to guess at here.

> **If you do need a service in this mesh to reach `metrics` or `vectors`, do not use
> `metrics.<env>.<app>.local` / `vectors.<env>.<app>.local`, even though that's the pattern
> Copilot's own docs use.** ECS Service Connect does not publish a real DNS record at all — it
> statically injects the bare alias name into `/etc/hosts`, mapped to a reserved `127.255.x.x`
> loopback address that the Envoy sidecar intercepts via `iptables`. The FQDN form resolves to
> nothing; only the bare name (e.g. `metrics`, `vectors`) works, and only from a task that is
> itself in the same Service Connect mesh (`service_connect_configuration.enabled = true` on
> that service). Confirmed live, by exec'ing into a running task — see "Service Connect names are
> bare, never FQDNs" in `TROUBLESHOOTING.md`.

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

Run `terraform plan` immediately after — it should report **no changes**. If it doesn't, resolve
that drift before moving on; see `TROUBLESHOOTING.md` for the specific drift this setup hit
(security group ports normalizing from `0` to `-1`) and how it was fixed at the source rather
than re-appearing on every plan.

## Verifying

```bash
terraform output public_alb_dns_name   # curl this — should load ui
```

Check every service's health, not just `ui`'s:

```bash
for svc in server ui metrics vectors mcp; do
  aws ecs describe-services --cluster <cluster_name> --services "$svc" \
    --query 'services[0].{Name:serviceName,Running:runningCount,Rollout:deployments[0].rolloutState}'
done
```

For the 4 load-balanced services (`server`, `ui`, `vectors`, `mcp` — not `metrics`, which has no
ALB by design), also check target health directly:

```bash
for tg in server ui vectors mcp; do
  arn=$(aws elbv2 describe-target-groups --names "<name_prefix>-$tg" --query 'TargetGroups[0].TargetGroupArn' --output text)
  aws elbv2 describe-target-health --target-group-arn "$arn" --query 'TargetHealthDescriptions[].TargetHealth.State'
done
```

All five should be `rolloutState: COMPLETED` with `healthy` targets. If any aren't, start with
`aws ecs describe-services ... --query 'services[0].events[0:5]'` and the service's CloudWatch
log group (`/aws/ecs/<service>/<container>`) — `TROUBLESHOOTING.md` walks through every failure
mode actually hit doing this, in the order they were hit.

## Tearing down

```bash
terraform destroy
```

EFS with data and a versioned S3 bucket with objects will block a plain destroy unless emptied
first — same caveat `../copilot-ecs/TEARDOWN.md` calls out for the Copilot version.
The app's own self-provisioned DynamoDB tables and S3 snapshot bucket (created by `server` at
runtime, not by Terraform) still need separate manual cleanup either way. A soft-deleted Secrets
Manager secret name stays reserved for a 30-day recovery window unless you
`aws secretsmanager delete-secret --force-delete-without-recovery` it — relevant if you plan to
`destroy` and re-`apply` under the same `env` name soon after.

## Custom domain + HTTPS

See `DNS-TLS-SETUP.md` for connecting a Route 53 domain and adding a validated HTTPS listener to
the public ALB. Treat it as a follow-up once the base HTTP deployment above is confirmed working
— the public ALB only gets an HTTP listener by default, matching Copilot's own default.

## Design notes: what's different from `copilot-ecs`

1. **Every service is fronted by a load balancer**, not just `ui`. Internal ALBs mediate
   `ui → server`, `server → vectors`, and `server → mcp`. `vectors → metrics` is the one hop
   still on Service Connect, with no ALB — confirmed: `vectors` is the only caller of `metrics`
   (Qdrant), so this direct hop is correct as built, not a placeholder.
2. **`mcp` is a 5th service**, added here — it already existed as a real Go service wired into
   this repo's Kubernetes Helm chart, just missing from the Copilot ECS docs.
3. **NAT Gateway + private subnets**, instead of Copilot's no-NAT/public-subnet default — since
   every task is now fronted by an ALB anyway, private subnets are the more natural fit.

LiteLLM was investigated and found to be a disconnected, experimental Helm chart (its own
Postgres/Redis) not wired into the app anywhere — out of scope here.
