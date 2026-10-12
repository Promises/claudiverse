# Auto-resume

A seat whose turn died on a proxy or connection error gets one `continue`, sent by the server once it can serve the seat again. Without it such a seat sits idle at its prompt until someone types `continue`, and a runner may read the silence as a hung worker.

Two causes are covered, both seen by the [API proxy](api-proxy.md):

- **The pool was empty.** A pooled model call was refused with `no_available_auth`: every account was cooling or needed re-authorisation ([account-pool.md](account-pool.md)). Claude Code retries, then ends the turn on `API Error: ... cv-proxy: no pool account is available (:no_available_auth)`.
- **A server restart cut the stream.** A model response was streaming to the seat through the proxy when the server stopped. Claude Code ends the turn on a connection error once its retries meet a server that is still down.

## How it works

```mermaid
sequenceDiagram
    participant Seat as seat (Claude Code)
    participant P as ProxyPlug
    participant AR as AutoResume.Server
    participant DB as seat_stalls
    participant Room as the seat's Room

    Seat->>P: model call (main loop)
    alt the model answers (200)
        P->>AR: stream_started (cast)
        AR->>DB: in_flight: true; an open incident is closed
        P->>AR: stream_ended (cast), when the exchange ends
        AR->>DB: in_flight: false
    else no pool account
        P-->>Seat: 429 no_available_auth
        P->>AR: refused (cast)
        AR->>DB: state stalled, reason no_available_auth, waiting pool
    end
    Note over AR,DB: boot: every row still in_flight becomes<br/>stalled, reason server_restart, waiting grace
    AR->>Room: send_message("continue"), reject-busy,<br/>once the cause is over
    Room-->>AR: delivered / busy / not connected
    AR->>DB: nudged, or waiting busy / seat
```

- **What the proxy reports.** Only the main loop's model calls (`POST /v1/messages` from a seat named in the path): a subagent's call, a session title, a prompt suggestion or the startup quota probe ends no turn. A call is the main loop's when the seat sends `x-claude-code-request-class: main` (or `compaction`); without that header, when it carries no `x-claude-code-agent-id` and its body has tools (the main loop sends about 110, the others none). The body is not decoded for this: the proxy looks for the bytes `"tools":[{`. Reports are casts to `AutoResume.Server`, never on the request's path.
- **In flight.** `stream_started` when the model answers 200 and the response starts streaming; `stream_ended` when the exchange ends, however it ends. The server counts each seat's streams in memory and writes the row only when a seat goes from none to one, or from one to none.
- **A restart.** The application's `prep_stop` tells `AutoResume.Server` the server is stopping. From then on a stream that ends cut (the client gone, the upstream broken, or the relaying process killed with the VM) leaves its row `in_flight`; one that finishes whole while the server drains is cleared as always. At boot every row still `in_flight` becomes a restart incident: `stalled`, reason `server_restart`, `waiting: grace`, `stalled_at` = boot.
- **An empty pool.** A refusal with `no_available_auth` opens a pool incident: `stalled`, reason `no_available_auth`, `waiting: pool`. Claude Code retries a 429 several times; each retry is refused the same way and the incident stays as it was opened.
- **Nudging.** A stalled seat gets its `continue` when its cause is over:
  - a restart incident, once `grace_s` (60 s) have passed since boot, so the seat's own retries and its reconnection come first;
  - a pool incident, once the pool has an account to lease (`AnthropicAuths.pick/0` finds one): a weekly reset, an upgrade, a cooldown that ran out.

  The `continue` goes through the seat's reject-busy delivery (`Room.send_message/2`, as `cv_send`): an idle seat gets it now, a busy one when it next goes idle, an absent one when it is next seen. Only a running row with the same title and the same Claude session id gets it: a fresh conversation under that title has no dead turn to continue.
- **When it is checked.** Every 30 s; once more as the grace after boot ends; at every pool event (`AnthropicAuths.pool_topic/0`); and when a stalled seat goes idle or is seen alive (the Notifications Router passes `went_idle` and `seat_seen` on, as it does for [scheduled prompts](schedules.md)). The seat signals are checked against the stalled titles held in memory, so only a hit reads the database.
- **One nudge per seat per incident.** An incident closes when one of the seat's model calls is answered (`stream_started`), whether after the `continue`, the seat's own retry or a person typing. A seat whose `continue` fails again stays `nudged` and gets no second one in the same incident. Two things open a new one: a different cause (a restart incident whose `continue` meets an empty pool becomes a pool incident), and an account's **weekly** reset (pool event `reset` with `limit: weekly`), which re-arms a `nudged` pool incident once. A restart incident exists only at boot. So a pool that looks leasable but cannot lease (a token that will not refresh) costs one `continue`, never a loop.

### What the seat receives

Exactly `continue`, as a user prompt, the same as a person typing it. The delivery is recorded on the session as an event (`cv_events`, `kind: "auto_resume"`, `trigger` the reason) and in the log:

