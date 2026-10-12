// node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { sessionRecords, matchSeat, runnerSlots, runnerWorker, sameStart, tmuxSession, tmuxNames } from "../lib/adopt.mjs";

const CEO = "d7dba841-a246-4186-9c74-da1d8534d610";
const STALE = "6d9b917b-1779-49d0-b95b-ad36f8a84f8b";
const OTHER = "c276c535-6eac-4ed3-b0bc-fd982d24fae4";
const DIR = "/Users/x/ipsum-api";

function configDir(records) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cvha-adopt-"));
  fs.mkdirSync(path.join(dir, "sessions"));
  for (const r of records) fs.writeFileSync(path.join(dir, "sessions", `${r.pid}.json`), JSON.stringify(r));
  return dir;
}

const rec = (pid, sessionId, extra = {}) => ({ pid, sessionId, cwd: DIR, procStart: "Sat Oct  3 08:18:54 2026", startedAt: pid, ...extra });

test("records are read from every config dir; junk and keys are skipped", () => {
  const a = configDir([rec(1, CEO)]);
  const b = configDir([rec(2, OTHER)]);
  fs.writeFileSync(path.join(a, "sessions", "3.json"), "{half");
  fs.writeFileSync(path.join(a, "sessions", "4.abc.key"), "x");
  fs.writeFileSync(path.join(a, "sessions", "5.json"), JSON.stringify({ pid: 5, sessionId: "not-a-uuid" }));
  const got = sessionRecords([a, b, a, null]);
  assert.deepEqual(got.map((r) => r.pid).sort(), [1, 2]);
  assert.equal(got.find((r) => r.pid === 1).configDir, a);
});

test("a conversation id match wins, case-insensitively", () => {
  const m = matchSeat([rec(1, CEO, { tmux: "elsewhere:@1.%1" })], { sessionIds: [CEO.toUpperCase()], title: "ipsum-admin", cwd: DIR });
  assert.equal(m.record.pid, 1);
  assert.equal(m.matchedBy, "session_id");
});

test("a stale row id falls back to tmux session name AND folder", () => {
  const records = [rec(1, CEO, { tmux: "ipsum-admin:@199.%199" })];
  const m = matchSeat(records, { sessionIds: [STALE], title: "ipsum-admin", cwd: DIR });
  assert.equal(m.record.pid, 1);
  assert.equal(m.matchedBy, "tmux_title");
  assert.ok(matchSeat(records, { sessionIds: [STALE], title: "ipsum-admin", cwd: "/elsewhere" }).none, "the folder must match too");
  assert.ok(matchSeat(records, { sessionIds: [STALE], title: "ipsum-orchestrator", cwd: DIR }).none, "the name must match too");
});

test("dead processes never match; two live ones are refused, not guessed", () => {
  const records = [rec(1, CEO), rec(2, CEO)];
  assert.equal(matchSeat(records, { sessionIds: [CEO] }, (pid) => pid === 2).record.pid, 2);
  assert.ok(matchSeat(records, { sessionIds: [CEO] }).several);
  assert.ok(matchSeat(records, { sessionIds: [CEO] }, () => false).none);
});

test("runner slots come from cv-runner command lines; their workers are <slot>-t<task>", () => {
  const ps = [
    "/usr/bin/node /x/cv-runner.mjs --bin /x/claude-rel --slot ipsum-w4 --channel ipsum-tasks",
    "/usr/bin/node /x/cv-mcp.mjs --slot not-a-runner",
    "zsh",
  ].join("\n");
  const slots = runnerSlots(ps);
  assert.deepEqual([...slots], ["ipsum-w4"]);
  assert.ok(runnerWorker("ipsum-w4-t30510", slots));
  assert.ok(!runnerWorker("ipsum-admin", slots));
  assert.ok(!runnerWorker("ipsum-w40-t1", slots), "ipsum-w40 is not ipsum-w4's worker");
});

test("start times compare whitespace-insensitively; a different time is a different process", () => {
  assert.ok(sameStart("Sat Oct  3 08:18:54 2026", "Sat Oct 3 08:18:54 2026   "));
  assert.ok(!sameStart("Sat Oct  3 08:18:54 2026", "Sat Oct  3 10:18:54 2026"));
  assert.ok(!sameStart(undefined, "Sat Oct  3 08:18:54 2026"));
});

test("tmux session name is the part before the colon", () => {
  assert.equal(tmuxSession("ipsum-admin:@199.%199"), "ipsum-admin");
  assert.equal(tmuxSession(null), null);
});

test("tmux sessions: listed names; none when no tmux server runs (a reboot); null when tmux could not say", () => {
  assert.deepEqual(tmuxNames({ code: 0, stdout: "ipsum-admin\nlorem-admin\n", stderr: "" }), ["ipsum-admin", "lorem-admin"]);
  assert.deepEqual(tmuxNames({ code: 1, stdout: "", stderr: "no server running on /private/tmp/tmux-501/default\n" }), []);
  assert.deepEqual(tmuxNames({ code: 1, stdout: "", stderr: "error connecting to /private/tmp/tmux-501/default (No such file or directory)\n" }), []);
  assert.equal(tmuxNames({ code: "ENOENT", stdout: "", stderr: "" }), null);
  assert.equal(tmuxNames({ code: 1, stdout: "", stderr: "error connecting to /private/tmp/tmux-501/default (Permission denied)\n" }), null);
});
