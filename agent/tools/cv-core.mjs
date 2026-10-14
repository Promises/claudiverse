// cv-core — shared client primitives for the Claudiverse orchestrator tools.
// Zero deps (Node ≥ 22 global fetch + WebSocket). Used by the MCP server.
// Readers are deliberately BOUNDED (limits + per-message caps) so an
// orchestrator never floods its context by pulling full logs.

const BASE_URL = (process.env.CLAUDIVERSE_URL || "http://localhost:4000").replace(/\/$/, "");
const TOKEN = process.env.CLAUDIVERSE_TOKEN || "";

// Exported so callers can NAME the endpoint in their own errors. A bare
// "fetch failed" is the same string whether the server is down, the token is
// wrong, or CLAUDIVERSE_URL was never exported and we are silently talking to a
// localhost default nobody chose. Measured 2026-08-16: three runners looked like
// a halt bug for ten minutes because the shell they were launched from had no
// CLAUDIVERSE_URL — the `--mcp` file configures the spawned WORKER, not the
// runner itself, so a correct-looking command line told nobody anything. The URL
// and whether it was defaulted are the two facts that separate those cases.
export const CV_BASE_URL = BASE_URL;
export const CV_URL_IS_DEFAULT = !process.env.CLAUDIVERSE_URL;
const WS_URL = BASE_URL.replace(/^http/, "ws") + "/socket/websocket";

function authHeaders(extra = {}) {
  return { Authorization: "Bearer " + TOKEN, ...extra };
}

// ── Bounded retry for TRANSPORT errors only ─────────────────────────────────
//
// Every cv_* call used to be a single attempt: a server restart (~10-15 s) or
// a network blip turned into "fetch failed" and, in a runner, a failed halt
// check or a lost report (fleet-control 30187-30191, 2026-10-02).
//
// ⛔ A blind retry of a WRITE can duplicate it: if the request reached the
// server and only the reply was lost, a second POST creates a second post or
// task. So writes retry only on errors that prove the connection was NEVER
// made, meaning the server cannot have seen the request. Reads (GET) are
// idempotent and also retry when the connection broke mid-flight. An HTTP
// status (4xx/5xx) is a server ANSWER, never retried here.
const NEVER_CONNECTED = new Set(["ECONNREFUSED", "ENOTFOUND", "EAI_AGAIN", "EHOSTUNREACH", "ENETUNREACH", "UND_ERR_CONNECT_TIMEOUT"]);
const BROKE_MID_FLIGHT = new Set(["ECONNRESET", "EPIPE", "UND_ERR_SOCKET", "UND_ERR_HEADERS_TIMEOUT", "UND_ERR_BODY_TIMEOUT", "TIMEOUT"]);
const RETRY_DELAYS_MS = [1000, 2000, 4000, 8000]; // ~15 s: covers a server restart

// Each attempt ends after this, answered or not. Without it a connection that
// is open but silent waits for undici's own limit, MEASURED 301 s on Node 24
// (UND_ERR_HEADERS_TIMEOUT), and a GET retries that 5×: a runner's halt check
// could sit ~25 min with nothing logged. CLAUDIVERSE_REQUEST_TIMEOUT_MS raises
// it for a caller with a slower endpoint.
const REQUEST_TIMEOUT_MS = Number(process.env.CLAUDIVERSE_REQUEST_TIMEOUT_MS) || 30_000;

function transportCode(e) {
  if (e?.name === "TimeoutError") return "TIMEOUT";
  return e?.cause?.code || e?.code || null;
}

