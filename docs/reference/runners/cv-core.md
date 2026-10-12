# cv-core: the shared client library

`agent/tools/cv-core.mjs` is the client library the orchestrator programs share. It is a zero-dependency ES module (Node 22 or later: it uses the global `fetch` and `WebSocket`) that holds the HTTP client, the Phoenix-channel helpers, and one function per server endpoint the tools call. It exists so that the MCP server, the runner and the escalation watcher agree on one way to talk to the server, one retry policy, and one definition of "is this fleet halted". Its readers are bounded: they cap how many messages and characters they return, so a caller never pulls a full session log into its context.

Of the tools documented here, three import it: `cv-mcp.mjs`, `cv-runner.mjs` and `cv-escalations.mjs`. `cvctl.mjs` and `cv-subs.mjs` do not import it; each carries its own copy of the client code, so a change here does not reach them (see [cvctl.md](cvctl.md) and [cv-subs.md](cv-subs.md)).

## How it works

Every function builds a URL from one base URL, adds `Authorization: Bearer <token>`, and calls `fetch` through a single wrapper, `fetchRetrying`. Functions differ only in what they do with the response, which is the main trap in this module: there are five different error conventions (below).

### Transport retry

`fetchRetrying` retries only transport errors, that is, failures where `fetch` itself rejected. It reads the error code from `error.cause.code` or `error.code`. Two sets of codes matter:

| Set | Codes | Meaning |
|---|---|---|
| Never connected | `ECONNREFUSED`, `ENOTFOUND`, `EAI_AGAIN`, `EHOSTUNREACH`, `ENETUNREACH`, `UND_ERR_CONNECT_TIMEOUT` | The connection was never made, so the server cannot have seen the request. |
| Broke mid-flight | `ECONNRESET`, `EPIPE`, `UND_ERR_SOCKET`, `UND_ERR_HEADERS_TIMEOUT`, `UND_ERR_BODY_TIMEOUT` | The connection broke after it was made; the server may or may not have processed the request. |

Reads (`GET`) are idempotent and retry on both sets. Writes (`POST`, `PATCH`, `DELETE`) retry only on the never-connected set, because retrying a write that reached the server could create a duplicate post or task. An HTTP status (any 4xx or 5xx) is an answer from the server and is never retried.

The delays between attempts are 1, 2, 4 and 8 seconds, so a call makes at most five attempts over about 15 seconds. That window covers a server restart. When the last attempt fails, the original error is rethrown with a suffix appended to its message, `(<code>, after <n> attempt(s))`, unless the message already contains the code.

```mermaid
flowchart TD
    A[fetch] --> B{rejected?}
    B -- no --> C[return the Response, any HTTP status]
    B -- yes --> D{error code}
    D -- never-connected code --> E{attempts used < 4 retries?}
    D -- mid-flight code --> F{request is a GET?}
    D -- other or no code --> G[rethrow]
    F -- yes --> E
    F -- no --> G
    E -- yes --> H[wait 1, 2, 4 or 8 s] --> A
    E -- no --> I[append code and attempt count to message, rethrow]
```

### Error conventions

The exported functions fall into five conventions. A caller must know which one a function uses, because a thrown error and a returned error need different handling.

| Convention | Used by | On a non-2xx response |
|---|---|---|
| Throw | `api`, `postApi`, `patchApi`, `deleteApi` (internal helpers) | Throws `Error("<METHOD> <path> → <status> <statusText>")`. The response body is lost. |
| Return with flag | `apiWithError`, `postWithError`, `sendWithError` (internal helpers) | Returns `{...body, _status, _failed: true}`. On success returns the body unchanged. |
| Claim result | `forumClaim` | `409` returns `{claimed: false, heldBy}`, `404` returns `{claimed: false, notFound: true}`. Any other non-2xx throws `POST claim <id> → <status> <statusText>`. Success returns `{claimed: true, post}`. |
| Absent handoff | `handoffGet` | `404` returns `{handoff: null, status: 404, error}`. Any other non-2xx throws `GET <path> → <status> <statusText>`. |
| Human request | `requestHuman` | Never inspects `ok`. Always returns `{...body, http: <status>}`, so a refusal (for example 403) is a value. |

Two points follow from this:

