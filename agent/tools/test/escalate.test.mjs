// node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import { escalateOnTask } from "../cv-escalate.mjs";

// A cv client that records each call; `fail` names the calls that throw, with what.
function fakeCv(fail = {}) {
  const calls = [];
  const call = (name, ret) => async (...args) => {
    calls.push([name, ...args]);
    if (fail[name]) throw new Error(fail[name]);
    return ret?.(...args);
  };
  return {
    calls,
    taskProgress: call("taskProgress", () => ({ ok: true })),
    notifyDirect: call("notifyDirect"),
    report: call("report"),
    forumPost: call("forumPost", () => ({ post: { id: 9001 } })),
    forumGet: call("forumGet", (id) => ({ post: { id } })),
  };
}

const run = async (cv, via, task) => {
  const lines = [];
  const where = await escalateOnTask({ cv, slot: "wc3-real", fleet: "wc3", channel: "wc3-real", via, log: (l) => lines.push(l) }, task, "30m with NO CPU consumed across its process tree, and no cv_task_done.\nmore");
  return { where, lines };
};

test("a task-table lane with no forum channel: on the task, and its author pinged; the 404 is said as 'no channel'", async () => {
  // MEASURED 2026-10-14: the alert went to POST /api/forum/posts → 404, and nobody heard.
  const cv = fakeCv({ forumPost: "POST /api/forum/posts → 404 Not Found" });
  const { where, lines } = await run(cv, "forum", { id: 2166, createdBy: "standalone-bob" });

  assert.deepEqual(where, ["task #2166", "a ping to standalone-bob, who wrote the task"]);
  const ping = cv.calls.find((c) => c[0] === "notifyDirect");
  assert.deepEqual(ping.slice(1, 3), ["wc3-real", "standalone-bob"]);
  assert.equal(ping[3], "RUNNER wc3-real needs a human — task #2166 (wc3/wc3-real): 30m with NO CPU consumed across its process tree, and no cv_task_done. — cv_task_show 2166");
  assert.ok(lines.includes("no forum channel #wc3-real: the escalation is not posted there."));
  assert.ok(!lines.some((l) => l.startsWith("⛔")), lines.join("\n"));
});

test("notify mode pings the lane's watchers too; a lane with a channel gets its post", async () => {
  const notify = await run(fakeCv(), "notify", { id: 7, createdBy: "lorem-orchestrator" });
  assert.deepEqual(notify.where, ["task #7", "a ping to lorem-orchestrator, who wrote the task", "ping tasks:wc3-real"]);
  const forum = await run(fakeCv(), "forum", { id: 7, createdBy: null });
  assert.deepEqual(forum.where, ["task #7", "forum post 9001"]);
});

test("a task the runner wrote itself pings nobody directly; nothing landing says so", async () => {
  const cv = fakeCv({ taskProgress: "500", forumPost: "socket hang up" });
  const { where, lines } = await run(cv, "forum", { id: 7, createdBy: "wc3-real" });
  assert.deepEqual(where, []);
  assert.ok(!cv.calls.some((c) => c[0] === "notifyDirect"));
  assert.ok(lines.some((l) => l.startsWith("⛔ escalation alert NOT POSTED to #wc3-real: socket hang up")));
  assert.equal(lines.at(-1), "⛔ escalation recorded NOWHERE — this log line is the only record.");
});