async function fetchRetrying(url, init, idempotent) {
  for (let attempt = 0; ; attempt++) {
    try {
      // A timed-out WRITE is not retried (BROKE_MID_FLIGHT is for reads): the
      // server may have seen it.
      return await fetch(url, { ...init, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
    } catch (e) {
      const code = transportCode(e);
      const retryable = NEVER_CONNECTED.has(code) || (idempotent && BROKE_MID_FLIGHT.has(code));
      if (!retryable || attempt >= RETRY_DELAYS_MS.length) {
        if (code === "TIMEOUT") e = new Error(`no answer within ${REQUEST_TIMEOUT_MS / 1000} s`, { cause: e });
        if (code && e instanceof Error && !e.message.includes(code)) e.message += ` (${code}, after ${attempt + 1} attempt(s))`;
        throw e;
      }
      await new Promise((r) => setTimeout(r, RETRY_DELAYS_MS[attempt]));
    }
  }
}

async function api(path) {
  const res = await fetchRetrying(BASE_URL + path, { headers: authHeaders() }, true);
  if (!res.ok) throw new Error(`GET ${path} → ${res.status} ${res.statusText}`);
  return res.json();
}

async function postApi(path, body) {
  const res = await fetchRetrying(BASE_URL + path, {
    method: "POST",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(body),
  }, false);
  if (!res.ok) throw new Error(`POST ${path} → ${res.status} ${res.statusText}`);
  return res.json();
}

async function patchApi(path, body) {
  const res = await fetchRetrying(BASE_URL + path, {
    method: "PATCH",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(body),
  }, false);
  if (!res.ok) throw new Error(`PATCH ${path} → ${res.status} ${res.statusText}`);
  return res.json();
}

async function deleteApi(path) {
  const res = await fetchRetrying(BASE_URL + path, {
    method: "DELETE",
    headers: authHeaders(),
  }, false);
  if (!res.ok) throw new Error(`DELETE ${path} → ${res.status} ${res.statusText}`);
  return res.json();
}

export async function listSessions(title) {
  const q = title ? "?title=" + encodeURIComponent(title) : "";
  const { sessions } = await api("/api/sessions" + q);
  return sessions || [];
}

export async function resolveSession(arg) {
  const literal = String(arg).replace(/^#/, "");
  if (/^\d+$/.test(literal)) return Number(literal);
  const matches = await listSessions(arg);
  if (!matches.length) throw new Error(`no session titled "${arg}"`);
  return (matches.find((s) => s.status === "running") || matches[0]).id;
}

// One-shot: join as observer, grab the replay buffer, close.
function fetchReplay(sessionId) {
  return new Promise((resolve, reject) => {
    const topic = "session:" + sessionId;
    const ws = new WebSocket(WS_URL + "?token=" + encodeURIComponent(TOKEN) + "&vsn=2.0.0");
    let ref = 0;
    const joinRef = String(++ref);
    let done = false;
    const finish = (fn, v) => { if (!done) { done = true; try { ws.close(); } catch {} fn(v); } };
    ws.addEventListener("open", () =>
      ws.send(JSON.stringify([joinRef, String(++ref), topic, "phx_join", { role: "observer" }]))
    );
    ws.addEventListener("message", (ev) => {
      const f = JSON.parse(ev.data);
      if (f[2] !== topic) return;
      if (f[3] === "phx_reply" && f[4]?.status === "error") finish(reject, new Error("join rejected"));
      if (f[3] === "replay") finish(resolve, f[4]?.messages || []);
    });
    ws.addEventListener("error", () => finish(reject, new Error("ws error")));
    setTimeout(() => finish(reject, new Error("replay timeout")), 5000);
  });
}

// One-shot: join as observer, fire one event, flush, close.
// Push `event` on the session's channel. Resolves with the server's reply to
// it ({status: "ok"|"error", response}) when it sends one, else null after
// 500 ms (an event the server does not answer). answer/decline are answered:
// their reply says whether anything was waiting for them.
function sendEvent(sessionId, event, payload) {
  return new Promise((resolve, reject) => {
    const topic = "session:" + sessionId;
    const ws = new WebSocket(WS_URL + "?token=" + encodeURIComponent(TOKEN) + "&vsn=2.0.0");
    let ref = 0;
    const joinRef = String(++ref);
    let pushRef = null;
    const done = (v) => { try { ws.close(); } catch {} resolve(v); };
    ws.addEventListener("open", () =>
      ws.send(JSON.stringify([joinRef, String(++ref), topic, "phx_join", { role: "observer" }]))
    );
    ws.addEventListener("message", (ev) => {
      const f = JSON.parse(ev.data);
      if (f[2] !== topic || f[3] !== "phx_reply") return;
      if (pushRef === null) {
        pushRef = String(++ref);
        ws.send(JSON.stringify([joinRef, pushRef, topic, event, payload]));
        setTimeout(() => done(null), 3000);
      } else if (f[1] === pushRef) {
        done(f[4] || null);
      }
    });
    ws.addEventListener("error", () => reject(new Error("ws error")));
    setTimeout(() => reject(new Error("send timeout")), 6000);
  });
}

// --- bounded rendering -------------------------------------------------------

function cap(s, n) {
  s = String(s || "");
  return s.length > n ? s.slice(0, n) + "…" : s;
}

function textOf(content, perBlock) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((b) => {
      if (b.type === "text") return b.text;
      if (b.type === "tool_use") return `[tool ${b.name} ${cap(JSON.stringify(b.input), 100)}]`;
      if (b.type === "tool_result") return "[tool_result]";
      if (b.type === "thinking") return "[thinking]";
      return "";
    })
    .filter(Boolean)
    .join("\n")
    .slice(0, perBlock);
}

// EVERY line carries its speaker, not just the first line of a message.
//
// 🔴 WHY: this used to push a whole multi-line message as ONE entry —
// `lines.push("assistant> " + s)` where s contains newlines. Only the FIRST line
// got a prefix; every continuation line rendered BARE. A bare line at the bottom
// of a tail is indistinguishable from a standalone utterance by nobody, and that
// is exactly what the fleet spent two days calling an "unsourced render artifact"
// and building rules around: four separate lines were refused as unattributable,
// and a watcher once escalated three times at a compliant agent because a real
// report's continuation line read as a stray imperative.
//
// A reader cannot recover the speaker from the text — the information was simply
// not emitted. Prefixing every line makes an unattributed line STRUCTURALLY
// IMPOSSIBLE rather than merely unlikely, so no discipline is needed to spot one.
const prefixEvery = (speaker, s) =>
  s
    .split("\n")
    .map((l) => `${speaker}> ${l}`)
    .join("\n");

function renderMeaningful(messages, { limit, perMsg }) {
  const lines = [];
  for (const m of messages) {
    if (m.type === "turn_complete") lines.push("── turn complete ──");
    else if (m.type === "assistant") {
      const s = textOf(m.message?.content, perMsg);
      if (s.trim()) lines.push(prefixEvery("assistant", s));
    } else if (m.type === "user") {
      const s = textOf(m.message?.content, perMsg);
      if (s.trim()) lines.push(prefixEvery("user", s));
    }
  }
  // NOTE: limit counts MESSAGES, not display lines — one entry per message, even
  // though an entry may render as many lines. That is why `cv_last n=2` shows so
  // little: it is two messages, and if the last is one line you see one line.
  return lines.slice(-limit);
}

// last `limit` meaningful lines, each capped at `perMsg` chars
export async function tail(sessionId, limit = 10, perMsg = 400) {
  const messages = await fetchReplay(sessionId);
  const lines = renderMeaningful(messages, { limit, perMsg });
  return lines.length ? lines.join("\n") : "(nothing in buffer)";
}

// the latest AskUserQuestion (compact)
export async function questions(sessionId) {
  const messages = await fetchReplay(sessionId);
  let last = null;
  for (const m of messages)
    if (m.type === "assistant")
      for (const b of m.message?.content || [])
        if (b.type === "tool_use" && b.name === "AskUserQuestion") last = b;
  if (!last) return null;
  return { tool_use_id: last.id, questions: last.input?.questions || [] };
}

// Reject-busy: returns { status: "delivered" | "busy" | "error", hint? }.
export const send = (id, text) => postApi("/api/notify/send", { session_id: id, content: text });
export const answer = (id, text) => sendEvent(id, "answer", { response: text });
export const decline = (id) => sendEvent(id, "decline", {});

export const subscribe = (self, watch, mode) => postApi("/api/notify/subscribe", { self, watch, ...(mode ? { mode } : {}) });
// Clears only pings `self` was shown (listed by `pending`); with `{ acted: true }`
// (cv_send/cv_answer/cv_decline on `target`), that title's queued pings.
// Answers {cleared, kept}.
export const ack = (self, target, extra = {}) => postApi("/api/notify/ack", { self, target, ...extra });
export const pending = (self) => api("/api/notify/pending?self=" + encodeURIComponent(self));
// GitHub: what this user's seats watch (gh: titles, @github) and the token that
// reads each; every repository the operator's tokens reach.
export const githubSubscriptions = () => api("/api/github/subscriptions");
export const githubRepos = () => api("/api/github/repos");
export const report = (self, text) => postApi("/api/notify/report", { self, text });
// One seat, by title, whether it watches anything or not: a runner's
// escalation to the seat that wrote the task. 404 for a title not the user's.
export const notifyDirect = (self, to, text) => postApi("/api/notify/direct", { self, to, text });

// Ask the operator to come to this seat (the app notifies their phone). A
// refusal (403) is returned, not thrown, so the caller can say why.
// 🔴 THE HTTP STATUS IS `http`, NOT `status`: the body carries its own
// "status": "open", and spreading it over an HTTP `status` made every SUCCESS
// read as "NOT requested (open)" — measured on ipsum-admin 2026-10-03, request 3,
// which the server had stored and notified.
export async function requestHuman(self, summary, detail) {
  const res = await fetchRetrying(BASE_URL + "/api/human_requests", {
    method: "POST",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ self, summary, detail }),
  }, false);
  const body = await res.json().catch(() => ({}));
  return { ...body, http: res.status };
}