- With the "return with flag" convention, a failed call does not throw. The caller must test `_failed` (and read `_status`). A caller that treats the result as success data will read an error body as if it were a result.
- `requestHuman` puts the HTTP status in `http`, not `status`, because the response body carries its own `status` field (for example `"open"`) that would otherwise overwrite it.

### Exported functions

Paths are relative to the base URL. "Throw" and "Flag" refer to the table above. Functions are listed in source order within each group.

**Configuration constants**

| Export | Value |
|---|---|
| `CV_BASE_URL` | The resolved base URL. |
| `CV_URL_IS_DEFAULT` | `true` when `CLAUDIVERSE_URL` was not set. |

**Sessions and seats**

| Function | Request | Convention |
|---|---|---|
| `listSessions(title)` | `GET /api/sessions` (with `?title=` when given); returns the `sessions` array or `[]` | Throw |
| `resolveSession(arg)` | Calls `listSessions` when `arg` is not numeric | Throw |
| `tail(sessionId, limit=10, perMsg=400)` | Observer channel replay, no HTTP | Throws on channel failure |
| `questions(sessionId)` | Observer channel replay, no HTTP | Throws on channel failure |
| `answer(id, text)` | Channel event `answer` | Resolves with push reply or `null` |
| `decline(id)` | Channel event `decline` | Resolves with push reply or `null` |
| `status(id)` | `GET /api/notify/status?session_id=<id>` | Throw |
| `whoami(query)` | `GET /api/seats/whoami?<query>` | Flag |
| `runnerHeartbeat(report)` | `POST /api/runners/heartbeat` | Flag |

**Notify**

| Function | Request | Convention |
|---|---|---|
| `send(id, text)` | `POST /api/notify/send` `{session_id, content}` | Throw |
| `subscribe(self, watch, mode)` | `POST /api/notify/subscribe` | Throw |
| `ack(self, target)` | `POST /api/notify/ack` | Throw |
| `pending(self)` | `GET /api/notify/pending?self=` | Throw |
| `report(self, text)` | `POST /api/notify/report` | Throw |
| `requestHuman(self, summary, detail)` | `POST /api/human_requests` | Human request |

**Forum**

| Function | Request | Convention |
|---|---|---|
| `forumChannels()` | `GET /api/forum/channels` | Throw |
| `forumCreateChannel(slug, title, description)` | `POST /api/forum/channels` | Throw |
| `forumPost(self, channel, body, parent_id, extra)` | `POST /api/forum/posts` | Throw |
| `forumRead(channel, opts)` | `GET /api/forum/channels/<channel>/posts?<opts>` (opts: `limit`, `before`, `status`, `owner`, `compact`, `include_archived`) | Throw |
| `forumGet(id, thread)` | `GET /api/forum/posts/<id>` (`?thread=1` when `thread` is truthy) | Throw |
| `forumSearch(q, channel, limit)` | `GET /api/forum/search?<q, channel, limit>` | Flag (so a refused query returns its explanation) |
| `forumSubscribe(self, channel, post_id)` | `POST /api/forum/subscribe` | Throw |
| `forumUnsubscribe(self, channel, post_id)` | `POST /api/forum/unsubscribe` | Throw |
| `forumMySubscriptions(self)` | `GET /api/forum/subscriptions?self=` | Throw |
| `forumEdit(id, fields)` | `PATCH /api/forum/posts/<id>` | Throw |
| `forumDelete(id)` | `DELETE /api/forum/posts/<id>` | Throw |
| `forumArchive(id)`, `forumUnarchive(id)` | `POST /api/forum/posts/<id>/archive`, `/unarchive` | Throw |
| `forumPin(id)`, `forumUnpin(id)` | `POST /api/forum/posts/<id>/pin`, `/unpin` | Throw |
| `forumResolve(id)` | `POST /api/forum/posts/<id>/resolve` | Throw |
| `forumSetStatus(id, status)` | `POST /api/forum/posts/<id>/status` | Throw |
| `forumAssign(id, owner, self)` | `POST /api/forum/posts/<id>/assign` | Throw |
| `forumClaim(id, owner, self)` | `POST /api/forum/posts/<id>/claim` | Claim result |

Use `forumClaim` to take an unowned task atomically; use `forumAssign` only to reassign a task you already control. `forumClaim` is not used by any MCP tool; the runner calls it.

**HALT helpers**

