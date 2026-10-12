// node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { timed, realRoots, listDirs, checkSpawn, checkResume, checkStopTitle, resolveInRoots, findTranscript, addRoot, removeRoot, defaultTitle, Refusal, MAX_DIRS,
         machineChoices, checkProfile, mcpConfigFor, isTrusted, trustKey, withTrust, setupDone, withSetupDone, spawnRuntime } from "../lib/rules.mjs";

async function tree() {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cvha-")));
  const root = path.join(base, "projects");
  for (const d of ["root/app", "root/lib", "root/.hidden", "outside"]) fs.mkdirSync(path.join(base, d.replace(/^root/, "projects")), { recursive: true });
  fs.writeFileSync(path.join(root, "file.txt"), "x");
  fs.symlinkSync(path.join(base, "outside"), path.join(root, "escape"));
  return { base, root, roots: await realRoots([root, path.join(base, "missing")]) };
}

const refused = (fn, code) => assert.rejects(async () => fn(), (e) => e instanceof Refusal && e.code === code);

test("a missing root is dropped, not trusted as a prefix", async () => {
  const t = await tree();
  assert.deepEqual(t.roots, [t.root]);
});

test("ls of '' lists the roots; ls of a root lists visible subfolders only", async () => {
  const t = await tree();
  assert.deepEqual((await listDirs("", t.roots)).dirs, [t.root]);
  const r = (await listDirs(t.root, t.roots));
  assert.deepEqual(r.dirs, ["app", "lib"], "no files, no dot-folders, no symlink escape");
  assert.equal(r.parent, "", "a root's parent is the root list");
  assert.equal((await listDirs(path.join(t.root, "app"), t.roots)).parent, t.root);
});

test("outside the roots is refused, including via .. and via a symlink", async () => {
  const t = await tree();
  await refused(() => listDirs(path.join(t.base, "outside"), t.roots), "outside_roots");
  await refused(() => listDirs(path.join(t.root, "..", "outside"), t.roots), "outside_roots");
  await refused(() => listDirs(path.join(t.root, "escape"), t.roots), "outside_roots");
  await refused(() => listDirs("/etc", t.roots), "outside_roots");
  await refused(() => listDirs(path.join(t.root, "nope"), t.roots), "not_found");
});

test("a sibling folder sharing the root's prefix is outside", async () => {
  const t = await tree();
  fs.mkdirSync(t.root + "-evil");
  await refused(() => listDirs(t.root + "-evil", t.roots), "outside_roots");
});

test("a long folder is truncated at the cap", async () => {
  const t = await tree();
  const big = path.join(t.root, "big");
  for (let i = 0; i < MAX_DIRS + 3; i++) fs.mkdirSync(path.join(big, `d${String(i).padStart(4, "0")}`), { recursive: true });
  const r = (await listDirs(big, t.roots));
  assert.equal(r.dirs.length, MAX_DIRS);
  assert.equal(r.truncated, true);
});

test("spawn: only the four normal modes; never bypassPermissions or dontAsk", async () => {
  const t = await tree();
  const app = path.join(t.root, "app");
  assert.equal((await checkSpawn({ path: app }, t.roots)).mode, "auto");
  for (const mode of ["default", "acceptEdits", "plan", "auto"]) assert.equal((await checkSpawn({ path: app, mode }, t.roots)).mode, mode);
  for (const mode of ["bypassPermissions", "dontAsk", "AUTO", ""]) await refused(() => checkSpawn({ path: app, mode }, t.roots), "bad_request");
});

test("spawn: path must be inside the roots; title defaults to the folder and is checked", async () => {
  const t = await tree();
  await refused(() => checkSpawn({ path: path.join(t.base, "outside") }, t.roots), "outside_roots");
  assert.equal((await checkSpawn({ path: path.join(t.root, "app") }, t.roots)).title, "app");
  await refused(() => checkSpawn({ path: path.join(t.root, "app"), title: "x:y" }, t.roots), "bad_request");
  await refused(() => checkSpawn({ path: path.join(t.root, "app"), prompt: "x".repeat(20001) }, t.roots), "bad_request");
});

