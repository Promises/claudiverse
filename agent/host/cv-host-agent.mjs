#!/usr/bin/env node
// claudiverse host agent — one per machine. Connects OUT to the claudiverse
// server (no inbound ports, no ssh) on the "host:<name>" channel with this
// machine's own host token, and answers the server's requests:
//   ls     — the subfolders of a folder inside this machine's roots
//   spawn  — start a seat here with the local cv-spawn.sh
//   resume — start a stopped seat again, continuing its Claude Code session
//   stop   — close a seat's tmux session (only a seat working inside the roots)
//   interrupt — press Escape once in a seat's tmux session (same rule as stop):
//            the patched binary's sidecar has no interrupt handler, so this is
//            how the app's Interrupt reaches those seats
//   start_profile — start a seat from a seat profile (the server's Profiles):
//            folder inside the roots, and runtime, mode and MCP servers only
//            from what THIS machine's config offers (see host-agent.example.json)
//   add_root / remove_root — change the whitelist from the operator's desktop.
//
// It also runs the LOCAL RELAY when the config sets "relay_port" (lib/relay.mjs):
// a plain `claude` here points at http://127.0.0.1:<port> and its requests run
// on the account pool through the server's proxy, falling back to Anthropic
// directly (the session's own login) whenever the server can't serve them.
//            remove is always accepted (it only narrows); add ONLY if this
//            machine's own config says "allow_remote_roots": true.
// This file holds no secrets; everything comes from the per-machine config
// (see host-agent.example.json). Requires Node 22+ (built-in WebSocket).
//
// The roots are a WHITELIST that this machine controls (operator,
// 2026-10-04): `cv-host-agent.mjs add-root <folder>` appends one; the running
// agent notices the config change and re-joins with the new list, so the app
// sees it at once. The desktop may add one remotely only where this machine's
// config opts in with "allow_remote_roots": true — without it, nothing the
// server or app sends can add a root.
//
//   cv-host-agent.mjs                 run the agent (what the service does)
//   cv-host-agent.mjs add-root DIR    append DIR to the whitelist
//   cv-host-agent.mjs list-roots      print the whitelist
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { createRelay } from "./lib/relay.mjs";
import { CYCLE, footerMode, dialogOpen } from "./lib/mode.mjs";
import { sessionRecords, matchSeat, runnerSlots, runnerWorker, sameStart, tmuxSession, tmuxNames } from "./lib/adopt.mjs";
import { realRoots, listDirs, resolveInRoots, checkSpawn, checkResume, checkStopTitle, findTranscript, addRoot, removeRoot, Refusal,
         machineChoices, checkProfile, mcpConfigFor, isTrusted, trustKey, withTrust, setupDone, withSetupDone, spawnRuntime } from "./lib/rules.mjs";

const VERSION = "0.12.0";
const CONFIG_PATH = process.env.CLAUDIVERSE_HOST_AGENT_CONFIG || path.join(os.homedir(), ".config/claudiverse/host-agent.json");

function log(...a) {
  console.log(new Date().toISOString(), ...a);
}

const readJson = () => JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));

function writeJson(c) {
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(c, null, 2) + "\n", { mode: 0o600 });
  fs.chmodSync(CONFIG_PATH, 0o600);
}

function loadConfig() {
  const c = readJson();
  for (const k of ["server", "host_token", "seat_token", "cv_spawn"])
    if (!c[k]) throw new Error(`config ${CONFIG_PATH}: "${k}" is required`);
  return {
    name: c.name || os.hostname(), // must equal the CLAUDIVERSE_HOST this machine's seats report
    max_seats: 10,
    min_interval_s: 10,
    // Where Claude Code keeps conversations for the seats this agent starts.
    claude_config_dir: process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude"),
    // Claude Code's global config (folder trust): inside CLAUDE_CONFIG_DIR when set.
    claude_json: process.env.CLAUDE_CONFIG_DIR ? path.join(process.env.CLAUDE_CONFIG_DIR, ".claude.json") : path.join(os.homedir(), ".claude.json"),
    // The MCP servers a profile may name, by name: { "mcpServers": { ... } }.
    mcp_catalog: path.join(os.homedir(), ".config/claudiverse/mcp-catalog.json"),
    // Where the MCP config generated for each profile's seat is written.
    profile_dir: path.join(os.homedir(), ".config/claudiverse/profiles"),
    ...c,
    roots: Array.isArray(c.roots) ? c.roots : [],
  };
}

