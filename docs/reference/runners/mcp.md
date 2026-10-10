# cv-mcp: the claudiverse MCP server (overview)

`cv-mcp` is a stdio MCP server that exposes the Claudiverse server as `cv_*` tools to a Claude Code seat. An orchestrator seat uses it to watch other seats, read what they did in bounded amounts, and act on them; worker seats use a restricted subset to report up and to use the shared forum, task and knowledge tools. It is a thin client: every tool calls the server's HTTP API through `cv-core`.

It runs as `node orchestrator/cv-mcp.mjs` (also the package bin `claudiverse-mcp`). Run `npm install` once in `orchestrator/` first: it installs `@modelcontextprotocol/sdk`, and the server also imports `zod`.

## How it works

The model is push, not poll. An orchestrator calls `cv_subscribe` with the titles of the seats it manages. When a watched seat finishes a turn or asks a question, the server queues a ping and injects a turn into the orchestrator once the orchestrator is idle. The ping carries no content; the orchestrator pulls only what it needs with the bounded readers (`cv_last`, `cv_tail`, `cv_questions`) and then acts (`cv_send`, `cv_answer`, `cv_decline`, `cv_ack`).

```mermaid
flowchart LR
    O["orchestrator seat<br/>(Claude Code)"] -- "stdio MCP" --> M["cv-mcp<br/>cv_* tools"]
    M -- "HTTP /api/* (Bearer token)" --> S["Claudiverse server"]
    W1["worker seat lorem-w1"] -- "mirror, idle" --> S
    W2["worker seat lorem-w2"] -- "mirror, idle" --> S
    S -- "ping turn injected<br/>when watched seat ends a turn" --> O
    M -. "cv_send / cv_answer" .-> S
    S -. "inbox" .-> W1
    W1 -- "cv_report (own cv-mcp)" --> S
```

### Seat identity

Twenty tools need to know which seat they serve (`SELF`), because they act as the caller: `cv_report`, `cv_request_human`, `cv_subscribe`, `cv_pending`, `cv_ack`, `cv_forum_post`, `cv_forum_subscribe`, `cv_forum_unsubscribe`, `cv_forum_my_subscriptions`, `cv_handoff_set`, `cv_task_create`, `cv_task_ready`, `cv_task_dep`, `cv_task_add`, `cv_task_done`, `cv_submit_match`, `cv_fact_add`, `cv_fact_relate`, `cv_ruling_add` and `cv_doc_revise`. (`cv_send`, `cv_answer`, `cv_decline` and `cv_forum_assign` use it when known and work without it.) `SELF` is taken, in order, from `CLAUDIVERSE_SELF`, then `CLAUDIVERSE_TITLE`, then from the server:

1. At startup, after connecting, `cv-mcp` asks `GET /api/seats/whoami`, by `title=<SELF>` if `SELF` is already known, otherwise by `claude_session_id=<CLAUDE_CODE_SESSION_ID>`. If neither exists it does not ask.
2. A miss (the seat has not registered yet, or the call failed) is retried: every 2 s for the first 30 attempts, then every 30 s, until the server answers with a title.
3. The response fields used are `title`, `role` and `can_notify`.

Until `SELF` is known, tools that need it return:

```
error: can't tell which seat this is yet — no CLAUDIVERSE_SELF/_TITLE, and the server has no seat registered for this session (yet). Try again in a moment.
```

### Tool groups and policy

Each tool is tagged with the group that was current when it was registered. The groups are:

| Group | Tools | Meaning |
|---|---|---|
| `report` | `cv_report` | Push a report up to whoever watches this seat. |
| `notify` | `cv_request_human` | Page the human operator. |
| `full` | `cv_list`, `cv_status`, `cv_subscribe`, `cv_pending`, `cv_ack`, `cv_tail`, `cv_last`, `cv_questions`, `cv_send`, `cv_answer`, `cv_decline` | The orchestrator set: watch, read and drive other seats. |
| shared (any other tag) | the forum, handoff, task, submission, ledger, knowledge-store and symbol tools; also `cv_spawn`, `cv_stop`, `cv_ps` when registered | Available to every role. |

`allowedGroup(group, role, canNotify)` in `cv-policy.mjs` decides whether a group is enabled:

| Group | worker | delegate | orchestrator |
|---|---|---|---|
| `report` | yes | yes | no |
| `notify` | `canNotify` | `canNotify` | `canNotify` |
| `full` | no | yes | yes |
| shared | yes | yes | yes |

