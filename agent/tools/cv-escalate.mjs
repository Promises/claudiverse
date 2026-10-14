// A runner's escalation for a task-table task: where it is recorded, and who
// hears of it. Split out of cv-runner so it can be tested with a fake client.
//
// MEASURED 2026-10-13/14: two wc3 workers sat 35 min at a dialog; each
// runner's escalation was recorded on its task, and its alert went to the
// forum channel named after the lane, which a task-table lane need not have:
// "POST /api/forum/posts → 404 Not Found". Nobody heard. So:
//   - always: an event on the task itself (cv_task_show renders it);
//   - the seat that wrote the task, pinged directly (it may watch nothing);
//   - --escalate-via notify: the lane's watchers (tasks:<lane>);
//   - --escalate-via forum: a post in the lane's channel, where one exists. A
//     404 there is "no such channel", said as that, not as a failure.

// The one line a ping carries.
export function escalationLine(slot, fleet, channel, task, body) {
  const first = String(body).split("\n")[0];
  const cut = first.length > 240 ? first.slice(0, 239) + "…" : first;
  return `RUNNER ${slot} needs a human — task #${task.id} (${fleet}/${channel}): ${cut} — cv_task_show ${task.id}`;
}

// Record and announce `body` for `task` ({id, createdBy}). `ctx`: {cv, slot,
// fleet, channel, via, log}. Returns where it landed (strings; empty: nowhere).
export async function escalateOnTask(ctx, task, body) {
  const { cv, slot, fleet, channel, via, log } = ctx;
  const where = [];
  const line = escalationLine(slot, fleet, channel, task, body);

  try {
    const ev = await cv.taskProgress(task.id, { worker: slot, detail: body });
    if (ev?._failed) throw new Error(`${ev._status ?? ""} ${ev.error ?? ""}`.trim());
    where.push(`task #${task.id}`);
  } catch (e) {
    log(`⛔ escalation NOT recorded on task #${task.id}: ${String(e.message || e)}.`);
  }

  if (task.createdBy && task.createdBy !== slot) {
    try {
      await cv.notifyDirect(slot, task.createdBy, line);
      where.push(`a ping to ${task.createdBy}, who wrote the task`);
    } catch (e) {
      log(`⛔ escalation ping to ${task.createdBy} (who wrote #${task.id}) FAILED: ${String(e.message || e)}.`);
    }
  }

  if (via === "notify") {
    try {
      await cv.report(`tasks:${channel}`, line);
      where.push(`ping tasks:${channel}`);
    } catch (e) {
      log(`⛔ escalation ping to tasks:${channel} FAILED: ${String(e.message || e)}.`);
    }
  } else {
    try {
      const r = await cv.forumPost(slot, channel, `${body}\n\nTask #${task.id} in ${fleet}/${channel} — read it with \`cv_task_show ${task.id}\`, not the forum post of that number.`, undefined, {
        title: `RUNNER: needs a human — task #${task.id}`,
      });
      const postId = r?.post?.id ?? null;
      if (postId !== null && (await cv.forumGet(postId, false))?.post?.id === postId) where.push(`forum post ${postId}`);
    } catch (e) {
      const msg = String(e.message || e);
      // A top-level post's only 404 is the channel: a task-table lane need not have one.
      if (/\b404\b/.test(msg)) log(`no forum channel #${channel}: the escalation is not posted there.`);
      else log(`⛔ escalation alert NOT POSTED to #${channel}: ${msg}.`);
    }
  }

  log(where.length ? `escalation recorded on ${where.join(", ")}` : `⛔ escalation recorded NOWHERE — this log line is the only record.`);
  return where;
}
