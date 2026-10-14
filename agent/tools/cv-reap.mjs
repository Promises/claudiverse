// What the runner reads off a finished task as it reaps it: the worker's
// declared outcome, and which of the continuations parked on it still stand.
// Split out of cv-runner so it can be tested without starting a runner.

import { execFile } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

export const CONTINUE_PREFIX = "CONTINUE #";
const TASK_COMPLETE = "**TASK COMPLETE**";

// The OUTCOME of `worker`'s last TASK COMPLETE, or null. cv_task_done writes
// one: a reply on a forum task, a PROGRESS event on a task-table row.
// `entries`: [{author, body}] in posting order.
export function completionOutcome(entries, worker) {
  const last = entries.filter((e) => e.author === worker && (e.body || "").startsWith(`${TASK_COMPLETE} — ${worker}`)).at(-1);
  if (!last) return null;
  const m = /\*\*OUTCOME\*\*\s*([\s\S]*?)(?:\n\n\*\*LEDGER DELTA\*\*|$)/.exec(last.body);
  return m ? m[1].trim() : null;
}

// Why the parked continuation `reply` must NOT be promoted, or null when it
// stands. `replies`: the task's thread, as cv.forumGet(id, true) gives it.
//
// A continuation is the seat's handover: where it stopped and what comes
// next. It stands while it is the seat's last word before its TASK COMPLETE.
// It does not stand when:
// - it is archived: withdrawn, or already promoted (the runner archives what
//   it promotes, so a second reap cannot promote it again);
// - its seat posted on the task again after it: the seat went on working, so
//   the handover no longer says where the work stopped. MEASURED 2026-10-12:
//   ipsum-w5-t31132 parked CONTINUE #31132 (31170) while blocked, went on once
//   the hold was lifted, posted its GREEN (31179) and completed (31183); the
//   runner promoted 31170 six seconds later into a duplicate task #31185.
//
// Not "a TASK COMPLETE came after it": cv_task_done always posts one after a
// real yield too, so that rule would end every continuation.
export function staleContinuation(reply, replies) {
  if (reply.archived) return "it is archived: withdrawn, or promoted already";
  const later = replies.filter(
    (r) =>
      r.id > reply.id &&
      r.author === reply.author &&
      !(r.body || "").startsWith(TASK_COMPLETE) &&
      !(r.title || "").startsWith(CONTINUE_PREFIX),
  );
  if (later.length) return `its seat posted #${later.map((r) => r.id).join(", #")} after it, so it went on working and the handover no longer stands`;
  return null;
}

// --- will a reaped worker's COMMITS survive? (cv-runner's durability gate) ---
// UNFINISHED IS SAFE; UNSAVED IS NOT.
const git = async (dir, ...args) => {
  try {
    const { stdout } = await execFileP("git", ["-C", dir, ...args]);
    return { ok: true, out: String(stdout).trim() };
  } catch (e) {
    return { ok: false, out: String(e.stderr || e.message || e).trim() };
  }
};

// durable:true  — HEAD is on a remote, or is already an ancestor of origin/master
// durable:false — HEAD exists only here
// durable:null  — could not determine. NOT the same as false, and never treated
//                 as "safe": the caller preserves anyway rather than guessing.
// skipped:true   — the workdir is not a git work tree (a folder that holds
//                 repos): a worker there commits nowhere this can see, so
//                 there is nothing to check, and no alarm. MEASURED 2026-10-14:
//                 a wc3-sim worker whose --workdir held the repos raised "commits
//                 UNVERIFIABLE … rev-parse HEAD failed … treat HEAD as at risk"
//                 having made no commits. A REPO whose rev-parse fails still alarms.
// `before`: refsAt(dir) at the spawn. Only commits made since then are the
// worker's: HEAD's commits that no ref held at the spawn and no remote has.
// MEASURED 2026-10-14: wc3-sim workers start on a branch whose HEAD is local
// and unpushed ON PURPOSE (its repo is public), and every reap reported that
// HEAD "NOT PUSHED … Push that ref" though the worker had made no commits.
export const commitsDurable = async (dir, before = null) => {
  const tree = await git(dir, "rev-parse", "--is-inside-work-tree");
  if (!tree.ok && /not a git repository/i.test(tree.out))
    return { durable: null, skipped: true, why: `workdir ${dir} is not a git repo; commit check skipped` };
  const head = await git(dir, "rev-parse", "HEAD");
  if (!head.ok) return { durable: null, why: `rev-parse HEAD failed: ${head.out}` };
  const sha = head.out;
  await git(dir, "fetch", "origin", "--quiet"); // stale remotes would fail CLOSED, which is the safe direction
  if (Array.isArray(before) && before.length) {
    const fresh = await git(dir, "rev-list", "--count", sha, "--not", ...before, "--remotes");
    if (!fresh.ok) return { durable: null, sha, why: `rev-list of the commits since the spawn failed: ${fresh.out}` };
    if (fresh.out === "0") return { durable: true, sha, nothingNew: true, why: `no commits since the spawn (HEAD ${sha.slice(0, 8)} was there before the task)` };
  }
  const onRemote = await git(dir, "branch", "-r", "--contains", sha);
  if (!onRemote.ok) return { durable: null, sha, why: `branch -r --contains failed: ${onRemote.out}` };
  if (onRemote.out) return { durable: true, sha, why: `on ${String(onRemote.out).split("\n")[0].trim()}` };
  // No separate "is it an ancestor of the mainline?" test: `branch -r --contains`
  // already lists EVERY remote branch containing the sha, so a merged commit is
  // reported by origin/master itself. An extra merge-base check would add nothing
  // except a hardcoded branch name that is wrong in any repo whose default is not
  // `master` — this file also runs against repos whose default is `main`.
  return { durable: false, sha, why: "on no remote branch" };
};

