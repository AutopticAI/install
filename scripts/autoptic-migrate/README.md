# autoptic-migrate

`autoptic_migrate.py` moves content between two Autoptic instances. It
moves environments, agents, skills, and tools, in bulk or by name. Use it
to promote work from a dev instance into a new prod instance. It replaces
the web UI, which moves one JSON file at a time.

This is an operator script, not product functionality. An operator runs it
by hand, from a local machine. Nothing schedules it.

## What it moves

| Type | Route it uses | Notes |
|---|---|---|
| environments | `/env/{id}` | Holds secret *references*, never secret values |
| tools | `/pql/{id}` | A tool is a saved PQL script |
| skills | `/skill/{name}` | |
| agents | `/agent/config/{id}` | Agents are briefs internally |

It does not move secrets, API tokens, brief records, snapshots,
notification deliveries, or vector collections. It does not move the
built-in catalog, which is part of the server binary and not tenant
content.

## Requirements

Python 3, standard library only. There is no package to install and no
virtual environment to create.

## Commands

Read the inventory of an instance:

```bash
./autoptic_migrate.py list --src-url http://127.0.0.1:19999
```

Resolve what a selection pulls in, and report problems. This writes
nothing:

```bash
./autoptic_migrate.py plan --src-url http://127.0.0.1:19999 --agent 'ec2-*'
```

Pull a selection into a bundle on disk:

```bash
./autoptic_migrate.py export --src-url http://127.0.0.1:19999 --agent foo --out ./bundle
```

Push a bundle into a target:

```bash
./autoptic_migrate.py import --dst-url http://prod:9999 --in ./bundle --apply
```

Move straight from one instance to the other:

```bash
./autoptic_migrate.py migrate \
  --src-url http://127.0.0.1:19999 \
  --dst-url http://127.0.0.1:29999 \
  --all --apply
```

Undo a previous run:

```bash
./autoptic_migrate.py rollback --dst-url http://prod:9999 --in ./rollback-default-20260903-141339
```

Each instance also takes `--src-ep` and `--dst-ep` for the endpoint ID.
Both default to `default`.

## Dry run is the default

`import` and `migrate` write nothing until you add `--apply`. A dry run
never prompts. If an object exists on the target and differs, the dry run
reports it and counts it as a conflict. The real run asks what to do with
it.

## Selection and dependencies

`--all` takes everything. To take part of an instance, use `--env`,
`--agent`, `--skill`, or `--tool`. Each one accepts a glob and repeats.

By default, a selection pulls in what it references. An agent brings its
environment and its skills. A skill brings its tools, and any skill named
in `runtime.allowed_skills` or `runtime.lead_skill`. To move exactly the
selection and nothing more, add `--no-deps`.

The server never validates these references when it saves an object. A
broken reference only shows up at run time. This script therefore reports
them itself, as warnings. Expect to find some that were already broken on
the source before the migration.

## Secrets

An environment never holds a secret value. It holds a template reference,
such as `{{ secret 'aws.key.secret' }}`. The server returns the reference
unresolved, so an exported environment is safe to move as it is.

Provisioning the real values on the target is your job. This script never
reads, writes, or transports a secret value.

Before an import, the script collects every secret key the environments
reference. Then it compares that list against the target. If a key is
missing, the run stops and names the key. To push anyway, add
`--assume-secrets-ready`.

CAUTION: `SaveEnvironment` rejects an environment whose secret keys are
missing from the target. Provision the keys first, or the environments in
the bundle fail one by one.

The script also scans exported environments for values that look like real
credentials rather than templates. It reports them as warnings.

## Collisions

The server has no versioning and no conflict detection. Every save is an
unconditional overwrite, and the last write wins. This script adds the
missing check.

Before each write, the script reads the object on the target:

- Absent: create it, with no prompt.
- Present and identical: report it as unchanged, and write nothing.
- Present and different: show a diff, then ask.

The prompt takes `[o]verwrite`, `[s]kip`, `overwrite-[a]ll`,
`skip-a[l]l`, and `[q]uit`. To answer in advance, use `--on-conflict` with
`skip` or `overwrite`. When the input is not a terminal, the default is
`skip`.

## Rollback

The server keeps no history, so this script captures its own before each
`--apply` run. It records the current state of every object in the plan,
including an explicit marker for objects that do not exist yet. It writes
this to `rollback-<endpoint>-<timestamp>/` in the working directory.

`rollback` replays that snapshot. It restores every captured object, and
it deletes every object marked as absent.

If any object cannot be read during capture, the run stops before it
writes anything. An object missing from the snapshot is invisible to
rollback, so an overwrite of it is permanent.

## Bundle format

```
bundle/
  manifest.json               source, timestamp, counts, required secret keys,
                              warnings, and the authoritative filename-to-id map
  environments/<id>.json      the raw body, exactly as GET returns it
  agents/<id>.json
  skills/<name>.json
  tools/<id>.json
```

