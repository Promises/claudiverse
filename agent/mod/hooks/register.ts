// claudiverse-seat — makes a STOCK Claude Code (2.1.287+, which has mods) a
// claudiverse seat, doing with the mods API what the in-place binary splices
// (patch-ref/tools/cvinject.py) do today:
//
//   register  session.start → POST /api/sessions: title, Claude's own session
//             id, version, host and folder (what the sidecar reports)
//   input     long-polls GET /api/seats/<title>/inbox (the semi seats' inbox):
//             200 → $.prompt.submit({ text, asUser }) (patch 003),
//             205 → $.turn.abort (interrupt, natively, no tmux Escape),
//             409 → another poller took this seat over; stop
//   mirror    every main-conversation row (session.append) → POST
//             /api/sessions/:id/mirror, and {"type":"idle"} when a turn ends,
//             which is what the server reads as ready for cv_send (002, 008/010);
//             a turn that died on an API error says so in its turn_complete
//   permission a permission prompt shows its dialog here AND is polled at POST
//             /api/hooks/seat/<title>/permissionrequest, so the apps can allow
//             or deny it; the first answer, here or there, wins.
//   question  an AskUserQuestion opens its dialog here AND is polled at POST
//             /api/hooks/seat/<title>/pretooluse until cv_answer or the app
//             answers (patch 007); the first answer, here or there, wins.
//   compact   {"type":"compact"} when the conversation is compacted (009)
//   command   /claudiverse: this seat's link to the server (005's mechanism;
//             patch 005 itself registers nothing today)
//
// Configured once per machine by the plugin's options (server_url, seat_token),
// so every `claude` becomes a seat with no environment variables. A launcher
// (a host agent starting a profile, cv-spawn) may still set CLAUDIVERSE_URL /
// _TOKEN / _TITLE / _HOST / _FLEET / _ORIGIN, and those win. With no title
// given, the seat is named after its folder plus the first four characters of
// its session id. No server configured: the mod does nothing.
//
// No server reachable: Claude Code works as stock; the status line reads
// "claudiverse offline" and the mod retries quietly (registration 30 s → 5 min,
// the inbox 5 s → 60 s) until the server answers. Session start waits on the
// server at most SERVER_WAIT_MS per request.
//
// Under the PATCHED binary (claude-rel), the runtime already connects the seat
// and sets CLAUDIVERSE_PATCHED_RUNTIME: the mod then stays inert, never a
// second registration or mirror.
//
// The validator follows `$` only into functions declared at the top of this
// file, so the helpers and the state they share live here, not in register.
import type { Register } from 'claude-code'

type Config = { url: string; token: string; title: string; host?: string; fleet?: string; origin?: string }
type Mirrored = Record<string, unknown> & { type: string }

const POLL_WAIT_S = 25 // the server caps a poll at 60 s
const RETRY_MS = 5000 // first inbox retry; doubles to POLL_RETRY_MAX_MS
const POLL_RETRY_MAX_MS = 60_000
const REGISTER_RETRY_MS = 30_000 // first registration retry; doubles to the max
const REGISTER_RETRY_MAX_MS = 300_000
const FLUSH_MS = 300 // batch the rows a burst produces into one POST
// How long session start waits on the server, per request: $.http.fetch has no
// timeout of its own, and an unreachable host holds a request about 30 s.
const SERVER_WAIT_MS = 3000
const MAX_BATCH = 200 // the server's limit per mirror call

let cfg: Config | null = null
let row: number | null = null // this seat's session id on the server
let turnId: string | null = null // the running turn, for an interrupt
let pollGen = 0 // bumped to retire a poll loop (a reload starts a new one)
let registration: Record<string, unknown> | null = null // what session.start registers, kept for retries
let pollFailures = 0
let pending: Mirrored[] = []
let flushScheduled = false
let titlePinned = false // CLAUDIVERSE_TITLE set by a launcher: /rename does not move the seat
let lastEffort: string | number | undefined // the main loop's effort, from its last model request
// The API error that is ending main's turn (classic.StopFailure, which fires
// just before its turn.complete; measured on 2.1.291): its kind and the text
// Claude Code shows, e.g. "API Error: ... (:no_available_auth)".
let turnError: { error: string; text?: string } | null = null
// This session's agents (forks, subagents, teammates) as the apps are told of
// them: what agent.spawn said (fork, background), and the last list sent.
const agentSpawns = new Map<string, { fork: boolean; background: boolean }>()
let agentsSent = ''
const agentEnded = new Set<string>()
let agentPoll = false
const AGENT_POLL_MS = 15_000
const TERMINAL = new Set(['completed', 'failed', 'killed'])
// This session's background work (shells, monitors, subagents, workflows) as
// the apps are told of it, by task id: a background Bash or Monitor call adds
// its task as it starts, TaskStop removes one, and at each end of main's turn
// the engine's own in-flight list (classic.Stop's background_tasks) replaces
// it. A finished shell wakes main with its notification, so that turn's end
// takes it off. Sent as {type: "background_tasks"} when it changes.
const background = new Map<string, Record<string, unknown>>()
let backgroundSent = ''