// Every commit a ref of `dir` points at now (HEAD and each local branch), or
// null outside a repository: what commitsDurable is told existed at the spawn.
export const refsAt = async (dir) => {
  const tree = await git(dir, "rev-parse", "--is-inside-work-tree");
  if (!tree.ok) return null;
  const head = await git(dir, "rev-parse", "HEAD");
  const heads = await git(dir, "for-each-ref", "--format=%(objectname)", "refs/heads");
  return [...new Set([head.ok ? head.out : null, ...(heads.ok ? heads.out.split("\n") : [])].filter((s) => /^[0-9a-f]{40}$/.test(s || "")))];
};

// --- who made the commits since the spawn? (a shared checkout) ---------------
// MEASURED 2026-10-14: wc3-real's workdir is also where standalone-bob
// commits. It committed on main during #2166 and #2169 while the workers,
// which made no commits, ran; each reap wrote a rescue ref and alarmed
// "commits NOT PUSHED". New commits are not the worker's because they are new:
// its transcript says which it made.

// A Bash command that can make a commit: git with any global options, then one of these.
const GIT_WRITES = /\bgit(?:\s+(?:-[Cc]\s+\S+|--?[\w-]+(?:=\S+)?))*\s+(?:commit|merge|cherry-pick|rebase|am|revert|pull)\b/;
// A commit made during a call is dated at most this far outside it (git dates to the second).
const CALL_SLACK_MS = 2_000;
// A call whose result never came (the seat died in it) is taken to have lasted this long.
const OPEN_CALL_MS = 10 * 60_000;

// The transcript files of Claude Code session `sessionId` under `configHome`
// (CLAUDE_CONFIG_DIR, or ~/.claude): projects/<folder>/<id>.jsonl, and its
// subagents' under projects/<folder>/<id>/subagents/. [] when there is none.
export function transcriptFiles(configHome, sessionId) {
  const projects = join(configHome, "projects");
  let folders;
  try {
    folders = readdirSync(projects);
  } catch {
    return [];
  }
  const files = [];
  for (const f of folders) {
    const main = join(projects, f, `${sessionId}.jsonl`);
    if (!existsSync(main)) continue;
    files.push(main);
    try {
      const subs = join(projects, f, sessionId, "subagents");
      for (const s of readdirSync(subs, { recursive: true })) if (String(s).endsWith(".jsonl")) files.push(join(subs, String(s)));
    } catch {}
  }
  return files;
}

const resultText = (c) => (typeof c === "string" ? c : Array.isArray(c) ? c.map((x) => (typeof x === "string" ? x : x?.text || "")).join("\n") : "");

// The Bash calls in transcript `files` that can make a commit, as
// [{command, start, end, output}] (ms; end null when no result came).
export function gitWriteCalls(files) {
  const calls = new Map();
  for (const file of files) {
    for (const line of readFileSync(file, "utf8").split("\n")) {
      let e;
      try {
        e = JSON.parse(line);
      } catch {
        continue;
      }
      const at = Date.parse(e?.timestamp);
      for (const c of Array.isArray(e?.message?.content) ? e.message.content : []) {
        if (c?.type === "tool_use" && c.name === "Bash" && GIT_WRITES.test(String(c.input?.command || "")))
          calls.set(c.id, { command: String(c.input.command), start: at, end: null, output: "" });
        else if (c?.type === "tool_result" && calls.has(c.tool_use_id)) {
          const call = calls.get(c.tool_use_id);
          call.end = at;
          call.output = resultText(c.content);
        }
      }
    }
  }
  return [...calls.values()].filter((c) => Number.isFinite(c.start));
}

