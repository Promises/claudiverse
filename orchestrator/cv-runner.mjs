#!/usr/bin/env node
//
// cv-runner — a slot. Run one per terminal; the terminal IS the reservation.
//
//   cv-runner.mjs --slot w1 --channel tasks --workdir /abs/path [--mcp worker.mcp.json]
//
// Claims one task, spawns an ephemeral worker for it, waits for that worker to
// declare itself done, reaps it, and loops. N terminals = N slots = a hard
// concurrency cap, which nothing else in this system currently provides.
//
// WHY A RUNNER AT ALL: nothing owns a worker's lifecycle today. cv_ps found
// sessions the server lists as running with no process behind them — orphans
// and ghosts are structural when spawn and reap have no single owner. A slot
// that holds the kill switch is also the right place to enforce the harvest
// gate, because it is the only party present at the moment state is destroyed.
//
// THE RULE THIS IS BUILT AROUND: **idle is not done.** An idle seat that has
// finished and one that is mid-thought produce identical output; a quota-dead
// seat reported "busy" for four and a half hours. So this runner NEVER reaps on
// idleness, elapsed time, or silence. It reaps on exactly one signal — the
// worker calling cv_task_done, which itself refuses without a handoff.
//
// AND IT NEVER KILLS ON TIMEOUT. A stuck worker is information; killing it
// destroys the evidence of why it stuck. On timeout the runner ESCALATES and
// keeps waiting. The human keeps the override.
//
import { execFile, spawn } from "node:child_process";
import { readFileSync, accessSync, existsSync, mkdtempSync, writeFileSync, rmSync, constants as fsConstants } from "node:fs";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { homedir, hostname, tmpdir } from "node:os";
import * as cv from "./cv-core.mjs";
import { VALIDATION_PREFIX, NO_AUTO_VALIDATE, isValidationTask, validationExemption } from "./cv-validation.mjs";

const execFileP = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));

// A flag's value is never another flag. Without this check, `--fleet --validate`
// silently sets FLEET="--validate" AND swallows --validate: the runner then looks
// correctly configured while being un-haltable by any scoped halt. Found by audit.
// Harmless for the other options (none takes a `--`-prefixed value); it matters
// here because --fleet is the first flag whose mis-parse degrades a SAFETY
// mechanism rather than a convenience one, and it degrades it invisibly.
const arg = (name, dflt) => {
  const i = process.argv.indexOf("--" + name);
  const v = i > -1 ? process.argv[i + 1] : undefined;
  return v && !v.startsWith("--") ? v : dflt;
};
const has = (name) => process.argv.includes("--" + name);

const SLOT = arg("slot");
const CHANNEL = arg("channel", "tasks");
const WORKDIR = arg("workdir");
const MCP = arg("mcp");
// Which claude binary the workers run on. Unset = cv-spawn's own DEFAULT_BIN.
//
// This exists so a new patched build can be rolled out PER SLOT instead of by
// replacing patch-ref/claude, which every seat in every fleet resolves through.
// Overwriting that file upgrades the whole estate at once and has no rollback
// short of restoring a copy; a flag lets one slot run the new build beside three
// on the old one, and reverting is removing the flag.
const BIN = arg("bin");
const MODE = arg("mode", "auto");
const POLL_MS = Number(arg("poll", "5000"));

// --- where claimable work comes from ----------------------------------------
// "forum" (default) = the legacy status=incoming forum-post queue.
// "tasks"           = Component E's real rows: READY state, integer priority,
//                     dependency edges, and a logged event trail.
//
// ⭐ PER-FLEET ON PURPOSE, and defaulting to the legacy path. This runner is
// SHARED BY BOTH FLEETS — ipsum-w5 and ipsum-w7 run --fleet ipsum-fleet today. A big-bang
// cutover would move ipsum-fleet at the same moment as lorem-fleet, for no reason. The halted
// fleet flips first and proves it; the live one follows when it suits.
//
// ⚠️ The two sources must never be mixed within one slot: a task claimed from
// one and completed against the other is exactly the strand this replaces.
const TASK_SOURCE = arg("task-source", "forum");
if (!["forum", "tasks"].includes(TASK_SOURCE)) {
  console.error(`--task-source must be "forum" or "tasks", got ${JSON.stringify(TASK_SOURCE)}`);
  process.exit(2);
}
// Where a tasks-path escalation alert goes besides the task's own event trail.
// "forum" (default) = a top-level post in the lane channel. "notify" = a direct
// ping from source `tasks:<lane>` to whoever watches it, and no forum post. A
// stall alert is useful once; the durable record is the task event.
// Per fleet, like --task-source; operator 2026-10-02 moved lorem-fleet off one-shot posts.
const ESCALATE_VIA = arg("escalate-via", "forum");
if (!["forum", "notify"].includes(ESCALATE_VIA)) {
  console.error(`--escalate-via must be "forum" or "notify", got ${JSON.stringify(ESCALATE_VIA)}`);
  process.exit(2);
}
const STUCK_MIN = Number(arg("stuck-after", "30"));
// Backstop for when CPU cannot be measured at all — deliberately long, because
// its only job is to stop an unreadable process table from silencing the alarm.
const STUCK_HARD_MIN = Number(arg("stuck-hard-after", "180"));
// CPU seconds across the tree that count as "this worker did something".
const CPU_EPS_S = Number(arg("cpu-epsilon", "0.5"));
const ONCE = has("once");
const ATTACH_RW = has("attach-rw");
const ATTACH = has("attach") || ATTACH_RW;
const VALIDATE = has("validate");
const CHARTER_PATH = arg("charter");
const FLEET = arg("fleet");

// --task-source=tasks scopes every claim by fleet. Without --fleet the claim
// would be for fleet=undefined, which matches nothing — a runner that polls
// forever and looks merely idle. Refuse at startup instead: a misconfiguration
// that presents as "no work available" is the expensive kind.
if (TASK_SOURCE === "tasks" && !FLEET) {
  console.error("--task-source tasks requires --fleet (claims are scoped by fleet)");
  process.exit(2);
}
// Model for the workers this slot spawns. Unset = the binary's default.
//
// VALIDATE_MODEL exists because the two tiers do different jobs: a task brief is now
// heavily specified — exact commands, frozen ground, named fail arms — so execution is
// tractable for a cheaper model. VALIDATION is not: it must judge whether the criteria
// THEMSELVES were sufficient, which is open-ended. Measured 2026-08-17: most defects
// this fleet has found were in the SPECIFICATION, not the execution.
//
// ⚠️ AND IT IS NOT A QUALITY BACKSTOP. A weak run does not fail loudly — ipsum-orchestrator's own
// test showed a worker that runs NOTHING and writes plausible prose passes all five
// fail arms, because arms grade the DESCRIPTION of method. Only proof-of-work that
// someone re-runs catches that. Spending the stronger model on validation puts it
// where that check happens; it does not make the check automatic.
const MODEL = arg("model");
const VALIDATE_MODEL = arg("validate-model", MODEL);
// Reasoning effort: low|medium|high|xhigh|max. Same two-tier logic as MODEL — a
// heavily-specified execution brief needs less deliberation than a validation that
// must judge whether the criteria themselves were sufficient.
//
// ⚠️ NOTE for anyone reaching for a spend cap: the binary's --max-budget-usd exists
// but its own help says "only works with --print". These workers run an interactive
// REPL, so it does NOT apply to them. Cost control here is model + effort, not a cap.
const EFFORT = arg("effort");
const VALIDATE_EFFORT = arg("validate-effort", EFFORT);
// Where an auto-enqueued VALIDATE task is POSTED. Defaults to this slot's own
// channel, which is the old behaviour — and which quietly defeats a two-tier setup:
// a cheap slot would validate its own cheap work, so the stronger model never sees
// it. Pointing this at the deeper channel is what makes "execute cheap, verify
// expensive" actually happen rather than merely be configured.
const VALIDATE_CHANNEL = arg("validate-channel", null);
// Where an auto-enqueued validation LANDS. A runner claiming from --task-source
// tasks used to post its validations to the FORUM, so nothing it could ever claim
// was created: the validation existed, read as enqueued, and no seat in the fleet
// could take it. Measured on lorem-fleet — #23984/#23988 sat unclaimable while a human
// hand-authored the real ones.
const VALIDATE_PRIORITY = Number(arg("validate-priority", "8"));
if (!Number.isInteger(VALIDATE_PRIORITY)) {
  console.error(`--validate-priority must be an integer, got ${JSON.stringify(arg("validate-priority"))}`);
  process.exit(2);
}
// The generic validation brief below is fleet-agnostic and therefore weaker than a
// lane that has tuned one. Auto-enqueueing with the generic body where a tuned
// template exists would RAISE throughput while LOWERING audit quality, so a lane
// can supply its own. #{TASK_ID} / #{WORKER} / #{TITLE} are substituted.
const VALIDATE_BODY_PATH = arg("validate-body", null);

