# Troubleshooting

Common errors you may hit during this install, with how to diagnose and fix each. Several of
these build on each other, so read them in order the first time through.

## `terraform plan` fails: `for_each` on `aws_efs_mount_target`

```
Error: Invalid for_each argument
The "for_each" set includes values derived from resource attributes that cannot be determined
until apply
```

`for_each` was originally keyed on `module.vpc.private_subnets` directly — the subnet IDs
themselves. For a brand-new VPC, those IDs aren't known until the VPC is created, so Terraform
can't evaluate the `for_each` set at plan time. This is already fixed in `efs.tf`: `for_each` is
keyed on a static string index (`"0"`, `"1"`) instead, with the subnet ID looked up by index
inside the resource body. If you see this error elsewhere in a change you're making, the fix is
the same shape: key `for_each` on something known at plan time, not on the resource's own
computed attributes.

## `-target` retries and the orphaned-secret loop

Step 2's first apply used `-target` to unblock the `config.json` chicken-and-egg problem (see
README). Two things went wrong here, in order:

**1. `creating Secrets Manager Secret ... already scheduled for deletion`**

```
InvalidRequestException: You can't create this secret because a secret with this name is
already scheduled for deletion.
```

AWS keeps a deleted secret's name reserved for a 30-day recovery window. A `terraform destroy`
(or a `-replace`) run between retries schedules the secret for deletion instead of removing it
outright, and the next apply then hits this error. **If you're retrying a failed apply, retry
the apply directly — don't `destroy` first.** If you're already stuck with an orphaned secret
and don't need the old value:

```bash
aws secretsmanager delete-secret --secret-id <name> --force-delete-without-recovery
```

**2. `does not have an associated load balancer`**

```
InvalidParameterException: The target group with targetGroupArn ... does not have an associated
load balancer.
```

A target group only counts as "associated with a load balancer" once a *listener* uses it — and
the `-target` list only named the `aws_lb` resources, not their listeners
(`aws_lb_listener.*`). `ecs.tf` had no dependency edge forcing the listeners to exist before ECS
tried to attach services to their target groups. This is already fixed: `module "ecs"` has an
explicit `depends_on` naming all 4 listeners. If you add a 6th service behind a new ALB later,
add its listener to that `depends_on` list too, or you'll hit this again.

## Security group drift that never goes away: `0` vs `-1`

```
~ from_port = -1 -> 0
~ to_port   = -1 -> 0
```

...on every single `terraform plan`, forever, never actually applying cleanly. AWS normalizes
`from_port`/`to_port` to `-1` when `ip_protocol` is `"-1"` (all protocols) — a rule declared with
`from_port = 0, to_port = 0` will always read back as `-1`/`-1` from the API, so Terraform sees a
perpetual diff. Already fixed in `security_groups.tf`: every all-protocol egress rule uses
`from_port = -1, to_port = -1` to match what AWS actually stores. If `terraform plan` ever
reports the same unresolvable diff repeatedly for a security group rule, check this first.

## `mcp` never starts: `secretsmanager:GetSecretValue` `AccessDeniedException`

```
AccessDeniedException: User: .../mcp-task-exec-... is not authorized to perform:
secretsmanager:GetSecretValue ... because no identity-based policy allows the action.
```

The permission was granted to the **task role** (`tasks_iam_role_statements`), but ECS resolves
a container's `secrets` block using the **execution role** — which acts before the task role is
ever assumed, to pull the container image and any registry/secret references. Any `secrets`
block anywhere in this config needs its Secrets Manager ARN in `task_exec_secret_arns`, not
`tasks_iam_role_statements`. Already fixed for both `mcp` and `ui`.

## `mcp` starts, then exits: `MCP_SERVER_ID is required`

```
config error: MCP_SERVER_ID is required for streamable_http transport
```

