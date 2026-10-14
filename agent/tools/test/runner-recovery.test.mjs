// node --test
// cv-runner after the server was unreachable: it keeps failing closed, then,
// once the server answers, logs "server reachable again" and claims. The real
// runner, against a fake server, in a temporary HOME.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const RUNNER = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "cv-runner.mjs");

// The endpoints an idle tasks-source runner uses. `hang(req)` true leaves a
// request unanswered: a server that accepts and stays silent.
function fakeServer({ hang = () => false } = {}) {
  const seen = [];
  const server = http.createServer((req, res) => {
    seen.push(`${req.method} ${req.url.split("?")[0]}`);
    if (hang(req)) return;
    const json = (body) => res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(body));
    if (req.method === "GET" && req.url.startsWith("/api/forum/channels/")) return json({ posts: [] });
    if (req.url === "/api/runners/heartbeat") return json({ ok: true });
    if (req.url === "/api/tasks/claim") return json({ task: null, reason: "none_ready" });
    res.writeHead(404, { "content-type": "application/json" }).end("{}");
  });
  return { server, seen };
}

const freePort = () =>
  new Promise((resolve) => {
    const s = http.createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });

function startRunner(port) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "cvr-home-"));
  const child = spawn(process.execPath, [RUNNER, "--slot", "t-w1", "--workdir", home, "--task-source", "tasks", "--fleet", "t", "--channel", "t-lane", "--poll", "200"], {
    env: { ...process.env, HOME: home, CLAUDIVERSE_URL: `http://127.0.0.1:${port}`, CLAUDIVERSE_TOKEN: "t", CLAUDIVERSE_REQUEST_TIMEOUT_MS: "500" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", (d) => (out += d));
  const waitFor = (re, ms) =>
    new Promise((resolve, reject) => {
      const t0 = Date.now();
      const tick = setInterval(() => {
        if (re.test(out)) { clearInterval(tick); resolve(); }
        else if (Date.now() - t0 > ms) { clearInterval(tick); reject(new Error(`no ${re} within ${ms / 1000} s; runner said:\n${out}`)); }
      }, 100);
    });
  const stop = () => new Promise((r) => { child.once("exit", r); child.kill("SIGKILL"); });
  return { waitFor, stop, out: () => out };
}

test("refused, then up: it fails closed, then reports the server back and claims", { timeout: 90_000 }, async () => {
  const port = await freePort();
  const runner = startRunner(port);
  try {
    await runner.waitFor(/HALT CHECK FAILED/, 40_000);
    const { server, seen } = fakeServer();
    await new Promise((r) => server.listen(port, "127.0.0.1", r));
    try {
      await runner.waitFor(/server reachable again/, 30_000);
      await runner.waitFor(/queue empty/, 10_000);
      assert.ok(seen.includes("POST /api/tasks/claim"), `no claim reached the server: ${seen.join(", ")}`);
    } finally {
      server.close();
      server.closeAllConnections();
    }
  } finally {
    await runner.stop();
  }
});

test("silent, then answering: a request that never answers costs seconds, not minutes", { timeout: 90_000 }, async () => {
  // Undici alone waits 301 s for headers (measured, Node 24) and the GET is
  // retried 5×: without the per-request timeout this test runs out of time.
  let halts = 0;
  const { server, seen } = fakeServer({ hang: (req) => req.url.startsWith("/api/forum/channels/") && ++halts <= 5 });
  const port = await freePort();
  await new Promise((r) => server.listen(port, "127.0.0.1", r));
  const runner = startRunner(port);
  try {
    await runner.waitFor(/HALT CHECK FAILED/, 40_000);
    await runner.waitFor(/server reachable again/, 30_000);
    await runner.waitFor(/queue empty/, 10_000);
    assert.ok(seen.includes("POST /api/tasks/claim"), `no claim reached the server: ${seen.join(", ")}`);
  } finally {
    await runner.stop();
    server.close();
    server.closeAllConnections();
  }
});

test("--commits takes only allowed or forbidden: anything else exits 2 at startup", async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "cvr-home-"));
  try {
    const child = spawn(process.execPath, [RUNNER, "--slot", "t-w1", "--workdir", home, "--commits", "never"], {
      env: { ...process.env, HOME: home, CLAUDIVERSE_URL: "http://127.0.0.1:9", CLAUDIVERSE_TOKEN: "t" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let err = "";
    child.stderr.on("data", (d) => (err += d));
    const timer = setTimeout(() => child.kill("SIGKILL"), 10_000);
    const code = await new Promise((r) => child.once("exit", r));
    clearTimeout(timer);
    assert.equal(code, 2, err);
    assert.match(err, /--commits must be "allowed" or "forbidden", got "never"/);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});