// A role's CHARTER is a per-role CONSTANT — prohibitions, discipline, how you
// finish. Hand-written briefs were ~5,800 chars each because every one restated
// it; only the task and its acceptance criterion are actually per-task, and
// those are a few hundred characters. Injecting the constant here makes the
// MARGINAL brief cheap, which is the thing that has to get cheap before this
// replaces standing seats.
//
// Injected via argv rather than fetched from the forum on purpose: forum reads
// are capped at ~1,499 collapsed chars and the cut is tail-biased, so a
// forum-hosted charter would silently lose its ending — measured on a topic doc
// that lost 82% of its body. argv is proven to carry 5,800+ chars intact.
//
// Read ONCE at startup and fail LOUDLY: a slot that silently ran charterless
// would produce workers with no prohibitions, and nothing downstream would show
// which brief was missing them.
// Same fail-loudly-at-startup treatment for --bin. A bad path is otherwise only
// discovered by CLAIMING a task and failing to spawn it: the task is released, so
// the queue is not corrupted, but the slot then sits looking healthy while every
// task it touches bounces. Check the one property that matters — executable — now,
// while the operator is still watching the terminal they launched from.
if (BIN) {
  try {
    accessSync(BIN, fsConstants.X_OK);
  } catch {
    console.error(`cv-runner: --bin ${BIN} is not an executable file — workers would fail to spawn.`);
    process.exit(2);
  }
}

let VALIDATE_BODY = "";
if (VALIDATE_BODY_PATH) {
  try {
    VALIDATE_BODY = readFileSync(VALIDATE_BODY_PATH, "utf8").trim();
  } catch (e) {
    console.error(`cv-runner: cannot read validate body ${VALIDATE_BODY_PATH}: ${String(e.message || e)}`);
    process.exit(2);
  }
  if (!VALIDATE_BODY) {
    console.error(`cv-runner: validate body ${VALIDATE_BODY_PATH} is empty — refusing to enqueue validations with no brief.`);
    process.exit(2);
  }
}

let CHARTER = "";
if (CHARTER_PATH) {
  try {
    CHARTER = readFileSync(CHARTER_PATH, "utf8").trim();
  } catch (e) {
    console.error(`cv-runner: cannot read charter ${CHARTER_PATH}: ${String(e.message || e)}`);
    process.exit(2);
  }
  if (!CHARTER) {
    console.error(`cv-runner: charter ${CHARTER_PATH} is empty — refusing to run workers with no charter.`);
    process.exit(2);
  }
}

if (!SLOT || !WORKDIR) {
  console.error("usage: cv-runner.mjs --slot <name> --workdir <abs path> [--channel tasks] [--mcp worker.mcp.json]");
  console.error("                     [--mode auto] [--poll 5000] [--stuck-after 30] [--once]");
  console.error("                     [--attach | --attach-rw]   watch the worker in this terminal");
  console.error("                     [--validate]               enqueue a check after each completed task");
  console.error("                     [--fleet <name>]           only bound by bare HALTs and HALT[<name>]");
  console.error("                     [--model M]                model for workers this slot spawns");
  console.error("                     [--validate-model M]       model for VALIDATE tasks (default: --model)");
  console.error("                     [--effort L]               low|medium|high|xhigh|max");
  console.error("                     [--validate-effort L]      effort for VALIDATE tasks (default: --effort)");
  console.error("                     [--validate-channel C]     post VALIDATE tasks to C (default: --channel)");
  console.error("                     [--validate-priority N]    priority for auto VALIDATE tasks (default 8 — above");
  console.error("                                                production, so unvalidated work cannot pile up)");
  console.error("                     [--validate-body FILE]     lane-specific validation brief; #{TASK_ID}/#{WORKER}/");
  console.error("                                                #{TITLE} substituted. Without it the generic brief is used");
  console.error("                     [--bin PATH]               claude binary for workers (default: cv-spawn's)");
  process.exit(2);
}

const now = () => new Date().toTimeString().slice(0, 8);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// While a tmux client owns this terminal, runner output would be scribbled over
// a screen tmux is actively redrawing — and, worse, LOST, because the redraw
// wins. Supervision lines are the whole reason this process exists, so they are
// buffered instead of printed and flushed the moment the terminal comes back.
// Watching must not cost you the log.
let logBuffer = null;
const log = (...a) => {
  const line = `[${now()}] ${SLOT} ${a.join(" ")}`;
  if (logBuffer) logBuffer.push(line);
  else console.log(line);
};
const flushLog = () => {
  if (!logBuffer) return;
  const held = logBuffer;
  logBuffer = null;
  if (held.length) console.log(held.join("\n"));
};

// Attach this terminal to the worker's pane. NOT awaited by the caller: the
// poll loop has to keep running while you watch, or attaching would silently
// disable escalation and reap-detection for as long as you had your eyes on it
// — turning the supervisor off at exactly the moment you were paying attention.
//
// Read-only by DEFAULT (-r). A supervisor's normal reason to attach is to look,
// and a stray keystroke lands in a live agent's REPL as if you had typed it.
// --attach-rw opts into an interactive client when you actually mean to steer.
//
// Detach with the usual  C-b d  — that ends the client, not the worker.
let attached = false; // guard: a second attach while one is live fights over stdio

function attachToWorker(name) {
  if (!process.stdout.isTTY) {
    log(`attach ignored: stdout is not a TTY (running detached?). Attach yourself: tmux attach -t ${name}`);
    return;
  }
  if (attached) return;
  const args = ["attach-session", "-t", name];
  if (!ATTACH_RW) args.push("-r");
  console.log(
    `[${now()}] ${SLOT} attaching to ${name} (${ATTACH_RW ? "INTERACTIVE — your keystrokes reach the agent" : "read-only"}). ` +
      `Detach with C-b d; runner output resumes then and nothing is lost.`
  );
  attached = true;
  // Hand the terminal over cleanly: the key reader holds stdin in raw mode, and
  // leaving it raw while tmux also owns the tty gives two readers one keyboard.
  stopKeys();
  logBuffer = [];
  const done = (msg) => {
    attached = false;
    flushLog();
    if (msg) log(msg);
    startKeys(); // take stdin back, so 'a' works again for the next worker
  };
  let child;
  try {
    child = spawn("tmux", args, { stdio: "inherit" });
  } catch (e) {
    done(`could not attach: ${String(e.message || e)} — supervision continues; attach manually: tmux attach -t ${name}`);
    return;
  }
  child.on("error", (e) =>
    done(`could not attach: ${String(e.message || e)} — supervision continues; attach manually: tmux attach -t ${name}`)
  );
  child.on("exit", () => done());
}

// --- keyboard: press 'a' in the runner's terminal to (re)attach ---------------
//
// Better than deciding up front with --attach: you attach at the moment you
// want to look, and detaching does not end your ability to look again.
//
// ⚠️ RAW MODE SILENTLY DISABLES Ctrl-C. In raw mode the tty stops generating
// SIGINT, so the interrupt key becomes an ordinary byte (0x03) that nothing
// handles — the runner would appear unkillable, and a supervisor you cannot
// stop is worse than one you cannot watch. 0x03 is therefore forwarded to the
// existing SIGINT handler by hand. Do not remove that branch.
let keysOn = false;
function startKeys() {
  if (keysOn || !process.stdin.isTTY) return;
  keysOn = true;
  process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdin.on("data", onKey);
}
function stopKeys() {
  if (!keysOn) return;
  keysOn = false;
  process.stdin.off("data", onKey);
  process.stdin.setRawMode(false);
  process.stdin.pause();
}
function onKey(buf) {
  const k = buf.toString();
  if (k === "\x03") {
    process.kill(process.pid, "SIGINT"); // raw mode ate the real one
    return;
  }
  if (k === "a" || k === "A") {
    if (!current?.worker) {
      log(`nothing to attach to — no worker running in this slot right now.`);
      return;
    }
    tmuxAlive(current.worker).then((alive) =>
      alive
        ? attachToWorker(current.worker)
        : log(`cannot attach: session '${current.worker}' is gone.`)
    );
  }
}

let current = null; // { taskId, worker } — for clean release on Ctrl-C
const spawnFailures = new Map(); // taskId -> consecutive spawn failures
const lastSpawnError = new Map(); // taskId -> the last spawn failure's message, for its escalation
const blocked = new Set(); // taskIds this slot will not re-claim (SPAWN_STRIKES, and declines)
const excludeIgnoredWarned = new Set(); // taskIds already reported as handed back despite exclude

const tmux = async (...args) => {
  try {
    const { stdout } = await execFileP("tmux", args);
    return { ok: true, out: stdout.trim() };
  } catch (e) {
    return { ok: false, out: String(e.stderr || e.message || e).trim() };
  }
};
const tmuxAlive = async (name) => (await tmux("has-session", "-t", name)).ok;

// --- is the worker WORKING, or merely QUIET? --------------------------------
// Elapsed silence is not a stall signal on this fleet. Measured 2026-08-24: the
// 30-minute rule fired SIX times and was wrong SIX times — zero true stalls.
// Both shapes are legitimate and neither writes to its pane: a full `build.sh
// usa` ran 1h20m while its agent sat correctly idle on a background shell, and
// an agent mid-analysis renders a spinner nobody reads. An alarm that is always
// wrong is worse than no alarm, because the one time it is right it reads like
// the other six.
//
// So measure WORK, not OUTPUT. CPU time summed over the worker's whole process
// tree advances while the agent thinks, while a tool call runs, and while a
// build burns in a detached shell — and stops when nothing is happening. It is
// the discipline this file already applies elsewhere: only CHANGE OVER TIME
// separates a working seat from a stalled one.
const parseCpuTime = (t) => {
  // ps TIME is [[DD-]HH:]MM:SS[.ss]
  const m = String(t).match(/^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$/);
  if (!m) return 0;
  const [, d, h, mm, ss] = m;
  return (+(d || 0)) * 86400 + (+(h || 0)) * 3600 + (+mm) * 60 + parseFloat(ss);
};

