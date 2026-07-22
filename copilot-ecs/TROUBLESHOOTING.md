# Troubleshooting

Every error we actually hit setting this up, in the order you're likely to hit them, with
how to diagnose and fix each.

---

## `failed to get shared config profile, default`

**When:** `server`/`scheduler` logs this and fails "Setup verification" / "Failed to get
S3 client", even though the ECS task role is correctly attached and has the right
permissions.

**Why:** The app reads `config.json`'s `aws.profile` field directly and always tries to
load a *named* shared-config profile if that field is non-empty — completely independent
of whether `AWS_PROFILE` is set as an OS environment variable, and independent of whether
an ECS task role is available. Since ECS has no `~/.aws` credentials file at all, trying
to resolve any named profile fails immediately, before the app ever falls through to the
task role.

**Fix:** Set `"aws": {"profile": ""}` (empty string) in `config.json`. This makes the SDK
skip profile-based loading entirely and use its default credential chain, which picks up
the ECS task role automatically.

---

## `mkdir: cannot create directory '...': Read-only file system`

**When:** `metrics` (or any service with an EFS-backed manifest volume) crash-loops
immediately on startup.

**Why:** Copilot's manifest-defined EFS volumes (`storage.volumes.<name>`) default to
`read_only: true`. Any container that needs to write to that path — Qdrant's
`seed-and-run.sh` creating `/qdrant/storage/collections`, or `ui`'s SQLite DB — fails
immediately.

**Fix:** Add `read_only: false` explicitly under the volume definition:
```yaml
storage:
  volumes:
    myvolume:
      path: /some/path
      read_only: false
      efs:
        uid: 10000
        gid: 10000
```
This applies separately to each container's `mount_points` entry too, if a sidecar (like
`server`'s `init`) also needs write access to a volume the main container mounts
read-only.

---

## `init` sidecar exits with code 252, and the main container then fails because the config file was never written

**When:** Using `public.ecr.aws/aws-cli/aws-cli:latest` as an init sidecar to pull a file
from S3.

**Why:** This image's `ENTRYPOINT` is already `/usr/local/bin/aws` — it is not a
general-purpose shell image. If you only set:
```yaml
command: ["sh", "-c", "aws s3 cp s3://... /mnt/shared/config.json"]
```
without also overriding `entrypoint`, ECS runs the image's entrypoint plus your command
concatenated:
```
aws sh -c "aws s3 cp s3://... /mnt/shared/config.json"
```
— which is invalid AWS CLI syntax. The CLI's usage-error exit code is **252**, which is
exactly what you'll see in `aws ecs describe-tasks`.

**Fix:** Override `entrypoint` explicitly, not just `command`:
```yaml
entrypoint: ["/bin/sh", "-c"]
command: ["aws s3 cp s3://<bucket>/config.json /mnt/shared/config.json"]
```

---

## `RuntimeError: unable to mmap <N> bytes from file <model>.safetensors: Cannot allocate memory (12)`

**When:** A service loading a large ML model (e.g. `vectors` loading `e5-large-v2`, a
~1.3GB safetensors file) crashes on startup.

**Why:** The task's `cpu`/`memory` allocation is too small. Even though `mmap` is normally
lazy (pages aren't all resident in RAM at once), Fargate's memory accounting still
requires meaningfully more headroom above the raw file size than you'd expect on a normal
host — undersized containers (e.g. the Fargate default of 512MB) fail immediately trying
to map a 1.3GB file.

**Fix:** Size the task generously above the model's file size — e.g. `cpu: 1024`,
`memory: 4096` for a ~1.3GB model. If you resize and still see the exact same error
afterward, double check you're actually looking at logs from the *new* task definition and
not a stale, still-crash-looping old one from mid-deployment (see next entry).

**How to actually verify a resize fixed it, instead of guessing from timestamps:**
```bash
aws ecs describe-task-definition --task-definition <family>:<revision> \
  --query 'taskDefinition.{TaskCpu:cpu,TaskMemory:memory}'
```
Confirm the revision number matches what your service is actually running
(`aws ecs describe-services ... --query 'services[0].taskDefinition'`), and check log
timestamps are genuinely *after* that revision's tasks started (from
`aws ecs describe-services ... --query 'services[0].events'`), not from an old task still
finishing its crash loop during the transition.

---

## Deployment rolls back with `ECS Deployment Circuit Breaker was triggered`

**When:** A service fails to stabilize and CloudFormation automatically rolls the whole
stack back.

**Why:** This is ECS's generic "tasks kept failing to become healthy" mechanism — it's a
symptom, not a root cause. The actual reason is almost always one of the other errors in
this document (bad AWS profile config, read-only EFS mount, undersized memory, bad
healthcheck).

**Fix:** Get the real per-container exit code and reason, which survives even after the
CFN stack and log group have already been torn down by the rollback:
```bash
CLUSTER=<cluster-arn>
TASKS=$(aws ecs list-tasks --cluster "$CLUSTER" --family <app>-<service>-<container> \
  --desired-status STOPPED --query 'taskArns' --output text)
aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASKS \
  --query 'tasks[].{StoppedReason:stoppedReason,Containers:containers[].{Name:name,ExitCode:exitCode,Reason:reason}}'
```

---

## Log group doesn't exist yet / `ResourceNotFoundException` on `aws logs tail`