Straightforward missing environment variable, not present in the Copilot ECS docs this design
was ported from (`mcp` didn't exist there at all). Set it via `var.mcp_server_id`
(`<MCP_SERVER_ID>` — must match a key suffix in your external token registry).

## `ui` crashes on boot: `Required environment variable not found`

```
ValueError: Required environment variable not found. Terminating now.
```

`open_webui/env.py` raises this when `WEBUI_AUTH` (default `true`) is set and `WEBUI_SECRET_KEY`
is empty. The image's own `start.sh` can auto-generate one into a file next to the app
(`.webui_secret_key`) if the env var is absent — but that write can silently fail depending on
the container's filesystem permissions (see the read-only-root-filesystem issue below), leaving
`WEBUI_SECRET_KEY` empty either way. Fixed by setting it directly via a Secrets Manager secret
(`aws_secretsmanager_secret.ui_webui_secret_key` in `secrets.tf`), bypassing the file-based
fallback entirely.

## `vectors` crashes: `No usable temporary directory found`

```
FileNotFoundError: [Errno 2] No usable temporary directory found in
['/tmp', '/var/tmp', '/usr/tmp', '/app']
```

The `terraform-aws-modules/ecs/aws` module's `container-definition` submodule defaults
`readonlyRootFilesystem` to `true` — this config never overrode it, for any of the 5 services.
`server`, `ui`, and `metrics` never noticed, since each only writes into its own EFS-mounted
subdirectory, not the root filesystem itself. `vectors` has no volume mount at all, so torch's
import-time `tempfile.TemporaryDirectory()` call (a side effect of importing `torch.distributed`)
had nowhere writable at all.

**Fix:** Set `readonlyRootFilesystem = false` explicitly on the container. This template already
sets it on all 7 containers (`init`, `server`, `scheduler`, `ui`, `metrics`, `vectors`, `mcp`).
If you add a new container later and it needs to write anywhere outside a declared volume mount
— even to `/tmp` — set this explicitly; don't rely on the module's default.

## `vectors`' `/health` returns `404`

Not a Terraform issue. The `vectors` image's own application code defines `@app.get("/health")`
in its source, but a deployed `vectors` image built before that route was added won't have it —
check your image's build history for when the route was added. Rebuild and push the image from a
commit that includes it, then force a new ECS deployment:

```bash
aws ecs update-service --cluster <cluster> --service vectors --force-new-deployment
```

## `vectors`' `/health` returns `503`: `Qdrant unreachable`

Once the route exists, its handler calls `client.get_collections()` against `QDRANT_URL`, which
defaults to `http://localhost:6333` — never set anywhere in this config originally, and Qdrant's
REST port (6333) is a different port than the one `server` uses (6334, gRPC, via
`config.json`'s `vector.qdrant_port`). Two things had to be fixed together:

1. `metrics`' `portMappings`/`service_connect_configuration` only declared port 6334. Added a
   second entry for port 6333, under the same `client_alias.dns_name = "metrics"` — two ports,
   one alias.
2. `vectors`' `QDRANT_URL` needed setting. **The first attempt used
   `http://metrics.<ENV_NAME>.<APP_NAME>.local:6333` — the FQDN form — and it still failed.**
   See the next section; this is the same root cause as the `404`-vs-DNS confusion.

## Service Connect names are bare, never FQDNs

**When:** `QDRANT_URL` (or any similar internal URL) is set to
`http://metrics.<env>.<app>.local:6333` — an FQDN — and the target service still can't be
reached, timing out at the socket level.

**Why:** ECS Service Connect does not publish a queryable DNS record. It resolves only the bare
alias name (exactly the `client_alias.dns_name` value, no namespace suffix), and only from a
task that is itself in the same Service Connect mesh
(`service_connect_configuration.enabled = true` on that service). You can confirm this from
inside a running task with ECS Exec (`aws ecs execute-command`) by checking `/etc/hosts` for the
bare name.

**Fix:** Use the bare name — `QDRANT_URL = "http://metrics:6333"`, not the FQDN form.

**A follow-on issue while fixing this:** don't rename an existing `discovery_name` in the
same `terraform apply` that adds a new `client_alias` entry for the same service. Doing so hits:

```
InvalidParameterException: ClientAlias metrics:6334 is already used by service with discovery
name metrics in namespace ...
```

AWS won't let a `client_alias` move to a new `discovery_name` while the old one is still live on
the running service — `UpdateService` validates the new registration before the old one is torn
down. Leave existing `discovery_name` values alone when adding a new port/alias to an existing
service; only the *new* entry needs a new name.

## `server`'s search or upsert operations against Qdrant don't work

**When:** `ui`, `vectors`, and the ALB health checks all report healthy, but `server`'s search
or upsert operations against Qdrant fail.

**Why:** `server` connects to Qdrant directly (via `config.json`'s
`vector.qdrant_host`/`qdrant_port`), separately from `vectors`' own internal Qdrant client. This
needs two things together: `server` must be in the Service Connect mesh (`ecs.tf`'s
`server.service_connect_configuration`, already set in this template), and `config.json`'s
`vector.qdrant_host` must be the bare name `metrics`, not an FQDN (see "Service Connect names are
bare, never FQDNs" above) — check both if this still fails.