const enc = encodeURIComponent
const clean = (v: string | undefined) => (v || '').trim() || undefined
const headers = () => ({ authorization: `Bearer ${cfg!.token}`, 'content-type': 'application/json' })

// The apps' agent list: $.agent.list() as {type: "agents"}, sent when it
// changes, plus agent_ended once an agent reaches a terminal status. While an
// agent is still live this re-reads every AGENT_POLL_MS, because an agent can
// end with no event of its own here (a killed one, a background one).
async function syncAgents($: any) {
  if (row == null) return
  let list: any[]
  try {
    list = await $.agent.list()
  } catch {
    return
  }
  const agents = list.map((a: any) => ({
    agent_id: a.id,
    agent_type: a.type,
    description: a.description,
    name: a.name,
    fork: agentSpawns.get(a.id)?.fork ?? a.type === 'fork',
    background: agentSpawns.get(a.id)?.background ?? undefined,
    status: a.status,
  }))
  for (const a of agents) {
    if (TERMINAL.has(a.status) && !agentEnded.has(a.agent_id)) {
      agentEnded.add(a.agent_id)
      pending.push({ type: 'agent_ended', agent_id: a.agent_id, status: a.status })
    }
  }
  const json = JSON.stringify(agents)
  if (json !== agentsSent) {
    agentsSent = json
    pending.push({ type: 'agents', agents })
  }
  flush($)
  const live = agents.some((a) => !TERMINAL.has(a.status))
  if (live && !agentPoll) {
    agentPoll = true
    $.clock.after(AGENT_POLL_MS, () => {
      agentPoll = false
      syncAgents($)
    })
  }
}

function sendBackground($: any) {
  if (row == null) return
  const tasks = [...background.values()]
  const json = JSON.stringify(tasks)
  if (json === backgroundSent) return
  backgroundSent = json
  pending.push({ type: 'background_tasks', tasks })
  flush($)
}

const nowIso = async ($: any) => new Date(await $.clock.now()).toISOString()

// One inbox long-poll at a time; each answer schedules the next.
function poll($: any, gen: number, event?: string) {
  if (gen !== pollGen || !cfg) return
  const q = `wait=${POLL_WAIT_S}` + (event ? `&event=${enc(event)}` : '') +
    (cfg.host ? `&host=${enc(cfg.host)}` : '') + (cfg.fleet ? `&fleet=${enc(cfg.fleet)}` : '') +
    (cfg.origin ? `&origin=${enc(cfg.origin)}` : '')

  $.http.fetch(`${cfg.url}/api/seats/${enc(cfg.title)}/inbox?${q}`, { headers: headers() })
    .then(async (r: { status: number; text: string }) => {
      if (gen !== pollGen) return
      if (r.status === 200 && r.text.trim()) {
        deliver($, r.text)
      } else if (r.status === 205) {
        // The app's Interrupt. A failure here was silent, and an interrupt that
        // did nothing could not be told from one never sent (MEASURED
        // 2026-10-05: the server answered 205 mid-turn and the turn ran on).
        if (!turnId) $.ui.log('claudiverse: interrupt received, but no running turn is known')
        else await $.turn.abort({ turnId }).catch((err: unknown) =>
          $.ui.log(`claudiverse: interrupt failed for turn ${turnId}: ${String((err as any)?.message ?? err)}`))
      } else if (r.status === 409) {
        $.ui.log('claudiverse: another poller took this seat over; inbox stopped')
        return
      } else if (r.status !== 204) {
        return pollFailed($, gen)
      }
      if (pollFailures > 0) {
        // Back after an outage: the server may have restarted, so say hello again
        // (registration is idempotent by Claude's session id) and tell it we are
        // idle. A turn that ended while the server was out sent its idle into the
        // void, and a restarted server reads the seat's last stored state: busy.
        // MEASURED 2026-10-11: a deploy cut lorem-w2-t2086's stream, its turn died,
        // and its row read busy for 30 min, so every cv_send bounced.
        pollFailures = 0
        $.ui.status(`claudiverse · ${cfg!.title}`)
        await registerSeat($)
        idleAgain($)
      }
      poll($, gen)
    })
    .catch(() => pollFailed($, gen))
}