**When:** Trying to check logs for a service that just failed extremely fast, or whose
CloudFormation stack already rolled back.

**Why:** If the task died before shipping a single log line, or if the whole stack rolled
back and tore down the log group along with everything else, there's nothing to tail.

**Fix:** Use `aws ecs describe-tasks` (see above) instead — it's the one thing that
survives a rollback for a little while. If you need to inspect the container's live
filesystem/environment/memory before it crashes, temporarily override its `command` to
`["sleep", "600"]`, redeploy, then:
```bash
aws ecs execute-command --cluster <cluster> --task <task-arn> --container <name> \
  --interactive --command "/bin/sh"
```
Revert the `sleep` override once you're done debugging — don't leave test values in a
manifest.

---

## `Ctrl+C` on a stuck `copilot svc deploy` doesn't actually stop anything

**When:** A deploy seems to hang, you cancel the local CLI, and the exact same failure
reappears on the next attempt.

**Why:** `Ctrl+C`/cancelling `copilot svc deploy` only kills the **local
progress-watcher** process. The underlying CloudFormation stack update keeps running on
AWS's side regardless. If you then immediately re-run `copilot svc deploy`, you'll get:
```
stack <name> is currently being updated and cannot be deployed to
```

**Fix:** Check the real stack status before doing anything else:
```bash
aws cloudformation describe-stacks --stack-name <app>-<env>-<service> \
  --query 'Stacks[0].StackStatus'
```
Wait for it to reach a terminal state (`*_COMPLETE` or `*_FAILED`) before retrying. ECS
rolling deployments with health checks and old crash-looping tasks to drain can
legitimately take 5–15+ minutes — this isn't automatically "stuck."

---

## `copilot svc exec` says "found no running task" even though the task is `RUNNING`/`HEALTHY`

**When:** Trying to shell into a container that's confirmed up via
`aws ecs describe-tasks`.

**Why:** Unclear — possibly a service-name lookup quirk in some Copilot CLI versions.

**Fix:** Bypass Copilot and call the AWS CLI directly (requires the Session Manager plugin
— see README prerequisites):
```bash
aws ecs execute-command --cluster <cluster-arn> --task <task-arn> \
  --container <container-name> --interactive --command "/bin/sh"
```

---

## `Not Secure` warning in the browser

**When:** Visiting the ALB's default `*.elb.amazonaws.com` URL.

**Why:** Copilot's ALB only gets an HTTP listener by default, and the shared
`*.elb.amazonaws.com` hostname can never get a real, browser-trusted certificate — public
CAs won't issue one for a domain you don't own.

**Fix:** Not a bug — see `DNS-TLS-SETUP.md` for setting up a real domain + ACM certificate.

---

## `rpc error: code = Unavailable desc = name resolver error: produced zero addresses`

**When:** `server` logs this trying to reach `metrics` (Qdrant) or `vectors`, even though
`aws servicediscovery list-namespaces` shows the environment's private DNS namespace
exists, and `server`/`ui` (which work fine) both resolve correctly.

**Why:** A Backend Service only gets registered under Service Connect/Cloud Map — i.e. it
only gets a DNS record at all — if its manifest's `image:` block declares a `port`. Without
`port`, Copilot silently deploys the service with no Service Connect endpoint whatsoever.
Check directly whether the DNS record even exists before assuming it's a networking/SG
problem:
```bash
aws route53 list-resource-record-sets --hosted-zone-id <PRIVATE_ZONE_ID> \
  --query 'ResourceRecordSets[].{Name:Name,Type:Type}' --output table
```
If the service you expect isn't listed at all (not even an A/SRV record), this is the bug.

**Fix:** Add `port: <container-port>` under `image:` in the service's manifest, even
though it's a `Backend Service` with no ALB and "does not allow any traffic" per Copilot's
own manifest comment — that comment refers to *public* traffic, not intra-environment
Service Connect traffic, which still needs the port declared. Redeploy the service, then
re-check the DNS record exists before assuming anything else is wrong.

---

## `ui` can't find `server`, but curling `server` directly from inside `ui`'s container works fine

**When:** The app's admin/settings page shows something like `Can't connect with the
server through the URL http://server.<env>.<app>.local:9999/. The URL will not be saved`
when you try to manually type in the internal Cloud Map address there.

**Why:** That validation runs in the **browser** (client-side JS), which has no route to
a private VPC-only DNS name at all — it will always fail for that address, regardless of
whether it's correct. This is a red herring; it doesn't mean the backend-to-backend
connection is broken. Verify the real connection works by exec'ing into `ui`'s own
container and curling `server` directly:
```bash
aws ecs execute-command --cluster <cluster> --task <ui-task-id> --container ui \
  --interactive --command "/bin/sh -c 'curl -sv http://server.<env>.<app>.local:9999/<endpoint>'"
```
If that succeeds, the settings-page field was never the right place to configure this.

**Fix:** `ui` needs an environment variable telling its own backend where to find
`server` — the same convention used in this app's Kubernetes deployment
(`AUTOPTIC_SERVER_URL`). Add it to `ui`'s manifest:
```yaml
variables:
  AUTOPTIC_SERVER_URL: http://server.<ENV_NAME>.<APP_NAME>.local:9999/
```
Do not rely on the browser-facing settings field for this — it's validated client-side and
can never succeed against a private DNS name.