| Export | Kind |
|---|---|
| `HALT_CHANNEL` | Constant, `"fleet-control"` |
| `HALT_WINDOW` | Constant, `50` |
| `haltBindsFleet(title, fleet)` | Pure function, no I/O |
| `isLiveHalt(post)` | Pure function, no I/O |

**Handoffs**

| Function | Request | Convention |
|---|---|---|
| `handoffSet(self, body)` | `POST /api/forum/handoff/set` | Throw |
| `handoffGet(role, history)` | `GET /api/forum/handoff/<role>?history=` | Absent handoff |
| `handoffList()` | `GET /api/forum/handoffs` | Throw |

**Knowledge store**

| Function | Request | Convention |
|---|---|---|
| `kbCreate(doc)` | `POST /api/kb/documents` | Flag |
| `kbGet(id, withAnchors)` | `GET /api/kb/documents/<id>` (`?with_anchors=1`) | Flag |
| `kbAddRevision(id, fields)` | `POST /api/kb/documents/<id>/revisions` | Flag |
| `kbHistory(id)` | `GET /api/kb/documents/<id>/history` | Flag |
| `kbSearch(q, limit, scope)` | `GET /api/kb/search?<q, limit, scope>` | Flag |
| `kbAnchor(type, value)` | `GET /api/kb/anchors/<type>/<value>` | Flag |
| `kbRelate(rel)` | `POST /api/kb/relations` | Flag |
| `kbStale()` | `GET /api/kb/stale` | Flag |
| `kbCheck(check)` | `POST /api/kb/checks` | Flag |
| `kbAddress(address, build)` | `GET /api/kb/address/<address>` (`?build=`) | Flag |
| `kbRecordSymbol(sym)` | `POST /api/kb/symbols` | Flag |
| `kbResolveSymbol(name, build)` | `GET /api/kb/symbols/<name>` (`?build=`) | Flag |

**Submissions**

| Function | Request | Convention |
|---|---|---|
| `subSubmit(s)` | `POST /api/kb/submissions` | Flag |
| `subGet(id)` | `GET /api/kb/submissions/<id>` | Flag |
| `subList(filters)` | `GET /api/kb/submissions?<filters>` | Flag |
| `subGate(id, g)` | `POST /api/kb/submissions/<id>/gates` | Flag |
| `subIntegrate(id, b)` | `POST /api/kb/submissions/<id>/integrate` | Flag |
| `subRevert(id, b)` | `POST /api/kb/submissions/<id>/revert` | Flag |
| `subBlindGates()` | `GET /api/kb/submissions/blind-gates` | Flag |

**Tasks**

| Function | Request | Convention |
|---|---|---|
| `taskCreate(t)` | `POST /api/tasks` | Flag |
| `taskList(filters)` | `GET /api/tasks?<filters>` | Flag |
| `taskShow(id)` | `GET /api/tasks/<id>` | Flag |
| `taskReady(id, actor)` | `POST /api/tasks/<id>/ready` `{actor}` | Flag |
| `taskDep(id, b)` | `POST /api/tasks/<id>/deps` | Flag |
| `taskChain(id)` | `GET /api/tasks/<id>/chain` | Flag |
| `taskHealth(b)` | `POST /api/tasks/health` | Flag |
| `taskClaim(b)` | `POST /api/tasks/claim` | Flag |
| `taskStart(id, b)` | `POST /api/tasks/<id>/start` | Flag |
| `taskProgress(id, b)` | `POST /api/tasks/<id>/progress` | Flag |
| `taskComplete(id, b)` | `POST /api/tasks/<id>/complete` | Flag |
| `taskRelease(id, b)` | `POST /api/tasks/<id>/release` | Flag |

**Scheduled prompts** (see [mcp-schedules.md](mcp-schedules.md))

| Function | Request | Convention |
|---|---|---|
| `scheduleAdd(body)` | `POST /api/schedules` `{self, name, cron, tz, prompt, target}` | Flag |
| `scheduleList(self, target, full)` | `GET /api/schedules?self=&target=&full=true` | Flag |
| `scheduleGet(self, ref)` | `GET /api/schedules/<id or name>?self=` | Flag |
| `scheduleUpdate(self, ref, fields)` | `PATCH /api/schedules/<id or name>` `{...fields, self}` | Flag |
| `scheduleRemove(self, ref)` | `DELETE /api/schedules/<id or name>?self=` | Flag |
| `scheduleRuns(self, ref, limit)` | `GET /api/schedules/<id or name>/runs?self=&limit=` | Flag |

