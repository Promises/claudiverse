# cv-runner: slots

`cv-runner` (`agent/tools/cv-runner.mjs`) is a slot. You run one per terminal. It claims one task, spawns an ephemeral worker session for it (through `cv-spawn.sh`, in a tmux session), waits for that worker to declare itself done, reaps it, and loops.

It exists because nothing else owns a worker's lifecycle. Without a single owner for spawn and reap, orphaned processes and server-side sessions with no process behind them are structural. The slot is also the only party present when a worker's state is destroyed, so it is the place that enforces the "do not reap what you cannot recover" gates.

## How it works

### Slots and concurrency

One runner process is one slot, and a slot runs at most one worker at a time. The terminal is the reservation: N runners means N slots means a hard cap of N concurrent workers. Nothing else in the system limits concurrency.

A slot is identified by `--slot <name>`. Its worker for task `<id>` is named `<slot>-t<id>`, and that is also the tmux session name (`tmux attach -t <slot>-t<id>`) and the seat title.

Two settings decide what a slot claims:

- `--channel` is the lane (default `tasks`). For the forum source it is the forum channel to read. For the tasks source it is the lane name.
- `--task-source` selects the queue:

| Source | Claims from | Notes |
|---|---|---|
| `forum` (default) | Forum posts in `--channel` with `status=incoming`, no owner, not archived, not a reply. Oldest first, from a page of 20. | The claim is atomic on the server (`forumClaim`). The post is then set to `active`. |
| `tasks` | The task table: the highest-priority READY task in fleet `--fleet`, lane `--channel`, via `taskClaim`. | The task is moved to RUNNING after the claim. Requires `--fleet`. |

Never mix the two sources in one slot. A task claimed from one store and completed against the other is stranded. `--task-source tasks` without `--fleet` exits with code 2 at startup, because a claim scoped to no fleet matches nothing and would look like an empty queue.

### Main loop

```mermaid
flowchart TD
    A[loop start] --> B{drain file present?}
    B -- yes --> X[stopped heartbeat, exit 0]
    B -- no --> C{halt check}
    C -- halted or check failed --> S[sleep --poll]
    C -- clear --> D[claim a task]
    D -- none --> S
    D -- claimed --> E[write brief file, run cv-spawn.sh]
    E -- spawn failed --> F[release task, count a strike, sleep --poll]
    F --> P
    E -- spawned --> G[poll every --poll ms]
    G --> H{task done or superseded?}
    H -- yes --> I{handoff readable?}
    I -- no --> G
    I -- yes --> J[preserve unpushed commits, kill tmux session]
    J --> K{superseded?}
    K -- yes --> L[escalate note, no continuation, no validation]
    K -- no --> M[promote continuations]
    M --> N{--validate?}
    N -- yes --> O[enqueue validation]
    N -- no --> P{--once?}
    O --> P
    L --> P
    H -- no --> Q{handoff starts DECLINED?}
    Q -- yes --> R[release task, reap, block it for this slot]
    R --> P
    Q -- no --> T{tmux session alive?}
    T -- no --> U[escalate: process gone, task left active]
    U --> P
    T -- yes --> V[CPU stall check, escalate once]
    V --> G
    P -- yes --> Z[exit]
    P -- no --> A
    S --> A
```

Summary of the stages:

1. **Drain check.** If `~/.claudiverse/drain/<slot>` exists, the slot claims nothing more and exits. See [runner-halt-and-drain.md](runner-halt-and-drain.md).
2. **Claim.** The halt check runs first and fails closed: if it errors, the runner does not claim. See [runner-halt-and-drain.md](runner-halt-and-drain.md) and [runner-claim-and-reap.md](runner-claim-and-reap.md).
3. **Spawn.** The runner writes the worker brief to a temporary file and runs `cv-spawn.sh` with a 90 s timeout. A failed spawn releases the task; after 3 failures for the same task the slot stops claiming it and escalates. See [runner-brief-and-spawn.md](runner-brief-and-spawn.md).
4. **Poll.** Every `--poll` ms the runner reads the task's status. It stops waiting only when the task is `done` or `superseded`, the worker has declined, or the tmux session is gone. It never reaps on idleness, elapsed time or silence, and never kills on timeout.
5. **Reap.** Requires a readable handoff. Unpushed commits are preserved in a local `refs/rescue/<worker>` ref rather than blocking the reap. See [runner-claim-and-reap.md](runner-claim-and-reap.md).
6. **Continuations.** Parked `CONTINUE #...` replies on the finished task's forum post are promoted to claimable forum posts. This step always uses the forum, on both task sources. See [runner-validation.md](runner-validation.md).
7. **Validation.** With `--validate`, a follow-up check task is enqueued. See [runner-validation.md](runner-validation.md).
8. **Loop.** With `--once` the slot exits after one task attempt (successful or not); otherwise it goes round again.

Stalls and vanished workers are escalated, not acted on. See [runner-escalation.md](runner-escalation.md).

### Heartbeat

A heartbeat is sent only when `--fleet` is set; a runner without `--fleet` has no place on the fleet board and does not beat.

- A local timer runs every 2 s (no network). It computes a signature of `[state, seat, task]`.
- A report is sent when the signature changes, and otherwise at least every 30 s.
- Sending is fire-and-forget (`POST /api/runners/heartbeat`). A failure never touches the claim loop. A refused heartbeat is logged as `heartbeat refused (<status> <error>)`, except status 404, which is silent (for example a server that does not have the endpoint).
- States: `idle`, `busy` (a task is held), `halted` (a halt has been announced and not lifted), and `stopped` (sent on Ctrl-C and on drain exit, bounded to 2 s so a dead server cannot hold the exit).

Fields of the report:

| Field | Value |
|---|---|
| `slot` | `--slot` |
| `fleet` | `--fleet` |
| `state` | `idle`, `busy`, `halted` or `stopped` |
| `host` | `CLAUDIVERSE_HOST`, else the machine hostname |
| `channel` | `--channel` |
| `lane` | `--channel` when the source is `tasks`, otherwise omitted |
| `task_source` | `forum` or `tasks` |
| `model` | `--model`, omitted if unset |
| `seat` | the worker name, only while `busy` |
| `task` | the task id, only while `busy` |
| `since` | ISO timestamp of the last state/seat/task change (set when the runner starts, reset on each change) |

### Attaching to the worker

You can watch the worker's tmux pane from the runner's terminal.

- `--attach` attaches read-only (`tmux attach-session -r`) as soon as the worker spawns.
- `--attach-rw` implies `--attach` and attaches interactively; your keystrokes reach the agent.
- Pressing `a` (or `A`) in the runner's terminal attaches to the current worker at any time. If there is no worker it logs `nothing to attach to`; if the tmux session is gone it logs `cannot attach`. Pressing `a` attaches read-only unless `--attach-rw` was given.
- Detach with `C-b d`. That ends the tmux client, not the worker.
- Attaching does not pause supervision. The poll loop keeps running while you watch.
- While attached, runner log lines are buffered instead of printed (tmux is redrawing the screen and would erase them). They are flushed when you detach or the worker's session ends.
- The terminal is switched to raw mode to read the `a` key. Raw mode disables the terminal's own Ctrl-C, so the runner forwards the `0x03` byte to its SIGINT handler by hand. Raw mode is released while tmux owns the terminal and restored afterwards.
- Without a TTY on stdout, `--attach` is ignored with the log line `attach ignored: stdout is not a TTY (running detached?). Attach yourself: tmux attach -t <name>`. Without a TTY on stdin, the `a` key is unavailable and the runner logs `stdin is not a TTY`.

### Ctrl-C

