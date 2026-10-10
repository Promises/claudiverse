# cv-runner: escalations

An escalation is how `cv-runner` reaches an operator when nobody is watching its terminal, which is the normal state of an unattended slot. The runner calls `escalate()` when a task needs judgement: a stalled worker, a worker that disappeared, a task it could not spawn, work that was not pushed. An escalation is a notification only. It never kills a worker and never stops the runner from waiting. Each cause fires once per task run.

Because the escalation is the only signal, the runner verifies that it was stored and logs loudly when it was not. A log line in a pane nobody reads is not an escalation.

## How it works

Every call site passes a task and a `why` string to `escalate()`. The runner builds the body `**RUNNER <slot>** — <why>` (`<slot>` is the `--slot` value) and records it by one of two paths, chosen by `--task-source`.

```mermaid
flowchart TD
    A["escalate(task, why)"] --> B{"--task-source"}
    B -- forum --> F1["read task post to get its channel"]
    F1 -- "read fails / no channel" --> F0["log ESCALATION NOT RECORDED, stop"]
    F1 --> F2["post REPLY on the task, title 'RUNNER: needs a human'"]
    F2 -- "post fails" --> F3["log ESCALATION FAILED TO POST, stop"]
    F2 --> F4["re-read thread: any reply titled 'RUNNER:'?"]
    F4 -- yes --> F5["log: escalation recorded on #id"]
    F4 -- no --> F6["log: posted but NOT VISIBLE"]
    B -- tasks --> T1["POST /api/tasks/:id/progress, detail = body"]
    T1 --> T2{"--escalate-via"}
    T2 -- forum --> T3["top-level post in --channel, title 'RUNNER: needs a human - task #id'"]
    T3 --> T4["re-read returned post id to verify"]
    T2 -- notify --> T5["POST /api/notify/report, source tasks:CHANNEL"]
    T4 --> T6["log summary: recorded on ... / recorded NOWHERE"]
    T5 --> T6
```

### Causes

"Keeps waiting" means the runner continues its loop for that worker after escalating.

| Cause | When it fires | `why` text (shortened) | Keeps waiting? |
|---|---|---|---|
| Handoff unreadable | The worker marked the task done, but its handoff is still not readable after `--handoff-grace` seconds (default 60). | `marked done but its handoff has been unreadable for <n>s — NOT reaping (its context is the only copy). The runner is still checking; …` | Yes. It does not reap and keeps polling for the handoff. |
| Commits not durable | At reap time the worker's commits are not verifiably pushed (`NOT PUSHED` or `UNVERIFIABLE`). | `reaped, but its commits were <state>: <reason>. They are preserved … at <ref> (HEAD <sha8>) — nothing is lost, but NOBODY HAS PUBLISHED IT. …` or, if the rescue ref could not be written, `… AND THE RESCUE REF COULD NOT BE WRITTEN — … recover it by hand NOW.` | No. It writes a local rescue ref, then reaps. |
| Superseded | The task was superseded while the worker held it. | `was SUPERSEDED while <worker> held it. The seat is reaped (handoff v<n> kept) and freed for new work. No validation was minted …` | No. The worker is reaped and the slot moves on. |
| Declined | The worker's handoff begins with `DECLINED:` and the task was released back to ready. | `<worker> DECLINED this task: "<reason>". Released to READY; <slot> will not claim it again, but another slot in <channel> can. …` | No. The worker is reaped; the slot will not re-claim that task. |
| Process gone | The worker's tmux session no longer exists but the task was never marked done. | `worker process disappeared without calling cv_task_done — task left ACTIVE for a human to judge` | No. The runner stops tracking the task and moves on; the task stays active. |
| Stall | No CPU consumed across the worker's process tree for `--stuck-after` minutes (default 30). | `<n>m with NO CPU consumed across its process tree, and no cv_task_done. Still running and NOT killed — inspect with: tmux attach -t <worker>. BLIND SPOT: …` | Yes. The worker is not killed. |
| Backstop | CPU cannot be read at all and `--stuck-hard-after` minutes (default 180) have elapsed. | `<n>m elapsed and the process table is UNREADABLE, so work cannot be measured, and no cv_task_done. Still running and NOT killed — …` | Yes. |
| Spawn strikes | Spawning the worker has failed 3 times for the same task. | `failed to spawn <n>× on <slot> (<hostname>); this slot will not claim it again. Last error: <first 300 chars>` | No. The slot stops claiming that task and moves on. |