Each file holds one object, in the same shape the web UI's download button
produces. A bundle is therefore readable, editable by hand, and safe to
commit. If this script fails, you can still upload any single file through
the UI.

Filenames are sanitized, so they can lose characters. The real ID lives in
`manifest.json`, which the import reads first.

## Getting access to an instance

You need two things for each side of a migration: a URL the script can
reach, and a token if that instance enforces auth.

### Reaching the API

The API listens on port 9999. How you reach it depends on the deployment:

| Deployment | How to reach it |
|---|---|
| Kubernetes | `kubectl -n <namespace> port-forward svc/api-service 19999:9999`, then use `http://127.0.0.1:19999` |
| Docker Compose | Already published on `9999`. Use `http://127.0.0.1:9999` |
| ECS | The load balancer is internal, in private subnets, with no public listener. Reach it from inside the VPC, through a bastion host, an SSM port-forward session, or a VPN |

To migrate between two instances at once, forward each to its own local
port. The examples above use 19999 for the source and 29999 for the
target.

Confirm the connection before anything else:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19999/health
```

A `200` means the API is reachable.

### Tokens

Pass `--src-token` and `--dst-token`, or set `AUTOPTIC_SRC_TOKEN` and
`AUTOPTIC_DST_TOKEN`. The script sends the token in the `x-api-token`
header. It never writes a token into a bundle or a log line.

The server ships with `auth.enforce` set to false. On an instance that
still uses that default, every command works with no token at all. Send a
token anyway. It is harmless, and the command keeps working after someone
turns auth on.

If auth is on, a call with no token returns `401` and this error:

```
ERROR: GET /env -> HTTP 401: {"error":"unauthorized"}
```

### Creating a token

A token is an entry in the endpoint's `default` secret dictionary. The
server accepts any key under the `api.autoptic.token.` prefix. The key
name carries the role:

```
api.autoptic.token.<name>.role.<role>
```

The `operator` role covers everything this script does. It needs read and
write on environments, agents, skills, and tools.

CAUTION: Create the token before you turn auth on. The secret routes are
admin-only. After enforcement starts, an operator token can no longer
write the dictionary that holds the tokens.

Write the key with the secret route. The body is base64-encoded JSON, and
each value is an object with a `value` field:

```bash
python3 -c "
import base64, json
d = {'api.autoptic.token.migrator.role.operator': {'value': 'YOUR-TOKEN-HERE'}}
print(base64.b64encode(json.dumps(d).encode()).decode())
" > token.b64

curl -X POST http://127.0.0.1:19999/story/ep/default/secret/default \
  -H 'Content-Type: application/json' --data-binary @token.b64
```

A `201` means the server saved the key. Now test the token:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'x-api-token: YOUR-TOKEN-HERE' \
  http://127.0.0.1:19999/story/ep/default/env
```

CAUTION: This route replaces the whole dictionary. If the endpoint already
holds secrets, read them first and send them back together with the new
key. Otherwise you erase every secret that endpoint depends on.

### The preflight cannot verify secrets with an operator token

The secret routes are admin-only, over and above roles. An operator token
therefore cannot read `/secret/default`, and the secrets preflight cannot
compare the required keys against the target. The run stops with this
message:

```
Could not read the target's /secret/default (401). The secret routes are
admin-only, so an operator token cannot read them.
```

If you already provisioned the keys, add `--assume-secrets-ready`. The run
then continues, and the server rejects any environment whose keys are
still missing. To verify the keys instead, use an admin token.

## Exit codes

- `0`: everything asked for succeeded.
- `1`: at least one object failed, or the run stopped before it started.

A partial run always exits `1`. A run that saves 3 of 40 objects must not
look like success to a wrapper script or a CI step.

## Confirmed against a real server

These shapes were confirmed live, not assumed:

- `GET /env` and `GET /agent/config` return bare ID strings.
- `GET /skill` returns whole skill objects in one call.
- `GET /pql` returns summary objects with `pql_id`, not bare ID strings.
  It also returns 404 when the list is empty, which this script treats as
  an empty list.
- `GET /agent/config` lists every brief, not only agents. The script
  fetches each one and keeps those with a `config` key and a `skill` or
  `task` array. It reports the rest instead of dropping them silently.
- Read and write are not symmetric. An environment reads as plain JSON and
  writes as base64. A tool reads with a plain `body` and writes with that
  body base64-encoded inside a JSON envelope. Skills and agents are plain
  JSON both ways.
- A tool carries a server-written `created_on` timestamp, and a tool and a
  skill both echo back `endpoint_id`. The script ignores these three
  fields when it compares objects. Without that, identical content looks
  different on every push.

## Known limits

- The scan for literal credentials matches on field name. A secret stored
  under a name the scan does not recognize still moves to the target.
- An agent that carries inline skills moves those skills inside its own
  body. They are not separate objects, so they do not appear in a plan as
  skills. Their tools do appear.