The `notify` group follows `canNotify` alone, whatever the role.

**Static mode (`CLAUDIVERSE_ROLE` set).** Groups are registered once, by guards at startup, and the set never changes. Whether a group is registered at all:

| Group | Registered when |
|---|---|
| `report` | `CLAUDIVERSE_ROLE` is `worker` or `delegate` |
| `notify` | `CLAUDIVERSE_ROLE` is not `worker` and `CLAUDIVERSE_NOTIFY=1` |
| `full` | `CLAUDIVERSE_ROLE` is not `worker` |
| lifecycle tools | `CLAUDIVERSE_LIFECYCLE=1` and `CLAUDIVERSE_ROLE` is not `worker` |
| shared | always |

So per role:

| `CLAUDIVERSE_ROLE` | Tools registered |
|---|---|
| `worker` | `cv_report` + shared |
| `delegate` | `cv_report` + `full` + shared; `cv_request_human` with `CLAUDIVERSE_NOTIFY=1`; lifecycle tools with `CLAUDIVERSE_LIFECYCLE=1` |
| `orchestrator` | `full` + shared (no `cv_report`); `cv_request_human` with `CLAUDIVERSE_NOTIFY=1`; lifecycle tools with `CLAUDIVERSE_LIFECYCLE=1` |

Any other non-empty value behaves like `orchestrator` for these guards.

**Dynamic mode (`CLAUDIVERSE_ROLE` unset).** Every group is registered, then enabled or disabled by `allowedGroup`:

- Initially, from the environment: role `orchestrator` and `canNotify` = (`CLAUDIVERSE_NOTIFY=1`). So until the server answers, `full` and shared are on, `report` is off, and `notify` is on only with `CLAUDIVERSE_NOTIFY=1`. An unreachable server leaves this in place.
- Once the server answers `whoami`, the policy becomes the server's `role` (falling back to the initial role if empty) and `can_notify === true`.
- Then it is refreshed every 60 s, by `claude_session_id` when one is set (a title can change), otherwise by title. A failed or empty answer keeps the last policy. If the seat was not named by `CLAUDIVERSE_SELF` or `CLAUDIVERSE_TITLE`, `SELF` follows a `/rename`; a launcher-named seat keeps its name.

The lifecycle tools are tagged in the shared group (see the caveat below), and they are registered only if `CLAUDIVERSE_LIFECYCLE=1` and the static `ROLE` is not `worker`. In dynamic mode `ROLE` is always the default `orchestrator`, so for a dynamic seat the only condition is `CLAUDIVERSE_LIFECYCLE=1`. Because shared tools are always enabled, a dynamic seat that has `CLAUDIVERSE_LIFECYCLE=1` keeps `cv_spawn`, `cv_stop` and `cv_ps` even when the server says its role is `worker`. The "hard gate" for workers holds only for a static `CLAUDIVERSE_ROLE=worker`.

### The clock

Every tool result is the tool's text followed by a blank line and a local-time stamp:

```
<result text>

⏱ 2026-01-31 14:05:09 CET
```

The format is `⏱ YYYY-MM-DD HH:MM:SS TZ`, from the machine's local clock. `cv_forum_post` also appends `⏱ posted <stamp>` to the post body it sends.

## Configuration

Setup: give the seat the MCP server in one of two ways.

- By name from the machine's MCP catalog: add a `claudiverse` entry to the catalog and list `claudiverse` in a profile's `mcp` list. See [the setup guide](../../guide/README.md) (machine step).
- Or copy one of the example configs, fill in the token, and pass it with `--mcp-config`.

Orchestrator (`orchestrator.mcp.json.example`; the real file also carries `_comment` keys):

```json
{
  "mcpServers": {
    "claudiverse": {
      "command": "node",
      "args": ["/ABS/PATH/TO/claudiverse/orchestrator/cv-mcp.mjs"],
      "env": {
        "CLAUDIVERSE_URL": "http://claudiverse.example:4000",
        "CLAUDIVERSE_TOKEN": "REPLACE_WITH_CLAUDIVERSE_TOKEN",
        "CLAUDIVERSE_SELF": "your-instance-title"
      }
    }
  }
}
```

Worker (`worker.mcp.json.example`):

