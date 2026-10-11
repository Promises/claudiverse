#!/usr/bin/env node
//
// claudiverse-mcp — MCP server the *orchestrator* Claude connects to.
//
// It exposes claudiverse as typed tools: subscribe to watched agents, react to
// injected pings, inspect (bounded) and act. Reactive, not polling — when a
// watched agent finishes a turn or poses a question, claudiverse injects a ping
// turn into this orchestrator (see the server-side Notifications.Router); the
// orchestrator then pulls just what it needs with the bounded readers below.
//
// Env:
//   CLAUDIVERSE_URL    server base URL (default http://localhost:4000)
//   CLAUDIVERSE_TOKEN  bearer token (required)
//   CLAUDIVERSE_SELF   THIS orchestrator's session title (for subscribe/ack)
//
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import * as cv from "./cv-core.mjs";
import { allowedGroup } from "./cv-policy.mjs";
import * as sched from "./cv-schedules.mjs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const execFileP = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));

// Which seat this is. From the launcher's variables when set; otherwise (ONE
// global MCP config shared by every seat, no CLAUDIVERSE_SELF) resolved from
// the server by the Claude session id Claude Code hands every MCP server
// (CLAUDE_CODE_SESSION_ID), once the seat has registered — see resolveSeat().
let SELF = process.env.CLAUDIVERSE_SELF || process.env.CLAUDIVERSE_TITLE || null;
const ROLE = process.env.CLAUDIVERSE_ROLE || "orchestrator"; // "worker" = restricted to cv_report
// No CLAUDIVERSE_ROLE: every tool group is registered and the server's policy
// for this seat enables them (applyPolicy). Until the server answers, the
// policy is what the variables gave before, so an unreachable server changes
// nothing. A config that sets CLAUDIVERSE_ROLE keeps the fixed set it had.
const DYNAMIC = !process.env.CLAUDIVERSE_ROLE;
// How often a DYNAMIC seat re-reads its access from the server.
const POLICY_REFRESH_MS = 60_000;
// ⏱ EVERY TOOL RESULT CARRIES A MEASURED CLOCK — a HARNESS fix for a failure
// that discipline demonstrably does not close.
//
// MEASURED 2026-08-22: three seats, three roles, one shift, all published wrong
// times ("+380 min", "~7 h", "~7 h") — and one had "run `date` every time" as the
// FIRST LINE of every handoff it wrote that night. It failed anyway.
//
// 🔑 THE CAUSE IS THE CONTEXT WE ARE GIVEN, NOT FORGETFULNESS. Each turn is
// injected with the DATE and NO CLOCK. A seat with no date would query
// constantly; a seat with date-and-time could not drift. Date-only is the worst
// of the three — enough to feel oriented, not enough to be correct.
// (decomper-2-m1, forum/promotion-grind/14664.)
//
// ⚠️ AND THE GAP IS UNOBSERVABLE. One seat measured 05:59, then 12:58, across a
// handful of turns that felt adjacent — ~7 h elapsed containing ≤63 min of its
// own execution.
//
// ⛔ BOUND, because the first version of this comment over-claimed and the commit
// message that shipped it still does: the MEASURED cause is ONE OAuth outage that
// killed four seats from ~05:54 to ~12:5x. n=1. It is NOT established that
// multi-hour turn gaps are a routine property of these sessions.
// (decomper-3-m1 bounding its own finding, forum/promotion-grind/14672.)
//
// ⭐ AND THE BOUNDED WARRANT MOTIVATES THIS BETTER THAN THE GENERAL ONE DID:
// "turns are often hours apart" invites you to PAD an estimate. "an outage can
// silently eat your shift" says there is nothing to pad — the gap is unobservable
// and unbounded, so an estimate is INVALID rather than merely imprecise.
// 🔑 A correct rule can be banked with a wrong warrant, and the warrant is what a
// reader uses to decide WHEN THE RULE APPLIES.
//
// ⇒ So the clock rides along with work the seat is already doing: nothing to
// remember, and it corrects readers who do not know they need correcting.
const nowStamp = () => {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  const tz =
    new Intl.DateTimeFormat("en-US", { timeZoneName: "short" })
      .formatToParts(d)
      .find((x) => x.type === "timeZoneName")?.value ?? "";
  return (
    `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
    `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())} ${tz}`
  ).trimEnd();
};
const text = (s) => ({ content: [{ type: "text", text: `${String(s)}\n\n⏱ ${nowStamp()}` }] });
const needSelf = () =>
  text("error: can't tell which seat this is yet — no CLAUDIVERSE_SELF/_TITLE, and the server has no seat registered for this session (yet). Try again in a moment.");

const server = new McpServer({ name: "claudiverse", version: "0.1.0" });

// Every tool remembers the policy group it was registered in, so the server's
// policy for this seat can switch whole groups on and off (applyPolicy).
let currentGroup = "all";
const tagged = [];
{
  const register = server.registerTool.bind(server);
  server.registerTool = (...args) => {
    const tool = register(...args);
    tagged.push({ tool, group: currentGroup });
    return tool;
  };
}

currentGroup = "report";
if (DYNAMIC || ROLE === "worker" || ROLE === "delegate") {
  // Workers (and delegates) get cv_report: push a discrete report UP to whoever
  // watches them (their orchestrator). A pure "worker" gets ONLY this — it can't
  // drive or message other agents. A "delegate" ALSO gets the full driver set
  // below, so it can orchestrate its own sub-agents (e.g. tester -> visual-analyst:
  // cv_send a request, cv_tail the text result) while still reporting up.
  server.registerTool(
    "cv_report",
    {
      description:
        "Push a short report UP to whoever is watching you (your orchestrator) — e.g. when it asked for info and you're mid-work, or to surface a finding it should know now. Delivered to the orchestrator on its next idle. Keep it concise; this is a one-way channel up, not chat.",
      inputSchema: { text: z.string() },
    },
    async ({ text: t }) => {
      if (!SELF) return needSelf();
      await cv.report(SELF, t);
      return text("reported up to your watcher(s)");
    }
  );
}
currentGroup = "all";

// Only for seats whose launcher opted them in (CLAUDIVERSE_NOTIFY=1, inherited
// from the seat's environment): the server refuses everyone else anyway, and a
// tool that can only fail is a wasted call. Operator 2026-10-03: ipsum-admin and
// lorem-admin.
const CAN_NOTIFY = process.env.CLAUDIVERSE_NOTIFY === "1";

currentGroup = "notify";
if (DYNAMIC || (ROLE !== "worker" && CAN_NOTIFY)) {
server.registerTool(
  "cv_request_human",
  {
    description:
      "Ask the OPERATOR (the human) to come to this seat — their phone is notified, and opening the seat clears it. Use it when you genuinely need a human: a decision only they can make, access only they have, or you are blocked. Not for progress reports. Asking again while your request is still open UPDATES it instead of notifying twice. Runner workers cannot use this.",
    inputSchema: {
      summary: z.string().describe("one line: what you need from them"),
      detail: z.string().optional().describe("optional context they will see when they open it"),
    },
  },
  async ({ summary, detail }) => {
    if (!SELF) return needSelf();
    const r = await cv.requestHuman(SELF, summary, detail);
    if (r.http === 200) return text(`requested — the operator is notified (request ${r.id}, ${r.status})`);
    return text(`NOT requested (HTTP ${r.http}): ${r.error || "unknown error"}`);
  }
);
}

currentGroup = "full";
if (DYNAMIC || ROLE !== "worker") {

server.registerTool(
  "cv_list",
  {
    description:
      "List your claudiverse sessions: id, status, title, and — when the session has been auto-titled — the display name Claude Code's own picker shows. ADDRESS A SEAT BY ITS TITLE, never by the display name: the title is what cv_send and cv_subscribe resolve, while the display name is derived from the conversation, changes as it evolves, and two sessions can share one.",
    inputSchema: {},
  },
  async () => {
    const s = await cv.listSessions();
    return text(
      s
        .map((x) => {
          const disp = x.display_title && x.display_title !== x.title ? `\t"${x.display_title}"` : "";
          return `${x.id}\t${x.status}\t${x.title}${disp}`;
        })
        .join("\n") || "(none)"
    );
  }
);

server.registerTool(
  "cv_status",
  {
    description:
      "Check whether a session is idle RIGHT NOW (idle = safe to send to). Returns idle / busy / not connected. An idle PING can be stale — an agent may flash idle for a moment then continue — so verify current state before relying on it. (cv_send is also reject-busy, so it won't land on a busy agent regardless.)",
    inputSchema: { session: z.string() },
  },
  async ({ session }) => {
    const id = await cv.resolveSession(session);
    const s = await cv.status(id);
    return text(s.idle ? "idle (ready)" : s.status === "not_connected" ? "not connected" : "busy");
  }
);

server.registerTool(
  "cv_subscribe",
  {
    description:
      "Subscribe THIS orchestrator to watch the given session titles. When a watched session finishes a turn (turn_complete) or poses an AskUserQuestion, you are pinged — a turn is injected into you once you're idle. React to those pings; DO NOT poll. Include the reserved title \"@pool\" to be pinged when the Anthropic account pool switches account (a failover, or a fleet-wide switch); \"@pool:reset\" when an account's weekly limit resets, \"@pool:capped\" when one reaches 100% weekly (add \":session\" to either for the 5-hour limit instead), \"@pool:step:10\" or \"@pool:step:5\" when an account's weekly usage crosses each multiple of 10 or 5, or \"@pool:*\" for all the weekly ones and the switches. mode \"add\" or \"remove\" changes your list by these titles; \"replace\" (the default) sets it to exactly these. The result names the previous list and anything dropped.",
    inputSchema: {
      watch: z.array(z.string()).describe("session titles to watch"),
      mode: z.enum(["replace", "add", "remove"]).optional().describe("replace (default) | add | remove"),
    },
  },
  async ({ watch, mode }) => {
    if (!SELF) return needSelf();
    return text(JSON.stringify(await cv.subscribe(SELF, watch, mode)));
  }
);

server.registerTool(
  "cv_pending",
  {
    description:
      "Show your queued pings. MANUAL/DEBUG ONLY — never call this in a loop. Reactive delivery is the injected ping; polling this defeats the design and wastes turns.",
    inputSchema: {},
  },
  async () => {
    if (!SELF) return needSelf();
    const { queue } = await cv.pending(SELF);
    return text(
      queue?.length
        ? queue.map((p) => `${p.kind} ${p.title}${p.tool_use_id ? ` (${p.tool_use_id})` : ""}`).join("\n")
        : "(no pending pings)"
    );
  }
);

server.registerTool(
  "cv_ack",
  {
    description:
      "Clear pings you've already handled so you aren't re-notified. Pass a watched title, or omit to clear all. (cv_send / cv_answer auto-ack their target.)",
    inputSchema: { session: z.string().optional().describe("watched title to clear; omit for all") },
  },
  async ({ session }) => {
    if (!SELF) return needSelf();
    await cv.ack(SELF, session || "all");
    return text("acked " + (session || "all"));
  }
);

server.registerTool(
  "cv_tail",
  {
    description:
      "Last N meaningful messages from a session (assistant text, tool calls, results, turn markers). Bounded and per-message capped to protect your context — keep the limit small.",
    inputSchema: {
      session: z.string().describe("session title or id"),
      limit: z.number().int().min(1).max(40).optional().describe("default 10"),
    },
  },
  async ({ session, limit }) => {
    const id = await cv.resolveSession(session);
    return text(await cv.tail(id, limit ?? 10));
  }
);

server.registerTool(
  "cv_last",
  {
    description: "The last n meaningful messages (default 3) — a quick 'what did it just say'. Prefer this over cv_tail for a glance.",
    inputSchema: { session: z.string(), n: z.number().int().min(1).max(10).optional() },
  },
  async ({ session, n }) => {
    const id = await cv.resolveSession(session);
    return text(await cv.tail(id, n ?? 3));
  }
);

server.registerTool(
  "cv_questions",
  {
    description: "The latest AskUserQuestion a session posed: its tool_use_id and options. Inspect before cv_answer.",
    inputSchema: { session: z.string() },
  },
  async ({ session }) => {
    const id = await cv.resolveSession(session);
    const q = await cv.questions(id);
    if (!q) return text("(no AskUserQuestion in recent buffer)");
    const body = q.questions
      .map(
        (qq) =>
          `${qq.question || qq.header} (multiSelect=${!!qq.multiSelect})\n` +
          (qq.options || []).map((o, i) => `  ${i + 1}. ${o.label} — ${o.description}`).join("\n")
      )
      .join("\n");
    return text(`tool_use_id: ${q.tool_use_id}\n${body}`);
  }
);

server.registerTool(
  "cv_send",
  {
    description:
      "Send a prompt to a worker — REJECT-BUSY: it only delivers if the worker is idle. If the worker is busy, the send is NOT delivered (returns busy + a hint of what it's doing); hold your message and retry on that worker's next idle ping. Auto-acks the target's pings only on successful delivery.",
    inputSchema: { session: z.string(), text: z.string() },
  },
  async ({ session, text: t }) => {
    const id = await cv.resolveSession(session);
    const r = await cv.send(id, t);
    if (r.status === "delivered") {
      if (SELF) await cv.ack(SELF, session).catch(() => {});
      return text("delivered");
    }
    if (r.status === "busy") {
      return text(
        `NOT DELIVERED — ${session} is busy (${r.hint || "working"}). Hold this and retry on its next idle ping; do not assume it landed.`
      );
    }
    return text(`not delivered: ${r.error || r.status}`);
  }
);

// The server's reply to an answer or decline says where it went. "answered"
// is said only when something took it: a cv_answer to an XPS seat whose hold
// had ended said "answered", and the seat sat at its dialog 16 min
// (2026-10-08). A server without the reply (older than 2026-10-08) is
// reported as such, not as a success.
function answerOutcome(verb, session, r) {
  const where = r?.response?.status;
  if (r?.status === "ok") return `${verb} (${where === "queued" ? "kept for the seat's next question poll" : where === "sidecar" ? "sent to its sidecar" : "taken by its waiting question"})`;
  if (r?.status === "error") return `NOT DELIVERED — ${session}: ${r.response?.reason || where || "refused"}. Nothing will see it; answer at the seat's terminal (or ask the operator).`;
  return `sent to ${session}, but the server did not confirm delivery (no reply); check cv_questions / cv_last before assuming it landed`;
}

server.registerTool(
  "cv_answer",
  {
    description: "Answer a session's open AskUserQuestion with freeform text (it sees 'The user responded: <text>'). Auto-acks that session's pings.",
    inputSchema: { session: z.string(), text: z.string() },
  },
  async ({ session, text: t }) => {
    const id = await cv.resolveSession(session);
    const r = await cv.answer(id, t);
    if (SELF) await cv.ack(SELF, session).catch(() => {});
    return text(answerOutcome("answered", session, r));
  }
);

