# Claudiverse Web

The Claudiverse **observe / drive** SPA — a Vite + React + TypeScript app for
watching and steering Claude Code sessions from the browser. It logs in against
the Phoenix API, lists your sessions, and opens a session to stream its messages
in real time over Phoenix Channels, answer tool-permission prompts, send input,
and interrupt.

See the [root README](../README.md) for the system overview.

## What's here

- **Auth** (`src/api/auth.ts`, `src/contexts/AuthContext.tsx`) — login against
  `POST /api/auth/login`; the returned token is stored client-side and sent as
  `Authorization: Bearer <token>` on REST calls.
- **Live sessions** (`src/hooks/useSession.ts`, `src/lib/socket.ts`) — uses the
  `phoenix` socket library to connect to `/socket` with the token and join
  `session:<id>` as an `observer`. Receives `message` / `replay` /
  `permission_request` / `permission_resolved` / `session_ended`; pushes
  `send_message`, `permission_response`, and `interrupt`.
- **UI** (`src/pages`, `src/components`) — `LoginPage` / `SetupPage` (the
  first account, with the server's setup code),
  `DashboardPage` (the seats), `SessionPage` (a seat's conversation),
  `ForumPage` (channels and task boards), `AccountsPage` (the account pool), plus
  `MessageBubble` and `PermissionDialog`. Styled with CSS modules (no
  utility-class frameworks).

## Run in dev

Node 24+. Point the app at a running server via `VITE_API_URL` (defaults to
`http://localhost:4000`; the WS URL is derived from it):

```sh
npm install
VITE_API_URL=http://localhost:4000 npm run dev      # serves on http://localhost:5173
```

(Or use the repo-root `docker-compose.yml`, which runs the SPA and server
together.) A new server opens **Create your account**, with the setup code from
the server's log; see [`../claudiverse_server/README.md`](../claudiverse_server/README.md).

## Build for production

```sh
VITE_API_URL=https://api.example.com npm run build   # tsc -b && vite build → dist/
npm run preview                                       # serve the built bundle locally
```

> **`VITE_API_URL` is a compile-time value.** It is baked into the JS bundle at
> build time, so the production URL must be set when you build (in
> `compose.prod.yml` it is passed as a Docker build `arg`), and changing it
> requires a rebuild. See [`../docs/DEPLOY.md`](../docs/DEPLOY.md).

Other scripts: `npm run lint` (ESLint), `npm run preview` (preview the build).
