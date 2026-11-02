# Autoptic on ECS Fargate — Setup From Zero (via AWS Copilot)

This is the ECS/Fargate equivalent of the local `docker-compose` setup. Instead of running
containers on a single host with bind mounts, each service runs as its own ECS service,
config/binaries are delivered via S3 + EFS, and AWS auth goes through an ECS task role
instead of `~/.aws` credential files.

Files in this directory:
```
copilot-ecs/
├── README.md                  ← you are here
├── config.json.example        ← what the S3-hosted config.json should look like
├── manifests/
│   ├── env-manifest.yml       ← environment manifest (add TLS cert here)
│   ├── server-manifest.yml    ← server + scheduler (sidecar) + init, setup_run and rbac_mint sidecars
│   ├── mcp-manifest.yml
│   ├── ui-manifest.yml        ← ui + init sidecar (config.json for token bootstrap)
│   ├── metrics-manifest.yml
│   └── vectors-manifest.yml
├── addons/
│   ├── server-policy.yml      ← IAM task role policy for server/scheduler
│   └── ui-policy.yml          ← lets the ui task read config.json from S3
├── overrides/
│   └── metrics-service-connect-port.yml   ← YAML patch: exposes Qdrant's REST port (6333)
│                                             on metrics, which vectors needs and no manifest
│                                             field can declare directly (see the file itself)
├── TROUBLESHOOTING.md          ← every error we hit and how we fixed it
├── DNS-TLS-SETUP.md            ← custom domain + HTTPS setup
└── TEARDOWN.md                 ← how to delete everything, including what Copilot won't
```

All placeholder values look like `<THIS>` — replace them with your real values before
using any file here. Don't paste these files in as-is.

You do **not** need to run the full `docker-compose` stack locally. You only need to:
1. Generate `config.json` once (via a throwaway local `docker run`),
2. Edit it for the ECS environment,
3. Upload it to S3,
4. Provision everything else via the AWS Copilot CLI.

---

## Prerequisites