const panePid = async (session) => {
  const r = await tmux("list-panes", "-t", session, "-F", "#{pane_pid}");
  if (!r.ok) return null;
  const n = parseInt(String(r.out).split("\n")[0], 10);
  return Number.isFinite(n) ? n : null;
};

// Returns seconds of CPU across rootPid and every descendant, or NULL if the
// process table could not be read. ⚠️ NULL IS NOT ZERO — an unreadable table
// must never be reported as "no work happening", which is exactly how a silent
// zero becomes a false alarm.
const cpuSecondsOfTree = async (rootPid) => {
  if (!rootPid) return null;
  let out;
  try {
    ({ stdout: out } = await execFileP("ps", ["-eo", "pid=,ppid=,time="]));
  } catch {
    return null;
  }
  const kids = new Map();
  const own = new Map();
  for (const line of String(out).split("\n")) {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(\S+)$/);
    if (!m) continue;
    const pid = +m[1];
    const ppid = +m[2];
    own.set(pid, parseCpuTime(m[3]));
    if (!kids.has(ppid)) kids.set(ppid, []);
    kids.get(ppid).push(pid);
  }
  let total = 0;
  const seen = new Set();
  const stack = [rootPid];
  while (stack.length) {
    const pid = stack.pop();
    if (seen.has(pid)) continue;
    seen.add(pid);
    total += own.get(pid) || 0;
    for (const c of kids.get(pid) || []) stack.push(c);
  }
  return total;
};

// --- will this worker's COMMITS survive being reaped? -----------------------
// cv_task_done enforces a HANDOFF. Nothing enforces that the worker's COMMITS
// outlive it. Measured 2026-08-24, twice in one shift: a worker was reaped
// holding the only copy of the first C-only ELF commit, and another holding a
// 976 KB plate corpus. Both survived only because a human happened to
// rescue-fetch the branch before the reap. That is not a gate, that is luck.
//
// UNFINISHED IS SAFE; UNSAVED IS NOT.
const git = async (dir, ...args) => {
  try {
    const { stdout } = await execFileP("git", ["-C", dir, ...args]);
    return { ok: true, out: String(stdout).trim() };
  } catch (e) {
    return { ok: false, out: String(e.stderr || e.message || e).trim() };
  }
};

// durable:true  — HEAD is on a remote, or is already an ancestor of origin/master
// durable:false — HEAD exists only here
// durable:null  — could not determine. NOT the same as false, and never treated
//                 as "safe": the caller preserves anyway rather than guessing.
const commitsDurable = async (dir) => {
  const head = await git(dir, "rev-parse", "HEAD");
  if (!head.ok) return { durable: null, why: `rev-parse HEAD failed: ${head.out}` };
  const sha = head.out;
  await git(dir, "fetch", "origin", "--quiet"); // stale remotes would fail CLOSED, which is the safe direction
  const onRemote = await git(dir, "branch", "-r", "--contains", sha);
  if (!onRemote.ok) return { durable: null, sha, why: `branch -r --contains failed: ${onRemote.out}` };
  if (onRemote.out) return { durable: true, sha, why: `on ${String(onRemote.out).split("\n")[0].trim()}` };
  // No separate "is it an ancestor of the mainline?" test: `branch -r --contains`
  // already lists EVERY remote branch containing the sha, so a merged commit is
  // reported by origin/master itself. An extra merge-base check would add nothing
  // except a hardcoded branch name that is wrong in any repo whose default is not
  // `master` — this file also runs against repos whose default is `main`.
  return { durable: false, sha, why: "on no remote branch" };
};

// A git WORKTREE shares its parent's object store, so a commit made here is
// already in that store — what disappears is the REF, when the slot is reused
// and the branch is reset or deleted. So preservation costs one local ref
// write: no network, no push, no authorship decision taken on a dead seat's
// behalf. Publishing is a human's call; NOT LOSING IT is not.
const preserveRef = async (dir, worker, sha) => {
  const name = `refs/rescue/${worker}`;
  const r = await git(dir, "update-ref", name, sha);
  return r.ok ? name : null;
};

// --- claim -----------------------------------------------------------------
// Optimistic concurrency: two runners can both write an owner; only one wins
// the re-read. Losing is normal and cheap — back off and take the next task.
// --- the brake ----------------------------------------------------------------
//
// A fleet-wide HALT. Any seat that can post can set it; no seat needs process
// lifecycle rights to stop the fleet from taking on more work.
//
//   set:  post to #fleet-control with a title starting "HALT" — put WHY in the body
//   lift: archive/resolve that post
//
// SCOPE, added 2026-08-16 after a measured incident: the brake used to be global
// with no way to narrow it, so a HALT posted when a lorem-fleet decomp deadline expired
// silently stopped `ipsum-w5` — a runner on an unrelated fleet, channel and repo —
// for three hours. Nothing was lost only because that queue happened to be empty.
// A brake that stops a lane nobody is using produces no symptom, so this class of
// error is invisible until someone enqueues and waits.
//
//   HALT …          binds EVERY runner            (unchanged; still the emergency stop)
//   HALT[lorem-fleet] …     binds runners started --fleet lorem-fleet
//   HALT[lorem-fleet,ipsum-fleet] …  binds either
//
// 🔴 IT FAILS CLOSED, and here is exactly how far that goes — the first version
// of this comment claimed more than the code did, and an audit found two ways it
// under-stopped. What is actually guaranteed:
//   - a runner with NO --fleet is bound by EVERY halt, scoped or not. It cannot
//     prove it is out of scope, so it does not get to opt out.
//   - a tag that does not parse ("HALT(lorem-fleet)"), an empty one ("HALT[]"), a
//     wildcard ("HALT[*]", "HALT[all]"), or one containing any token that is not
//     a plain fleet name ("HALT[[ipsum-fleet]") is treated as GLOBAL.
//
// ⚠️ AND WHAT IS NOT GUARANTEED, because no check here can reach it: a tag that
// is well-formed but names the WRONG fleet — "HALT[pe2]" intended as "ipsum-fleet" — is
// indistinguishable from a halt that legitimately does not concern you, and will
// bind nobody. Only a registry of live fleet names could catch it and we do not
// have one. If a halt seems not to have taken, SUSPECT THE SPELLING FIRST: the
// runner logs its own scope next to the halt it matched, so compare those two.
//
// A forum post rather than a local file on purpose: runners may be on different
// machines, and the halt must be visible, attributable and auditable — who
// stopped the fleet, when, and why. A file answers none of those.
//
// 🔴 IT FAILS CLOSED. If the check itself errors, the runner does NOT claim.
// This is the one place in this file where an unreachable server must mean STOP
// rather than CARRY ON — the default `catch { proceed }` would produce a brake
// that silently disengages exactly when the system is unhealthy, which is when
// it is most likely to be needed.
//
// ⚠️ SCOPE, so nobody mistakes this for more than it is: this stops NEW CLAIMS.
// A worker already running is unaffected and will run to completion. Stopping
// in-flight work needs either the worker's cooperation at a yield point or a
// kill, and a kill destroys the handoff this whole design is built on.
// The halt predicate and its constants now live in cv-core, because cv-fleet.sh
// must ask the SAME question before it starts a batch of slots. Re-spelling it
// here would give two parsers that agree only by luck; a launcher whose predicate
// had drifted would report "clear" for a board that stops every slot it started.
const HALT_CHANNEL = cv.HALT_CHANNEL;
const HALT_WINDOW = cv.HALT_WINDOW;
let haltAnnounced = false;

const haltBindsMe = (title) => cv.haltBindsFleet(title, FLEET);

// The board query is windowed (cv.HALT_WINDOW), so a halt can fall off the end of
// it. That path fails OPEN — the runner resumes claiming with a live HALT sitting
// unarchived in the channel, and cheerfully logs "halt lifted". This is the one
// check in the file documented to fail closed, so the window is a CORRECTNESS
// boundary, not a context-size nicety. Scoping makes eviction likelier, not less:
// non-binding scoped halts consume window slots without stopping anything, and
// more halts in flight is the explicit intent of the scoping change. Pin a halt
// post to make it unevictable — pinned sorts ahead of everything in this view.

// How long a completed worker's handoff may stay unreadable before a human is
// told. Not a timeout — the runner keeps checking past it. Generous on purpose:
// the cost of waiting is an idle session, the cost of giving up is a stranded
// one that nothing will ever reap.
const HANDOFF_GRACE_S = Number(arg("handoff-grace", "60"));
const DECLINE_POLL_MS = Math.max(POLL_MS, Number(arg("decline-poll", "30000")));
async function halted() {
  let posts;
  try {
    posts = (await cv.forumRead(HALT_CHANNEL, { limit: HALT_WINDOW, compact: true }))?.posts ?? [];
  } catch (e) {
    log(`⛔ HALT CHECK FAILED (${String(e.message || e)}) — refusing to claim. Failing CLOSED on purpose.`);
    log(`   server: ${cv.CV_BASE_URL}${cv.CV_URL_IS_DEFAULT ? "  ⚠️ DEFAULT — CLAUDIVERSE_URL is not set in this shell. --mcp configures the WORKER, not this runner." : ""}`);
    return true;
  }
  const halt = posts.find(
    (p) => (p.title || "").startsWith("HALT") && !p.archived && haltBindsMe(p.title || ""),
  );
  if (!halt) {
    // Say so rather than reporting a clean "no halt". A full window means the
    // query could not see the whole channel, so "no halt found" and "no halt
    // exists" have come apart and only the weaker one was measured.
    if (posts.length >= HALT_WINDOW) {
      log(`⚠️ halt check saw a FULL window (${posts.length}/${HALT_WINDOW} unarchived posts in #${HALT_CHANNEL}) — an older halt could be out of view. Archive stale posts, or pin the halt.`);
    }
    if (haltAnnounced) log(`halt lifted — resuming claims`);
    haltAnnounced = false;
    return false;
  }
  if (!haltAnnounced) {
    haltAnnounced = true;
    log(`⛔ FLEET HALTED by #${halt.id} "${halt.title}" (${halt.author ?? "unknown"}) — not claiming. Archive that post to resume.`);
    log(`   this runner's scope: ${FLEET ? `--fleet ${FLEET}` : "NONE (bound by every halt)"}`);
    log(`   In-flight workers are NOT stopped by this and will run to completion.`);
  }
  return true;
}