// --- forum -------------------------------------------------------------------
// A persistent, DB-backed discussion forum. Reading/searching is pull (no
// alert); subscribing routes new-post pings through the native idle path.
const qs = (params) =>
  Object.entries(params)
    .filter(([, v]) => v !== undefined && v !== null && v !== "")
    .map(([k, v]) => encodeURIComponent(k) + "=" + encodeURIComponent(v))
    .join("&");

export const forumChannels = () => api("/api/forum/channels");
export const forumCreateChannel = (slug, title, description) =>
  postApi("/api/forum/channels", { slug, title, description });
// Top-level posts may double as task cards: pass title/status/owner to seed one.
export const forumPost = (self, channel, body, parent_id, extra = {}) =>
  postApi("/api/forum/posts", { self, channel, body, parent_id, ...extra });
// Read opts: { limit, before, status, owner, compact, include_archived }.
export const forumRead = (channel, opts = {}) =>
  api(`/api/forum/channels/${encodeURIComponent(channel)}/posts?` + qs(opts));
// Fetch one post by id; pass thread=true to also get its replies (whole thread
// when id is a top-level post).
export const forumGet = (id, thread) =>
  api(`/api/forum/posts/${encodeURIComponent(id)}?` + qs({ thread: thread ? 1 : undefined }));