// --- the whitelist commands (edit the config, then exit) ------------------------

if (process.argv[2] === "list-roots") {
  for (const r of readJson().roots || []) console.log(r);
  process.exit(0);
}

if (process.argv[2] === "add-root") {
  try {
    const r = await addRoot(readJson(), process.argv[3]);
    if (r.changed) writeJson(r.config);
    console.log(r.changed ? `whitelisted ${r.roots.at(-1)} (the running agent picks it up within a few seconds)` : "already whitelisted");
    process.exit(0);
  } catch (e) {
    console.error(`add-root: ${e.message}`);
    process.exit(1);
  }
}

const cfg = loadConfig();
// Checked at start: a spawn_runtime naming no runtime stops the agent here,
// rather than every New seat failing later.
const SPAWN_RUNTIME = spawnRuntime(cfg);
let roots = [];

// Read fresh each time: the flag is the machine's, edited in its config.
function remoteAllowed() {
  try {
    return readJson().allow_remote_roots === true;
  } catch {
    return false;
  }
}

// Resolve the configured roots. Async and timed (see lib/rules.mjs): a root
// the machine will not let the agent resolve is skipped with a warning, never
// waited on, so the agent always comes online and keeps answering.
async function applyRoots(list) {
  const resolved = await realRoots(list);
  for (const r of list) {
    if (!(await realRoots([r])).length) log(`warning: root ${r} does not exist or cannot be read yet; ignored`);
  }
  roots = resolved;
  if (!roots.length) log("the whitelist is empty: no folders are offered until one is added (add-root)");
}

await applyRoots(cfg.roots);

// --- spawning ----------------------------------------------------------------------

const SURVIVE_MS = 5000;
const spawned = new Set(); // titles this agent started (its cap counts only these)
let lastSpawnAt = 0;

function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: 110_000, maxBuffer: 1 << 20, ...opts }, (err, stdout, stderr) =>
      resolve({ code: err ? (err.code ?? 1) : 0, stdout: String(stdout), stderr: String(stderr) }));
  });
}

const tmuxHas = async (title) => (await run("tmux", ["has-session", "-t", `=${title}`])).code === 0;

// The machine's MCP catalog, read fresh (an edit applies to the next start).
// Missing or unreadable: no servers to offer.
function readCatalog() {
  try {
    const c = JSON.parse(fs.readFileSync(cfg.mcp_catalog, "utf8"));
    return c && typeof c.mcpServers === "object" ? c : { mcpServers: {} };
  } catch {
    return { mcpServers: {} };
  }
}

// Write `file` whole or not at all (a rename never leaves half a file).
function writeAtomic(file, text, mode) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text, { mode });
  fs.renameSync(tmp, file);
}

// The git root of `dir` (real path), or null outside a repo.
async function gitRoot(dir) {
  const r = await run("git", ["-C", dir, "rev-parse", "--show-toplevel"]);
  if (r.code !== 0 || !r.stdout.trim()) return null;
  try {
    return fs.realpathSync(r.stdout.trim());
  } catch {
    return null;
  }
}

// Trust `dir` in Claude Code's global config unless Claude Code would already
// (see isTrusted), on the entry its own dialog would set (the repo root), and
// mark its first-run setup done if it never ran (see setupDone): a seat must
// start with no dialog waiting. Only ever adds those flags; Claude Code
// rewrites this file itself, so it is read just before and replaced in one
// rename.
// claudeJson: the .claude.json the seat will read, its runtime's config dir's
// when it has one (CLAUDE_CONFIG_DIR moves it there), else the machine's.
async function ensureTrusted(dir, claudeJson = cfg.claude_json) {
  const root = await gitRoot(dir);
  let json = {};
  try {
    json = JSON.parse(fs.readFileSync(claudeJson, "utf8"));
  } catch (e) {
    if (e.code !== "ENOENT") throw new Refusal("error", `cannot read ${claudeJson} to trust ${dir}: ${e.message}`);
  }
  const trusted = isTrusted(json, dir, root);
  const setUp = setupDone(json);
  if (trusted && setUp) return;
  const key = trustKey(dir, root);
  if (!trusted) json = withTrust(json, key);
  if (!setUp) json = withSetupDone(json);
  writeAtomic(claudeJson, JSON.stringify(json, null, 2), 0o600);
  if (!setUp) log(`marked Claude Code's first-run setup done in ${claudeJson}`);
  if (!trusted) log(`trusted ${key}${root ? ` (the git root of ${dir})` : ""} in ${claudeJson}`);
}

