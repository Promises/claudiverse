# Configuration reference

This page lists everything that configures the `claudiverse-seat` mod: how it is installed as a Claude Code plugin, the two plugin options, every environment variable it reads, every fixed constant in `hooks/register.ts`, and every status-line string and log message it can print. The mod is configured once per machine through the plugin options, and a launcher (a host agent starting a profile, or `cv-spawn`) can override them per session with environment variables. Nothing here is configurable at run time beyond these inputs; the timing constants are fixed in the source.

## How it works

### Installation as a plugin

The mod is a Claude Code plugin. The files that define it are:

| File | What it shows |
|---|---|
| `.claude-plugin/plugin.json` | `name` is `claudiverse-seat`, `version` is `0.10.1`. The `description` reads: "Makes every Claude Code session (2.1.287+) a claudiverse seat: registration, remote input and interrupt, the message mirror, remote answers. Works offline as plain Claude Code." It declares the two options (`userConfig`) below. |
| `hooks/hooks.json` | `{ "modules": ["./register.ts"] }`: the plugin loads one module, `hooks/register.ts`. |
| `hooks/register.ts` | The mod itself. It exports `register`, which attaches the hooks (`session.start`, `session.append`, `tool.call`, `classic.PermissionRequest`, `classic.Stop`, `agent.spawn`, `session.compact`, `command.run`, `turn.step`, `turn.start`, `turn.complete`, `session.end`). |
| `tsconfig.json` | Extends `./.claude-plugin/types/tsconfig.json`. |

The source comment states the target: a stock Claude Code 2.1.287 or later, which has mods. How to install the mod is in the guide, [3. A machine for seats](../../../guide/3-machine.md).

### Resolution order

At `session.start` the mod resolves its settings in this order:

1. If `CLAUDIVERSE_PATCHED_RUNTIME` is non-empty, the mod does nothing for the whole session.
2. URL: `CLAUDIVERSE_URL`, else the plugin option `server_url`.
3. Token: `CLAUDIVERSE_TOKEN`, else the plugin option `seat_token`.
4. If the URL or the token is still empty, the mod does nothing and Claude Code runs as stock.
5. Title: `CLAUDIVERSE_TITLE`, else the title of the seat the server already has for this Claude session id (asked with `GET /api/seats/whoami`), else `<folder>-<first 4 characters of the session id>`.
6. Host: `CLAUDIVERSE_HOST`, else the output of the `hostname` command.

Every environment variable is trimmed; an empty or whitespace-only value counts as unset. A trailing `/` on the URL is removed.

## Configuration

### Plugin options

Set once per machine (`userConfig` in `.claude-plugin/plugin.json`). The mod reads them as `options.server_url` and `options.seat_token`.

| Option | Title | Sensitive | Description (from `plugin.json`) |
|---|---|---|---|
| `server_url` | claudiverse server | no | "Address of the claudiverse server, for example `https://claudiverse.example`. Leave empty to keep this machine's sessions out of claudiverse." |
| `seat_token` | Seat token | yes | "The token this machine's seats use with the claudiverse server." |

### Environment variables

These are exactly the variables read with `$.env.get(` in `register.ts`, and all are read once, at `session.start`.

| Variable | Default | Precedence and effect |
|---|---|---|
| `CLAUDIVERSE_PATCHED_RUNTIME` | unset | If non-empty, the mod stays inert: no registration, no mirror, no hooks acting. The patched binary's runtime connects the seat itself. |
| `CLAUDIVERSE_URL` | plugin option `server_url` | Server address. Wins over the option. |
| `CLAUDIVERSE_TOKEN` | plugin option `seat_token` | Seat token. Wins over the option. |
| `CLAUDIVERSE_TITLE` | derived (see above) | Pins the title. A pinned seat skips the `whoami` lookup, gets origin `manual` unless `CLAUDIVERSE_ORIGIN` is set, and ignores `/rename`. |
| `CLAUDIVERSE_HOST` | output of `hostname` (unset if that fails) | Sent as `host` in the registration and in each inbox poll. |
| `CLAUDIVERSE_FLEET` | unset | Sent as `fleet` in the registration and in each inbox poll. |
| `CLAUDIVERSE_ORIGIN` | see below | Sent as `origin`. |
| `CLAUDIVERSE_PROFILE` | unset | Sent as `profile_id` in the registration. |
| `CLAUDIVERSE_PROFILE_REVISION` | unset | Sent as `profile_revision` in the registration. |
| `CLAUDIVERSE_TMUX` | unset | Sent as `tmux_session` in the registration. |

Default for `origin` when `CLAUDIVERSE_ORIGIN` is unset: `manual` if the title is pinned by `CLAUDIVERSE_TITLE`; otherwise omitted if the `whoami` lookup found an existing seat; otherwise `plain`. See [registration.md](registration.md).

### Constants

Fixed in `hooks/register.ts`; none can be changed without editing the mod.