// The server marks a seat busy when it hands over a prompt, and only a
// finished turn reports it idle again. So whatever starts no turn reports idle
// itself, or every later cv_send bounces off a seat sitting at its prompt.
// MEASURED 2026-10-08: a cv_send of "/compact" was refused by prompt.submit
// (a "/" text would run a command as the user) and lorem-orchestrator read
// busy for 35 min.
function idleAgain($: any) {
  if (turnId || row == null) return
  pending.push({ type: 'idle' })
  flush($)
}

// Slash commands a supervisor may run on a seat by cv_send. Only /compact: it
// changes nothing but the context, and a long-running seat needs it. Any other
// "/" text is refused here as prompt.submit would refuse it (the server
// refuses it up front, so its sender is told).
const INBOX_COMMANDS = new Set(['compact'])

function deliver($: any, text: string) {
  const slash = text.trim().match(/^\/([A-Za-z][\w-]*)(?:\s+([\s\S]*))?$/)
  if (slash) {
    const [, command, args] = slash
    if (!INBOX_COMMANDS.has(command)) {
      $.ui.log(`claudiverse: /${command} from the inbox was not run (only ${[...INBOX_COMMANDS].map((c) => '/' + c).join(', ')} is)`)
      idleAgain($)
      return
    }
    // Queued until the session is idle, and it is not a turn: idle again after.
    $.command.run({ command, args: args ?? '' })
      .catch((err: unknown) => $.ui.log(`claudiverse: /${command} from the inbox failed: ${String((err as any)?.message ?? err)}`))
      .finally(() => idleAgain($))
    return
  }
  // Not awaited. A prompt delivered mid-turn is queued, and its submit
  // resolves only when that queued turn STARTS (measured on 2.1.291): the
  // inbox stopped for the rest of the running turn, the server took the
  // missing poll for a dead seat and stopped it 3 min later, and the app's
  // Interrupt, which arrives on this poll, could not reach the turn.
  $.prompt.submit({ text, asUser: true }).catch((err: unknown) => {
    $.ui.log(`claudiverse: could not submit an inbox prompt: ${String((err as any)?.message ?? err)}`)
    idleAgain($)
  })
}

// The retry names the seat's state as an inbox event ("Stop": no turn is
// running), which a restarted server reads as soon as the poll arrives; the
// idle row sent on recovery comes only when that poll is answered (up to
// POLL_WAIT_S later). A server that did not restart ignores the hint.
function pollFailed($: any, gen: number) {
  pollFailures += 1
  if (pollFailures === 2) $.ui.status('claudiverse offline')
  const wait = Math.min(RETRY_MS * 2 ** (pollFailures - 1), POLL_RETRY_MAX_MS)
  $.clock.after(wait, () => poll($, gen, turnId ? undefined : 'Stop'))
}

// What `work` resolves to, or `fallback` once `ms` pass first. `work` itself
// runs on: a caller that must not lose its result keeps hold of it.
function within<T>($: any, ms: number, work: Promise<T>, fallback: T): Promise<T> {
  return Promise.race([work, new Promise<T>((resolve) => $.clock.after(ms, () => resolve(fallback)))])
}

// The seat already registered for this Claude session id, if any: its title
// and origin. Null when there is none, or the server cannot say within
// SERVER_WAIT_MS: the session then starts under a derived name, as before this
// lookup existed.
async function seatOfSession($: any, url: string, token: string, sessionId: string): Promise<{ title: string; origin?: string } | null> {
  const lookup = (async () => {
    try {
      const r = await $.http.fetch(`${url.replace(/\/$/, '')}/api/seats/whoami?claude_session_id=${enc(sessionId)}`, {
        headers: { authorization: `Bearer ${token}` },
      })
      if (!r.ok) return null
      const s = JSON.parse(r.text)
      return typeof s?.title === 'string' && s.title ? { title: s.title, origin: s.origin ?? undefined } : null
    } catch {
      return null
    }
  })()
  return within($, SERVER_WAIT_MS, lookup, null)
}

// How long one question poll waits at the server: under the 30 s that
// $.http.fetch allows a request, whatever the server does (measured on
// 2.1.292: a keepalive written every 10 s did not extend it).
const QUESTION_POLL_S = 25
const PERMISSION_OUTAGE_MS = 15 * 60_000 // how long a permission poll waits out a server outage

// A poll that could not reach the server, or that a server error answered:
// wait and poll again. A server that is restarting refuses connections for a
// few seconds, then knows nothing of the question until the next poll names it.
// MEASURED 2026-10-07: 0.8.5 gave the question up on the first such failure, so
// claudiverse-android's question stayed at its terminal for 50 min, and the
// app's answer, sent after the restart, had no poll to go to.
const outage = (r: { status: number } | null) => r === null || r.status === 0 || r.status >= 500
const pause = ($: any, ms: number) => new Promise<void>((resolve) => $.clock.after(ms, () => resolve()))
const backoff = (failures: number) => Math.min(RETRY_MS * 2 ** (failures - 1), POLL_RETRY_MAX_MS)