async function startProfile(args) {
  const catalog = readCatalog();
  const p = await checkProfile(args, roots, cfg, catalog);

  // "latest" is the server's guess from any machine's seats; a conversation
  // that is not on THIS machine starts fresh rather than failing forever. An
  // explicitly chosen one must exist (startSeat refuses).
  // Conversations and trust live in the runtime's own config dir when it has one.
  const configDir = p.configDir || cfg.claude_config_dir;
  let sessionId = p.resume;
  if (sessionId && p.resumePolicy === "latest" && !findTranscript(configDir, p.dir, sessionId)) {
    log(`profile ${p.name}: conversation ${sessionId} is not on this machine; starting a new one`);
    sessionId = null;
  }

  const argv = ["--origin", "profile", "--profile", String(p.profileId), "--revision", String(p.revision), "--host", cfg.name];
  if (p.model) argv.push("--model", p.model);
  if (p.effort) argv.push("--effort", p.effort);
  if (p.fleet) argv.push("--fleet", p.fleet);
  if (p.debug) argv.push("--debug");
  if (p.poolOnly) argv.push("--pool-only");
  else if (p.pooled) argv.push("--pooled");
  if (p.configDir) argv.push("--config-dir", p.configDir);
  if (p.oauthTokenFile) argv.push("--oauth-token-file", p.oauthTokenFile);
  if (p.mcp.length) {
    fs.mkdirSync(cfg.profile_dir, { recursive: true, mode: 0o700 });
    const file = path.join(cfg.profile_dir, `${p.name}.mcp.json`);
    writeAtomic(file, JSON.stringify(mcpConfigFor(catalog, p.mcp), null, 2) + "\n", 0o600);
    argv.push("--mcp", file);
  }
  await ensureTrusted(p.dir, p.configDir ? path.join(p.configDir, ".claude.json") : cfg.claude_json);

  log(`profile ${p.name} r${p.revision}: ${p.runtime}${p.poolOnly ? ", pool only" : p.pooled ? ", pooled" : ""}, mcp [${p.mcp.join(", ")}]`);
  return startSeat({ dir: p.dir, title: p.name, mode: p.mode, sessionId, bin: p.bin, extra: argv, configDir });
}

// The app's New seat and resume: on `spawn_runtime` when the machine names
// one, launched as a profile on that runtime is (its binary, login token file
// and config dir, the folder trusted so no dialog waits); else on `bin`.
async function startPlain(seat) {
  const rt = SPAWN_RUNTIME;
  if (!rt) return startSeat(seat);
  const argv = ["--origin", "spawn"];
  if (cfg.mcp) argv.push("--mcp", cfg.mcp);
  if (rt.configDir) argv.push("--config-dir", rt.configDir);
  if (rt.oauthTokenFile) argv.push("--oauth-token-file", rt.oauthTokenFile);
  if (rt.poolOnly) argv.push("--pool-only");
  else if (rt.pooled) argv.push("--pooled");
  await ensureTrusted(seat.dir, rt.configDir ? path.join(rt.configDir, ".claude.json") : cfg.claude_json);
  return startSeat({ ...seat, bin: rt.bin, extra: argv, configDir: rt.configDir || cfg.claude_config_dir });
}

