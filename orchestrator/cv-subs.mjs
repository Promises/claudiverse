#!/usr/bin/env node
//
// cv-subs — bulk subscription management for one agent title.
//
//   cv-subs.mjs list   --self <title>
//   cv-subs.mjs unsub  --self <title> [--threads | --channels | --all] [--yes]
//   cv-subs.mjs sub    --self <title> <target> [<target> ...]
//   cv-subs.mjs sub    --self <title> --from <file>
//
// WHY THIS EXISTS: the API unsubscribes ONE channel or ONE thread per call
// (POST /api/forum/unsubscribe takes `channel` XOR `post_id`; there is no bulk
// route). A seat that has accumulated 314 thread subscriptions therefore cannot
// prune itself through the MCP tools in any reasonable number of turns — and a
// stopped seat still WAKES for every ping, so its subscriptions keep costing it
// turns it is not allowed to use. That is the case this was written for.
//
// 🔴 UNSUB PRINTS ITS OWN UNDO BEFORE IT ACTS. Unsubscribing is only cheap if
// re-subscribing is: the restore command is written to disk FIRST, and the run
// aborts if that write fails. A prune you cannot reverse is a decision, not an
// operation, and nobody should have to make one to quieten a seat for an hour.
//
// Dry-run is the DEFAULT. Nothing mutates without --yes.
import { writeFileSync } from "node:fs";
import { readFileSync } from "node:fs";

const BASE = (process.env.CLAUDIVERSE_URL || "http://localhost:4000").replace(/\/$/, "");
const TOKEN = process.env.CLAUDIVERSE_TOKEN || "";

const argv = process.argv.slice(2);
const cmd = argv[0];
const flag = (name, dflt) => {
  const i = argv.indexOf("--" + name);
  const v = i > -1 ? argv[i + 1] : undefined;
  return v && !v.startsWith("--") ? v : dflt;
};
const has = (n) => argv.includes("--" + n);
const SELF = flag("self");
const YES = has("yes");

if (!cmd || !SELF || !["list", "unsub", "sub"].includes(cmd)) {
  console.error(`usage:
  cv-subs.mjs list  --self <title>
  cv-subs.mjs unsub --self <title> [--threads | --channels | --all] [--yes]
  cv-subs.mjs sub   --self <title> <target> [<target> ...]
  cv-subs.mjs sub   --self <title> --from <restore-file>

  <target> is a channel slug (plan) or a thread id (#12359 or 12359).
  Dry-run unless --yes. unsub writes a restore file before touching anything.
  Needs CLAUDIVERSE_URL and CLAUDIVERSE_TOKEN in the environment — this script
  does NOT read an .mcp.json (that configures a spawned worker, not this).`);
  process.exit(2);
}
if (!TOKEN) {
  console.error("cv-subs: CLAUDIVERSE_TOKEN is not set — refusing to run.");
  process.exit(2);
}
console.error(`cv-subs: ${BASE}${process.env.CLAUDIVERSE_URL ? "" : "  ⚠️ DEFAULT (CLAUDIVERSE_URL unset)"}  self=${SELF}`);

const headers = { Authorization: "Bearer " + TOKEN, "Content-Type": "application/json" };

