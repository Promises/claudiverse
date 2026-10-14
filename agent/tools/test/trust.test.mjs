// node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { configFile, ensureTrusted, trustKey } from "../cv-trust.mjs";

// Real folders and real git, in a throwaway place.
const scratch = () => fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cv-trust-")));
const git = (dir, ...args) => execFileSync("git", ["-C", dir, "-c", "user.name=test", "-c", "user.email=test@example.com", ...args], { stdio: "pipe" });
const read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));

test("a plain folder is trusted as itself, first-run setup marked done, and nothing else in the file changes", () => {
  const home = scratch();
  const dir = path.join(home, "work");
  fs.mkdirSync(dir);
  const file = path.join(home, ".claude.json");
  fs.writeFileSync(file, JSON.stringify({ numStartups: 7, theme: "light", projects: { "/elsewhere": { allowedTools: ["Bash"] } } }));

  assert.deepEqual(ensureTrusted(dir, file), { changed: true, key: dir, file });
  const c = read(file);
  assert.equal(c.projects[dir].hasTrustDialogAccepted, true);
  assert.deepEqual(c.projects["/elsewhere"], { allowedTools: ["Bash"] });
  assert.equal(c.numStartups, 7);
  assert.equal(c.theme, "light", "a theme already chosen is kept");
  assert.equal(c.hasCompletedOnboarding, true);
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.equal(fs.existsSync(`${file}.lock`), false, "the lock is released");
});

test("in a repository the key is its root; in a worktree, the main repository's root", () => {
  const base = scratch();
  const repo = path.join(base, "repo");
  fs.mkdirSync(path.join(repo, "sub"), { recursive: true });
  git(repo, "init", "-q");
  git(repo, "commit", "-q", "--allow-empty", "-m", "first");
  assert.equal(trustKey(path.join(repo, "sub")), repo);

  const wt = path.join(base, "wt");
  git(repo, "worktree", "add", "-q", wt);
  assert.equal(trustKey(wt), repo, "what Claude Code's dialog writes for a worktree (resolveCanonicalRoot)");
});

test("a folder already trusted, itself or by a folder above it, is left alone: no write", () => {
  const home = scratch();
  const dir = path.join(home, "a", "b");
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(home, ".claude.json");
  const text = JSON.stringify({ theme: "dark", hasCompletedOnboarding: true, projects: { [path.join(home, "a")]: { hasTrustDialogAccepted: true } } });
  fs.writeFileSync(file, text);
  assert.equal(ensureTrusted(dir, file).changed, false);
  assert.equal(fs.readFileSync(file, "utf8"), text);
});

test("Claude Code's lock is waited for while held, and taken over when stale", async () => {
  const home = scratch();
  const dir = path.join(home, "work");
  fs.mkdirSync(dir);
  const file = path.join(home, ".claude.json");
  fs.writeFileSync(file, "{}");

  // Held by another process, released 300 ms later.
  fs.mkdirSync(`${file}.lock`);
  const releaser = spawn("sh", ["-c", `sleep 0.3; rmdir '${file}.lock'`]);
  const t0 = Date.now();
  assert.equal(ensureTrusted(dir, file).changed, true);
  assert.ok(Date.now() - t0 >= 250, "it waited for the lock");
  await new Promise((res) => releaser.on("exit", res));

  // Abandoned a minute ago: stale.
  const dir2 = path.join(home, "work2");
  fs.mkdirSync(dir2);
  fs.mkdirSync(`${file}.lock`);
  const old = new Date(Date.now() - 60_000);
  fs.utimesSync(`${file}.lock`, old, old);
  assert.equal(ensureTrusted(dir2, file).changed, true);
  assert.equal(read(file).projects[dir2].hasTrustDialogAccepted, true);
});

test("a config it cannot read is refused, not overwritten", () => {
  const home = scratch();
  const dir = path.join(home, "work");
  fs.mkdirSync(dir);
  const file = path.join(home, ".claude.json");
  fs.writeFileSync(file, "{ not json");
  assert.throws(() => ensureTrusted(dir, file), /cannot read/);
  assert.equal(fs.readFileSync(file, "utf8"), "{ not json");
});

test("the config file is the one Claude Code reads: CLAUDE_CONFIG_DIR's, else the home's; a legacy .config.json first", () => {
  const home = scratch();
  const cfg = path.join(home, "cfg");
  fs.mkdirSync(cfg);
  assert.equal(configFile({}, home), path.join(home, ".claude.json"));
  assert.equal(configFile({ CLAUDE_CONFIG_DIR: cfg }, home), path.join(cfg, ".claude.json"));
  fs.writeFileSync(path.join(cfg, ".config.json"), "{}");
  assert.equal(configFile({ CLAUDE_CONFIG_DIR: cfg }, home), path.join(cfg, ".config.json"));
});
