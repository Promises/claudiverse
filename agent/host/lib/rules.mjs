// The host agent's rules: which folders it shows, and which spawns, stops and
// resumes it accepts.
// Pure (no network, no tmux), so they can be tested on their own. The agent is
// the AUTHORITY on these — the server checks the request shape too, but a
// compromised server must still not browse or spawn outside the roots.
//
// 🔴 EVERY FILESYSTEM CALL IS ASYNC AND TIMED. On macOS, reading a protected
// folder (Documents, Desktop, Downloads) from a launchd-run node waits on a
// privacy consent prompt on the machine's screen, for as long as nobody
// answers. With sync calls that froze the whole agent: MEASURED 2026-10-04 on
// the M1, tccd logged AUTHREQ_PROMPTING kTCCServiceSystemPolicyDocumentsFolder
// for the agent, and every request — even the root list, which reads nothing —
// went unanswered while the machine still showed online. Async keeps the agent
// answering; the timeout turns the wait into a refusal that says what to do.
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";

export const MODES = ["default", "acceptEdits", "plan", "auto"]; // never bypassPermissions/dontAsk
export const TITLE = /^[A-Za-z0-9._-]{1,64}$/;
export const MAX_PROMPT = 20000;
export const MAX_DIRS = 500;
export const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const FS_TIMEOUT_MS = 5000;

export class Refusal extends Error {
  // `path`: the folder a refusal is about, when there is one (outside_roots),
  // so a client can offer to allow it instead of only quoting the sentence.
  constructor(code, message, path = null) {
    super(message);
    this.code = code; // outside_roots | not_found | bad_request | limit | spawn_failed | not_permitted
    this.path = path;
  }
}

// `op` on `p`, or a not_permitted Refusal if it has not finished within
// `ms`: the operating system is holding it (a privacy prompt nobody has
// answered). The held call itself stays pending; only the reply moves on.
export function timed(op, p, ms = FS_TIMEOUT_MS) {
  let timer;
  const held = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Refusal("not_permitted",
        `this machine did not let the agent read ${p} within ${ms / 1000} s — on macOS, answer the privacy prompt on its screen, ` +
        `or give node access in System Settings → Privacy & Security → Files and Folders (or Full Disk Access)`)),
      ms);
  });
  return Promise.race([op, held]).finally(() => clearTimeout(timer));
}

// The real paths of the configured roots. A root that does not exist is
// dropped (and reported by the caller), never trusted as a string prefix; so
// is one the machine will not let the agent resolve in time.
export async function realRoots(roots, ms) {
  const out = [];
  for (const r of roots || []) {
    try {
      out.push(await timed(fsp.realpath(r), r, ms));
    } catch {
      /* missing or held root: skipped */
    }
  }
  return out;
}

// The real path of `p`, if it is a root or inside one; else a Refusal.
// realpath first, so `..` and symlinks cannot walk out of a root.
export async function resolveInRoots(p, roots, ms) {
  let real;
  try {
    real = await timed(fsp.realpath(p), p, ms);
  } catch (e) {
    if (e instanceof Refusal) throw e;
    throw new Refusal("not_found", `${p} does not exist`);
  }
  const inside = roots.some((r) => real === r || real.startsWith(r.endsWith(path.sep) ? r : r + path.sep));
  if (!inside) throw new Refusal("outside_roots", `${p} is outside this machine's allowed folders`, real);
  if (!(await timed(fsp.stat(real), p, ms)).isDirectory()) throw new Refusal("bad_request", `${p} is not a folder`);
  return real;
}

// ls: "" lists the roots themselves (full paths); a folder lists its visible
// subfolders by name. `parent` is "" when the folder is a root (back to the
// root list), else its parent folder.
export async function listDirs(p, roots, ms) {
  if (!p) return { path: "", parent: null, dirs: [...roots], truncated: false };

  const real = await resolveInRoots(p, roots, ms);
  const names = (await timed(fsp.readdir(real, { withFileTypes: true }), p, ms))
    .filter((d) => d.isDirectory() && !d.name.startsWith("."))
    .map((d) => d.name)
    .sort((a, b) => a.localeCompare(b));

  return {
    path: real,
    parent: roots.includes(real) ? "" : path.dirname(real),
    dirs: names.slice(0, MAX_DIRS),
    truncated: names.length > MAX_DIRS,
  };
}

// A title from a folder name: invalid characters become "-", cut to 64.
export function defaultTitle(dir) {
  const t = path.basename(dir).replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64);
  return TITLE.test(t) ? t : "seat";
}