- Docker installed locally (only used to generate `config.json` — nothing else runs locally).
- AWS CLI configured with credentials that can create VPCs, ECS clusters, IAM roles, EFS,
  ALBs, and CloudFormation stacks (this is a different permission set than the app's own
  runtime IAM policy — see [Step 6](#step-6-create-the-task-role-policy)).
- [AWS Copilot CLI](https://aws.github.io/copilot-cli/) installed:
  ```bash
  # macOS
  brew install aws/tap/copilot-cli

  # Linux
  curl -Lo copilot https://github.com/aws/copilot-cli/releases/latest/download/copilot-linux
  chmod +x copilot
  sudo mv copilot /usr/local/bin/copilot

  copilot --version
  ```
- The [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  installed, if you want to `copilot svc exec`/debug into running containers later:
  ```bash
  curl -sSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/smp.deb
  mkdir -p /tmp/smp-extract && cd /tmp/smp-extract && ar x /tmp/smp.deb && tar xf data.tar.gz
  mkdir -p ~/.local/bin
  cp usr/local/sessionmanagerplugin/bin/session-manager-plugin ~/.local/bin/
  chmod +x ~/.local/bin/session-manager-plugin
  ```

---

## Step 1: Generate `config.json`

Choose a tenant short name: lowercase letters and digits only (`a-z`, `0-9`). No hyphens,
no underscores — not `my-company`, not `acme-corp`. This becomes the prefix of your
generated instance ID and shows up in every AWS resource name (DynamoDB tables, S3
bucket).

```bash
docker run --rm autoptic/server:latest setup --prepare <TENANT_SHORT_NAME> > config.json
```

This produces a `config.json` with defaults filled in, including a freshly generated
`instance.id` (`{tenant_short_name}-{randomHex}` — the dash is added automatically; it
must not appear in your tenant short name).

---

## Step 2: Edit `config.json` for ECS

See `config.json.example` in this directory for the full annotated example. The short
version of what changes vs. the local/EC2 config:

| Field | Local/EC2 value | ECS value | Why |
|---|---|---|---|
| `aws.profile` | `"default"` | `""` (empty) | The app reads this field directly and always tries to load a *named* shared-config profile if it's non-empty — regardless of whether an ECS task role is attached. Leaving it empty makes the AWS SDK fall through to its default credential chain, which picks up the task role automatically. |
| `pql.command` | e.g. `/root/pql` | `/server/pql` | Matches wherever the Dockerfile actually bakes the `pql` binary (`WORKDIR /server`, `COPY ... ./pql`). Check your image's Dockerfile — don't assume a path. |
| `vector.qdrant_host` / `vector.embed_url` | `localhost` | `metrics.<ENV>.<APP>.local` / `http://vectors.<ENV>.<APP>.local:8000` | ECS has no shared network namespace between separate services — they discover each other via Cloud Map DNS instead. Get the real namespace name with `aws servicediscovery list-namespaces` **after** `copilot env init` — don't guess the format, it's `<environment>.<app>.local`, not just `<app>.local`. |

---

## Step 3: Upload `config.json` to S3

Anything that was a bind mount from the host (`./config.json:/server/config.json:ro` in
compose) needs a different delivery mechanism on ECS, since there's no host filesystem to
mount from. `config.json` gets delivered via S3 + an init sidecar (see Step 8). Anything
static and never changing at runtime (like the `pql` binary, if your Dockerfile doesn't
already bake it in) should just be added to the image at build time instead — don't build
a whole file-delivery pipeline for something that never changes.

```bash
aws s3 mb s3://<DEPLOY_ARTIFACTS_BUCKET>
aws s3 cp ./config.json s3://<DEPLOY_ARTIFACTS_BUCKET>/config.json --sse AES256
```

---

## Step 4: Initialize the Copilot app and environment

```bash
copilot app init <APP_NAME>
copilot env init --name <ENV_NAME> --profile <AWS_PROFILE> --default-config
copilot env deploy --name <ENV_NAME>
```

`env init` only writes a manifest and provisions bootstrap IAM roles — `env deploy` is
what actually creates the VPC, subnets, ECS cluster, and Cloud Map namespace.

> **No NAT Gateway by default.** `--default-config` does not include a NAT Gateway. If your
> services need to pull images from Docker Hub (not ECR) or reach the public internet,
> either add a NAT Gateway (~$32+/mo) or place tasks in public subnets instead (see
> Step 9) — free, and fine for services with no public-facing ports as long as the default
> security group still blocks inbound traffic.

Get the real Cloud Map namespace name to use in `config.json` (Step 2):
```bash
aws servicediscovery list-namespaces --query 'Namespaces[].Name' --output table
# → <ENV_NAME>.<APP_NAME>.local
```

---

## Step 5: Initialize the five services

```bash
copilot svc init --name server  --svc-type "Backend Service"          --image <YOUR_ORG>/server:latest  --port 9999
copilot svc init --name ui      --svc-type "Load Balanced Web Service" --image <YOUR_ORG>/ui:latest      --port 8080
copilot svc init --name metrics --svc-type "Backend Service"          --image <YOUR_ORG>/metrics:latest --port 6334
copilot svc init --name vectors --svc-type "Backend Service"          --image <YOUR_ORG>/vectors:latest --port 8000
copilot svc init --name mcp     --svc-type "Load Balanced Web Service" --image <YOUR_ORG>/mcp:1.12.0     --port 7000
```

> **`--port` is required on every service, including `Backend Service` ones with no ALB.**
> Copilot only registers a service under Service Connect/Cloud Map — i.e. only gives it a
> DNS name at all — if a port is declared. Skip it and other services calling this one
> will fail with a DNS/name-resolution error, not a clean connection-refused, since the
> DNS record never gets created in the first place. See `TROUBLESHOOTING.md`.

- `server` is `Backend Service` (no ALB) if nothing outside the environment calls it
  directly — `ui` reaches it via `server.<ENV_NAME>.<APP_NAME>.local:9999`. Only make it
  `Load Balanced Web Service` if external clients need to hit the API directly.
- `--image` points straight at Docker Hub — no need to build/push to ECR unless you want
  to (Copilot still creates an unused ECR repo per service by default; harmless).
- Docker Hub images are subject to anonymous pull rate limits and have no SLA — fine for
  a demo/internal tool, but for anything production-critical consider mirroring to ECR.

This generates `copilot/<service>/manifest.yml` for each service — replace them with the
annotated examples in `manifests/` in this directory (adjusted for your real values).

---

## Step 6: Create the task role policy

The `setup_run` sidecar creates the app's DynamoDB tables and S3 bucket on first start, so the
task role needs create permissions, not just read/write. See `addons/server-policy.yml` in this
directory for the full template — place it at `copilot/server/addons/policy.yml` in your
project. Any `AWS::IAM::ManagedPolicy` output from a `copilot/<service>/addons/*.yml` file
is automatically attached to that service's task role on the next deploy — no manual
attach step, no console work.

Since `scheduler` runs as a sidecar in the *same task* as `server` (Step 8), one addon on
`server` covers both.

---

## Step 7: Persistent storage (EFS)

Two services need real persistence, not ephemeral task storage:

- **`ui`** — SQLite DB (chat history, users, settings) and the generated `WEBUI_SECRET_KEY`
  live under `/app/backend/data`. Without persistence, every redeploy wipes all of it.
- **`metrics`** (Qdrant) — its `seed-and-run.sh` entrypoint only reseeds the bundled demo
  dataset if `/qdrant/storage/collections` is empty; if your usage actually writes new
  vectors over time, losing that volume on every task replacement means silently falling
  back to just the seed data. Confirm this against your image's actual seed script before
  assuming persistence is/isn't needed.

If your Copilot CLI version supports `storage init -t EFS`, use that. If it only supports
`DynamoDB`/`S3`/`Aurora`, configure EFS directly in the manifest instead — Copilot creates
and manages the filesystem automatically the first time a manifest references one, no
separate provisioning step. See `manifests/ui-manifest.yml` and
`manifests/metrics-manifest.yml` for the exact block.

> **Gotcha:** Copilot's manifest-defined EFS volumes default to `read_only: true`. If the
> container needs to write anything at all, you must explicitly set `read_only: false` —
> otherwise you'll see errors like `mkdir: cannot create directory '...': Read-only file
> system` at container startup. See `TROUBLESHOOTING.md`.

---

## Step 8: `server` manifest — config delivery + `scheduler` sidecar

`server` and `scheduler` run in the same ECS task (not two separate services) — this
replicates compose's `network_mode: service:server`, since all containers in one ECS
task already share a network namespace automatically.

Config delivery: an `init` sidecar pulls `config.json` from S3 onto a shared EFS volume
before `server`/`scheduler` start. Full manifest in `manifests/server-manifest.yml`.

> **Gotcha:** `public.ecr.aws/aws-cli/aws-cli`'s image `ENTRYPOINT` is already
> `/usr/local/bin/aws` — it's not a general-purpose shell image. If you only set
> `command: ["sh", "-c", "aws s3 cp ..."]` **without** also overriding `entrypoint`, ECS
> runs `aws sh -c "aws s3 cp ..."` (entrypoint + command concatenated), which is invalid
> AWS CLI syntax and exits with code 252 (the CLI's usage-error exit code). Always set
> `entrypoint: ["/bin/sh", "-c"]` explicitly when you need shell semantics from this image.

---

## Step 9: Tell `ui` where `server` is

`ui` needs an environment variable telling its own backend where to reach `server` —
the same convention this app uses in its Kubernetes deployment (`AUTOPTIC_SERVER_URL`).
Add to `manifests/ui-manifest.yml`:

```yaml
variables:
  AUTOPTIC_SERVER_URL: http://server.<ENV_NAME>.<APP_NAME>.local:9999/
```

> **Do not** rely on the "Server URL" field in the app's own admin/settings page for this.
> That field is validated **client-side, in the browser**, before it lets you save — and a
> browser has no route to a private Cloud Map DNS name at all. You'll see an error like
> `Can't connect with the server through the URL ...`. This does not mean the real,
> backend-to-backend connection is broken; it means that specific UI field is the wrong
> place to configure it. See `TROUBLESHOOTING.md`.

---

## Step 10: No NAT Gateway? Add public placement to every service

If you skipped the NAT Gateway to save cost, every service pulling from Docker Hub needs
a public IP for egress (private subnets have zero internet access without NAT). Every
manifest in `manifests/` already includes:

```yaml
network:
  connect: true
  vpc:
    placement: public
```

This is safe even though it assigns a public IP — Copilot's default security group still
only allows inbound traffic from other services in the environment (or from the ALB, for
`Load Balanced Web Service` types); nothing is exposed to the internet just because the
task has a public IP.

---

## Step 11: Size `vectors` for its embedding model, not just a default guess

If your model is large (e.g. an ~1.3GB `e5-large-v2` safetensors file), Fargate's default
`cpu: 256` / `memory: 512` isn't enough to even `mmap` the file into memory, let alone run
inference — you'll see `RuntimeError: unable to mmap ... bytes ...: Cannot allocate
memory`. `manifests/vectors-manifest.yml` sizes this at `cpu: 1024` / `memory: 4096` —
adjust upward if your model is bigger.

---

## Access control (before Step 12)

Access control is on by default. `manifests/server-manifest.yml` sets `AUTH_ENFORCE`,
`AUTH_PERMISSIONS` and `AUTH_BOOTSTRAP_SHA_ENABLE` to `"true"`. Before the API starts, its
`setup_run` sidecar creates the tables, and its `rbac_mint` sidecar mints the tokens. The `init` sidecar sets
`config.json` to mode 600.

Place `addons/ui-policy.yml` at `copilot/ui/addons/policy.yml`. The `ui` task needs it to read `config.json`.

`rbac_mint` mints the role and machine tokens, and it logs their ids only.

**Get the `role.admin` token.** The bootstrap route gives it to a caller that sends the SHA-256 of
`config.json`. The `server` service has no public route, so send the request from inside the
service:

1. Calculate the SHA-256 of your `config.json`: `sha256sum config.json`.
2. Open a shell in the `server` container. The server manifest sets `exec: true` for this:

   ```bash
   copilot svc exec --name server --env <ENV_NAME> --container server --command sh
   ```

3. In that shell, send the request:

   ```bash
   curl -s -X POST http://localhost:9999/story/ep/default/auth/bootstrap/credential \
     -H 'Content-Type: application/json' \
     -d '{"bootstrap_sha":"<sha256>","principal_id":"role.admin"}'
   ```

**Named tokens and MCP.** Create a named token for each person in the web app: Tokens, New
principal, Person. The `mcp` service has no secret of its own. Each MCP client sends two headers to
`http://<environment load balancer DNS>/mcp`:

- `Authorization: Bearer <named token>`
- `X-MCP-Endpoint: default`

The docs page "Connect to Autoptic MCP and API" gives users the steps.

`mcp` refuses each tool call while `AUTH_ENFORCE` or `AUTH_PERMISSIONS` is off. Before a client
connects, make sure that the API enforces access control. In the shell of the `server` container:

```bash
curl -s http://localhost:9999/story/ep/default/auth/whoami -H "x-api-token: <named token>"
```

The answer must contain `"enforced":true`.

To opt out, set `AUTH_ENFORCE` and `AUTH_PERMISSIONS` to `"false"` in the server manifest. Then
`mcp` refuses each tool call. The docs page "Access control" has the steps for admins and for
upgrades.

**Upgrade from mcp 1.10.** mcp 1.11.0 removes the MCP keys. Clients that still send `X-MCP-Token`
keep working, because mcp 1.11.0 ignores this header. mcp 1.11.0 needs server 1.216.0 or later.
If your registry has an older copy of `server:latest`, copy the new image to it first.

1. Run the `whoami` check above. The answer must contain `"enforced":true`.
2. Remove `MCP_SERVER_ID` and `MCP_SERVER_TOKEN` from `copilot/server/manifest.yml` and
   `copilot/mcp/manifest.yml`.
3. In `copilot/mcp/manifest.yml`, set the image to 1.11.0 or later.
4. Deploy `server`, then `mcp`.
5. Remove the `X-MCP-Token` header from the MCP clients. You can do this at any time.
6. Erase the SSM parameter of the old credential:

   ```bash
   aws ssm delete-parameter --name /copilot/<APP_NAME>/<ENV_NAME>/secrets/mcp_server_token
   ```

7. When no MCP 1.10 server uses this API, erase two keys from the `default` secret dict. The keys
   are `mcp.autoptic.server` and `mcp.autoptic.service.<MCP_SERVER_ID>` (web app: Utils, Secrets).

---

## Step 12: Deploy in dependency order

```bash
copilot svc deploy --name metrics --env <ENV_NAME>
copilot svc deploy --name vectors --env <ENV_NAME>
copilot svc deploy --name server  --env <ENV_NAME>
copilot svc deploy --name mcp     --env <ENV_NAME>
copilot svc deploy --name ui      --env <ENV_NAME>
```

`metrics`/`vectors` first, since `server` depends on reaching them at startup.

If a deploy is stuck `UPDATE_IN_PROGRESS` and you `Ctrl+C` the local `copilot` CLI, note
that this only kills the **local progress-watcher** — it does not cancel the actual
CloudFormation stack update, which keeps running server-side. Check with:
```bash
aws cloudformation describe-stacks --stack-name <APP_NAME>-<ENV_NAME>-<service> --query 'Stacks[0].StackStatus'
```
before assuming it's stuck — ECS rolling deployments with health checks and old
crash-looping tasks to clean up can legitimately take 5–15+ minutes.

---

## Step 13 (optional): Custom domain + HTTPS

See `DNS-TLS-SETUP.md` in this directory for the full walkthrough. Copilot's ALB only gets
an HTTP listener by default — treat this as a separate follow-up once the base deployment
is confirmed working over plain HTTP.

---

## Troubleshooting

See `TROUBLESHOOTING.md` for every error we actually hit setting this up and how each was
fixed/diagnosed.

---

## Tearing it all down

See `TEARDOWN.md` — Copilot only deletes what it created. The app's own self-provisioned
DynamoDB tables/S3 bucket, the deploy-artifacts bucket, and any DNS/ACM setup all need
separate manual cleanup, covered there.
