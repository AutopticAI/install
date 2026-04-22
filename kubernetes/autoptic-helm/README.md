## Autoptic Helm Chart

This chart packages the Autoptic demo stack (API, UI, Scheduler, Metrics/Qdrant, Vectors) for Kubernetes.

### Prerequisites

- Kubernetes cluster (e.g., EKS, Minikube)
- kubectl and helm installed
- AWS IAM role or credentials (for DynamoDB and S3 access)

### IAM Prerequisite

Before installing this chart, you must create an IAM role or user with the required permissions. The Autoptic setup process creates AWS resources and requires specific IAM permissions.

**Required DynamoDB Actions:**

The setup creates 6 DynamoDB tables with the naming pattern `autoptic-{table-type}-{instance-id}`:
- `autoptic-environment-{instance-id}` - Environment configurations
- `autoptic-pql-{instance-id}` - PQL query definitions
- `autoptic-token-{instance-id}` - Authentication tokens
- `autoptic-brief-{instance-id}` - Brief configurations
- `autoptic-briefrecord-{instance-id}` - Brief execution records
- `autoptic-secrets-{instance-id}` - Encrypted secrets

Required actions: `dynamodb:CreateTable`, `dynamodb:DescribeTable`, `dynamodb:PutItem`, `dynamodb:GetItem`, `dynamodb:Query`, `dynamodb:DeleteItem`, `dynamodb:ListTables`

**Required S3 Actions:**

The setup creates one S3 bucket with the naming pattern `autoptic-snaps-{instance-id}` for storing snapshots and generated content.

Required actions: `s3:CreateBucket`, `s3:HeadBucket`, `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject`

**Recommended IAM Policy:**

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:CreateTable",
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
                "s3:CreateBucket",
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

**AWS Authentication:**

The chart supports two authentication methods:

1. **IRSA (recommended for EKS):** Set `serviceAccounts.s3DynamoDbAccess.roleArn` to the ARN of your IAM role.
2. **Static credentials:** Set `awsSecret.enabled=true` and provide `awsSecret.accessKeyId` and `awsSecret.secretAccessKey`.

**Important:** Use an AWS region other than `us-east-1` for production workloads. The chart defaults to `us-west-2`.

### Quick Start

With IRSA (recommended for EKS):

```bash
helm upgrade --install autoptic . \
  -n autoptic --create-namespace \
  --set setup.tenantShortName=my-company \
  --set serviceAccounts.s3DynamoDbAccess.roleArn=arn:aws:iam::123456789012:role/autoptic-role
```

With static AWS credentials:

```bash
helm upgrade --install autoptic . \
  -n autoptic --create-namespace \
  --set setup.tenantShortName=my-company \
  --set awsSecret.enabled=true \
  --set awsSecret.accessKeyId=AKIA... \
  --set awsSecret.secretAccessKey=...
```

### Known-Good Isolated Install (recommended for first test)

Use a separate release/namespace for validation so previous state does not interfere:

```bash
helm upgrade --install autoptic-2 solutions/autoptic-helm-prod \
  -n autoptic-2 --create-namespace \
  --timeout 20m --wait --wait-for-jobs \
  --set namespace.name=autoptic-2 \
  --set setup.tenantShortName=company2 \
  --set serviceAccounts.s3DynamoDbAccess.create=true \
  --set serviceAccounts.s3DynamoDbAccess.name=s3-dynamodb-access-2 \
  --set serviceAccounts.s3DynamoDbAccess.roleArn=arn:aws:iam::<account-id>:role/<irsa-role-name> \
  --set ui.ingress.enabled=false \
  --set api.service.type=ClusterIP \
  --set ui.service.type=ClusterIP \
  --set ui.secrets.webuiSecretKey=change-me-secret \
  --set ui.secrets.openaiApiKey=change-me-key \
  --set pql.storage.pvName=pql-aws-pv-2 \
  --set pql.storage.pvcName=pql-aws-storage-2
```

This command is validated and known to work end-to-end when cluster prerequisites are present.

Access points (when using ClusterIP + port-forward):

- UI: <http://127.0.0.1:8080>
- API: <http://127.0.0.1:9999>

### How the Setup Works

The chart includes three pre/post-install hooks that replace the docker-compose installation steps:

