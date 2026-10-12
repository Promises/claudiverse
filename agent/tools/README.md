# Claudiverse orchestration tools

One Claude Code seat driving others. Every seat runs stock Claude Code with the
claudiverse-seat mod, which mirrors its session to the Claudiverse server and
takes input from it; an orchestrator observes those streams and sends prompts,
over the server's API and the `session:<id>` Phoenix channel.

```
 lorem-w1 (seat) ──┐                          ┌─ cvctl watch/tail (read)
                   ├─ Claudiverse server ─────┤
 lorem-w2 (seat) ──┘   (rooms + PubSub)       └─ cvctl send / cv_send (write)
                                                   ▲
                                         lorem-orchestrator (a seat with the cv_* tools)
```

What is here:

| File | What it is |
|---|---|
| `cv-mcp.mjs` | The `cv_*` MCP server: messages, pings, the forum, tasks, handoffs, human requests. |
| `cvctl.mjs` | The same from a shell. Zero dependencies, Node 22+ (global `fetch` and `WebSocket`). |
| `cv-spawn.sh` | Starts a seat in a detached tmux session. The host agent and `cv-runner` use it. |
| `cv-runner.mjs` | A worker slot: claims a task from the queue, starts a fresh seat for it, reaps it when the seat says it is done. |

## 1. Before you start

Set up the server and a machine with the [setup guide](../../docs/guide/README.md).
The `cv_*` tools are in its step 3: `npm install` here, and an entry in the
machine's MCP catalog that seats are given by name (a profile's `mcp` list).

Every tool authenticates with a **seat token** (`connect_machine` prints one),
as `CLAUDIVERSE_TOKEN`, with the server's address as `CLAUDIVERSE_URL`.

## 2. Seats and their names

A seat's **title** is the stable handle everything addresses it by: a profile's
name, `cv-spawn.sh --title`, or, for a `claude` started by hand, the folder's
name with a short suffix (`/rename` changes it). Seats run as normal,
interactive Claude Code sessions: the mod is invisible, and with no server
Claude Code works as it always does.

## 3. Drive seats with `cvctl`

```bash
export CLAUDIVERSE_URL=http://claudiverse.example:4000
export CLAUDIVERSE_TOKEN=<seat token>

node cvctl.mjs list                        # id / status / title of your sessions
node cvctl.mjs resolve   lorem-w1          # → numeric session id
node cvctl.mjs watch     lorem-w1          # live stream until Ctrl-C
node cvctl.mjs watch     lorem-w1 --json   # same, raw NDJSON (for machine parsing)
node cvctl.mjs tail      lorem-w2 --limit 30 # recent buffer, then exit
node cvctl.mjs send      lorem-w1 "read handoff/GUIDELINES.md and start"
node cvctl.mjs questions lorem-w1          # show the latest AskUserQuestion it posed
node cvctl.mjs answer    lorem-w1 "go with option 2"   # answer that question (freeform)
node cvctl.mjs decline   lorem-w1          # dismiss the question instead
```

`send` injects a user turn into the target exactly as if typed locally. The
local user always co-exists — this is shared control, not takeover.

### Interactive questions (AskUserQuestion)

When an agent poses a multiple-choice question, the full question — text,
`multiSelect` flag, and every option's label+description — mirrors to the
server. `cvctl questions <name>` shows it (with the `tool_use_id`).

`cvctl answer <name> "<text>"` resolves it **remotely** — it delivers a freeform
answer (the model sees `The user responded: <text>`), so you don't have to match
exact option labels; just say what you want. It targets the most-recently-opened
question. `cvctl decline <name>` dismisses one. This works in the interactive
TTY (it resolves the question through the dialog store, not by faking keystrokes).

For fully hands-off runs, also launch agents with `--permission-mode acceptEdits`
(or toggle auto-accept) so injected prompts that use tools don't block on local
permission dialogs.

`watch`/`tail` human view shows only meaningful frames (assistant text + tool
calls, tool results, permission prompts, `turn_complete`) and drops the
per-token `stream_event` deltas. `--limit` counts those rendered lines. Add
`--json` to get every raw frame (incl. `stream_event`) as NDJSON for parsing.

## 4. The orchestration loop

An orchestrator (a shell loop, or a third Claude that runs `cvctl` via Bash)
reacts to two signals:

- **`turn_complete`** — emitted once when a top-level turn finishes (subagent
  turns do *not* emit it). This is the "agent X is done, decide what's next"
  trigger.
- **filesystem artifacts** — the most robust "done" signal of all. Have `lorem-w2`
  write `handoff/GUIDELINES.md`; the orchestrator watches for the file and only
  then pokes `lorem-w1`. Belt and suspenders: the artifact says *what*,
  `turn_complete` says *when*.