let announcedEmpty = false;

// Component E claim. Same return shape as the forum path, so nothing
// downstream needs to know which source produced the task.
async function claimFromTasks() {
  if (await halted()) return null;
  let r;
  try {
    // `blocked` is sent to the server. The forum path filters it client-side,
    // but a task claim is atomic server-side and picks the top of the lane, so
    // a client-side filter here would be a no-op: a declined task released to
    // READY is still the top of the lane and would come straight back.
    r = await cv.taskClaim({ fleet: FLEET, lane: CHANNEL, worker: SLOT, vm_busy: false, exclude: [...blocked] });
  } catch (e) {
    log(`cannot claim from tasks (${FLEET}/${CHANNEL}):`, String(e.message || e));
    return null;
  }

  // An empty queue is a 200 with task:null — a normal poll result, not an
  // error. That is why this can distinguish "nothing to do" from "the call
  // failed" without parsing an error body.
  if (!r?.task) {
    if (!announcedEmpty) {
      announcedEmpty = true;
      log(`queue empty — 0 READY tasks in ${FLEET}/${CHANNEL} (reason: ${r?.reason ?? "none_ready"})`);
    }
    return null;
  }
  announcedEmpty = false;

  const t = r.task;
  const worker = `${SLOT}-t${t.id}`;

  // A server that predates `exclude` ignores it and hands the task back. Give
  // it straight back rather than run a task this slot declined, and say so
  // ONCE: the fix for that is a server deploy, not a louder log.
  if (blocked.has(t.id)) {
    if (!excludeIgnoredWarned.has(t.id)) {
      excludeIgnoredWarned.add(t.id);
      log(`⚠️ server handed back #${t.id}, which this slot declined — it ignored \`exclude\` (server older than the decline fix). Releasing it each time; another slot can still take it.`);
    }
    const rel = await cv.taskRelease(t.id, { worker: SLOT, reason: `${SLOT} declined this task earlier` });
    if (rel?._failed) log(`⛔ could not release #${t.id} (${rel._status} ${rel.error ?? ""}) — it is HELD by ${SLOT} and nothing is running it.`);
    return null;
  }

  // The claim already moved it to CLAIMED atomically server-side; mark RUNNING
  // so a stall check can tell "claimed but never started" from "working".
  try {
    await cv.taskStart(t.id, { worker: SLOT });
  } catch (e) {
    log(`claimed #${t.id} but could not mark RUNNING: ${String(e.message || e)}`);
  }

  return { id: t.id, worker, title: t.title || `task ${t.id}`, body: t.body_md || "", validatesTaskId: t.validates_task_id ?? null, lane: t.lane ?? null };
}

// A DRAIN: `touch ~/.claudiverse/drain/<slot>` on the slot's host and the
// runner exits after its current task (reaped, its validation minted)
// instead of claiming the next one, so a restart (new lane, new code) never
// lands mid-row. The file is removed as the runner leaves. Host-local on
// purpose: a HALT is fleet-wide, and a slot-scoped HALT tag reads as GLOBAL
// to runners that do not parse it. MEASURED 2026-10-08: moving w7 to another
// lane had no moment between "reaped" and the next claim.
const DRAIN_FILE = join(homedir(), ".claudiverse", "drain", SLOT);

async function drainIfAsked() {
  if (!existsSync(DRAIN_FILE)) return;
  log(`drain requested (${DRAIN_FILE}): no new claim, the slot closes.`);
  rmSync(DRAIN_FILE, { force: true });
  if (FLEET) await Promise.race([beat(slotReport("stopped")), new Promise((r) => setTimeout(r, 2000))]);
  stopKeys();
  flushLog();
  process.exit(0);
}

async function claim() {
  if (TASK_SOURCE === "tasks") return claimFromTasks();
  if (await halted()) return null;
  let posts;
  try {
    const r = await cv.forumRead(CHANNEL, { status: "incoming", limit: 20, compact: true });
    posts = r?.posts ?? [];
  } catch (e) {
    log("cannot read #" + CHANNEL + ":", String(e.message || e));
    return null;
  }
  // A task post MUST carry status=incoming (cv_task_add sets it). A post created
  // without a status has status NULL and never appears here — an empty queue and
  // a mis-created task are the same observable, so say which filter produced the
  // zero rather than sitting quietly and looking busy.
  // Replies can never be tasks; claiming one would hijack a thread.
  const open = posts.filter((p) => !p.owner && !p.archived && !p.parent_id && !blocked.has(p.id)).reverse(); // oldest first
  if (!open.length && !announcedEmpty) {
    announcedEmpty = true;
    log(
      `queue empty — 0 claimable in #${CHANNEL} (filter: status=incoming, no owner, not a reply). ` +
        `If you expected work here: a post created WITHOUT status=incoming is invisible to this query. Use cv_task_add.`
    );
  }
  if (open.length) announcedEmpty = false;
  for (const p of open) {
    const worker = `${SLOT}-t${p.id}`;
    try {
      // ATOMIC claim. This replaced assign-then-verify, which was a TOCTOU race:
      // forumAssign overwrites unconditionally, so two runners both "won" and the
      // read-back could not tell them apart — the loser read its own name back
      // before the winner overwrote it. Measured 2026-08-16: ipsum-w5 and ipsum-w7 BOTH
      // ran task 12467 to completion, on a task that creates records and sends
      // mail. The verify was not weak, it was structurally incapable: a check
      // separated from its write cannot decide a race.
      //
      // The server now does `UPDATE … WHERE id = $1 AND owner IS NULL` and the
      // matched-row count IS the verdict. There is no window and no second read.
      const claim = await cv.forumClaim(p.id, worker, SLOT);
      if (!claim.claimed) {
        log(
          claim.notFound
            ? `#${p.id} vanished before it could be claimed — skipping`
            : `#${p.id} already held by ${claim.heldBy ?? "another slot"} — skipping`
        );
        continue;
      }
      await cv.forumSetStatus(p.id, "active");
      const post = claim.post ?? {};
      return { id: p.id, worker, title: post.title || `task ${p.id}`, body: post.body || "" };
    } catch (e) {
      // A THROW here is transport/server, never a lost race — a lost race returns
      // claimed:false. So this is genuinely "we do not know", and we must not
      // treat it as either won or lost: skip and retry on the next poll.
      log(`claim of #${p.id} FAILED (not a lost race — could not reach the server):`, String(e.message || e));
    }
  }
  return null;
}

// --- brief -----------------------------------------------------------------
function brief(task, worker) {
  return [
    `You are ${worker}, an EPHEMERAL worker. You exist for this one task and will be`,
    `stopped when it is done. Nothing in your context survives — only what you write.`,
    ``,
    ...(CHARTER ? [``, CHARTER, ``] : []),
    `TASK #${task.id} — ${task.title}`,
    ``,
    task.body,
    ``,
    `── HOW YOU FINISH ──`,
    `1. Record what you learn with cv_fact_add. Every fact needs a COMMAND that`,
    `   re-derives it and a statement of what FAILURE would look like — a check`,
    `   with no reachable negative is decoration, not evidence.`,
    `2. Correct existing facts with cv_fact_relate. Use NARROWS when a claim`,
    `   survives but its bound shrinks — that is the common case. CORRECTIONS`,
    `   COUNT AS COMPLETE OUTPUT, not as failure.`,
    `3. Severity, priority and "this is a defect" are NOT facts — they have no`,
    `   command behind them. Leave them to whoever owns the call.`,
    `4. Write cv_handoff_set BEFORE finishing: what you did, what you would`,
    `   qualify, what the next worker needs.`,
    `5. Call cv_task_done(${task.id}, ...). It REFUSES without a handoff.`,
    ``,
    `── IF YOU MUST NOT DO THIS TASK ──`,
    `If you conclude this task is not yours to do — e.g. a seat check shows you`,
    `are not independent of the work — DECLINE instead of finishing:`,
    `  cv_handoff_set with a FIRST LINE of exactly: DECLINED: <why>`,
    `then stop. Do NOT call cv_task_done — that records undone work as done.`,
    `Your runner releases the task to another seat and will not hand it back`,
    `to you. Doing the half you CAN do independently is not a decline: finish`,
    `normally and say which half you could not discharge.`,
    ``,
    `You are not being timed. If you get stuck, say so in the task thread and`,
    `stop — a stuck worker that reports is worth more than one that guesses.`,
  ].join("\n");
}