// spawn, resume and start_profile share everything but the checks and the
// cv-spawn flags. A profile brings its own binary and flags (`bin`, `extra`)
// in place of the machine's spawn defaults.
async function startSeat({ dir, title, mode, prompt, sessionId, bin, extra, configDir = cfg.claude_config_dir }) {
  if (sessionId && !findTranscript(configDir, dir, sessionId))
    throw new Refusal("not_found", `nothing to resume: conversation ${sessionId} does not exist here (a seat that never had a turn has none)`);

  const now = Date.now();
  if (now - lastSpawnAt < cfg.min_interval_s * 1000) throw new Refusal("limit", `at most one spawn per ${cfg.min_interval_s} s`);
  for (const t of spawned) if (!(await tmuxHas(t))) spawned.delete(t);
  if (spawned.size >= cfg.max_seats) throw new Refusal("limit", `this machine already runs ${spawned.size} app-started seats (max ${cfg.max_seats})`);
  if (await tmuxHas(title)) throw new Refusal("bad_request", `a seat named ${title} already runs here`);
  lastSpawnAt = now;

  const argv = [dir, "--title", title, "--mode", mode];
  if (sessionId) argv.push("--resume", sessionId);
  if (prompt) argv.push("--prompt", prompt);
  if (extra) {
    argv.push(...extra, "--bin", bin);
  } else {
    argv.push("--origin", "spawn");
    if (cfg.mcp) argv.push("--mcp", cfg.mcp);
    if (cfg.bin) argv.push("--bin", cfg.bin);
  }

  // The seat gets THIS machine's ordinary seat token — never anything the
  // server sent — and none of the agent's own opt-ins (notify, fleet).
  const env = { ...process.env, CLAUDIVERSE_URL: cfg.server, CLAUDIVERSE_TOKEN: cfg.seat_token };
  for (const k of ["CLAUDIVERSE_NOTIFY", "CLAUDIVERSE_FLEET", "CLAUDIVERSE_ORIGIN", "CLAUDIVERSE_HOST_AGENT_CONFIG"]) delete env[k];

  log(`${sessionId ? `resume ${sessionId} as` : "spawn"} ${title} in ${dir} (mode ${mode})`);
  const r = await run(cfg.cv_spawn, argv, { env });
  if (r.code !== 0) throw new Refusal("spawn_failed", (r.stderr || r.stdout).trim().split("\n").slice(-3).join(" ").slice(0, 500));

  // cv-spawn only sees the command START. A claude that exits at once (a
  // conversation it cannot load, a bad flag) would still be reported as ok, so
  // check it is still running a moment later, and clear away the dead session.
  await new Promise((res) => setTimeout(res, SURVIVE_MS));
  const cmd = (await tmuxHas(title))
    ? (await run("tmux", ["display-message", "-p", "-t", `=${title}:`, "#{pane_current_command}"])).stdout.trim()
    : "";
  if (["", "sh", "bash", "zsh", "fish"].includes(cmd)) {
    await run("tmux", ["kill-session", "-t", `=${title}`]);
    throw new Refusal("spawn_failed", `${title} exited within ${SURVIVE_MS / 1000} s of starting`);
  }
  spawned.add(title);
  return { title };
}

// Close a seat's tmux session. Only one whose pane works inside the roots, so
// the app reaches no further than it can spawn. The conversation stays on
// disk, so the seat can be resumed.
// A running seat this agent may act on: its tmux session exists and its pane
// works inside the roots. Returns the title.
async function seatInRoots(args) {
  const title = checkStopTitle(args);
  // has-session first: display-message on a missing target exits 0 with empty output.
  if (!(await tmuxHas(title))) throw new Refusal("not_found", `no seat named ${title} runs here`);
  const r = await run("tmux", ["display-message", "-p", "-t", `=${title}:`, "#{pane_current_path}"]);
  const folder = r.stdout.trim();
  if (r.code !== 0 || !folder) throw new Refusal("error", `could not read ${title}'s folder`);
  await resolveInRoots(folder, roots);
  return title;
}

// ONE Escape: Claude Code stops the turn (or dismisses a permission prompt).
// Never two — a second quick Escape opens the rewind menu.
async function interruptSeat(args) {
  const title = await seatInRoots(args);
  const k = await run("tmux", ["send-keys", "-t", `=${title}:`, "Escape"]);
  if (k.code !== 0) throw new Refusal("error", `tmux send-keys failed: ${k.stderr.trim()}`);
  log(`interrupt ${title}`);
  return { title };
}