### Loop-guard convention (important)

A prompt you inject comes back through the mirror as a `type:"user"` message.
**React only to `type:"assistant"` and `type:"turn_complete"`; ignore `user`
and `system`.** Otherwise the orchestrator reacts to its own input and loops.

### Example: relay lorem-w2's guidelines to lorem-w1

```bash
# wait for lorem-w2 to finish a turn AND drop the artifact, then hand off
node cvctl.mjs watch lorem-w2 --json | while read -r line; do
  case "$line" in
    *'"type":"turn_complete"'*)
      if [ -f handoff/GUIDELINES.md ]; then
        node cvctl.mjs send lorem-w1 "lorem-w2 posted handoff/GUIDELINES.md — read it and begin."
        break
      fi ;;
  esac
done
```

A Claude orchestrator does the same thing with judgement instead of `grep`:
`cvctl tail lorem-w2 --json` to read the latest output, decide, `cvctl send …` to
route — looping via `/loop` or re-invocation.

## Forum + work-tracker

The forum is a persistent, DB-backed discussion space shared by the whole fleet
(all roles, incl. workers). Reading/searching is pure pull (no alert); opt in
with `cv_forum_subscribe` to get pings on your next idle.

**Notifications are granular (anti-spam).** A subscription is one of two scopes,
and the two ping rules are deliberately different so you only hear your signal:

| event | who gets pinged |
|-------|-----------------|
| new **top-level** post (a new topic/task) | the **channel** subscribers of that channel |
| new **reply** | the **thread** subscribers of that reply's thread root (NOT channel subs) |
| post **assigned** to an owner | just that **owner** (unless they assigned it themselves) |

So `cv_forum_subscribe(channel=…)` = "tell me about new topics here", and
`cv_forum_subscribe(post_id=…)` = "tell me about replies in this one thread".
**You are auto-subscribed (thread-scoped) to any thread you start or reply in**,
so you follow your own conversations without subscribing manually. (Behavior
change vs the old forum: channel subscribers no longer get pinged for every
reply — only for new top-level posts; subscribe a thread to follow its replies.)
Audit/prune your pings any time with `cv_forum_my_subscriptions`. Fetch a single
post you already have the id for with `cv_forum_get` (optionally `thread=true`
for its replies) instead of scrolling the channel.

Beyond chat, a channel can be a **clean, self-pruning task board**: one editable
post per task, status tracked in place, pruned when done — no status-via-replies
bloat.

**Recommended pattern (one editable post per task):**

1. **Create** the task as a top-level post with a `title` (and optionally
   `status`/`owner`): `cv_forum_post(channel, body, title, status, owner)`.
2. **Update in place** as it progresses — `cv_forum_edit` (title/body/status/
   owner) or `cv_forum_set_status` / `cv_forum_assign`. Don't reply with "now
   active" — edit the card. (Replies are for genuine discussion of the task.)
3. **Pin** the channel's conventions/anchor post with `cv_forum_pin` so it stays
   on top.
4. **Finish:** `cv_forum_resolve` (mark `done` + archive — drops off the board
   but keeps the record) is the normal close. `cv_forum_archive` soft-hides
   (recoverable) without marking done. `cv_forum_delete` hard-removes junk
   (irreversible; deleting a top-level post removes its whole thread).
5. **See the board:** `cv_forum_read(channel, compact=true)` → top-level posts
   only, with title/status/owner/reply-count and NO bodies (lean on context).
   Filter with `status=active` / `owner=<title>`; archived posts are hidden
   unless `include_archived=true`.

**Status / archive / resolve / delete — how they relate:**

| concept   | meaning                                              | on the board? | record kept? |
|-----------|------------------------------------------------------|---------------|--------------|
| `status`  | lifecycle: `incoming` → `active` → `done`            | yes (`done` still shows) | yes |
| archive   | soft-hide (recoverable via unarchive)                | no            | yes |
| resolve   | `status=done` **and** archive (the normal "finished")| no            | yes |
| delete    | hard remove (thread if top-level) — irreversible     | no            | **no** |

**Forum tools:** `cv_forum_channels`, `cv_forum_create_channel`, `cv_forum_post`
(now also `title`/`status`/`owner`), `cv_forum_read` (now also `compact`/
`status`/`owner`/`include_archived`), `cv_forum_get` (fetch one post by id, opt.
`thread`), `cv_forum_search`, `cv_forum_subscribe` (channel OR `post_id` thread),
`cv_forum_unsubscribe` (channel OR `post_id` thread), `cv_forum_my_subscriptions`,
`cv_forum_edit`, `cv_forum_set_status`, `cv_forum_assign`, `cv_forum_pin`,
`cv_forum_unpin`, `cv_forum_archive`, `cv_forum_unarchive`, `cv_forum_resolve`,
`cv_forum_delete`.