test("default titles are made safe for tmux", async () => {
  assert.equal(defaultTitle("/a/My Project (v2)"), "My-Project-v2");
  assert.equal(defaultTitle("/a/:::"), "seat");
});

const SID = "6d9b917b-1779-49d0-b95b-ad36f8a84f8b";

test("resume: needs a session uuid, then follows the spawn rules and drops any prompt", async () => {
  const t = await tree();
  const app = path.join(t.root, "app");
  const r = (await checkResume({ path: app, session_id: SID.toUpperCase(), prompt: "hi" }, t.roots));
  assert.deepEqual(r, { dir: app, title: "app", mode: "auto", sessionId: SID });
  for (const session_id of [undefined, "", "abc", `${SID}; rm -rf /`, `--${SID}`, 42])
    await refused(() => checkResume({ path: app, session_id }, t.roots), "bad_request");
  await refused(() => checkResume({ path: path.join(t.base, "outside"), session_id: SID }, t.roots), "outside_roots");
  await refused(() => checkResume({ path: app, session_id: SID, mode: "bypassPermissions" }, t.roots), "bad_request");
});

test("stop: the title must be a plain tmux name; its folder must be inside the roots", async () => {
  const t = await tree();
  assert.equal(checkStopTitle({ title: "ipsum-admin" }), "ipsum-admin");
  for (const title of [undefined, "", "a:b", "=x", "a b", "x".repeat(65)]) await refused(() => checkStopTitle({ title }), "bad_request");
  // the agent checks the seat's pane folder with resolveInRoots
  assert.equal((await resolveInRoots(path.join(t.root, "app"), t.roots)), path.join(t.root, "app"));
  await refused(() => resolveInRoots(path.join(t.base, "outside"), t.roots), "outside_roots");
});

test("findTranscript: the folder's own slug, else any project; null when the conversation never existed", async () => {
  const t = await tree();
  const conf = path.join(t.base, "claude");
  const app = path.join(t.root, "app");
  const slug = app.replace(/[^A-Za-z0-9]/g, "-");
  fs.mkdirSync(path.join(conf, "projects", slug), { recursive: true });
  fs.mkdirSync(path.join(conf, "projects", "-shortened-hash"), { recursive: true });

  assert.equal(findTranscript(conf, app, SID), null, "no transcript: nothing to resume");
  fs.writeFileSync(path.join(conf, "projects", "-shortened-hash", `${SID}.jsonl`), "{}\n");
  assert.equal(findTranscript(conf, app, SID), path.join(conf, "projects", "-shortened-hash", `${SID}.jsonl`));
  fs.writeFileSync(path.join(conf, "projects", slug, `${SID}.jsonl`), "{}\n");
  assert.equal(findTranscript(conf, app, SID), path.join(conf, "projects", slug, `${SID}.jsonl`));
  assert.equal(findTranscript(path.join(t.base, "no-such-config"), app, SID), null);
});

test("addRoot: an existing folder, stored by real path, once; anything else is refused", async () => {
  const t = await tree();
  const app = path.join(t.root, "app");
  const r = (await addRoot({ roots: [], other: 1 }, path.join(t.root, "lib", "..", "app")));
  assert.deepEqual(r.roots, [app]);
  assert.equal(r.changed, true);
  assert.equal(r.config.other, 1, "the rest of the config is kept");
  assert.equal((await addRoot(r.config, app)).changed, false);
  await refused(() => addRoot({ roots: [] }, path.join(t.root, "nope")), "not_found");
  await refused(() => addRoot({ roots: [] }, path.join(t.root, "file.txt")), "not_found");
  assert.deepEqual((await addRoot({}, app)).roots, [app], "a config without roots gets one");
});

