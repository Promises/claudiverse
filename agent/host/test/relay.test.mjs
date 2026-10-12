// node --test
import { test, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { createRelay } from "../lib/relay.mjs";

// A fake claudiverse server (whoami + proxy) and a fake api.anthropic.com.
function fake(handler) {
  const seen = [];
  const s = http.createServer(async (req, res) => {
    const chunks = []; for await (const c of req) chunks.push(c);
    seen.push({ url: req.url, headers: req.headers, body: Buffer.concat(chunks).toString() });
    handler(req, res);
  });
  return new Promise((r) => s.listen(0, "127.0.0.1", () => r({ s, seen, url: `http://127.0.0.1:${s.address().port}` })));
}
const listen = (srv) => new Promise((r) => srv.listen(0, "127.0.0.1", () => r(`http://127.0.0.1:${srv.address().port}`)));
const servers = [];
after(() => servers.forEach((s) => s.close()));

async function call(url, extra = {}) {
  const r = await fetch(`${url}/v1/messages?beta=true`, {
    method: "POST",
    headers: { authorization: "Bearer OWN-LOGIN", "x-claude-code-session-id": "sess-1", "content-type": "application/json", ...extra },
    body: JSON.stringify({ model: "m", messages: [] }),
  });
  return { status: r.status, text: await r.text(), headers: r.headers };
}

async function setup(serverBehaviour, opts = {}) {
  let whoami = 0;
  const server = await fake((req, res) => {
    if (req.url.startsWith("/api/seats/whoami")) {
      whoami += 1;
      if (opts.registeredAfter && whoami <= opts.registeredAfter) { res.writeHead(404); return res.end("{}"); }
      res.writeHead(200, { "content-type": "application/json" }); return res.end('{"title":"proj-ab12"}');
    }
    serverBehaviour(req, res);
  });
  const direct = await fake((req, res) => { res.writeHead(200, { "content-type": "text/event-stream" }); res.end("data: direct\n\n"); });
  servers.push(server.s, direct.s);
  const logs = [];
  const relay = createRelay({ server: opts.serverUrl || server.url, token: "SEAT-TOKEN", machine: "m5", direct: direct.url, skipMs: 1000, connectMs: 500, log: (m) => logs.push(m) });
  servers.push(relay);
  return { server, direct, logs, url: await listen(relay) };
}

test("normal path: through the server's proxy with the pool headers, own login kept, stream passed through", async () => {
  const t = await setup((req, res) => { res.writeHead(200, { "content-type": "text/event-stream" }); res.write("data: one\n\n"); res.end("data: two\n\n"); });
  const r = await call(t.url);
  assert.equal(r.status, 200);
  assert.equal(r.text, "data: one\n\ndata: two\n\n");
  const p = t.server.seen.find((x) => x.url.startsWith("/proxy/"));
  assert.equal(p.url, "/proxy/seat/proj-ab12/v1/messages?beta=true");
  assert.equal(p.headers["x-claudiverse-token"], "SEAT-TOKEN");
  assert.equal(p.headers["x-claudiverse-pool"], "1");
  assert.equal(p.headers["x-claudiverse-observe"], "off");
  assert.equal(p.headers.authorization, "Bearer OWN-LOGIN");
  assert.equal(t.direct.seen.length, 0);
});

test("server unreachable: direct with the own login, then the server is skipped for a while", async () => {
  const dead = http.createServer(); const deadUrl = await listen(dead); dead.close();
  const t = await setup(() => {}, { serverUrl: deadUrl });
  const r1 = await call(t.url);
  assert.equal(r1.text, "data: direct\n\n");
  assert.equal(t.direct.seen[0].headers.authorization, "Bearer OWN-LOGIN");
  assert.equal(t.direct.seen[0].headers["x-claudiverse-token"], undefined, "no claudiverse header goes to Anthropic");
  await call(t.url);
  assert.equal(t.direct.seen.length, 2);
  assert.equal(t.logs.filter((m) => m.includes("unreachable")).length, 1, "the second request skipped the server");
});

test("pool empty (the proxy's own 429) or the proxy refusing (403): this request goes direct", async () => {
  for (const status of [429, 403]) {
    const t = await setup((req, res) => { res.writeHead(status, { "content-type": "application/json" }); res.end('{"error":"cv-proxy"}'); });
    const r = await call(t.url);
    assert.equal(r.status, 200, `status ${status} should fall back`);
    assert.equal(r.text, "data: direct\n\n");
  }
});

test("Anthropic's own 429 through the proxy reaches the session, not retried direct", async () => {
  const t = await setup((req, res) => { res.writeHead(429, { "anthropic-ratelimit-unified-status": "rejected" }); res.end("limited"); });
  const r = await call(t.url);
  assert.equal(r.status, 429);
  assert.equal(t.direct.seen.length, 0);
});

test("claudiverse headers a session sends itself never reach Anthropic on the direct path", async () => {
  const dead = http.createServer(); const deadUrl = await listen(dead); dead.close();
  const t = await setup(() => {}, { serverUrl: deadUrl });
  await call(t.url, { "x-claudiverse-token": "CLIENT-TOKEN", "x-claudiverse-pool": "1" });
  const h = t.direct.seen[0].headers;
  assert.equal(h["x-claudiverse-token"], undefined);
  assert.equal(h["x-claudiverse-pool"], undefined);
});

test("/_relay answers locally and is never forwarded", async () => {
  const t = await setup(() => { throw new Error("must not reach the server"); });
  const r = await fetch(`${t.url}/_relay`);
  assert.equal(r.status, 200);
  assert.equal(await r.text(), "pool");
  assert.equal(t.server.seen.length, 0);
});

test("a seat not registered yet gets the fallback label once, then its own title (no cached miss)", async () => {
  const t = await setup((req, res) => { res.writeHead(200); res.end("ok"); }, { registeredAfter: 1 });
  await call(t.url);
  await call(t.url);
  const urls = t.server.seen.filter((x) => x.url.startsWith("/proxy/")).map((x) => x.url.split("/")[3]);
  assert.deepEqual(urls, ["plain-m5", "proj-ab12"]);
});
