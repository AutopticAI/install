## Autoptic Helm Chart (BYO - Bring Your Own AWS Resources)

This is the **BYO (bring-your-own)** sibling chart that assumes you have already provisioned AWS resources (DynamoDB tables and S3 bucket) using the `autoptic/server` container outside the cluster. The chart deploys Autoptic workloads using a user-provided `config.json`.

For the automated flow where AWS resources are provisioned in-cluster, see the sibling chart: [`install/kubernetes/autoptic-helm`](../autoptic-helm/).

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Step 1: Provision AWS Resources with Docker](#step-1-provision-aws-resources-with-docker)
- [Step 2: Deploy with Helm](#step-2-deploy-with-helm)
- [IRSA Setup](#irsa-setup)
- [Marker-Aware Setup Load](#marker-aware-setup-load)
- [Migration from Automated Chart](#migration-from-automated-chart)
- [MCP Server](#mcp-server)
- [Troubleshooting](#troubleshooting)
- [Values Reference](#values-reference)

---

## Overview

This two-step installation flow gives you full control over AWS resource provisioning:

1. **Step 1 (outside cluster)**: Use the `autoptic/server` container to generate `config.json` and create AWS resources.
2. **Step 2 (in cluster)**: Deploy the Helm chart using the generated `config.json` via a user-provided ConfigMap.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Step 1: Docker Host (or CI/CD)                                  │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │ docker run autoptic/server:latest                       │     │
│  │   setup --prepare <tenant> > config.json                │     │
│  │   setup --run config.json                               │     │
│  │   [optional] setup --verify-schema config.json           │     │
│  └─────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 2: Kubernetes Cluster                                      │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │ kubectl create configmap autoptic-config                │     │
│  │   --from-file=config.json                               │     │
│  │   --from-literal=AUTOPTIC_INSTANCE_ID=<id>              │     │
│  │   --from-literal=AUTOPTIC_TENANT_SHORT_NAME=<tenant>  │     │
│  └─────────────────────────────────────────────────────────┘     │
│                              │                                   │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │ helm upgrade --install autoptic-byo ./autoptic-helm-byo │     │
│  │   -n autoptic --create-namespace                          │     │
│  │   --set config.useExisting=true                          │     │
│  │   --set serviceAccounts.s3DynamoDbAccess.roleArn=<arn> │     │
│  └─────────────────────────────────────────────────────────┘     │
│                              │                                   │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │ Post-install hook runs setup --load (marker-aware)      │     │
│  └─────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- Kubernetes cluster (EKS recommended for IRSA support)
- `kubectl` and `helm` installed
- Docker installed (for Step 1)
- AWS credentials configured (IAM user or IRSA on host)
- An IAM role with permissions for DynamoDB and S3 (for the pod, not the Docker host)

### IAM Permissions for Pods (IRSA)

The IAM role attached to the Kubernetes ServiceAccount needs:

**DynamoDB Actions:**
- `dynamodb:DescribeTable`, `dynamodb:PutItem`, `dynamodb:GetItem`, `dynamodb:Query`, `dynamodb:DeleteItem`, `dynamodb:ListTables`

**S3 Actions:**
- `s3:HeadBucket`, `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject`

**Note:** Unlike the automated chart, this BYO chart does NOT need `dynamodb:CreateTable` or `s3:CreateBucket` permissions since tables/buckets are already created.

---

## Step 1: Provision AWS Resources with Docker

### 1A) Generate config (`setup --prepare`)

```bash
# Using default AWS credentials from environment
docker run --rm \
  -v "$PWD:/work" -w /work \
  -e AWS_REGION=us-west-2 \
  autoptic/server:latest \
  setup --prepare mytenant > config.json
```

Or using AWS profile from local machine:

```bash
docker run --rm \
  -v "$PWD:/work" -w /work \
  -v "$HOME/.aws:/root/.aws:ro" \
  -e AWS_PROFILE=my-profile \
  -e AWS_REGION=us-west-2 \
  autoptic/server:latest \
  setup --prepare mytenant > config.json
```

**What this does:**
- Validates tenant short name
- Generates `instance.id` in form `<tenant>-<random-hex>`
- Produces table/bucket names derived from that `instance.id`
- Writes a full `config.json` you will use in Helm

### 1B) Provision AWS resources (`setup --run`)

```bash
docker run --rm \
  -v "$PWD:/work" -w /work \
  -v "$HOME/.aws:/root/.aws:ro" \
  -e AWS_PROFILE=my-profile \
  -e AWS_REGION=us-west-2 \
  autoptic/server:latest \
  setup --run /work/config.json
```

**What this creates:**
- **6 DynamoDB tables** (if missing), where `<id> = instance.id`:
  - `autoptic-environment-<id>`
  - `autoptic-pql-<id>`
  - `autoptic-token-<id>`
  - `autoptic-brief-<id>`
  - `autoptic-briefrecord-<id>`
  - `autoptic-secrets-<id>`
- **1 S3 bucket**:
  - `autoptic-snaps-<id>`

**Stricter Schema Verification Note:**
Current `autoptic/server` performs stricter schema verification:
- **PQL and BriefRecord tables**: Missing GSIs are auto-reconciled (created and re-verified)
- **Environment, Token, Brief, Secrets tables**: Any schema mismatch fails with an actionable error requiring manual remediation

### 1C) Optional read-only schema preflight

```bash
docker run --rm \
  -v "$PWD:/work" -w /work \
  -v "$HOME/.aws:/root/.aws:ro" \
  -e AWS_PROFILE=my-profile \
  -e AWS_REGION=us-west-2 \
  autoptic/server:latest \
  setup --verify-schema /work/config.json
```

---

## Step 2: Deploy with Helm

### 2A) Patch config for Kubernetes DNS (no `jq`)

```bash
NS=autoptic-byo

python3 - <<'PY'
import json, os
ns = os.environ.get("NS", "autoptic-byo")

with open("config.json", "r", encoding="utf-8") as f:
    cfg = json.load(f)

cfg["server"]["ui"] = f"http://ui-service.{ns}.svc.cluster.local:8080"
cfg["scheduler"]["api_endpoint"] = f"http://autoptic-byo-api.{ns}.svc.cluster.local:9999/story/ep/default"
cfg["vector"]["embed_url"] = f"http://vectors-service.{ns}.svc.cluster.local:8000"
cfg["vector"]["qdrant_host"] = f"metrics-service.{ns}.svc.cluster.local"
cfg["vector"]["qdrant_port"] = 6334

# Important for IRSA runtime in Kubernetes:
# remove profile-based auth keys from config so pods do not try shared AWS profiles.
for section in ("server", "scheduler", "vector", "storage", "aws"):
    if isinstance(cfg.get(section), dict):
        cfg[section].pop("aws_profile", None)
        cfg[section].pop("profile", None)

with open("config.k8s.json", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print(cfg["instance"]["id"])
print(cfg["instance"]["tenant_short_name"])
PY
```

The script prints two lines:
1. `INSTANCE_ID`
2. `TENANT_SHORT_NAME`

Use those values in the next step.

### 2B) Create namespace and ConfigMap

```bash
NS=autoptic-byo
CM=autoptic-config
INSTANCE_ID="<paste-instance-id-from-python-output>"
TENANT_SHORT_NAME="<paste-tenant-short-name-from-python-output>"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create configmap "$CM" \
  --from-file=config.json=./config.k8s.json \
  --from-literal=AUTOPTIC_INSTANCE_ID="$INSTANCE_ID" \
  --from-literal=AUTOPTIC_TENANT_SHORT_NAME="$TENANT_SHORT_NAME" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 2B.1) Known good example (`autoptic7`)

```bash
NS=autoptic-byo
CM=autoptic-config
INSTANCE_ID="autoptic7-823eb54dfe56676b"
TENANT_SHORT_NAME="autoptic7"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create configmap "$CM" \
  --from-file=config.json=./config.k8s.json \
  --from-literal=AUTOPTIC_INSTANCE_ID="$INSTANCE_ID" \
  --from-literal=AUTOPTIC_TENANT_SHORT_NAME="$TENANT_SHORT_NAME" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 2B.2) Verify ConfigMap content

```bash
kubectl -n "$NS" describe configmap "$CM"
```

Expected runtime values in `config.json`:
- `server.ui = http://ui-service.<ns>.svc.cluster.local:8080`
- `scheduler.api_endpoint = http://autoptic-byo-api.<ns>.svc.cluster.local:9999/story/ep/default`
- `vector.embed_url = http://vectors-service.<ns>.svc.cluster.local:8000`
- `vector.qdrant_host = metrics-service.<ns>.svc.cluster.local`
- no `aws_profile` / `profile` keys under runtime sections (`server`, `scheduler`, `vector`, etc.)

Note: `messages.info` may still contain historical localhost lines from `setup --prepare`. Those are informational log lines, not active runtime endpoints.

### 2C) Install Helm

```bash
helm upgrade --install autoptic-byo ./autoptic-helm-byo \
  -n "$NS" --create-namespace \
  --timeout 20m --wait --wait-for-jobs \
  --set namespace.name="$NS" \
  --set config.useExisting=true \
  --set config.name="$CM" \
  --set api.env.awsRegion=us-west-2 \
  --set scheduler.env.awsRegion=us-west-2 \
  --set ui.gateway.hostnames[0]=autoptic-byo.dev.autoptic.com \
  --set ui.gateway.parentRefs[0].name=shared-gateway \
  --set ui.gateway.parentRefs[0].namespace=nginx-gateway \
  --set serviceAccounts.s3DynamoDbAccess.roleArn=arn:aws:iam::<account-id>:role/<role-name>
```

**Required values:**
- `namespace.name=<namespace>`: ensures rendered resources target the same namespace as Helm release
- `config.useExisting=true`: Use the user-provided ConfigMap
- `config.name=autoptic-config`: Name of the ConfigMap you created
- `serviceAccounts.s3DynamoDbAccess.roleArn`: IRSA role ARN for the pods

**Optional but recommended:**
- `ui.secrets.webuiSecretKey`: Secret key for UI sessions
- `ui.secrets.openaiApiKey`: OpenAI API key

No manual hook ServiceAccount creation is required. The chart now binds marker ConfigMap RBAC to the main workload ServiceAccount (`s3-dynamodb-access`) so `setup-load` uses the same IRSA identity as API and scheduler.

### 2D) Upgrade behavior for master-key pre-upgrade hook

If `externalSecrets.enabled=false`, pre-upgrade master-key hook expects UI secrets.
Use one of these patterns:

```bash
# Pattern A: provide secrets on each upgrade (recommended)
helm upgrade --install autoptic-byo ./autoptic-helm-byo \
  -n "$NS" \
  --set ui.secrets.webuiSecretKey='change-me-secret' \
  --set ui.secrets.openaiApiKey='change-me-key'
```

```bash
# Pattern B: disable master-key generation for route-only/metadata-only upgrades
helm upgrade --install autoptic-byo ./autoptic-helm-byo \
  -n "$NS" \
  --set hooks.masterKey.generate=false
```

---

## IRSA Setup

### Create IAM Policy

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:DescribeTable",
                "dynamodb:PutItem",
                "dynamodb:GetItem",
                "dynamodb:Query",
                "dynamodb:DeleteItem",
                "dynamodb:ListTables"
            ],
            "Resource": [
                "arn:aws:dynamodb:*:*:table/autoptic-*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:HeadBucket",
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::autoptic-snaps-*",
                "arn:aws:s3:::autoptic-snaps-*/*"
            ]
        }
    ]
}
```

### Create IAM Role with Trust Policy

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::<account-id>:oidc-provider/<oidc-provider>"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "<oidc-provider>:sub": "system:serviceaccount:<namespace>:<service-account-name>"
                }
            }
        }
    ]
}
```

The ServiceAccount name will be generated by the chart based on the release name.

---

## Marker-Aware Setup Load

The chart includes a marker-aware post-install/post-upgrade hook that runs `setup --load` to load sample content. The hook uses a marker ConfigMap (`autoptic-setup-state`) to track completion per instance-id.

**Features:**
- **Idempotency**: Re-running Helm won't duplicate sample content
- **Safety**: The marker survives `helm uninstall`
- **Control**: You can force a re-run by resetting the marker

### Force re-run of setup-load

```bash
# Reset the marker
kubectl -n autoptic patch configmap autoptic-setup-state \
  --type merge -p '{"data":{"setup-load.completed":"false"}}'

# Or delete the marker ConfigMap entirely
kubectl -n autoptic delete configmap autoptic-setup-state

# Re-run by upgrading with --wait
helm upgrade --install autoptic-byo ./autoptic-helm-byo \
  -n autoptic --wait --wait-for-jobs
```

---

## Migration from Automated Chart

If you're switching from the automated `autoptic-helm` chart to this BYO chart:

### 1. Export existing ConfigMap and Secret

```bash
# Export the ConfigMap
kubectl -n autoptic get configmap autoptic-config -o yaml > autoptic-config-backup.yaml

# Export the instance-id Secret
kubectl -n autoptic get secret autoptic-instance-id -o yaml > autoptic-instance-id-backup.yaml
```

### 2. Extract config.json from ConfigMap

```bash
kubectl -n autoptic get configmap autoptic-config \
  -o jsonpath='{.data.config\.json}' > config.json
```

### 3. Verify AWS resources exist

```bash
# Check DynamoDB tables
aws dynamodb list-tables | grep "autoptic-.*-$(jq -r '.instance.id' config.json)"

# Check S3 bucket
aws s3 ls | grep "autoptic-snaps-$(jq -r '.instance.id' config.json)"
```

### 4. Uninstall old chart

```bash
helm uninstall autoptic -n autoptic
```

### 5. Create fresh ConfigMap with the BYO chart

```bash
INSTANCE_ID="$(jq -r '.instance.id' config.json)"
TENANT_SHORT_NAME="$(jq -r '.instance.tenant_short_name' config.json)"

kubectl -n autoptic create configmap autoptic-config \
  --from-file=config.json=./config.json \
  --from-literal=AUTOPTIC_INSTANCE_ID="$INSTANCE_ID" \
  --from-literal=AUTOPTIC_TENANT_SHORT_NAME="$TENANT_SHORT_NAME" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 6. Install BYO chart

```bash
helm upgrade --install autoptic-byo ./autoptic-helm-byo \
  -n autoptic --create-namespace \
  --timeout 20m --wait --wait-for-jobs \
  --set config.useExisting=true \
  --set serviceAccounts.s3DynamoDbAccess.roleArn=arn:aws:iam::<account-id>:role/<role-name>
```

---

## MCP Server

This chart also deploys the `mcp` component: [Autoptic's MCP (Model Context Protocol) server](https://github.com/AutopticAI/mcp),
which exposes Autoptic's agent/catalog/brief-record API as MCP tools — for external MCP clients (Claude Code,
Claude Desktop, etc. connecting directly) and for Autoptic's own agents to call back into themselves as an
MCP-backed data source (`"type": "mcp"` steps in agent skills).

**What it does:** wraps `AUTOPTIC_API_BASE_URL` (the in-cluster `api-service`, in this BYO chart's `autoptic-byo`
namespace) and exposes it as MCP tools: `autoptic_catalog_list`/`_search`/`_add` (browse and register catalog
entries), `autoptic_search_brief_records`/`_get_brief_record` (find and read past agent findings),
`autoptic_run_agent_skill` (execute a skill), and the persisted-config CRUD tools (`autoptic_config_list`/`_get`/
`_delete`, `autoptic_agents_save`, `autoptic_env_save`, `autoptic_pql_save`, `autoptic_skills_save`).

**How it's secured — two separate tokens, not one:**

1. `MCP_SERVER_TOKEN` (the `mcp-server-token` key in the Secret below). This is the mcp pod's
   own credential to the Autoptic API — it identifies this MCP server instance, and the Autoptic
   API checks it against a value stored under the key `mcp.autoptic.service.<serverId>` in
   Autoptic's own secret store (`<serverId>` is `mcp.env.serverId` below). The pod refuses to
   start without it set (`config error: MCP_SERVER_TOKEN is required for streamable_http transport`).
2. The `X-MCP-Token` header value an actual MCP client sends. This is a completely different,
   per-endpoint token, checked live by the Autoptic API against a value stored under the key
   `mcp.autoptic.server` in Autoptic's own secret store. This chart never creates or holds this
   value — create it directly in Autoptic (see your Autoptic API's secrets documentation), and
   give it only to whoever is configuring an MCP client.

**Do not send `MCP_SERVER_TOKEN` as `X-MCP-Token`, and do not store the same value under both
`mcp.autoptic.service.<serverId>` and `mcp.autoptic.server` in Autoptic's secret store.** They
are different tokens for different purposes; that mistake is the most common cause of
`X-MCP-Token` requests failing to authenticate even though the pod itself is running fine.

**Configuring `MCP_SERVER_TOKEN`:**

```yaml
mcp:
  enabled: true
  secrets:
    mcpServerToken: "" # leave empty — this chart generates and keeps one automatically
    autopticApiToken: "" # optional; only needed if the Autoptic API itself requires bearer auth
```

Leave `mcpServerToken` empty. This chart generates a random value on first install and reuses
that same value on every later `helm upgrade`, so it never needs typing by hand and never
rotates out from under an already-configured deployment. Set it explicitly only if you need this
value to match something outside this chart's control.

To read the generated value later, for example to set the matching
`mcp.autoptic.service.<serverId>` entry in Autoptic's secret store:

```bash
kubectl get secret <mcp.secretName> -n autoptic-byo -o jsonpath='{.data.mcp-server-token}' | base64 -d
```

If `externalSecrets.enabled: true`, this chart does **not** create the `mcp-server-token`/`autoptic-api-token`
Secret itself, and does not generate a value either — sync both keys into `mcp.secretName` (default
`autoptic-mcp-secrets`) via your own `ExternalSecret`/`SecretStore`.

**Connecting to it:**

- **From within the cluster** (an agent's `where[]` MCP entry):
  `http://mcp-service.autoptic-byo.svc.cluster.local:7000/mcp`, with
  `headers: { "X-MCP-Token": "{{ secret 'mcp.autoptic.server' }}" }` in the environment config —
  the per-endpoint token from point 2 above, created directly in Autoptic, never `MCP_SERVER_TOKEN`.
- **From outside the cluster**: enable `mcp.gateway` (same Gateway API `HTTPRoute` pattern the `ui`/automated
  chart uses, just under `mcp.` instead of `ui.`) and connect to `https://<your-mcp-hostname>/mcp` with the
  same `X-MCP-Token` header, the same per-endpoint token.
- **Health check**: `GET /health` on port 7000 is unauthenticated and used for the liveness/readiness probes.

**Running mcp locally instead (stdio transport)**, e.g. for a developer's own Claude Desktop/Code
`mcpServers` config, talking to the deployed Autoptic API over the internet rather than to the in-cluster
pod at all — no `X-MCP-Token`/Gateway involved, since `stdio` skips the HTTP auth gate entirely and instead
requires `AUTOPTIC_API_TOKEN` directly:

```json
{
  "mcpServers": {
    "autoptic": {
      "command": "/path/to/autoptic-mcp",
      "args": ["--transport", "stdio"],
      "env": {
        "AUTOPTIC_API_BASE_URL": "https://<your-api-hostname>/",
        "AUTOPTIC_API_TOKEN": "<your-autoptic-api-token>"
      }
    }
  }
}
```

Note: this assumes the Autoptic **API** itself (not mcp) already has its own external route configured
separately (outside this chart) — point `AUTOPTIC_API_BASE_URL` at wherever that is.

---

## Troubleshooting

### Load hook skipped but I want to re-run

```bash
kubectl -n autoptic delete configmap autoptic-setup-state
helm upgrade --install autoptic-byo ./autoptic-helm-byo -n autoptic --wait --wait-for-jobs
```

### ConfigMap not found

Ensure `config.useExisting=true` and the ConfigMap exists:

```bash
kubectl -n autoptic get configmap autoptic-config
```

### Namespace typo (common)

If `kubectl get` shows no resources unexpectedly, verify the namespace spelling first (for example, `autptic-byo` vs `autoptic-byo`):

```bash
kubectl get ns
kubectl get configmap -n autoptic-byo
```

### IRSA permissions denied

Check the ServiceAccount has the correct annotation:

```bash
kubectl -n autoptic get sa -o yaml | grep -A5 "eks.amazonaws.com/role-arn"
```

### Pods fail with `failed to get shared config profile`

If logs show `failed to get shared config profile, default`, your `config.json` still includes
`aws_profile`/`profile` keys. Remove those keys in Step 2A (Python patch) and re-apply the ConfigMap.
Kubernetes workloads should authenticate with IRSA, not shared profile files.

### Upgrade fails in `master-key-hook`

If Helm upgrade fails with:
`WEBUI_SECRET_KEY and OPENAI_API_KEY are required when external secrets are disabled`

retry with either:

```bash
# Include required UI secrets
helm upgrade --install autoptic-byo ./autoptic-helm-byo -n "$NS" \
  --set ui.secrets.webuiSecretKey='change-me-secret' \
  --set ui.secrets.openaiApiKey='change-me-key'
```

or:

```bash
# Disable master-key generation for this upgrade
helm upgrade --install autoptic-byo ./autoptic-helm-byo -n "$NS" \
  --set hooks.masterKey.generate=false
```

### Setup-load fails with "API not ready"

Check API pod status:

```bash
kubectl -n autoptic get pods -l app.kubernetes.io/component=api
kubectl -n autoptic logs deploy/autoptic-api
```

---

## Values Reference

Key BYO-specific values:

```yaml
# Use the user-provided ConfigMap (required)
config:
  useExisting: true
  name: autoptic-config

# Setup hooks - prepare and run are disabled (user already did this)
setup:
  enabled: true
  prepare:
    enabled: false
  run:
    enabled: false
  load:
    enabled: true  # Post-install content loading (marker-aware)

# IRSA role ARN (required)
serviceAccounts:
  s3DynamoDbAccess:
    roleArn: arn:aws:iam::<account-id>:role/<role-name>

# UI secrets (recommended)
ui:
  secrets:
    webuiSecretKey: "change-me-secret"
    openaiApiKey: "change-me-key"
```

See [`values.yaml`](values.yaml) for the full reference.