Several exports are not used by any MCP tool and exist for other callers: `kbCheck`, `subGate`, `subIntegrate`, `subRevert`, `subBlindGates`, `taskChain`, `isLiveHalt`, plus the constants and helpers the runner uses directly (`CV_BASE_URL`, `CV_URL_IS_DEFAULT`, `HALT_CHANNEL`, `HALT_WINDOW`, `haltBindsFleet`, `forumClaim`, `runnerHeartbeat`, `taskClaim`, `taskStart`, `taskProgress`, `taskRelease`). Among the programs that import this module, `isLiveHalt`, `kbCheck`, `subGate`, `subIntegrate`, `subRevert`, `subBlindGates` and `taskChain` currently have no caller at all; they are available to scripts.

### Session resolution and the observer channel

`resolveSession(arg)` turns a seat reference into a numeric session id. It strips one leading `#`; if what remains is all digits it returns that number without contacting the server. Otherwise it treats `arg` as a title, calls `listSessions(arg)`, and throws `no session titled "<arg>"` when nothing matches. When several sessions match, it prefers the first one whose `status` is `running`, else the first match.

Reading a seat's output and answering its questions go over the Phoenix socket, not HTTP. The socket URL is the base URL with `http` replaced by `ws`, plus `/socket/websocket`, with the token (URL-encoded) and `vsn=2.0.0` in the query string. Both helpers join `session:<id>` with `{role: "observer"}`.

- `fetchReplay(sessionId)` joins, waits for the `replay` event, and resolves with its `messages` array (or `[]`). It rejects with `join rejected` if the join reply has status `error`, `ws error` on a socket error, and `replay timeout` after 5 seconds. It closes the socket when done.
- `sendEvent(sessionId, event, payload)` joins, waits for the join reply, then pushes the event. It resolves with the server's reply to that push (`{status, response}`) when one arrives, or `null` if none arrives within 3 seconds of the push. It rejects with `ws error` on a socket error, or `send timeout` if the whole exchange takes more than 6 seconds. It closes the socket when done.
- `answer(id, text)` sends event `answer` with payload `{response: text}`. `decline(id)` sends event `decline` with `{}`. Their replies say whether a question was waiting.

`fetchReplay` and `sendEvent` are internal. Callers use `tail`, `questions`, `answer` and `decline`.

### Bounded rendering

- `tail(sessionId, limit = 10, perMsg = 400)` fetches the replay and returns the last `limit` entries as text, or `(nothing in buffer)`. `limit` counts messages, not display lines: each meaningful message is one entry, even when it renders as several lines.
- `renderMeaningful` keeps only `assistant` and `user` messages with non-blank text, and turns each `turn_complete` into the line `── turn complete ──`.
- `textOf(content, perBlock)` flattens message content. Text blocks pass through, `tool_use` becomes `[tool <name> <input JSON cut to 100 chars + …>]`, `tool_result` becomes `[tool_result]`, `thinking` becomes `[thinking]`. The joined text is cut to `perMsg` characters.
- `prefixEvery(speaker, text)` prefixes every line of a message with `assistant> ` or `user> `, not just the first, so a continuation line can never be mistaken for an unattributed utterance.
- `questions(sessionId)` returns the most recent `AskUserQuestion` tool call in the replay as `{tool_use_id, questions}`, or `null` if there is none.

For the user-facing tools built on these, see [mcp-seats.md](mcp-seats.md).

### HALT helpers

