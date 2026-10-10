#!/usr/bin/env node
//
// cvctl — Claudiverse orchestrator CLI
//
// A thin client over the Claudiverse server's *observer* protocol. It lets one
// process (a human, a shell loop, or an orchestrating Claude) watch the
// mirrored message stream of a running Claude Code instance and inject prompts
// into it — the read + write halves needed to make one agent drive others.
//
// It speaks the same Phoenix v2 channel protocol as the patched SidecarClient,
// but joins with role "observer" instead of "sidecar". Zero dependencies:
// Node 24 ships global fetch + global WebSocket.
//
// Env:
//   CLAUDIVERSE_URL    Server base URL        (default http://localhost:4000)
//   CLAUDIVERSE_TOKEN  Bearer token           (required)
//
// Commands:
//   cvctl list                       List your sessions (id, title, status)
//   cvctl resolve <name|#id>         Print the numeric session id for a title
//   cvctl watch   <name|#id> [--json]        Stream messages live until Ctrl-C
//   cvctl tail    <name|#id> [--limit N] [--json]  Print recent buffer, exit
//   cvctl send    <name|#id> <text...>       Inject a user turn, then exit
//
// A <name> is matched against session titles (the CLAUDIVERSE_TITLE an instance
// was launched with); the newest *running* match wins. A "#123" or bare number
// is treated as a literal session id.
//
// Orchestration note: messages the orchestrator injects come back through the
// mirror as type "user". To avoid reacting to your own input, an orchestrator
// should key off type "assistant" and "turn_complete" and ignore "user"/"system".

const BASE_URL = (process.env.CLAUDIVERSE_URL || "http://localhost:4000").replace(/\/$/, "");
const TOKEN = process.env.CLAUDIVERSE_TOKEN || "";
const WS_URL = BASE_URL.replace(/^http/, "ws") + "/socket/websocket";

function die(msg, code = 1) {
  process.stderr.write(msg + "\n");
  process.exit(code);
}

if (!TOKEN) die("CLAUDIVERSE_TOKEN is not set.");

// --- REST helpers -----------------------------------------------------------

async function api(path) {
  const res = await fetch(BASE_URL + path, {
    headers: { Authorization: "Bearer " + TOKEN },
  });
  if (!res.ok) die(`GET ${path} → ${res.status} ${res.statusText}`);
  return res.json();
}

async function postApi(path, body) {
  const res = await fetch(BASE_URL + path, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + TOKEN },
    body: JSON.stringify(body),
  });
  if (!res.ok) die(`POST ${path} → ${res.status} ${res.statusText}`);
  return res.json();
}

async function listSessions(title) {
  const q = title ? "?title=" + encodeURIComponent(title) : "";
  const { sessions } = await api("/api/sessions" + q);
  return sessions || [];
}

// Resolve a friendly name (or literal id) to a numeric session id.
async function resolveSession(arg) {
  const literal = String(arg).replace(/^#/, "");
  if (/^\d+$/.test(literal)) return Number(literal);

  const matches = await listSessions(arg);
  if (matches.length === 0) die(`No session titled "${arg}".`);
  // Newest running match wins; fall back to newest of any status.
  const running = matches.filter((s) => s.status === "running");
  const pick = (running[0] || matches[0]);
  return pick.id;
}

// --- Phoenix v2 channel -----------------------------------------------------
//
// Wire frames are JSON arrays: [join_ref, ref, topic, event, payload].

function joinChannel(sessionId, { onEvent, onJoined } = {}) {
  const topic = "session:" + sessionId;
  const ws = new WebSocket(WS_URL + "?token=" + encodeURIComponent(TOKEN) + "&vsn=2.0.0");
  let ref = 0;
  const nextRef = () => String(++ref);
  const joinRef = nextRef();
  let joined = false;
  let heartbeat = null;

  const send = (jRef, event, payload) =>
    ws.send(JSON.stringify([jRef, nextRef(), topic, event, payload]));

  ws.addEventListener("open", () => {
    ws.send(JSON.stringify([joinRef, nextRef(), topic, "phx_join", { role: "observer" }]));
    heartbeat = setInterval(() => {
      try { ws.send(JSON.stringify([null, nextRef(), "phoenix", "heartbeat", {}])); } catch {}
    }, 30000);
  });

  ws.addEventListener("message", (ev) => {
    let frame;
    try { frame = JSON.parse(ev.data); } catch { return; }
    if (!Array.isArray(frame) || frame.length < 5) return;
    const [, , fTopic, event, payload] = frame;
    if (fTopic !== topic) return;

    if (event === "phx_reply" && !joined) {
      if (payload && payload.status === "ok") {
        joined = true;
        onJoined && onJoined({ send: (e, p) => send(joinRef, e, p) });
      } else {
        die(`Join rejected for ${topic}: ${JSON.stringify(payload)}`);
      }
      return;
    }
    if (joined && onEvent) onEvent(event, payload || {});
  });

  ws.addEventListener("close", () => { if (heartbeat) clearInterval(heartbeat); });
  ws.addEventListener("error", (e) => die("WebSocket error: " + (e.message || "connection failed")));

  return ws;
}

// --- Rendering --------------------------------------------------------------

function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((b) => {
      if (b.type === "text") return b.text;
      if (b.type === "tool_use") return `[tool ${b.name} ${JSON.stringify(b.input).slice(0, 120)}]`;
      if (b.type === "tool_result") return `[tool_result]`;
      if (b.type === "thinking") return `[thinking]`;
      return "";
    })
    .filter(Boolean)
    .join("\n");
}