test("addRoot keeps the list free of duplicates: a covered folder adds nothing, a parent replaces its children", async () => {
  const t = await tree();
  const app = path.join(t.root, "app");
  const covered = await addRoot({ roots: [t.root] }, app);
  assert.equal(covered.changed, false);
  assert.deepEqual(covered.roots, [t.root]);

  const other = fs.mkdtempSync(path.join(t.base, "other-"));
  const parent = await addRoot({ roots: [app, other] }, t.root);
  assert.deepEqual(parent.roots, [other, t.root], "app is inside the new root; other is not");

  // Whole segments: /x/projects2 is not inside /x/projects.
  const sibling = fs.realpathSync(fs.mkdtempSync(t.root + "-sib"));
  assert.deepEqual((await addRoot({ roots: [t.root] }, sibling)).roots, [t.root, sibling]);
});

test("removeRoot: by stored path or by any path to the same folder; a vanished folder can still go", async () => {
  const t = await tree();
  const app = path.join(t.root, "app");
  assert.deepEqual((await removeRoot({ roots: [t.root, app] }, path.join(t.root, "lib", "..", "app"))).roots, [t.root]);
  assert.deepEqual((await removeRoot({ roots: ["/gone/folder", app] }, "/gone/folder")).roots, [app]);
  assert.equal((await removeRoot({ roots: [app] }, t.root)).changed, false);
});

test("a filesystem call the machine holds becomes a not_permitted refusal, not a hang", async () => {
  const never = new Promise(() => {});
  const t0 = Date.now();
  await assert.rejects(timed(never, "/Users/x/Documents", 50), (e) => e instanceof Refusal && e.code === "not_permitted" && /privacy/.test(e.message));
  assert.ok(Date.now() - t0 < 1000);
  assert.equal(await timed(Promise.resolve(7), "/x", 50), 7, "a call that finishes in time is passed through");
});

// --- seat profiles ------------------------------------------------------------------

const cfgP = { runtimes: { "stock+mod": { bin: "/usr/local/bin/claude", version: "2.1.289" }, bad: { bin: "relative/claude" } }, modes: ["default", "auto", "bypassPermissions"] };
const catalog = { mcpServers: { claudiverse: { command: "node", args: ["cv-mcp.mjs"] }, ghidra: { command: "ghidra-mcp" } } };
const UUID = "0b5e4c2a-1111-4222-8333-944455556666";

async function profileArgs(t, extra = {}) {
  return { name: "ipsum-admin", profile_id: 7, revision: 3, folder: path.join(t.root, "app"), runtime: "stock+mod", mode: "auto",
           mcp: ["claudiverse"], model: "claude-opus-5-5[1m]", effort: "high", fleet: "ipsum-fleet", resume: null, debug: false, ...extra };
}

test("machine choices: modes never beyond MODES, runtimes only with an absolute binary, catalog names", () => {
  assert.deepEqual(machineChoices(cfgP, catalog), {
    modes: ["default", "auto"],
    runtimes: [{ name: "stock+mod", version: "2.1.289" }],
    mcp: ["claudiverse", "ghidra"],
  });
  assert.deepEqual(machineChoices({}, null).runtimes, [], "no runtimes configured: nothing to start");
});

