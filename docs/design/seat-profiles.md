# Seat profiles — design for review (2026-10-05)

Status: **proposal, revision 3** (claudiverse-desktop's review; the operator's
requirement that ad-hoc sessions and server-less use stay first-class).
Reviewers: the operator, claudiverse-desktop. Author: Failover.

## Why

Every long-lived seat today is a shell script in `~/startup-scripts/` that sets a
bundle of environment variables and CLI flags, then execs a pinned binary:

- the settings live in files on one machine, copied and edited by hand, and drift
  apart (ipsum-admin.sh, ipsum-orchestrator.sh, lorem-admin.sh, failover.sh, claudiverse-apk.sh, …);
- identity is easy to get wrong: claudiverse-apk ran for days with Failover's
  `CLAUDIVERSE_SELF` because both used one shared `.mcp.json`;
- nothing restarts a seat after a reboot; the operator runs the scripts;
- fleets are not declared anywhere the server can read, so the fleet board guesses
  members from titles.

The claudiverse-seat mod (`mods/claudiverse-seat`, verified on stock 2.1.289) now
does everything a seat needs at runtime. What is left is *starting* seats, and that
is what the scripts do badly.

## Goal

One record per seat on the server, a **profile**. The machine's host agent starts
the seat from it; the mod applies what can change while the seat runs. No startup
scripts, no per-seat env bundles, no binary patch needed (stock Claude Code + mod),
with the patched binary kept as a per-profile rollback.

## The baseline: every `claude` is a seat, profile or not

The operator's requirement (2026-10-05): typing `claude` in any terminal must open a
session that is connected to claudiverse, with everything assigned on the fly, and
Claude must keep working when there is no server. Today that is a shell alias to
the patched `claude-rel` plus five `CLAUDIVERSE_*` variables in the shell profile.
The new baseline does the same with no patch and no variables:

- **The mod is installed for the user** (a user-scope plugin), so every Claude Code
  session on the machine loads it, however it was started.
- **Its settings are plugin options**, not environment variables: the server address
  and the seat token live in the plugin's `userConfig` (Claude Code keeps them in the
  user settings, `pluginConfigs`). Set once per machine.
- **Identity is assigned on the fly.** The mod registers with the folder, machine,
  Claude Code session id and versions. The title is the session's own name when it
  has one (`/rename`), else the folder name with a short suffix. The server may
  assign the rest at registration from simple rules (for example: this folder →
  fleet `lorem-fleet`; notify off), and answers with what it assigned; the mod applies it.
- **No server, no problem.** If registration fails, Claude works exactly as stock;
  the status line says `claudiverse offline`, and the mod retries with a growing
  delay (30 s up to 5 min), registering when the server comes back. Nothing blocks or
  slows the session, and the login stays the machine's own.
- **Profiles are an optional layer** for managed, long-lived seats. A seat the agent
  starts from a profile carries `CLAUDIVERSE_PROFILE`; the mod then registers that
  profile id and the server applies the profile's fields. Everything else in this
  document is about that layer.

So there are three kinds of seat, all running the same mod:

| Kind | Started by | Identity from | Server down |
|---|---|---|---|
| ad-hoc | you typing `claude` | the session + server rules | plain Claude, mod retries quietly |
| profile | a host agent, from a profile | the profile | the agent cannot start it; a running one carries on like ad-hoc |
| runner worker | `cv-runner` | the runner's slot and task | as today: no claims while the server is down |

## The profile

| Field | Example | Notes |
|---|---|---|
| `id` | `17` | the stable key: URLs, seat rows and saved board layouts use it |
| `name` | `ipsum-admin` | the seat title and tmux session name; unique per user; **cannot be changed** (a rename would break tmux, layouts and history links: create a new profile instead) |
| `revision` | `4` | bumped on every edit; a save sends the revision it read, and gets 409 if it changed |
| `machine` | `my-mac.local` | a host with an online agent |
| `folder` | `~/projects/my-app` | must be inside that machine's whitelist |
| `fleet` | `ipsum-fleet` | declared membership (fleet board) |
| `role` | `member` / `watcher` / `orchestrator` | shown on the board; `origin` becomes `profile` |
| `can_notify` | `true` | may page the operator (`cv_request_human`) |
| `runtime` | `stock+mod` / `patched` | patched = today's `claude-rel`, the rollback |
| `model`, `effort` | `claude-opus-5-5[1m]`, `high` | launch flags; the mod can change them live |
| `permission_mode` | `auto` | from the agent's whitelist only; never `bypassPermissions` |
| `mcp` | `["claudiverse", "ghidra"]` | NAMES from the machine's own MCP catalog (see Safety) |
| `pooled` | `false` | true: pool login + proxy failover (optional feature) |
| `autostart` | `true` | the agent starts it when it comes online and it isn't running |
| `resume` | `latest` / `new` / a conversation id | a fixed id lets a migrated script's conversation continue |
| `debug` | `false` | `CLAUDIVERSE_DEBUG` and `--debug-file` |

