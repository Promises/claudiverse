#!/usr/bin/env node
// cv-trust.mjs <workdir> — make sure Claude Code starts in <workdir> with no
// dialog waiting: the folder trusted, and its first-run setup done. cv-spawn
// runs it before every launch; it exits non-zero, saying why, rather than ever
// leave a seat at a dialog nobody answers.
//
// Why: CLAUDIVERSE_SKIP_TRUST was a patched build's feature; stock Claude Code
// ignores it. MEASURED 2026-10-13: two runner workers (2.1.296) sat 35 min on
// "Quick safety check: … trust this folder?", "No, exit" selected, after their
// workdirs moved into repositories nobody had trusted.
//
// What Claude Code reads (source reference 2.1.88, utils/config.ts and env.ts):
//   - the global config: <CLAUDE_CONFIG_DIR or $HOME>/.claude.json, unless a
//     legacy <config home>/.config.json exists;
//   - a folder is trusted when `projects[<key>].hasTrustDialogAccepted` is set
//     for its canonical git root (for a worktree: the main repository's root),
//     else the folder itself, or for any folder above it;
//   - first-run setup opens while `theme` or `hasCompletedOnboarding` is unset.
// Its own writes take a lock, `<file>.lock`, a directory (proper-lockfile).
// This takes the same lock, re-reads the file under it, only ADDS those
// flags, and replaces the file in one rename, so a running seat's write is
// neither lost nor clobbers this one.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const LOCK_WAIT_MS = 15_000;
// proper-lockfile refreshes a held lock's mtime; one untouched this long is stale.
const LOCK_STALE_MS = 30_000;

// The global config Claude Code would read, as it chooses it.
export function configFile(env = process.env, home = os.homedir()) {
  const configHome = env.CLAUDE_CONFIG_DIR || path.join(home, ".claude");
  const legacy = path.join(configHome, ".config.json");
  if (fs.existsSync(legacy)) return legacy;
  return path.join(env.CLAUDE_CONFIG_DIR || home, ".claude.json");
}

const git = (dir, ...args) => {
  try {
    return execFileSync("git", ["-C", dir, ...args], { stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
  } catch {
    return null;
  }
};

// The key Claude Code's trust dialog writes for `dir`: its canonical git root
// (a worktree's main repository root), else the folder. Real paths.
export function trustKey(dir) {
  const real = fs.realpathSync(dir);
  const top = git(real, "rev-parse", "--show-toplevel");
  if (!top) return real;
  const common = git(real, "rev-parse", "--path-format=absolute", "--git-common-dir");
  // A worktree's common dir is the main repository's .git; a submodule's is not named .git.
  if (common && path.basename(common) === ".git") return fs.realpathSync(path.dirname(common));
  return fs.realpathSync(top);
}

// Whether `config` already trusts `dir` (its key, or a folder above it), as Claude Code checks.
export function isTrusted(config, dir, key) {
  const projects = config?.projects || {};
  if (projects[key]?.hasTrustDialogAccepted) return true;
  for (let p = dir; ; p = path.dirname(p)) {
    if (projects[p]?.hasTrustDialogAccepted) return true;
    if (path.dirname(p) === p) return false;
  }
}

export const setupDone = (config) => config?.theme != null && config?.hasCompletedOnboarding === true;

// `config` with `key` trusted and first-run setup done; nothing else changed.
export function withTrustAndSetup(config, key) {
  const c = { ...(config || {}) };
  c.projects = { ...(c.projects || {}), [key]: { ...(c.projects?.[key] || {}), hasTrustDialogAccepted: true } };
  if (c.theme == null) c.theme = "dark";
  c.hasCompletedOnboarding = true;
  return c;
}

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function lock(file) {
  const dir = `${file}.lock`;
  const until = Date.now() + LOCK_WAIT_MS;
  for (;;) {
    try {
      fs.mkdirSync(dir);
      return () => fs.rmSync(dir, { recursive: true, force: true });
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      let age = 0;
      try {
        age = Date.now() - fs.statSync(dir).mtimeMs;
      } catch {
        continue; // released between the two calls
      }
      if (age > LOCK_STALE_MS) {
        fs.rmSync(dir, { recursive: true, force: true });
        continue;
      }
      if (Date.now() > until) throw new Error(`${file} stayed locked (${dir}) for ${LOCK_WAIT_MS / 1000} s: a Claude Code process is writing it`);
      sleep(100);
    }
  }
}

// Trust `dir` and mark first-run setup done in `file`, if needed. Returns
// {changed, key, file}. Throws, saying why, when it cannot.
export function ensureTrusted(dir, file = configFile()) {
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) throw new Error(`${dir} is not a folder`);
  const real = fs.realpathSync(dir);
  const key = trustKey(real);
  const read = () => {
    try {
      return JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (e) {
      if (e.code === "ENOENT") return {};
      throw new Error(`cannot read ${file}: ${e.message}`);
    }
  };

  const before = read();
  if (isTrusted(before, real, key) && setupDone(before)) return { changed: false, key, file };

  fs.mkdirSync(path.dirname(file), { recursive: true });
  const release = lock(file);
  try {
    const config = read(); // under the lock: what the last writer left
    if (isTrusted(config, real, key) && setupDone(config)) return { changed: false, key, file };
    const tmp = `${file}.cv-trust.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(withTrustAndSetup(config, key), null, 2), { mode: 0o600 });
    fs.renameSync(tmp, file);
    return { changed: true, key, file };
  } finally {
    release();
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === fs.realpathSync(process.argv[1])) {
  const dir = process.argv[2];
  if (!dir) {
    console.error("usage: cv-trust.mjs <workdir>   (CLAUDE_CONFIG_DIR chooses the config, as for Claude Code)");
    process.exit(2);
  }
  try {
    const r = ensureTrusted(dir);
    console.error(r.changed ? `cv-trust: trusted ${r.key} in ${r.file}` : `cv-trust: ${r.key} already trusted in ${r.file}`);
  } catch (e) {
    console.error(`cv-trust: cannot make ${dir} start without a dialog: ${e.message}`);
    process.exit(1);
  }
}