// Validate a spawn request; returns the normalised arguments or throws.
export async function checkSpawn(args, roots, ms) {
  const mode = args?.mode ?? "auto";
  if (!MODES.includes(mode)) throw new Refusal("bad_request", `mode must be one of ${MODES.join(", ")}`);
  if (typeof args?.path !== "string" || !args.path) throw new Refusal("bad_request", "path is required");

  const title = args.title == null || args.title === "" ? null : args.title;
  if (title !== null && (typeof title !== "string" || !TITLE.test(title)))
    throw new Refusal("bad_request", "title must be 1-64 of A-Z a-z 0-9 . _ -");

  const prompt = args.prompt == null || args.prompt === "" ? null : args.prompt;
  if (prompt !== null && (typeof prompt !== "string" || prompt.length > MAX_PROMPT))
    throw new Refusal("bad_request", `prompt must be text of at most ${MAX_PROMPT} characters`);

  const dir = await resolveInRoots(args.path, roots, ms);
  return { dir, title: title ?? defaultTitle(dir), mode, prompt };
}

// Validate a resume request: a spawn (same folder, mode and title rules) plus
// the Claude Code session id to continue. No prompt: a resumed seat waits for
// its next message like any other.
export async function checkResume(args, roots, ms) {
  if (typeof args?.session_id !== "string" || !SESSION_ID.test(args.session_id))
    throw new Refusal("bad_request", "session_id must be a Claude Code session uuid");
  const { dir, title, mode } = await checkSpawn({ ...args, prompt: null }, roots, ms);
  return { dir, title, mode, sessionId: args.session_id.toLowerCase() };
}

// Validate a stop request's title (the tmux session to close).
export function checkStopTitle(args) {
  if (typeof args?.title !== "string" || !TITLE.test(args.title)) throw new Refusal("bad_request", "title must be 1-64 of A-Z a-z 0-9 . _ -");
  return args.title;
}