// Poll the server for a remote answer to question `e` until one comes. The
// server's reply when it is an answer or a decline; null when the remote side
// is out: `stop` (answered at the terminal), the server's hold ended, or the
// server refused the question (a 4xx). An outage is waited out (`outage`).
// The terminal dialog decides alone meanwhile.
async function answerRemotely($: any, e: any, stop: { done: boolean }): Promise<any | null> {
  const body = JSON.stringify({
    tool_name: 'AskUserQuestion',
    tool_input: { questions: e.questions },
    tool_use_id: e.tool_use_id,
    // The agent that asks (a fork, a subagent); absent for main.
    agent_id: e.agentId,
    wait: QUESTION_POLL_S,
  })
  let failures = 0
  while (!stop.done) {
    let r: { status: number; ok: boolean; text: string } | null = null
    try {
      r = await $.http.fetch(`${cfg!.url}/api/hooks/seat/${enc(cfg!.title)}/pretooluse`, { method: 'POST', headers: headers(), body })
    } catch {
      r = null
    }
    if (stop.done) return null
    if (outage(r)) {
      await pause($, backoff(++failures))
      continue
    }
    failures = 0
    let reply: any = null
    try {
      reply = r!.ok ? JSON.parse(r!.text.trim() || '{}') : null
    } catch {
      reply = null
    }
    if (!reply) return null
    if (reply.pending) continue
    const decision = reply.hookSpecificOutput?.permissionDecision
    if (decision === 'deny' || (decision === 'allow' && reply.hookSpecificOutput.updatedInput?.answers)) return reply
    return null
  }
  return null
}

// Poll the server for a remote answer to permission prompt `e` (a classic
// PermissionRequest) until one comes: the hook's `{ decision }`, or null when
// the remote side is out (settled at the terminal, the seat's row gone, the
// server unreachable). Claude Code shows its dialog while this runs (measured
// on 2.1.292), and an answer returned later closes it.
async function decideRemotely($: any, e: any): Promise<any | null> {
  const url = `${cfg!.url}/api/hooks/seat/${enc(cfg!.title)}/permissionrequest`
  let requestId: string | null = null
  // Nothing here learns that the prompt was settled at the terminal while the
  // server is out, so an outage is waited out for a while, not for ever.
  const giveUpAt = (await $.clock.now()) + PERMISSION_OUTAGE_MS
  let failures = 0
  for (;;) {
    let r: { status: number; ok: boolean; text: string } | null = null
    try {
      const body = { tool_name: e.tool_name, tool_input: e.tool_input, permission_suggestions: e.permission_suggestions, agent_id: e.agent_id, wait: QUESTION_POLL_S,
        ...(requestId ? { request_id: requestId } : {}) }
      r = await $.http.fetch(url, { method: 'POST', headers: headers(), body: JSON.stringify(body) })
    } catch {
      r = null
    }
    if (outage(r)) {
      if ((await $.clock.now()) >= giveUpAt) return null
      await pause($, backoff(++failures))
      continue
    }
    failures = 0
    let reply: any = null
    try {
      reply = r!.ok ? JSON.parse(r!.text.trim() || '{}') : null
    } catch {
      reply = null
    }
    if (!reply) return null
    if (reply.pending && typeof reply.request_id === 'string') {
      requestId = reply.request_id
      continue
    }
    const decision = reply.hookSpecificOutput?.decision
    return decision?.behavior === 'allow' || decision?.behavior === 'deny' ? { decision } : null
  }
}

// The question was answered at the terminal: end the poll still waiting for
// it at the server, so the app no longer offers it.
async function withdrawQuestion($: any, toolUseId: string): Promise<void> {
  const sent = $.http
    .fetch(`${cfg!.url}/api/hooks/seat/${enc(cfg!.title)}/pretooluse`, {
      method: 'POST',
      headers: headers(),
      body: JSON.stringify({ tool_name: 'AskUserQuestion', tool_use_id: toolUseId, withdraw: true }),
    })
    .catch(() => null)
  await within($, SERVER_WAIT_MS, sent, null)
}

// POST the registration; true when the server has the seat. Idempotent: the
// server reuses the row with this Claude session id.
async function registerSeat($: any): Promise<boolean> {
  if (!cfg || !registration) return false
  try {
    const r = await $.http.fetch(`${cfg.url}/api/sessions`, { method: 'POST', headers: headers(), body: JSON.stringify(registration) })
    const created = r.ok ? JSON.parse(r.text) : null
    const id = created?.id ?? created?.session?.id ?? null
    if (id == null) return false
    row = id
    return true
  } catch {
    return false
  }
}

