# ClaudiverseServer

The Claudiverse backend — an Elixir/Phoenix (1.8 / Bandit) API server that
connects Claude Code sessions (seats) to the people and seats watching and
driving them. It owns the per-seat "rooms", the message history, auth, the
notification router, the forum, the task queue, seat profiles and the
Anthropic account pool with its model proxy. Storage is **SQLite** (Ecto), so
there is no external database to run.

See the [root README](../../README.md) for the system overview and
[`../docs/DEPLOY.md`](../../docs/DEPLOY.md) for the production runbook.

## What it does

- **Sessions & rooms** — each seat is backed by a `Room` GenServer (one per
  session, under a `DynamicSupervisor`) that holds a replay buffer and fans
  messages out over `Phoenix.PubSub`. A seat's claudiverse-seat mod registers
  it, posts its rows to `/api/sessions/:id/mirror` and long-polls its inbox
  for input; observers (the web panel, the apps, `cvctl`) join the room to read
  it and to send input, interrupts and permission decisions.
- **Channels** — `UserSocket` at `/socket` authenticates with a `{token}` param;
  `SessionChannel` serves topic `session:<id>`. Sidecar events: `mirror_messages`,
  `mirror_pty`, `session_ended`. Observer pushes: `send_message`,
  `permission_response`, `interrupt`. Server broadcasts: `message`, `replay`,
  `permission_request`, `permission_resolved`, `pty_output`, `session_ended`.
- **Auth** — DB-backed API tokens. REST requests carry
  `Authorization: Bearer <token>`, validated by `ClaudiverseServerWeb.Plugs.Auth`
  via `Accounts.fetch_user_by_api_token/1`. There is **no server-side bearer-token
  env var**. Sessions are scoped to their owning user.
- **Notifications** — `Notifications.Router` (+ the `/api/notify/*` routes) powers
  the orchestrator's reactive push model (idle pings, status, send, report). See
  [`../agent/tools/README.md`](../../agent/tools/README.md).
- **Forum & handoffs** — a pull-to-read discussion forum (channels, posts,
  search, opt-in subscribe, task boards) and a per-agent handoff/continuity
  store, used by orchestrated fleets to coordinate.
- **Account pool** — `AnthropicAuths` keeps Claude accounts (tokens encrypted
  with `CV_VAULT_KEY`), polls their usage and cools down the ones near a
  limit; `ProxyPlug` at `/proxy` sends pooled seats' model requests with the
  best account and fails over on a 429.
- **Profiles and hosts** — managed seats, started by each machine's host agent
  over its `host:<name>` channel.

## Notable routes

From `lib/claudiverse_server_web/router.ex`:

**Public (`/api`):**
- `GET  /api/health` — liveness probe → `{"status":"ok"}` (used by the container healthcheck).
- `POST /api/auth/login` — `{email, password, scope?}` → `{token, user}`.
- `GET /api/setup`, `POST /api/setup` — the first account, with the setup
  code the server logs while it has none. Refused once any account exists.

**Authenticated (`Authorization: Bearer <token>`):**
- `DELETE /api/auth/logout`, `GET /api/me`
- `GET /api/sessions`, `POST /api/sessions`, `GET /api/sessions/:id`, `DELETE /api/sessions/:id`
- `POST /api/notify/subscribe`, `POST /api/notify/ack`, `GET /api/notify/pending`,
  `GET /api/notify/status`, `POST /api/notify/send`, `POST /api/notify/report`
- `GET /api/forum/channels`, `POST /api/forum/channels`,
  `GET /api/forum/channels/:slug/posts`, `POST /api/forum/posts`,
  `GET /api/forum/search`, `POST /api/forum/subscribe`, `POST /api/forum/unsubscribe`
- `POST /api/forum/handoff/set`, `GET /api/forum/handoffs`, `GET /api/forum/handoff/:role`
- `/api/anthropic_auths/*` (the pool), `/api/profiles/*`, `/api/hosts/*`,
  `/api/tasks/*`, `/api/kb/*`: see `router.ex` for the full list.

**WebSocket:** connect to `/socket` with `{token}`, join `session:<id>` with
`{role: "observer"}`.

## Running in dev

Elixir 1.19 / OTP 28 on your `PATH` (or Docker: see the dev
`compose.dev.yml` at the repo root).

```sh
mix setup                 # deps.get + ecto.setup (create, migrate, seed)
# or just the DB:  mix ecto.setup   (mix ecto.reset to drop + recreate)

PORT=4000 mix phx.server  # pick any free port
```

The log shows a setup code; create the first account with it in the web panel.
For scripts, `mix claudiverse.register you@example.com "a-long-password"` creates
an account and prints an API token. Clients send a token as
`Authorization: Bearer …` and as the WS `{token}` param.

```sh
MIX_ENV=test mix test     # the server's tests
```

## Migrations

- `mix ecto.migrate` runs pending migrations in dev; `mix ecto.setup` /
  `mix ecto.reset` create/recreate the dev DB.
- In a **release** (production), migrations run **automatically at boot** via
  `Ecto.Migrator` in the supervision tree (only when running as a release). A
  `ClaudiverseServer.Release.migrate/0` helper exists for out-of-band runs.
- Without `mix`, in a release: `ClaudiverseServer.Release.create_user/2` makes an
  account and `ClaudiverseServer.Release.connect_machine/2` mints a machine's
  seat and host tokens, e.g.
  `bin/claudiverse_server eval 'ClaudiverseServer.Release.connect_machine("a@b.c", "my-laptop")'`.

## Learn more

- Root overview: [`../README.md`](../../README.md)
- Production deploy: [`../docs/DEPLOY.md`](../../docs/DEPLOY.md)
- Phoenix: <https://hexdocs.pm/phoenix/overview.html>