// The Claude Code session record of the claude running in tmux session
// `title`'s pane (the pane's process or its child), or null.
async function paneSession(title) {
  const pane = Number((await run("tmux", ["display-message", "-p", "-t", `=${title}:`, "#{pane_pid}"])).stdout.trim());
  if (!Number.isInteger(pane) || pane <= 0) return null;
  const children = (await run("pgrep", ["-P", String(pane)])).stdout.split("\n").map(Number).filter(Boolean);
  const pids = new Set([pane, ...children]);
  return sessionRecords(configDirs()).find((r) => pids.has(r.pid)) ?? null;
}

// The tmux sessions with a Claude Code process in their pane, named at each
// join: the server's autostart starts a profile whose row still reads running
// while none lives here (the machine rebooted, the process died). MEASURED
// 2026-10-11: after an unexpected reboot every profile's row read running, so
// autostart skipped them all until the agent was restarted by hand. Null when
// tmux could not say, and the server changes nothing.
async function liveSeats() {
  const titles = tmuxNames(await run("tmux", ["list-sessions", "-F", "#{session_name}"]));
  if (!titles) return null;
  const live = [];
  for (const title of titles) if (await paneSession(title)) live.push(title);
  return live;
}

// Every seat's mode, read from its footer, reported to the server on change
// ("seat_modes"), so the apps show the mode a mod seat is really in: unlike a
// patched seat, it reports none itself. A pane with a dialog open is skipped
// (the dialog hides the footer); `reportedModes` is cleared on each join, as
// the server forgets them on a restart.
let reportedModes = {};
const MODE_SWEEP_MS = 10_000;

async function sweepModes() {
  if (ws?.readyState !== WebSocket.OPEN) return;
  const byPid = new Map(sessionRecords(configDirs()).map((r) => [r.pid, r]));
  const titles = (await run("tmux", ["list-sessions", "-F", "#{session_name}"])).stdout.split("\n").filter(Boolean);
  const changed = {};
  for (const title of titles) {
    const pane = Number((await run("tmux", ["display-message", "-p", "-t", `=${title}:`, "#{pane_pid}"])).stdout.trim());
    if (!Number.isInteger(pane) || pane <= 0) continue;
    const pids = [pane, ...(await run("pgrep", ["-P", String(pane)])).stdout.split("\n").map(Number).filter(Boolean)];
    if (!pids.some((p) => byPid.has(p))) continue;
    // A failed or empty capture says nothing: read as a footer it would be
    // "default", so it is skipped instead.
    const cap = await run("tmux", ["capture-pane", "-p", "-t", `=${title}:`]);
    const text = cap.code === 0 ? cap.stdout : "";
    if (!text.trim() || dialogOpen(text)) continue;
    const mode = footerMode(text);
    if (reportedModes[title] !== mode) changed[title] = reportedModes[title] = mode;
  }
  if (Object.keys(changed).length) send("seat_modes", { modes: changed });
}

// set_mode {title, mode}: switch a running seat's permission mode with
// Shift+Tab until its footer shows `mode`, as a person at its terminal would.
// The pane is addressed by its exact session ("=title:"), only while the seat
// is idle (its own session record says so) with no dialog open, and at most one
// full cycle is pressed: a mode not reached by then is not in its cycle.
async function setMode(args) {
  const title = await seatInRoots(args);
  const mode = args?.mode;
  if (!CYCLE.includes(mode)) throw new Refusal("bad_request", `mode must be one of ${CYCLE.join(", ")}`);
  const record = await paneSession(title);
  if (!record) throw new Refusal("not_found", `cannot find the Claude Code session running in ${title}`);
  if (record.status !== "idle") throw new Refusal("busy", `${title} is mid-turn; switch its mode when it is idle`);
  const pane = async () => (await run("tmux", ["capture-pane", "-p", "-t", `=${title}:`])).stdout;
  let now = await pane();
  if (dialogOpen(now)) throw new Refusal("busy", `${title} has a dialog open; answer it first`);
  for (let presses = 0; footerMode(now) !== mode; presses++) {
    if (presses >= CYCLE.length) throw new Refusal("not_allowed", `${mode} is not in ${title}'s Shift+Tab cycle (it stays ${footerMode(now)})`);
    const k = await run("tmux", ["send-keys", "-t", `=${title}:`, "BTab"]);
    if (k.code !== 0) throw new Refusal("error", `tmux send-keys failed: ${k.stderr.trim()}`);
    await new Promise((res) => setTimeout(res, 400));
    now = await pane();
  }
  log(`mode ${title}: ${mode}`);
  return { title, mode };
}