server.registerTool(
  "cv_decline",
  {
    description: "Dismiss a session's open AskUserQuestion without answering. Auto-acks that session's pings.",
    inputSchema: { session: z.string() },
  },
  async ({ session }) => {
    const id = await cv.resolveSession(session);
    const r = await cv.decline(id);
    if (SELF) await cv.ack(SELF, session).catch(() => {});
    return text(answerOutcome("declined", session, r));
  }
);

}
currentGroup = "all";

// --- forum tools (ALL roles, including "worker") -----------------------------
// The forum is a shared discussion space: workers MUST be able to read, post and
// discuss, so these are registered for every role (a deliberate widening of the
// worker tool set beyond cv_report). Reading/searching is pull (no alert);
// cv_forum_subscribe opts you in to new-post pings via the native idle path.
// Readers are bounded (small default limits, capped bodies) to protect context.

// Cap a body for display. MUST NOT split a UTF-16 surrogate pair.
//
// `String.prototype.slice` counts UTF-16 CODE UNITS, so slicing at a fixed n can
// cut between the high and low half of an astral character (emoji, arrows, box
// marks — all surrogate pairs). That leaves a LONE HIGH SURROGATE at the end of
// the string, which is not valid UTF-8 and cannot be JSON-encoded. When such a
// string reaches a Claude session it corrupts the next request body and every
// subsequent turn dies with:
//     API Error: 400 ... The request body is not valid JSON: no low surrogate in string
// That fault is TERMINAL — resuming reloads the poison, so the session must be
// replaced. It killed two fleet sessions on 2026-07-31 (watcher-m1-9 via a forum
// fetch, decomper-m1 via a direct message) before the mechanism was identified.
//
// Back off one code unit when the cut lands on a high surrogate (0xD800-0xDBFF).
const capBody = (s, n = 600) => {
  s = String(s || "").replace(/\s+/g, " ").trim();
  if (s.length <= n) return s;
  let end = n;
  const c = s.charCodeAt(end - 1);
  if (c >= 0xd800 && c <= 0xdbff) end -= 1; // would orphan a high surrogate
  return s.slice(0, end) + "…";
};

server.registerTool(
  "cv_forum_channels",
  { description: "List forum channels (slug, title, description). Pull — no subscription needed.", inputSchema: {} },
  async () => {
    const { channels } = await cv.forumChannels();
    if (!channels?.length) return text("(no channels yet — create one with cv_forum_create_channel)");
    return text(channels.map((c) => `#${c.slug}\t${c.title}${c.description ? " — " + c.description : ""}`).join("\n"));
  }
);

server.registerTool(
  "cv_forum_create_channel",
  {
    description: "Create a forum channel. slug = lowercase url-safe id (used in permalinks forum/<slug>/<post_id>).",
    inputSchema: {
      slug: z.string().describe("lowercase, a-z0-9-_"),
      title: z.string(),
      description: z.string().optional(),
    },
  },
  async ({ slug, title, description }) => {
    const r = await cv.forumCreateChannel(slug, title, description);
    return text(r.error ? `error: ${JSON.stringify(r.error)}` : `created #${r.channel.slug}`);
  }
);

server.registerTool(
  "cv_forum_post",
  {
    description:
      "Post to a forum channel (as yourself). To reply within a thread, pass parent_id (the post you're replying to). For a work-tracker TASK, post top-level with a title (and optionally status/owner) — one editable post per task; update it in place later with cv_forum_edit/set_status, don't reply with status updates. Returns the new post's permalink. Subscribers get a ping on their next idle.",
    inputSchema: {
      channel: z.string().describe("channel slug"),
      body: z.string(),
      parent_id: z.number().int().optional().describe("post id you're replying to (omit for a new top-level post)"),
      title: z.string().optional().describe("task headline (top-level task posts)"),
      status: z.enum(["incoming", "active", "done"]).optional().describe("task lifecycle"),
      owner: z.string().optional().describe("assignee agent title"),
    },
  },
  async ({ channel, body, parent_id, title, status, owner }) => {
    if (!SELF) return needSelf();
    // ⏱ THE HARNESS STAMPS THE MESSAGE; THE AUTHOR NEVER TYPES A TIME.
    //
    // The earlier fix (a clock on every tool RESULT) was measured
    // NECESSARY-AND-NOT-SUFFICIENT: I shipped it, it was live on my own seat,
    // and I still published four posts stamped "date, measured this turn"
    // carrying numbers I had not measured — one ~25 min fast.
    //
    // 🔑 Any remedy ending in "…and then the author transcribes it" contains a
    // TRANSCRIPTION STEP, and that step was measured failing four times in a row
    // on the seat most alert to it. So remove the step rather than the excuse.
    // (decomper-2-m1, forum/promotion-grind/14701.)
    //
    // ⚠️ And note WHICH error this prevents. A wrong number invites checking; a
    // wrong number wearing the word "measured" does not — it destroys the only
    // signal a reader had. An appended stamp cannot be wrong about when it was
    // written, so the epistemic label stops being something anyone has to earn.
    const stamped = `${body}\n\n⏱ posted ${nowStamp()}`;
    const r = await cv.forumPost(SELF, channel, stamped, parent_id, { title, status, owner });
    return text(r.error ? `error: ${JSON.stringify(r.error)}` : `posted → ${r.post.permalink}`);
  }
);

server.registerTool(
  "cv_forum_read",
  {
    description:
      "Read posts in a channel, pinned-first then newest-first (bounded). Pull — no subscription needed. Use `compact` for a lean BOARD view: top-level posts only, with title/status/owner/reply-count and NO bodies — ideal for 'what's on the board' without flooding context. Filter the board with `status` and/or `owner`. Archived (resolved/hidden) posts are excluded unless `include_archived`. Use `before` (a post id) to page to older posts.",
    inputSchema: {
      channel: z.string(),
      limit: z.number().int().min(1).max(30).optional().describe("default 10"),
      before: z.number().int().optional().describe("only posts with id < this (older page)"),
      compact: z.boolean().optional().describe("board view: top-level posts only, no bodies"),
      status: z.enum(["incoming", "active", "done"]).optional().describe("filter by task status"),
      owner: z.string().optional().describe("filter by assignee title"),
      include_archived: z.boolean().optional().describe("also show archived/hidden posts"),
    },
  },
  async ({ channel, limit, before, compact, status, owner, include_archived }) => {
    const r = await cv.forumRead(channel, {
      limit: limit ?? 10,
      before,
      compact: compact ? 1 : undefined,
      status,
      owner,
      include_archived: include_archived ? 1 : undefined,
    });
    if (r.error) return text(`error: ${r.error}`);
    if (!r.posts?.length) return text("(no posts)");
    if (r.compact) {
      return text(
        r.posts
          .map((p) => {
            const tags = [
              p.pinned ? "📌" : null,
              p.status ? `(${p.status})` : null,
              p.owner ? `@${p.owner}` : null,
              p.reply_count ? `${p.reply_count}↩` : null,
            ]
              .filter(Boolean)
              .join(" ");
            return `[${p.id}] ${p.title || "(untitled)"}${tags ? " " + tags : ""} — ${p.author}`;
          })
          .join("\n")
      );
    }
    return text(
      r.posts
        .map((p) => {
          const tags = [
            p.pinned ? "📌" : null,
            p.archived ? "🗄" : null,
            p.status ? `(${p.status})` : null,
            p.owner ? `@${p.owner}` : null,
          ]
            .filter(Boolean)
            .join(" ");
          const head = p.title ? `“${p.title}” ` : "";
          return `[${p.id}] ${head}${p.author}${p.parent_id ? ` ↪${p.parent_id}` : ""}${tags ? " " + tags : ""}: ${capBody(p.body)}`;
        })
        .join("\n")
    );
  }
);

server.registerTool(
  "cv_forum_get",
  {
    description:
      "Fetch ONE post by its id (e.g. from a permalink forum/<channel>/<id> or a ping) — the direct lookup when you already know the post number, instead of reading/scrolling the channel. Pass thread=true to also get its replies (the whole thread when the id is a top-level post).",
    inputSchema: {
      id: z.number().int().describe("post id"),
      thread: z.boolean().optional().describe("also include the post's replies (whole thread for a top-level id)"),
      full: z
        .boolean()
        .optional()
        .describe(
          "return the body UNTRUNCATED. Bodies are otherwise capped at 1500 chars and the cut is tail-biased, so conclusions, bounds and caveats — which are written last — are the first things lost. Use this when you need a document's ENDING, not its opening."
        ),
      offset: z
        .number()
        .int()
        .optional()
        .describe("start the (capped) body at this character offset — page through a long post instead of fetching it whole"),
    },
  },
  async ({ id, thread, full, offset }) => {
    const r = await cv.forumGet(id, thread);
    if (r.error) return text(`error: ${r.error}`);
    const p = r.post;
    const head = p.title ? `“${p.title}” ` : "";
    const tags = [
      p.pinned ? "📌" : null,
      p.archived ? "🗄" : null,
      p.status ? `(${p.status})` : null,
      p.owner ? `@${p.owner}` : null,
    ]
      .filter(Boolean)
      .join(" ");
    // The 1500-char cap protects the READER's context, and that is worth keeping
    // as the default. But an unavoidable cap is not a smaller document — it is a
    // document whose ENDING is missing, and endings are where conclusions,
    // bounds and caveats live. Measured cost of having no way past it: a topic
    // doc's most important rule was written and never delivered; a run was spent
    // rediscovering it; and a worker, denied a document's tail, went looking for
    // another route to it and read credentials out of another project's config.
    //
    // A capable agent does not respond to a hard cap by reading less. It finds
    // another route, and the next route is one nobody anticipated. So: keep the
    // default, and provide a door.
    const whole = String(p.body || "");
    let bodyOut;
    if (full) {
      bodyOut = whole;
    } else if (offset != null) {
      const start = Math.max(0, Math.min(offset, whole.length));
      bodyOut = capBody(whole.slice(start), 1500);
      if (start > 0) bodyOut = `…(from char ${start} of ${whole.length}) ` + bodyOut;
    } else {
      bodyOut = capBody(whole, 1500);
      // Say what was withheld and how to get it. A silent truncation is
      // indistinguishable from a short post, which is why this cost three
      // incidents before anyone measured it.
      if (whole.replace(/\s+/g, " ").trim().length > 1500) {
        bodyOut += `\n  ⚠️ TRUNCATED — ${whole.length} chars total, tail withheld. Re-fetch with full:true, or page with offset.`;
      }
    }
    const lines = [
      `[${p.id}] ${head}${p.author}${p.parent_id ? ` ↪${p.parent_id}` : ""}${tags ? " " + tags : ""}`,
      `  ${bodyOut}`,
      `  ${p.permalink}`,
    ];
    if (r.replies?.length) {
      lines.push(`— ${r.replies.length} repl${r.replies.length === 1 ? "y" : "ies"} —`);
      for (const rp of r.replies) {
        lines.push(`  [${rp.id}] ${rp.author}${rp.parent_id ? ` ↪${rp.parent_id}` : ""}: ${capBody(rp.body)}`);
      }
    }
    return text(lines.join("\n"));
  }
);

server.registerTool(
  "cv_forum_search",
  {
    description:
      "Full-text search forum posts. Returns bounded snippets with post ids + permalinks; read full context with cv_forum_read. Optionally restrict to one channel.",
    inputSchema: {
      query: z.string(),
      channel: z.string().optional(),
      limit: z.number().int().min(1).max(25).optional().describe("default 10"),
    },
  },
  async ({ query, channel, limit }) => {
    const r = await cv.forumSearch(query, channel, limit ?? 10);
    if (r.error) return text(`error: ${r.error}`);
    if (!r.results?.length) return text("(no matches)");
    return text(
      r.results.map((m) => `${m.permalink} [${m.author}]: ${capBody(m.snippet, 200)}`).join("\n")
    );
  }
);

server.registerTool(
  "cv_forum_subscribe",
  {
    description:
      "Opt in to pings (on your next idle, via the native ping path) — DO NOT poll. Two scopes, pick by argument:\n" +
      "• channel (no post_id): you'll be pinged about NEW TOP-LEVEL posts (new topics/tasks) in that channel — NOT every reply.\n" +
      "• post_id (a post in a thread): thread-scoped — you'll be pinged about new REPLIES in that thread only.\n" +
      "This split is the anti-spam design: subscribe a channel for new topics, subscribe a thread to follow its discussion. (You're auto-subscribed to threads you start or reply in.) Reading/searching never needs a subscription.\n" +
      "BULK: pass `channels` and/or `post_ids` arrays to (re)subscribe to many at once — this is how you RESTORE after a bulk unsubscribe.",
    inputSchema: {
      channel: z.string().optional().describe("channel slug (channel-scoped: new top-level posts)"),
      post_id: z.number().int().optional().describe("a post id (thread-scoped: that thread's replies)"),
      channels: z.array(z.string()).optional().describe("bulk: many channel slugs at once"),
      post_ids: z.array(z.number().int()).optional().describe("bulk: many thread ids at once (the undo for all_threads)"),
    },
  },
  async ({ channel, post_id, channels, post_ids }) => {
    if (!SELF) return needSelf();
    const chs = [...(channels || []), ...(channel ? [channel] : [])];
    const ids = [...(post_ids || []), ...(post_id !== undefined ? [post_id] : [])];
    if (!chs.length && !ids.length) return text("error: pass channel/post_id, or channels/post_ids");

    let ok = 0;
    const failed = [];
    for (const c of chs) {
      const r = await cv.forumSubscribe(SELF, c, undefined);
      r.error ? failed.push(`#${c}: ${JSON.stringify(r.error)}`) : ok++;
    }
    for (const id of ids) {
      const r = await cv.forumSubscribe(SELF, undefined, id);
      r.error ? failed.push(`${id}: ${JSON.stringify(r.error)}`) : ok++;
    }
    // Name the failures individually. "288/292" with no members is unactionable —
    // you cannot retry a count.
    const lines = [`subscribed ${ok}/${chs.length + ids.length}`];
    if (failed.length) lines.push(`FAILED ${failed.length}:`, ...failed.map((f) => "  " + f));
    return text(lines.join("\n"));
  }
);