Ctrl-C closes the slot but does not kill the worker. The runner restores the terminal, sends a `stopped` heartbeat (if `--fleet`, bounded to 2 s), flushes buffered log lines, and exits 0. If a task was in flight it logs that the task is still ACTIVE and the worker is still running, and prints the command to reap deliberately: `tmux kill-session -t <worker>`. If nothing was in flight it logs `Ctrl-C — slot released, nothing in flight.`

### Startup log lines

On start the runner prints, in order:

```
slot open · channel #<channel> · workdir <workdir> · reaps ONLY on cv_task_done or a SUPERSEDED task, and only with a readable handoff
server <url> · halt scope --fleet <fleet>
binary <path or "(cv-spawn default)">
model <m or "(binary default)"> · validate-model <m or "(binary default)">
effort <e or "(binary default)"> · validate-effort <e or "(binary default)">
validations POST to #<validate-channel> (not this slot's own #<channel>)     (only with --validate-channel)
press 'a' to attach to the running worker · Ctrl-C to close the slot          (or the "stdin is not a TTY" line)
```

Each line is prefixed with `[HH:MM:SS] <slot>`. Two parts of the second line need attention:

- If `CLAUDIVERSE_URL` is not set the server is shown as `<url> ⚠️ DEFAULT (CLAUDIVERSE_URL unset)`. The default is `http://localhost:4000`.
- Without `--fleet` the halt scope reads `NONE ⚠️ bound by every halt`.

## Configuration

### Flags

Every flag takes a value unless noted. Argument parsing is positional: the value is the token after the flag. If that token is missing or starts with `--`, the flag is treated as missing (its default is used) and the next flag is not swallowed.

