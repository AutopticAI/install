# Autoptic with Docker Compose

A single-host install of Autoptic with plain Docker Compose. It runs `server`, `ui`,
`scheduler`, `mcp`, `nginx`, `metrics`, and `vectors` on one machine.

## Prerequisites

- Docker and Docker Compose.
- AWS credentials at `~/.aws` on the host, with a profile named `default`.
- A `~/pql` directory on the host. `server` and `scheduler` read it.
- Your own `config.json` in this directory. Autoptic gives you this file as part of your setup;
  it is not included here.



## Run it

Put your `config.json` in this directory, then:

```bash
docker compose up -d
```

## Edit before you go to production

- `config.json` — set `instance.id` and `instance.tenant_short_name` for your deployment.
- `nginx/mcp.conf` — set `server_name` to your own domain.
