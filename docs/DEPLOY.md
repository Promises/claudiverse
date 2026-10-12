# Claudiverse — Production Deploy Runbook

Deploy target: **Docker Compose on a single Linux server (VM)**. Storage:
**SQLite** on a named Docker volume (no external DB).

The stack has two services:

| Service  | What it is                          | Image base            | Listens |
|----------|-------------------------------------|-----------------------|---------|
| `server` | Phoenix API (Elixir 1.19 / OTP 28, Phoenix 1.8, Bandit), `mix release` | `debian:bookworm-slim` | `PORT` (default 4000) |
| `server/web`    | Vite/React SPA, static build served by nginx | `nginx:1.27-alpine` | `WEB_PORT` (default 8080) → 80 |

Seats, host agents and the `cv_*` tools run on your own machines, not in this
stack: see the [setup guide](guide/README.md).

---

## 1. Prerequisites

- A Linux host with Docker Engine + Compose v2 (`docker compose version`).
- Ports of your choosing that are free on the host (defaults 4000 + 8080).
- This repo checked out (the build needs `server/api/` and `server/web/`).

## 2. Configure env

```sh
cp .env.example .env
$EDITOR .env
```

Required, at minimum:

- `SECRET_KEY_BASE` — generate one: `docker run --rm elixir:1.19-otp-28-slim mix phx.gen.secret`
  (or `openssl rand -base64 48`). Never commit it (`.env` is gitignored).
- `PHX_HOST` — the public hostname the API is reached at.
- `PORT` — API host+container port.
- `VITE_API_URL` — the API URL **as the browser will reach it** (this is baked
  into the JS bundle at build time, so changing it requires rebuilding `server/web`).
- `WEB_PORT` — host port for the SPA.

Behind a TLS-terminating reverse proxy: set `PHX_SCHEME=https`,
`PHX_URL_PORT=443`, and consider `CHECK_ORIGIN=https://your-web-host`.

Note: `DATABASE_PATH` is fixed to `/data/claudiverse.db` inside the container,
which is the mounted named volume — you don't normally change it.

## 3. Build

```sh
docker compose -f compose.yml --env-file .env build
```

## 4. Run

```sh
docker compose -f compose.yml --env-file .env up -d
```

- The server runs the release (not `mix phx.server`) and **auto-runs pending
  Ecto migrations at boot** (via `Ecto.Migrator` in the supervision tree; it
  only does this when running as a release, i.e. `RELEASE_NAME` is set).
- `server/web` waits for the server's healthcheck to pass before it is considered up.

Check status / logs:

```sh
docker compose -f compose.yml ps
docker compose -f compose.yml logs -f server
```

## 5. Where it listens

- API:  `http://<host>:<PORT>`  — health probe at `GET /api/health` → `{"status":"ok"}`.
- Web:  `http://<host>:<WEB_PORT>` — SPA (nginx liveness at `/healthz`).

## 6. Data persistence

The SQLite DB lives on the named volume `claudiverse_db` (mounted at `/data`).
It survives `down`/`up` and image rebuilds. Back it up by copying the file:

```sh
docker compose -f compose.yml exec server sh -c 'cp /data/claudiverse.db /data/backup-$(date +%F).db'
docker compose -f compose.yml cp server:/data/claudiverse.db ./claudiverse-backup.db
```

To wipe and start fresh: `docker compose -f compose.yml down -v` (the `-v`
deletes the volume — destroys all data).

## 7. The first account and tokens (auth)

A new server logs a one-time **setup code**; open the web panel and create the
first account with it:

```sh
docker compose -f compose.yml logs server | grep -A3 "setup code"
```

There is **no server-side bearer-token env var**. Auth is DB-backed: each user
has API tokens, and the `Authorization: Bearer <token>` header is validated
against the DB (`Accounts.fetch_user_by_api_token/1`). A machine's seat and host
tokens come from:

```sh
docker compose -f compose.yml exec server bin/claudiverse_server eval \
  'ClaudiverseServer.Release.connect_machine("you@example.com", "my-laptop")'
```

`POST /api/auth/login` with email and password also returns a token, and
`ClaudiverseServer.Release.create_user/2` creates an account from a script.

## 8. Upgrades

```sh
git pull
docker compose -f compose.yml --env-file .env build
docker compose -f compose.yml --env-file .env up -d
```

New migrations run automatically on the next server boot. The volume (and its
data) is preserved.

## 9. Ports

The dev stack (`compose.dev.yml`) uses `4000` and `5173`. This prod stack is
fully `PORT`/`WEB_PORT`-driven and independent of it: set them to whatever is
free on your server.

## 10. How a customer tests this in their environment

1. Clone the repo, `cp .env.example .env`, set `SECRET_KEY_BASE`, `PHX_HOST`,
   `PORT`, `WEB_PORT`, and `VITE_API_URL` (must point at the API as their
   browser will reach it, e.g. `http://their-host:4000`).
2. `docker compose -f compose.yml --env-file .env up -d --build`.
3. Verify the API: `curl http://their-host:$PORT/api/health` → `{"status":"ok"}`.
4. Open `http://their-host:$WEB_PORT` in a browser — the SPA loads.
5. Create a user/token (step 7), log in through the SPA or call the API with the
   bearer token.
6. Data persists across restarts (named volume); tear down with
   `docker compose -f compose.yml down` (keep data) or `down -v` (wipe).
