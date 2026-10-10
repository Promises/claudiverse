// cv-spawn.sh's launch line, read from a stub tmux: what the seat's shell is
// actually told to run. No real tmux or claude is started.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const SPAWN = path.join(import.meta.dirname, "..", "cv-spawn.sh");

// A tmux that records every call, reports no existing session, a ready shell
// and a started process; and a claude whose --help lists no --name.
function stubs() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cvspawn-"));
  const log = path.join(dir, "tmux.log");
  fs.writeFileSync(path.join(dir, "tmux"), `#!/bin/bash
printf '%s\\n' "$*" >> ${JSON.stringify(log)}
case "$1" in
  has-session) exit 1;;
  capture-pane) echo CVREADY;;
  display-message) echo claude;;
esac
exit 0
`, { mode: 0o755 });
  fs.writeFileSync(path.join(dir, "claude"), "#!/bin/bash\nexit 0\n", { mode: 0o755 });
  fs.mkdirSync(path.join(dir, "work"));
  return { dir, log };
}

function spawn(args) {
  const s = stubs();
  const r = spawnSync("bash", [SPAWN, path.join(s.dir, "work"), "--title", "t1", "--token", "tok", "--url", "http://srv:4000", "--bin", path.join(s.dir, "claude"), ...args], {
    env: { ...process.env, PATH: `${s.dir}:${process.env.PATH}`, CV_SPAWN_POOLED: "", CV_SPAWN_POOL_ONLY: "", CV_SPAWN_OAUTH_TOKEN_FILE: "" },
    encoding: "utf8",
  });
  const sent = fs.existsSync(s.log) ? fs.readFileSync(s.log, "utf8").split("\n").filter((l) => l.startsWith("send-keys") && !l.includes("CV")) : [];
  return { status: r.status, stderr: r.stderr, launch: sent.join("\n") };
}

test("--pool-only logs the seat in with the pool placeholder and routes it through the proxy", () => {
  const r = spawn(["--pool-only"]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.launch, /CLAUDE_CODE_OAUTH_TOKEN=cv-pool /);
  assert.match(r.launch, /ANTHROPIC_BASE_URL=http:\/\/srv:4000\/proxy\/seat\/t1 /);
  assert.match(r.launch, /X-Claudiverse-Pool: 1/);
});

test("--pooled alone keeps the machine's own login", () => {
  const r = spawn(["--pooled"]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.launch, /ANTHROPIC_BASE_URL=/);
  assert.doesNotMatch(r.launch, /CLAUDE_CODE_OAUTH_TOKEN/);
});

test("neither: no pool, no login override", () => {
  const r = spawn([]);
  assert.equal(r.status, 0, r.stderr);
  assert.doesNotMatch(r.launch, /ANTHROPIC_BASE_URL|CLAUDE_CODE_OAUTH_TOKEN/);
});

test("--pool-only with --oauth-token-file is refused: two logins", () => {
  const s = stubs();
  const file = path.join(s.dir, "token");
  fs.writeFileSync(file, "x");
  const r = spawn(["--pool-only", "--oauth-token-file", file]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /two different logins/);
});