1. **setup-prepare** (pre-install, pre-upgrade): Runs `server setup --prepare <tenant>` to generate `config.json`, creates the ConfigMap, and persists the instance-id in a Secret.
2. **setup-run** (pre-install, pre-upgrade): Runs `server setup --run` to create DynamoDB tables and S3 bucket (idempotent).
3. **setup-load** (post-install only): Runs `server setup --load` to load sample content (environments, PQL queries, briefs).

The instance-id is persisted across upgrades via the `autoptic-instance-id` Secret. This ensures that the same AWS resources are reused on subsequent installs.

On `helm upgrade` (without uninstall), `setup-prepare` reuses the existing `instance-id` and `tenant-short-name` from that Secret and rewrites `config.json` with those values before `setup-run` executes. This prevents creating new DynamoDB tables/S3 buckets on each upgrade.

Quick verification:

```bash
# Run this before and after helm upgrade; value should stay the same
kubectl -n autoptic get secret autoptic-instance-id -o jsonpath='{.data.instance-id}' | base64 -d; echo

# setup-prepare logs should mention reuse
kubectl -n autoptic logs job/autoptic-setup-prepare | rg "Reusing existing instance ID from Secret|Instance ID:"
```

### Manual install, upgrade, delete

#### Install/Upgrade

```bash
helm upgrade --install autoptic . \
  -n autoptic --create-namespace \
  --set ui.ingress.enabled=false \
  --set api.service.type=ClusterIP \
  --set ui.service.type=ClusterIP
```

#### Check status

```bash
kubectl -n autoptic get pods
kubectl -n autoptic get svc
```

#### Check hook status

```bash
# View hook job logs
kubectl -n autoptic logs job/autoptic-setup-prepare
kubectl -n autoptic logs job/autoptic-setup-run
kubectl -n autoptic logs job/autoptic-setup-load

# View generated config
kubectl -n autoptic get configmap autoptic-config -o yaml

# View persisted instance-id
kubectl -n autoptic get secret autoptic-instance-id -o yaml
```

#### Port-forward (when using ClusterIP services)

```bash
kubectl -n autoptic port-forward svc/ui-service 8080:8080 &
kubectl -n autoptic port-forward svc/api-service 9999:9999 &
```

#### Uninstall

```bash
helm uninstall autoptic -n autoptic
```

### Values reference (selected)

- `namespace.*`: Namespace configuration (`create`, `name`, `labels`, `annotations`)
- `api.*`: API Deployment and Service
- `scheduler.*`: Scheduler Deployment with `waitForApi` configuration
- `config.*`: ConfigMap with `configJson`, `configJsonString`, `extraData`, `useExisting`
- `ui.*`: UI Deployment, Service, Ingress, Persistence, and SecurityContexts
- `ui.secrets.*`: UI secrets (`webuiSecretKey`, `openaiApiKey`, `grokApiKey`, `googleClientSecret`, `oktaClientSecret`)
- `ui.gateway.*`: Gateway API HTTPRoute configuration (mutually exclusive with Ingress)
- `metrics.*`: Qdrant (HTTP 6333, gRPC 6334) with persistence and security contexts
- `vectors.*`: Vectors embedding service with computed Qdrant URL defaults
- `serviceAccounts.s3DynamoDbAccess.*`: Service account with optional IRSA roleArn
- `awsSecret.*`: AWS credentials Secret (disabled when using IRSA via `serviceAccounts`)
- `externalSecrets.*`: External Secrets Operator configuration for AWS Secrets Manager
- `hooks.masterKey.*`: Pre-install hook for Fernet master key generation (`pythonJob` or `helmSecret` strategy)
- `setup.*`: Setup hooks for automated bootstrap (replaces docker-compose setup)
- `pql.storage.*`: PV/PVC for PQL state; includes optional pre-install hostPath creation

### Placeholder values examples

The chart copy under `install/kubernetes/autoptic-helm` uses `replace-me-*` defaults for environment-specific fields.  
Use values like the following:

```yaml
api:
  env:
    awsRegion: us-west-2

scheduler:
  env:
    awsRegion: us-west-2

config:
  extraData:
    AUTOPTIC_INSTANCE_ID: company-ab12cd34ef56gh78
    AUTOPTIC_TENANT_SHORT_NAME: company

setup:
  tenantShortName: company

ui:
  ingress:
    hosts:
      - host: ui.company.example.com
  gateway:
    parentRefs:
      - name: shared-gateway
        namespace: nginx-gateway
    hostnames:
      - ui.company.example.com

externalSecrets:
  secretStoreName: aws-secretsstore
  awsAccessKeyIdPath: autoptic/aws-access-key-id
  awsSecretAccessKeyPath: autoptic/aws-secret-access-key
  openaiApiKeyPath: autoptic/openai-api-key
  grokApiKeyPath: autoptic/grok-api-key
  webuiSecretKeyPath: autoptic/webui-secret-key

pql:
  storage:
    pvName: pql-aws-pv-company
    pvcName: pql-aws-storage-company
```