```text
[auto_resume] ipsum-worker-2: its stream was cut by the restart; a continue follows in 60 s
[auto_resume] ipsum-worker-2: sent continue to session 41 (server_restart)
[auto_resume] ipsum-worker-2 is answered again (server_restart, nudged); incident closed
```

### The seat's side

The `continue` reaches a seat only if the server reads it idle. Two things in the [claudiverse-seat mod](../services/mod/README.md) (0.11.0) make that true after these failures:

- A turn that died on an API error ends like any other: `turn_complete`, now with `reason: "error"`, the error's kind and its text, then `idle` ([mirroring.md](../services/mod/mirroring.md)).
- A turn that ended while the server was down sent its `idle` into the void, and a restarted Room restores the seat's last stored state, which was busy. After an outage the mod's retry poll names `Stop` as its inbox event, which a restarted Room reads as idle when the poll arrives, and its first good poll mirrors `idle` again ([outages-and-session-end.md](../services/mod/outages-and-session-end.md)).

## The records

`seat_stalls`, one row per seat title per user:

| Field | Meaning |
|---|---|
| `seat_title` | The seat's title, as the proxy path names it. |
| `claude_session_id` | The Claude session id of its last model call (`x-claude-code-session-id`). Only a running row with this id gets the `continue`. |
| `in_flight` | A model response is streaming to the seat now. |
| `state` | `clear` (its last model call was answered), `stalled` (an incident is open and the `continue` has not gone out), `nudged` (it went out; the incident stays open until a call is answered). |
| `reason` | `no_available_auth` or `server_restart`, while an incident is open. |
| `detail` | What the proxy or the boot said. |
| `stalled_at` | When the incident opened (for a restart, the boot). |
| `waiting` | For a `stalled` row, what the `continue` waits on: `grace`, `pool`, `seat` (no running row with this title and session, or not connected), `busy`. |
| `nudged_at`, `nudged_session_id` | When and to which session row the last `continue` went. |

See [data-model.md](data-model.md) for the columns and indexes.

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `config :claudiverse_server, ClaudiverseServer.AutoResume, enabled:` | `true` | `false`: no boot conversion, no ticks, no pool subscription (the test config does this; tests call `Server.boot/1` and `Server.tick/1`). |
| `... track:` | `true` | `false`: the proxy reports nothing. |
| `... grace_s:` | `60` | Seconds after boot before a seat whose stream the restart cut is nudged. |

The 30 s tick is a constant in `AutoResume.Server`.

## Failure modes and troubleshooting

- **A seat that died in a restart got no `continue`.** Its stream was not in flight when the server stopped: it was between model calls (running a tool), and its next call met the server down. Claude Code retries a refused connection for a while; if the server is down longer, the turn dies on `ECONNREFUSED` and nothing marks it. Not covered; send `continue` by hand.
- **A row reads `waiting: busy` for a long time.** The seat never reported idle. On a mod older than 0.11.0 a turn that ended during the outage left it busy; on the patched runtime the `cvstate` heartbeat corrects it. An app's force send reaches it.
- **A row reads `waiting: seat`.** No running row has that title and Claude session id. A seat restarted as a new conversation is not nudged by design; its row clears with its first answered call.
- **A pool incident reads `nudged` and the seat is idle on the pool error again.** Its `continue` was refused too (the pool emptied again, or the account could not be leased). It gets one more at the next weekly reset of an account, or when a person types.
- **A seat that ended a turn normally just as an empty pool refused a side call** (a title, a suggestion) without the request-class header and with tools in its body: it may be nudged once. The heuristic cannot tell such a call from the main loop's.
- **Only proxied seats.** A seat whose model calls do not pass the proxy is invisible here.

## Related pages

- [api-proxy.md](api-proxy.md): the proxy, pooled seats and their refusals
- [account-pool.md](account-pool.md): what makes an account leasable, and the pool events
- [notifications.md](notifications.md): `went_idle` and `seat_seen`
- [mirror-inbox-liveness.md](mirror-inbox-liveness.md): reject-busy delivery and the inbox hint
- [data-model.md](data-model.md)

## Source

- `claudiverse_server/lib/claudiverse_server/auto_resume.ex`
- `claudiverse_server/lib/claudiverse_server/auto_resume/server.ex`, `stall.ex`
- `claudiverse_server/lib/claudiverse_server_web/proxy_plug.ex` (`resume_key/5`, the `stream_*` and `refused` reports), `claudiverse_server/lib/claudiverse_server/proxy/request.ex` (`main_loop?/2`)
- `claudiverse_server/lib/claudiverse_server/application.ex` (`prep_stop/1`)
- `claudiverse_server/priv/repo/migrations/20261011180000_create_seat_stalls.exs`
- Tests: `claudiverse_server/test/claudiverse_server/auto_resume_test.exs`
