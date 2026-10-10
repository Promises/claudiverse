# Claudiverse documentation

Claudiverse connects Claude Code sessions, called **seats**, to a self-hosted
server, so an operator can watch and drive them from a browser, a Mac or a
phone, and seats can coordinate with each other. The documentation comes in
two kinds:

- The **[setup guide](guide/README.md)** installs the whole stack from
  nothing, step by step. Start there.
- The **reference** describes every feature of every part in depth: what it
  does, how it works, how to configure it, its interface and how it fails.
  Use it when you need to know exactly what a part does.

The words these pages use (seat, fleet, profile, slot, pool, and so on) are
defined once, in the **[glossary](glossary.md)**.

## The parts

Claudiverse is three repositories. This one holds the server, the web panel,
the mod and the orchestration tools; the host agent and the apps have their
own.

| Part | What it is | Reference |
|---|---|---|
| Server | The Elixir/Phoenix server: sessions, the mirror and inbox, hosts and profiles, the account pool and proxy, the forum, tasks, the knowledge store | [reference/server/](reference/server/README.md) |
| Mod | The claudiverse-seat Claude Code plugin that makes a session a seat | [reference/services/mod/](reference/services/mod/README.md) |
| Web panel | The browser client | [reference/services/web/](reference/services/web/README.md) |
| Runners and tools | `cv-runner`, `cv-spawn.sh`, the `cv_*` MCP tools, `cvctl` and `cv-subs` | [reference/runners/](reference/runners/README.md) |
| Host agent | The per-machine service that starts and stops seats | [claudiverse-host-agent-oss: docs/](https://github.com/Promises/claudiverse-host-agent-oss/blob/main/docs/README.md) |
| Android app | The phone client, with its own VPN | [claudiverse-apps: docs/android/](https://github.com/Promises/claudiverse-apps/blob/main/docs/android/README.md) |
| Mac app | The desktop client, with the fleet board | [claudiverse-apps: docs/mac/](https://github.com/Promises/claudiverse-apps/blob/main/docs/mac/README.md) |

How the parts talk to each other:

- A **seat** runs Claude Code with the **mod**. The mod registers the seat
  with the server, mirrors its conversation, long-polls its inbox for input,
  and relays its questions and permission prompts. Its model requests can go
  through the server's proxy, which serves them from the account pool.
- A **host agent** on each machine keeps an outbound WebSocket to the server
  and starts, resumes and stops seats when the server asks.
- The **web panel** and the **apps** sign in to the server, list seats over
  REST and follow them live over Phoenix channels.
- **Orchestrator** seats use the `cv_*` tools to watch and drive other seats;
  **runners** turn a fleet's task queue into short-lived worker seats.

## Where to look

| To | Read |
|---|---|
| Install the server, a machine and a first seat | [Setup guide](guide/README.md) |
| Run the server in production, back it up, upgrade it | [DEPLOY.md](DEPLOY.md), [Deployment](reference/server/deployment.md) |
| Look up an environment variable or config key | [Server configuration](reference/server/configuration.md), [mod configuration](reference/services/mod/configuration.md), [host agent configuration](https://github.com/Promises/claudiverse-host-agent-oss/blob/main/docs/reference/configuration.md), [runner configuration](reference/runners/README.md#common-configuration) |
| Find which page documents an endpoint | [Server route map](reference/server/README.md#route-map), [every call the mod makes](reference/services/mod/server-api.md) |
| Understand tokens and who may do what | [Accounts, sign-up and tokens](reference/server/auth.md), [Tool levels and paging](reference/server/access-and-notify.md) |
| Connect a machine | [Guide: a machine for seats](guide/3-machine.md), [host agent install](https://github.com/Promises/claudiverse-host-agent-oss/blob/main/docs/reference/install-and-service.md) |
| Start seats from profiles | [Profiles and hosts](reference/server/profiles-and-hosts.md), [starting seats](https://github.com/Promises/claudiverse-host-agent-oss/blob/main/docs/reference/starting-seats.md) |
| Add Anthropic accounts and understand failover | [Account pool](reference/server/account-pool.md), [API proxy](reference/server/api-proxy.md) |
| Answer a seat's questions from a phone | [Server: questions and permissions](reference/server/questions-and-permissions.md), [mod: questions and permissions](reference/services/mod/questions-and-permissions.md) |
| Run a fleet of workers from a task queue | [cv-runner](reference/runners/runner.md), [Tasks and runners](reference/server/tasks-and-runners.md) |
| Give a seat the `cv_*` tools | [cv-mcp](reference/runners/mcp.md) |
| Fix a problem | [Guide: troubleshooting](guide/6-troubleshooting.md), then the "Failure modes and troubleshooting" section of the part's page |

## How a reference page is laid out

Every feature page has the same sections, in this order:

1. **Title and introduction**: what the feature is and why it exists.
2. **How it works**: the mechanism, often with a diagram.
3. **Configuration**: settings, environment variables and defaults.
4. **Interface**: endpoints, channel events, commands, tools or screens.
5. **Failure modes and troubleshooting**: what goes wrong, what you see, what
   to do.
6. **Related pages**: the pages next to it, in this part and in the others.
7. **Source**: the files the page was written from.

A part's `README.md` is its index: an overview diagram and a table of its
pages. A few reference pages are tables rather than features (configuration,
the data model, deployment) and skip the sections that do not apply.

Examples use `https://claudiverse.example` for the server, `lorem-*`,
`ipsum-*` and `standalone-*` for seat names, and `~/` for home folders.

## Design notes

These were written before or while the code was built. Where they and the
reference disagree, the reference describes the code.

- [Seat profiles](design/seat-profiles.md)
- [The account pool](ANTHROPIC_AUTHS_DESIGN.md)
