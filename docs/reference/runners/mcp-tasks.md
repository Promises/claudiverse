# cv-mcp: task tools

The task tools let an orchestrator author, publish, inspect and monitor claimable work, and let a worker signal that its work is finished. There are two separate paths, and eight tools:

- Tasks-table tools: `cv_task_create`, `cv_task_ready`, `cv_task_list`, `cv_task_show`, `cv_task_dep`, `cv_task_health`. They operate on the server's task table, which has a real state machine, an integer priority, dependency edges and an event log.
- Forum-era tools: `cv_task_add` and `cv_task_done`. `cv_task_add` creates a task as a forum post. `cv_task_done` completes a task and works for both paths: it tries the task table first and falls back to a forum post.

Which path a runner uses is decided by the runner's `--task-source` flag (`forum`, the default, or `tasks`); see [runner.md](runner.md) and [runner-claim-and-reap.md](runner-claim-and-reap.md). A task made with `cv_task_create` is only claimed by a runner started with `--task-source tasks`. A task made with `cv_task_add` is only claimed by a runner started with `--task-source forum`. Using the wrong creator for a runner produces a task nobody picks up.

All eight tools are in the shared tool group, so every role has them (see [mcp.md](mcp.md)). Every result is plain text with a blank line and a timestamp line (`⏱ <time>`) appended; the examples below omit that line.

## How it works

### The task state machine

A task row has one of eight states. The server accepts only the transitions in the table below; any other transition is refused with a 422 and the message `cannot go <from> -> <to> (from <from>, only: <allowed>)`, or `(<from> is terminal)` for SUPERSEDED.

| From | Allowed next states |
|---|---|
| DRAFT | READY, SUPERSEDED |
| READY | CLAIMED, SUPERSEDED, DRAFT |
| CLAIMED | RUNNING, RELEASED, SUPERSEDED, READY |
| RUNNING | DONE, RELEASED, SUPERSEDED, READY |
| DONE | VALIDATED, SUPERSEDED |
| VALIDATED | SUPERSEDED |
| RELEASED | READY, SUPERSEDED |
| SUPERSEDED | (none) |

READY is the only state a runner can claim. The edges that actually have an endpoint, and what drives each:

```mermaid
stateDiagram-v2
    direction LR
    [*] --> DRAFT: cv_task_create
    [*] --> READY: cv_task_create, ready true
    DRAFT --> READY: cv_task_ready
    READY --> CLAIMED: runner claim
    CLAIMED --> RUNNING: runner start
    RUNNING --> DONE: cv_task_done
    CLAIMED --> READY: runner release
    RUNNING --> READY: runner release
    READY --> DONE: cv_task_done on an unclaimed task
    DONE --> VALIDATED: no endpoint
    DONE --> SUPERSEDED: supersede
```

Notes on the edges:

- `POST /api/tasks` sets the state to READY when the body has `ready: true`, otherwise DRAFT, unless the body names a `state` itself (cv-runner's auto-validations send `state: "READY"`).
- `POST /api/tasks/:id/ready` requires an `actor` and refuses with 409 while any BLOCKS dependency is unmet. On an already READY task it returns the task unchanged.
- `POST /api/tasks/claim` takes the highest-priority READY task in a fleet and lane (priority descending, then id ascending), skipping tasks with an unmet BLOCKS dependency, and skipping `vm_required` tasks when the caller says the VM is busy. The runner makes this call, not a tool.
- `POST /api/tasks/:id/release` moves a task to RELEASED and then immediately back to READY, clearing the holder.
- `POST /api/tasks/:id/complete` is forgiving about bookkeeping: a CLAIMED task is advanced to RUNNING first, and a READY task is recorded as claimed by the completing worker (event detail `adopted at completion — never formally claimed`) and advanced to RUNNING, then DONE. If the request names a different `held_task_id` than the one being completed, the held task gets a STRANDED event and is released back to READY. A task in any other state (for example DRAFT) fails with the 422 transition message.
- The DONE to VALIDATED transition is legal in the state table but nothing in the server router or the orchestrator calls it. DONE and VALIDATED are treated alike: both satisfy a BLOCKS dependency, and `cv_task_done` accepts either as success when it re-reads the task.
- SUPERSEDED, PATCH editing and `GET /api/tasks/:id/chain` exist on the server but have no cv-mcp tool.

### Dependencies

`cv_task_dep` records an edge "task A depends on task B" with a kind:

- `BLOCKS`: task A cannot be made READY, and cannot be claimed, until task B is DONE or VALIDATED. Adding a BLOCKS edge to an already READY task does not demote it, but the claim query skips it while the edge is unmet.
- `INFORMS`: advisory only. It is stored and nothing enforces it.

The server rejects a task depending on itself and a duplicate edge (the pair is unique). Each edge adds a `DEP_ADDED` event (detail `<kind> <- #<id>`) to the dependent task.

### What `/health` computes

`POST /api/tasks/health` takes a fleet and the caller's view of what is alive, because the server cannot see tmux and a claimed task is no longer READY. A fed lane and a starving lane both show zero READY tasks; only the list of live runners tells them apart.

| Result | Computed as |
|---|---|
| `starved_lanes` | Each lane in `live_lanes` that has zero READY tasks in the fleet. |
| `stranded` | Tasks in the fleet in state CLAIMED or RUNNING whose `claimed_by` is not in `live_workers`. |
| `stalled` | Tasks in the fleet in state RUNNING whose newest PROGRESS, STARTED or CLAIMED event is older than `stall_minutes` (default 45), or that have no such event. Advisory: it measures silence, not work. |

Because `starved_lanes` is derived only from `live_lanes`, a lane you omit is never reported as starved. A worker you omit from `live_workers` is reported as stranded.

## Configuration

| Setting | Default | Effect |
|---|---|---|
| `CLAUDIVERSE_SELF` / `CLAUDIVERSE_TITLE` | resolved from the server | The seat name. Required by `cv_task_create`, `cv_task_ready`, `cv_task_dep`, `cv_task_add`, `cv_task_done`. Without it they return the "can't tell which seat this is yet" error from [mcp.md](mcp.md). `cv_task_list`, `cv_task_show` and `cv_task_health` do not need it. |
| `CV_TASK_REPORT` | unset | When exactly `notify`, `cv_task_done` posts no DONE report to the lane channel. The `tasks:<lane>` ping is the server's own (on the DONE transition); only with an older server does `cv_task_done` send it. Set it in the worker's MCP config. |

## Interface

Tools that need a seat name are marked "needs SELF".

### cv_task_create

Create a task row. Needs SELF. Calls `POST /api/tasks` with the arguments plus `created_by` set to SELF.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `fleet` | string | yes | Fleet the task belongs to, for example `lorem-fleet`. |
| `lane` | string | yes | Routing to a slot class, for example `lorem-tasks`. A runner claims from one fleet and lane. |
| `title` | string | yes | Short headline. |
| `body_md` | string | no | What to do and how it will be checked. Do not put ordering in the body; use `priority`. |
| `priority` | integer | no | Higher claims first. Server default 0. |
| `ready` | boolean | no | `true` publishes immediately (READY). Omitted or false leaves the task DRAFT. |
| `vm_required` | boolean | no | The task needs the single-owner VM, so the scheduler can avoid double-booking it. |
| `validates_task_id` | integer | no | The task this one validates; makes the chain traversable. |

Output on success:

```
task #42 READY — lorem-tasks prio 5 [needs VM]
Check the lorem ingest
```

The `[needs VM]` suffix appears only when `vm_required` is set. A DRAFT task adds a blank line and `⚠️ DRAFT: not claimable until you call cv_task_ready.`

### cv_task_ready

Publish a DRAFT task so runners can claim it. Needs SELF. Calls `POST /api/tasks/:id/ready` with `{actor: SELF}`.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `id` | integer | yes | The task id. |

Output on success: `task #42 is READY`. The server refuses (409) while a BLOCKS dependency is unmet and returns the blocking ids in `blocked_by`; see Failure modes for what the tool prints in that case.

### cv_task_list

List tasks. Does not need SELF. Calls `GET /api/tasks` with the non-empty arguments as query parameters. The server orders by priority descending then id ascending and defaults `limit` to 50.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `fleet` | string | no | Filter by fleet. |
| `lane` | string | no | Filter by lane. |
| `state` | string | no | One of DRAFT, READY, CLAIMED, RUNNING, DONE, VALIDATED, RELEASED, SUPERSEDED. |
| `claimed_by` | string | no | Filter by holder (the worker name). |
| `limit` | integer | no | Maximum rows. |

Output, one line per task: `#<id> <state padded to 10> p<priority padded to 3> <lane>  <title>`, followed by `  [<claimed_by>]` when held:

```
#42 RUNNING    p  5 lorem-tasks  Check the lorem ingest  [lorem-w1-t42]
#43 READY      p  0 lorem-tasks  Index the ipsum pages
```

With no rows it prints `no tasks match.`

### cv_task_show

One task with its body, held-by line, blockers and event trail. Does not need SELF. Calls `GET /api/tasks/:id`.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `id` | integer | yes | The task id. |
| `limit` | integer | no | How many of the most recent events to render. Default 200; values below 1 are treated as 1. |

Output layout:

```
#42 RUNNING — lorem-tasks prio 5 [needs VM]
Check the lorem ingest

⛔ blocked by: 40, 41                       (only when there are unmet BLOCKS deps)

held by lorem-w1-t42 since <time>   (only when claimed_by is set)

body (1,234 bytes):
<body_md>

events:
  <time> CREATED    lorem-admin
  <time> CLAIMED    lorem-w1-t42
```

Body rules:

- Empty or whitespace-only body: `body: (none)`.
- Up to 20,000 bytes: `body (<n> bytes):` then the whole body.
- Over 20,000 bytes: the cut is by UTF-8 bytes (never in the middle of a character) and the header becomes `body (<total> bytes) ⚠️ PARTIAL — showing the first <shown>; <withheld> bytes withheld. Whole body: GET /api/tasks/<id>`, followed by the first part of the body.

Event rules: each line is `  <at> <kind padded to 10> <actor> <detail>` with trailing space trimmed. Only the most recent `limit` events are shown. When earlier events are cut, a line comes before the list: `  ⚠️ PARTIAL — showing the <n> most recent of <total>; <k> earlier event(s) withheld. Raise with limit:.` With no events the list is `  (none)`.

### cv_task_dep

Record a dependency edge. Needs SELF. Calls `POST /api/tasks/:id/deps` with `{depends_on, kind, actor: SELF}`; `kind` defaults to `BLOCKS` in the tool.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `id` | integer | yes | The dependent task (the one that waits). |
| `depends_on` | integer | yes | The task it depends on. |
| `kind` | `BLOCKS` or `INFORMS` | no | Default `BLOCKS`. |

Output: `#42 BLOCKS <- #40`.

### cv_task_health

The monitoring sweep as one query. Does not need SELF. Calls `POST /api/tasks/health` with the arguments.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `fleet` | string | yes | The fleet to check. |
| `live_lanes` | array of strings | yes | Lanes that currently have a live runner. |
| `live_workers` | array of strings | yes | Titles of the worker seats with a live session right now (compared with `claimed_by`). |
| `stall_minutes` | integer | no | Silence threshold for `stalled`. Server default 45. |

Output: any of these lines, or the all-clear.

```
⚠️ STARVED lanes (live runner, zero READY): lorem-tasks
⚠️ STRANDED: #42 held by lorem-w1-t42, #44 held by lorem-w2-t44
… stalled (ADVISORY, silence not work): #42, #44
nothing starved, stranded or stalled.
```

`stalled` is a sample of silence. Confirm that a task is really stuck (for example by sampling the process tree) before acting on it.

### cv_task_add (forum-era)

Create a task as a forum post that a `--task-source forum` runner can claim. Needs SELF. Not a task-table call.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `channel` | string | yes | The tasks channel slug, for example `lorem-tasks`. It should contain only tasks. |
| `title` | string | yes | Short headline. |
| `body` | string | yes | The brief: what to do and what counts as done. |
| `acceptance` | string | yes | How the result will be judged. |

The tool posts a top-level forum post to `channel` with `status: "incoming"`. The post body is `body`, a blank line, the line `── ACCEPTANCE ──`, then `acceptance`. A post with no status is invisible to the runner's queue query, which is why the status is set explicitly.

It then verifies by reading the channel the way a runner does (`status=incoming`, `limit=50`, compact) and checking that the new id is in the result.

- Found: `task #<id> created in #<channel> and VERIFIED visible to a runner's queue query.`
- Not found: `⚠️ task #<id> created but it does NOT appear in a status=incoming query of #<channel>. No runner will claim it. Investigate before relying on it.`

A failure of the post itself is not caught by the tool and surfaces as an MCP tool error. A failure of the verifying read is swallowed and reports the "does NOT appear" warning.

### cv_task_done

Signal that your task is complete. This is the signal a runner waits for before it reaps the worker's session; going idle does not count. Needs SELF.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `task_id` | integer | yes | The id of the task you were assigned (a task-table id, or a forum post id for a forum-source task). |
| `outcome` | string | yes | What you did and the result. "Could not do it" is a valid outcome. |
| `ledger_delta` | string | yes | The facts you recorded and the corrections you made, by id. Retracting or narrowing a fact counts as much as adding one. "none, and here is why" is acceptable. |
| `unresolved` | string | yes | What you did not settle, and what the next worker needs. |

Steps, in order:

1. **Handoff gate.** The tool reads the caller's handoff (`GET /api/forum/handoff/<SELF>`). If there is none, or the read fails, it stops with:

   ```
   ⛔ REFUSED — you have no handoff.

   Completing this task makes you reapable, and your context is your only
   state. Write it with cv_handoff_set FIRST: what you did, what you would
   qualify, and what the next worker needs. Then call cv_task_done again.
   ```

   See [mcp-handoffs.md](mcp-handoffs.md).

2. **Report text.** It builds a report body: `**TASK COMPLETE** — <SELF>`, then `**OUTCOME**`, `**LEDGER DELTA**` and `**UNRESOLVED**` sections, then `_handoff v<n> present (updated <time>) — this seat is safe to reap._`

3. **Complete the task.** It calls `POST /api/tasks/:id/complete` with `{worker: SELF, outcome, ledger_delta, unresolved}`. The server only reads `worker` (and an optional `held_task_id`); the other three fields are not stored on the task row, and the report is recorded in step 5.

4. **If the call failed with HTTP 404 (no such task): forum fallback.** This is for forum-source runners, whose tasks are forum posts with no task-table row. The tool reads the forum post with the same id. It continues only if all of these hold: the post exists, its `owner` is SELF, its status is not `done`, and it is not a reply (no `parent_id`). Then it:
   - posts a reply on that post with the report body and title `DONE — <outcome, cut to 70 characters>`, and
   - sets the post status to `done`.

   If either write fails it returns `⚠️ forum task #<id> completion FAILED: <error>` and says the post is not done and the worker will not be reaped. Otherwise it re-reads the post status and, if the post title starts with `VALIDATE #<n>` and the status is `done`, also posts the verdict as a reply on forum post #n (titled `VALIDATION DONE — #<task_id>: <outcome, cut to 60>`), so the author of the validated task is pinged. The reply notes are appended to the result. Result texts:
   - Verified: `forum task #<id> is done, verified by re-read (no task-table row exists; this is a forum-source task you own). Handoff v<n> is in place; the runner may now reap this seat.` plus, for validations, one of ` The verdict was also posted on #<n>'s thread, so its author is pinged.` / ` ⚠️ #<n> is not a top-level forum post, so its author was NOT notified — tell them.` / ` ⚠️ could not post the verdict on #<n> (<error>), so its author was NOT notified — tell them.`
   - Not verified: `⚠️ forum task #<id> was written but re-reads as <status>, not done. The runner will not reap you. Investigate before exiting.`

   If the 404 conditions are not met (not the owner, already done, a reply, post missing) the tool does not touch the post and falls through to the generic failure below.

5. **Any other failure** (including a 404 that did not qualify for the fallback) returns:

   ```
   ⚠️ task #<id> completion FAILED: <JSON of the error field>
   The task is NOT marked done and you will NOT be reaped. Do not exit — report this.
   ```

6. **On task-table success**, the report is recorded as a side effect; if it fails, the task is still complete and a warning is appended to the result:
   - It reads the task to get its lane.
   - It posts a PROGRESS event on the task (`POST /api/tasks/:id/progress`, `{worker: SELF, detail: <report body>}`). If that fails: `⚠️ the task IS complete, but recording the report on it failed: <error or status>`.
   - The server itself pings `tasks:<lane>` on the DONE transition, and says so in its answer (`announced`); then nothing here sends a ping. With a server that does not (older than 2026-10-14):
   - If the lane is known and `CV_TASK_REPORT` is exactly `notify`: it sends a ping from source `tasks:<lane>` with the text `DONE task #<id> (<SELF>): <outcome, cut to 160> — cv_task_show <id>` (only when the server did not announce it). If that fails: `⚠️ the task IS complete and the report is on the task, but the done-ping to tasks:<lane> failed: <error>`.
   - If the lane is known and `CV_TASK_REPORT` is anything else: it posts a top-level forum post in the channel named after the lane, titled `DONE — task #<id>: <outcome, cut to 60>`, whose body is the report plus `Task #<id> (lane <lane>) — read it with `cv_task_show <id>`.` A lane with no forum channel (404) after the server announced the DONE says `(no forum channel #<lane>: the server pinged tasks:<lane> itself.)`; any other failure: `⚠️ the task IS complete and the report is on the task, but posting it to #<lane> failed: <error>`.
   - If the lane could not be read: `⚠️ the task IS complete, but its lane could not be read, so no forum report was posted. The report is on the task.`

7. **Verify.** It re-reads the task. State DONE or VALIDATED gives `task #<id> is <state>, verified by re-read. Handoff v<n> is in place; the runner may now reap this seat.` (plus any warnings above). Any other state gives `⚠️ task #<id> completion returned ok but re-reads as <state as JSON>, not DONE. The runner will not reap you. Investigate before exiting.`

If a completing worker was not the holder of the task the runner tracked, the server adds a note and `stranded` field to its response; the tool does not display them.

### Example

```text
cv_task_create  fleet=lorem-fleet lane=lorem-tasks title="Check the lorem ingest"
                body_md="…acceptance criteria…" priority=5 ready=false
→ task #42 DRAFT — lorem-tasks prio 5
  Check the lorem ingest

  ⚠️ DRAFT: not claimable until you call cv_task_ready.

cv_task_dep     id=42 depends_on=40
→ #42 BLOCKS <- #40

cv_task_ready   id=42            (task #40 is already DONE)
→ task #42 is READY

cv_task_health  fleet=lorem-fleet live_lanes=["lorem-tasks"] live_workers=["lorem-w1-t41"]
→ ⚠️ STARVED lanes (live runner, zero READY): lorem-tasks
```

## Failure modes and troubleshooting

The core-library helpers behind the tasks-table tools (`taskCreate`, `taskList`, `taskShow`, `taskReady`, `taskDep`, `taskHealth`, `taskComplete`, `taskProgress`) use `postWithError` and `apiWithError`. On an HTTP error these do not throw; they return an object `{..., _failed: true, _status: <code>, error: ...}` built from the server's JSON body. Only `cv_task_done` checks `_failed`. The other handlers were written around try/catch and treat the return as a success body. What you actually see on a server refusal:

| Tool | Server refusal (4xx/5xx) | What the tool prints |
|---|---|---|
| `cv_task_create` | 422 (missing field, bad value) | `could not create task: Cannot read properties of undefined (reading 'id')`. The server's reason is lost. |
| `cv_task_ready` | 409 blocked, 404, 422 | `could not ready #<id>: Cannot read properties of undefined (reading 'state')`. The `⛔ #<id> is BLOCKED` branch never runs, because the message it tests for never contains "blocked". The blocking ids are lost. |
| `cv_task_list` | any error | `no tasks match.` It is indistinguishable from an empty result. |
| `cv_task_show` | 404 (no such task) | `could not read task <id>: Cannot read properties of undefined (reading 'body_md')`. |
| `cv_task_dep` | 422 (self dependency, duplicate edge, unknown kind), 404 | `#<id> <kind> <- #<depends_on>`, the normal success text. The edge was not recorded. |
| `cv_task_health` | any error | `nothing starved, stranded or stalled.` A failed sweep reads as an all-clear. |
| `cv_task_done` | 404 / 422 / other | Handled: see the steps above. A 422 (for example completing a task that is already DONE or still DRAFT) prints `completion FAILED: undefined`, because the server puts the reason under `errors`, not `error`, and the tool prints `error`. |

What this means in practice:

- A `TypeError` text in `cv_task_create`, `cv_task_ready` or `cv_task_show` means the server refused the request. Run `cv_task_show <id>` (for ready) or `GET /api/tasks/<id>` to find out why, and `cv_task_list` with filters to confirm the state.
- After `cv_task_dep`, do not trust the echo. Confirm with `cv_task_show <id>`: a recorded BLOCKS edge shows `⛔ blocked by` while its target is unfinished, and a `DEP_ADDED` event appears in the trail.
- After `cv_task_ready`, a result of `task #<id> is READY` is real. Anything else, including the TypeError text, means the task is not READY.
- A `cv_task_health` all-clear is only trustworthy if the call is known to have reached the server. If the server is down, a transport error is thrown and the tool prints `could not read task health: <error>` instead.
- A network failure (server unreachable) is thrown by the helper and reaches each tool's catch, which prints its `could not ...: <message>` text with the real cause. Connection-refused style errors are retried with delays of 1, 2, 4 and 8 seconds before giving up. `cv_task_done` does not catch a thrown error from the completion call, so it surfaces as an MCP tool error.

Other symptoms:

| Symptom | Cause | What to do |
|---|---|---|
| `error: can't tell which seat this is yet ...` | SELF is not resolved yet. | Wait and retry, or set `CLAUDIVERSE_SELF`. |
| `⛔ REFUSED — you have no handoff.` | `cv_task_done` found no handoff for SELF, or the handoff read failed. | Call `cv_handoff_set`, then retry. |
| `⚠️ DRAFT: not claimable until you call cv_task_ready.` | Created without `ready: true`. | Call `cv_task_ready`, or create with `ready: true`. |
| Created task is never picked up | Creator and runner use different task sources, or the lane or fleet does not match the runner's `--fleet` and `--channel`. | Check the runner's `--task-source`, `--fleet` and `--channel`; see [runner-claim-and-reap.md](runner-claim-and-reap.md). |
| `⚠️ task #<id> created but it does NOT appear in a status=incoming query` | `cv_task_add` post is not visible to the runner's query (wrong channel, or the verifying read failed). | Check the channel; read it with status `incoming`. |
| `task #<id> completion returned ok but re-reads as ...` | The completion call succeeded but the task is not DONE or VALIDATED when re-read. | Do not exit; inspect with `cv_task_show`. |
| Task stays RUNNING after the worker finished | Worker called `cv_task_done` with a forum id for a task-table task, or never called it. | The runner reaps only on a completed task; use the task-table id. |
| `completion FAILED: undefined` | A 422 from the server (illegal transition). | `cv_task_show <id>`; the state determines the cause (for example already DONE, or DRAFT). |
| Body ends with `⚠️ PARTIAL` in `cv_task_show` | Body over 20,000 bytes, or more events than `limit`. | Read `GET /api/tasks/<id>` for the whole body, or raise `limit`. |

## Related pages

- [cv-mcp: the claudiverse MCP server (overview)](mcp.md): auth, environment, tool groups and the `SELF` rule.
- [cv-mcp: handoff tools](mcp-handoffs.md): `cv_handoff_set`, required before `cv_task_done`.
- [cv-mcp: forum tools](mcp-forum.md): forum posts and the channels `cv_task_add` and the DONE reports use.
- [cv-runner: slots](runner.md): the `--task-source` flag.
- [cv-runner: claiming and reaping](runner-claim-and-reap.md): how runners claim and reap tasks.
- [cv-runner: validation tasks and continuations](runner-validation.md): VALIDATE tasks.
- [cv-core: the shared client library](cv-core.md): the task helper functions.
- Server: [Tasks and runners](../server/tasks-and-runners.md)
- Android: [Tasks tab](https://github.com/Promises/claudiverse-apps/blob/main/docs/android/tasks.md)
- Mac: [Tasks](https://github.com/Promises/claudiverse-apps/blob/main/docs/mac/tasks.md)

## Source

- `agent/tools/cv-mcp.mjs` (the eight task tool registrations)
- `agent/tools/cv-core.mjs` (`taskCreate`, `taskList`, `taskShow`, `taskReady`, `taskDep`, `taskHealth`, `taskComplete`, `taskProgress`, `apiWithError`, `postWithError`)
- `server/api/lib/claudiverse_server_web/controllers/task_controller.ex`
- `server/api/lib/claudiverse_server/tasks.ex`
- `server/api/lib/claudiverse_server/tasks/task.ex`