Stored beside the profile, as facts (not status): `last_start` — when, the outcome
(started / refused / machine offline / exited at once) and the agent's reason.

Each **seat row** records the `profile_id` that started it, the profile `revision` it
launched with (so a client can show "restart needed"), its tmux session name, its
Claude Code and mod versions, and what it can do (for example `set_mode`, so the
apps grey out remote mode switching on stock+mod seats).

Deliberately **not** in a profile: free-form CLI arguments, free-form environment
variables, binary paths, MCP commands. Each of those would let a profile edit run
arbitrary code on a machine.

## Who applies what

| Concern | Server | Host agent (launch) | Mod (runtime) |
|---|---|---|---|
| store, validate, list profiles | ✔ | | |
| seat title, server URL, seat token | hands title to agent | sets `CLAUDIVERSE_*` env | registers with them |
| folder, trust | | checks whitelist; pre-trusts (`~/.claude.json` project entry) | |
| tmux | | starts the seat in a tmux session named after the profile | reports the session name |
| profile id, revision | hands them to the agent | sets `CLAUDIVERSE_PROFILE` / `_REVISION` | registers them on the seat row |
| runtime, model, effort, mode | | builds argv (`--plugin-dir`, `--model`, …) | model/effort changes live via `turn.step` |
| MCP servers | | generates the config from its catalog, `SELF` = name | |
| fleet, role, can_notify | knows them from the profile; row filled on registration | | |
| pooled | lease + proxy routing | sets proxy env + leased login | |
| resume | tracks the conversation id (already does) | `--resume <id>` | |
| autostart, restart | asks the agent | starts if not running | |

## API

- `GET/POST/PATCH/DELETE /api/profiles[/:id]` — super token for writes; any token
  reads (a stated choice: it shows folders to every seat's token, acceptable in
  this private project). The list carries each profile's derived status.
- `PATCH` requires the revision it read (409 on a mismatch).
- `DELETE` of a running profile is refused (409): stop it first.
- `POST /api/profiles/:id/start | stop | restart` — app or super token; relayed to
  the profile's machine (new agent op `start_profile`, existing `stop`). 202 with a
  request id; the outcome as a `profile` event on `operator:events`, and stored as
  `last_start`.
- Every profile change is pushed as a `profile` event on `operator:events`.
- `GET /api/hosts` lists, per machine, the choices its agent allows: permission
  modes, runtimes (with the pinned Claude Code build each maps to) and MCP catalog
  names, so editors offer menus.
- `GET /api/fleets` gains `members` from profiles: `id`, `name`, `role`, `machine`,
  derived `status` (running / stopped / starting / failed / machine offline) and the
  current `seat` id or null.
- Status is derived, never stored: the seat rows carrying this `profile_id`, the
  machine's presence, and `last_start`.

## Safety

The machine stays the authority, as with the whitelist today:

- folder must be inside the machine's roots (realpath-checked);
- permission mode from the agent's own list; `bypassPermissions` never;
- `runtime` names map to binaries in the agent's config, not paths from the server;
- `mcp` names map to entries in the agent's local MCP catalog
  (`~/.config/claudiverse/mcp-catalog.json`), so the server can choose *which*
  servers a seat gets but never *what command* runs;
- writes need the super token; the agent refuses a profile for another machine.

## Migration

1. Write a profile for each startup script; run it once beside the script and
   compare (same title, fleet, MCP tools, model, mode).
2. Switch one seat at a time, ipsum-fleet first. lorem-fleet seats only via lorem-admin.
3. Keep each script until its profile has run for a week; then delete the script.

## Runners (phase 4)

`cv-runner`'s flags become a runner profile: slot, fleet, channel/lane, task source,
model/effort, validation settings, charter, and a worker template (folder, MCP,
runtime). The agent runs `cv-runner` from it, and the fleet board's runner spaces
become configurable, not only observed.

## Decisions (from review)

1. Remote permission-mode switching (patch 013) stays on the patched runtime until
   mods get an API for it; no `tool.check` emulation (it would show a mode Claude
   Code is not in). Seats report `set_mode` capability; apps grey the control out.
2. Each machine's agent config pins one Claude Code build per runtime name; no
   automatic install or upgrade (the mod is verified per version). Seats report
   their Claude Code and mod versions.
3. Profile edits apply at the next restart; model and effort apply live through the
   mod. Seats record the revision they launched with, so clients show "restart
   needed".
4. The mod ships with the host agent repo, so the two are versioned together.

## Phases

| Phase | Scope |
|---|---|
| 1 | profiles table + API; agent `start_profile` (stock+mod, unpooled); desktop editor |
| 2 | pooled launch (proxy `X-Claudiverse-Pool` + lease); autostart |
| 3 | migrate the startup scripts, ipsum-fleet first |
| 4 | runner profiles |

Before phase 1, a **phase 0** brings the mod to the baseline: plugin options in place
of environment variables, automatic titles, server-assigned fields, the offline
backoff, and installing it as a user plugin so a plain `claude` loads it. That is
also what retires the `claude` alias to the patched binary.