async function stopSeat(args) {
  const title = await seatInRoots(args);
  log(`stop ${title}`);
  const k = await run("tmux", ["kill-session", "-t", `=${title}`]);
  if (k.code !== 0) throw new Refusal("error", `tmux kill-session failed: ${k.stderr.trim()}`);
  spawned.delete(title);
  return { title };
}

// --- adopt (lib/adopt.mjs) ------------------------------------------------------

// Every config dir a seat on this machine may use: the machine's and each
// runtime's own (CLAUDE_CONFIG_DIR).
const configDirs = () => [cfg.claude_config_dir, ...Object.values(cfg.runtimes || {}).map((r) => r?.config_dir)]
  .filter((d) => typeof d === "string" && path.isAbsolute(d));

const pidAlive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === "EPERM";
  }
};

const utcStart = async (pid) => (await run("ps", ["-o", "lstart=", "-p", String(pid)], { env: { ...process.env, TZ: "UTC" } })).stdout.trim();

// The config dir `runtime` keeps conversations in, or null for a runtime this
// machine does not have.
function runtimeConfigDir(runtime) {
  const r = cfg.runtimes?.[runtime];
  if (!r) return null;
  return typeof r.config_dir === "string" && path.isAbsolute(r.config_dir) ? r.config_dir : cfg.claude_config_dir;
}

// The seat's process, checked: alive, the same process the record was written
// for, inside the roots, not a runner's worker. Throws a Refusal otherwise.
async function adoptable({ session_ids, title, cwd }) {
  const m = matchSeat(sessionRecords(configDirs()), { sessionIds: session_ids || [], title, cwd }, pidAlive);
  if (m.none) throw new Refusal("not_found", m.none);
  if (m.several) throw new Refusal("several", m.several);
  const r = m.record;
  if (!sameStart(r.procStart, await utcStart(r.pid)))
    throw new Refusal("process_changed", `pid ${r.pid} is no longer the process its record names; look again`);
  await resolveInRoots(r.cwd, roots);
  if (runnerWorker(title, runnerSlots((await run("ps", ["-axo", "args="])).stdout)))
    throw new Refusal("runner", `${title} is a worker of a cv-runner slot here; its runner stops and starts it`);
  return { record: r, matchedBy: m.matchedBy };
}

// locate_seat {session_ids, title, cwd, runtime}: what adopting would stop.
// `transcript` says whether `runtime` can resume the conversation.
async function locateSeat(args) {
  const { record: r, matchedBy } = await adoptable(args || {});
  const dir = args?.runtime ? runtimeConfigDir(args.runtime) : null;
  return {
    pid: r.pid, proc_start: r.procStart, tmux: r.tmux ?? null, status: r.status ?? null, version: r.version ?? null,
    matched_by: matchedBy, session_id: r.sessionId.toLowerCase(), cwd: r.cwd, name: r.name ?? null,
    transcript: dir ? Boolean(findTranscript(dir, r.cwd, r.sessionId)) : null,
  };
}