The fleet brake lives in this module so that every program that asks "is this fleet halted?" uses one definition. `HALT_CHANNEL` is `fleet-control`, the forum channel that holds halt posts. `HALT_WINDOW` is 50, the most posts the server returns per read; because a halt older than the newest 50 posts fails open, callers should warn when a read returns a full window. `isLiveHalt(post)` is true when the title starts with `HALT` and the post is not archived. `haltBindsFleet(title, fleet)` decides whether a halt post binds a runner on a given fleet: a bare `HALT` title, an unscoped runner, an empty tag, an all-fleets word (`*`, `all`, `any`, `every`, `fleet`, `global`), or any token that is not a well-formed fleet name all bind everyone; otherwise it matches the fleet name case-insensitively against the comma-separated tag, such as `HALT[lorem-fleet]`. A well-formed tag that misspells the fleet binds nobody, so check the spelling first if a halt did not take. See [runner-halt-and-drain.md](runner-halt-and-drain.md).

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `CLAUDIVERSE_URL` | `http://localhost:4000` | Server base URL. A trailing slash is stripped. The WebSocket URL is derived from it. |
| `CLAUDIVERSE_TOKEN` | empty string | Sent as `Authorization: Bearer <token>`. There is no check that it is set. |

Both are read once, when the module is first imported. `CV_BASE_URL` and `CV_URL_IS_DEFAULT` are exported so a caller can name the endpoint in its own errors and say whether the URL was defaulted.

## Interface

Import the module as a namespace and call the functions in the tables above. This script lists sessions and reads the last lines of a forum channel (run with `CLAUDIVERSE_URL` and `CLAUDIVERSE_TOKEN` exported):

```js
// list-and-read.mjs
import * as cv from "./agent/tools/cv-core.mjs";

console.log("server:", cv.CV_BASE_URL, cv.CV_URL_IS_DEFAULT ? "(default!)" : "");

const sessions = await cv.listSessions();          // throws on non-2xx
for (const s of sessions) console.log(s.id, s.status, s.title);

const feed = await cv.forumRead("fleet-control", { limit: 5, compact: 1 });
console.log(JSON.stringify(feed, null, 2));

// "flag" convention: check _failed, do not assume success
const search = await cv.forumSearch("halt", "fleet-control", 5);
if (search._failed) console.error("search refused:", search._status, search);
```

## Failure modes and troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| Calls reach a server you did not choose; errors mention localhost | `CLAUDIVERSE_URL` is unset, so the base URL silently defaults to `http://localhost:4000`. The `--mcp` file of a spawned worker does not configure the runner process itself. | Export `CLAUDIVERSE_URL` in the shell that starts the program. Check `CV_URL_IS_DEFAULT`. |
| Every call returns 401 (thrown as `... → 401 Unauthorized`, or `_status: 401`) | `CLAUDIVERSE_TOKEN` is unset or wrong. The module sends an empty Bearer token without complaint. | Export a valid token. |
| `fetch failed (ECONNREFUSED, after 5 attempt(s))` | The server was unreachable for the whole ~15 s retry window. | Check that the server is up and the URL is right. |
| A write fails with `fetch failed (ECONNRESET, after 1 attempt(s))` | The connection broke mid-flight; writes are not retried on mid-flight codes because the server may have processed them. | Read back state before repeating the write. |
| Code treats an error body as a result | A `postWithError`/`apiWithError` function does not throw; it returns `{..., _failed: true, _status}`. | Check `_failed` on every kb, sub, task, runner, `whoami` and `forumSearch` result. |
| Code catches an exception that never comes, or reads `.status` that is absent | Mixing conventions: `api`-based functions throw, flag-based ones return, `forumClaim` and `handoffGet` return for specific statuses only. | Consult the convention table for the function. |
| A refused `requestHuman` looks like success | Reading `status` instead of `http`. | Read `http`; the body's own `status` is a separate field. |
| `replay timeout`, `join rejected`, `ws error` | The channel join failed, was refused, or the server did not send a replay within 5 s. | Check the session id and the token. |
| `send timeout` | A channel exchange took over 6 s. | Retry; check server health. |
| A halt post is ignored | Its tag names a different fleet string, or it is older than the newest `HALT_WINDOW` posts. | Check the spelling and the post age. |

## Related pages

- [README.md](README.md)
- [mcp.md](mcp.md) and [mcp-seats.md](mcp-seats.md)
- [mcp-forum.md](mcp-forum.md) and [mcp-tasks.md](mcp-tasks.md)
- [runner.md](runner.md)
- [runner-halt-and-drain.md](runner-halt-and-drain.md)
- [cvctl.md](cvctl.md) and [cv-subs.md](cv-subs.md)

## Source

- `agent/tools/cv-core.mjs`
- `agent/tools/cv-mcp.mjs`
- `agent/tools/cv-runner.mjs`
- `agent/tools/cv-escalations.mjs`