test("checkProfile accepts a profile within the machine's choices", async () => {
  const t = await tree();
  const p = await checkProfile(await profileArgs(t, { resume: UUID.toUpperCase(), resume_policy: "latest" }), t.roots, cfgP, catalog);
  assert.equal(p.bin, "/usr/local/bin/claude");
  assert.equal(p.dir, path.join(t.root, "app"));
  assert.equal(p.resume, UUID);
  assert.equal(p.resumePolicy, "latest");
  assert.deepEqual(p.mcp, ["claudiverse"]);
  assert.equal(p.pooled, false, "pooled only when the profile says true");
  assert.equal(p.configDir, null, "no config dir unless the runtime names one");
  const withDir = { ...cfgP, runtimes: { ...cfgP.runtimes, "stock+mod": { ...cfgP.runtimes["stock+mod"], config_dir: "/Users/x/.claude-pilot" } } };
  assert.equal((await checkProfile(await profileArgs(t), t.roots, withDir, catalog)).configDir, "/Users/x/.claude-pilot");
  const relDir = { ...cfgP, runtimes: { ...cfgP.runtimes, "stock+mod": { ...cfgP.runtimes["stock+mod"], config_dir: "relative/dir" } } };
  assert.equal((await checkProfile(await profileArgs(t), t.roots, relDir, catalog)).configDir, null, "only an absolute path");
  assert.equal(p.oauthTokenFile, null, "no token file unless the runtime names one");
  const withTok = { ...cfgP, runtimes: { ...cfgP.runtimes, "stock+mod": { ...cfgP.runtimes["stock+mod"], oauth_token_file: "/Users/x/.config/claudiverse/pilot-oauth-token" } } };
  assert.equal((await checkProfile(await profileArgs(t), t.roots, withTok, catalog)).oauthTokenFile, "/Users/x/.config/claudiverse/pilot-oauth-token");
  const relTok = { ...cfgP, runtimes: { ...cfgP.runtimes, "stock+mod": { ...cfgP.runtimes["stock+mod"], oauth_token_file: "token" } } };
  assert.equal((await checkProfile(await profileArgs(t), t.roots, relTok, catalog)).oauthTokenFile, null, "only an absolute path");
  assert.equal((await checkProfile(await profileArgs(t, { pooled: true }), t.roots, cfgP, catalog)).pooled, true);
  assert.equal((await checkProfile(await profileArgs(t, { pooled: "yes" }), t.roots, cfgP, catalog)).pooled, false, "only a real true");
  assert.equal(p.poolOnly, false, "a runtime is pool-only only when it says so");
  const poolOnly = { ...cfgP, runtimes: { ...cfgP.runtimes, "stock+mod": { ...cfgP.runtimes["stock+mod"], pool_only: true } } };
  assert.equal((await checkProfile(await profileArgs(t, { pooled: false }), t.roots, poolOnly, catalog)).poolOnly, true);
});

test("checkProfile refuses what the machine does not offer", async () => {
  const t = await tree();
  const bad = async (extra, code) => refused(async () => checkProfile(await profileArgs(t, extra), t.roots, cfgP, catalog), code);
  await bad({ mode: "bypassPermissions" }, "not_allowed");
  await bad({ mode: "acceptEdits" }, "not_allowed");
  await bad({ runtime: "bad" }, "not_allowed");
  await bad({ runtime: "/bin/sh" }, "not_allowed");
  await bad({ mcp: ["evil"] }, "not_allowed");
  await bad({ folder: path.join(t.base, "outside") }, "outside_roots");
  await bad({ folder: path.join(t.root, "escape") }, "outside_roots");
  await bad({ name: "a b" }, "bad_request");
  await bad({ name: "x; rm -rf ~" }, "bad_request");
  await bad({ profile_id: "7" }, "bad_request");
  await bad({ model: "opus --dangerously-skip-permissions" }, "bad_request");
  await bad({ effort: "huge" }, "bad_request");
  await bad({ resume: "../../etc" }, "bad_request");
  await bad({ fleet: "a/b" }, "bad_request");
});

test("the generated MCP config holds only the named catalog entries", () => {
  assert.deepEqual(mcpConfigFor(catalog, ["ghidra"]), { mcpServers: { ghidra: { command: "ghidra-mcp" } } });
  assert.deepEqual(mcpConfigFor(catalog, []), { mcpServers: {} });
});

test("trust: a trusted parent covers a subfolder; withTrust adds only the flag", () => {
  const json = { theme: "dark", projects: { "/srv": { hasTrustDialogAccepted: true }, "/home/a": { allowedTools: ["x"] } } };
  // Only the exact entry counts: inherited trust is not relied on.
  assert.equal(isTrusted(json, "/srv"), true);
  assert.equal(isTrusted(json, "/srv/ipsum/app"), false, "a trusted parent does not count");
  assert.equal(isTrusted(json, "/home/a"), false);
  assert.equal(isTrusted({}, "/x"), false);
  // An explicit false on the folder (claudiverse-forum-dev's case) is untrusted.
  assert.equal(isTrusted({ projects: { "/d": { hasTrustDialogAccepted: false }, "/": { hasTrustDialogAccepted: true } } }, "/d"), false);
  // Inside a git repo the key is the repo root.
  assert.equal(isTrusted(json, "/srv/ipsum/app", "/srv/ipsum"), false);
  assert.equal(isTrusted({ projects: { "/srv/ipsum": { hasTrustDialogAccepted: true } } }, "/srv/ipsum/app", "/srv/ipsum"), true);
  assert.equal(trustKey("/srv/ipsum/app", "/srv/ipsum"), "/srv/ipsum");
  assert.equal(trustKey("/srv/x", null), "/srv/x");
  const t = withTrust(json, "/home/a");
  assert.deepEqual(t.projects["/home/a"], { allowedTools: ["x"], hasTrustDialogAccepted: true });
  assert.equal(t.theme, "dark");
  assert.equal(json.projects["/home/a"].hasTrustDialogAccepted, undefined, "the input is not modified");
});