// apiWithError, not api(): a refused query (400, e.g. too many terms) must reach
// the caller as its explanatory error, not as a bare "400 Bad Request" throw.
export const forumSearch = (q, channel, limit) =>
  apiWithError("/api/forum/search?" + qs({ q, channel, limit }));

// ── the HALT board ────────────────────────────────────────────────────────────
//
// The fleet brake lives here, not in cv-runner, for ONE reason: more than one
// program needs to ask "is this fleet halted?" — the runner before it claims, and
// the fleet launcher before it starts four detached sessions that would each
// start cleanly and then never claim.
//
// ⚠️ A SECOND IMPLEMENTATION WOULD BE WORSE THAN NO CHECK. Two parsers that agree
// prove only that they share a spec, not that the spec is right — and a launcher
// whose halt predicate had drifted from the runner's would confidently report
// "clear" for a board that stops every slot it just started. One definition,
// imported by both.
export const HALT_CHANNEL = "fleet-control";
// 50 is the server's own max_read_limit; asking for more is silently clamped.
// This window is a CORRECTNESS boundary: a halt that falls off the end of it
// fails OPEN, so callers should warn when the window comes back full.
export const HALT_WINDOW = 50;

// Words that mean "every fleet". `HALT[*]` and `HALT[all]` are what a human
// reaches for when they mean "stop everything", and before these were handled
// they did the exact OPPOSITE — parsed as a scope naming no live fleet, so they
// bound nobody. Found by audit, not by review.
const HALT_SCOPE_ALL = new Set(["*", "all", "any", "every", "fleet", "global"]);
// A well-formed fleet token. Anything else in the tag means the tag cannot be
// trusted at all, so the whole halt is treated as GLOBAL rather than as a scope
// that happens not to name us.
const HALT_SCOPE_TOKEN = /^[a-z0-9][a-z0-9._-]*$/;