// release_seat {pid, proc_start, session_ids, title, cwd, runtime, force}:
// stop the seat's process so its profile can start, re-checking everything the
// preview showed. SIGTERM to that one pid; SIGKILL only with force. Its tmux
// session, if it outlives the process (a shell pane) and has the profile's
// name, is renamed so the profile can take the name. Refusals leave the
// process untouched.
async function releaseSeat(args) {
  const a = args || {};
  const { record: r } = await adoptable(a);
  if (r.pid !== a.pid || !sameStart(r.procStart, a.proc_start))
    throw new Refusal("process_changed", `the seat now runs as pid ${r.pid}, not the pid ${a.pid} the preview showed; look again`);
  const dir = runtimeConfigDir(a.runtime);
  if (!dir) throw new Refusal("not_allowed", `runtime ${a.runtime} is not configured here`);
  if (!findTranscript(dir, r.cwd, r.sessionId))
    throw new Refusal("not_found", `runtime ${a.runtime} keeps conversations in ${dir}, and ${r.sessionId} is not there; it would start a new conversation`);
  if (r.status === "busy" && a.force !== true) throw new Refusal("busy", `${a.title} is mid-turn; wait, or stop it anyway`);

  log(`adopt ${a.title}: stopping pid ${r.pid} (${r.version}, ${r.tmux || "no tmux"})`);
  process.kill(r.pid, "SIGTERM");
  const gone = async (ms) => {
    for (let t = 0; t < ms; t += 200) {
      if (!pidAlive(r.pid)) return true;
      await new Promise((res) => setTimeout(res, 200));
    }
    return !pidAlive(r.pid);
  };
  if (!(await gone(10_000))) {
    if (a.force !== true) throw new Refusal("busy", `pid ${r.pid} did not exit within 10 s of SIGTERM; stop it anyway to kill it`);
    process.kill(r.pid, "SIGKILL");
    if (!(await gone(5_000))) throw new Refusal("error", `pid ${r.pid} survived SIGKILL`);
  }
  // Its record goes with it; a stale one would make the next locate see a ghost.
  for (let t = 0; t < 2000 && fs.existsSync(r.file); t += 200) await new Promise((res) => setTimeout(res, 200));
  if (fs.existsSync(r.file)) fs.rmSync(r.file, { force: true });

  const old = tmuxSession(r.tmux);
  if (old && old === a.title && (await tmuxHas(old))) {
    const moved = `${old}-pre-adopt`;
    await run("tmux", ["rename-session", "-t", `=${old}`, moved]);
    log(`adopt ${a.title}: its old tmux session lives on as ${moved}`);
  }
  return { stopped: r.pid, session_id: r.sessionId.toLowerCase() };
}

// The desktop's whitelist edits. The config file is the record, and the
// watcher below re-joins with the new list, so the app sees the change.
async function remoteRoots(op, args) {
  const c = readJson();
  if (op === "add_root" && c.allow_remote_roots !== true)
    throw new Refusal("not_allowed", `${cfg.name} does not accept folders from the desktop (set "allow_remote_roots": true in its config)`);
  if (typeof args?.path !== "string" || !path.isAbsolute(args.path)) throw new Refusal("bad_request", "path must be an absolute folder path");
  const r = op === "add_root" ? await addRoot(c, args.path) : await removeRoot(c, args.path);
  if (r.changed) {
    writeJson(r.config);
    log(`${op} ${args.path} (from the desktop)`);
    await applyRoots(r.roots);
    rejoinSoon(); // after this reply is sent, so the server's list updates
  }
  return { roots };
}

async function handle(op, args) {
  if (op === "add_root" || op === "remove_root") return remoteRoots(op, args);
  if (op === "ls") return listDirs(args?.path || "", roots);
  if (op === "spawn") return startPlain(await checkSpawn(args || {}, roots));
  if (op === "resume") return startPlain(await checkResume(args || {}, roots));
  if (op === "start_profile") return startProfile(args || {});
  if (op === "stop") return stopSeat(args || {});
  if (op === "set_mode") return setMode(args);
  if (op === "locate_seat") return locateSeat(args);
  if (op === "release_seat") return releaseSeat(args);
  if (op === "interrupt") return interruptSeat(args || {});
  throw new Refusal("bad_request", `unknown op ${op}`);
}

// --- the channel (Phoenix V2 protocol: [join_ref, ref, topic, event, payload]) ---

const topic = `host:${cfg.name}`;

// Re-join (close; "close" reconnects) so the server gets the current roots
// and remote_roots flag in the join payload.
function rejoinSoon() {
  setTimeout(() => ws?.close(), 200);
}
let ws = null;
let ref = 0;
let joinRef = null;
let heartbeat = null;
let backoff = 2000;

function send(event, payload, jr = joinRef, t = topic) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify([jr, String(++ref), t, event, payload]));
}