// --- run one task ----------------------------------------------------------
async function runTask(task) {
  current = { taskId: task.id, worker: task.worker };
  log(`claimed #${task.id} — ${task.title}`);

  if (await tmuxAlive(task.worker)) {
    log(`⛔ tmux session '${task.worker}' already exists; refusing to clobber. Releasing claim.`);
    await release(task.id);
    return;
  }

  // Insert --mcp at index 1: immediately after the positional WORKDIR and BEFORE
  // any flag. Index 2 lands between "--title" and its value, so cv-spawn reads
  // TITLE="--mcp" and then chokes on the config path as an unknown positional.
  // This never fired in testing because the probe runs were launched WITHOUT
  // --mcp — the only path that exercises this line is the one nothing tested.
  // A VALIDATE task gets VALIDATE_MODEL; everything else gets MODEL. Both default to
  // unset, in which case no --model is passed at all and the binary picks.
  const isVal = isValidationTask(task);
  const model = isVal ? VALIDATE_MODEL : MODEL;
  const effort = isVal ? VALIDATE_EFFORT : EFFORT;
  // 🔴 THE BRIEF GOES TO cv-spawn AS A FILE, NEVER AS AN ARGUMENT. Linux caps
  // ONE argv string at 128 KiB (MAX_ARG_STRLEN), macOS does not: a 128+ KB
  // brief failed "spawn E2BIG" three times on both Linux hosts (task #1930,
  // w6 12:07 and w7 12:25, 2026-10-08) while the M1 slots never could. cv-spawn
  // copies it into its own prompt folder; this one is removed once it returns.
  const briefDir = mkdtempSync(join(tmpdir(), "cv-runner-brief-"));
  const briefFile = join(briefDir, `${task.worker}.md`);
  writeFileSync(briefFile, brief(task, task.worker));
  const args = [WORKDIR, "--title", task.worker, "--mode", MODE, "--prompt-file", briefFile];
  if (model) args.splice(1, 0, "--model", model);
  if (effort) args.splice(1, 0, "--effort", effort);
  if (MCP) args.splice(1, 0, "--mcp", MCP);
  if (BIN) args.splice(1, 0, "--bin", BIN);
  // Marks the worker as a runner seat (the app's runner filter; runner seats
  // may not request a human) and groups it under its fleet.
  args.splice(1, 0, "--origin", "runner");
  if (FLEET) args.splice(1, 0, "--fleet", FLEET);
  try {
    // 90s, not 30s: cv-spawn now WAITS for the shell prompt and then verifies
    // the process actually started before returning. 30s could kill it during
    // its own verification, turning a good spawn into a reported failure.
    await execFileP(join(HERE, "cv-spawn.sh"), args, { timeout: 90000 });
  } catch (e) {
    const n = (spawnFailures.get(task.id) ?? 0) + 1;
    spawnFailures.set(task.id, n);
    const why = String(e.stderr || e.message || e).trim();
    lastSpawnError.set(task.id, why);
    log(`spawn FAILED (attempt ${n}):`, why);
    await release(task.id);
    return;
  } finally {
    rmSync(briefDir, { recursive: true, force: true });
  }
  log(`spawned ${task.worker}  (watch: tmux attach -t ${task.worker})`);
  if (ATTACH) attachToWorker(task.worker); // deliberately not awaited — see above

  const started = Date.now();
  let escalated = false;
  // Handoff-gate state. `done` can be observed before the handoff is readable —
  // the two writes are not atomic — so we need to remember when we first saw it
  // to tell a momentary race from a genuine stall, and to warn/escalate ONCE
  // rather than once per poll.
  let doneSince = 0;
  let noHandoffWarned = false;
  let noHandoffEscalated = false;
  // Work-liveness state. lastWorkAt starts at spawn so a worker that never
  // burns CPU at all is still caught by the ordinary quiet rule.
  let lastCpu = null;
  let lastWorkAt = Date.now();
  // Decline state. The handoff is read on a slower clock than the task: a
  // declining seat is idle, so seconds do not matter, and every runner reads.
  let lastDeclineCheck = 0;
  let declineReleaseFailed = false;

  for (;;) {
    await sleep(POLL_MS);

    let post;
    try {
      if (TASK_SOURCE === "tasks") {
        // Same contract, different store: DONE is the signal, and a read
        // failure is still not a verdict.
        const t = (await cv.taskShow(task.id))?.task;
        // SUPERSEDED is terminal too. It used to fall through as "not done", so a
        // seat whose task was superseded while it held it was NEVER reaped: its
        // worker cannot cv_task_done a superseded task, and nothing else ends
        // the wait. MEASURED 2026-09-28: #898 was superseded 35 s after lorem-w4
        // claimed it; the worker finished 24 min later and the finished seat sat
        // until a human ended it (the same failure cost lorem-w4 3 h on #657).
        post = t && {
          status: t.state === "DONE" ? "done" : t.state === "SUPERSEDED" ? "superseded" : String(t.state).toLowerCase(),
        };
      } else {
        post = (await cv.forumGet(task.id, false))?.post;
      }
    } catch {
      continue; // transient read failure is not a verdict
    }

    if (post?.status === "done" || post?.status === "superseded") {
      // A superseded task goes through the SAME gates as a done one — readable
      // handoff, durable commits — because the worker's context and any commits
      // are just as unrecoverable. What differs is after the reap: its work was
      // replaced on purpose, so no continuation is promoted and no validation is
      // minted (validating it would check work nobody will land).
      // ⚠️ A worker that wrote an INTERIM handoff early can be reaped mid-run
      // here. Accepted: its task no longer exists as work, and the handoff is kept.
      const superseded = post.status === "superseded";
      // Second gate: cv_task_done enforces the handoff, but this runner holds
      // the kill switch, so it checks independently rather than trusting that
      // the check ran. Verify the thing you are about to destroy is recoverable.
      //
      // 🔴 THIS PATH MUST NOT BE TERMINAL, and it was. Measured 2026-08-16: a
      // worker completed, this gate read the handoff a beat too early, logged
      // "NO handoff — NOT reaping" and `return`ed. The handoff appeared moments
      // later; nothing ever looked again; the session was still idle-and-alive
      // three hours on, with its tmux client, holding a name the slot had moved
      // past. `return` was the whole bug.
      //
      // WHY IT IS ALWAYS TRANSIENT: cv_task_done REFUSES to run without a
      // handoff. So `status=done AND no handoff` cannot be a steady state — the
      // only ways to observe it are (a) this read landing between the handoff
      // write and the status write, or (b) the read itself failing. Both resolve.
      // Treating a logically-impossible state as permanent is what stranded it.
      //
      // Note the asymmetry this fixes: the post read six lines up already says
      // "transient read failure is not a verdict" and does `continue`. The same
      // rule simply was not carried to the second read.
      if (!doneSince) doneSince = Date.now();
      let hv = null;
      let readFailed = false;
      try {
        hv = (await cv.handoffGet(task.worker))?.handoff;
      } catch (e) {
        // ⚠️ ABSENT and UNREADABLE are different facts. Collapsing them into one
        // null is how a network blip becomes "this worker has no handoff".
        readFailed = true;
      }
      if (!hv) {
        const waited = Math.round((Date.now() - doneSince) / 1000);
        if (!noHandoffWarned) {
          noHandoffWarned = true;
          log(
            `#${task.id} is done but ${task.worker}'s handoff is ${readFailed ? "UNREADABLE (read failed)" : "not visible yet"} — not reaping, still checking.`
          );
        }
        // Escalate ONCE, after a grace period, so a genuine stall still reaches a
        // human — but KEEP POLLING either way. Escalation is a notification, not
        // an exit.
        if (!noHandoffEscalated && waited >= HANDOFF_GRACE_S) {
          noHandoffEscalated = true;
          log(`⚠️ #${task.id}: still no readable handoff after ${waited}s — escalating, and continuing to check.`);
          await escalate(
            task,
            `marked done but its handoff has been unreadable for ${waited}s — NOT reaping (its context is the only copy). The runner is still checking; this is a notification, not a stop.`
          );
        }
        continue;
      }
      // DURABILITY GATE — the handoff gate above protects the worker's CONTEXT;
      // this protects its WORK. Both are "do not destroy what you cannot
      // recover"; only one of them existed until 2026-08-25.
      //
      // ⚠️ THIS PRESERVES, IT DOES NOT BLOCK. Refusing to reap would strand the
      // slot forever: the worker is already done, so it will never push, so the
      // condition would never clear — a gate that cannot be satisfied is an
      // outage, not a safeguard. Writing a local rescue ref costs nothing, is
      // instant, needs no network, and takes no authorship decision on a dead
      // seat's behalf. The escalation is how a human learns to publish it.
      const dur = await commitsDurable(WORKDIR);
      if (dur.durable !== true) {
        const kept = dur.sha ? await preserveRef(WORKDIR, task.worker, dur.sha) : null;
        const state = dur.durable === false ? "NOT PUSHED" : "UNVERIFIABLE";
        log(
          `⚠️ #${task.id}: ${task.worker}'s commits are ${state} (${dur.why})` +
            (kept ? ` — preserved at ${kept} before reaping.` : ` — AND THE RESCUE REF COULD NOT BE WRITTEN.`)
        );
        await escalate(
          task,
          `reaped, but its commits were ${state}: ${dur.why}. ` +
            (kept
              ? `They are preserved in the worktree's object store at ${kept} (HEAD ${String(dur.sha).slice(0, 8)}) — nothing is lost, but NOBODY HAS PUBLISHED IT. Push that ref, or the work lives on one machine.`
              : `⛔ AND THE RESCUE REF COULD NOT BE WRITTEN — treat HEAD ${String(dur.sha || "?").slice(0, 8)} in ${WORKDIR} as at risk and recover it by hand NOW.`)
        );
      }
      await tmux("kill-session", "-t", task.worker);
      // Killing the session drops any attached client, handing this terminal
      // back. Give that a beat to land before writing, so the completion line
      // is not the one message the redraw eats.
      if (logBuffer) await sleep(300);
      flushLog();
      const gone = !(await tmuxAlive(task.worker));
      log(`#${task.id} ${superseded ? "SUPERSEDED" : "done"} · handoff v${hv.version} · reaped${gone ? "" : " (⚠️ tmux session still present)"}`);
      current = null;
      if (superseded) {
        await escalate(
          task,
          `was SUPERSEDED while ${task.worker} held it. The seat is reaped (handoff v${hv.version} kept) and freed for new work. No validation was minted, since the task's work was replaced on purpose. If the worker produced something worth keeping, its handoff says where.`
        );
        return;
      }
      await promoteContinuations(task);
      if (VALIDATE) await enqueueValidation(task);
      return;
    }

    // ── DECLINE ──────────────────────────────────────────────────────────
    // A worker that must not do its task cannot finish it: cv_task_done would
    // record undone work as done. Before this path existed it could only sit
    // there. MEASURED 2026-09-27 on lorem-fleet: a validator that correctly declined
    // its seat check held its slot for 2h40m, until a human closed the task —
    // and closing it auto-minted a validation of nothing.
    //
    // The signal is the handoff, because the handoff is what makes a reap
    // safe: a decline written there has already saved the worker's reasoning.
    if (Date.now() - lastDeclineCheck >= DECLINE_POLL_MS) {
      lastDeclineCheck = Date.now();
      const why = await readDecline(task.worker);
      if (why !== null) {
        const released = await releaseDeclined(task, why);
        if (!released) {
          // Keep the worker: killing it with the task still held strands both.
          if (!declineReleaseFailed) {
            declineReleaseFailed = true;
            log(`⛔ ${task.worker} DECLINED #${task.id} but the release FAILED — worker kept, retrying.`);
          }
          continue;
        }
        blocked.add(task.id);
        const dur = await commitsDurable(WORKDIR);
        const kept = dur.durable !== true && dur.sha ? await preserveRef(WORKDIR, task.worker, dur.sha) : null;
        await tmux("kill-session", "-t", task.worker);
        if (logBuffer) await sleep(300);
        flushLog();
        log(`#${task.id} DECLINED by ${task.worker}: ${why} — released to READY, reaped, and this slot will not claim it again.`);
        await escalate(
          task,
          `${task.worker} DECLINED this task: "${why}". Released to READY; ${SLOT} will not claim it again, ` +
            `but another slot in ${CHANNEL} can. ⚠️ If every slot in that lane declines, nobody will take it — re-route it.` +
            (kept ? ` The worker also left unpushed commits, preserved at ${kept}.` : "")
        );
        current = null;
        return;
      }
    }

    const alive = await tmuxAlive(task.worker);
    if (!alive) {
      // Process vanished without declaring done. Do not mark the task done and
      // do not silently re-queue: something ended it, and that is worth knowing.
      // The session dying also dropped any attached client, so the terminal is
      // ours again — flush before writing the one line that explains why.
      if (logBuffer) await sleep(300);
      flushLog();
      log(`⚠️ ${task.worker} process is GONE but #${task.id} was never marked done.`);
      await escalate(task, `worker process disappeared without calling cv_task_done — task left ACTIVE for a human to judge`);
      current = null;
      return;
    }

    // Sample WORK, not silence. See cpuSecondsOfTree above for why elapsed time
    // alone was a 6-for-6 false-positive generator on 2026-08-24.
    const cpu = await cpuSecondsOfTree(await panePid(task.worker));
    if (cpu !== null) {
      if (lastCpu === null || cpu - lastCpu >= CPU_EPS_S) lastWorkAt = Date.now();
      lastCpu = cpu;
    }
    const mins = Math.floor((Date.now() - started) / 60000);
    const quietMin = Math.floor((Date.now() - lastWorkAt) / 60000);
    // Two independent triggers, and they answer different questions:
    //   quietMin  — the process tree has burned no CPU for STUCK_MIN. That is a
    //               real stall ONLY if the work runs inside this tree. It does
    //               not when a build runs inside a colima VM, or when the worker
    //               is blocked on a Monitor/background job it started: neither
    //               burns host CPU. All 6 firings on 2026-09-27 were such seats
    //               (FACT #8052). Treat this as "look", not "stuck".
    //   mins      — a LONG-STOP backstop, used when CPU is unreadable so the
    //               primary signal is unavailable. Without it an unreadable
    //               process table would silence the alarm entirely, which is the
    //               silent-zero failure this whole change exists to avoid.
    const stalled = cpu !== null && quietMin >= STUCK_MIN;
    const backstop = cpu === null && mins >= STUCK_HARD_MIN;
    if ((stalled || backstop) && !escalated) {
      escalated = true;
      const why = stalled
        ? `${quietMin}m with NO CPU consumed across its process tree`
        : `${mins}m elapsed and the process table is UNREADABLE, so work cannot be measured`;
      log(`⚠️ ${why} — escalating. NOT killing: a stuck worker is evidence.`);
      await escalate(
        task,
        `${why}, and no cv_task_done. Still running and NOT killed — inspect with: tmux attach -t ${task.worker}. ` +
          `BLIND SPOT: this samples CPU in the worker's HOST process tree. A build inside a colima VM, or a worker blocked on a Monitor it started, burns no host CPU and reads exactly like a stall — all 6 firings on 2026-09-27 were working seats (FACT #8052). Capture the worker pane before acting: a live spinner or an in-flight command means it is working.`
      );
    }
  }
}

