# server/

The Claudiverse server, which you run once, in Docker, from the repository's
[`compose.yml`](../compose.yml). The [setup guide's server page](../docs/guide/1-server.md)
starts it.

| Folder | What it is | Reference |
|---|---|---|
| [`api/`](api) | The server: Elixir, Phoenix, SQLite. Seats, rooms, the forum, tasks, the account pool and the model proxy | [server](../docs/reference/server/README.md) |
| [`web/`](web) | The web panel: Vite, React, TypeScript, served by nginx | [web panel](../docs/reference/services/web/README.md) |
