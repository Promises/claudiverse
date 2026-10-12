// The local relay: a plain `claude` on this machine sends its API requests here
// (ANTHROPIC_BASE_URL=http://127.0.0.1:<port>, set by the opt-in shell function,
// never by settings.json: settings env OVERRIDES a seat's own, measured on
// 2.1.291), and the relay sends them through the claudiverse server's proxy so
// they run on the account pool with its failover.
//
// 🔴 A PLAIN CLAUDE MUST WORK WITH NO SERVER. So the session keeps its own login
// (the proxy replaces it on the way out: X-Claudiverse-Pool), and every request
// the server cannot serve goes straight to Anthropic with that login instead:
// the server unreachable, the proxy refusing (403: token), or the pool empty
// (the proxy's own 429 "no pool account"). After a connection failure the
// server is skipped for `skipMs`, so a dead server costs one connect timeout,
// not one per request.
//
// Bodies are buffered (a request may be sent twice: server, then direct);
// responses stream through untouched.
import http from "node:http";
import https from "node:https";

const HOP = new Set(["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "trailer", "host", "content-length"]);
const TITLE = /^[A-Za-z0-9._-]{1,64}$/;

export function createRelay({ server, token, machine, direct = "https://api.anthropic.com", skipMs = 30_000, connectMs = 3_000, log = () => {} }) {
  let skipUntil = 0;
  const titles = new Map(); // claude session id -> { title, at }

  // The seat's title, for the proxy path (its pool assignment is labelled by it).
  async function seatFor(sessionId) {
    const fallback = `plain-${machine}`.replace(/[^A-Za-z0-9._-]+/g, "-").slice(0, 64);
    if (!sessionId) return fallback;
    const hit = titles.get(sessionId);
    if (hit && Date.now() - hit.at < 60_000) return hit.title;
    try {
      const r = await fetch(`${server}/api/seats/whoami?claude_session_id=${encodeURIComponent(sessionId)}`,
        { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(connectMs) });
      const t = r.ok ? (await r.json()).title : null;
      if (typeof t !== "string" || !TITLE.test(t)) return fallback;
      // Only a real answer is cached. Claude Code's first requests come before
      // the mod has registered the seat; caching that miss labelled a whole
      // minute of a new session "plain-<machine>" (measured 2026-10-06).
      titles.set(sessionId, { title: t, at: Date.now() });
      return t;
    } catch {
      return fallback;
    }
  }

  function send(target, method, headers, body, res, onHead) {
    return new Promise((resolve) => {
      const u = new URL(target);
      const lib = u.protocol === "https:" ? https : http;
      const req = lib.request(u, { method, headers: { ...headers, host: u.host, "content-length": body.length } }, (up) => {
        if (onHead && onHead(up) === "retry") {
          up.resume();
          return resolve("retry");
        }
        const out = {};
        for (const [k, v] of Object.entries(up.headers)) if (!HOP.has(k)) out[k] = v;
        res.writeHead(up.statusCode, out);
        up.pipe(res);
        up.on("end", () => resolve("done"));
        up.on("error", () => { res.destroy(); resolve("done"); });
      });
      req.setTimeout(connectMs, () => { if (!req.socket?.connecting) return; req.destroy(new Error("connect timeout")); });
      req.on("error", (e) => resolve({ error: e }));
      req.end(body);
    });
  }

  // Whether the server's answer means "go direct": its proxy refusing the
  // claudiverse token (403), or the pool having no account (its own 429).
  // An ordinary 429 from Anthropic carries anthropic-ratelimit headers and is
  // the session's to see (the proxy already failed over where it could).
  function serverDeclined(up) {
    if (up.statusCode === 403) return true;
    if (up.statusCode === 429 && !Object.keys(up.headers).some((k) => k.startsWith("anthropic-ratelimit"))) return true;
    return [502, 503, 504].includes(up.statusCode) && !Object.keys(up.headers).some((k) => k.startsWith("anthropic-"));
  }

  async function handle(req, res) {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks);
    const headers = {};
    for (const [k, v] of Object.entries(req.headers)) if (!HOP.has(k) && !k.startsWith("x-claudiverse-")) headers[k] = v;

    if (Date.now() >= skipUntil) {
      const seat = await seatFor(req.headers["x-claude-code-session-id"]);
      const viaServer = {
        ...headers,
        "x-claudiverse-token": token,
        "x-claudiverse-pool": "1",
        "x-claudiverse-observe": "off",
      };
      const r = await send(`${server}/proxy/seat/${seat}${req.url}`, req.method, viaServer, body, res, (up) => (serverDeclined(up) ? "retry" : "ok"));
      if (r === "done") return;
      if (r?.error) {
        skipUntil = Date.now() + skipMs;
        log(`relay: server unreachable (${r.error.code || r.error.message}); direct for ${skipMs / 1000} s`);
      } else {
        log(`relay: server declined ${req.method} ${req.url.split("?")[0]}; this request goes direct`);
      }
    }
    const r = await send(`${direct}${req.url}`, req.method, headers, body, res);
    if (r?.error && !res.headersSent) {
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ type: "error", error: { type: "api_error", message: `cv-relay: ${r.error.message}` } }));
    }
  }

  return http.createServer((req, res) => {
    // Answered here, never forwarded: the shell function's "is the relay up?".
    if (req.url === "/_relay") {
      res.writeHead(200, { "content-type": "text/plain" });
      return res.end(Date.now() < skipUntil ? "direct" : "pool");
    }
    handle(req, res).catch((e) => {
      log(`relay: ${e.message}`);
      if (!res.headersSent) res.writeHead(502);
      res.end();
    });
  });
}
