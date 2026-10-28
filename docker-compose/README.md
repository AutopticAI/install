# Autoptic with Docker Compose

A single-host install of Autoptic with plain Docker Compose. It runs `server`, `ui`,
`scheduler`, `mcp`, `nginx`, `metrics`, and `vectors` on one machine.

## Prerequisites

- Docker and Docker Compose.
- AWS credentials at `~/.aws` on the host, with a profile named `default`.
- A `~/pql` directory on the host. `server` and `scheduler` read it.
- The AWS resources of the instance (DynamoDB tables and S3 bucket). Create them by hand, as the docs
  page "Installation" shows in "Step 5: Run Initial Setup" (`setup --run`). If they are missing,
  `rbac_mint` stops with an error and the API does not start.

`~/.aws`, `~/pql`, `config.json` and `nginx/mcp.conf` must exist before you start. If one is
missing, Compose stops with an error. It does not create an empty directory in its place.
- Your own `config.json` in this directory. Autoptic gives you this file as part of your setup.
  This directory does not include it.



## Run it

Put your `config.json` in this directory. Create a `.env` file next to `docker-compose.yaml` with
the credential of the MCP server:

```bash
echo "MCP_SERVER_TOKEN=$(openssl rand -hex 32)" > .env
chmod 600 .env
```

Then start Autoptic:

```bash
docker compose up -d
```

## Ports

Only `nginx` (port 6767) is open to the network. Use it for the web app (`/`), the API server
(`/autoptic-api/`) and MCP (`/mcp`). The other services are published on `127.0.0.1` only, for
checks from this host:

| Service | Port | Note |
|---|---|---|
| `ui` | 8080 | Through nginx: `/` |
| `mcp` | 7000 | Through nginx: `/mcp` |
| `metrics` | 6333, 6334 | Qdrant. It has no authentication. Do not open it to the network. |
| `vectors` | 8000 | Embedding service |

Docker port publishing goes around firewalld and ufw. A port published on `0.0.0.0` is open to the
network, also when the firewall blocks it.

## Image versions

Each image tag comes from `.env`. The default is `latest`. To pin a release, set the tags in `.env`:

| Variable | Images |
|---|---|
| `AUTOPTIC_SERVER_TAG` | `server`, `scheduler` and `rbac_mint`. One tag, so the three always run the same version. |
| `AUTOPTIC_UI_TAG` | `ui` |
| `AUTOPTIC_MCP_TAG` | `mcp`. The default is `1.10.0`. Use `1.10.0` or later. |
| `AUTOPTIC_METRICS_TAG` | `metrics` |
| `AUTOPTIC_VECTORS_TAG` | `vectors` |

## API tokens (RBAC)

Access control is on by default. `AUTH_ENFORCE`, `AUTH_PERMISSIONS` and `AUTH_BOOTSTRAP_SHA_ENABLE`
are `true`. The first `docker compose up -d` does this before the API starts:

1. `init_permissions` sets `config.json` to owner `1000:1000` and mode `600`.
2. `rbac_mint` mints the role and machine tokens. It logs their ids only, not the values.

After the first start, `config.json` belongs to uid `1000`. To edit it, use `sudo`.

**Get the `role.admin` token**

The bootstrap route gives the `role.admin` token to a caller that sends the SHA-256 of `config.json`.
Run these commands on the host, next to `docker-compose.yaml`:

```bash
SHA=$(sudo sha256sum config.json | cut -d' ' -f1)
curl -s -X POST http://127.0.0.1:6767/autoptic-api/story/ep/default/auth/bootstrap/credential \
  -H 'Content-Type: application/json' \
  -d "{\"bootstrap_sha\":\"$SHA\",\"principal_id\":\"role.admin\"}"
```

The answer is `{"principal_id":"role.admin","token":"<token>"}`. Keep each copy of `config.json` as
safe as this token, because its SHA-256 is the proof for bootstrap.

**MCP keys for mcp 1.10**

Released servers do not register the MCP keys. Add both in the web app, under Utils, Secrets, in the
`default` secret dict:

| Key | Value |
|---|---|
| `mcp.autoptic.service.<MCP_SERVER_ID>` | The value of `MCP_SERVER_TOKEN` in `.env` |
| `mcp.autoptic.server` | A new random value, for example from `openssl rand -hex 32`. MCP clients send it as `X-MCP-Token`. |

Then create a named token for each person in the web app: Tokens, New principal, Person.

To opt out, set `AUTH_ENFORCE=false` and `AUTH_PERMISSIONS=false` in `.env`, then run
`docker compose up -d server`. With enforce off, the token and secret APIs answer callers with no token.

**Upgrade of an existing install**

An upgrade is `docker compose pull`, `docker compose down`, then `docker compose up -d`, with a short
downtime. A new install needs no rotation. An install that ran with enforce off must do these steps in
order. Do each step only after the previous step works.

CAUTION: Do step 1 before the first `docker compose up` with this version of the file. Otherwise the
API enforces tokens at once, and MCP and REST clients without a named token stop working.

1. Add `AUTH_ENFORCE=false`, `AUTH_PERMISSIONS=false` and `AUTH_BOOTSTRAP_SHA_ENABLE=false` to `.env`.
2. Upgrade: `docker compose pull`, `docker compose down`, `docker compose up -d`. `rbac_mint` mints the
   tokens. Add the MCP keys as "MCP keys for mcp 1.10" shows.
3. Set `AUTH_BOOTSTRAP_SHA_ENABLE=true` in `.env`, then run `docker compose up -d`. Make sure that the
   `scheduler` log shows `using API token fetched via bootstrap`. To make it ask at once, run
   `docker compose restart scheduler`.
4. Create a named token for each MCP user in the web app.
5. Remove `AUTH_ENFORCE` and `AUTH_PERMISSIONS` from `.env`, then run `docker compose up -d`.
6. Rotate every token, `role.admin` first:
   `POST /autoptic-api/story/ep/default/token/role.admin/credential`. Keep the new value, then rotate
   the other tokens with it. Before step 5, the Secret API accepted calls without a token.

`docker compose up -d` recreates only the services whose settings changed. A full `down` and `up` also
works, with a short downtime.

**Rules**

- `server`, `scheduler` and `ui` mount the same `config.json`. After each edit of `config.json`,
  run `docker compose up -d --force-recreate server scheduler ui`. An edit changes the bootstrap
  hash. Do not use `docker compose restart` for this. A restart keeps the old mount, and an editor
  that saves `config.json` as a new file leaves the containers with the old content.
- `nginx` finds `server`, `ui` and `mcp` again through Docker DNS after they are created again
  (`resolver` in `nginx/mcp.conf`). You do not need to restart `nginx`.
- The web app sends API tokens only to `AUTOPTIC_SERVER_URL` (default `http://server:9999/`). The
  server URL that people set in the web app must be exactly this value.
- An MCP client sends three headers to `http://<host>:6767/mcp`: `Authorization: Bearer <named
  token>`, `X-MCP-Token: <mcp.autoptic.server value>`, and `X-MCP-Endpoint: default`. The docs page "Connect to Autoptic MCP and API" gives users the steps.
- The API server sees the nginx address for each caller. `AUTH_TRUSTED_PROXIES` (default: the private
  ranges, which hold the Compose network) makes it use the client address from `X-Forwarded-For`.
  Without it, one caller with bad tokens can cause `429` for every caller behind nginx.

## Edit before you go to production

- `config.json` — set `instance.id` and `instance.tenant_short_name` for your deployment.
- `nginx/mcp.conf` — set `server_name` to your own domain.
