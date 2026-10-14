// node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import { idleProblem, unsentPrompt, readClaudeArgv, readClaudeEnv, rebuildArgs, capProblem, resumeCommand } from "../lib/restart.mjs";

const UUID = "d7dba841-a246-4186-9c74-da1d8534d610";

test("a seat is idle enough only when its record says idle, for long enough", () => {
  const now = 1_000_000;
  assert.equal(idleProblem({ status: "idle", statusUpdatedAt: now - 61_000 }, now, 60_000), null);
  assert.match(idleProblem({ status: "idle", statusUpdatedAt: now - 20_000 }, now, 60_000), /20 s, less than 60 s/);
  assert.match(idleProblem({ status: "busy", statusUpdatedAt: now - 600_000 }, now, 60_000), /busy/);
  assert.match(idleProblem({ status: "waiting", statusUpdatedAt: now - 600_000 }, now, 60_000), /waiting/);
});

// MEASURED on 2.1.292 (capture-pane -e of an idle seat, and with "abc def" typed).
const RULE = "\x1b[38;5;244m" + "─".repeat(60) + " hello ─";
const pane = (prompt) => ["", RULE, prompt, "\x1b[38;5;244m" + "─".repeat(60), "  ⏵⏵ auto mode on (shift+tab to cycle)"].join("\n");

test("unsent text: the dim placeholder is not text, typed text is, and no prompt in view cannot be told", () => {
  assert.equal(unsentPrompt(pane('\x1b[39m❯ \x1b[2mTry "create a util logging.py that..."\x1b[0m\x1b[39m\x1b[49m')), false);
  assert.equal(unsentPrompt(pane("\x1b[39m❯ abc def")), true);
  assert.equal(unsentPrompt(pane("\x1b[39m❯ ")), false);
  assert.equal(unsentPrompt(["", " Do you want to proceed?", " ❯ 1. Yes", " Esc to cancel"].join("\n")), true, "a menu's ❯ line reads as text: never stopped");
  assert.equal(unsentPrompt("just some output\nno prompt here"), null);
});

test("a rebuild keeps its model, effort, every MCP config and options it does not know; it says what it drops", () => {
  const argv = ["/opt/claude/2.1.292", "--mcp-config", "/c/claudiverse.json", "--mcp-config", "/c/ghidra.json", "/c/chrome.json",
    "--permission-mode", "auto", "--name", "ipsum-w1", "--model", "claude-opus-5-5[1m]", "--effort", "high",
    "--add-dir", "/srv/a", "/srv/b", "--plugin-dir=/p/mod", "--append-system-prompt", "Be brief, and say why.",
    "--some-future-flag", "x", "--verbose", "--resume", UUID];
  const r = readClaudeArgv(argv);
  assert.equal(r.model, "claude-opus-5-5[1m]");
  assert.equal(r.effort, "high");
  assert.equal(r.mode, "auto");
  assert.deepEqual(r.mcp, ["/c/claudiverse.json", "/c/ghidra.json", "/c/chrome.json"]);
  assert.deepEqual(r.carry, ["--add-dir", "/srv/a", "/srv/b", "--plugin-dir=/p/mod", "--append-system-prompt", "Be brief, and say why.",
    "--some-future-flag", "x", "--verbose"]);
  assert.deepEqual(r.argvNames, ["--model", "--effort", "--mcp-config", "--mcp-config", "--mcp-config", "--add-dir", "--plugin-dir",
    "--append-system-prompt", "--some-future-flag", "--verbose"]);
  assert.ok(r.dropped.some((d) => d.startsWith("--name")));
  assert.ok(r.dropped.some((d) => d.startsWith("--resume")));
});

test("a node-run claude, a first prompt after a flag that takes none, bypass and --print", () => {
  const r = readClaudeArgv(["node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--verbose", "fix the build"]);
  assert.deepEqual(r.carry, ["--verbose"]);
  assert.ok(r.dropped.some((d) => d.includes("first prompt")), "the old first prompt is not sent again");
  assert.ok(readClaudeArgv(["claude", "--dangerously-skip-permissions"]).dropped[0].includes("never started"));
  assert.match(readClaudeArgv(["claude", "--permission-mode", "bypassPermissions"]).dropped[0], /only default/);
  assert.match(readClaudeArgv(["claude", "-p", "hi"]).refuse, /print/);
  assert.match(readClaudeArgv([]).refuse, /could not be read/);
});

