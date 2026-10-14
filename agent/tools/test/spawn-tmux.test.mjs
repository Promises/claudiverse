// node --test
// cv-spawn.sh with a REAL tmux, on a private tmux server (never the user's),
// and a stand-in claude that records the environment it was started with:
// a spawned pane's whole scrollback holds no secret, and the seat still gets
// every one. MEASURED 2026-10-14: a runner's stall evidence, a pane capture,
// held a seat token in clear text, typed there by cv-spawn's launch line.
//
// CV_SPAWN_UNDER_TEST names another cv-spawn.sh to run this against.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";

const SPAWN = process.env.CV_SPAWN_UNDER_TEST || new URL("../cv-spawn.sh", import.meta.url).pathname;
const TOKEN = "SECRET-SEAT-TOKEN-4f2a9c";
const CARRIED = "CARRIED-SECRET-9d1e77";

let realTmux = null;
try {
  realTmux = execFileSync("sh", ["-c", "command -v tmux"]).toString().trim();
} catch {}

const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cvspawn-tmux-")));
const socket = `cvtest-spawn-${process.pid}`;
const tmux = (...args) => execFileSync(realTmux, ["-L", socket, ...args]).toString();

after(() => {
  if (realTmux) {
    spawnSync(realTmux, ["-L", socket, "kill-server"]);
    // The pane's shell writes its history into this HOME as it exits: wait for the server to be gone.
    for (let i = 0; i < 50 && spawnSync(realTmux, ["-L", socket, "ls"]).status === 0; i++) spawnSync("sleep", ["0.1"]);
    spawnSync("sleep", ["0.5"]);
  }
  fs.rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
});

test("a spawned pane's whole scrollback holds no secret; the seat still gets them all", { skip: !realTmux && "no tmux here" }, () => {
  const bin = path.join(dir, "bin");
  fs.mkdirSync(bin);
  fs.mkdirSync(path.join(dir, "work"));
  fs.mkdirSync(path.join(dir, "tmp"));
  // tmux, on this test's own server.
  fs.writeFileSync(path.join(bin, "tmux"), `#!/bin/sh\nexec ${JSON.stringify(realTmux)} -L ${socket} "$@"\n`, { mode: 0o755 });
  // claude: records its environment, then stays (its process is not a shell, so the launch check passes).
  const seen = path.join(dir, "seen.env");
  fs.writeFileSync(path.join(bin, "claude"), `#!/bin/bash\n[ "$1" = --help ] && exit 0\nenv > ${JSON.stringify(seen)}\nexec sleep 60\n`, { mode: 0o755 });

  const r = spawnSync("bash", [SPAWN, path.join(dir, "work"), "--title", "cvtest-secret", "--token", TOKEN, "--url", "http://srv:4000",
    "--bin", path.join(bin, "claude"), "--pooled", "--carry-env", "CV_TEST_SECRET", "--prompt", "say hi"], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, HOME: dir, TMPDIR: path.join(dir, "tmp"), CLAUDE_CONFIG_DIR: "",
           CLAUDIVERSE_TOKEN: "", CV_TEST_SECRET: CARRIED, CV_SPAWN_POOLED: "", CV_SPAWN_POOL_ONLY: "", CV_SPAWN_OAUTH_TOKEN_FILE: "" },
    encoding: "utf8",
    timeout: 60_000,
  });
  assert.equal(r.status, 0, r.stderr);

  const scrollback = tmux("capture-pane", "-p", "-J", "-S", "-", "-E", "-", "-t", "cvtest-secret");
  assert.ok(scrollback.includes("cd "), "the launch line is in the scrollback");
  assert.ok(!scrollback.includes(TOKEN), "no seat token in the pane");
  assert.ok(!scrollback.includes(CARRIED), "no carried value in the pane");
  assert.ok(!r.stdout.includes(TOKEN) && !r.stderr.includes(TOKEN), "nor in what cv-spawn printed");

  const env = fs.readFileSync(seen, "utf8");
  assert.match(env, new RegExp(`^CLAUDIVERSE_TOKEN=${TOKEN}$`, "m"));
  assert.match(env, new RegExp(`^ANTHROPIC_CUSTOM_HEADERS=X-Claudiverse-Token: ${TOKEN}$`, "m"));
  assert.match(env, new RegExp(`^CV_TEST_SECRET=${CARRIED}$`, "m"));
  assert.match(env, /^CLAUDIVERSE_TITLE=cvtest-secret$/m);

  // The env file was deleted once read.
  const envDir = path.join(dir, "tmp", "cv-env");
  assert.deepEqual(fs.existsSync(envDir) ? fs.readdirSync(envDir) : [], []);
});