server.registerTool(
  "cv_forum_unsubscribe",
  {
    description:
      "Stop receiving pings — for a channel (pass channel) or a single thread (pass post_id). You can still read either any time.\n" +
      "BULK: `all_threads: true` drops EVERY thread subscription (channel subs kept); `all_channels: true` drops every channel. " +
      "A seat that has replied in hundreds of threads accumulates hundreds of ping sources, and unsubscribing one at a time is not feasible — that is what these are for. " +
      "⚠️ The result LISTS THE IDS IT REMOVED. That list is your ONLY undo: replay it with cv_forum_subscribe post_ids=[...]. Keep it before you act on anything else.",
    inputSchema: {
      channel: z.string().optional().describe("channel slug to unsubscribe from"),
      post_id: z.number().int().optional().describe("a post id to unsubscribe from its thread"),
      all_threads: z.boolean().optional().describe("drop EVERY thread subscription (channel subs kept)"),
      all_channels: z.boolean().optional().describe("drop EVERY channel subscription"),
    },
  },
  async ({ channel, post_id, all_threads, all_channels }) => {
    if (!SELF) return needSelf();

    if (all_threads || all_channels) {
      const cur = await cv.forumMySubscriptions(SELF);
      if (cur.error) return text(`error: ${JSON.stringify(cur.error)}`);
      const chs = all_channels ? (cur.channels || []).map((c) => c.slug) : [];
      const ids = all_threads ? (cur.threads || []).map((t) => t.post_id) : [];
      if (!chs.length && !ids.length) return text("(nothing to unsubscribe)");

      // Emit the undo BEFORE the removals, so it survives even if the loop dies
      // partway: a half-finished prune with no id list is unrecoverable, and the
      // ids exist nowhere else once the subscriptions are gone.
      const undo = [
        `UNDO (keep this — it is the only record):`,
        ids.length ? `  cv_forum_subscribe post_ids=[${ids.join(",")}]` : null,
        chs.length ? `  cv_forum_subscribe channels=[${chs.map((c) => `"${c}"`).join(",")}]` : null,
      ].filter(Boolean);

      let removed = 0;
      const failed = [];
      for (const c of chs) {
        const r = await cv.forumUnsubscribe(SELF, c, undefined);
        r.error ? failed.push(`#${c}: ${JSON.stringify(r.error)}`) : removed++;
      }
      for (const id of ids) {
        const r = await cv.forumUnsubscribe(SELF, undefined, id);
        r.error ? failed.push(`${id}: ${JSON.stringify(r.error)}`) : removed++;
      }
      // Re-read rather than trusting our own tally: the loop counts what we BELIEVE
      // we did; only the server measures the server.
      const after = await cv.forumMySubscriptions(SELF);
      const lines = [
        `removed ${removed}/${chs.length + ids.length}`,
        after.error
          ? `(could not verify: ${JSON.stringify(after.error)})`
          : `verified after: ${(after.channels || []).length} channel subs, ${(after.threads || []).length} thread subs`,
        ...undo,
      ];
      if (failed.length) lines.push(`FAILED ${failed.length}:`, ...failed.map((f) => "  " + f));
      return text(lines.join("\n"));
    }

    if (!channel && post_id === undefined)
      return text("error: pass channel, post_id, all_threads or all_channels");
    const r = await cv.forumUnsubscribe(SELF, channel, post_id);
    if (r.error) return text(`error: ${JSON.stringify(r.error)}`);
    return text(post_id !== undefined ? `unsubscribed from thread ${post_id}` : `unsubscribed from #${channel}`);
  }
);

server.registerTool(
  "cv_forum_my_subscriptions",
  {
    description:
      "List what YOU are subscribed to: channels (new-topic pings) and threads (reply pings). Use it to audit/prune your pings if you're getting too many.",
    inputSchema: {},
  },
  async () => {
    if (!SELF) return needSelf();
    const r = await cv.forumMySubscriptions(SELF);
    if (r.error) return text(`error: ${JSON.stringify(r.error)}`);
    const channels = (r.channels || []).map((c) => `#${c.slug}`);
    const threads = (r.threads || []).map(
      (t) => `thread ${t.post_id}${t.title ? ` “${t.title}”` : ""}${t.channel_slug ? ` (#${t.channel_slug})` : ""}`
    );
    if (!channels.length && !threads.length) return text("(no subscriptions)");
    const parts = [];
    if (channels.length) parts.push("channels: " + channels.join(", "));
    if (threads.length) parts.push("threads:\n  " + threads.join("\n  "));
    return text(parts.join("\n"));
  }
);

// --- forum work-tracker mutations (ALL roles) --------------------------------
// Turn the forum into a clean, self-pruning task board: ONE editable post per
// task — edit it in place, set its status/owner, pin the anchor, then archive or
// resolve (done+archive, record kept) or delete (hard remove) when finished.
// Cooperative: any fleet member may act (shared account); identity is your title.

const okPost = (r, verb) =>
  text(r.error ? `error: ${JSON.stringify(r.error)}` : `${verb} [${r.post.id}]${r.post.title ? ` “${r.post.title}”` : ""}${r.post.status ? ` (${r.post.status})` : ""}`);

server.registerTool(
  "cv_forum_edit",
  {
    description:
      "Edit a post IN PLACE (the work-tracker way to update a task — change its title/body/status/owner instead of replying with status updates). Pass only the fields you want to change.",
    inputSchema: {
      id: z.number().int().describe("post id to edit"),
      title: z.string().optional(),
      body: z.string().optional(),
      status: z.enum(["incoming", "active", "done"]).optional(),
      owner: z.string().optional().describe("assignee title"),
    },
  },
  async ({ id, title, body, status, owner }) => {
    const fields = {};
    if (title !== undefined) fields.title = title;
    if (body !== undefined) fields.body = body;
    if (status !== undefined) fields.status = status;
    if (owner !== undefined) fields.owner = owner;
    if (!Object.keys(fields).length) return text("nothing to edit (pass title/body/status/owner)");
    return okPost(await cv.forumEdit(id, fields), "edited");
  }
);

server.registerTool(
  "cv_forum_set_status",
  {
    description:
      "Set a task post's status: incoming → active → done. (done stays visible on the board; use cv_forum_resolve to also drop it off.)",
    inputSchema: { id: z.number().int(), status: z.enum(["incoming", "active", "done"]) },
  },
  async ({ id, status }) => okPost(await cv.forumSetStatus(id, status), "status →")
);

server.registerTool(
  "cv_forum_assign",
  {
    description:
      "Assign (or reassign) a task post's owner. Omit owner to clear the assignee. The new owner is pinged that work was assigned to it (no channel subscription needed) — unless you assign it to yourself.",
    inputSchema: { id: z.number().int(), owner: z.string().optional().describe("assignee title; omit to unassign") },
  },
  async ({ id, owner }) => okPost(await cv.forumAssign(id, owner ?? null, SELF), "assigned")
);

server.registerTool(
  "cv_forum_pin",
  {
    description: "Pin a post to the top of its channel (e.g. the conventions/anchor post). Pinned posts surface first in reads.",
    inputSchema: { id: z.number().int() },
  },
  async ({ id }) => okPost(await cv.forumPin(id), "pinned")
);

server.registerTool(
  "cv_forum_unpin",
  { description: "Remove a pin from a post.", inputSchema: { id: z.number().int() } },
  async ({ id }) => okPost(await cv.forumUnpin(id), "unpinned")
);

server.registerTool(
  "cv_forum_archive",
  {
    description:
      "Archive a post: soft-hide it (excluded from default reads, recoverable with cv_forum_unarchive). The recoverable way to clear something off the board. Keeps the full record.",
    inputSchema: { id: z.number().int() },
  },
  async ({ id }) => okPost(await cv.forumArchive(id), "archived")
);

server.registerTool(
  "cv_forum_unarchive",
  { description: "Restore an archived post back to the board.", inputSchema: { id: z.number().int() } },
  async ({ id }) => okPost(await cv.forumUnarchive(id), "unarchived")
);

server.registerTool(
  "cv_forum_resolve",
  {
    description:
      "Resolve a task: mark it done AND archive it in one step, so it drops off the active board but the record is KEPT. The normal 'this task is finished' action. (Distinct from cv_forum_delete, which removes the record.)",
    inputSchema: { id: z.number().int() },
  },
  async ({ id }) => okPost(await cv.forumResolve(id), "resolved")
);

server.registerTool(
  "cv_forum_delete",
  {
    description:
      "Hard-delete a post — IRREVERSIBLE. Deleting a top-level post removes the whole thread (root + replies); deleting a reply removes just that reply. Prefer cv_forum_archive/cv_forum_resolve to keep the record; use delete only for genuine junk.",
    inputSchema: { id: z.number().int().describe("post id to delete") },
  },
  async ({ id }) => {
    const r = await cv.forumDelete(id);
    return text(r.error ? `error: ${JSON.stringify(r.error)}` : `deleted (${r.deleted} row${r.deleted === 1 ? "" : "s"})`);
  }
);

// --- handoff tools (ALL roles, including "worker") ---------------------------
// Per-agent continuity state: your own canonical "here's where I am / next step /
// blockers" note, so a restart or a successor taking over your role can resume
// losslessly. PULL-ONLY by design — cv_handoff_set pings NOBODY, and nobody is
// expected to read others' handoffs unless they're taking over that role. There
// is exactly ONE current-state per role (set = upsert/overwrite, not a scroll).

server.registerTool(
  "cv_handoff_set",
  {
    description:
      "Upsert YOUR OWN handoff / current-state (overwrites your previous one — it's a single canonical note, not a thread). Put your standing state, current instructions, next step, and blockers so a restart or successor can resume your role losslessly. Update it at milestones / before risky points. Pings NOBODY — purely pull. You can only set your own role's handoff.",
    inputSchema: { body: z.string().describe("your full current-state note (markdown ok)") },
  },
  async ({ body }) => {
    if (!SELF) return needSelf();
    const r = await cv.handoffSet(SELF, body);
    return text(
      r.error
        ? `error: ${JSON.stringify(r.error)}`
        : `handoff for ${r.handoff.role} saved (v${r.handoff.version})`
    );
  }
);

server.registerTool(
  "cv_handoff_get",
  {
    description:
      "Read a role's canonical current-state handoff — use this on TAKEOVER (you're resuming/covering that role) or to recover your own after a restart. Pull-only; reading does not subscribe you to anything. Optionally include the last N historical versions.",
    inputSchema: {
      role: z.string().describe("the agent role/title whose handoff to read (e.g. decomper, tester)"),
      history: z.number().int().min(1).max(20).optional().describe("also return the last N prior versions"),
    },
  },
  async ({ role, history }) => {
    const r = await cv.handoffGet(role, history);
    if (r.error) return text(`error: ${r.error}`);
    const h = r.handoff;
    const head = `# handoff: ${h.role} (v${h.version}, updated ${h.updated_at})\n${h.body}`;
    if (!r.history?.length) return text(head);
    const hist = r.history
      .map((v) => `--- v${v.version} (${v.inserted_at}) ---\n${v.body}`)
      .join("\n\n");
    return text(`${head}\n\n=== history ===\n${hist}`);
  }
);

server.registerTool(
  "cv_handoff_list",
  {
    description:
      "List which roles currently have a handoff and when each was last updated. Pull-only. Use to see who's left resumable state.",
    inputSchema: {},
  },
  async () => {
    const { handoffs } = await cv.handoffList();
    if (!handoffs?.length) return text("(no handoffs yet — set yours with cv_handoff_set)");
    return text(handoffs.map((h) => `${h.role}\tv${h.version}\tupdated ${h.updated_at}`).join("\n"));
  }
);

// ---------------------------------------------------------------------------
// LIFECYCLE — spawn / stop / ps.
//
// Opt-in per seat: requires CLAUDIVERSE_LIFECYCLE=1 in that seat's mcp.json AND
// a non-worker role. Deliberately NOT on by default — adding these tools must
// not silently grant every existing seat the power to start OS processes on its
// next restart. The CEO/orchestrator seat opts in; nobody else does.
//
// These shell out to cv-spawn.sh / tmux directly rather than going through the
// server's POST /api/spawn, so lifecycle works with no Elixir change and no
// server restart (PENDING-CHANGES.md: server changes wait for the next
// necessary restart). cv-spawn.sh remains the single source of truth for HOW an
// instance launches; this is only a caller.
//
// execFile with an argv ARRAY (never a shell string) — arguments cannot be
// re-parsed as shell, so a title/prompt containing quotes or ';' is inert.
// ---------------------------------------------------------------------------
const LIFECYCLE = process.env.CLAUDIVERSE_LIFECYCLE === "1" && ROLE !== "worker";

const tmux = async (...args) => {
  try {
    const { stdout } = await execFileP("tmux", args);
    return { ok: true, out: stdout.trim() };
  } catch (e) {
    return { ok: false, out: String(e.stderr || e.message || e).trim() };
  }
};

const tmuxSessions = async () => {
  const r = await tmux("list-sessions", "-F", "#{session_name}");
  // No server running => "no server running on ..." on stderr, which is an EMPTY
  // fleet, not an error. Distinguish it from a real tmux failure.
  if (!r.ok) return /no server running/i.test(r.out) ? [] : null;
  return r.out ? r.out.split("\n").filter(Boolean) : [];
};

if (LIFECYCLE) {

server.registerTool(
  "cv_spawn",
  {
    description:
      "Start a NEW claudiverse agent session (detached tmux + mirrored to the server). Use for ephemeral per-task workers. Returns once the process is launched — the seat is NOT registered until it connects, so poll cv_status/cv_ps before sending it work. Refuses if a session of that title already exists.",
    inputSchema: {
      title: z.string().describe("session title — also the tmux session name; must be unique"),
      workdir: z.string().describe("absolute path the agent starts in"),
      mcp: z
        .string()
        .optional()
        .describe("path to the seat's .mcp.json (e.g. worker.mcp.json). Determines its role and tool surface."),
      mode: z
        .enum(["auto", "acceptEdits", "plan", "default"])
        .optional()
        .describe("permission mode; default 'auto' (classifier guardrail, recommended for unattended spawns)"),
      prompt: z.string().optional().describe("initial prompt injected at launch (the task brief)"),
    },
  },
  async ({ title, workdir, mcp, mode, prompt }) => {
    const live = await tmuxSessions();
    if (live === null) return text("error: tmux is not usable from here — cannot spawn.");
    if (live.includes(title)) return text(`refused: a tmux session named '${title}' already exists. Stop it first (cv_stop) or pick another title.`);

    const args = [workdir, "--title", title];
    if (mcp) args.push("--mcp", mcp);
    if (mode) args.push("--mode", mode);
    if (prompt) args.push("--prompt", prompt);

    try {
      const { stdout } = await execFileP(join(HERE, "cv-spawn.sh"), args, { timeout: 30000 });
      const after = await tmuxSessions();
      const present = Array.isArray(after) && after.includes(title);
      return text(
        `${stdout.trim()}\n\n` +
          `tmux session present: ${present ? "YES" : "NO — spawn reported success but the session is absent; investigate before sending work"}\n` +
          `NOT YET VERIFIED: that the agent connected to the server. Check cv_ps / cv_status '${title}' before treating it as live.`
      );
    } catch (e) {
      return text(`spawn FAILED: ${String(e.stderr || e.message || e).trim()}`);
    }
  }
);

server.registerTool(
  "cv_stop",
  {
    description:
      "Stop an agent session (kills its tmux session). REFUSES BY DEFAULT if that role has no handoff — a seat whose only state is its context cannot be killed without losing it. Pass force:true to override once you've accepted that loss.",
    inputSchema: {
      title: z.string().describe("session title to stop"),
      force: z.boolean().optional().describe("stop even if the role has no handoff — you are accepting the knowledge loss"),
    },
  },
  async ({ title, force }) => {
    const live = await tmuxSessions();
    if (live === null) return text("error: tmux is not usable from here — cannot stop.");
    if (!live.includes(title)) return text(`no tmux session named '${title}' — nothing to stop. (It may already be gone; cv_ps to see the full picture.)`);

    // The gate: refuse to destroy a context that was never externalised.
    let handoffNote;
    try {
      const h = await cv.handoffGet(title);
      const hh = h?.handoff;
      handoffNote = hh
        ? `handoff present: v${hh.version}, updated ${hh.updated_at}`
        : null;
    } catch {
      handoffNote = null; // 404 / absent
    }

    if (!handoffNote && !force) {
      return text(
        `⛔ REFUSED: '${title}' has NO handoff.\n\n` +
          `Killing it destroys everything it knows — its context is its only state.\n` +
          `Ask it to run cv_handoff_set first, then stop it. If the work is genuinely\n` +
          `worthless, re-run with force:true and say so in the record.`
      );
    }

    const k = await tmux("kill-session", "-t", title);
    if (!k.ok) return text(`stop FAILED: ${k.out}`);
    const after = await tmuxSessions();
    const gone = Array.isArray(after) && !after.includes(title);
    return text(
      `stopped '${title}' — tmux session ${gone ? "confirmed gone" : "STILL PRESENT (verify manually)"}\n` +
        (handoffNote ? handoffNote : "⚠️ stopped WITHOUT a handoff (force) — its knowledge is gone.")
    );
  }
);

server.registerTool(
  "cv_ps",
  {
    description:
      "Cross-check tmux sessions ON THIS HOST against what the server thinks is running. Surfaces UNREGISTERED processes and UNACCOUNTED sessions. ⚠️ The server's list is FLEET-WIDE but tmux is LOCAL — a seat on another machine is not distinguishable here from a dead one. Read the UNACCOUNTED bound before acting on it.",
    inputSchema: {},
  },
  async () => {
    const live = await tmuxSessions();
    if (live === null) return text("error: tmux is not usable from here.");
    const sessions = await cv.listSessions();
    const serverRunning = sessions.filter((s) => s.status === "running").map((s) => s.title);
    let host = "this host";
    try {
      const { stdout } = await execFileP("hostname", []);
      host = stdout.trim() || host;
    } catch {}

    const both = live.filter((t) => serverRunning.includes(t)).sort();
    const tmuxOnly = live.filter((t) => !serverRunning.includes(t)).sort();
    const unaccounted = serverRunning.filter((t) => !live.includes(t)).sort();

    const fmt = (label, arr, note) =>
      `${label} (${arr.length})${note ? " — " + note : ""}\n` + (arr.length ? arr.map((t) => "  " + t).join("\n") : "  (none)");

    return text(
      [
        `host: ${host}`,
        fmt("LIVE + REGISTERED", both, "tmux session HERE and the server lists it running"),
        fmt("PROCESS ONLY", tmuxOnly, "tmux session HERE, server does NOT list it running — never connected, or died mid-handshake"),
        fmt(
          "UNACCOUNTED",
          unaccounted,
          "server lists it running, NO tmux session on THIS host"
        ),
        "⛔ UNACCOUNTED IS NOT 'DEAD'. It means exactly one of:\n" +
          "   (a) the seat runs on ANOTHER MACHINE — normal, expected, not a fault; or\n" +
          "   (b) the process is genuinely gone and the server's status is stale.\n" +
          "   This tool CANNOT tell them apart: sessions carry no host field. Do not\n" +
          "   'clean up' an UNACCOUNTED seat without checking the other machines first.",
        "Bound: tmux presence proves a PROCESS, not a healthy agent. A wedged seat still shows LIVE.",
      ].join("\n\n")
    );
  }
);

}

// ---------------------------------------------------------------------------
// LEDGER — addressable facts for ephemeral workers.
//
// A worker that dies after one task leaves nothing behind but this. So the
// store, not the seat, is the system. Built on forum posts (no migration, no
// server restart): a FACT is a top-level post; a CORRECTION is a typed reply.
//
// Four design rules, each bought with a measured failure:
//
//  1. EVERY FACT CARRIES A COMMAND THAT CAN FAIL. `git show -s <sha>` prints the
//     subject of an ORPHANED commit — it re-derives the fact and confirms a dead
//     identifier. A re-derivation with no reachable negative is decoration, so
//     `fails_when` is REQUIRED: if you cannot say what failure looks like, you
//     do not have a check.
//
//  2. NO UN-THREADED READ PATH. cv_forum_get renders a post WITHOUT its replies,
//     so a ping hands you an id and the natural fetch structurally hides every
//     correction since. Measured on post 8523: seven replies hidden, one of them
//     its own retraction. cv_fact_get always threads and LEADS with corrections.
//
//  3. CORRECTIONS ARE TYPED, NOT PROSE. Forcing co-presence only moves the
//     failure from "reader didn't fetch" to "writer didn't mark", and a missing
//     mark is indistinguishable from no correction. Observed live: a reversal
//     that read as a fresh finding with its retracting force buried in prose.
//     RETRACTS / NARROWS / SUPERSEDES — and NARROWS matters most, because most
//     corrections shrink a bound rather than kill a claim ("17/26 rendered" was
//     never wrong; "17/26 verified" was). A binary schema is lossy on the
//     majority case, in both directions.
//
//  4. FACTS AND RULINGS ARE DIFFERENT THINGS. "This is a hazard" has no command
//     that re-derives it, so it is structurally not a fact. Excluded — but
//     exclusion without a destination just sends it back to prose welded onto a
//     real fact, which is how a correct mechanism and an invented severity get
//     published as one finding and only half of it gets audited. Rulings get
//     their own store: OWNER, DATE, and REVOKED-BY (the substitute for COMMAND —
//     a ruling whose retiring condition is unstated never retires).
//
// Credit: rules 2, 3 and 4 are ipsum-admin's, from its own fleet's failures.
// ---------------------------------------------------------------------------
const REL = { RETRACTS: "RETRACTS", NARROWS: "NARROWS", SUPERSEDES: "SUPERSEDES" };
const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);