test("the environment: pooling, config dir, a login token, what is carried and what is set fresh", () => {
  const e = readClaudeEnv([
    "ANTHROPIC_BASE_URL=http://srv:4000/proxy/seat/ipsum-w1", "CLAUDE_CODE_OAUTH_TOKEN=cv-pool", "CLAUDE_CONFIG_DIR=/home/me/.claude-mod",
    "CLAUDIVERSE_TITLE=ipsum-w1", "CLAUDIVERSE_TOKEN=secret", "CLAUDIVERSE_NOTIFY=1", "CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000",
    "CLAUDE_CODE_ENTRYPOINT=cli", "PATH=/usr/bin", "HOME=/home/me",
  ]);
  assert.deepEqual([e.pooled, e.poolOnly, e.configDir, e.oauthToken], [true, true, "/home/me/.claude-mod", null]);
  assert.deepEqual(e.carry, { CLAUDIVERSE_NOTIFY: "1", CLAUDE_CODE_MAX_OUTPUT_TOKENS: "64000" });
  assert.deepEqual(e.envNames, ["CLAUDE_CODE_MAX_OUTPUT_TOKENS", "CLAUDIVERSE_NOTIFY"]);

  const own = readClaudeEnv(["CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-x", "ANTHROPIC_BASE_URL=https://elsewhere.example"]);
  assert.deepEqual([own.pooled, own.oauthToken], [false, "sk-ant-oat01-x"]);
  assert.match(own.dropped[0], /ANTHROPIC_BASE_URL/);
});

test("the new seat's arguments: effort and MCP configs come back, a config dir only if it was set, the mode it was started in", () => {
  // MEASURED (Debian, 2.1.296): a seat started without CLAUDE_CONFIG_DIR came
  // back at first-run setup when the restart set it to the default folder.
  const cl = readClaudeArgv(["/home/me/.local/bin/claude", "--mcp-config", "/home/me/extra-mcp.json", "--permission-mode", "auto", "--name", "rich", "--effort", "high"]);
  const plain = rebuildArgs(cl, readClaudeEnv(["ANTHROPIC_BASE_URL=http://srv/proxy/seat/rich", "CLAUDE_CODE_OAUTH_TOKEN=cv-pool"]));
  assert.ok(!plain.extra.includes("--config-dir"));
  assert.ok(!plain.envNames.includes("CLAUDE_CONFIG_DIR"));
  assert.deepEqual(plain.extra.slice(plain.extra.indexOf("--effort"), plain.extra.indexOf("--effort") + 4), ["--effort", "high", "--mcp", "/home/me/extra-mcp.json"]);
  assert.ok(plain.extra.includes("--pool-only"));
  assert.equal(plain.mode, "auto", "no mode heard: the one it was started in");

  const own = rebuildArgs(cl, readClaudeEnv(["CLAUDE_CONFIG_DIR=/home/me/.claude-mod"]), { live: "plan", fleet: "lorem" });
  assert.deepEqual(own.extra.slice(0, 6), ["--origin", "spawn", "--config-dir", "/home/me/.claude-mod", "--fleet", "lorem"]);
  assert.equal(own.mode, "plan", "the mode it is in now wins");
  assert.ok(own.dropped.some((d) => d.startsWith("--permission-mode auto")));

  const token = readClaudeEnv(["CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-x"]);
  const withFile = rebuildArgs(cl, token, { tokenFile: "/home/me/.claude-token" }).extra;
  assert.equal(withFile[withFile.indexOf("--oauth-token-file") + 1], "/home/me/.claude-token");
  assert.ok(rebuildArgs(cl, token).dropped.some((d) => d.startsWith("CLAUDE_CODE_OAUTH_TOKEN")));
});

test("max_seats before the stop: the seat being restarted is counted out; one the agent did not start needs a free place", () => {
  // MEASURED live (an M5, max_seats 10): seats the agent had not started were
  // stopped one after another, each restart adding one, until the 10th could
  // not start again. These are refused before the stop now.
  const alive = new Set(["a", "b", "c"]);
  assert.equal(capProblem(alive, "c", 3), null, "its own place back");
  assert.match(capProblem(alive, "by-hand", 3), /^would exceed max_seats \(3\): this machine already runs 3 app-started seats$/);
  assert.equal(capProblem(alive, "by-hand", 4), null);
  assert.match(capProblem(alive, null, 3), /max_seats \(3\)/, "a new seat: every one counts");
  // A dry run: the seats planned before it take their places first.
  assert.equal(capProblem(alive, "by-hand", 5), null);
  assert.match(capProblem(alive, "by-hand", 5, 2), /already runs 3 app-started seats, and the 2 restarted before it in this batch would take places$/);
});

test("the command that brings a stopped seat back by hand", () => {
  const id = "d7dba841-a246-4186-9c74-da1d8534d610";
  assert.equal(resumeCommand({ cwd: "/home/me/projects/lorem", bin: "/opt/claude/2.1.296", sessionId: id }),
    `cd /home/me/projects/lorem && /opt/claude/2.1.296 --resume ${id}`);
  assert.equal(resumeCommand({ cwd: "/home/me/my lorem's", configDir: "/home/me/.claude-mod", sessionId: id }),
    `cd '/home/me/my lorem'\\''s' && CLAUDE_CONFIG_DIR=/home/me/.claude-mod claude --resume ${id}`);
});