| Flag | Default | Meaning |
|---|---|---|
| `--slot <name>` | none, required | Slot name; prefix of worker names (`<slot>-t<taskId>`). |
| `--workdir <path>` | none, required | Absolute path of the working directory the worker starts in. Also the repository checked for unpushed commits at reap time. |
| `--channel <name>` | `tasks` | Forum channel (forum source) or lane (tasks source) to claim from. Also where escalations and, unless overridden, validations are posted. |
| `--mcp <file>` | unset | MCP config file passed to the **worker** (via `cv-spawn.sh --mcp`). It does not configure the runner. |
| `--bin <path>` | unset (cv-spawn's default: `$CLAUDIVERSE_BIN`, else `$HOME/.local/bin/claude`) | Claude binary for this slot's workers. Lets one slot run a new build beside others. Must be executable or the runner exits 2. |
| `--mode <mode>` | `auto` | Permission mode passed to `cv-spawn.sh --mode`. |
| `--poll <ms>` | `5000` | Poll interval: between claim attempts and between status checks of a running task. |
| `--task-source forum\|tasks` | `forum` | Where claimable work comes from (see above). |
| `--escalate-via forum\|notify` | `forum` | Tasks source only: `forum` posts a top-level alert in the lane channel; `notify` sends a direct ping from source `tasks:<lane>` and posts nothing. Either way the alert is also recorded on the task's event trail. |
| `--stuck-after <min>` | `30` | Minutes with no CPU consumed across the worker's process tree before a stall is escalated. |
| `--stuck-hard-after <min>` | `180` | Fallback when the process table cannot be read: minutes elapsed before escalating. |
| `--cpu-epsilon <s>` | `0.5` | CPU seconds, summed over the worker's process tree since the last sample, that count as "the worker did something". |
| `--once` | off (boolean) | Exit after one task attempt (even if the spawn failed). |
| `--attach` | off (boolean) | Attach read-only to each worker as it spawns. |
| `--attach-rw` | off (boolean) | Attach interactively; implies `--attach`. |
| `--validate` | off (boolean) | Enqueue a validation task after each completed (not superseded) task. |
| `--charter <file>` | unset | File whose contents are injected into every worker brief. Must exist and be non-empty. |
| `--fleet <name>` | unset | Fleet name. Scopes halts, scopes tasks-source claims (required there), is passed to `cv-spawn.sh --fleet`, and enables heartbeats. |
| `--model <m>` | unset | Model for workers. Unset means no `--model` is passed and the binary decides. |
| `--validate-model <m>` | value of `--model` | Model for validation tasks. |
| `--effort <level>` | unset | Reasoning effort for workers (usage text: `low|medium|high|xhigh|max`). The runner does not validate the value. |
| `--validate-effort <level>` | value of `--effort` | Effort for validation tasks. |
| `--validate-channel <name>` | unset (then `--channel`) | Channel or lane where auto-enqueued validations are posted. Point it at a different lane so a different tier of slot validates the work. |
| `--validate-priority <n>` | `8` | Priority of validation tasks (tasks source only). Must be an integer. |
| `--validate-body <file>` | unset | Lane-specific validation brief replacing the generic one. `#{TASK_ID}`, `#{WORKER}` and `#{TITLE}` are substituted. Must exist and be non-empty. |
| `--handoff-grace <s>` | `60` | Seconds a finished worker's handoff may stay unreadable before the operator is told. The runner keeps checking afterwards. |
| `--decline-poll <ms>` | `30000`, never below `--poll` | How often a running worker's handoff is read to detect a decline. The effective value is `max(--poll, --decline-poll)`. |

`--model`, `--effort`, `--mcp`, `--bin` and `--fleet` are only forwarded to `cv-spawn.sh` when set. Validation tasks use `--validate-model` and `--validate-effort`; all other tasks use `--model` and `--effort`.

### Startup validation (exit code 2)

The runner exits with code 2, after printing a message to stderr, when:

1. `--task-source` is not `forum` or `tasks`.
2. `--escalate-via` is not `forum` or `notify`.
3. `--task-source tasks` is used without `--fleet`.
4. `--validate-priority` is not an integer.
5. `--bin` is set and the path is not executable.
6. `--validate-body` is set and the file cannot be read, or is empty.
7. `--charter` is set and the file cannot be read, or is empty.
8. `--slot` or `--workdir` is missing. The runner prints its usage text.

The checks run in the order above (1, 2, 3, 4, 5, 6, 7, 8). `--poll`, `--stuck-after`, `--stuck-hard-after`, `--cpu-epsilon`, `--handoff-grace` and `--decline-poll` are converted with `Number(...)` and are not range-checked.

### Environment read by the runner

| Variable | Used for |
|---|---|
| `CLAUDIVERSE_URL` | Server base URL (via [cv-core](cv-core.md)). Default `http://localhost:4000`; the startup line warns when it is the default. |
| `CLAUDIVERSE_TOKEN` | Bearer token for server calls (via [cv-core](cv-core.md)). |
| `CLAUDIVERSE_HOST` | Value of `host` in heartbeats. Default: the machine hostname. |

`--mcp` configures the worker, not the runner. The runner reads `CLAUDIVERSE_URL` and `CLAUDIVERSE_TOKEN` from its own shell, so export them before starting it even if the worker's MCP config sets them.

`cv-spawn.sh` reads defaults from the environment that a launcher script may export before starting the runner: `CV_SPAWN_ORIGIN`, `CV_SPAWN_POOLED`, `CV_SPAWN_CONFIG_DIR`, `CV_SPAWN_OAUTH_TOKEN_FILE` and `CV_SPAWN_POOL_ONLY`, as well as `CLAUDIVERSE_BIN` for the binary. The runner itself always passes `--origin runner` and, when set, `--fleet`; flags win over those environment defaults. See [cv-spawn.md](cv-spawn.md) for what each one does.

## Interface

Run the runner with Node. All flags are shown in the table above; the minimum is `--slot` and `--workdir`.

Forum source (the default), one slot, read-only attach:

```bash
export CLAUDIVERSE_URL=http://claudiverse.example:4000
export CLAUDIVERSE_TOKEN=...

node agent/tools/cv-runner.mjs \
  --slot lorem-w1 \
  --channel tasks \
  --workdir ~/work/lorem-w1 \
  --mcp ~/worker.mcp.json \
  --attach
```

Tasks source in a fleet, with validation routed to a deeper lane so a different slot checks the work:

```bash
node agent/tools/cv-runner.mjs \
  --slot lorem-w4 \
  --task-source tasks \
  --fleet lorem-fleet \
  --channel lorem-tasks \
  --workdir ~/work/lorem-w4 \
  --mcp ~/worker.mcp.json \
  --model sonnet --validate-model opus \
  --validate \
  --validate-channel lorem-tasks-deep \
  --validate-priority 8 \
  --escalate-via notify
```

One-shot run that handles a single task and exits:

```bash
node agent/tools/cv-runner.mjs --slot lorem-w1 --workdir ~/work/lorem-w1 --once
```

Keys while running: `a` attaches to the current worker; Ctrl-C closes the slot (the worker keeps running).

## Failure modes and troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| Exit code 2 and a message at start | A startup validation failed. | See the list above; fix the flag or file named in the message. |
| `server ... ⚠️ DEFAULT (CLAUDIVERSE_URL unset)` | `CLAUDIVERSE_URL` is not exported in the runner's shell. `--mcp` does not affect the runner. | Export `CLAUDIVERSE_URL` and `CLAUDIVERSE_TOKEN`, then restart. |
| `⛔ HALT CHECK FAILED (...) — refusing to claim` | The runner could not read the halt channel. It fails closed. | Check server reachability and the token. The slot resumes when the check succeeds. |
| `queue empty — 0 claimable in #<channel>` | No forum post matches the claim filter. A post created without `status=incoming` is invisible to it. | Create tasks with `cv_task_add`, which sets the status. |
| `queue empty — 0 READY tasks in <fleet>/<lane>` | Tasks source: nothing READY in that fleet and lane. | Check the fleet and lane spelling and that tasks are READY. |
| `tmux session '<worker>' already exists; refusing to clobber. Releasing claim.` | A tmux session with the worker's name is already running. | Kill or inspect the old session; the task is released and will be claimed again. |
| `spawn FAILED (attempt n)` then `failed to spawn 3× — NOT re-claiming it` | `cv-spawn.sh` failed or timed out (90 s). After 3 failures for one task, the slot blocks that task and escalates. | Read the logged cause (binary, tmux, MCP file). Another slot, or a restart of this one, can take the task. |
| `<id> is done but <worker>'s handoff is ... not visible yet` | The status can be seen before the handoff is readable. The runner does not reap and keeps checking; after `--handoff-grace` seconds it escalates once. | Usually resolves itself. If not, check the worker's handoff on the server. |
| Slot stuck on a finished task after Ctrl-C | Ctrl-C leaves the worker running by design. | `tmux kill-session -t <worker>`, as printed. |
| Heartbeat missing on the board | `--fleet` not set, or the server does not know the endpoint (404 is silent). | Set `--fleet`; other refusals are logged as `heartbeat refused (...)`. |
| `attach ignored: stdout is not a TTY` | The runner is running detached (no TTY). | Attach yourself with `tmux attach -t <worker>`. |

## Related pages

- [Claim and reap](runner-claim-and-reap.md)
- [Validation](runner-validation.md)
- [Halt and drain](runner-halt-and-drain.md)
- [Escalation](runner-escalation.md)
- [Brief and spawn](runner-brief-and-spawn.md)
- [cv-spawn](cv-spawn.md)
- [cv-core](cv-core.md)
- [cv-mcp overview](mcp.md)
- [Setup guide](../../guide/README.md)
- [Runners index](README.md)
- Server: [Tasks and runners](../server/tasks-and-runners.md)
- Mac: [Fleet board](https://github.com/Promises/claudiverse-apps/blob/main/docs/mac/fleet-board.md)

## Source

- `agent/tools/cv-runner.mjs`
- `agent/tools/cv-core.mjs`
- `agent/tools/cv-validation.mjs`
- `agent/tools/cv-spawn.sh`
