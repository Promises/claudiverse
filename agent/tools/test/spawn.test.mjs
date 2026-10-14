// cv-spawn.sh's launch line, read from a stub tmux: what the seat's shell is
// actually told to run. No real tmux or claude is started.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const SPAWN = path.join(import.meta.dirname, "..", "cv-spawn.sh");

// A tmux that records every call, reports no existing session, a ready shell
// and a started process; and a claude whose --help lists no --name. When the
// launch line is typed it also keeps the env file it names, and its mode (the
// real pane sources and deletes it).
function stubs() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cvspawn-"));
  scratch.push(dir);
  const log = path.join(dir, "tmux.log");
  fs.writeFileSync(path.join(dir, "tmux"), `#!/bin/bash
printf '%s\\n' "$*" >> ${JSON.stringify(log)}
re=' [.] ([^ ]*cv-env-[A-Za-z0-9]+) '
if [ "$1" = send-keys ] && [[ "$*" =~ $re ]]; then
  f="${'$'}{BASH_REMATCH[1]}"
  { stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f"; } > ${JSON.stringify(log)}.envmode
  cp "$f" ${JSON.stringify(log)}.env
fi
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

// Every stub folder, removed when the tests end.
const scratch = [];
after(() => {
  for (const d of scratch) fs.rmSync(d, { recursive: true, force: true });
});

function spawn(args, extraEnv = {}, prepare = () => {}) {
  const s = stubs();
  prepare(s.dir);
  const r = spawnSync("bash", [SPAWN, path.join(s.dir, "work"), "--title", "t1", "--token", "tok", "--url", "http://srv:4000", "--bin", path.join(s.dir, "claude"), ...args], {
    // HOME and CLAUDE_CONFIG_DIR are the scratch folder's: cv-spawn trusts the
    // working folder in the seat's Claude config (cv-trust.mjs), which must
    // never be the real one's.
    env: { ...process.env, PATH: `${s.dir}:${process.env.PATH}`, HOME: s.dir, CLAUDE_CONFIG_DIR: "", CV_SPAWN_CONFIG_DIR: "",
           CV_SPAWN_POOLED: "", CV_SPAWN_POOL_ONLY: "", CV_SPAWN_OAUTH_TOKEN_FILE: "", ...extraEnv },
    encoding: "utf8",
  });
  const sent = fs.existsSync(s.log) ? fs.readFileSync(s.log, "utf8").split("\n").filter((l) => l.startsWith("send-keys") && !l.includes("CV")) : [];
  let config = null;
  try {
    config = JSON.parse(fs.readFileSync(path.join(s.dir, ".claude.json"), "utf8"));
  } catch {}
  const env = fs.existsSync(`${s.log}.env`) ? fs.readFileSync(`${s.log}.env`, "utf8") : "";
  const envMode = fs.existsSync(`${s.log}.envmode`) ? fs.readFileSync(`${s.log}.envmode`, "utf8").trim() : null;
  return { status: r.status, stderr: r.stderr, launch: sent.join("\n"), env, envMode, config, work: fs.realpathSync(path.join(s.dir, "work")) };
}

test("--pool-only logs the seat in with the pool placeholder and routes it through the proxy", () => {
  const r = spawn(["--pool-only"]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.launch, /CLAUDE_CODE_OAUTH_TOKEN=cv-pool /);
  assert.match(r.launch, /ANTHROPIC_BASE_URL=http:\/\/srv:4000\/proxy\/seat\/t1 /);
  // The pool headers carry the seat token: in the env file, not on the typed line.
  assert.match(r.env, /^export ANTHROPIC_CUSTOM_HEADERS=.*X-Claudiverse-Pool: 1/m);
  assert.doesNotMatch(r.launch, /X-Claudiverse-Token|ANTHROPIC_CUSTOM_HEADERS/);
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

test("a restart's carried options go on verbatim, quoted, and carried variables by name from the environment", () => {
  const r = spawn(["--claude-arg", "--append-system-prompt", "--claude-arg", "Be brief; say why.", "--claude-arg", "--add-dir", "--claude-arg", "/srv/a b",
    "--carry-env", "CLAUDIVERSE_NOTIFY", "--carry-env", "CLAUDE_CODE_MAX_OUTPUT_TOKENS"], { CLAUDIVERSE_NOTIFY: "1", CLAUDE_CODE_MAX_OUTPUT_TOKENS: "64000 x" });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.launch, / --append-system-prompt Be\\ brief\\;\\ say\\ why\. --add-dir \/srv\/a\\ b/);
  // Carried variables may hold anything: in the env file too.
  assert.match(r.env, /^export CLAUDIVERSE_NOTIFY=1$/m);
  assert.match(r.env, /^export CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000\\ x$/m);
  assert.doesNotMatch(r.launch, /64000/);
  assert.equal(spawn(["--carry-env", "BAD-NAME"]).status, 2);
});

test("the working folder is trusted, and first-run setup done, in the seat's Claude config before the launch", () => {
  const r = spawn([]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.config.projects[r.work].hasTrustDialogAccepted, true);
  assert.equal(r.config.hasCompletedOnboarding, true);
});

test("a seat that would stop at a dialog is not started: no tmux session when its config cannot be read", () => {
  const r = spawn([], {}, (dir) => fs.writeFileSync(path.join(dir, ".claude.json"), "{ not json"));
  assert.equal(r.status, 1);
  assert.match(r.stderr, /cv-trust: cannot make .* start without a dialog: cannot read/);
  assert.match(r.stderr, /not starting t1: it would wait at Claude Code's trust or first-run dialog/);
  assert.equal(r.launch, "", "nothing was sent to a session");
});

test("no secret is typed into the pane: the seat token is in a 0600 env file the typed line sources and deletes", () => {
  const r = spawn(["--pooled"], { CLAUDIVERSE_TOKEN: "" }, () => {});
  assert.equal(r.status, 0, r.stderr);
  assert.doesNotMatch(r.launch, /tok\b|CLAUDIVERSE_TOKEN=/, "the typed line holds no token");
  assert.match(r.env, /^export CLAUDIVERSE_TOKEN=tok$/m);
  assert.equal(r.envMode, "600");
  assert.match(r.launch, /&& \( \. \S+cv-env-\w+ && rm -f \S+cv-env-\w+ && CLAUDIVERSE_TITLE=t1 .* exec \S+claude /);
});