test("first-run setup: done only with a theme and the onboarding flag; withSetupDone keeps a chosen theme", () => {
  assert.equal(setupDone({}), false, "a machine that never ran claude");
  assert.equal(setupDone({ theme: "dark" }), false);
  assert.equal(setupDone({ hasCompletedOnboarding: true }), false);
  assert.equal(setupDone({ theme: "light", hasCompletedOnboarding: true }), true);
  assert.deepEqual(withSetupDone({}), { theme: "dark", hasCompletedOnboarding: true });
  const mine = { theme: "light-daltonized", projects: { "/a": { hasTrustDialogAccepted: true } } };
  assert.deepEqual(withSetupDone(mine), { ...mine, hasCompletedOnboarding: true });
  assert.equal(setupDone(withSetupDone(mine)), true);
});

test("an outside_roots refusal names the folder, so a client can offer to allow it", async () => {
  const t = await tree();
  const outside = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cvha-out-")));
  await assert.rejects(resolveInRoots(outside, [t.root]), (e) => e instanceof Refusal && e.code === "outside_roots" && e.path === outside);
});

test("spawnRuntime: unset leaves plain spawns on bin; a named runtime brings its binary, token file and config dir", () => {
  const runtimes = {
    "stock+mod": { bin: "/opt/claude/2.1.292", oauth_token_file: "/home/me/.config/claudiverse/token", config_dir: "relative/ignored" },
    patched: { bin: "/opt/claude/claude-rel" },
  };
  assert.equal(spawnRuntime({ runtimes }), null);
  assert.deepEqual(spawnRuntime({ runtimes, spawn_runtime: "stock+mod" }),
    { name: "stock+mod", bin: "/opt/claude/2.1.292", configDir: null, oauthTokenFile: "/home/me/.config/claudiverse/token", poolOnly: false, pooled: false });
  assert.equal(spawnRuntime({ runtimes: { pool: { bin: "/opt/claude/c", pool_only: true } }, spawn_runtime: "pool" }).poolOnly, true);
  assert.equal(spawnRuntime({ runtimes: { pool: { bin: "/opt/claude/c", pool_only: "yes" } }, spawn_runtime: "pool" }).poolOnly, false, "only a real true");
  assert.equal(spawnRuntime({ runtimes, spawn_runtime: "patched" }).bin, "/opt/claude/claude-rel");
});

test("spawnRuntime: a name that is not one of the machine's runtimes is a config error", () => {
  assert.throws(() => spawnRuntime({ runtimes: {}, spawn_runtime: "stock+mod" }), /not one of this machine's runtimes/);
  assert.throws(() => spawnRuntime({ runtimes: { x: { bin: "relative/claude" } }, spawn_runtime: "x" }), /not one of/);
});

test("spawnRuntime: spawn_pooled makes plain seats pooled; pool_only implies it; off by default", () => {
  const runtimes = { "stock+mod": { bin: "/opt/claude/2.1.292" }, pool: { bin: "/opt/claude/2.1.292", pool_only: true } };
  assert.equal(spawnRuntime({ runtimes, spawn_runtime: "stock+mod" }).pooled, false);
  assert.equal(spawnRuntime({ runtimes, spawn_runtime: "stock+mod", spawn_pooled: true }).pooled, true);
  assert.equal(spawnRuntime({ runtimes, spawn_runtime: "pool" }).pooled, true);
});