// An escalation is the ONLY way this runner surfaces a problem when nobody is
// watching the terminal — which is the entire point of an unattended slot. So it
// must land in the store, and it must say so loudly when it does not.
//
// This function previously posted with channel:"" and swallowed the failure in a
// bare catch, under a comment claiming the channel was derived server-side for
// replies. That was never verified and is false: the API rejects a blank channel
// outright. Every escalation went to the terminal and nowhere else. Same bug as
// cv_fact_relate had, in the same file, hidden by a confident comment.
async function escalate(task, why) {
  const body = `**RUNNER ${SLOT}** — ${why}`;
  if (TASK_SOURCE === "tasks") return escalateTask(task, body);
  let channel = null;
  try {
    channel = (await cv.forumGet(task.id, false))?.post?.channel ?? null;
  } catch (e) {
    log(`⛔ ESCALATION NOT RECORDED (could not read #${task.id}: ${String(e.message || e)}). This log line is the ONLY record.`);
    return;
  }
  if (!channel) {
    log(`⛔ ESCALATION NOT RECORDED (#${task.id} has no channel). This log line is the ONLY record.`);
    return;
  }
  try {
    await cv.forumPost(SLOT, channel, body, task.id, { title: `RUNNER: needs a human` });
  } catch (e) {
    log(`⛔ ESCALATION FAILED TO POST: ${String(e.message || e)}. This log line is the ONLY record.`);
    return;
  }
  // Verify through the reader's path: an escalation nobody can find is not an
  // escalation. Confirm it is actually attached to the task before claiming it.
  let landed = false;
  try {
    landed = ((await cv.forumGet(task.id, true))?.replies ?? []).some(
      (r) => (r.title || "").startsWith("RUNNER:")
    );
  } catch {}
  log(landed ? `escalation recorded on #${task.id}` : `⛔ escalation posted but NOT VISIBLE on #${task.id} — treat the log as the only record.`);
}

// ⛔ On the tasks path task.id is a TASK-TABLE id, and escalate() above looks
// it up as a FORUM POST id. Different id spaces, so it found whatever old post
// shares the integer and replied there. MEASURED 2026-09-27: task #864's stall
// escalations went onto forum post #864, a June thread by decomper-2. Its
// "landed" check could not catch it — it accepts ANY "RUNNER:" reply, so the
// first misfiled escalation vouched for every later one.
//
// So the tasks path records on the task itself (a durable event that
// cv_task_show renders), and posts a top-level alert in the lane's channel
// naming the task, verified by the id the post came back with.
async function escalateTask(task, body) {
  const ev = await cv.taskProgress(task.id, { worker: SLOT, detail: body }).catch((e) => ({ _failed: true, error: String(e.message || e) }));
  if (ev?._failed) log(`⛔ escalation NOT recorded on task #${task.id} (${ev._status ?? ""} ${ev.error ?? ""}).`);
  if (ESCALATE_VIA === "notify") {
    let pinged = false;
    try {
      const firstLine = body.split("\n")[0];
      await cv.report(
        `tasks:${CHANNEL}`,
        `RUNNER ${SLOT} needs a human — task #${task.id}: ${firstLine.length > 240 ? firstLine.slice(0, 239) + "…" : firstLine} — cv_task_show ${task.id}`
      );
      pinged = true;
    } catch (e) {
      log(`⛔ escalation ping to tasks:${CHANNEL} FAILED: ${String(e.message || e)}.`);
    }
    const where = [ev?._failed ? null : `task #${task.id}`, pinged ? `ping tasks:${CHANNEL}` : null].filter(Boolean);
    log(where.length ? `escalation recorded on ${where.join(" and ")}` : `⛔ escalation recorded NOWHERE — this log line is the only record.`);
    return;
  }
  let postId = null;
  try {
    const r = await cv.forumPost(
      SLOT,
      CHANNEL,
      `${body}\n\nTask #${task.id} in ${FLEET}/${CHANNEL} — read it with \`cv_task_show ${task.id}\`, not the forum post of that number.`,
      undefined,
      { title: `RUNNER: needs a human — task #${task.id}` }
    );
    postId = r?.post?.id ?? null;
    if (postId !== null && (await cv.forumGet(postId, false))?.post?.id !== postId) postId = null;
  } catch (e) {
    log(`⛔ escalation alert NOT POSTED to #${CHANNEL}: ${String(e.message || e)}.`);
  }
  const where = [ev?._failed ? null : `task #${task.id}`, postId !== null ? `forum post ${postId}` : null].filter(Boolean);
  log(where.length ? `escalation recorded on ${where.join(" and ")}` : `⛔ escalation recorded NOWHERE — this log line is the only record.`);
}