### Setup Values (v0.3.0+)

The `setup.*` values control the automated bootstrap hooks:

```yaml
setup:
  enabled: true                           # Enable all setup hooks
  tenantShortName: "company"              # Tenant name (used in AWS resource naming)
  image: autoptic/server:latest           # Server image for setup commands
  imagePullPolicy: Always
  kubectlImage: registry.k8s.io/kubectl:v1.30.0  # Kubectl image for prepare hook
  instanceIdSecretName: autoptic-instance-id     # Secret to persist instance-id
  activeDeadlineSeconds: 600              # Timeout for each hook Job
  prepare:
    enabled: true                         # Run setup --prepare to generate config
  run:
    enabled: true                         # Run setup --run to create AWS resources
  load:
    enabled: true                         # Run setup --load to load sample content
```

**Disabling hooks for re-installs:**

If you need to reinstall without re-running setup (e.g., the AWS resources already exist):

```bash
helm upgrade --install autoptic . \
  --set setup.prepare.enabled=false \
  --set setup.run.enabled=false \
  --set setup.load.enabled=false
```

**Manual re-run of setup --load:**

The load hook runs only on post-install (not upgrades). To manually re-run it:

```bash
kubectl -n autoptic create job manual-setup-load \
  --from=cronjob/autoptic-setup-load
```

### New Values (added in v0.3.0)

- `setup.*`: Automated setup hooks that replace docker-compose steps 3/5/6
- `setup.tenantShortName`: Tenant name used for AWS resource naming
- `setup.prepare.enabled`: Generate config.json via `setup --prepare`
- `setup.run.enabled`: Create DynamoDB/S3 via `setup --run`
- `setup.load.enabled`: Load sample content via `setup --load`

### New Values (added in v0.2.0)

- `namespace`: Now an object with `create`, `name`, `labels`, `annotations` (was a string)
- `config.useExisting`: Skip ConfigMap creation and use existing one
- `api.livenessProbe` / `api.readinessProbe`: Configurable HTTP health probes on `/health`
- `scheduler.waitForApi`: Init container configuration for API readiness check
- `ui.secrets.*`: Required secrets for UI (previously inline values)
- `ui.securityContext` / `ui.containerSecurityContext`: Pod and container security contexts
- `ui.persistence.*`: Renamed from `ui.pvc.*` with additional options
- `ui.gateway.*`: Gateway API HTTPRoute support (mutually exclusive with Ingress)
- `externalSecrets.*`: External Secrets Operator integration for AWS Secrets Manager
- `hooks.masterKey.*`: Pre-install hook for generating/preserving Fernet master key
- `metrics.persistence.*`: Qdrant PVC with init container for permission fixes
- `metrics.securityContext` / `metrics.containerSecurityContext`: Security contexts
- `vectors.securityContext` / `vectors.containerSecurityContext`: Security contexts

### Removed Values (from v0.1.0)

- `namespace`: String value replaced by object structure (use `namespace.name`)
- `awsAuth.useIRSA`: Replaced by `serviceAccounts.s3DynamoDbAccess.roleArn`
- `ui.pvc.*`: Renamed to `ui.persistence.*`
- `baseApp.enabled`: Removed along with scaffolding templates
- `image.pullPolicy`: Now per-component (`api.imagePullPolicy`, `ui.imagePullPolicy`, etc.)

### Component layout

- API (api-deployment, api-service)
  - Reads config from ConfigMap (autoptic-config), AWS creds from Secret (aws-credentials) or IRSA
  - Exposes port 9999; uses AWS SDK env credentials
  - Health checks on `/health` endpoint
- UI (ui-deployment, ui-service, optional ui-ingress or ui-gateway HTTPRoute)
  - Talks to API at api-service:9999
  - Uses Qdrant via QDRANT_URI
  - PVC mounted at /app/backend/data via init container
  - Secrets backed by K8s Secret or External Secrets Operator
  - Master key generated via pre-install hook