// Render a single "message"-event payload (a raw mirrored SDK message) for a
// human. Returns null for low-signal frames (per-token stream_event deltas and
// other internal bookkeeping) so live monitoring isn't swamped — the final
// "assistant" message already carries the same text. Use --json to see everything.
function render(payload) {
  const t = payload.type;
  if (t === "turn_complete") return "── turn complete ──";
  if (t === "assistant") {
    const s = textOf(payload.message && payload.message.content);
    return s.trim() ? "assistant> " + s : null;
  }
  if (t === "user") {
    const s = textOf(payload.message && payload.message.content);
    return s.trim() ? "user> " + s : null;
  }
  if (t === "system") return "system> " + (payload.subtype || "");
  if (t === "result") return "result> " + (payload.subtype || "");
  if (t === "control_request") {
    const r = payload.request || {};
    return r.subtype === "can_use_tool" ? `permission?> ${r.tool_name}` : `control_request> ${r.subtype || ""}`;
  }
  return null; // stream_event, stream_request_start, *_in_progress, … — noise
}

// --- Commands ---------------------------------------------------------------

async function cmdList() {
  const sessions = await listSessions();
  if (sessions.length === 0) return console.log("(no sessions)");
  for (const s of sessions) {
    console.log(`${String(s.id).padStart(4)}  ${(s.status || "?").padEnd(8)}  ${s.title || "(untitled)"}`);
  }
}

async function cmdResolve(name) {
  console.log(await resolveSession(name));
}

async function cmdWatch(name, json) {
  const id = await resolveSession(name);
  process.stderr.write(`watching session ${id} (${name}) — Ctrl-C to stop\n`);
  joinChannel(id, {
    onEvent: (event, payload) => {
      if (event === "replay") {
        for (const m of payload.messages || []) emit(m, json);
      } else if (event === "message") {
        emit(payload, json);
      } else if (event === "permission_request") {
        if (json) console.log(JSON.stringify({ type: "permission_request", ...payload }));
        else console.log(`permission?> ${payload.tool_name} (request_id ${payload.request_id})`);
      } else if (event === "session_ended") {
        if (!json) console.log("── session ended ──");
      }
    },
  });
}

function emit(payload, json) {
  if (json) {
    console.log(JSON.stringify(payload));
    return;
  }
  const line = render(payload);
  if (line != null) console.log(line);
}

async function cmdTail(name, limit, json) {
  const id = await resolveSession(name);
  const ws = joinChannel(id, {
    onEvent: (event, payload) => {
      if (event === "replay") {
        const msgs = payload.messages || [];
        if (json) {
          for (const m of msgs.slice(-limit)) console.log(JSON.stringify(m));
        } else {
          // Limit counts *rendered* lines, so noise frames don't eat the budget.
          const lines = msgs.map(render).filter((l) => l != null);
          for (const l of lines.slice(-limit)) console.log(l);
        }
        ws.close();
        process.exit(0);
      }
    },
  });
  // The server pushes "replay" right after join; bail if it never arrives.
  setTimeout(() => die("Timed out waiting for replay buffer.", 1), 5000);
}

// Join, fire one observer event, flush, exit. (These events are fire-and-forget
// — the server returns :noreply — so we just give the frame time to flush.)
async function cmdEvent(name, event, payload) {
  const id = await resolveSession(name);
  const ws = joinChannel(id, {
    onJoined: ({ send }) => {
      send(event, payload);
      setTimeout(() => {
        ws.close();
        process.exit(0);
      }, 600);
    },
  });
  setTimeout(() => die("Timed out joining channel.", 1), 5000);
}

const cmdSend = (name, text) => cmdEvent(name, "send_message", { content: text });

// Answer an interactive AskUserQuestion with freeform text (-> the model sees
// "The user responded: <text>"). Targets the most-recently-opened question.
const cmdAnswer = (name, text) => cmdEvent(name, "answer", { response: text });
const cmdDecline = (name) => cmdEvent(name, "decline", {});