const relationOf = (title = "") => {
  const m = /^(RETRACTS|NARROWS|SUPERSEDES)\s+#(\d+)/.exec(title.trim());
  return m ? { rel: m[1], target: Number(m[2]) } : null;
};

server.registerTool(
  "cv_task_create",
  {
    description:
      "Author a task with real state. ⭐ A task you cannot claim is IMPOSSIBLE here, not merely warned about: `ready` publishes it, otherwise it stays DRAFT deliberately. Priority is a FIELD — do NOT write ordering into the body. Prose in a body is what redirected a worker away from the task its runner was tracking and stranded a slot for an hour.",
    inputSchema: {
      fleet: z.string().describe("e.g. lorem-fleet, ipsum-fleet"),
      lane: z.string().describe("routing to a slot class, e.g. lorem-tasks, lorem-tasks-deep, lorem-analysis"),
      title: z.string(),
      body_md: z.string().optional().describe("what to do and how it will be checked. NOT ordering — use priority."),
      priority: z.number().int().optional().describe("higher claims first. This replaces 'TAKE #NNNN FIRST' in a body."),
      ready: z.boolean().optional().describe("true = claimable now; omit to leave DRAFT"),
      vm_required: z.boolean().optional().describe("true if it needs the single-owner colima VM, so the scheduler can avoid double-booking it"),
      validates_task_id: z.number().int().optional().describe("the task this validates — makes the chain traversable instead of grep-able"),
    },
  },
  async (a) => {
    if (!SELF) return needSelf();
    try {
      const r = await cv.taskCreate({ ...a, created_by: SELF });
      const t = r.task;
      return text(
        `task #${t.id} ${t.state} — ${t.lane} prio ${t.priority}${t.vm_required ? " [needs VM]" : ""}\n${t.title}` +
          (t.state === "DRAFT" ? "\n\n⚠️ DRAFT: not claimable until you call cv_task_ready." : "")
      );
    } catch (e) {
      return text(`could not create task: ${String(e.message || e)}`);
    }
  }
);

server.registerTool(
  "cv_task_ready",
  {
    description: "Publish a DRAFT task, making it claimable. REFUSES while a BLOCKS dependency is unmet — 'do X first' is an edge the scheduler enforces, not a sentence a worker might misread. Idempotent on an already-READY task.",
    inputSchema: { id: z.number().int() },
  },
  async ({ id }) => {
    // Publishing makes a task claimable by the whole fleet. Without this guard
    // SELF fell through as null and the server took it: #18 was published to
    // lorem-fleet by a blank actor and the event log could record only that it
    // happened, never who to ask.
    if (!SELF) return needSelf();
    try {
      const r = await cv.taskReady(id, SELF);
      return text(`task #${id} is ${r.task.state}`);
    } catch (e) {
      const m = String(e.message || e);
      return text(m.includes("blocked") ? `⛔ #${id} is BLOCKED: ${m}` : `could not ready #${id}: ${m}`);
    }
  }
);

server.registerTool(
  "cv_task_list",
  {
    description: "List tasks by fleet, lane, state or holder. States: DRAFT READY CLAIMED RUNNING DONE VALIDATED RELEASED SUPERSEDED. READY is the only claimable one.",
    inputSchema: {
      fleet: z.string().optional(),
      lane: z.string().optional(),
      state: z.string().optional(),
      claimed_by: z.string().optional(),
      limit: z.number().int().optional(),
    },
  },
  async (f) => {
    try {
      const r = await cv.taskList(f);
      if (!r.tasks?.length) return text("no tasks match.");
      return text(
        r.tasks
          .map((t) => `#${t.id} ${t.state.padEnd(10)} p${String(t.priority).padStart(3)} ${t.lane}  ${t.title}${t.claimed_by ? "  [" + t.claimed_by + "]" : ""}`)
          .join("\n")
      );
    } catch (e) {
      return text(`could not list tasks: ${String(e.message || e)}`);
    }
  }
);

server.registerTool(
  "cv_task_show",
  {
    description: "One task with its body, its RECENT event history and any unmet blockers. The event trail is durable — today the equivalent is ephemeral tmux scrollback, so a strand leaves no record once the pane scrolls. The trail is bounded to the most recent events and says so when it elides; raise it with limit:. The body is shown whole up to 20,000 bytes and says how much it withheld beyond that.",
    inputSchema: {
      id: z.number().int(),
      limit: z.number().int().optional().describe("how many of the most recent events to render (default 200)"),
    },
  },
  async ({ id, limit }) => {
    try {
      const r = await cv.taskShow(id);
      const t = r.task;
      // The server returns body_md and this renderer used to DROP it. A validator
      // reading #282 (6,642-byte body, acceptance criteria verbatim) through this
      // tool saw a one-line title and concluded the task "HAS NO ACCEPTANCE
      // SECTION AT ALL" — a statement about the rendering, escalated as a spec
      // defect. So: absence prints as absence, presence prints with its size,
      // and a withheld tail says how many bytes it withheld.
      const BODY_CAP = 20_000; // bytes; the forum's post cap, and a task body has never needed more
      const body = t.body_md ?? "";
      const bodyBytes = Buffer.byteLength(body, "utf8");
      let bodyOut;
      if (!body.trim()) {
        bodyOut = `body: (none)`;
      } else if (bodyBytes <= BODY_CAP) {
        bodyOut = `body (${bodyBytes.toLocaleString("en-US")} bytes):\n${body}`;
      } else {
        // Cut by BYTES, not by String.slice's UTF-16 units: a 12,000-char body of
        // 2-byte characters is 24,000 bytes, and a char-based cut would have shown
        // it whole under a PARTIAL banner claiming "0 bytes withheld" (caught by
        // the multibyte control in task #289). Shrink until it fits, then drop a
        // dangling high surrogate so the cut never lands inside one code point.
        let head = body;
        while (Buffer.byteLength(head, "utf8") > BODY_CAP) {
          head = head.slice(0, Math.floor((head.length * BODY_CAP) / Buffer.byteLength(head, "utf8")));
        }
        if (/[\uD800-\uDBFF]$/.test(head)) head = head.slice(0, -1);
        const withheld = bodyBytes - Buffer.byteLength(head, "utf8");
        bodyOut =
          `body (${bodyBytes.toLocaleString("en-US")} bytes) ⚠️ PARTIAL — showing the first ${Buffer.byteLength(head, "utf8").toLocaleString("en-US")}; ` +
          `${withheld.toLocaleString("en-US")} bytes withheld. Whole body: GET /api/tasks/${t.id}\n${head}`;
      }
      // An unbounded event trail is not a cosmetic problem: rendered whole it
      // has written >16MB to stdout as a SINGLE JSON-RPC line and killed the
      // caller's transport, taking every cv_* tool out of that session.
      // Keep the most recent events and SAY what was withheld — a trimmed
      // history that reads as a complete short one is the failure this project
      // keeps paying for.
      const allEvents = r.events || [];
      const keep = Math.max(1, limit ?? 200);
      const shownEvents = allEvents.length > keep ? allEvents.slice(-keep) : allEvents;
      const elided = allEvents.length - shownEvents.length;
      const ev = shownEvents.map((e) => `  ${e.at} ${e.kind.padEnd(10)} ${e.actor || ""} ${e.detail || ""}`.trimEnd()).join("\n");
      return text(
        `#${t.id} ${t.state} — ${t.lane} prio ${t.priority}${t.vm_required ? " [needs VM]" : ""}\n${t.title}\n` +
          (r.blocked_by?.length ? `\n⛔ blocked by: ${r.blocked_by.join(", ")}\n` : "") +
          (t.claimed_by ? `\nheld by ${t.claimed_by} since ${t.claimed_at}\n` : "") +
          `\n${bodyOut}\n` +
          `\nevents:\n` +
          // The bound goes BEFORE the list: a tail-biased reader loses the last
          // line first, and that is exactly where a trailing caveat dies.
          (elided
            ? `  ⚠️ PARTIAL — showing the ${shownEvents.length} most recent of ${allEvents.length}; ${elided} earlier event(s) withheld. Raise with limit:.\n`
            : "") +
          (ev || "  (none)")
      );
    } catch (e) {
      return text(`could not read task ${id}: ${String(e.message || e)}`);
    }
  }
);

server.registerTool(
  "cv_task_dep",
  {
    description: "Record that one task depends on another. BLOCKS keeps the task out of READY until the dependency is DONE; INFORMS is advisory. This replaces writing 'do #NNNN first' into a body, which is prose a worker can act on in the wrong order.",
    inputSchema: {
      id: z.number().int().describe("the dependent task"),
      depends_on: z.number().int(),
      kind: z.enum(["BLOCKS", "INFORMS"]).optional(),
    },
  },
  async ({ id, depends_on, kind }) => {
    // A BLOCKS edge decides what workers may claim, so it is an authority
    // change and carries the same attribution as publishing one.
    if (!SELF) return needSelf();
    try {
      await cv.taskDep(id, { depends_on, kind: kind || "BLOCKS", actor: SELF });
      return text(`#${id} ${kind || "BLOCKS"} <- #${depends_on}`);
    } catch (e) {
      return text(`could not add dep: ${String(e.message || e)}`);
    }
  }
);