// The first non-blank line of the worker's handoff, if it is a decline.
// Uppercase DECLINED plus a separator, optionally in markdown emphasis or a
// heading, so a handoff that merely begins "Declined to re-run X" is not one.
// An unreadable handoff is NOT a decline: it is no information.
const DECLINE_RE = /^[#>*_\s]*DECLINED[*_]*\s*[:—–-][*_]*\s*(.*)$/;
async function readDecline(worker) {
  let hv;
  try {
    hv = (await cv.handoffGet(worker))?.handoff;
  } catch {
    return null;
  }
  const first = String(hv?.body ?? "").split("\n").find((l) => l.trim()) ?? "";
  const m = first.match(DECLINE_RE);
  return m ? m[1].replace(/[*_]+$/, "").trim() || "(no reason given)" : null;
}

// true only when the task is verifiably handed back.
async function releaseDeclined(task, why) {
  const reason = `declined by ${task.worker}: ${why}`.slice(0, 500);
  try {
    if (TASK_SOURCE === "tasks") {
      const r = await cv.taskRelease(task.id, { worker: SLOT, reason });
      return !r?._failed;
    }
    await cv.forumAssign(task.id, "", SLOT);
    await cv.forumSetStatus(task.id, "incoming");
    return true;
  } catch {
    return false;
  }
}

// --- continuations: ordering, structurally ------------------------------------
//
// A worker that must yield before its goal is finished PARKS its successor's
// brief as a REPLY on the task it is blocked behind, titled "CONTINUE #<goal>".
// A parked reply is NOT claimable — the claim filter already skips replies. The
// runner promotes it to a top-level `incoming` task only after the blocker is
// SUCCESSFULLY REAPED.
//
// WHY THIS RATHER THAN A blocked_on FIELD: ordering becomes a consequence of who
// promotes, not a predicate anyone has to check. And it is failure-aware for
// free — a task that fails is never successfully reaped, so its successor is
// never promoted. No new status, no change to the claim filter.
//
// ⚠️ MUST FETCH THREADED. cv_forum_get renders a post WITHOUT its replies by
// default, and the compact board view renders titles with no bodies at all. A
// runner that fetched the blocker alone would never see the parked continuation
// and the chain would stop silently — the same read-path blindness that let a
// retracted refutation keep its original title.
//
// The successor's brief is authored by the YIELDING worker: it is the only party
// that knows where it stopped, its context is already loaded, and the brief then
// has its own task id — which is a correction surface. A prediction carried in an
// overwritable per-seat handoff had nowhere to be corrected; this does.
const CONTINUE_PREFIX = "CONTINUE #";

async function promoteContinuations(task) {
  let replies;
  try {
    replies = (await cv.forumGet(task.id, true))?.replies ?? [];
  } catch (e) {
    log(`⚠️ could not read #${task.id} threaded; any parked continuation is NOT promoted: ${String(e.message || e)}`);
    return;
  }
  const parked = replies.filter((r) => (r.title || "").startsWith(CONTINUE_PREFIX));
  if (!parked.length) return;
  for (const p of parked) {
    try {
      const r = await cv.forumPost(SLOT, CHANNEL, p.body || "", undefined, {
        title: p.title,
        status: "incoming",
      });
      const id = r?.post?.id ?? r?.id;
      // Verify through the claim query itself: a continuation that is not
      // claimable stops the chain and looks exactly like a chain that ended.
      const q = await cv.forumRead(CHANNEL, { status: "incoming", limit: 50, compact: true });
      const claimable = (q?.posts ?? []).some((x) => x.id === id);
      log(
        claimable
          ? `promoted continuation #${id} (parked on #${task.id})`
          : `⚠️ continuation #${id} promoted but NOT visible to a claim query — the chain is stalled.`
      );
    } catch (e) {
      log(`⛔ failed to promote a continuation parked on #${task.id}: ${String(e.message || e)}. This log line is the only record.`);
    }
  }
}

// --- validation ---------------------------------------------------------------
//
// Fired by the RUNNER because the runner is the only party that observes
// completion. It ENQUEUES; it does not spawn. The slot stays the only thing
// that starts and reaps processes, so this adds no new lifecycle owner.
//
// The validator is a NON-AUTHOR by construction, which is the property that
// produced every useful correction observed so far — an author cannot see past
// the framing it already published.
//
// ⚠️ KNOWN BLIND SPOT, stated in the task body so the validator can act on it:
// checking work against its acceptance criteria PASSES work that satisfied a
// DEFECTIVE criterion. Measured: an acceptance criterion of mine ("an
// application exists with a stable handle") was satisfiable by an application
// that had never completed. A validator reading only that criterion would have
// passed it. So the validator is asked to judge the CRITERION as well as the
// work — otherwise it inherits the spec's defects and reports them as success.
// VALIDATION_PREFIX, NO_AUTO_VALIDATE, isValidationTask and validationExemption
// live in cv-validation.mjs (tested in test/validation.test.mjs).

async function enqueueValidation(task) {
  const exempt = validationExemption(task, { validateLane: VALIDATE_CHANNEL });
  if (exempt) {
    // Logged, never silent: a skipped validation must be distinguishable from a
    // failed enqueue.
    log(`no validation minted for #${task.id}: ${exempt}`);
    return;
  }
  const title = `${VALIDATION_PREFIX}${task.id} — ${(task.title || "").slice(0, 90)}`;
  const body = [
    `Task **#${task.id}** was marked finished by \`${task.worker}\`. **Check that the work was actually finished.**`,
    ``,
    `You did not do this work and have no stake in its framing. That is why you are the one asked.`,
    ``,
    `## What to read`,
    `- the task post **#${task.id}** — its ACCEPTANCE section is the spec`,
    `- the worker's result reply and its handoff (\`cv_handoff_get role=${task.worker}\`)`,
    `- ⚠️ reads are capped; a long result is silently cut with the TAIL lost. If the`,
    `  part you need is missing, \`cv_forum_search\` can reach it — but you have to`,
    `  suspect it exists first.`,
    ``,
    `## What to check`,
    `1. **Re-derive, do not re-read.** For each claim with a command, RUN it. A claim`,
    `   confirmed by reading the claim again has not been checked.`,
    `2. **Every acceptance criterion — met, or not?** Name each one and say which.`,
    `3. 🔴 **JUDGE THE CRITERIA THEMSELVES.** This is not optional and it is the part`,
    `   most likely to matter. A criterion can be fully satisfied and still not`,
    `   establish what it was written to establish. MEASURED PRECEDENT: a criterion`,
    `   reading "an application exists in the DB with a stable handle" was satisfiable`,
    `   by an application that had never completed checkout — the work passed and the`,
    `   spec was wrong. If a criterion is weak, say so and say what would have been`,
    `   sufficient. **Most defects found in this fleet so far have been in the`,
    `   specification, not in the execution.**`,
    `4. **Where a result is a ZERO**, confirm a positive control exists proving the`,
    `   instrument could have returned non-zero at that moment. A zero without one is`,
    `   not a result.`,
    `5. **Claims labelled DEMONSTRATED** — was a failing arm actually observed, or was`,
    `   it asserted and mislabelled?`,
    ``,
    `## Verdict`,
    `**PASS / PASS-WITH-QUALIFICATION / FAIL**, and for anything short of PASS name the`,
    `specific claim and the command that shows it. **A bare PASS with no re-derivation`,
    `is worth nothing** — say which claims you actually re-ran and which you took on`,
    `trust. Taking some on trust is fine; not saying which is not.`,
    ``,
    `Do not fix anything. Do not re-run the original task. Report.`,
    ``,
    `── ACCEPTANCE ──`,
    `1. A verdict, with per-criterion findings.`,
    `2. An explicit list: claims RE-DERIVED vs claims taken on TRUST.`,
    `3. A judgement on the criteria themselves, including "they were adequate" if so.`,
    `4. \`cv_handoff_set\`, then \`cv_task_done\` on THIS post.`,
  ].join("\n");
  // A lane-supplied brief replaces the generic one wholesale. Substitution is
  // explicit rather than templated so a missing token is visible in the task body
  // instead of silently rendering as empty.
  const finalBody = VALIDATE_BODY
    ? VALIDATE_BODY.replaceAll("#{TASK_ID}", String(task.id))
        .replaceAll("#{WORKER}", String(task.worker ?? "(unknown)"))
        .replaceAll("#{TITLE}", String(task.title ?? ""))
    : body;

  // ⭐ ENQUEUE WHERE THIS RUNNER CAN ACTUALLY CLAIM FROM.
  // A --task-source tasks runner claims from the TASK TABLE and never reads the
  // forum queue, so a validation posted to the forum is created, logged as
  // enqueued, and claimable by nobody. The validation existed and the audit did
  // not. validates_task_id makes the chain traversable (GET /tasks/:id/chain).
  if (TASK_SOURCE === "tasks") {
    // ⭐ --validate-channel MUST route HERE TOO. This is the path every
    // --task-source tasks runner takes, and it hardcoded this slot's own lane,
    // so the producer's own slot could claim its own validation — RULING #7208
    // condition 3 is void when the finding seat re-derives it (/17891).
    // Measured on the lorem-fleet fleet 2026-09-26: startup logged "validations POST to
    // #lorem-tasks-deep" while task #683 was created in lorem-analysis and claimed by
    // lorem-w4, the slot that produced #680.
    const target = VALIDATE_CHANNEL || CHANNEL;
    try {
      const r = await cv.taskCreate({
        fleet: FLEET,
        lane: target,
        title,
        body_md: finalBody,
        priority: VALIDATE_PRIORITY,
        validates_task_id: task.id,
        created_by: SLOT,
        state: "READY",
      });
      const id = r?.task?.id ?? r?.id;
      // Verify through the CLAIM QUERY the runner itself uses — not through a
      // read-back of the row. A row that exists but is not claimable is exactly
      // the failure this replaces, and re-reading the row cannot see it.
      const q = await cv.taskList({ fleet: FLEET, lane: target, state: "READY", limit: 200 });
      const claimable = (q?.tasks ?? []).some((t) => t.id === id);
      log(
        claimable
          ? `validation task #${id} enqueued for #${task.id} in #${target} (prio ${VALIDATE_PRIORITY}, validates_task_id=${task.id})`
          : `⚠️ validation task #${id} created but NOT in the READY claim query for ${FLEET}/${target} — no runner will take it.`
      );
    } catch (e) {
      log(`⛔ could not enqueue validation TASK for #${task.id}: ${String(e.message || e)}. This log line is the only record.`);
    }
    return;
  }

  try {
    const target = VALIDATE_CHANNEL || CHANNEL;
    const r = await cv.forumPost(SLOT, target, finalBody, undefined, { title, status: "incoming" });
    const id = r?.post?.id ?? r?.id;
    // Verify through the queue's own query: a validation nobody can claim is
    // indistinguishable from no validation at all, and fails silently.
    // ⚠️ Query the channel we POSTED TO, not this slot's own — they differ whenever
    // --validate-channel routes validations elsewhere, and checking the wrong one
    // would report "no runner will take it" on every correctly-routed validation.
    const q = await cv.forumRead(target, { status: "incoming", limit: 50, compact: true });
    const claimable = (q?.posts ?? []).some((p) => p.id === id);
    log(
      claimable
        ? `validation #${id} enqueued for #${task.id}${VALIDATE_CHANNEL ? ` → #${target}` : ""}`
        : `⚠️ validation #${id} created in #${target} but NOT visible to a claim query — no runner will take it.`
    );
  } catch (e) {
    log(`⛔ could not enqueue validation for #${task.id}: ${String(e.message || e)}. This log line is the only record.`);
  }
}

async function release(taskId) {
  try {
    if (TASK_SOURCE === "tasks") {
      // RELEASED -> READY is a first-class transition here, and it logs an
      // event. The forum path can only blank the owner and hope.
      // postWithError RETURNS a failure rather than throwing, so the catch
      // below never saw one: a failed release was silent.
      const r = await cv.taskRelease(taskId, { worker: SLOT, reason: `released by ${SLOT}` });
      if (r?._failed) log(`⛔ release of #${taskId} FAILED (${r._status} ${r.error ?? ""}) — it is still HELD by ${SLOT}.`);
    } else {
      await cv.forumAssign(taskId, "", SLOT);
      await cv.forumSetStatus(taskId, "incoming");
    }
  } catch {}
  current = null;
}

// --- heartbeat ---------------------------------------------------------------
// The server had no idea what a slot was doing: idle or busy, with which seat
// and task lived only in this process, and a forum-sourced slot left no trace
// on the server at all. Report it — on every change (checked locally every
// 2 s, no network) and every 30 s regardless, so the server can tell a slot
// that went quiet ("missing") from one that is idle. Fire-and-forget: a lost
// heartbeat never touches the claim loop. A runner without --fleet has no
// place on the fleet board and does not beat.
const BEAT_HOST = process.env.CLAUDIVERSE_HOST || hostname();
const BEAT_EVERY_MS = 30_000;
let beatSig = "";
let beatAt = 0;
let slotSince = new Date().toISOString();

function slotReport(state = current ? "busy" : haltAnnounced ? "halted" : "idle") {
  return {
    slot: SLOT,
    fleet: FLEET,
    state,
    host: BEAT_HOST,
    channel: CHANNEL,
    lane: TASK_SOURCE === "tasks" ? CHANNEL : undefined,
    task_source: TASK_SOURCE,
    model: MODEL || undefined,
    seat: state === "busy" ? current?.worker : undefined,
    task: state === "busy" ? current?.taskId : undefined,
  };
}

async function beat(report) {
  try {
    const r = await cv.runnerHeartbeat({ ...report, since: slotSince });
    if (r?._failed && r._status !== 404) log(`heartbeat refused (${r._status} ${r.error ?? ""})`);
  } catch {
    /* server unreachable: the next beat retries */
  }
}

if (FLEET) {
  setInterval(() => {
    const report = slotReport();
    const sig = JSON.stringify([report.state, report.seat, report.task]);
    if (sig !== beatSig) slotSince = new Date().toISOString();
    if (sig !== beatSig || Date.now() - beatAt >= BEAT_EVERY_MS) {
      beatSig = sig;
      beatAt = Date.now();
      beat(report);
    }
  }, 2000).unref();
}

// --- main ------------------------------------------------------------------
process.on("SIGINT", async () => {
  stopKeys(); // restore the tty — leaving it raw would wreck the user's shell
  // Say the slot closed, so the board drops it rather than showing it missing.
  // Bounded: a dead server must not hold Ctrl-C.
  if (FLEET) await Promise.race([beat(slotReport("stopped")), new Promise((r) => setTimeout(r, 2000))]);
  flushLog(); // never exit holding buffered supervision lines
  console.log("");
  if (current) {
    log(`Ctrl-C — task #${current.taskId} is still ACTIVE and ${current.worker} is STILL RUNNING.`);
    log(`This runner does not kill on exit. Reap deliberately: tmux kill-session -t ${current.worker}`);
  } else {
    log("Ctrl-C — slot released, nothing in flight.");
  }
  process.exit(0);
});

log(`slot open · channel #${CHANNEL} · workdir ${WORKDIR} · reaps ONLY on cv_task_done or a SUPERSEDED task, and only with a readable handoff`);
// State the two things that are invisible in the command line and account for
// every start-up failure seen so far: which server we resolved, and what halt
// scope we carry. Both were silently defaulted in real incidents on 2026-08-16.
log(`server ${cv.CV_BASE_URL}${cv.CV_URL_IS_DEFAULT ? " ⚠️ DEFAULT (CLAUDIVERSE_URL unset)" : ""} · halt scope ${FLEET ? `--fleet ${FLEET}` : "NONE ⚠️ bound by every halt"}`);
// State the models on startup. Which model a worker ran on is otherwise invisible until
// someone reads its transcript, and a slot silently running the wrong tier is exactly the
// kind of thing that gets discovered a day later from a cost report.
log(`binary ${BIN || "(cv-spawn default)"}`);
log(`model ${MODEL || "(binary default)"} · validate-model ${VALIDATE_MODEL || "(binary default)"}`);
log(`effort ${EFFORT || "(binary default)"} · validate-effort ${VALIDATE_EFFORT || "(binary default)"}`);
if (VALIDATE_CHANNEL) log(`validations POST to #${VALIDATE_CHANNEL} (not this slot's own #${CHANNEL})`);
startKeys();
if (process.stdin.isTTY) log(`press 'a' to attach to the running worker · Ctrl-C to close the slot`);
else log(`stdin is not a TTY — the 'a' attach key is unavailable in this terminal`);

// Spawn failures are counted PER TASK. Without this the loop was: claim ->
// spawn fails -> release() sets it back to incoming -> claim the SAME task
// again, with no delay. A tight retry spin that --once has been hiding, since
// --once exits after one attempt whether or not it succeeded. Three strikes and
// the task is left for a human instead of being hammered.
const SPAWN_STRIKES = 3;
for (;;) {
  await drainIfAsked();
  const task = await claim();
  if (task) {
    const before = spawnFailures.get(task.id) ?? 0;
    await runTask(task);
    const after = spawnFailures.get(task.id) ?? 0;
    if (after > before) {
      if (after >= SPAWN_STRIKES) {
        log(`⛔ #${task.id} failed to spawn ${after}× — NOT re-claiming it. Left for a human; the slot moves on.`);
        blocked.add(task.id);
        // A log line in a pane nobody watches is not "left for a human": #1930
        // sat unclaimed 45 min on two slots until lorem-admin's sweep found it
        // (2026-10-08). escalate() records it on the task and pings.
        await escalate(task, `failed to spawn ${after}× on ${SLOT} (${hostname()}); this slot will not claim it again. Last error: ${(lastSpawnError.get(task.id) || "?").slice(0, 300)}`);
      }
      await sleep(POLL_MS); // never re-claim a failing task at spin speed
    }
    if (ONCE) {
      log("--once: slot closing.");
      break;
    }
  } else {
    await sleep(POLL_MS);
  }
}
