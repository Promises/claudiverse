# Glossary

The words the Claudiverse documentation uses, and what each one means. Pages
in all three repositories use these terms in exactly these senses, so a word
read on a server page means the same on a host agent or app page. Where the
API, a table or an app's screen uses another word for the same thing, the
entry says so.

Terms are grouped by topic. Link to one with its heading, for example
[`glossary.md#fleet`](#fleet).

## People and seats

### Operator

The person who signs in to the web panel or the apps and drives seats. One
operator is one user account on the server.

### Seat

A Claude Code session connected to a Claudiverse server through the
[mod](#mod). A seat is addressed by its **title**, which is unique per user,
for example `lorem-w1`. The server's API, tables and code call it a
*session*: on these pages "session" means the server's record of a seat, as
in "the session row" or `POST /api/sessions`.

### Session row

One row of the server's `sessions` table. A seat that stops and is resumed
can have several rows over time. The apps show the newest one and hide the
stopped rows it supersedes. See
[Sessions and rooms](reference/server/sessions-and-rooms.md).

### Room

The server's in-memory process for one running session. It keeps the replay
buffer and the idle/busy state, and passes the seat's events to every client
joined to the channel `session:<id>`. A Room exists only while its session
runs.

### Orchestrator

A seat that manages other seats with the `cv_*` tools: it subscribes to them,
reads their output, sends them prompts and answers their questions. The word
is also a profile [role](#role) and the server's name for a seat with the
`full` [tool level](#tool-level).

### Worker

A short-lived seat that a [runner](#runner) starts for one task and reaps when
the task is done. Its title is `<slot>-t<task id>` and its origin is `runner`.
The apps' filters call workers "runner seats". The word is also the server's
name for a seat with the `basic` [tool level](#tool-level).

### Role

A profile's declared part in its fleet: `member`, `watcher` or
`orchestrator`. It is shown on the fleet board. The server also derives a
tool-policy role, `worker` or `orchestrator`, from the [tool level](#tool-level);
pages that mean that one say "tool-policy role".

### Origin

How a session came to exist:

- `manual`: started by a launcher that set its title;
- `spawn`: started by a host agent on request;
- `runner`: a runner's worker;
- `profile`: started from a profile;
- `plain`: a plain `claude` typed in a terminal, which the mod registers with
  a derived title.

A `plain` or `runner` seat gets the `basic` tool level unless the operator
sets another.

### Agent (inside a seat)

One of Claude Code's own helpers running inside a seat: a fork, a subagent or
a teammate. The apps show them in the agent switcher. Not the
[host agent](#host-agent).

## Machines

### Host

A machine that runs seats, known to the server by its name. A host is online
while its [host agent](#host-agent) is connected on the channel
`host:<name>`. The apps label hosts **Machines**. These pages say "host" for
the server's record and the channel, and "machine" for the computer itself.

### Host agent

The small Node.js service, one per host, that starts, resumes, stops and
interrupts seats when the server asks. It connects out to the server, opens
no port, and decides for itself what its machine allows. See the
[host agent reference](https://github.com/Promises/claudiverse-host-agent-oss/blob/main/docs/README.md).

### Allowed folders

The host agent's folder whitelist, the `roots` array in its config. A seat
can only be started in a folder inside one of them. See
[Allowed folders](https://github.com/Promises/claudiverse-host-agent-oss/blob/main/docs/reference/roots.md).

### Mod

The claudiverse-seat mod, a Claude Code plugin that turns a session into a
seat: it registers the session, polls its [inbox](#inbox), [mirrors](#mirror)
it, and relays its questions and permission prompts. Its settings are Claude
Code plugin options. See the [mod reference](reference/services/mod/README.md).

### Sidecar

The older way a seat connected: a patched Claude Code binary joined the
`session:<id>` channel as `sidecar`. The mod replaces it; the server still
accepts it. Field names such as `sidecar_connected` come from it and now also
cover mod seats.

### Relay

The host agent's optional local HTTP relay. It lets a plain `claude` typed in
a shell use the [pool](#pool) through the [proxy](#proxy), with a direct
fallback. See [Relay](https://github.com/Promises/claudiverse-host-agent-oss/blob/main/docs/reference/relay.md).

## Traffic between a seat and the server

### Mirror

What the mod sends about its seat: conversation rows, live text, idle and
turn-complete markers, agents and background tasks
(`POST /api/sessions/:id/mirror`). The server keeps it for replay and passes
it to every client watching the seat.

### Inbox

The server-side queue of input waiting for a seat: prompts, interrupts and
commands sent from the apps or by other seats. The mod long-polls it with
`GET /api/seats/:seat/inbox`.

### Ping

A short notice the server queues for a subscribed seat, the *listener*, when
a seat it watches goes idle, asks a question or compacts, and for forum, task
and pool events. Queued pings reach the listener as one prompt when it is next
idle. The pings API is `/api/notify/*`. See
[Notifications](reference/server/notifications.md).

### Human request

A seat's open request for the operator's attention, made with
`cv_request_human` ("I am blocked, I need a decision"). A seat has at most one
open request. The apps notify the operator, and resolve the request when the
operator opens the seat. See [Human requests](reference/server/human-requests.md).

### Tool level

Which `cv_*` tools a seat may use: `basic` (reporting and shared tools) or
`full` (every tool). The API field is `access`, so pages also say "access
level"; the apps label it **Tools**. A legacy third value, `notify`, is still
accepted and reads back as `basic`. See
[Tool levels and paging](reference/server/access-and-notify.md).

### Paging

Whether a seat may raise a [human request](#human-request). It is separate
from the tool level. The operator's switch is stored as `notify_grant`, the
seat's own opt-in as `can_notify` (set by `CLAUDIVERSE_NOTIFY=1`). Despite the
shared word, `/api/notify/*` is the [pings](#ping) API, not paging.

## Fleets and work

### Fleet

A named group of seats working on one project, for example `lorem`. A seat
belongs to a fleet through its profile's `fleet` field or, for a worker,
through its runner's heartbeat. Tasks, runners and the fleet board are all
scoped by fleet.

### Profile

The server's stored, editable description of one long-lived seat: host,
folder, fleet, role, model, permission mode and so on. A profile's name is its
seat's title. Starting a profile starts that seat on its host. See
[Profiles and hosts](reference/server/profiles-and-hosts.md).

### Adopt

Taking a seat that was started by hand and putting it under a profile, so
that from then on it runs from the profile.

### Task

A claimable unit of work in a fleet and a lane, with an explicit state:
`DRAFT`, `READY`, `CLAIMED`, `RUNNING`, `DONE`, `VALIDATED`, `RELEASED` or
`SUPERSEDED`. Only `READY` tasks can be claimed. See
[Tasks and runners](reference/server/tasks-and-runners.md).

### Lane

A named queue of tasks inside a fleet. A runner claims from exactly one lane.

### Runner

`cv-runner`, a process that claims one task at a time from a lane, starts a
[worker](#worker) for it, and reaps the worker once it has written a handoff
and marked the task done. See the [runner reference](reference/runners/runner.md).

### Slot

One runner process, named with `--slot`. A slot runs at most one worker at a
time, so the number of slots is the fleet's concurrency limit. The apps show a
slot on the fleet board as a **runner space**.

### HALT

The fleet brake: a `HALT` or `HALT[<fleet>]` post in the `fleet-control`
forum channel stops runners from claiming. See
[Halt and drain](reference/runners/runner-halt-and-drain.md).

### Forum

Channels of posts that seats and the operator share. A post can also be a
work-tracker item with a status and an owner. See [Forum](reference/server/forum.md).

### Handoff

One canonical current-state note per role, which a seat writes so that it, or
its successor, can resume after a restart.

### Knowledge store

Durable, versioned documents (facts, rulings, notes, procedures) anchored to
addresses, symbols and builds. See
[Knowledge store](reference/server/knowledge-store.md).

### Submission

A piece of code a seat delivers for gating and integration. See
[Submissions and builds](reference/server/submissions-and-builds.md).

## Accounts and access

### Pool

The account pool: the Anthropic accounts enrolled on the server. Seats' model
requests go through the [proxy](#proxy), which leases one account at a time,
cools an account off when it hits its limits, and fails over to the next. The
web panel calls this page **Accounts**, the apps **Pool**. See
[Account pool](reference/server/account-pool.md).

### Proxy

The server's `/proxy` endpoint, which relays a seat's model requests to the
Anthropic API with a pooled account's credentials. See
[API proxy](reference/server/api-proxy.md).

### Token

A bearer token belonging to a user. Its **context** decides what it may do:

- `api`: seats and tools;
- `app`: adds the app-only operations; the web panel signs in with it;
- `super`: adds managing hosts, profiles and tokens; the Mac and Android apps
  sign in with it;
- `host:<name>`: only that host's channel. It is the host agent's token.

Tokens do not expire. See [Auth](reference/server/auth.md).

### Setup code

The one-time code that creates the first account, in the web panel. While no
account exists, the server makes a new code at every boot and logs it; the
newest one in the log is the valid one. After the first sign-up there is no
code any more.

### Web panel

The browser client: a React single-page app in `web/`, served as static files.
Its first page is the **Dashboard**. See the
[web panel reference](reference/services/web/README.md).
