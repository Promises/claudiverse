// Restarting a running seat on this machine's current runtime (restart_seat):
// is it idle enough, is text waiting unsent in its prompt, and what was its
// claude process started with (argv and environment), so the new one gets the
// same. Pure; cv-host-agent.mjs reads the process, stops and starts.

import { MODES } from "./rules.mjs";

// --- idle ---------------------------------------------------------------------------

// Why the seat whose session record is `record` is not idle enough to stop at
// `now` (ms), or null. Its own record says: status "idle", unchanged for at
// least `minMs`.
export function idleProblem(record, now, minMs) {
  if (record.status !== "idle") return `it is ${record.status || "not idle"}`;
  const since = Number(record.statusUpdatedAt || record.updatedAt);
  if (!Number.isFinite(since)) return "its record does not say since when it is idle";
  const idle = now - since;
  if (idle < minMs) return `it has been idle for ${Math.round(idle / 1000)} s, less than ${Math.round(minMs / 1000)} s`;
  return null;
}

// --- unsent prompt text (a tmux seat's pane) -------------------------------------------

const ESC = /\x1b\[[0-9;?]*[ -/]*[@-~]/g;
// The empty prompt's placeholder ("Try …") is drawn dim; typed text is not.
// MEASURED on 2.1.292: `❯ \x1b[2mTry "create a util…"\x1b[0m` when empty,
// `❯ abc def` with text typed.
const DIM = /\x1b\[2m[\s\S]*?(?:\x1b\[(?:0|22)m|$)/g;
const RULE = /^\s*─{8,}/;

// Whether text is typed but unsent in the prompt of `pane` (captured with
// `capture-pane -e`): true, false, or null when no prompt is in view (a dialog
// or a menu): then it cannot be told.
export function unsentPrompt(pane) {
  const lines = pane.replace(/\s+$/, "").split("\n");
  for (let i = lines.length - 1; i >= Math.max(0, lines.length - 40); i--) {
    if (!/^\s*❯/.test(lines[i].replace(ESC, ""))) continue;
    const typed = [lines[i]];
    for (let j = i + 1; j < lines.length && !RULE.test(lines[j].replace(ESC, "")); j++) typed.push(lines[j]);
    const text = typed.map((l) => l.replace(DIM, "").replace(ESC, "")).join("\n").replace(/^\s*❯/, "");
    return text.trim().length > 0;
  }
  return null;
}

// --- what the process was started with -------------------------------------------------

// claude's options by what follows them. Options this rebuild sets itself are
// handled; every other option is carried as it was, with what follows it.
const TAKES_ONE = new Set(["--model", "--effort", "--permission-mode", "--name", "-n", "--session-id", "--settings", "--system-prompt",
  "--system-prompt-file", "--append-system-prompt", "--append-system-prompt-file", "--agents", "--agent", "--fallback-model",
  "--setting-sources", "--max-turns", "--debug-file", "--output-format", "--input-format"]);
const TAKES_MANY = new Set(["--mcp-config", "--add-dir", "--plugin-dir", "--allowedTools", "--allowed-tools", "--disallowedTools",
  "--disallowed-tools", "--betas", "--tools"]);
// Options that take nothing: what follows them is not theirs (a first prompt).
const TAKES_NONE = new Set(["--continue", "-c", "--verbose", "--ide", "--strict-mcp-config", "--chrome", "--no-chrome", "--fork-session",
  "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--include-partial-messages", "--replay-user-messages",
  "--disable-slash-commands", "-p", "--print"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// argv[0] is the binary (the pid is the one its session record names, so it
// is claude, whatever its file is called: runtimes live at version-named
// paths like /opt/claude/2.1.292); a JavaScript runtime runs the script next.
const SCRIPT_RUNNER = /(^|\/)(node|nodejs|bun)$/;
const isOpt = (a) => typeof a === "string" && a.startsWith("-") && a !== "-";

// The values option `opt` takes from args[i+1…]; returns [values, next i].
function valuesOf(opt, args, i) {
  const values = [];
  if (TAKES_NONE.has(opt)) return [values, i];
  if (TAKES_ONE.has(opt)) return i + 1 < args.length ? [[args[i + 1]], i + 1] : [values, i];
  // --resume takes a conversation id, or nothing (the picker); --debug a filter, or nothing.
  if (opt === "--resume" || opt === "-r") return i + 1 < args.length && UUID.test(args[i + 1]) ? [[args[i + 1]], i + 1] : [values, i];
  // TAKES_MANY, and an option this rebuild does not know: what follows it until the next option.
  while (i + 1 < args.length && !isOpt(args[i + 1])) values.push(args[++i]);
  return [values, i];
}

// A claude process's command line, read for a rebuild. Returns:
// { model, effort, mode, mcp: [files], carry: [verbatim args], dropped: [what
//   and why], argvNames: [options the new seat gets] } or { refuse: reason }.
export function readClaudeArgv(argv) {
  if (!argv.length) return { refuse: "its command line could not be read" };
  const args = argv.slice(SCRIPT_RUNNER.test(argv[0]) ? 2 : 1);
  const out = { model: null, effort: null, mode: null, mcp: [], carry: [], dropped: [] };

  for (let i = 0; i < args.length; i++) {
    const raw = args[i];
    if (!isOpt(raw)) {
      out.dropped.push("its first prompt (a one-time message given on the command line)");
      continue;
    }
    const eq = raw.startsWith("--") ? raw.indexOf("=") : -1;
    const opt = eq > 0 ? raw.slice(0, eq) : raw;
    let values;
    if (eq > 0) values = [raw.slice(eq + 1)];
    else [values, i] = valuesOf(opt, args, i);

    switch (opt) {
      case "-p":
      case "--print":
        return { refuse: "it runs in --print mode, not as an interactive seat" };
      case "--model":
        out.model = values[0] ?? null;
        break;
      case "--effort":
        out.effort = values[0] ?? null;
        break;
      case "--permission-mode":
        if (MODES.includes(values[0])) out.mode = values[0];
        else out.dropped.push(`--permission-mode ${values[0]} (the agent starts only ${MODES.join(", ")})`);
        break;
      case "--mcp-config":
        out.mcp.push(...values);
        break;
      case "--name":
      case "-n":
        out.dropped.push("--name (the seat's title is set anew)");
        break;
      case "--resume":
      case "-r":
      case "--continue":
      case "-c":
      case "--session-id":
        out.dropped.push(`${opt} (it resumes its conversation by id)`);
        break;
      case "--dangerously-skip-permissions":
      case "--allow-dangerously-skip-permissions":
        out.dropped.push(`${opt} (never started by the agent)`);
        break;
      default:
        out.carry.push(raw, ...(eq > 0 ? [] : values));
    }
  }
  out.argvNames = [
    ...(out.model ? ["--model"] : []),
    ...(out.effort ? ["--effort"] : []),
    ...out.mcp.map(() => "--mcp-config"),
    ...out.carry.filter(isOpt).map((a) => (a.includes("=") ? a.slice(0, a.indexOf("=")) : a)),
  ];
  return out;
}

// Environment cv-spawn sets fresh for every seat, or this rebuild sets itself:
// not carried. Per-process ones Claude Code sets for its own children too.
const SET_FRESH = new Set(["CLAUDIVERSE_TITLE", "CLAUDIVERSE_ORIGIN", "CLAUDIVERSE_FLEET", "CLAUDIVERSE_PROFILE", "CLAUDIVERSE_PROFILE_REVISION",
  "CLAUDIVERSE_TMUX", "CLAUDIVERSE_HOST", "CLAUDIVERSE_DEBUG", "CLAUDIVERSE_SKIP_TRUST", "CLAUDIVERSE_URL", "CLAUDIVERSE_TOKEN",
  "CLAUDIVERSE_HOST_AGENT_CONFIG", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
  "DISABLE_AUTOUPDATER", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"]);
const CARRIED = /^(CLAUDE_CODE_|CLAUDIVERSE_)/;
const POOL_URL = /\/proxy\/seat\//;

// A claude process's environment (["NAME=value", …]), read for a rebuild:
// { pooled, poolOnly, configDir, oauthToken, carry: {NAME: value}, envNames:
// [names the new seat gets], dropped: [what and why] }.
export function readClaudeEnv(envList) {
  const env = Object.fromEntries(envList.map((e) => [e.slice(0, e.indexOf("=")), e.slice(e.indexOf("=") + 1)]));
  const pooled = POOL_URL.test(env.ANTHROPIC_BASE_URL || "");
  const poolOnly = env.CLAUDE_CODE_OAUTH_TOKEN === "cv-pool";
  const carry = {};
  for (const [k, v] of Object.entries(env)) if (CARRIED.test(k) && !SET_FRESH.has(k)) carry[k] = v;
  const dropped = [];
  if (env.ANTHROPIC_BASE_URL && !pooled) dropped.push("ANTHROPIC_BASE_URL (not the server's pool; the agent never sets another endpoint)");
  return {
    pooled: pooled || poolOnly,
    poolOnly,
    configDir: env.CLAUDE_CONFIG_DIR || null,
    oauthToken: !poolOnly && env.CLAUDE_CODE_OAUTH_TOKEN ? env.CLAUDE_CODE_OAUTH_TOKEN : null,
    carry,
    envNames: Object.keys(carry).sort(),
    dropped,
  };
}

// --- the new seat's cv-spawn arguments -------------------------------------------------

// What cv-spawn is given to start the seat again, from readClaudeArgv `cl` and
// readClaudeEnv `ce`. `live` is the mode its room last heard (null if none:
// then the one it was started with); `tokenFile` the agent's login-token file
// when it holds the very token the process had. Returns { mode, extra (cv-spawn
// arguments after --title/--mode/--resume), argvNames, envNames, carried,
// dropped } (names, never values, but in extra).
export function rebuildArgs(cl, ce, { live = null, fleet = null, tokenFile = null } = {}) {
  const dropped = [...cl.dropped, ...ce.dropped];
  const mode = live || cl.mode || "default";
  if (cl.mode && mode !== cl.mode) dropped.push(`--permission-mode ${cl.mode} (it comes back in ${mode}, the mode it is in now)`);
  // CLAUDE_CONFIG_DIR is set again only when it was set: set even to the
  // default folder it moves Claude Code's own settings (.claude.json) into it,
  // and the seat comes back at first-run setup (measured, 2.1.296).
  const extra = ["--origin", "spawn", ...(ce.configDir ? ["--config-dir", ce.configDir] : []), ...(fleet ? ["--fleet", fleet] : [])];
  if (cl.model) extra.push("--model", cl.model);
  if (cl.effort) extra.push("--effort", cl.effort);
  for (const f of cl.mcp) extra.push("--mcp", f);
  if (ce.poolOnly) extra.push("--pool-only");
  else if (ce.pooled) extra.push("--pooled");
  if (ce.oauthToken && tokenFile) extra.push("--oauth-token-file", tokenFile);
  else if (ce.oauthToken) dropped.push("CLAUDE_CODE_OAUTH_TOKEN (a login token in its environment, in no file this agent knows; it comes back with its config dir's own login)");
  for (const arg of cl.carry) extra.push("--claude-arg", arg);
  for (const n of ce.envNames) extra.push("--carry-env", n);
  return {
    mode,
    extra,
    argvNames: ["--permission-mode", ...cl.argvNames, "--resume"],
    envNames: [...(ce.configDir ? ["CLAUDE_CONFIG_DIR"] : []), ...(ce.pooled ? ["ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS"] : []),
      ...(ce.poolOnly || (ce.oauthToken && tokenFile) ? ["CLAUDE_CODE_OAUTH_TOKEN"] : []), ...ce.envNames],
    carried: [...cl.argvNames, ...ce.envNames],
    dropped,
  };
}

// --- before the stop: can it start again? ------------------------------------------------

// Why the seat `replacing` could not start again under the cap of `max` seats
// this agent started, `alive` the titles of those still running; or null. A
// restart replaces a seat: the one being restarted is counted out, so a seat
// the agent started takes its own place back, and one it did not (started by
// hand, or before the agent's own restart) needs a free place. `taking`: the
// places seats planned before it in the same batch will take (a dry run's
// count; the real run checks each seat against the count then). Checked
// BEFORE the stop: a seat that cannot start again is never stopped.
export function capProblem(alive, replacing, max, taking = 0) {
  const others = [...alive].filter((t) => t !== replacing).length;
  if (others + taking < max) return null;
  return `would exceed max_seats (${max}): this machine already runs ${others} app-started seats` +
    (taking ? `, and the ${taking} restarted before it in this batch would take ${taking === 1 ? "a place" : "places"}` : "");
}

const sh = (s) => (/^[\w@%+=:,./-]+$/.test(s) ? s : `'${String(s).replace(/'/g, "'\\''")}'`);

// The command that brings a seat's conversation back by hand, for a seat that
// was stopped and could not be started again.
export function resumeCommand({ cwd, configDir = null, bin = "claude", sessionId }) {
  return `cd ${sh(cwd)} && ${configDir ? `CLAUDE_CONFIG_DIR=${sh(configDir)} ` : ""}${sh(bin)} --resume ${sh(sessionId)}`;
}