| Constant | Value | Meaning |
|---|---|---|
| `POLL_WAIT_S` | 25 | `wait` (seconds) sent with each inbox poll. The server caps a poll at 60 s. |
| `RETRY_MS` | 5000 | First delay after a failed inbox poll, and the first backoff for question and permission polls. Doubles per consecutive failure. |
| `POLL_RETRY_MAX_MS` | 60 000 | Longest delay between failed polls (inbox, question, permission). |
| `REGISTER_RETRY_MS` | 30 000 | First delay before retrying a failed registration. Doubles per failure. |
| `REGISTER_RETRY_MAX_MS` | 300 000 | Longest delay between registration retries (5 min). |
| `FLUSH_MS` | 300 | How long a queued mirror row waits so a burst goes out as one POST. |
| `SERVER_WAIT_MS` | 3000 | How long session start waits on the server per request (`whoami`, registration), and how long the question withdraw is awaited. `$.http.fetch` has no timeout of its own and an unreachable host holds a request about 30 s. |
| `MAX_BATCH` | 200 | Most rows per mirror POST; the server's limit per call. |
| `AGENT_POLL_MS` | 15 000 | While any agent is live, how often the agent list is read again. |
| `QUESTION_POLL_S` | 25 | `wait` (seconds) sent on every question and permission poll; kept under the 30 s a `$.http.fetch` request is allowed. |
| `PERMISSION_OUTAGE_MS` | 900 000 (15 min) | How long a permission poll waits out a server outage before giving up. Question polls have no such limit. |
| `INBOX_COMMANDS` | `compact` | The only slash command run when it arrives through the inbox. |
| `TERMINAL` | `completed`, `failed`, `killed` | Agent statuses that count as finished; an agent in one of them is reported once with `agent_ended`, and stops the agent re-poll. |

Backoff is `min(RETRY_MS * 2^(failures-1), POLL_RETRY_MAX_MS)`: 5 s, 10 s, 20 s, 40 s, 60 s, 60 s, and so on. Registration retry is 30 s, 60 s, 120 s, 240 s, 300 s, 300 s, and so on.

### Status line and log messages

The status line is set with `$.ui.status`; the other messages go to the Claude Code UI log with `$.ui.log`. `<title>`, `<name>`, `<cmd>`, `<id>` and `<message>` are filled in at run time.

| Text | Kind | When and what it means |
|---|---|---|
| `claudiverse · <title>` | status | The seat is registered and the inbox poll is running. Also restored after an outage, after a question is settled, and (with the new name) after a successful `/rename`. |
| `claudiverse offline` | status | Registration did not finish within `SERVER_WAIT_MS` or failed, or the second consecutive inbox poll failed. Claude Code works as stock; the mod retries on its own. |
| `claudiverse · <title> · question sent: answer here or in claudiverse` | status | An `AskUserQuestion` was relayed to the server and is open both at the terminal and in the apps. See [questions-and-permissions.md](questions-and-permissions.md). |
| `claudiverse: interrupt received, but no running turn is known` | log | The app's Interrupt arrived (inbox 205) while no main turn was known to be running. Nothing was aborted. |
| `claudiverse: interrupt failed for turn <id>: <message>` | log | `$.turn.abort` rejected. Press Escape at the terminal. |
| `claudiverse: another poller took this seat over; inbox stopped` | log | The inbox answered 409. The loop stops and does not restart. |
| `claudiverse: /<cmd> from the inbox was not run (only /compact is)` | log | A slash text other than `/compact` arrived through the inbox and was refused. The seat reports idle. |
| `claudiverse: /<cmd> from the inbox failed: <message>` | log | `/compact` from the inbox rejected. The seat reports idle. |
| `claudiverse: could not submit an inbox prompt: <message>` | log | `$.prompt.submit` rejected for an inbox prompt. The seat reports idle. |
| `claudiverse: the seat keeps its launch title <title> (CLAUDIVERSE_TITLE)` | log | `/rename` was used on a seat whose title is pinned by `CLAUDIVERSE_TITLE`. The seat is not renamed. |

The `/claudiverse` command answers with a result text rather than a log line: `claudiverse: seat <title> · session <id or "not registered"> · <url>`, then ` · host <host>` and ` · fleet <fleet>` when set. See [commands.md](commands.md).

Messages that are not printed: failed mirror batches, failed registration retries, and failed question or permission polls are silent. A remote question denied from the apps returns the tool result `declined via claudiverse` when the server gives no reason of its own.

## Failure modes and troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| No status line, no seat, no `/claudiverse` command | No URL or no token resolved, or `CLAUDIVERSE_PATCHED_RUNTIME` is set. | Set `server_url` and `seat_token`, or `CLAUDIVERSE_URL` and `CLAUDIVERSE_TOKEN`. |
| A variable set in the shell has no effect | It is empty or whitespace only (counts as unset), or the launcher did not pass it to the `claude` process. | Check the variable in the environment of the process that starts Claude Code. |
| Seat has an unexpected title | `CLAUDIVERSE_TITLE` unset and the derived or `whoami` title was used. | Pin the title with `CLAUDIVERSE_TITLE`. See [registration.md](registration.md). |
| `claudiverse offline` | See the table above and [outages-and-session-end.md](outages-and-session-end.md). | Check the URL, the token and that the server is reachable. |
| Seat has wrong host | `CLAUDIVERSE_HOST` unset, and `hostname` returned the machine's own name. | Set `CLAUDIVERSE_HOST`. |

## Related pages

- [Mod overview](README.md)
- [Registration](registration.md)
- [Inbox](inbox.md)
- [Mirroring](mirroring.md)
- [Questions and permissions](questions-and-permissions.md)
- [Agents and background work](agents-and-background.md)
- [Commands](commands.md)
- [Outages and session end](outages-and-session-end.md)
- [Server API](server-api.md)
- Server: [Accounts, sign-up and tokens](../../server/auth.md), [Configuration](../../server/configuration.md)
- Runners and tools: [cv-mcp: the claudiverse MCP server (overview)](../../runners/mcp.md)
- Host agent: [Configuration reference](../../host-agent/configuration.md)

## Source

- `agent/mod/hooks/register.ts`
- `agent/mod/.claude-plugin/plugin.json`
- `agent/mod/hooks/hooks.json`
- `agent/mod/tsconfig.json`