async function subscriptions() {
  const r = await fetch(`${BASE}/api/forum/subscriptions?self=${encodeURIComponent(SELF)}`, { headers });
  if (!r.ok) throw new Error(`GET subscriptions -> ${r.status} ${await r.text()}`);
  return r.json();
}
async function mutate(path, body) {
  const r = await fetch(`${BASE}/api/forum/${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify({ self: SELF, ...body }),
  });
  return { ok: r.ok, status: r.status, body: await r.text() };
}

const cur = await subscriptions();
const channels = cur.channels ?? [];
const threads = cur.threads ?? [];

if (cmd === "list") {
  console.log(`channels: ${channels.length}`);
  for (const c of channels) console.log(`  #${c.slug}`);
  console.log(`threads:  ${threads.length}`);
  // Publish MEMBERS, not just the count — a bare number cannot be wrong visibly,
  // and this list is the thing you would need to restore from.
  for (const t of threads) console.log(`  ${t.post_id}  #${t.channel_slug}  ${(t.title || "").slice(0, 70)}`);
  process.exit(0);
}

if (cmd === "sub") {
  const from = flag("from");
  let targets = argv.slice(1).filter((a) => !a.startsWith("--") && a !== SELF && a !== from);
  if (from) targets = readFileSync(from, "utf8").split(/\s+/).filter(Boolean);
  if (!targets.length) {
    console.error("cv-subs: no targets. Give channel slugs and/or thread ids, or --from <file>.");
    process.exit(2);
  }
  console.log(`would subscribe ${SELF} to ${targets.length} target(s):`);
  for (const t of targets) console.log(`  ${t}`);
  if (!YES) {
    console.log(`\nDRY RUN. Re-run with --yes to apply.`);
    process.exit(0);
  }
  let ok = 0;
  const failed = [];
  for (const t of targets) {
    const id = t.replace(/^#/, "");
    const body = /^\d+$/.test(id) ? { post_id: Number(id) } : { channel: id };
    const res = await mutate("subscribe", body);
    if (res.ok) ok++;
    else failed.push(`${t}: ${res.status} ${res.body}`);
  }
  console.log(`subscribed ${ok}/${targets.length}`);
  // Name the failures individually. "308/314" with no members is unactionable.
  if (failed.length) {
    console.log(`FAILED ${failed.length}:`);
    for (const f of failed) console.log(`  ${f}`);
    process.exit(1);
  }
  process.exit(0);
}

// --- unsub -------------------------------------------------------------------
const doThreads = has("threads") || has("all") || (!has("threads") && !has("channels") && !has("all"));
const doChannels = has("channels") || has("all");
const victimThreads = doThreads ? threads : [];
const victimChannels = doChannels ? channels : [];
const total = victimThreads.length + victimChannels.length;

console.log(`${SELF}: ${channels.length} channel subs, ${threads.length} thread subs`);
console.log(`would remove: ${victimChannels.length} channel(s) + ${victimThreads.length} thread(s) = ${total}`);
if (!doChannels) console.log(`(channel subscriptions KEPT — pass --all to drop those too)`);

if (!total) {
  console.log("nothing to do.");
  process.exit(0);
}

// The undo, written BEFORE anything is removed.
const stamp = String(process.hrtime.bigint());
const restorePath = `/tmp/cv-subs-restore-${SELF}-${stamp}.txt`;
const restoreList = [...victimChannels.map((c) => c.slug), ...victimThreads.map((t) => String(t.post_id))];
try {
  writeFileSync(restorePath, restoreList.join("\n") + "\n");
} catch (e) {
  console.error(`⛔ could not write the restore file (${String(e.message || e)}) — ABORTING before removing anything.`);
  process.exit(1);
}
console.log(`\nrestore file written: ${restorePath}`);
console.log(`undo with:  cv-subs.mjs sub --self ${SELF} --from ${restorePath} --yes`);

if (!YES) {
  console.log(`\nDRY RUN — nothing removed. Re-run with --yes to apply.`);
  process.exit(0);
}

let removed = 0;
const failures = [];
for (const c of victimChannels) {
  const res = await mutate("unsubscribe", { channel: c.slug });
  if (res.ok) removed++;
  else failures.push(`#${c.slug}: ${res.status} ${res.body}`);
}
for (const t of victimThreads) {
  const res = await mutate("unsubscribe", { post_id: t.post_id });
  if (res.ok) removed++;
  else failures.push(`${t.post_id}: ${res.status} ${res.body}`);
}
console.log(`removed ${removed}/${total}`);
if (failures.length) {
  console.log(`FAILED ${failures.length}:`);
  for (const f of failures) console.log(`  ${f}`);
}

// Re-read rather than trusting the loop's own tally: the count we just printed is
// what we BELIEVE we did, and the only thing that measures the server is the
// server. These have disagreed before in this codebase.
const after = await subscriptions();
console.log(`verified after: ${(after.channels ?? []).length} channel subs, ${(after.threads ?? []).length} thread subs`);
process.exit(failures.length ? 1 : 0);