// Does this HALT post bind a runner on `fleet`? (fleet null/"" => unscoped.)
//
// 🔴 THE ONLY DANGEROUS DIRECTION IS UNDER-STOPPING, so every uncertain case
// returns true. An audit found two ways the first version under-stopped, both via
// the same hole: a tag that PARSES into a non-empty list naming no live fleet
// skipped the empty-tag fallback and quietly bound nobody.
//   "HALT[[ipsum-fleet]"  -> capture "[ipsum-fleet" -> non-empty -> bound nobody
//   "HALT[*]"    -> capture "*"   -> non-empty -> bound nobody
// Presence of the empty-tag guard was not the question; what a MALFORMED-BUT-
// NON-EMPTY tag did was. Charset-validating each token closes both.
//
// ⚠️ NOT REACHABLE BY ANY CHECK HERE: a well-formed tag naming the WRONG fleet
// ("HALT[pe2]" meant as "ipsum-fleet") is indistinguishable from a halt that legitimately
// does not concern you, and binds nobody. Only a registry of live fleet names
// could catch it. If a halt seems not to have taken, SUSPECT THE SPELLING FIRST.
export function haltBindsFleet(title, fleet) {
  const tag = /^HALT\s*\[([^\]]*)\]/.exec(title);
  if (!tag) return true; // bare "HALT …", or a tag too broken to parse => global
  if (!fleet) return true; // unscoped runner => bound by everything
  const scopes = tag[1]
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  if (!scopes.length) return true; // "HALT[]", "HALT[ , ]" => global
  if (scopes.some((s) => HALT_SCOPE_ALL.has(s))) return true; // "HALT[*]" => global
  // One unusable token poisons the whole tag. A scope we cannot parse is not
  // evidence that we are out of scope — it is evidence we do not know.
  if (scopes.some((s) => !HALT_SCOPE_TOKEN.test(s))) return true;
  return scopes.includes(String(fleet).toLowerCase());
}

// Is a post a live halt at all? Title-prefix + not archived — the retitle-in-place
// convention for lifting a halt relies on exactly this predicate, so it lives
// beside it rather than being re-spelled at each call site.
export const isLiveHalt = (p) => (p?.title || "").startsWith("HALT") && !p?.archived;
// Subscribe channel-scoped (no post_id → new top-level posts) or thread-scoped
// (post_id → that thread's replies).
export const forumSubscribe = (self, channel, post_id) =>
  postApi("/api/forum/subscribe", { self, channel, post_id });
export const forumUnsubscribe = (self, channel, post_id) =>
  postApi("/api/forum/unsubscribe", { self, channel, post_id });
// What THIS agent is subscribed to: { channels: [...], threads: [...] }.
export const forumMySubscriptions = (self) =>
  api("/api/forum/subscriptions?" + qs({ self }));

// --- forum work-tracker mutations -------------------------------------------
// Edit a post in place; prune (delete/archive); status/owner/pin/resolve. All
// Bearer-gated server-side; any fleet member may act (shared account).
export const forumEdit = (id, fields = {}) =>
  patchApi(`/api/forum/posts/${encodeURIComponent(id)}`, fields);
export const forumDelete = (id) =>
  deleteApi(`/api/forum/posts/${encodeURIComponent(id)}`);
export const forumArchive = (id) =>
  postApi(`/api/forum/posts/${encodeURIComponent(id)}/archive`, {});
export const forumUnarchive = (id) =>
  postApi(`/api/forum/posts/${encodeURIComponent(id)}/unarchive`, {});
export const forumPin = (id) =>
  postApi(`/api/forum/posts/${encodeURIComponent(id)}/pin`, {});
export const forumUnpin = (id) =>
  postApi(`/api/forum/posts/${encodeURIComponent(id)}/unpin`, {});
export const forumResolve = (id) =>
  postApi(`/api/forum/posts/${encodeURIComponent(id)}/resolve`, {});
export const forumSetStatus = (id, status) =>
  postApi(`/api/forum/posts/${encodeURIComponent(id)}/status`, { status });
// `self` (the assigner) lets the server ping the new owner — unless self IS the
// new owner — without spamming the rest of the channel.
export const forumAssign = (id, owner, self) =>
  postApi(`/api/forum/posts/${encodeURIComponent(id)}/assign`, { owner, self });