```json
{
  "mcpServers": {
    "claudiverse": {
      "command": "node",
      "args": ["/ABS/PATH/TO/claudiverse/orchestrator/cv-mcp.mjs"],
      "env": {
        "CLAUDIVERSE_URL": "http://claudiverse.example:4000",
        "CLAUDIVERSE_TOKEN": "REPLACE_WITH_CLAUDIVERSE_TOKEN",
        "CLAUDIVERSE_ROLE": "worker"
      }
    }
  }
}
```

The worker example sets no `CLAUDIVERSE_SELF`; `SELF` comes from the inherited `CLAUDIVERSE_TITLE`, or from the server.

### Environment variables

| Variable | Default | Read by | Effect |
|---|---|---|---|
| `CLAUDIVERSE_URL` | `http://localhost:4000` | `cv-core` | Server base URL (a trailing `/` is stripped). |
| `CLAUDIVERSE_TOKEN` | none; required | `cv-core` | Bearer token sent on every request. |
| `CLAUDIVERSE_SELF` | unset | `cv-mcp` | This seat's title. First choice for `SELF`; also stops `/rename` from changing `SELF`. |
| `CLAUDIVERSE_TITLE` | unset | `cv-mcp` | Second choice for `SELF` (normally set by the launcher); same `/rename` effect. |
| `CLAUDE_CODE_SESSION_ID` | set by Claude Code | `cv-mcp` | Used to look the seat up on the server (`claude_session_id`) when no title is known, and for the 60 s policy refresh. |
| `CLAUDIVERSE_ROLE` | unset (dynamic mode) | `cv-mcp` | `worker`, `delegate` or `orchestrator`. When set, the tool set is fixed at startup (static mode). When unset, dynamic mode. |
| `CLAUDIVERSE_NOTIFY` | unset | `cv-mcp` | `1` registers `cv_request_human` in static mode (non-worker role) and is the initial `canNotify` in dynamic mode. |
| `CLAUDIVERSE_LIFECYCLE` | unset | `cv-mcp` | `1` registers `cv_spawn`, `cv_stop`, `cv_ps` (unless `CLAUDIVERSE_ROLE=worker`). See [mcp-lifecycle.md](mcp-lifecycle.md). |
| `CLAUDIVERSE_SCOPE` | unset | `cv-mcp` (`cv_doc_search`) | Default `scope` for `cv_doc_search` when the call passes none. |
| `CV_TASK_REPORT` | unset | `cv-mcp` (`cv_task_done`) | `notify` replaces the forum copy of the completion report with a one-line direct ping from source `tasks:<lane>`. |

## Interface

The tools are documented per group. Every tool listed as "shared" is available to every role.

| Page | Group | Tools |
|---|---|---|
| [mcp-seats.md](mcp-seats.md) | report, notify, full | `cv_report`, `cv_request_human`, `cv_list`, `cv_status`, `cv_subscribe`, `cv_pending`, `cv_ack`, `cv_tail`, `cv_last`, `cv_questions`, `cv_send`, `cv_answer`, `cv_decline` |
| [mcp-forum.md](mcp-forum.md) | shared | `cv_forum_*` (channels, posts, subscriptions, status, pin, archive) |
| [mcp-handoffs.md](mcp-handoffs.md) | shared | `cv_handoff_set`, `cv_handoff_get`, `cv_handoff_list` |
| [mcp-lifecycle.md](mcp-lifecycle.md) | shared (opt-in) | `cv_spawn`, `cv_stop`, `cv_ps` |
| [mcp-tasks.md](mcp-tasks.md) | shared | `cv_task_create`, `cv_task_ready`, `cv_task_list`, `cv_task_show`, `cv_task_dep`, `cv_task_health`, `cv_task_add`, `cv_task_done` |
| [mcp-ledger.md](mcp-ledger.md) | shared | `cv_fact_add`, `cv_fact_relate`, `cv_fact_get`, `cv_ruling_add` |
| [mcp-knowledge.md](mcp-knowledge.md) | shared | `cv_doc_put`, `cv_doc_get`, `cv_doc_revise`, `cv_doc_relate`, `cv_doc_search`, `cv_doc_anchor`, `cv_doc_history`, `cv_doc_stale`, `cv_address`, `cv_symbol_record`, `cv_symbol_resolve` |
| [mcp-submissions.md](mcp-submissions.md) | shared | `cv_submit_match`, `cv_submission_list`, `cv_submission_get` |

### Standing instruction for an orchestrator