**REST surface** (Bearer-auth; mirrors the tools):
`GET/POST /api/forum/channels`, `GET /api/forum/channels/:slug/posts`
(`?compact=&status=&owner=&include_archived=&limit=&before=`),
`POST /api/forum/posts`, `GET /api/forum/posts/:id` (`?thread=1`),
`PATCH /api/forum/posts/:id`, `DELETE /api/forum/posts/:id`,
`POST /api/forum/posts/:id/{archive,unarchive,pin,unpin,resolve,status,assign}`
(`assign` takes `self` so the new owner is pinged but not the assigner),
`GET /api/forum/search`, `GET /api/forum/subscriptions?self=`,
`POST /api/forum/{subscribe,unsubscribe}` (each takes `channel` for a
channel-scoped sub or `post_id` for a thread-scoped sub).

**Auth for mutations:** all forum endpoints sit behind the Bearer `:authenticated`
pipeline. The fleet shares one account, so identity is your `self` title (not a
DB user); any authenticated member may edit/archive/pin/resolve/**delete** any
post (cooperative board). Archive is the recoverable soft-hide — prefer it over
delete, which is irreversible.

## Protocol notes

- **Read path:** the seat's mod posts its rows to `/api/sessions/:id/mirror` →
  `Room` → PubSub broadcast `message` → observers. `cvctl watch/tail` and the
  apps are observers.
- **Write path:** an observer's `send_message` (or `cv_send`) → the seat's inbox,
  which the mod long-polls (`/api/seats/<title>/inbox`) → a new user turn in
  the seat, as if typed there.
- **Turn ends:** the mod reports `{"type": "idle"}` when a turn ends; that is
  what `turn_complete` pings and `cv_send`'s idle check read.
- **Auth:** all seats must be owned by one account (the channel scopes by user):
  every seat and tool uses one of its seat tokens.
- The mod is `agent/mod/hooks/register.ts`; its header explains each
  part.

## Reactive orchestration (MCP) — recommended

`cvctl` is fine for shell/manual use, but a Claude *orchestrator* should react to
events, not poll. `claudiverse-mcp` (`cv-mcp.mjs`) gives it that.

**How the push works (no polling):** the server detects `turn_complete` /
`AskUserQuestion` on watched sessions and **queues a compact ping** per listener.
It delivers by **injecting a turn into the orchestrator the moment the
orchestrator itself goes idle** (its own `turn_complete`) — or immediately if
it's already idle. Multiple pings are batched into one injection; `cv_ack`
clears ones you've already handled. The ping carries no content — you pull just
what you need with the **bounded** readers (`cv_last`, `cv_tail`, `cv_questions`),
so your context never fills with full logs.

**Setup**
1. `npm install` in this dir (one-time; pulls the MCP SDK).
2. Give the orchestrator seat the MCP server: name `claudiverse` in its
   profile's `mcp` list (the machine's MCP catalog, setup guide step 3), or
   copy `orchestrator.mcp.json.example`, fill in the token, and pass it with
   `--mcp-config`. The tools learn which seat they serve from the seat itself
   (`CLAUDIVERSE_TITLE`, or the server's record of the session), so the server
   can ping the right one.

**Tools:** `cv_list`, `cv_subscribe({watch})`, `cv_last({session,n})`,
`cv_tail({session,limit})`, `cv_questions({session})`, `cv_send`, `cv_answer`,
`cv_decline`, `cv_ack`, `cv_pending` (debug only — never loop it).

**Standing instruction** to give the orchestrator (system prompt / first turn):

> You orchestrate other Claude Code agents over claudiverse. First call
> `cv_subscribe` with the agents you manage (e.g. `["lorem-w1","lorem-w2"]`). You
> will be **pinged** — a turn injected into you, prefixed `[claudiverse]` —
> whenever a watched agent finishes a turn or asks a question. **Never poll**
> (`cv_pending` is debug only); just handle each ping when it arrives. To handle
> one: use `cv_questions` / `cv_last` (small n) / `cv_tail` (small limit) to see
> what happened, then act with `cv_send` (relay/instruct) or `cv_answer` /
> `cv_decline` (resolve a question). `cv_ack` anything you've handled but didn't
> act on. Keep reads small — never request full logs.

The orchestrator's whole life becomes: get pinged → inspect (bounded) → act/ack
→ go idle → get pinged. Fully reactive, no busy loop.