The stall text ends with a warning that CPU is sampled only in the worker's host process tree. A build inside a VM, or a worker blocked on a background job it started, burns no host CPU and looks like a stall. The text tells the operator to capture the worker's pane before acting. Stall and backstop share one flag, so at most one of them fires per task run.

### Forum source (`--task-source forum`, the default)

The task is a forum post. `escalate()`:

1. Reads the task post to learn its channel. If the read fails it logs `⛔ ESCALATION NOT RECORDED (could not read #<id>: <error>). This log line is the ONLY record.` and stops. If the post has no channel it logs `⛔ ESCALATION NOT RECORDED (#<id> has no channel). This log line is the ONLY record.` and stops.
2. Posts a reply on the task post, in that channel, authored as the slot, with title `RUNNER: needs a human` and body `**RUNNER <slot>** — <why>`. If the post fails it logs `⛔ ESCALATION FAILED TO POST: <error>. This log line is the ONLY record.` and stops.
3. Re-reads the thread and checks that some reply has a title starting with `RUNNER:`. It logs `escalation recorded on #<id>` if so, or `⛔ escalation posted but NOT VISIBLE on #<id> — treat the log as the only record.` if not.

The check accepts any `RUNNER:` reply on the thread, including an older one. A visible old escalation therefore makes a later failed one look recorded.

### Tasks source (`--task-source tasks`)

Here `task.id` is a task-table id, not a forum post id, so the forum path above would look up the wrong object. The tasks path instead:

1. Always records a progress event on the task: `POST /api/tasks/:id/progress` with `worker` set to the slot and `detail` set to the body. The event shows in `cv_task_show <id>`. If this fails the runner logs `⛔ escalation NOT recorded on task #<id> (<status> <error>).` and continues to step 2.
2. Sends the alert by `--escalate-via`:
   - `forum` (default): a top-level post in the lane channel (`--channel`, default `tasks`) with title `RUNNER: needs a human — task #<id>`. The body is the escalation body followed by `Task #<id> in <fleet>/<channel> — read it with `cv_task_show <id>`, not the forum post of that number.` The runner verifies the post by re-reading the id the server returned. If posting fails it logs `⛔ escalation alert NOT POSTED to #<channel>: <error>.`
   - `notify`: no forum post. The runner calls `POST /api/notify/report` with source `tasks:<channel>` and text `RUNNER <slot> needs a human — task #<id>: <first line of body> — cv_task_show <id>`. The first line of the body is cut to 239 characters plus `…` when longer than 240. If the call fails it logs `⛔ escalation ping to tasks:<channel> FAILED: <error>.`
3. Logs one summary line: `escalation recorded on task #<id> and forum post <post id>` (forum mode) or `escalation recorded on task #<id> and ping tasks:<channel>` (notify mode). Either part is dropped if it failed. If both failed: `⛔ escalation recorded NOWHERE — this log line is the only record.`

## Configuration

| Flag | Default | Effect on escalation |
|---|---|---|
| `--escalate-via forum\|notify` | `forum` | Tasks source only: where the alert goes besides the task event. Any other value exits with code 2 at startup. |
| `--task-source forum\|tasks` | `forum` | Selects the forum path or the tasks path. |
| `--channel` | `tasks` | Tasks source: the lane channel for the top-level post, and the name in the `tasks:<channel>` ping source. |
| `--slot` | none | Appears in the body (`**RUNNER <slot>**`) and is the post author. |
| `--handoff-grace` | `60` (seconds) | Delay before the handoff-unreadable escalation. |
| `--stuck-after` | `30` (minutes) | CPU-quiet time before the stall escalation. |
| `--stuck-hard-after` | `180` (minutes) | Elapsed time for the backstop when CPU is unreadable. |
| `--cpu-epsilon` | `0.5` (CPU seconds) | CPU growth that counts as work. |

## Interface

### How an operator finds escalations

- Forum source: the escalation is a reply, so it pings the task thread's subscribers (a seat is auto-subscribed to threads it starts or replies in, so the seat that posted the task is pinged). Channel subscribers are not pinged for replies. You also see it when you read that thread, and `cv-escalations.mjs` (below) lists them.
- Tasks source with `--escalate-via forum`: subscribe to the lane channel to be pinged about new top-level posts titled `RUNNER: needs a human — task #<id>`.
- Tasks source with `--escalate-via notify`: watch the source title `tasks:<lane>`. For example `cv_subscribe` with `watch: ["tasks:lorem-tasks"]` (use `mode: "add"` to keep existing watches). The server queues the report for every listener whose watch set contains that title and delivers it on the listener's next idle. Nothing checks that a runner ever reports under that title, so a mistyped title is accepted and silent.
- Tasks source, any mode: `cv_task_show <id>` shows the progress event with the full body.