server.registerTool(
  "cv_task_health",
  {
    description:
      "⭐ THE WATCHER SWEEP AS A QUERY — starved lanes, stranded claims, stalled runs. ⚠️ You MUST supply live_lanes and live_workers: the server cannot see tmux, and a claimed task leaves the ready set, so a fed-and-working lane and a starving one produce the IDENTICAL zero. Queue depth is only interpretable next to consumer liveness. `stalled` samples SILENCE and is advisory — a quota-dead seat reported busy for 4.5 hours, and qemu sat at 162% and 309% while genuinely building.",
    inputSchema: {
      fleet: z.string(),
      live_lanes: z.array(z.string()).describe("lanes that currently have a live runner"),
      live_workers: z.array(z.string()).describe("worker slots with a live session right now"),
      stall_minutes: z.number().int().optional(),
    },
  },
  async (a) => {
    try {
      const r = await cv.taskHealth(a);
      const lines = [];
      if (r.starved_lanes?.length) lines.push(`⚠️ STARVED lanes (live runner, zero READY): ${r.starved_lanes.join(", ")}`);
      if (r.stranded?.length) lines.push(`⚠️ STRANDED: ${r.stranded.map((t) => `#${t.id} held by ${t.claimed_by}`).join(", ")}`);
      if (r.stalled?.length) lines.push(`… stalled (ADVISORY, silence not work): ${r.stalled.map((t) => "#" + t.id).join(", ")}`);
      return text(lines.length ? lines.join("\n") : "nothing starved, stranded or stalled.");
    } catch (e) {
      return text(`could not read task health: ${String(e.message || e)}`);
    }
  }
);

server.registerTool(
  "cv_submit_match",
  {
    description:
      "Deliver a matched function. ⭐ ONE CALL — no branch, no push, no git. It is DURABLE the moment this returns: if you are killed one instruction later, nothing is lost. This REPLACES 'push anything kept to an eph/ branch', which the charter also forbids — that contradiction is what produced 153 rescue refs, 84 of them reachable from no remote.",
    inputSchema: {
      address: z.string().describe("the function's address — any spelling (0x00336B88, func_00336b88, 00336B88). This is the durable identity; a NAME can be renamed out from under it."),
      build: z.string().describe("which build, e.g. usa_v200"),
      body_c: z.string().describe("the C you are delivering, verbatim"),
      unit: z.string().optional().describe("the unit it belongs to, e.g. text/336000"),
      tier: z.enum(["T1", "T2", "T3"]).optional(),
      base_sha: z.string().optional().describe("the sha you derived and gated against. A submission gated on an older tree is re-gated at HEAD — it is never integrated on stale evidence."),
      compiler: z.string().optional(),
      flags: z.string().optional(),
      notes: z.string().optional().describe("anything a reviewer needs that the C does not say"),
    },
  },
  async ({ address, build, body_c, unit, tier, base_sha, compiler, flags, notes }) => {
    if (!SELF) return needSelf();
    try {
      const r = await cv.subSubmit({
        address, build, body_c, unit, tier, base_sha, compiler, flags, notes,
        submitted_by: SELF,
      });
      const s = r.submission;
      return text(
        `✅ submission #${s.id} DURABLE — address ${s.address}, build ${s.build}, state ${s.state}.\n` +
          `You may be reaped now without losing this. Do NOT create a branch for it.\n\n` +
          `body_hash ${String(s.body_hash).slice(0, 16)}…` +
          (s.superseded_by ? `\n⚠️ supersedes an earlier submission for this address.` : "")
      );
    } catch (e) {
      // ⛔ A failed submission must be UNMISTAKABLE. If a worker reads this as
      // success it will move on and the work is gone — which is exactly the
      // loss this tool exists to prevent.
      return text(
        `⛔ SUBMISSION FAILED — NOTHING WAS STORED: ${String(e.message || e).slice(0, 300)}\n\n` +
          `Your work is NOT durable. Do not move on. Retry, or keep it in your worktree and report.`
      );
    }
  }
);

server.registerTool(
  "cv_submission_list",
  {
    description: "List submissions by address, build, unit, state or submitter. States: SUBMITTED · GATING · GATE_PASS · GATE_FAIL · INTEGRATED · AUDITED · RETRACTED · SUPERSEDED. GATE_PASS is NOT integrated, and INTEGRATED is NOT audited — three different claims with three different amounts of evidence.",
    inputSchema: {
      address: z.string().optional(),
      build: z.string().optional(),
      unit: z.string().optional(),
      state: z.string().optional(),
      submitted_by: z.string().optional(),
      limit: z.number().int().optional(),
    },
  },
  async (f) => {
    try {
      const r = await cv.subList(f);
      if (!r.submissions?.length) return text("no submissions match.");
      return text(
        r.submissions
          .map((s) => `#${s.id} ${s.address} ${s.build} ${s.state}${s.unit ? " " + s.unit : ""} — ${s.submitted_by}`)
          .join("\n")
      );
    } catch (e) {
      return text(`could not list submissions: ${String(e.message || e)}`);
    }
  }
);

server.registerTool(
  "cv_submission_get",
  {
    description: "Read one submission with its gate runs. Each gate shows could_have_failed — whether a positive control was recorded. ⭐ A gate that could NOT have failed reports PASS forever and is indistinguishable from one that works.",
    inputSchema: { id: z.number().int() },
  },
  async ({ id }) => {
    try {
      const r = await cv.subGet(id);
      const s = r.submission;
      const gates = (r.gates || [])
        .map(
          (g) =>
            `  ${g.verdict.padEnd(10)} ${g.gate_name}` +
            (g.could_have_failed ? "" : "   ⚠️ NO POSITIVE CONTROL — this run could not have failed")
        )
        .join("\n");
      return text(
        `#${s.id} ${s.address} ${s.build} — ${s.state}\n` +
          `unit ${s.unit || "?"} · tier ${s.tier || "?"} · by ${s.submitted_by}\n` +
          `base_sha ${s.base_sha || "(none recorded)"}\n\n` +
          (gates || "  (no gate runs yet)") +
          (r.integration ? `\n\nintegrated at ${r.integration.integrated_sha}` : "")
      );
    } catch (e) {
      return text(`could not read submission ${id}: ${String(e.message || e)}`);
    }
  }
);

server.registerTool(
  "cv_fact_add",
  {
    description:
      "Record a FACT in the ledger — the durable substrate an ephemeral worker leaves behind. Requires a command that RE-DERIVES it and a statement of what FAILURE would look like: a check with no reachable negative is decoration. Do NOT use for severity/priority/'this is a defect' — those are rulings (cv_ruling_add), not facts.",
    inputSchema: {
      channel: z.string().describe("ledger channel slug — 'ledger-proto2' (the one the knowledge-store importer reads). There is NO channel named 'ledger'; it returns 404."),
      claim: z.string().describe("what is true — one sentence, checkable"),
      command: z.string().describe("the command that RE-DERIVES this. Record the command, never just its output."),
      fails_when: z
        .string()
        .describe("what output would show the claim is FALSE. If you cannot state this, the command cannot fail and is not evidence."),
      fails_when_status: z
        .enum(["DEMONSTRATED", "ASSERTED"])
        .describe(
          "DEMONSTRATED = you have SEEN this command produce that failing output (say how in demonstrated_by). ASSERTED = you believe it would. Be honest: an unobserved FAILS_WHEN is decoration, and mislabelling it is the defect this field exists to prevent."
        ),
      demonstrated_by: z
        .string()
        .optional()
        .describe("required when DEMONSTRATED: the negative control you actually ran, and what it returned"),
      bound: z.string().describe("what this does NOT establish. 'precise but not complete' is a valid and common bound."),
      derived_under: z
        .string()
        .describe("the question or design this was reasoned against — so a design change can invalidate it by default"),
    },
  },
  async ({ channel, claim, command, fails_when, fails_when_status, demonstrated_by, bound, derived_under }) => {
    if (!SELF) return needSelf();
    if (fails_when_status === "DEMONSTRATED" && !demonstrated_by) {
      return text(
        `⛔ REFUSED: fails_when_status=DEMONSTRATED requires demonstrated_by — the negative control you ran and what it returned.\n` +
          `A DEMONSTRATED marker with no observation behind it is the strongest false assurance in the schema. Use ASSERTED if you did not run it.`
      );
    }
    // Assurance fields are satisfiable by assertion. They cannot be validated
    // here, so they are LABELLED instead: a reader must be able to see which
    // fields were observed and which were merely typed. Absent, a reader knows
    // to check; present-and-unvalidated, the reader stops.  (ipsum-admin.)
    const fwMark =
      fails_when_status === "DEMONSTRATED"
        ? `DEMONSTRATED — ${demonstrated_by}`
        : "ASSERTED — never observed to fail; treat as untested";
    const body = [
      `**CLAIM** ${claim}`,
      "",
      "```",
      `COMMAND       ${command}`,
      `FAILS WHEN    ${fails_when}`,
      `  └ status    ${fwMark}`,
      "```",
      `**BOUND** ${bound}  _(ASSERTED — not verified)_`,
      "",
      `**DERIVED UNDER** ${derived_under}`,
      "",
      `_recorded by ${SELF}. COMMAND is executable and re-runnable; FAILS WHEN and BOUND are claims about the command, not outputs of it._`,
    ].join("\n");
    const r = await cv.forumPost(SELF, channel, body, undefined, {
      title: `FACT: ${clip(claim, 90)}`,
      status: "active",
    });
    const id = r?.post?.id ?? r?.id;

    // ── Also record it in the KNOWLEDGE STORE ────────────────────────────────
    //
    // Without this the store is a SNAPSHOT: 4,112 facts frozen at import time
    // while the ledger keeps growing in the forum. That silently recreates the
    // two-sources-of-truth problem the store exists to remove, and it starts
    // the moment the import finishes.
    //
    // ⭐ FORUM FIRST, deliberately. The two failure modes are not symmetric:
    //   · store write fails  -> RECOVERABLE. `LedgerImport.run()` is idempotent
    //     and keys on the post id, so the next import picks this fact up.
    //   · forum write fails  -> NOT recoverable. The store has no notification
    //     path, so nobody would ever learn the fact was recorded.
    // Writing the recoverable one second makes the pair eventually consistent.
    //
    // The slug matches the importer's (`ledger-<post_id>`) so a later import
    // recognises this document instead of creating a duplicate.
    let kbNote = "";
    if (id) {
      try {
        await cv.kbCreate({
          slug: `ledger-${id}`,
          kind: "FACT",
          scope: "ledger",
          title: `FACT: ${clip(claim, 200)}`,
          body_md: body,
          author: SELF,
          created_by: SELF,
          fact_command: command,
          fact_fails_when: fails_when,
          fact_fails_when_status: fails_when_status,
          fact_bound: bound,
          fact_derived_under: derived_under,
          front_matter: {
            source_post_id: id,
            source_channel: channel,
            demonstrated_by: demonstrated_by ?? null,
          },
        });
        kbNote = " · indexed as ledger-" + id;
      } catch (e) {
        // Reported, never swallowed: a silent half-write is how the two stores
        // drift without anyone noticing.
        kbNote =
          `\n\n⚠️ NOT indexed in the knowledge store: ${String(e.message || e).slice(0, 160)}` +
          `\n   The fact IS in the forum and the next ledger import will pick it up.`;
      }
    }

    return text(
      `fact #${id} recorded in #${channel}${kbNote}\n\nCorrect it later with cv_fact_relate — never by editing it.`
    );
  }
);

server.registerTool(
  "cv_fact_relate",
  {
    description:
      "Correct an existing fact with a TYPED relation. Use NARROWS when the claim survives but its bound shrinks — that is the common case and the one a retract/not-retract schema destroys. Corrections are worth full weight at harvest; they are not second-class output.",
    inputSchema: {
      fact_id: z.number().int().describe("the fact being corrected"),
      relation: z
        .enum(["RETRACTS", "NARROWS", "SUPERSEDES"])
        .describe("RETRACTS = claim is dead · NARROWS = claim survives, bound shrinks · SUPERSEDES = replaced by a better-scoped claim"),
      because: z.string().describe("what changed, and the measurement behind it"),
      command: z.string().optional().describe("command re-deriving the correction, if there is one"),
      new_bound: z.string().optional().describe("for NARROWS: the bound as it now stands"),
    },
  },
  async ({ fact_id, relation, because, command, new_bound }) => {
    if (!SELF) return needSelf();

    // The reply must land in the PARENT's channel — the API rejects a blank one,
    // and an unverified write is how a correction silently fails to exist.
    let parent;
    try {
      const pr = await cv.forumGet(fact_id, false);
      parent = pr?.post ?? pr;
    } catch (e) {
      return text(`cannot correct #${fact_id}: could not read it (${String(e.message || e)}). Nothing was written.`);
    }
    if (!parent?.channel) return text(`cannot correct #${fact_id}: it has no channel. Nothing was written.`);

    // ⛔ fact_id is a FORUM POST id, but FACTs now live in the knowledge store
    // with their own id sequence. Given a store FACT's number, this tool used to
    // reply to whatever unrelated forum post shares the integer — in whatever
    // channel that is. MEASURED 2026-10-02: five lorem-fleet NARROWS (e.g. "NARROWS
    // #8705", forum/ipsum-queue/29449) landed inside ipsum-fleet's #1256 thread. Only a
    // forum-era fact (top-level, titled "FACT: …") is a valid target here.
    if (parent.parent_id || !String(parent.title || "").startsWith("FACT:")) {
      return text(
        `⛔ REFUSED — forum post #${fact_id} is not a forum-era FACT (it is ${JSON.stringify(clip(String(parent.title || "untitled"), 60))} in #${parent.channel}). ` +
          `Knowledge-store FACTs have their own ids: correct them with cv_doc_relate (NARROWS / RETRACTS / SUPERSEDES). Nothing was written.`
      );
    }

    const body = [
      `**${relation} #${fact_id}**`,
      "",
      because,
      command ? "\n```\nCOMMAND  " + command + "\n```" : "",
      new_bound ? `\n**BOUND NOW** ${new_bound}` : "",
      "",
      `_by ${SELF}_`,
    ].join("\n");

    try {
      await cv.forumPost(SELF, parent.channel, body, fact_id, { title: `${relation} #${fact_id}` });
    } catch (e) {
      return text(`correction FAILED to post: ${String(e.message || e)}. #${fact_id} is UNCHANGED and still reads as originally recorded.`);
    }

    if (relation === REL.RETRACTS) {
      try {
        await cv.forumSetStatus(fact_id, "done");
      } catch {}
    }

    // VERIFY THROUGH THE READER'S PATH. The writer's return value proves a
    // request succeeded; only re-reading the way a reader reads proves the
    // correction is actually reachable. A correction that posts but does not
    // surface is worse than one that fails loudly.
    let visible = false;
    try {
      const check = await cv.forumGet(fact_id, true);
      visible = (check?.replies ?? []).some((p) => {
        const r = relationOf(p.title || "");
        return r && r.target === fact_id && r.rel === relation;
      });
    } catch {}

    // ── Mirror the correction into the KNOWLEDGE STORE ──────────────────────
    //
    // A correction that reaches only the forum leaves the store showing the
    // claim as it was ORIGINALLY recorded — the single worst drift this pair
    // can have, because the store then answers confidently and wrongly. The
    // whole premise of `get_document` returning corrections inline is that
    // nobody can be handed a claim whose retraction exists but is not shown.
    //
    // As in cv_fact_add: forum first (unrecoverable if lost), store second
    // (recoverable — the idempotent importer re-wires it by post id).
    let kbNote = "";
    try {
      const replies = (await cv.forumGet(fact_id, true))?.replies ?? [];
      const mine = replies
        .filter((p) => {
          const r = relationOf(p.title || "");
          return r && r.target === fact_id && r.rel === relation;
        })
        .pop();

      if (mine?.id) {
        await cv.kbCreate({
          slug: `ledger-${mine.id}`,
          kind: "NOTE",
          scope: "ledger",
          title: `${relation} #${fact_id}`,
          body_md: body,
          author: SELF,
          created_by: SELF,
          front_matter: { source_post_id: mine.id, source_channel: parent.channel },
        });

        await cv.kbRelate({
          from: `ledger-${mine.id}`,
          to: `ledger-${fact_id}`,
          kind: relation,
          author: SELF,
        });

        kbNote = ` · correction edge ledger-${mine.id} -> ledger-${fact_id} recorded in the store`;
      }
    } catch (e) {
      kbNote =
        `\n\n⚠️ The correction is in the FORUM but NOT in the knowledge store: ` +
        `${String(e.message || e).slice(0, 160)}\n` +
        `   ⛔ A store read of this fact may still show it UNCORRECTED. Re-run the ledger import.`;
    }

    return text(
      visible
        ? `#${fact_id} ${relation} recorded AND VERIFIED — re-read through cv_fact_get confirms it now leads the fact.${kbNote}`
        : `⚠️ #${fact_id} ${relation} was posted but is NOT VISIBLE on re-read.\n` +
            `Do NOT assume the fact is corrected — a reader fetching #${fact_id} may still get the uncorrected claim.\n` +
            `Investigate before relying on it.${kbNote}`
    );
  }
);

server.registerTool(
  "cv_fact_get",
  {
    description:
      "Read a fact WITH its corrections. There is deliberately no un-threaded read path: fetching a fact by id must never be able to hand you a claim whose retraction exists but is not shown.",
    inputSchema: { id: z.number().int() },
  },
  async ({ id }) => {
    const r = await cv.forumGet(id, true);
    const post = r?.post ?? r;
    const replies = r?.replies ?? [];
    const rels = replies
      .map((p) => ({ p, r: relationOf(p.title || "") }))
      .filter((x) => x.r && x.r.target === id);

    const head = rels.length
      ? "⛔ THIS FACT HAS BEEN CORRECTED — read these FIRST:\n\n" +
        rels.map((x) => `[${x.p.id}] ${x.r.rel}\n${x.p.body}`).join("\n\n---\n\n") +
        "\n\n=== the corrected fact, below, as originally recorded ===\n"
      : "";
    const untyped = replies.length - rels.length;
    const tail = untyped
      ? `\n\n⚠️ ${untyped} further repl${untyped === 1 ? "y" : "ies"} on this fact carry NO typed relation. ` +
        `A correction written as prose is invisible to this tool — read the thread if the stakes are high.`
      : "";
    return text(`${head}[${post.id}] ${post.title || "(untitled)"}\n${post.body}${tail}`);
  }
);

server.registerTool(
  "cv_ruling_add",
  {
    description:
      "Record a RULING — a decision, priority, severity or 'do not do X'. NOT a fact: it has no command that re-derives it. Requires REVOKED_BY, the observable that would retire it, because a ruling with no stated retiring condition never retires and quietly outlives its cause.",
    inputSchema: {
      channel: z.string().describe("rulings channel slug, e.g. 'rulings'"),
      ruling: z.string().describe("what is decided"),
      because: z.string().describe("the reasoning — and name any FACT ids it rests on"),
      revoked_by: z
        .string()
        .describe("the observable that would retire this ruling. 'nothing / permanent' is an answer, but say it deliberately."),
      owner: z
        .string()
        .optional()
        .describe("who made this call. Defaults to you. Naming SOMEONE ELSE requires grant_ref — you cannot attribute a decision to a party that did not make it."),
      grant_ref: z
        .number()
        .int()
        .optional()
        .describe("post id in which the named owner actually issued this. VERIFIED: the post's author must equal owner."),
    },
  },
  async ({ channel, ruling, because, revoked_by, owner, grant_ref }) => {
    if (!SELF) return needSelf();
    const claimedOwner = owner || SELF;

    // OWNER is the one assurance field that CAN be validated, so it is.
    // Unvalidated, it converts an INVENTED ruling into an ATTRIBUTED one --
    // worse than prose, because it now looks sourced. The issuer must BE the
    // owner, or must cite the grant. No third option.  (ipsum-admin, measured: it
    // issued a ruling "owned by the operator" that the operator never made.)
    let provenance;
    if (claimedOwner === SELF) {
      provenance = `**OWNER** ${SELF} _(issuer — self-attributed, VERIFIED: this tool knows who called it)_`;
    } else {
      if (!grant_ref) {
        return text(
          `⛔ REFUSED: you named '${claimedOwner}' as owner but you are '${SELF}'.\n\n` +
            `A ruling attributed to someone who did not issue it is worse than an\n` +
            `unattributed one — it looks sourced. Either own it yourself, or pass\n` +
            `grant_ref: the post id where ${claimedOwner} actually made this call.`
        );
      }
      let grant;
      try {
        const g = await cv.forumGet(grant_ref, false);
        grant = g?.post ?? g;
      } catch (e) {
        return text(`⛔ REFUSED: grant_ref #${grant_ref} could not be read (${String(e.message || e)}). Nothing was written.`);
      }
      if (grant?.author !== claimedOwner) {
        return text(
          `⛔ REFUSED: grant_ref #${grant_ref} was written by '${grant?.author ?? "unknown"}', not '${claimedOwner}'.\n` +
            `The citation does not support the attribution. Nothing was written.`
        );
      }
      provenance = `**OWNER** ${claimedOwner} _(VERIFIED against #${grant_ref}, authored by ${claimedOwner}; recorded by ${SELF})_`;
    }

    const when = new Date().toISOString();
    const body = [
      `**RULING** ${ruling}`,
      "",
      provenance,
      `**DATED** ${when}`,
      `**REVOKED BY** ${revoked_by}  _(ASSERTED — not verified)_`,
      "",
      `**BECAUSE** ${because}`,
      "",
      `_A ruling is not a fact. It carries no command and must not be cited as measured._`,
    ].join("\n");
    const r = await cv.forumPost(SELF, channel, body, undefined, {
      title: `RULING: ${clip(ruling, 90)}`,
      status: "active",
      owner: claimedOwner,
    });
    const id = r?.post?.id ?? r?.id;
    return text(`ruling #${id} recorded in #${channel}, owner ${claimedOwner} (provenance verified), dated ${when}.`);
  }
);

server.registerTool(
  "cv_task_add",
  {
    description:
      "Create a TASK a runner can claim. Sets status=incoming explicitly — a post created without a status has status NULL and is INVISIBLE to a runner's queue query, which fails silently and looks exactly like an empty queue. Put tasks in their own channel: a runner must never have to guess whether an unowned post is a task or a fact.",
    inputSchema: {
      channel: z.string().describe("tasks channel slug — should contain ONLY tasks"),
      title: z.string().describe("short task headline"),
      body: z.string().describe("the brief: what to do, and what would count as done"),
      acceptance: z.string().describe("how the result will be judged — state it up front, not after"),
    },
  },
  async ({ channel, title, body, acceptance }) => {
    if (!SELF) return needSelf();
    const full = [body, "", "── ACCEPTANCE ──", acceptance].join("\n");
    const r = await cv.forumPost(SELF, channel, full, undefined, {
      title,
      status: "incoming",
    });
    const id = r?.post?.id ?? r?.id;
    // Verify through the queue's own query — creating a task a runner cannot
    // see is the failure this tool exists to prevent, and it is silent.
    let claimable = false;
    try {
      const q = await cv.forumRead(channel, { status: "incoming", limit: 50, compact: true });
      claimable = (q?.posts ?? []).some((p) => p.id === id);
    } catch {}
    return text(
      claimable
        ? `task #${id} created in #${channel} and VERIFIED visible to a runner's queue query.`
        : `⚠️ task #${id} created but it does NOT appear in a status=incoming query of #${channel}. No runner will claim it. Investigate before relying on it.`
    );
  }
);

server.registerTool(
  "cv_task_done",
  {
    description:
      "Signal that your task is COMPLETE. This is the ONLY thing that tells a runner it may reap you — going idle does NOT, because an idle seat that has finished and one that is mid-thought are indistinguishable. REFUSES until you have written a handoff: your context is about to be destroyed and it is the only state that survives.",
    inputSchema: {
      task_id: z.number().int().describe("the task post id you were assigned"),
      outcome: z.string().describe("what you did and what the result was — including 'could not do it', which is a valid outcome"),
      ledger_delta: z
        .string()
        .describe(
          "the facts you recorded and the corrections you made, by id. CORRECTIONS COUNT AT FULL WEIGHT — retracting or narrowing an existing fact is as complete an outcome as adding one. 'none, and here is why' is acceptable; silence is not."
        ),
      unresolved: z
        .string()
        .describe("what you did NOT settle, and what the next worker would need. An empty answer here is almost always wrong."),
    },
  },
  async ({ task_id, outcome, ledger_delta, unresolved }) => {
    if (!SELF) return needSelf();

    // HARVEST GATE. A worker about to be reaped has one job left: leave its
    // state somewhere that outlives it. Enforced here rather than trusted,
    // because the seats that most need this rule are the ones mid-task who
    // believe they will "write it up after".
    let hv;
    try {
      const h = await cv.handoffGet(SELF);
      hv = h?.handoff;
    } catch {
      hv = null;
    }
    if (!hv) {
      return text(
        `⛔ REFUSED — you have no handoff.\n\n` +
          `Completing this task makes you reapable, and your context is your only\n` +
          `state. Write it with cv_handoff_set FIRST: what you did, what you would\n` +
          `qualify, and what the next worker needs. Then call cv_task_done again.`
      );
    }

    const body = [
      `**TASK COMPLETE** — ${SELF}`,
      "",
      `**OUTCOME** ${outcome}`,
      "",
      `**LEDGER DELTA** ${ledger_delta}`,
      "",
      `**UNRESOLVED** ${unresolved}`,
      "",
      `_handoff v${hv.version} present (updated ${hv.updated_at}) — this seat is safe to reap._`,
    ].join("\n");

    // ⛔ THE TASK IS THE THING TO COMPLETE — not the forum post with the same id.
    //
    // This used to call forumSetStatus(task_id, "done") and then VERIFY by
    // re-reading that forum post's status. It passed, truthfully, about the
    // wrong object: the TASK stayed RUNNING with completed_at NULL forever.
    // A leftover from the forum-task era, invisible because both id spaces are
    // small integers so nothing ever errored.
    //
    // MEASURED 2026-09-11: #12 and #15 both reported "marked DONE and verified"
    // and both sat RUNNING in `tasks` with no DONE event. Consequences compound:
    // the lane reads as FED so the starvation monitor is structurally blind to
    // it, and a BLOCKS gate can NEVER release because it clears on DONE.
    const r = await cv.taskComplete(task_id, {
      worker: SELF,
      outcome,
      ledger_delta,
      unresolved,
    });

    if (r?._failed) {
      // A FORUM-SOURCE runner (the default --task-source) hands out forum posts,
      // not task rows, and reaps on the POST's status. The task table has no row
      // for such a task, so the call above 404s and — before this branch — the
      // report and status write below were never reached: every forum-source
      // worker stranded. MEASURED 2026-09-28: ipsum-w6-t27905 held its slot ~7.5 h
      // after parking #27905, "no task 27905"; all four ipsum-fleet runners are forum-source.
      //
      // The 2026-09-11 rule above still holds: never complete a forum post just
      // because it shares an integer with the task you meant. So this fires only
      // on "no such task" AND a post this caller is the recorded OWNER of — the
      // owner is written by the claiming runner, so it cannot name the wrong post.
      if (r._status === 404) {
        let post = null;
        try {
          post = (await cv.forumGet(task_id, false))?.post ?? null;
        } catch {}
        if (post && post.owner === SELF && post.status !== "done" && !post.parent_id) {
          try {
            await cv.forumPost(SELF, post.channel, body, task_id, { title: `DONE — ${clip(outcome, 70)}` });
            await cv.forumSetStatus(task_id, "done");
          } catch (e) {
            return text(
              `⚠️ forum task #${task_id} completion FAILED: ${String(e.message || e)}\n` +
                `The post is NOT marked done and you will NOT be reaped. Do not exit — report this.`
            );
          }
          // Verify through the reader the forum-source runner uses.
          let after = null;
          try {
            after = (await cv.forumGet(task_id, false))?.post?.status ?? null;
          } catch {}

          // A VALIDATION's replies ping nobody: the runner authors the VALIDATE
          // post as its slot, so the slot is that thread's only subscriber and no
          // session reads a slot's pings. The manager who authored the VALIDATED
          // task #N is subscribed to #N's thread, so the verdict is also posted
          // there. MEASURED 2026-09-28: ipsum-admin had to nudge ipsum-orchestrator by hand that
          // validator #28108 had finished.
          let notifyNote = "";
          const m = /^VALIDATE #(\d+)\b/.exec(post.title || "");
          if (m && after === "done") {
            const origId = Number(m[1]);
            try {
              const orig = (await cv.forumGet(origId, false))?.post;
              if (orig?.channel && !orig.parent_id) {
                await cv.forumPost(
                  SELF,
                  orig.channel,
                  `**VALIDATION of #${origId} FINISHED** — ${SELF}, on #${task_id}.\n\n` +
                    `**OUTCOME** ${outcome}\n\n**UNRESOLVED** ${unresolved}\n\n` +
                    `Full report and evidence: the #${task_id} thread.`,
                  origId,
                  { title: `VALIDATION DONE — #${task_id}: ${clip(outcome, 60)}` }
                );
                notifyNote = ` The verdict was also posted on #${origId}'s thread, so its author is pinged.`;
              } else {
                notifyNote = ` ⚠️ #${origId} is not a top-level forum post, so its author was NOT notified — tell them.`;
              }
            } catch (e) {
              notifyNote = ` ⚠️ could not post the verdict on #${origId} (${String(e.message || e)}), so its author was NOT notified — tell them.`;
            }
          }

          return text(
            after === "done"
              ? `forum task #${task_id} is done, verified by re-read (no task-table row exists; this is a forum-source task you own). Handoff v${hv.version} is in place; the runner may now reap this seat.${notifyNote}`
              : `⚠️ forum task #${task_id} was written but re-reads as ${JSON.stringify(after)}, not done. The runner will not reap you. Investigate before exiting.`
          );
        }
      }
      return text(
        `⚠️ task #${task_id} completion FAILED: ${JSON.stringify(r.error)}\n` +
          `The task is NOT marked done and you will NOT be reaped. Do not exit — report this.`
      );
    }

    // The REPORT is a side effect: if it fails the task is still complete; say so.
    //
    // ⛔ It must NOT go to the forum post that shares this task's number. This
    // block used to forumGet(task_id), reply there and set that post "done" —
    // the same id-space defect the 2026-09-11 comment above fixed for the
    // completion itself. Task and forum ids are separate sequences, so every
    // task-path report landed on an unrelated old thread, pinged its old
    // subscribers, and flipped that post's status. MEASURED 2026-09-28: lorem-fleet task
    // #889's DONE report is a reply to forum post #889, a June tester status post.
    //
    // So the report goes (a) onto the TASK as a PROGRESS event, which
    // cv_task_show renders and nothing can misfile, and (b) as a TOP-LEVEL post
    // in the task's lane channel, titled with the task number, which pings that
    // channel's subscribers.
    let reportNote = "";
    let lane = null;
    try {
      lane = (await cv.taskShow(task_id))?.task?.lane ?? null;
    } catch {}
    const ev = await cv
      .taskProgress(task_id, { worker: SELF, detail: body })
      .catch((e) => ({ _failed: true, error: String(e.message || e) }));
    if (ev?._failed) reportNote += `\n⚠️ the task IS complete, but recording the report on it failed: ${JSON.stringify(ev.error ?? ev._status)}`;
    // CV_TASK_REPORT=notify (set in a fleet's worker mcp.json) replaces the
    // forum copy with a one-line direct ping from source `tasks:<lane>`, which
    // that fleet's managers watch. A finished task is useful once: the record
    // is the task event above, not a post every subscriber is pinged about.
    // Operator, 2026-10-02: the forum is for what needs remembering.
    if (lane && process.env.CV_TASK_REPORT === "notify") {
      try {
        await cv.report(`tasks:${lane}`, `DONE task #${task_id} (${SELF}): ${clip(outcome, 160)} — cv_task_show ${task_id}`);
      } catch (e) {
        reportNote += `\n⚠️ the task IS complete and the report is on the task, but the done-ping to tasks:${lane} failed: ${String(e.message || e)}`;
      }
    } else if (lane) {
      try {
        await cv.forumPost(SELF, lane, `${body}\n\nTask #${task_id} (lane ${lane}) — read it with \`cv_task_show ${task_id}\`.`, undefined, {
          title: `DONE — task #${task_id}: ${clip(outcome, 60)}`,
        });
      } catch (e) {
        reportNote += `\n⚠️ the task IS complete and the report is on the task, but posting it to #${lane} failed: ${String(e.message || e)}`;
      }
    } else {
      reportNote += `\n⚠️ the task IS complete, but its lane could not be read, so no forum report was posted. The report is on the task.`;
    }

    // Verify against the TASK, through the same reader the runner uses.
    let state = null;
    try {
      state = (await cv.taskShow(task_id))?.task?.state;
    } catch {}

    return text(
      state === "DONE" || state === "VALIDATED"
        ? `task #${task_id} is ${state}, verified by re-read. Handoff v${hv.version} is in place; the runner may now reap this seat.${reportNote}`
        : `⚠️ task #${task_id} completion returned ok but re-reads as ${JSON.stringify(state)}, not DONE. The runner will not reap you. Investigate before exiting.${reportNote}`
    );
  }
);


// ============================================================================
// KNOWLEDGE STORE — cv_doc_*
//
// Durable, versioned, ANCHORED documents. Distinct from the forum on purpose:
// a post is a MOMENT, a document is a CURRENT BEST STATEMENT. Documents are
// returned WHOLE — the ~1,500-char cap is a feed affordance, and applying it
// to a document drops exactly the bound/derived_under fields that qualify a
// claim, because the cut is tail-biased.
// ============================================================================

server.registerTool(
  "cv_doc_put",
  {
    description:
      "Create a knowledge DOCUMENT — durable, versioned, anchored, and NOT truncated on read (unlike a forum post). kind=FACT requires a command that RE-DERIVES the claim and the output that would show it FALSE: a check with no reachable negative is decoration. ⛔ A FACT may be revised but NEVER silently: revision count and author ride on the default read, so a drifted citation announces itself. Use a RELATION (prefer NARROWS) when the claim turned out WRONG; use a revision to attach scope or evidence it was filed without. ASSERTED->DEMONSTRATED requires demonstrated_by. ⛔ There is no STATUS kind: status is DERIVED from facts, never stored, because a written-down status goes stale and becomes a second source of truth. Anchor on the ADDRESS, not the name — names are aliases and a rename must not orphan the knowledge.",
    inputSchema: {
      kind: z.enum(["FACT", "RULING", "NOTE", "TOPIC", "PROCEDURE"]),
      scope: z.string().describe("'fleet' for operational knowledge every fleet shares (shimmed grep, runner semantics), or 'project:<name>' for knowledge about one codebase"),
      title: z.string(),
      slug: z.string().describe("stable identifier, kebab-case"),
      body_md: z.string().describe("the document, in markdown. No length cap."),
      author: z.string(),
      fact_command: z.string().optional().describe("FACT only: the command that RE-DERIVES this. Record the command, never just its output."),
      fact_fails_when: z.string().optional().describe("FACT only: the output that would show the claim is FALSE."),
      fact_fails_when_status: z.enum(["DEMONSTRATED", "ASSERTED"]).optional()
        .describe("DEMONSTRATED = you have SEEN it produce that failure. ASSERTED = you only believe it would — and an ASSERTED fact is NEVER swept green, it reports as untested until someone demonstrates the failing arm."),
      ruling_revoked_by: z.string().optional()
        .describe("RULING only: the OBSERVABLE that retires this ruling. Without one a ruling outlives its cause and nobody notices. Name what someone would have to SEE, not a date."),
      fact_bound: z.string().optional()
        .describe("FACT only: what this does NOT establish — sample size, the conditions it was measured under, what the instrument CANNOT see. A claim with no stated bound gets read wider than it was measured."),
      fact_derived_under: z.string().optional()
        .describe("FACT only: the commit/build/region the measurement was taken at. A number without its anchor cannot be re-derived or aged."),
      demonstrated_by: z.string().optional()
        .describe("FACT only, and REQUIRED when fails_when_status=DEMONSTRATED: how you saw the check produce its failure — the mutation you injected, the control that fired. Without it, DEMONSTRATED is an unbacked assertion that reports green."),
      anchors: z.array(z.object({ type: z.string(), value: z.string() })).optional()
        .describe("what this is ABOUT: {type:'address',value:'0x00336B88'}, unit, symbol, build, sha, tool."),
    },
  },
  async (args) => {
    const r = await cv.kbCreate(args);
    if (r._failed) return text(`error (${r._status}): ${JSON.stringify(r.error)}`);
    const d = r.document;
    return text(`recorded ${d.kind} #${d.id} '${d.slug}' — ${d.title}`);
  }
);

server.registerTool(
  "cv_doc_get",
  {
    description:
      "Fetch a document by slug or id, WHOLE. ⭐ Corrections are ALWAYS included — there is deliberately no un-threaded read, so you cannot be handed a claim whose retraction exists but is not shown. For a FACT it also returns sweep_status: untested (ASSERTED — never green), never_run, stale, or fresh.",
    inputSchema: {
      id: z.string().describe("slug or numeric id"),
      with_anchors: z.boolean().optional(),
    },
  },
  async ({ id, with_anchors }) => {
    const r = await cv.kbGet(id, with_anchors);
    if (r._failed) return text(`error (${r._status}): ${JSON.stringify(r.error)}`);
    const d = r.document, rev = r.revision;
    const lines = [
      `${d.kind} #${d.id} '${d.slug}' [${d.scope}] — ${d.title}`,
      r.sweep_status ? `sweep: ${r.sweep_status}` : null,
      rev?.fact_command ? `command: ${rev.fact_command}` : null,
      rev?.fact_fails_when ? `fails_when (${rev.fact_fails_when_status}): ${rev.fact_fails_when}` : null,
      rev?.front_matter?.revoked_by ? `revoked_by: ${rev.front_matter.revoked_by}` : null,
      rev?.front_matter?.demonstrated_by ? `demonstrated_by: ${rev.front_matter.demonstrated_by}` : null,
      rev?.front_matter?.bound ? `bound: ${rev.front_matter.bound}` : null,
      rev?.front_matter?.derived_under ? `derived_under: ${rev.front_matter.derived_under}` : null,
      r.anchors?.length ? `anchors: ${r.anchors.map((a) => `${a.type}:${a.value}`).join(" ")}` : null,
      r.revisions?.count > 1
        ? `⚠️ REVISED — ${r.revisions.count} revisions, latest ${r.revisions.latest}. This is not the claim as first filed; use cv_doc_history to see what changed.`
        : null,
      "",
      rev?.body_md ?? "(no revision)",
    ].filter(Boolean);
    if (r.corrections?.length) {
      lines.push("", `⚠️ ${r.corrections.length} CORRECTION(S) apply to this claim:`);
      for (const c of r.corrections) lines.push(`  ${c.kind} by doc #${c.from_document_id}${c.note ? ` — ${c.note}` : ""}`);
    }
    return text(lines.join("\n"));
  }
);

server.registerTool(
  "cv_doc_revise",
  {
    description:
      "Revise a document IN PLACE — a new revision, not a new document. ⛔ Use this to ATTACH scope, evidence or a bound the claim was filed without, or to raise ASSERTED->DEMONSTRATED. Use cv_doc_relate (prefer NARROWS) when the CLAIM ITSELF turned out wrong: a relation preserves what was cited, a revision does not. Never silent — revision count and author ride on the default read, so a drifted citation announces itself. ASSERTED->DEMONSTRATED requires demonstrated_by in the SAME revision.",
    inputSchema: {
      id: z.union([z.string(), z.number()]).describe("document id or slug"),
      body_md: z.string().describe("the full new body. A revision replaces the body; it does not append."),
      title: z.string().optional(),
      fact_command: z.string().optional().describe("FACT only: the command that RE-DERIVES this."),
      fact_fails_when: z.string().optional().describe("FACT only: the output that would show the claim FALSE."),
      fact_fails_when_status: z.enum(["DEMONSTRATED", "ASSERTED"]).optional(),
      demonstrated_by: z.string().optional().describe("how the failing arm was actually OBSERVED. Required to set DEMONSTRATED."),
      bound: z.string().optional().describe("what you read, what you did NOT read, what the claim does not cover."),
      derived_under: z.string().optional().describe("tree, build, client — the conditions the claim was derived under."),
    },
  },
  async ({ id, body_md, title, fact_command, fact_fails_when, fact_fails_when_status, demonstrated_by, bound, derived_under }) => {
    if (!SELF) return needSelf();

    // ⚠️ POST /revisions does NOT promote these to front_matter the way document
    // CREATE does — it passes params straight through. Sent top-level they 422,
    // which cost three attempts to discover. The asymmetry is the server's; the
    // tool absorbs it so no caller meets it again.
    // ⭐ CARRY THE EXISTING RECORD FORWARD. A revision REPLACES the row; it does
    // not merge. Sending only the field being added therefore does two damaging
    // things, and the second is silent:
    //   1. a FACT revised without its command 422s — "a FACT requires a command
    //      that re-derives it", which is the tool's PRIMARY use case (attaching a
    //      bound to a FACT) failing outright. Measured on FACT #5915.
    //   2. front_matter is overwritten wholesale, so adding a `bound` DELETES an
    //      existing demonstrated_by and derived_under. A revision whose purpose
    //      is to ADD scope would quietly destroy the scope already recorded —
    //      and a DEMONSTRATED claim stripped of its demonstrated_by still reads
    //      as demonstrated.
    // So read the current revision first and override only what was supplied.
    const cur = await cv.kbGet(id, false);
    if (cur?._failed) return text(`error (${cur._status}) reading #${id} before revising: ${JSON.stringify(cur.error)}`);
    const prev = cur?.revision ?? {};
    const prevFront = prev.front_matter ?? {};

    const front = { ...prevFront };
    if (demonstrated_by) front.demonstrated_by = demonstrated_by;
    if (bound) front.bound = bound;
    if (derived_under) front.derived_under = derived_under;

    // Refuse the one combination the store treats as a lie: claiming a failing
    // arm was observed without saying how. The server enforces this on revisions
    // too, but failing here names the missing field instead of returning a
    // changeset error.
    if ((fact_fails_when_status ?? prev.fact_fails_when_status) === "DEMONSTRATED" && !front.demonstrated_by) {
      return text(
        "⛔ DEMONSTRATED requires demonstrated_by in the SAME revision — say how you OBSERVED the failing arm " +
          "(what you seeded, what it printed). Without it the claim reads as tested when it was only asserted."
      );
    }

    const fields = { author: SELF, body_md };
    fields.title = title ?? prev.title ?? undefined;
    fields.fact_command = fact_command ?? prev.fact_command ?? undefined;
    fields.fact_fails_when = fact_fails_when ?? prev.fact_fails_when ?? undefined;
    fields.fact_fails_when_status = fact_fails_when_status ?? prev.fact_fails_when_status ?? undefined;
    for (const k of Object.keys(fields)) if (fields[k] === undefined) delete fields[k];
    if (Object.keys(front).length) fields.front_matter = front;

    const r = await cv.kbAddRevision(id, fields);
    if (r?._failed) {
      const e = JSON.stringify(r.error);
      return text(
        r._status === 409
          ? `refused (${r._status}): ${e}\n⇒ a 409 here usually means the claim itself is wrong rather than under-scoped. Use cv_doc_relate NARROWS/RETRACTS instead — it preserves what was cited.`
          : `error (${r._status}): ${e}`
      );
    }
    const d = r.document ?? r;
    return text(`revised ${d.kind ?? "doc"} #${d.id ?? id} '${d.slug ?? ""}' — now ${d.revision_count ?? "?"} revision(s), author ${SELF}.`);
  }
);

server.registerTool(
  "cv_doc_relate",
  {
    description:
      "Correct or cite a document. ⭐ Prefer NARROWS — the claim survives and its bound shrinks, which is the COMMON case; a retract/keep binary destroys the usual outcome, that a claim was right and smaller than stated. RETRACTS = the claim is dead. SUPERSEDES = replaced by a better-scoped claim. CITES = provenance. Prefer this over revising a FACT whenever the CLAIM turned out wrong — a relation preserves what was cited, a revision replaces it.",
    inputSchema: {
      from_document_id: z.number().int().describe("the correcting/citing document"),
      to_document_id: z.number().int().describe("the document being corrected"),
      kind: z.enum(["NARROWS", "RETRACTS", "SUPERSEDES", "CITES", "ANSWERS"]),
      author: z.string(),
      note: z.string().optional(),
    },
  },
  async (args) => {
    const r = await cv.kbRelate(args);
    if (r._failed) return text(`error (${r._status}): ${JSON.stringify(r.error)}`);
    return text(`${args.kind}: doc #${args.from_document_id} → doc #${args.to_document_id}`);
  }
);

server.registerTool(
  "cv_doc_search",
  {
    description:
      "Full-text search over knowledge documents. ⚠️ A MALFORMED QUERY RETURNS AN ERROR, NOT AN EMPTY LIST — terms containing '-' or '/' are FTS5 operator syntax and must be quoted (\"text/235FE8\"). That distinction is deliberate: 'your query was malformed' and 'no such knowledge exists' must not look the same.",
    inputSchema: {
      q: z.string(),
      limit: z.number().int().optional(),
      scope: z
        .string()
        .optional()
        .describe(
          "restrict to one scope PLUS 'fleet' (shared operational knowledge is always included). One corpus serves several fleets, so an unscoped search returns other projects' documents. Defaults to $CLAUDIVERSE_SCOPE if this seat sets one; pass '*' to search everything. Whatever a filter withholds is COUNTED and reported, never dropped silently."
        ),
    },
  },
  async ({ q, limit, scope }) => {
    const eff = scope ?? process.env.CLAUDIVERSE_SCOPE ?? undefined;
    const r = await cv.kbSearch(q, limit, eff);
    if (r._failed) return text(`⚠️ ${r.error}${r.hint ? ` — ${r.hint}` : ""}\n(this is a QUERY error, not an empty result)`);
    // A scope filter that hides matches without saying so is the same defect as
    // a malformed query returning an empty list: the caller cannot tell "no such
    // knowledge" from "filtered away", and will act on the wrong one.
    const hidden = r.withheld
      ? `\n⚠️ ${r.withheld} further match(es) in OTHER scopes, hidden by scope='${eff}'. Re-run with scope='*' to see them.`
      : "";
    if (!r.results?.length)
      return text(`no documents match ${JSON.stringify(q)} (query was valid)${hidden}`);
    return text(
      r.results.map((d) => `${d.kind} #${d.id} '${d.slug}' [${d.scope}] — ${d.title}`).join("\n") + hidden
    );
  }
);

server.registerTool(
  "cv_doc_anchor",
  {
    description:
      "Everything known about an anchor — an address, unit, symbol, build, sha or tool. ⭐ Addresses normalise, so 0x00336B88, 0x336b88 and 336B88 all resolve to the same anchor, and knowledge anchored at an address SURVIVES A RENAME. That is the property whose absence desynced knowledge from code and broke a master link.",
    inputSchema: {
      type: z.enum(["address", "symbol", "unit", "segment", "build", "sha", "tool", "channel", "fleet"]),
      value: z.string(),
    },
  },
  async ({ type, value }) => {
    const r = await cv.kbAnchor(type, value);
    if (r._failed) return text(`error (${r._status}): ${JSON.stringify(r.error)}`);
    if (!r.documents?.length) return text(`nothing anchored at ${type}:${value}`);
    return text(
      `${r.documents.length} document(s) at ${type}:${value}\n` +
        r.documents.map((d) => `  ${d.kind} #${d.id} '${d.slug}' — ${d.title}`).join("\n")
    );
  }
);

server.registerTool(
  "cv_doc_history",
  {
    description: "The revision chain for a document, oldest first — history and diff come from this chain the way git derives them from commits.",
    inputSchema: { id: z.string() },
  },
  async ({ id }) => {
    const r = await cv.kbHistory(id);
    if (r._failed) return text(`error (${r._status}): ${JSON.stringify(r.error)}`);
    return text(r.revisions.map((v) => `rev #${v.id} by ${v.author} at ${v.inserted_at} (${(v.body_md || "").length} chars)`).join("\n"));
  }
);

server.registerTool(
  "cv_doc_stale",
  {
    description:
      "The staleness worklist: every FACT that is not fresh, with its reason. untested = ASSERTED, its failing arm has never been observed, so it can NEVER be reported green. never_run = no check yet. stale = the last check FAILED or was UNRUNNABLE. This is the feature the current post-based ledger cannot have, because there `command` is prose in a body rather than a column.",
    inputSchema: {},
  },
  async () => {
    const r = await cv.kbStale();
    if (r._failed) return text(`error (${r._status}): ${JSON.stringify(r.error)}`);
    if (!r.count) return text("no stale facts");
    return text(
      `${r.count} fact(s) not fresh:\n` +
        r.stale.map((s) => `  ${s.sweep_status.padEnd(10)} #${s.document.id} '${s.document.slug}' — ${s.document.title}`).join("\n")
    );
  }
);

server.registerTool(
  "cv_address",
  {
    description:
      "⭐ THE LISTING VIEW — everything known at one address: its current name, EVERY alias it has ever had, and the documents anchored there. Addresses normalise, so 0x00336B88, 0x336b88 and 336B88 are the same lookup. Use this instead of guessing which name a function currently goes by.",
    inputSchema: {
      address: z.string().describe("e.g. 0x00336B88 — any spelling"),
      build: z.string().optional().describe("default usa_v200; the same address means different things in different builds"),
    },
  },
  async ({ address, build }) => {
    const r = await cv.kbAddress(address, build);
    if (r._failed) return text(`error (${r._status}): ${JSON.stringify(r.error)}`);
    const cur = r.current_symbol ? r.current_symbol.name : "(unnamed)";
    const dead = (r.aliases || []).filter((a) => !a.current).map((a) => a.name);
    const lines = [
      `0x${r.address} [${r.build}] — ${cur}`,
      dead.length ? `former names: ${dead.join(", ")}` : null,
      r.documents?.length
        ? `\n${r.documents.length} document(s):\n` + r.documents.map((d) => `  ${d.kind} #${d.id} '${d.slug}' — ${d.title}`).join("\n")
        : "\nno documents anchored here",
    ].filter(Boolean);
    return text(lines.join("\n"));
  }
);

server.registerTool(
  "cv_symbol_record",
  {
    description:
      "Record the name an address CURRENTLY has. If a different name was current, that row is CLOSED rather than overwritten — so a document written under the old spelling stays findable by it. Renaming without this is how knowledge desyncs from code: commit bb754675 renamed asm glabels and broke a master link for days.",
    inputSchema: {
      address: z.string(),
      name: z.string(),
      build: z.string().optional(),
      recorded_by: z.string(),
      source_sha: z.string().optional().describe("the commit that made this name true"),
    },
  },
  async (a) => {
    const r = await cv.kbRecordSymbol(a);
    if (r._failed) return text(`error (${r._status}): ${JSON.stringify(r.error)}`);
    return text(`0x${r.symbol.address} [${r.symbol.build}] is now '${r.symbol.name}'`);
  }
);

server.registerTool(
  "cv_symbol_resolve",
  {
    description:
      "Resolve a name to its address(es) — INCLUDING names that are no longer current. Searching a DEAD spelling still finds the address, which is the whole reason names are stored as intervals rather than overwritten.",
    inputSchema: { name: z.string(), build: z.string().optional() },
  },
  async ({ name, build }) => {
    const r = await cv.kbResolveSymbol(name, build);
    if (r._failed) return text(`error (${r._status}): ${JSON.stringify(r.error)}`);
    if (!r.addresses?.length) return text(`no address recorded for '${name}'`);
    return text(r.addresses.map((a) => `0x${a.address} [${a.build}] ${a.current ? "(current)" : "(FORMER name)"}`).join("\n"));
  }
);

// --- scheduled prompts --------------------------------------------------------
// A cron kept by the server: it outlives restarts, compactions and deploys
// (Claude Code's CronCreate lasts one session, at most 7 days). A seat manages
// only schedules that target itself. Refusals read as refusals, and a prompt
// is never cut (cv-schedules.mjs).
currentGroup = "full";
if (DYNAMIC || ROLE !== "worker") {
const scheduleRef = z.union([z.number().int(), z.string()]).describe("the schedule's id or name");

server.registerTool(
  "cv_schedule_add",
  {
    description:
      "Schedule a prompt to this seat on a cron, kept by the server: it survives restarts, compactions and deploys, with no expiry. A due time missed while the server was down fires once, marked LATE; a prompt for a seat that is not running is held until it is. The prompt must be SELF-CONTAINED (it may reach a brand-new seat with no context): up to 20,000 characters, stored and delivered exactly.",
    inputSchema: {
      name: z.string().describe("short and unique, e.g. weekly-review (A-Z a-z 0-9 . _ -)"),
      cron: z.string().describe("5 fields, minute hour day-of-month month day-of-week, e.g. '0 12 * * 0' = Sundays 12:00"),
      tz: z.string().optional().describe(`IANA zone the cron is read in (default ${sched.DEFAULT_TZ}); 12:00 stays 12:00 local across DST`),
      prompt: z.string().describe("the whole brief, up to 20,000 characters"),
      target: z.string().optional().describe("the seat title; defaults to this seat, and a seat can only target itself"),
    },
  },
  async ({ name, cron, tz, prompt, target }) => {
    const r = await cv.scheduleAdd({ self: SELF ?? undefined, name, cron, tz: tz || sched.DEFAULT_TZ, prompt, target });
    return text(sched.refusal(r, `schedule ${name}`) ?? sched.added(r.schedule, prompt));
  }
);

server.registerTool(
  "cv_schedule_list",
  {
    description: "This seat's scheduled prompts with their next fire times, and each prompt's length, sha256 and first 120 characters. full=true prints every prompt in full.",
    inputSchema: {
      target: z.string().optional().describe("an app token may list another seat's; a seat sees its own"),
      full: z.boolean().optional(),
    },
  },
  async ({ target, full }) => {
    const r = await cv.scheduleList(SELF ?? undefined, target, full);
    const no = sched.refusal(r, "list schedules");
    if (no) return text(no);
    if (!r.schedules.length) return text("no schedules");
    return text(r.schedules.map((s) => sched.scheduleLine(s) + (full ? "\n" + sched.fullPrompt(s) : "")).join("\n\n"));
  }
);

server.registerTool(
  "cv_schedule_get",
  {
    description: "One scheduled prompt with its FULL stored text, verbatim, and its sha256 to check it against.",
    inputSchema: { schedule: scheduleRef },
  },
  async ({ schedule }) => {
    const r = await cv.scheduleGet(SELF ?? undefined, schedule);
    return text(sched.refusal(r, `read schedule ${schedule}`) ?? sched.scheduleLine(r.schedule) + "\n" + sched.fullPrompt(r.schedule));
  }
);

for (const [tool, enabled, verb] of [["cv_schedule_pause", false, "pause"], ["cv_schedule_resume", true, "resume"]]) {
  server.registerTool(
    tool,
    {
      description:
        enabled
          ? "Resume a paused schedule. It fires next at its next time from now; occurrences missed while paused do not fire late."
          : "Pause a schedule: it stops firing, and a prompt it holds for its seat waits until it is resumed.",
      inputSchema: { schedule: scheduleRef },
    },
    async ({ schedule }) => {
      const r = await cv.scheduleUpdate(SELF ?? undefined, schedule, { enabled });
      return text(sched.refusal(r, `${verb} schedule ${schedule}`) ?? `${verb}d: ${sched.scheduleLine(r.schedule)}`);
    }
  );
}

server.registerTool(
  "cv_schedule_remove",
  {
    description: "Delete a scheduled prompt and its run history.",
    inputSchema: { schedule: scheduleRef },
  },
  async ({ schedule }) => {
    const r = await cv.scheduleRemove(SELF ?? undefined, schedule);
    return text(sched.refusal(r, `remove schedule ${schedule}`) ?? `removed schedule #${r.deleted.id} ${r.deleted.name}`);
  }
);

server.registerTool(
  "cv_schedule_runs",
  {
    description: "A schedule's run history, newest first: each firing's due and fired time, LATE, its status (delivered, queued for a busy seat, waiting_for_seat, superseded) and the sha256 of the prompt it delivered.",
    inputSchema: { schedule: scheduleRef, limit: z.number().int().optional().describe("default 50") },
  },
  async ({ schedule, limit }) => {
    const r = await cv.scheduleRuns(SELF ?? undefined, schedule, limit);
    const no = sched.refusal(r, `read the runs of schedule ${schedule}`);
    if (no) return text(no);
    const head = sched.scheduleLine(r.schedule);
    return text(r.runs.length ? head + "\n" + r.runs.map(sched.runLine).join("\n") : head + "\nno runs yet");
  }
);
}
currentGroup = "all";

// --- the tool policy --------------------------------------------------------
// Which groups a role may use: a runner's worker only reports and shares the
// forum and ledger; a delegate also drives; notify only where allowed.
function applyPolicy(role, canNotify) {
  for (const { tool, group } of tagged) {
    const on = allowedGroup(group, role, canNotify);
    if (tool.enabled !== on) on ? tool.enable() : tool.disable();
  }
}

if (DYNAMIC) applyPolicy(ROLE, CAN_NOTIFY);

// Ask the server who this is and what it may use: by title when the launcher
// named the seat, else by Claude's session id. The seat registers itself at
// startup (the mod or the patched sidecar), possibly after this server
// starts, so a miss is retried: every 2 s for the first minute, then every
// 30 s. Once it answers, the identity and the policy are the server's.
//
// Then, for a seat whose policy is the server's (DYNAMIC), it asks again every
// minute: the operator can change a seat's access from the apps
// (POST /api/sessions/:id/access), and a /rename changes its title, both
// without a restart. The refresh asks by Claude's session id when there is
// one (a title can change under it).
async function resolveSeat() {
  const sid = process.env.CLAUDE_CODE_SESSION_ID;
  const query = SELF ? "title=" + encodeURIComponent(SELF) : sid ? "claude_session_id=" + encodeURIComponent(sid) : null;
  if (!query) return;
  for (let attempt = 0; ; attempt++) {
    const seat = await cv.whoami(query).catch(() => null);
    if (seat && !seat._failed && seat.title) {
      if (!SELF) SELF = seat.title;
      if (DYNAMIC) {
        applyPolicy(seat.role || ROLE, seat.can_notify === true);
        refreshPolicy(sid ? "claude_session_id=" + encodeURIComponent(sid) : "title=" + encodeURIComponent(SELF));
      }
      return;
    }
    await new Promise((r) => setTimeout(r, attempt < 30 ? 2000 : 30000));
  }
}

function refreshPolicy(query) {
  setInterval(async () => {
    const seat = await cv.whoami(query).catch(() => null);
    if (!seat || seat._failed || !seat.title) return; // keep the last policy
    // A launcher-named seat keeps its name; a self-named one follows /rename.
    if (seat.title !== SELF && !process.env.CLAUDIVERSE_SELF && !process.env.CLAUDIVERSE_TITLE) SELF = seat.title;
    applyPolicy(seat.role || ROLE, seat.can_notify === true);
  }, POLICY_REFRESH_MS).unref();
}

await server.connect(new StdioServerTransport());
resolveSeat();
