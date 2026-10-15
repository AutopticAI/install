# Autoptic with Docker Compose

A single-host install of Autoptic with plain Docker Compose. It runs `server`, `ui`,
`scheduler`, `mcp`, `nginx`, `metrics`, and `vectors` on one machine.

## Prerequisites

- Docker and Docker Compose.
- AWS credentials at `~/.aws` on the host, with a profile named `default`.
- A `~/pql` directory on the host. `server` and `scheduler` read it.

`~/.aws`, `~/pql`, `config.json` and `nginx/mcp.conf` must exist before you start. If one is
missing, Compose stops with an error. It does not create an empty directory in its place.
- Your own `config.json` in this directory. Autoptic gives you this file as part of your setup;
  it is not included here.



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
| `AUTOPTIC_MCP_TAG` | `mcp` |
| `AUTOPTIC_METRICS_TAG` | `metrics` |
| `AUTOPTIC_VECTORS_TAG` | `vectors` |

## API tokens (RBAC)

With the default settings, the API server accepts calls without a token. Do these steps in this
order to turn on API tokens. Do each step only after the previous step works.

1. Protect `config.json`. Each person who can read it can get every role token.

   ```bash
   sudo chown 1000:1000 config.json && chmod 600 config.json
   ```

2. Mint the tokens. The output shows `RBAC MINT SUMMARY` with the minted ids.

   ```bash
   docker compose --profile rbac run --rm rbac_mint
   ```

3. Store two keys in the `"default"` secret dict through the Secret API. Do this before step 6,
   because after step 6 the Secret API accepts only an admin token.
   - `mcp.autoptic.service.<MCP_SERVER_ID>` (default `mcp.autoptic.service.local-demo`): the value
     of `MCP_SERVER_TOKEN`.
   - `mcp.autoptic.server`: a new random value. Each MCP client sends it as `X-MCP-Token`.
4. Add `AUTH_BOOTSTRAP_SHA_ENABLE=true` to `.env`, then run `docker compose up -d server`. Make sure
   that the `scheduler` log shows `using API token fetched via bootstrap`. While bootstrap is off, the
   scheduler asks only every 5 minutes. To make it ask at once, run `docker compose restart scheduler`.
5. In the web app, create a named token for each MCP user: Tokens, New principal, Person.
6. Add `AUTH_ENFORCE=true` and `AUTH_PERMISSIONS=true` to `.env`, then run `docker compose up -d server`.
7. Rotate every token, `role.admin` first:
   `POST /autoptic-api/story/ep/default/token/role.admin/credential`. Keep the new value, then rotate
   the other tokens with it. In steps 2 to 6 the Secret API accepted calls without a token.

To turn a switch off, remove it from `.env` and run `docker compose up -d server`. The tokens stay.

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
  token>`, `X-MCP-Token: <mcp.autoptic.server value>`, and `X-MCP-Endpoint: default`.
- The API server sees the nginx address for each caller. Add the range of the Compose network to
  `auth.trusted_proxies` in `config.json`. Without it, one caller with bad tokens can cause `429`
  for every caller behind nginx.

## Edit before you go to production

- `config.json` — set `instance.id` and `instance.tenant_short_name` for your deployment.
- `nginx/mcp.conf` — set `server_name` to your own domain.