// Where Claude Code keeps conversation `id`, if anywhere: <configDir>/projects/
// <folder slug>/<id>.jsonl. A seat that never had a turn has none, and
// `claude --resume` of it exits at once, so the agent refuses up front. Looks
// in the folder's own slug first, then in every project (the slug rule is
// Claude Code's, and long paths are shortened), so a slug mismatch cannot
// refuse a conversation that exists. Sync: the config dir is never a
// privacy-protected folder.
export function findTranscript(configDir, dir, id) {
  const projects = path.join(configDir, "projects");
  const own = path.join(projects, dir.replace(/[^A-Za-z0-9]/g, "-"), `${id}.jsonl`);
  if (fs.existsSync(own)) return own;
  let entries = [];
  try {
    entries = fs.readdirSync(projects, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const e of entries) {
    const f = path.join(projects, e.name, `${id}.jsonl`);
    if (e.isDirectory() && fs.existsSync(f)) return f;
  }
  return null;
}

// The whitelist edits, on a parsed config object (the caller writes it back).
// add: `dir` must be an existing folder; stored as its real path, once. A
// folder an allowed root already covers adds nothing, and the roots a new one
// covers are dropped (by real path, whole segments), so the list holds no
// duplicates whichever client edits it.
// remove: drops every entry that is `dir` or resolves to the same real path.
// Both return { config, changed, roots }.
export async function addRoot(config, dir, ms) {
  let real;
  try {
    real = await timed(fsp.realpath(dir || ""), dir, ms);
    if (!(await timed(fsp.stat(real), dir, ms)).isDirectory()) throw new Error("not a folder");
  } catch (e) {
    if (e instanceof Refusal) throw e;
    throw new Refusal("not_found", `${dir || "(none)"} is not an existing folder`);
  }
  const before = Array.isArray(config.roots) ? config.roots : [];
  const reals = await Promise.all(before.map((r) => timed(fsp.realpath(r), r, ms).catch(() => r)));
  const within = (inner, outer) => inner === outer || inner.startsWith(outer.endsWith(path.sep) ? outer : outer + path.sep);
  if (reals.some((r) => within(real, r))) return { config: { ...config, roots: [...before] }, changed: false, roots: [...before] };
  const roots = [...before.filter((_, i) => !within(reals[i], real)), real];
  return { config: { ...config, roots }, changed: true, roots };
}

export async function removeRoot(config, dir, ms) {
  const realOf = async (p) => {
    try {
      return await timed(fsp.realpath(p), p, ms);
    } catch {
      return null; // gone or held: compared by its stored path only
    }
  };
  const real = await realOf(dir);
  const before = Array.isArray(config.roots) ? config.roots : [];
  const roots = [];
  for (const r of before) {
    if (r === dir) continue;
    if (real && (await realOf(r)) === real) continue;
    roots.push(r);
  }
  return { config: { ...config, roots }, changed: roots.length !== before.length, roots };
}

// --- seat profiles (the server's start_profile) ------------------------------------
//
// A profile chooses only among what THIS machine's config offers: permission
// modes (a subset of MODES), runtime NAMES (each mapped to a binary here) and
// MCP server NAMES from the machine's own catalog. Nothing in a profile is a
// path to run, a command line or an environment variable.

const MODEL = /^[A-Za-z0-9._:\[\]-]{1,100}$/;
export const RUNTIME = /^[A-Za-z0-9.+_-]{1,64}$/; // "stock+mod"
export const EFFORTS = ["low", "medium", "high", "xhigh", "max"];

// What a profile may choose on this machine, as the server lists it.
export function machineChoices(cfg, catalog) {
  const modes = (Array.isArray(cfg.modes) ? cfg.modes : MODES).filter((m) => MODES.includes(m));
  const runtimes = Object.entries(cfg.runtimes || {})
    .filter(([n, r]) => RUNTIME.test(n) && typeof r?.bin === "string" && path.isAbsolute(r.bin))
    .map(([name, r]) => ({ name, version: typeof r.version === "string" ? r.version : null }));
  const mcp = Object.keys(catalog?.mcpServers || {}).filter((n) => TITLE.test(n));
  return { modes, runtimes, mcp };
}

// The runtime the app's plain New seat and resume start, when `spawn_runtime`
// names one of this machine's runtimes; null leaves them on `bin` (or
// cv-spawn's default). A profile names its own runtime and is not affected.
// Without it a seat from the app's "+" ran the patched runtime, which sends
// none of the mod's rows (agents, background tasks, timestamps): MEASURED
// 2026-10-09, seat 204701 came up as 2.1.289 [claudiverse] beside a fleet on
// stock+mod. An unknown name is a config error, not a silent fallback.
export function spawnRuntime(cfg) {
  const name = cfg.spawn_runtime;
  if (name == null) return null;
  const r = cfg.runtimes?.[name];
  if (!RUNTIME.test(String(name)) || typeof r?.bin !== "string" || !path.isAbsolute(r.bin))
    throw new Error(`spawn_runtime "${name}" is not one of this machine's runtimes`);
  const abs = (v) => (typeof v === "string" && path.isAbsolute(v) ? v : null);
  // spawn_pooled: plain seats send their model calls through the server's
  // account pool (--pooled). Profiles choose pooling themselves. MEASURED
  // 2026-10-11: a "+" seat on stock+mod used the runtime's token file alone,
  // i.e. one account directly, and stopped at that account's weekly limit
  // while the pool had another account free.
  return { name, bin: r.bin, configDir: abs(r.config_dir), oauthTokenFile: abs(r.oauth_token_file), poolOnly: r.pool_only === true,
           pooled: cfg.spawn_pooled === true || r.pool_only === true };
}

const posInt = (v) => Number.isInteger(v) && v > 0;

// Validate a start_profile request against this machine's choices; returns
// what the launch needs or throws a Refusal.
export async function checkProfile(args, roots, cfg, catalog, ms) {
  const a = args || {};
  if (typeof a.name !== "string" || !TITLE.test(a.name)) throw new Refusal("bad_request", "name must be 1-64 of A-Z a-z 0-9 . _ -");
  if (!posInt(a.profile_id) || !posInt(a.revision)) throw new Refusal("bad_request", "profile_id and revision must be positive integers");
  const choices = machineChoices(cfg, catalog);
  if (!choices.modes.includes(a.mode)) throw new Refusal("not_allowed", `mode ${a.mode} is not allowed here (${choices.modes.join(", ")})`);
  const runtime = choices.runtimes.find((r) => r.name === a.runtime);
  if (!runtime) throw new Refusal("not_allowed", `runtime ${a.runtime} is not configured here (${choices.runtimes.map((r) => r.name).join(", ") || "none"})`);
  if (a.model != null && !(typeof a.model === "string" && MODEL.test(a.model))) throw new Refusal("bad_request", "model must be a model name");
  if (a.effort != null && !EFFORTS.includes(a.effort)) throw new Refusal("bad_request", `effort must be one of ${EFFORTS.join(", ")}`);
  if (a.fleet != null && !(typeof a.fleet === "string" && TITLE.test(a.fleet))) throw new Refusal("bad_request", "fleet must be 1-64 of A-Z a-z 0-9 . _ -");
  const mcp = a.mcp ?? [];
  if (!Array.isArray(mcp) || mcp.some((n) => typeof n !== "string")) throw new Refusal("bad_request", "mcp must be a list of names");
  const missing = mcp.filter((n) => !choices.mcp.includes(n));
  if (missing.length) throw new Refusal("not_allowed", `not in this machine's MCP catalog: ${missing.join(", ")}`);
  if (a.resume != null && !(typeof a.resume === "string" && SESSION_ID.test(a.resume))) throw new Refusal("bad_request", "resume must be a Claude Code session uuid");

  const dir = await resolveInRoots(a.folder, roots, ms);
  return {
    name: a.name, profileId: a.profile_id, revision: a.revision, dir, mode: a.mode,
    runtime: runtime.name, bin: cfg.runtimes[runtime.name].bin,
    // A runtime may name its own Claude Code config dir (CLAUDE_CONFIG_DIR):
    // the M1's stock+mod seats use ~/.claude-pilot (mod + login), so
    // ~/.claude, which the patched fleet uses, stays untouched.
    configDir: typeof cfg.runtimes[runtime.name].config_dir === "string" && path.isAbsolute(cfg.runtimes[runtime.name].config_dir)
      ? cfg.runtimes[runtime.name].config_dir : null,
    // And may log its seats in with a long-lived token file (`claude
    // setup-token`) instead of that dir's refreshing login: one rejected
    // refresh blanked the M1 pilot's shared login for every seat on it
    // (2026-10-06). Passed to cv-spawn as --oauth-token-file.
    oauthTokenFile: typeof cfg.runtimes[runtime.name].oauth_token_file === "string" && path.isAbsolute(cfg.runtimes[runtime.name].oauth_token_file)
      ? cfg.runtimes[runtime.name].oauth_token_file : null,
    // And may have no login at all: "pool_only" seats log in with the pool's
    // placeholder and run on the server's account pool (cv-spawn --pool-only),
    // whatever the profile's own `pooled` says, since nothing else can serve them.
    poolOnly: cfg.runtimes[runtime.name].pool_only === true,
    model: a.model ?? null, effort: a.effort ?? null, fleet: a.fleet ?? null, mcp,
    resume: a.resume ? a.resume.toLowerCase() : null, resumePolicy: a.resume_policy === "latest" ? "latest" : "fixed",
    debug: a.debug === true,
    pooled: a.pooled === true,
  };
}

// The MCP config a profile's seat gets: the named entries of the catalog, as is.
export function mcpConfigFor(catalog, names) {
  return { mcpServers: Object.fromEntries(names.map((n) => [n, catalog.mcpServers[n]])) };
}

// Claude Code's folder trust lives in its global config (~/.claude.json):
// projects[<folder>].hasTrustDialogAccepted. A stock seat started in an
// untrusted folder sits at the trust dialog with nobody there to answer it.
//
// Inherited trust is NOT reliable, so the agent requires the EXACT entry
// Claude Code's own dialog writes (the git root, else the folder) to be true.
// MEASURED on 2.1.289: (1) a seat in a subfolder of the claudiverse repo got
// the dialog although ~/Documents was trusted (inside a repo the lookup stops
// at the repo root); (2) claudiverse-forum-dev, not a repo, got the dialog
// although ~/Documents was trusted, because its own entry said
// hasTrustDialogAccepted: false; with that entry true, no dialog. A probe
// folder with NO entry inherited fine, which is why (2) slipped through.
// `root` is the folder's git root, or null.
export function isTrusted(claudeJson, dir, root = null) {
  return claudeJson?.projects?.[trustKey(dir, root)]?.hasTrustDialogAccepted === true;
}

// The entry Claude Code's own dialog would set: the repo root, else the folder.
export const trustKey = (dir, root = null) => root ?? dir;

export function withTrust(claudeJson, dir) {
  const projects = { ...(claudeJson?.projects || {}) };
  projects[dir] = { ...(projects[dir] || {}), hasTrustDialogAccepted: true };
  return { ...(claudeJson || {}), projects };
}

// Claude Code's first-run setup (choose a theme, read the security notes)
// opens whenever the global config has no `theme` or no
// `hasCompletedOnboarding`, before any folder's trust. On a machine where
// nobody ever ran `claude` by hand, a seat would sit there with nobody to
// answer it (MEASURED on 2.1.296, a fresh Debian with no Claude login). Set
// both as the first run would, keeping a theme already chosen.
export function setupDone(claudeJson) {
  return claudeJson?.theme != null && claudeJson?.hasCompletedOnboarding === true;
}

export function withSetupDone(claudeJson) {
  return { ...(claudeJson || {}), theme: claudeJson?.theme ?? "dark", hasCompletedOnboarding: true };
}