// ATOMIC claim-if-unowned. Use this to TAKE a task; use forumAssign only to
// REASSIGN one you already control.
//
// Deliberately NOT built on postApi: that throws on any non-2xx, and a 409 here
// is not an error — it is the correct, expected answer for every runner but one.
// Throwing would turn "someone else got it" into an exception indistinguishable
// from a network failure, and the caller would have to parse a message string to
// tell a lost race from a dead server.
//
// Returns { claimed: true, post } | { claimed: false, heldBy } | { claimed: false, notFound: true }
// and THROWS only on a genuine transport/server fault, which is the one case the
// caller must not treat as a verdict.
export async function forumClaim(id, owner, self) {
  const res = await fetchRetrying(`${BASE_URL}/api/forum/posts/${encodeURIComponent(id)}/claim`, {
    method: "POST",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ owner, self }),
  }, false);
  if (res.status === 409) {
    const body = await res.json().catch(() => ({}));
    // notClaimable: the post is no longer a task to take (done, archived),
    // which the server now checks in the claim itself.
    return { claimed: false, heldBy: body.held_by ?? null, notClaimable: body.not_claimable ?? null };
  }
  if (res.status === 404) return { claimed: false, notFound: true };
  if (!res.ok) throw new Error(`POST claim ${id} → ${res.status} ${res.statusText}`);
  const body = await res.json();
  return { claimed: true, post: body.post };
}

// --- handoffs ----------------------------------------------------------------
// Per-agent continuity state. PULL-ONLY: setting a handoff pings nobody. `set`
// is scoped to the caller's own role (self) server-side. `get` is used on
// takeover to resume a role losslessly.
export const handoffSet = (self, body) =>
  postApi("/api/forum/handoff/set", { self, body });
// ⚠️ A 404 here means ABSENT — the role has never written a handoff — and is
// returned as a value, not thrown. api() throws on every non-2xx, which made a
// clean "no handoff yet" indistinguishable from a failed read: cv-runner's reap
// gate logged "handoff is UNREADABLE (read failed)" for a plain 404, and a
// watcher then chased corruption that did not exist. Only the 404 is changed;
// any OTHER failure still throws, so a real read failure stays loud.
// Callers that already treat a throw as "absent" (cv-mcp's stop and task_done
// gates) see the same branch via the null handoff; cv_handoff_get's existing
// `r.error` check now fires instead of a raw exception.
export const handoffGet = async (role, history) => {
  const path = `/api/forum/handoff/${encodeURIComponent(role)}?` + qs({ history });
  const res = await fetchRetrying(BASE_URL + path, { headers: authHeaders() }, true);
  if (res.status === 404) {
    const body = await res.json().catch(() => ({}));
    return { handoff: null, status: 404, error: body.error || `no handoff for ${role}` };
  }
  if (!res.ok) throw new Error(`GET ${path} → ${res.status} ${res.statusText}`);
  return res.json();
};
export const handoffList = () => api("/api/forum/handoffs");
export const status = (id) => api("/api/notify/status?session_id=" + encodeURIComponent(id));

// --- knowledge store -------------------------------------------------------
// Durable, versioned documents, distinct from the forum feed. A post is a
// moment; a document is a current best statement. Documents are returned WHOLE
// — the ~1,500-char cap is a feed affordance and applying it here would drop
// exactly the bound/derived_under fields that qualify a claim, because the cut
// is tail-biased.

// Unlike api(), this surfaces the RESPONSE BODY on a non-2xx instead of
// throwing a bare status. Needed because /api/kb/search answers a malformed
// query with 400 + a hint, and collapsing that into an exception would make
// "your query was malformed" indistinguishable from "no such knowledge" — the
// exact ambiguity the endpoint exists to avoid.
async function apiWithError(path) {
  const res = await fetchRetrying(BASE_URL + path, { headers: authHeaders() }, true);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) return { ...body, _status: res.status, _failed: true };
  return body;
}

async function postWithError(path, payload) {
  const res = await fetchRetrying(BASE_URL + path, {
    method: "POST",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(payload),
  }, false);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) return { ...body, _status: res.status, _failed: true };
  return body;
}

async function sendWithError(method, path, payload) {
  const res = await fetchRetrying(BASE_URL + path, {
    method,
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: payload === undefined ? undefined : JSON.stringify(payload),
  }, false);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) return { ...body, _status: res.status, _failed: true };
  return body;
}

// Scheduled prompts (server: ScheduleController). `self` names the calling
// seat; a seat may only manage schedules that target itself. Every call
// returns the server's refusal ({_failed, _status, error}) instead of throwing.
const scheduleRef = (ref) => "/api/schedules/" + encodeURIComponent(String(ref));
export const scheduleAdd = (body) => postWithError("/api/schedules", body);
export const scheduleList = (self, target, full) =>
  apiWithError("/api/schedules?" + qs({ self, target, full: full ? "true" : undefined }));
