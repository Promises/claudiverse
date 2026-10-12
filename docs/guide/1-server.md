# 1. The server

The server is a Phoenix application with an SQLite database, and a web panel
served by nginx. Both run from `compose.yml`.

## Prerequisites

- Docker Engine with Docker Compose v2. Check with `docker compose version`.
- `git` and `openssl`.
- Two free TCP ports: one for the API (default `4000`) and one for the web
  panel (default `8080`).

## Get the code and configure it

```sh
git clone https://github.com/Promises/claudiverse.git claudiverse
cd claudiverse
cp .env.example .env
```

Open `.env` in an editor and set these values:

| Setting | What to put there |
|---|---|
| `SECRET_KEY_BASE` | The output of `openssl rand -base64 48` |
| `CV_VAULT_KEY` | The output of `openssl rand -base64 32`. It encrypts the Anthropic tokens the server stores. Keep a copy: if it changes, every account has to be added again. |
| `PHX_HOST` | The server's hostname, for example `claudiverse.example` |
| `PORT` | The API port, `4000` unless that is taken |
| `WEB_PORT` | The web panel's port, `8080` unless that is taken |
| `VITE_API_URL` | The API's address **as your browser reaches it**, for example `http://claudiverse.example:4000`. It is built into the web panel, so if you change it later, run the `up --build` command below again. |

Leave the rest as it is.

## Start it

```sh
docker compose -f compose.yml --env-file .env up -d --build
```

The first build takes a few minutes. When it is done, check the API:

```sh
curl http://claudiverse.example:4000/api/health
```

It answers `{"status":"ok"}`.

## Create your account

A new server has no account. It prints a one-time **setup code** in its log
instead:

```sh
docker compose -f compose.yml logs server | grep -A3 "setup code"
```

```
server-1  |   with this one-time setup code:
server-1  |
server-1  |       K7QD-2MXA-…
```

Open the web panel at `http://claudiverse.example:8080`. It shows **Create
your account**: enter your email, a password (8 to 72 characters) and the
setup code. You are signed in.

That closes sign-up for good: the server refuses every later sign-up, with or
without the code. A restart before you sign up prints a new code, and only the
newest one works.

## Next

[Add your Anthropic accounts](2-accounts.md).

For backups, upgrades and running behind a TLS proxy, see
[DEPLOY.md](../DEPLOY.md).