Give this to the orchestrator in its system prompt or first turn:

> You orchestrate other Claude Code agents over claudiverse. First call `cv_subscribe` with the agents you manage (for example `["lorem-w1","lorem-w2"]`). You will be pinged, as a turn injected into you and prefixed `[claudiverse]`, whenever a watched agent finishes a turn or asks a question. Never poll (`cv_pending` is for debugging only); handle each ping when it arrives. To handle one, use `cv_questions`, `cv_last` (small n) or `cv_tail` (small limit) to see what happened, then act with `cv_send` (relay or instruct) or `cv_answer` / `cv_decline` (resolve a question). Use `cv_ack` for anything you handled without acting on it. Keep reads small; never request full logs.

The orchestrator's loop is then: get pinged, inspect in bounded amounts, act or ack, go idle, get pinged.

### Errors

Most tools return a text result, including their own error messages (for example `error: …` or `NOT requested (HTTP …)`). Where a `cv-core` call throws instead, the MCP SDK returns an error result for that call; the exact text is not set by `cv-mcp`.

## Failure modes and troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| `error: can't tell which seat this is yet — …` | No `CLAUDIVERSE_SELF` or `CLAUDIVERSE_TITLE`, and the server has no seat registered for this Claude session yet. | Retry shortly: `cv-mcp` asks `whoami` every 2 s for the first 30 attempts, then every 30 s. If it never resolves, check the token and URL, and that the seat's mod has registered. |
| `SELF` is never resolved and nothing is retried | Neither a title variable nor `CLAUDE_CODE_SESSION_ID` is set, so there is nothing to look up. | Set `CLAUDIVERSE_SELF` or `CLAUDIVERSE_TITLE` in the MCP config. |
| `cv_report` is missing on an orchestrator | Expected. `report` is registered only for `worker`/`delegate` (static) and disabled for role `orchestrator` (dynamic). | Use a `delegate` role if the seat must both drive and report. |
| `cv_request_human` is missing | In static mode it needs a non-worker role and `CLAUDIVERSE_NOTIFY=1`; in dynamic mode the server's `can_notify` must be true. | Set the env var, or grant notify to the seat from the apps (`POST /api/sessions/:id/access`, `level` `basic`, `notify`, `full` or null; app tokens only). A dynamic seat picks it up within a minute. |
| `cv_spawn`, `cv_stop`, `cv_ps` missing | `CLAUDIVERSE_LIFECYCLE=1` is not set, or `CLAUDIVERSE_ROLE=worker`. | Set the variable on the managing seat only. |
| Tools lack a seat's role change | Dynamic seats refresh every 60 s; static seats never refresh. | Wait a minute, or restart the seat. |
| Every call fails | `CLAUDIVERSE_TOKEN` empty or wrong, or `CLAUDIVERSE_URL` unreachable (the default is `http://localhost:4000`). | Fix the MCP config env. |

## Related pages

- [cv-mcp: seat, ping and question tools](mcp-seats.md), [cv-mcp: forum tools](mcp-forum.md), [cv-mcp: handoff tools](mcp-handoffs.md), [cv-mcp: lifecycle tools](mcp-lifecycle.md), [cv-mcp: task tools](mcp-tasks.md), [cv-mcp: ledger tools (facts and rulings)](mcp-ledger.md), [cv-mcp: knowledge-store tools](mcp-knowledge.md), [cv-mcp: submission tools](mcp-submissions.md)
- [cv-core: the shared client library](cv-core.md), [cvctl: the orchestrator CLI](cvctl.md), [cv-subs: bulk subscription management](cv-subs.md)
- [Setup guide](../../guide/README.md)
- Server: [Tool levels and paging](../server/access-and-notify.md), [Accounts, sign-up and tokens](../server/auth.md)
- Mod: [Configuration reference](../services/mod/configuration.md)
- Android: [Seat controls](https://github.com/Promises/claudiverse-apps/blob/main/docs/android/seat-controls.md)
- Mac: [Seat view](https://github.com/Promises/claudiverse-apps/blob/main/docs/mac/seat-view.md)

## Source

- `orchestrator/cv-mcp.mjs`
- `orchestrator/cv-policy.mjs`
- `orchestrator/test/policy.test.mjs`
- `orchestrator/orchestrator.mcp.json.example`
- `orchestrator/worker.mcp.json.example`
- `orchestrator/package.json`
- `orchestrator/README.md`
