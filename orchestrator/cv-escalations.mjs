#!/usr/bin/env node
//
// cv-escalations.mjs — list every task carrying an unresolved RUNNER escalation.
//
// WHY THIS EXISTS
//
// When a worker stalls, cv-runner posts "RUNNER: needs a human" as a REPLY on the
// task and verifies it landed. That part works. What does not work is DISCOVERY:
// the reply is visible only to someone already reading that thread, and nobody is
// subscribed to "escalations" as a category.
//
// Measured 2026-08-22: ipsum-w8-t14180 sat at an interactive permission prompt for
// ~45 minutes. The runner escalated correctly at the 30-minute mark and even
// named the remedy ("inspect with: tmux attach -t ipsum-w8-t14180"). A watcher spent
// that time polling cv_status and cv_tail instead — BOTH OF WHICH REPORT A WORKER
// WAITING ON A HUMAN AS "busy", indistinguishable from one that is working. The
// signal existed and was correct; only the reading of it failed.
//
// ⛔ WHY NOT JUST MIRROR ESCALATIONS INTO #fleet-control
//
// Because that would quietly break the fleet brake. The halt check reads a
// WINDOWED view of #fleet-control (cv.HALT_WINDOW = 50, the server's own max), and
// a halt that falls off the end of that window FAILS OPEN — runners resume
// claiming with a live HALT sitting unarchived. Escalation traffic in that channel
// would consume window slots and make eviction likelier exactly when the fleet is
// unhealthy and escalating most. The brake's channel stays low-volume ON PURPOSE.
//
// Usage:
//   cv-escalations.mjs [channel ...]     (default: the known task channels)
//
// Env: CLAUDIVERSE_URL, CLAUDIVERSE_TOKEN (same as every other orchestrator tool).

import * as cv from "./cv-core.mjs";

const DEFAULT_CHANNELS = ["ipsum-tasks", "ipsum-tasks-deep", "lorem-tasks", "lorem-tasks-deep"];
const channels = process.argv.slice(2).length ? process.argv.slice(2) : DEFAULT_CHANNELS;

// A runner titles every escalation this way. Matching the TITLE rather than the
// body keeps this independent of the wording of `why`, which varies per cause
// (stuck timeout vs. worker process gone).
const isEscalation = (r) => (r.title || "").startsWith("RUNNER:");

const age = (iso) => {
  if (!iso) return "?";
  const mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 60) return `${mins}m`;
  const h = Math.floor(mins / 60);
  return h < 24 ? `${h}h${mins % 60}m` : `${Math.floor(h / 24)}d${h % 24}h`;
};

let found = 0;
let scanned = 0;
const unreadable = [];

for (const channel of channels) {
  let posts;
  try {
    // Only live work can carry a live escalation. A `done` task whose escalation
    // was resolved is not news; including it would bury the ones that matter.
    const r = await cv.forumRead(channel, { status: "active", limit: 30, compact: true });
    posts = r?.posts ?? [];
  } catch (e) {
    // ⚠️ A channel we could not read is NOT a channel with no escalations. Report
    // it separately — collapsing the two would turn an outage into a clean bill
    // of health, which is the exact failure this tool exists to prevent.
    unreadable.push(`${channel}: ${String(e.message || e)}`);
    continue;
  }

  for (const p of posts) {
    // compact view carries reply counts; only pay for a thread fetch when there
    // could be something in it.
    const replies = p.reply_count ?? p.replies_count ?? 1;
    if (!replies) continue;
    scanned++;
    let thread;
    try {
      thread = (await cv.forumGet(p.id, true))?.replies ?? [];
    } catch (e) {
      unreadable.push(`${channel}/#${p.id}: ${String(e.message || e)}`);
      continue;
    }
    const esc = thread.filter(isEscalation);
    if (!esc.length) continue;
    found++;
    const last = esc[esc.length - 1];
    console.log(`\n🔴 #${p.id}  [${channel}]  owner=${p.owner || "-"}  escalated ${age(last.inserted_at || last.updated_at)} ago`);
    console.log(`   task: ${(p.title || "").slice(0, 100)}`);
    console.log(`   ${(last.body || "").replace(/\s+/g, " ").slice(0, 220)}`);
  }
}

console.log(
  `\n── scanned ${scanned} active task(s) across ${channels.length} channel(s) → ${found} with escalations`
);

// Silence is not success. If nothing could be read, say so loudly rather than
// printing a reassuring zero.
if (unreadable.length) {
  console.log(`\n⚠️  ${unreadable.length} target(s) COULD NOT BE READ — this is not "no escalations":`);
  for (const u of unreadable) console.log(`   ${u}`);
  process.exit(1);
}
if (!found) console.log("✅ no open escalations");