// Registration that failed (no server yet): retry with a growing delay, and
// start the inbox once it lands. The session works as stock meanwhile.
function registerUntilUp($: any, wait: number) {
  $.clock.after(wait, async () => {
    if (await registerSeat($)) goOnline($)
    else registerUntilUp($, Math.min(wait * 2, REGISTER_RETRY_MAX_MS))
  })
}

// The seat is registered: show it, report ready for cv_send, start the inbox.
function goOnline($: any) {
  $.ui.status(`claudiverse · ${cfg!.title}`)
  pending.push({ type: 'idle' })
  flush($)
  poll($, ++pollGen, 'SessionStart')
}

// Send what is pending now: a question must reach the server before its
// hold starts, or the app sees the hold with no question to answer.
async function flushNow($: any) {
  while (pending.length && row != null && cfg) {
    const batch = pending.splice(0, MAX_BATCH)
    await $.http.fetch(`${cfg.url}/api/sessions/${row}/mirror`, {
      method: 'POST', headers: headers(), body: JSON.stringify({ messages: batch }),
    }).catch(() => {})
  }
}

// Mirror what is pending, batched over FLUSH_MS. A lost batch only thins the
// mirror; it never touches the session.
function flush($: any) {
  if (flushScheduled || row == null || !cfg) return
  flushScheduled = true
  $.clock.after(FLUSH_MS, async () => {
    flushScheduled = false
    while (pending.length) {
      const batch = pending.splice(0, MAX_BATCH)
      await $.http.fetch(`${cfg!.url}/api/sessions/${row}/mirror`, {
        method: 'POST', headers: headers(), body: JSON.stringify({ messages: batch }),
      }).catch(() => {})
    }
  })
}

// Live text for the apps, as the patched runtime streams it: the step's
// chunks rebuilt as the API's stream events (content_block_start / _delta /
// _stop, message_stop). Pieces of one block that arrive within a flush window
// are merged into one delta, so a response is a few rows, not one per token;
// the finished message is mirrored whole by session.append as before.
function streamEvent(event: Record<string, unknown>) {
  pending.push({ type: 'stream_event', event })
}

function streamDelta(index: number, kind: string, field: string, text: string) {
  if (!text) return // thinking arrives empty where the build does not show it
  const last = pending[pending.length - 1] as any
  const d = last?.type === 'stream_event' && last.event.type === 'content_block_delta' && last.event.index === index ? last.event.delta : null
  if (d && d.type === kind) d[field] += text
  else streamEvent({ type: 'content_block_delta', index, delta: { type: kind, [field]: text } })
}

function streamChunk(c: any, open: Set<number>) {
  const start = (block: Record<string, unknown>) => {
    if (open.has(c.index)) return
    open.add(c.index)
    streamEvent({ type: 'content_block_start', index: c.index, content_block: block })
  }
  if (c.kind === 'text') {
    start({ type: 'text', text: '' })
    streamDelta(c.index, 'text_delta', 'text', c.text)
  } else if (c.kind === 'thinking') {
    start({ type: 'thinking', thinking: '' })
    streamDelta(c.index, 'thinking_delta', 'thinking', c.text)
  } else if (c.kind === 'tool') {
    start({ type: 'tool_use', id: c.id, name: c.name, input: {} })
  } else if (c.kind === 'input') {
    streamDelta(c.index, 'input_json_delta', 'partial_json', c.json)
  } else if (c.kind === 'stop') {
    for (const i of open) streamEvent({ type: 'content_block_stop', index: i })
    open.clear()
    streamEvent({ type: 'message_delta', delta: { stop_reason: c.stopReason } })
  }
}