- Scheduler (scheduler-deployment)
  - Polls API at .../story/ep/default
  - Optional wait-for-api initContainer (scheduler.waitForApi.enabled)
- Metrics (metrics-deployment, metrics-service)
  - Qdrant HTTP: 6333, gRPC: 6334
  - Persistent storage with permission fix init container
- Vectors (vectors-embedding, vectors-service)
  - Connects to Qdrant via auto-computed QDRANT_URL/HOST/PORT
- Storage (pql-aws-pv, pql-aws-storage)
  - PV hostPath created automatically with pre-install hook (DirectoryOrCreate)

### Gateway API vs Ingress

The chart supports two mutually exclusive external routing options:

**Ingress (traditional):**
```yaml
ui:
  ingress:
    enabled: true
  gateway:
    enabled: false
```

**Gateway API (HTTPRoute referencing existing Gateway):**
```yaml
ui:
  ingress:
    enabled: false
  gateway:
    enabled: true
    parentRefs:
      - name: my-gateway
        namespace: gateway-ns
    hostnames:
      - myapp.example.com
    rules:
      - matches:
          - path:
              type: PathPrefix
              value: /
```

### Minikube notes

- When using ClusterIP services, use port-forward or `minikube service ... --url`
- hostPath PV is auto-prepared via chart hook; no manual SSH to node needed

### Troubleshooting

**Setup hook failures:**

If the `setup-prepare` or `setup-run` hooks fail, check the logs:

```bash
kubectl -n autoptic logs job/autoptic-setup-prepare
kubectl -n autoptic logs job/autoptic-setup-run
```

Common causes:
- Missing IAM permissions: Ensure the IAM role has `dynamodb:ListTables` and `s3:HeadBucket` for connectivity validation
- AWS region issues: Use a region other than `us-east-1`
- Instance ID mismatch: The prepare hook persists the instance-id in a Secret. Check `kubectl -n autoptic get secret autoptic-instance-id -o yaml`

**AWS credentials:**

Ensure `serviceAccounts.s3DynamoDbAccess.roleArn` is set for IRSA; or `awsSecret.*` for static creds.

**Install fails with `ui.secrets.webuiSecretKey is required`:**

- Cause: `hooks.masterKey.strategy=pythonJob` with `externalSecrets.enabled=false` and empty `ui.secrets.*`.
- Fix: either provide `ui.secrets.webuiSecretKey` + `ui.secrets.openaiApiKey`, or use `hooks.masterKey.strategy=helmSecret`, or enable external secrets with a valid store.

**Install fails with `configmaps "autoptic-config" already exists`:**

- Cause: duplicate ConfigMap definitions with same name.
- Fix: keep a single shared `autoptic-config` ConfigMap (UI and server must reference the same one).

**Gateway URL does not work even though route exists:**

- Cause: stale/duplicate HTTPRoute for same hostname/path (often old Terraform route).
- Fix: ensure only one active route for the hostname; remove stale route with backend `ui-service` not found.

**Helm release stuck in `pending-upgrade`:**

- Fix: rollback to last healthy revision first:
  - `helm history <release> -n <ns>`
  - `helm rollback <release> <good-revision> -n <ns> --wait`
  - then retry upgrade/install.

**API pod looks for `mysecret` unexpectedly:**

- Cause: running revision still uses old values from a failed/stuck upgrade.
- Fix: clear stuck Helm state (rollback/uninstall) and reinstall with current values.

**Qdrant ports:**

UI uses HTTP (6334 per standalone manifests), API uses gRPC (6334).

**Scheduler startup:**

Disable init wait to match standalone: `scheduler.waitForApi.enabled=false`

**Force rollouts:**

```bash
kubectl -n autoptic rollout restart deploy/api-deployment deploy/autoptic-ui
kubectl -n autoptic rollout restart deploy/metrics-deployment deploy/vectors-embedding
```

### External Secrets Operator

To use AWS Secrets Manager instead of K8s Secrets:

```yaml
externalSecrets:
  enabled: true
  secretStoreName: aws-secretsstore
  webuiSecretKeyPath: "autoptic/webui-secret-key"
  openaiApiKeyPath: "autoptic/openai-api-key"
```

### Master Key Hook

The chart includes a pre-install/pre-upgrade hook to generate and preserve a Fernet-compatible master key:

```yaml
hooks:
  masterKey:
    generate: true
    strategy: pythonJob  # or "helmSecret" for pure Helm templating
```

The master key is used for encrypting sensitive data and is preserved across upgrades.