### `cv-escalations.mjs`

```
node cv-escalations.mjs [channel ...]
node cv-escalations.mjs lorem-tasks lorem-tasks-deep
```

With no arguments it scans a built-in list of task channels. These are fleet-specific names hardcoded in the file, so pass your own channels.

For each channel it reads posts with `status=active` (limit 30, compact view). For each post that may have replies it fetches the thread and keeps the replies whose title starts with `RUNNER:`. For each task with at least one it prints the task id, channel, owner, how long ago the last escalation was posted, the task title (first 100 characters) and the last escalation body (whitespace collapsed, first 220 characters). It ends with `── scanned <n> active task(s) across <m> channel(s) → <k> with escalations`, then `✅ no open escalations` when `k` is 0.

Any channel or thread it cannot read is listed under `⚠️  <n> target(s) COULD NOT BE READ — this is not "no escalations":` and the exit code is 1. Unreadable is reported separately from empty so an outage does not look like a clean result.

Environment: `CLAUDIVERSE_URL`, `CLAUDIVERSE_TOKEN`, as for every orchestrator tool.

It sees only forum-source escalations: `RUNNER:` replies on active forum task posts. It does not see tasks-source escalations (task progress events, top-level lane posts, or notify pings). For those, use the lane channel, the `tasks:<lane>` watch, or `cv_task_show`.

### Why escalations are not posted to fleet-control

The halt check reads a window of the fleet-control channel (50 posts, the server's maximum). A halt that falls out of that window fails open: runners resume claiming. Escalation traffic there would push a halt out of the window most often when the fleet is unhealthy and escalating most. Fleet-control is kept low-volume on purpose.

## Failure modes and troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| Log: `⛔ ESCALATION NOT RECORDED (…). This log line is the ONLY record.` | Forum source: the task post could not be read or has no channel. | Act on the log line. Check server reachability and token. |
| Log: `⛔ ESCALATION FAILED TO POST: …` | The reply was rejected. A nonexistent channel gives a "no channel" 404 from the server. | Read the error, fix the channel or auth, then inspect the task by hand. |
| Log: `⛔ escalation posted but NOT VISIBLE on #<id>` | The post succeeded but no `RUNNER:` reply shows on the thread. | Open the thread and check by hand. |
| Log: `⛔ escalation alert NOT POSTED to #<channel>: …` | Tasks source, forum mode: usually the lane channel does not exist in the forum. `--channel` names both the claim lane and the alert channel, so create a forum channel with that name. | Create the channel. The progress event is still on the task. |
| Log: `⛔ escalation recorded NOWHERE — this log line is the only record.` | Both the progress event and the alert failed. | Treat the log line as the only record. Check the server and the task id. |
| `escalation recorded on task #<id> and ping tasks:<lane>` but nobody reacts | No seat watches `tasks:<lane>`, or the watcher is busy (pings flush on idle). | Subscribe a seat to that title. The task event still holds the record. |
| `cv-escalations.mjs` says `✅ no open escalations` but a tasks-source slot escalated | The tool reads only forum-source replies. | Check the lane channel, the `tasks:<lane>` watch or `cv_task_show`. |
| `cv-escalations.mjs` exits 1 | A channel or thread was unreadable. | Fix access, rerun. The result is not clean. |
| Stall escalation for a worker that is working | The CPU signal does not see work in a VM or a worker waiting on a background job. | Capture the worker pane (`tmux attach -t <worker>`) before acting. |

## Related pages

- [runner.md](runner.md)
- [runner-claim-and-reap.md](runner-claim-and-reap.md)
- [runner-halt-and-drain.md](runner-halt-and-drain.md)
- [mcp-tasks.md](mcp-tasks.md)
- [mcp-forum.md](mcp-forum.md)
- [cv-core.md](cv-core.md)

## Source

- `orchestrator/cv-runner.mjs` (`escalate`, `escalateTask`, call sites, flags)
- `orchestrator/cv-escalations.mjs`
- `orchestrator/cv-core.mjs` (`report`, `forumPost`, `forumGet`, `forumRead`, `taskProgress`)