// Show the most recent AskUserQuestion the agent posed (from the mirror buffer).
async function cmdQuestions(name, json) {
  const id = await resolveSession(name);
  const ws = joinChannel(id, {
    onEvent: (event, payload) => {
      if (event !== "replay") return;
      let last = null;
      for (const m of payload.messages || []) {
        if (m.type !== "assistant") continue;
        for (const b of (m.message && m.message.content) || [])
          if (b.type === "tool_use" && b.name === "AskUserQuestion") last = b;
      }
      if (!last) console.log("(no AskUserQuestion in recent buffer)");
      else if (json) console.log(JSON.stringify({ tool_use_id: last.id, ...last.input }));
      else
        for (const q of last.input.questions || []) {
          console.log(`Q [${last.id}]: ${q.question || q.header}  (multiSelect=${!!q.multiSelect})`);
          (q.options || []).forEach((o, i) => console.log(`   ${i + 1}. ${o.label} — ${o.description}`));
        }
      ws.close();
      process.exit(0);
    },
  });
  setTimeout(() => die("Timed out waiting for replay buffer.", 1), 5000);
}

// --- Notifications (reactive orchestration) ---------------------------------

async function cmdSubscribe(self, watch) {
  console.log(JSON.stringify(await postApi("/api/notify/subscribe", { self, watch })));
}

async function cmdAck(self, target) {
  await postApi("/api/notify/ack", { self, target });
  console.log("acked", target);
}

async function cmdPending(self) {
  const { queue } = await api("/api/notify/pending?self=" + encodeURIComponent(self));
  if (!queue || !queue.length) return console.log("(no pending pings)");
  for (const p of queue)
    console.log(`${p.kind}  ${p.title}${p.tool_use_id ? " (" + p.tool_use_id + ")" : ""}`);
}

// --- Arg parsing ------------------------------------------------------------

function flag(args, name) {
  const i = args.indexOf(name);
  if (i === -1) return undefined;
  args.splice(i, 1);
  return true;
}
function opt(args, name, def) {
  const i = args.indexOf(name);
  if (i === -1) return def;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
}

const [cmd, ...rest] = process.argv.slice(2);

switch (cmd) {
  case "list":
    await cmdList();
    break;
  case "resolve":
    await cmdResolve(rest[0] || die("usage: cvctl resolve <name|#id>"));
    break;
  case "watch": {
    const json = flag(rest, "--json");
    await cmdWatch(rest[0] || die("usage: cvctl watch <name|#id> [--json]"), json);
    break;
  }
  case "tail": {
    const json = flag(rest, "--json");
    const limit = Number(opt(rest, "--limit", "20"));
    await cmdTail(rest[0] || die("usage: cvctl tail <name|#id> [--limit N] [--json]"), limit, json);
    break;
  }
  case "send": {
    const name = rest.shift() || die("usage: cvctl send <name|#id> <text...>");
    const text = rest.join(" ");
    if (!text) die("usage: cvctl send <name|#id> <text...>");
    await cmdSend(name, text);
    break;
  }
  case "questions": {
    const json = flag(rest, "--json");
    await cmdQuestions(rest[0] || die("usage: cvctl questions <name|#id> [--json]"), json);
    break;
  }
  case "answer": {
    const name = rest.shift() || die("usage: cvctl answer <name|#id> <text...>");
    const text = rest.join(" ");
    if (!text) die("usage: cvctl answer <name|#id> <text...>");
    await cmdAnswer(name, text);
    break;
  }
  case "decline":
    await cmdDecline(rest[0] || die("usage: cvctl decline <name|#id>"));
    break;
  case "subscribe": {
    const self = rest.shift() || die("usage: cvctl subscribe <self> --watch a,b,c");
    const watch = (opt(rest, "--watch", "") || "").split(",").map((s) => s.trim()).filter(Boolean);
    if (!watch.length) die("usage: cvctl subscribe <self> --watch a,b,c");
    await cmdSubscribe(self, watch);
    break;
  }
  case "ack": {
    const self = rest.shift() || die("usage: cvctl ack <self> [--session X | --all]");
    await cmdAck(self, opt(rest, "--session", null) || "all");
    break;
  }
  case "pending":
    await cmdPending(rest[0] || die("usage: cvctl pending <self>"));
    break;
  default:
    die(
      "cvctl — Claudiverse orchestrator CLI\n\n" +
        "  cvctl list\n" +
        "  cvctl resolve   <name|#id>\n" +
        "  cvctl watch     <name|#id> [--json]\n" +
        "  cvctl tail      <name|#id> [--limit N] [--json]\n" +
        "  cvctl send      <name|#id> <text...>\n" +
        "  cvctl questions <name|#id> [--json]      show the latest AskUserQuestion\n" +
        "  cvctl answer    <name|#id> <text...>     answer it (freeform)\n" +
        "  cvctl decline   <name|#id>               dismiss it\n" +
        "  cvctl subscribe <self> --watch a,b,c     listen for events on a,b,c\n" +
        "  cvctl ack       <self> [--session X|--all]  clear handled pings\n" +
        "  cvctl pending   <self>                   show queued pings (NEVER poll this)\n",
      cmd ? 1 : 0
    );
}