function connect() {
  const url = cfg.server.replace(/^http/, "ws").replace(/\/$/, "") + `/socket/websocket?vsn=2.0.0&token=${encodeURIComponent(cfg.host_token)}`;
  ws = new WebSocket(url);

  ws.addEventListener("open", async () => {
    backoff = 2000;
    joinRef = String(++ref);
    const jr = joinRef;
    const live = await liveSeats().catch(() => null);
    // A socket that closed or rejoined meanwhile is not this join's.
    if (jr !== joinRef || ws?.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify([joinRef, joinRef, topic, "phx_join", { roots, version: VERSION, remote_roots: remoteAllowed(), ...machineChoices(cfg, readCatalog()), ...(live ? { live_seats: live } : {}) }]));
    clearInterval(heartbeat);
    heartbeat = setInterval(() => send("heartbeat", {}, null, "phoenix"), 30_000);
  });

  ws.addEventListener("message", async (msg) => {
    let frame;
    try {
      frame = JSON.parse(msg.data);
    } catch {
      return;
    }
    const [, , t, event, payload] = frame;
    if (t !== topic) return;

    if (event === "phx_reply" && payload?.status === "ok" && frame[1] === joinRef) {
      log(`online as ${topic} (roots: ${roots.join(", ")})`);
      reportedModes = {};
    } else if (event === "phx_reply" && payload?.status === "error") {
      log(`join refused: ${JSON.stringify(payload.response)} — check host_token and name`);
    } else if (event === "phx_close" || event === "phx_error") {
      ws.close();
    } else if (event === "request") {
      const { request_id, op, args } = payload || {};
      try {
        send("reply", { request_id, ok: true, result: await handle(op, args) });
      } catch (e) {
        const code = e instanceof Refusal ? e.code : "error";
        if (!(e instanceof Refusal)) log(`error in ${op}:`, e);
        send("reply", { request_id, ok: false, code, error: e.message, ...(e?.path ? { path: e.path } : {}) });
      }
    }
  });

  ws.addEventListener("close", () => {
    clearInterval(heartbeat);
    log(`disconnected; reconnecting in ${backoff / 1000} s`);
    setTimeout(connect, backoff);
    backoff = Math.min(backoff * 2, 30_000);
  });

  ws.addEventListener("error", () => {}); // "close" follows and reconnects
}

// The whitelist can grow while running: re-read it, and on a change re-join
// so the server (and the app) get the new list. Polling, not fs.watch: an
// editor's save-by-rename would silently end an fs.watch watcher.
let joinedRemote = remoteAllowed();
fs.watchFile(CONFIG_PATH, { interval: 2000 }, async () => {
  let list;
  try {
    list = readJson().roots || [];
  } catch (e) {
    log(`config unreadable, keeping the current whitelist: ${e.message}`);
    return;
  }
  const before = JSON.stringify(roots);
  await applyRoots(list);
  const remote = remoteAllowed();
  if (JSON.stringify(roots) !== before || remote !== joinedRemote) {
    joinedRemote = remote;
    log(`whitelist changed: ${roots.join(", ") || "(empty)"}; remote folders ${remote ? "allowed" : "not allowed"}; re-joining`);
    ws?.close();
  }
});

// A catalog edit changes what profiles may choose here: re-join so the
// server's host list (the desktop's menus) shows it.
fs.watchFile(cfg.mcp_catalog, { interval: 2000 }, () => {
  log(`MCP catalog changed: ${machineChoices(cfg, readCatalog()).mcp.join(", ") || "(none)"}; re-joining`);
  ws?.close();
});

// The local relay (opt-in): loopback only, so nothing on the network reaches it.
if (Number.isInteger(cfg.relay_port) && cfg.relay_port > 0) {
  const relay = createRelay({ server: cfg.server.replace(/\/$/, ""), token: cfg.seat_token, machine: cfg.name, log });
  relay.on("error", (e) => log(`relay: cannot listen on 127.0.0.1:${cfg.relay_port}: ${e.message}`));
  relay.listen(cfg.relay_port, "127.0.0.1", () => log(`relay: listening on 127.0.0.1:${cfg.relay_port}`));
}

log(`claudiverse host agent ${VERSION}: ${cfg.name} -> ${cfg.server}`);
connect();
// One sweep at a time: a slow tmux never stacks them.
let sweeping = false;
setInterval(async () => {
  if (sweeping) return;
  sweeping = true;
  try {
    await sweepModes();
  } catch (e) {
    log("mode sweep failed:", e.message);
  } finally {
    sweeping = false;
  }
}, MODE_SWEEP_MS);