export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    // The patched runtime already connects this seat.
    if (clean(await $.env.get('CLAUDIVERSE_PATCHED_RUNTIME'))) return next(e)

    // Literal names: the validator lists exactly which variables a mod reads.
    // A launcher's variables win over the plugin's options.
    const url = clean(await $.env.get('CLAUDIVERSE_URL')) || clean(options.server_url as string | undefined)
    const token = clean(await $.env.get('CLAUDIVERSE_TOKEN')) || clean(options.seat_token as string | undefined)
    if (!url || !token) return next(e)
    const sessionId = await $.session.id()
    const folder = (e.cwd.split('/').filter(Boolean).pop() || 'seat').replace(/[^A-Za-z0-9._-]+/g, '-')
    const pinned = clean(await $.env.get('CLAUDIVERSE_TITLE'))
    titlePinned = !!pinned
    // A plain `claude --resume` of a conversation that already has a seat keeps
    // that seat's name and placement: the row is reused by session id, and a
    // derived "<folder>-<id>" title and origin "plain" overwrote a named seat's
    // (unifi-basement-ap became vm_management-6830, 2026-10-07).
    const existing = pinned ? null : await seatOfSession($, url, token, sessionId)
    const title = pinned || existing?.title || `${folder}-${sessionId.slice(0, 4)}`
    cfg = {
      url: url.replace(/\/$/, ''),
      token,
      title,
      host: clean(await $.env.get('CLAUDIVERSE_HOST')),
      fleet: clean(await $.env.get('CLAUDIVERSE_FLEET')),
      origin: clean(await $.env.get('CLAUDIVERSE_ORIGIN')),
    }
    if (!cfg.host) {
      const r = await $.process.run(['hostname']).catch(() => null)
      cfg.host = r?.stdout.trim() || undefined
    }

    const v = await $.session.version()
    registration = {
      title: cfg.title,
      claude_session_id: sessionId,
      working_directory: e.cwd,
      client_version: `${v.version} (Claude Code) [claudiverse-mod]`,
      host: cfg.host,
      fleet: cfg.fleet,
      // No launcher named or placed this session: a `claude` typed in a
      // terminal. The server gives "plain" seats basic access by default
      // (Sessions.Access); the operator can grant more from the apps.
      // A resumed seat's origin is left as it was (absent is no news to the server).
      origin: cfg.origin ?? (titlePinned ? 'manual' : existing ? undefined : 'plain'),
      type: 'sidecar',
      // Set by a host agent starting a profile (cv-spawn --profile): the
      // server then fills fleet, notify and origin from the profile.
      profile_id: clean(await $.env.get('CLAUDIVERSE_PROFILE')),
      profile_revision: clean(await $.env.get('CLAUDIVERSE_PROFILE_REVISION')),
      tmux_session: clean(await $.env.get('CLAUDIVERSE_TMUX')),
    }

    await $.command.register({ name: 'claudiverse', description: "Shows this seat's link to the claudiverse server" })
    // Registration slower than SERVER_WAIT_MS does not hold up the session:
    // it goes on starting offline, and that same request settles the seat
    // when it answers, so no second registration races it.
    const registered = registerSeat($)
    if (await within($, SERVER_WAIT_MS, registered, false)) {
      goOnline($)
    } else {
      $.ui.status('claudiverse offline')
      registered.then((ok) => (ok ? goOnline($) : registerUntilUp($, REGISTER_RETRY_MS)))
    }
    return next(e)
  })

  // Main-conversation rows only: a subagent's rows carry an agentId.
  on('session.append', async ($, e, next) => {
    const stored = await next(e)
    const mirrored = row != null && (e.message.type === 'user' || e.message.type === 'assistant')
    // When the row was stored: the apps' message times and day dividers. The
    // append carries no time of its own, and the server's arrival time is late
    // by the flush wait, or by a whole outage for rows queued through one.
    const timestamp = mirrored ? new Date(await $.clock.now()).toISOString() : undefined
    if (row != null && e.agentId === undefined && (e.message.type === 'user' || e.message.type === 'assistant')) {
      // An assistant row carries what the apps show about the seat — the model
      // that answered and the effort it ran at — as the patched runtime
      // mirrors them; without them the app fell back to a stale effort (it
      // showed "medium" for a seat at "high"). The row itself has neither:
      // the model is its origin's, the effort the main loop's last request's.
      const model = e.origin?.kind === 'model' ? e.origin.model : undefined
      pending.push({
        type: e.message.type,
        uuid: stored?.uuid ?? e.uuid,
        timestamp,
        isMeta: e.message.isMeta || undefined,
        effort: e.message.type === 'assistant' ? lastEffort : undefined,
        message: { role: e.message.role, content: stored?.message?.content ?? e.message.content, ...(model ? { model } : {}) },
      })
      flush($)
    } else if (row != null && e.agentId !== undefined && (e.message.type === 'user' || e.message.type === 'assistant')) {
      // An agent's row: its own type, so main's transcript, busy/idle and
      // live reply stay main's (the patched runtime mixed a fork's rows into
      // main's). The inner row has main's shape, uuid included.
      const model = e.origin?.kind === 'model' ? e.origin.model : undefined
      pending.push({
        type: 'agent_message',
        agent_id: e.agentId,
        timestamp,
        message: {
          type: e.message.type,
          uuid: stored?.uuid ?? e.uuid,
          timestamp,
          isMeta: e.message.isMeta || undefined,
          message: { role: e.message.role, content: stored?.message?.content ?? e.message.content, ...(model ? { model } : {}) },
        },
      })
      flush($)
    }
    return stored
  })

  // A new agent: a fork, a subagent, a teammate. tool_use_id ties it to the
  // Agent call in its parent's transcript.
  // A background shell (run_in_background, Ctrl+B, or a timeout that moved it)
  // and a monitor are in the apps' list the moment they start, not only when
  // main's turn ends.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const r: any = await next(e)
    const id = r?.result?.backgroundTaskId
    if (row != null && typeof id === 'string') {
      background.set(id, { id, type: 'shell', status: 'running', description: e.description, command: e.command, started_at: await nowIso($) })
      sendBackground($)
    }
    return r
  })

  on('tool.call', { tool: 'Monitor' }, async ($, e, next) => {
    const r: any = await next(e)
    const id = r?.result?.taskId
    if (row != null && typeof id === 'string') {
      background.set(id, { id, type: 'monitor', status: 'running', description: e.description, command: e.command ?? e.ws?.url, started_at: await nowIso($) })
      sendBackground($)
    }
    return r
  })

  on('tool.call', { tool: 'TaskStop' }, async ($, e, next) => {
    const r: any = await next(e)
    const id = e.task_id ?? e.shell_id
    if (row != null && typeof id === 'string' && !r?.deny && !r?.isError && background.delete(id)) sendBackground($)
    return r
  })

  // What is still in flight as main's turn ends, by the engine's own count.
  // A task's start time is the one its call recorded here, if it was seen.
  on('classic.Stop', async ($, e: any, next) => {
    const r = await next(e)
    if (row != null && Array.isArray(e.background_tasks)) {
      const startedAt = new Map([...background].map(([id, t]) => [id, t.started_at]))
      background.clear()
      for (const t of e.background_tasks) {
        background.set(t.id, {
          id: t.id, type: t.type, status: t.status, description: t.description, command: t.command,
          agent_type: t.agent_type, server: t.server, tool: t.tool, name: t.name, started_at: startedAt.get(t.id),
        })
      }
      sendBackground($)
    }
    return r
  })

  on('agent.spawn', async ($, e, next) => {
    const r = await next(e)
    if (row != null && r?.agentId) {
      agentSpawns.set(r.agentId, { fork: e.fork, background: e.background })
      pending.push({
        type: 'agent_started',
        agent_id: r.agentId,
        agent_type: e.subagentType,
        description: e.description,
        name: e.name,
        fork: e.fork,
        background: e.background,
        parent_agent_id: e.parentAgentId,
        tool_use_id: e.tool_use_id,
      })
      flush($)
      syncAgents($)
    }
    return r
  })

  // 007: the question is answered here or in claudiverse, whichever comes
  // first. The terminal dialog opens at once (next) while the server is
  // polled for a remote answer; returning while next is pending aborts the
  // dialog, and an answer at the terminal withdraws the remote question. A
  // seat nobody watches waits for the app; a person at the terminal is never
  // locked out, and a server that is out leaves the dialog to decide alone.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    if (row == null || !cfg) return next(e)
    await flushNow($)
    $.ui.status(`claudiverse · ${cfg.title} · question sent: answer here or in claudiverse`)
    const stop = { done: false }
    const local = next(e).then(
      (result) => ({ result }),
      (error) => ({ error }),
    )
    const remote = answerRemotely($, e, stop).then((reply) => (reply ? { reply } : local))
    const first: any = await Promise.race([local, remote])
    stop.done = true
    $.ui.status(`claudiverse · ${cfg.title}`)
    if (!('reply' in first)) {
      await withdrawQuestion($, e.tool_use_id)
      if ('error' in first) throw first.error
      return first.result
    }
    const out = first.reply.hookSpecificOutput
    if (out.permissionDecision === 'deny') return { deny: out.permissionDecisionReason || 'declined via claudiverse' }
    // Answered remotely: the hook answers the call itself, and returning
    // aborts the dialog beneath. Core records this as the tool's result.
    return {
      result: {
        questions: e.questions,
        answers: out.updatedInput.answers,
        ...(out.updatedInput.annotations ? { annotations: out.updatedInput.annotations } : {}),
      },
    }
  })

  // A permission prompt is offered in claudiverse too, while its dialog shows
  // here: the apps can allow or deny it, and an answer at the terminal settles
  // it there (the server sees the tool's result in the mirror).
  // An AskUserQuestion's own dialog is a permission prompt too; it is not
  // relayed, because its question already is (tool.call above). Relayed, the
  // apps showed the question AND a card asking to allow it (MEASURED
  // 2026-10-10 by the operator on Failover's three-question ask).
  on('classic.PermissionRequest', async ($, e, next) => {
    if (row == null || !cfg || e.tool_name === 'AskUserQuestion') return next(e)
    await flushNow($)
    const remote = await decideRemotely($, e)
    return remote ?? next(e)
  })

  // 009: tell the server the context was dropped.
  on('session.compact', async ($, e, next) => {
    const r = await next(e)
    if (row != null) {
      pending.push({ type: 'compact' })
      flush($)
    }
    return r
  })

  // 005: a command of our own, answered with no turn.
  // /rename <name>: the seat follows the session's new name. Re-registering on
  // the same Claude session id updates this row's title; the inbox is keyed by
  // title, so the poll restarts under the new one. A launcher's
  // CLAUDIVERSE_TITLE wins (it is re-applied on every restart, so a rename
  // would revert), as on the patched runtime. A bare /rename (Claude picks
  // the name) is not followed: the mod cannot read the name it picked.
  on('command.run', { command: 'rename' }, async ($, e, next) => {
    const r = await next(e)
    const name = (e.args || '').trim().replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 64)
    if (!cfg || !registration || !name || name === cfg.title) return r
    if (titlePinned) {
      $.ui.log(`claudiverse: the seat keeps its launch title ${cfg.title} (CLAUDIVERSE_TITLE)`)
      return r
    }
    cfg.title = name
    registration.title = name
    if (await registerSeat($)) {
      $.ui.status(`claudiverse · ${name}`)
      poll($, ++pollGen)
    }
    return r
  })

  on('command.run', { command: 'claudiverse' }, async () => ({
    text: cfg
      ? `claudiverse: seat ${cfg.title} · session ${row ?? 'not registered'} · ${cfg.url}` +
        (cfg.host ? ` · host ${cfg.host}` : '') + (cfg.fleet ? ` · fleet ${cfg.fleet}` : '')
      : 'claudiverse: not configured (CLAUDIVERSE_URL, CLAUDIVERSE_TOKEN and CLAUDIVERSE_TITLE are needed)',
  }))

  // The main loop's model requests only (a subagent's are not the seat's
  // conversation). Every chunk is passed on unchanged; mirroring never
  // touches the session, and a failure in it only thins the live view.
  on('turn.step', async function* ($, e, next) {
    if (e.agentId === undefined) lastEffort = e.effort
    if (row == null || e.agentId !== undefined) return yield* next(e)
    const open = new Set<number>()
    streamEvent({ type: 'message_start', message: { role: 'assistant', model: e.model, content: [] } })
    for await (const c of next(e)) {
      try {
        streamChunk(c, open)
        flush($)
      } catch {}
      yield c
    }
    for (const i of open) streamEvent({ type: 'content_block_stop', index: i })
    streamEvent({ type: 'message_stop' })
    flush($)
  })

  // The process is leaving (/exit, ctrl+c, logout, a signal): end this row
  // now. A seat with no socket otherwise reads "running" until the server's
  // liveness check gives up on it (~3 min), next to the seat that replaced
  // it. Not on a /clear or an in-session resume: the process goes on (and no
  // session.start follows a /clear), so the row must stay. Within
  // session.end's short budget: what is pending, then the frame.
  on('session.end', async ($, e, next) => {
    if (row != null && cfg && e.reason !== 'clear' && e.reason !== 'resume') {
      pending.push({ type: 'session_ended', reason: e.reason, exit_code: 0 })
      await flushNow($).catch(() => {})
      row = null
    }
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    turnId = e.turnId
    turnError = null
    return next(e)
  })

  // The API error ending a turn: kept for that turn's turn_complete. A
  // subagent's runs end in a turn.complete of their own, never main's.
  on('classic.StopFailure', async ($, e: any, next) => {
    if (e.agent_id === undefined) turnError = { error: e.error, text: e.last_assistant_message }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    // An agent's turn ending is the agent's: up to 0.8.8 a fork finishing a
    // turn told the server main was idle and dropped main's turnId, so the
    // app's Interrupt could no longer reach a main turn still running.
    if (e.agentId !== undefined) {
      if (row != null) {
        pending.push({ type: 'agent_turn_complete', agent_id: e.agentId })
        flush($)
        syncAgents($)
      }
      return r
    }
    turnId = null
    // A turn that died on an API error (the pool empty, the stream cut) is
    // idle all the same, and says why, so the row reads truthfully and the
    // server's reject-busy delivery (a continue, a cv_send) reaches it.
    const failed = e.reason === 'error' ? { error: turnError?.error ?? 'unknown', error_text: turnError?.text } : {}
    turnError = null
    if (row != null) {
      pending.push({ type: 'turn_complete', reason: e.reason, ...failed }, { type: 'idle' })
      flush($)
    }
    return r
  })
}