export const scheduleGet = (self, ref) => apiWithError(scheduleRef(ref) + "?" + qs({ self }));
export const scheduleUpdate = (self, ref, fields) => sendWithError("PATCH", scheduleRef(ref), { ...fields, self });
export const scheduleRemove = (self, ref) => sendWithError("DELETE", scheduleRef(ref) + "?" + qs({ self }));
export const scheduleRuns = (self, ref, limit) => apiWithError(scheduleRef(ref) + "/runs?" + qs({ self, limit }));

// A runner slot's heartbeat (server: ClaudiverseServer.Runners). Returns a
// failure rather than throwing; a lost heartbeat must never stop a runner.
export const runnerHeartbeat = (report) => postWithError("/api/runners/heartbeat", report);

// Which seat this process belongs to, and its tool policy (server:
// SeatController.whoami). `query` is "claude_session_id=..." or "title=...".
export const whoami = (query) => apiWithError("/api/seats/whoami?" + query);

export const kbCreate = (doc) => postWithError("/api/kb/documents", doc);
export const kbGet = (id, withAnchors) =>
  apiWithError(`/api/kb/documents/${encodeURIComponent(id)}?` + qs({ with_anchors: withAnchors ? 1 : undefined }));
export const kbAddRevision = (id, fields) =>
  postWithError(`/api/kb/documents/${encodeURIComponent(id)}/revisions`, fields);
export const kbHistory = (id) => apiWithError(`/api/kb/documents/${encodeURIComponent(id)}/history`);
export const kbSearch = (q, limit, scope) => apiWithError("/api/kb/search?" + qs({ q, limit, scope }));
export const kbAnchor = (type, value) =>
  apiWithError(`/api/kb/anchors/${encodeURIComponent(type)}/${encodeURIComponent(value)}`);
// Accepts `from`/`to` as slugs or ids — the server resolves them, so callers
// never have to know internal row ids (and cannot resolve the wrong one).
export const kbRelate = (rel) => postWithError("/api/kb/relations", rel);
export const kbStale = () => apiWithError("/api/kb/stale");
export const kbCheck = (check) => postWithError("/api/kb/checks", check);
export const kbAddress = (address, build) =>
  apiWithError(`/api/kb/address/${encodeURIComponent(address)}?` + qs({ build }));
export const kbRecordSymbol = (sym) => postWithError("/api/kb/symbols", sym);

// ── Component B — submissions ────────────────────────────────────────────────
// Durability arrives when subSubmit resolves, not when a git ref survives a reap.
export const subSubmit = (s) => postWithError("/api/kb/submissions", s);
export const subGet = (id) => apiWithError(`/api/kb/submissions/${id}`);
export const subList = (f) => apiWithError("/api/kb/submissions?" + qs(f || {}));
export const subGate = (id, g) => postWithError(`/api/kb/submissions/${id}/gates`, g);
export const subIntegrate = (id, b) => postWithError(`/api/kb/submissions/${id}/integrate`, b);
export const subRevert = (id, b) => postWithError(`/api/kb/submissions/${id}/revert`, b);
export const subBlindGates = () => apiWithError("/api/kb/submissions/blind-gates");

// ── Component E — tasks ──────────────────────────────────────────────────────
export const taskCreate = (t) => postWithError("/api/tasks", t);
export const taskList = (f) => apiWithError("/api/tasks?" + qs(f || {}));
export const taskShow = (id) => apiWithError(`/api/tasks/${id}`);
export const taskReady = (id, actor) => postWithError(`/api/tasks/${id}/ready`, { actor });
export const taskDep = (id, b) => postWithError(`/api/tasks/${id}/deps`, b);
export const taskChain = (id) => apiWithError(`/api/tasks/${id}/chain`);
export const taskHealth = (b) => postWithError("/api/tasks/health", b);
export const taskClaim = (b) => postWithError("/api/tasks/claim", b);
export const taskStart = (id, b) => postWithError(`/api/tasks/${id}/start`, b);
export const taskProgress = (id, b) => postWithError(`/api/tasks/${id}/progress`, b);
export const taskComplete = (id, b) => postWithError(`/api/tasks/${id}/complete`, b);
export const taskRelease = (id, b) => postWithError(`/api/tasks/${id}/release`, b);
export const kbResolveSymbol = (name, build) =>
  apiWithError(`/api/kb/symbols/${encodeURIComponent(name)}?` + qs({ build }));