// Whether `calls` (gitWriteCalls) made `commit` ({sha, at}): a call printed
// its sha (git commit's "[main 1a2b3c4] …"), or it was made while one ran.
export function madeBy(commit, calls) {
  return calls.some((c) => {
    if ((c.output.match(/\b[0-9a-f]{7,40}\b/g) || []).some((h) => commit.sha.startsWith(h))) return true;
    const end = c.end ?? c.start + OPEN_CALL_MS;
    return commit.at >= c.start - CALL_SLACK_MS && commit.at <= end + CALL_SLACK_MS;
  });
}

const short = (c) => `${c.sha.slice(0, 8)} ${c.subject}`.trim();

// What the reap does about the commits in `dir`: is anything the worker made
// at risk, or against its lane's rules? `before`: refsAt(dir) at the spawn.
// `transcript`: transcriptFiles of the worker's session, or null when its
// session is unknown. `policy`: "allowed" | "forbidden" (the lane's charter
// forbids commits) | "local" (the charter has workers commit and NEVER push:
// someone pushes after validation). Returns {kind, why, sha, mine, foreign}:
//   quiet      — nothing of the worker's is at risk;
//   local      — "local" lane: the worker's own commits are on no remote, as
//                its charter says they should be (sha: the newest);
//   unpushed   — the worker's commits are on no remote (sha: the newest);
//   unverifiable — could not tell (sha: HEAD);
//   violation  — the worker committed in a lane that forbids it (sha: its newest).
// `foreign`: commits since the spawn the worker did not make, to log. A commit
// cannot be attributed without the transcript: then every unpushed one alarms.
export async function commitCheck(dir, before, transcript, policy = "allowed") {
  const dur = await commitsDurable(dir, before);
  const none = { mine: [], foreign: [] };
  if (dur.skipped) return { kind: "quiet", why: dur.why, ...none };
  // Not on nothingNew: that says no commit is at risk, but a pushed one can still break the lane's rule.
  if (!Array.isArray(before) || !before.length || !dur.sha)
    return { kind: dur.durable === true ? "quiet" : dur.durable === false ? "unpushed" : "unverifiable", why: dur.why, sha: dur.sha, ...none };

  const log = await git(dir, "log", "--format=%H %ct %s", dur.sha, "--not", ...before);
  const unpushed = await git(dir, "rev-list", dur.sha, "--not", ...before, "--remotes");
  if (!log.ok || !unpushed.ok) return { kind: "unverifiable", why: `listing the commits since the spawn failed: ${log.ok ? unpushed.out : log.out}`, sha: dur.sha, ...none };
  if (!log.out) return { kind: "quiet", why: dur.why, ...none };
  const atRisk = new Set(unpushed.out.split("\n").filter(Boolean));
  const commits = log.out.split("\n").filter(Boolean).map((l) => {
    const [sha, ct, ...subject] = l.split(" ");
    return { sha, at: Number(ct) * 1000, subject: subject.join(" "), pushed: !atRisk.has(sha) };
  });

  if (!transcript?.length) {
    const risky = commits.filter((c) => !c.pushed);
    if (!risky.length) return { kind: "quiet", why: dur.why, ...none };
    return {
      kind: "unpushed",
      why: `${risky.length} commit(s) since the spawn on no remote (${risky.map(short).join("; ")}); the worker's transcript was not found, so whose they are is unknown`,
      sha: risky[0].sha,
      ...none,
    };
  }
  const calls = gitWriteCalls(transcript);
  const mine = commits.filter((c) => madeBy(c, calls));
  const foreign = commits.filter((c) => !mine.includes(c));
  if (policy === "forbidden" && mine.length)
    return { kind: "violation", why: `it made ${mine.length} commit(s) in a lane whose charter forbids commits: ${mine.map(short).join("; ")}`, sha: mine[0].sha, mine, foreign };
  const risky = mine.filter((c) => !c.pushed);
  if (risky.length && policy === "local")
    return { kind: "local", why: `${risky.length} commit(s) of its own, unpushed as its charter says: ${risky.map(short).join("; ")}`, sha: risky[0].sha, mine, foreign };
  if (risky.length) return { kind: "unpushed", why: `${risky.length} commit(s) of its own on no remote: ${risky.map(short).join("; ")}`, sha: risky[0].sha, mine, foreign };
  return { kind: "quiet", why: mine.length ? `its ${mine.length} commit(s) are on a remote` : "it made no commits", mine, foreign };
}

// A git WORKTREE shares its parent's object store, so a commit made here is
// already in that store — what disappears is the REF, when the slot is reused
// and the branch is reset or deleted. So preservation costs one local ref
// write: no network, no push, no authorship decision taken on a dead seat's
// behalf. Publishing is a human's call; NOT LOSING IT is not.
export const preserveRef = async (dir, worker, sha) => {
  const name = `refs/rescue/${worker}`;
  const r = await git(dir, "update-ref", name, sha);
  return r.ok ? name : null;
};

