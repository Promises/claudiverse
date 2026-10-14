// node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import { completionOutcome, staleContinuation, CONTINUE_PREFIX, commitsDurable, refsAt, commitCheck, transcriptFiles } from "../cv-reap.mjs";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { execFileSync } from "node:child_process";
import { validationExemption } from "../cv-validation.mjs";

const done = (worker, outcome) => ({
  author: worker,
  body: `**TASK COMPLETE** — ${worker}\n\n**OUTCOME** ${outcome}\n\n**LEDGER DELTA** none\n\n**UNRESOLVED** none`,
});

test("the outcome is the worker's last TASK COMPLETE, not anyone else's", () => {
  const entries = [
    done("w5-t1", "first try"),
    { author: "ipsum-admin", body: "**TASK COMPLETE** — ipsum-admin\n\n**OUTCOME** not the worker's" },
    { author: "w5-t1", body: "a progress note" },
    done("w5-t1", "NO-OP. This was a duplicate dispatch."),
  ];
  assert.equal(completionOutcome(entries, "w5-t1"), "NO-OP. This was a duplicate dispatch.");
  assert.equal(completionOutcome([{ author: "w5-t1", body: "no completion here" }], "w5-t1"), null);
});

// Shaped like #31132's thread (2026-10-12): the seat parked CONTINUE #31132
// while blocked, then the hold was lifted (31176, ipsum-admin), it went on and
// posted its GREEN report (31179) and completed (31183). The runner promoted
// 31170 six seconds later: a duplicate seat, and a validator of its no-op.
test("a CONTINUE its seat worked past is stale; one it yielded on stands", () => {
  const cont = { id: 31170, author: "ipsum-w5-t31132", title: `${CONTINUE_PREFIX}31132`, body: "TO CONTINUE: …" };
  const workedPast = [
    cont,
    { id: 31176, author: "ipsum-admin", body: "hold lifted" },
    { id: 31179, author: "ipsum-w5-t31132", body: "GREEN: …" },
    { id: 31183, ...done("ipsum-w5-t31132", "built and verified RED → GREEN") },
  ];
  assert.match(staleContinuation(cont, workedPast), /31179/);

  // A real yield: the report first, the CONTINUE last, then cv_task_done.
  const yielded = [
    { id: 10, author: "w5-t9", body: "what I did so far" },
    { id: 11, author: "w5-t9", title: `${CONTINUE_PREFIX}9`, body: "next: …" },
    { id: 12, author: "ipsum-admin", body: "noted" },
    { id: 13, ...done("w5-t9", "yielded: blocked on #8; continuation parked") },
  ];
  assert.equal(staleContinuation(yielded[1], yielded), null);
});

test("a withdrawn or already promoted CONTINUE (archived) is not promoted again", () => {
  const cont = { id: 11, author: "w5-t9", title: `${CONTINUE_PREFIX}9`, archived: true };
  assert.match(staleContinuation(cont, [cont]), /archived/);
});

test("a finished task whose outcome declares a no-op or duplicate gets no validator", () => {
  assert.match(validationExemption({ id: 31185, title: "CONTINUE #31132" }, { outcome: "NO-OP. This was a duplicate dispatch." }), /no-op/i);
  assert.match(validationExemption({ id: 2, title: "x" }, { outcome: "**DUPLICATE** of #31132" }), /no-op/i);
  // Only a DECLARATION, at the start: a real outcome that mentions the words keeps its validator.
  assert.equal(validationExemption({ id: 3, title: "x" }, { outcome: "Fixed the no-op branch in the duplicate check" }), null);
  assert.equal(validationExemption({ id: 4, title: "x" }, { outcome: null }), null);
});

// Real git, in throwaway folders.
const scratch = () => mkdtempSync(join(tmpdir(), "cv-reap-"));
const gitIn = (dir, ...args) => execFileSync("git", ["-C", dir, "-c", "user.name=test", "-c", "user.email=test@example.com", ...args], { stdio: "pipe" });

test("a workdir that is not a git repo has no commits to check: skipped, not an alarm", async () => {
  const dir = scratch();
  try {
    const r = await commitsDurable(dir);
    assert.equal(r.skipped, true);
    assert.match(r.why, /is not a git repo; commit check skipped/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a repo still alarms: an unpushed commit is not durable, and a HEAD that cannot be read is unverifiable", async () => {
  const dir = scratch();
  try {
    gitIn(dir, "init", "-q");
    const empty = await commitsDurable(dir);
    assert.equal(empty.skipped, undefined, "a repo whose rev-parse HEAD fails is not skipped");
    assert.equal(empty.durable, null);
    assert.match(empty.why, /rev-parse HEAD failed/);

    gitIn(dir, "commit", "-q", "--allow-empty", "-m", "work");
    const local = await commitsDurable(dir);
    assert.equal(local.durable, false);
    assert.match(local.sha, /^[0-9a-f]{40}$/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("only commits made since the spawn are at risk: a branch's own unpushed HEAD is not the worker's", async () => {
  // MEASURED 2026-10-14: a wc3-sim worker made no commits, and the reap said its
  // branch's HEAD (local on purpose: the repo is public) was "NOT PUSHED … Push that ref".
  const dir = scratch();
  try {
    gitIn(dir, "init", "-q", "-b", "sim-backend");
    gitIn(dir, "commit", "-q", "--allow-empty", "-m", "local on purpose");
    gitIn(dir, "branch", "other-local");
    gitIn(dir, "commit", "-q", "--allow-empty", "-m", "also there before the task");
    const before = await refsAt(dir);

    const noop = await commitsDurable(dir, before);
    assert.equal(noop.durable, true);
    assert.equal(noop.nothingNew, true);
    assert.match(noop.why, /no commits since the spawn/);

    gitIn(dir, "checkout", "-q", "other-local");
    assert.equal((await commitsDurable(dir, before)).nothingNew, true, "a branch that existed at the spawn is not new work");

    gitIn(dir, "commit", "-q", "--allow-empty", "-m", "the worker's");
    const work = await commitsDurable(dir, before);
    assert.equal(work.durable, false, "a commit made during the task still alarms");
    assert.equal(work.nothingNew, undefined);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// --- whose commits? A shared checkout (MEASURED 2026-10-14: standalone-bob
// committed on main in wc3-real's workdir during #2166 and #2169; the workers
// made none, and each reap alarmed "commits NOT PUSHED"). ---

const T0 = 1_760_000_000; // seconds
const commitAt = (dir, s, msg) => {
  execFileSync("git", ["-C", dir, "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", msg], {
    env: { ...process.env, GIT_COMMITTER_DATE: `@${s} +0000`, GIT_AUTHOR_DATE: `@${s} +0000` },
  });
  return execFileSync("git", ["-C", dir, "rev-parse", "HEAD"]).toString().trim();
};
const iso = (s) => new Date(s * 1000).toISOString();
// Claude Code transcript lines: an assistant Bash tool_use, then the user's tool_result.
const bash = (id, s, command, output, e = 1) => [
  { type: "assistant", timestamp: iso(s), message: { role: "assistant", content: [{ type: "tool_use", id, name: "Bash", input: { command } }] } },
  { type: "user", timestamp: iso(s + e), message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: output }] } },
];
const SESSION = "0b9a3f4e-6c1d-4f2a-9e8b-7d6c5b4a3f21";

// A repo whose main existed before the spawn, and a config home for its worker's transcript.
function sharedCheckout() {
  const root = mkdtempSync(join(tmpdir(), "cv-reap-shared-"));
  const dir = join(root, "repo");
  mkdirSync(dir);
  gitIn(dir, "init", "-q", "-b", "main");
  commitAt(dir, T0 - 1000, "there before the task");
  const home = join(root, "claude");
  const folder = join(home, "projects", "-repo");
  mkdirSync(folder, { recursive: true });
  const transcript = (lines, file = join(folder, `${SESSION}.jsonl`)) => {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
    return transcriptFiles(home, SESSION);
  };
  return { root, dir, home, folder, transcript };
}

test("a commit someone else made in a shared checkout during the task is logged, not alarmed", async () => {
  const { root, dir, transcript } = sharedCheckout();
  try {
    const before = await refsAt(dir);
    const foreign = commitAt(dir, T0 + 100, "standalone-bob's");
    // The worker ran things, git log included (it printed the foreign sha), but made no commit.
    const files = transcript([...bash("t1", T0, "make sim", "ok"), ...bash("t2", T0 + 200, "git log --oneline -3", `${foreign.slice(0, 7)} standalone-bob's`)]);
    for (const policy of ["allowed", "forbidden"]) {
      const c = await commitCheck(dir, before, files, policy);
      assert.equal(c.kind, "quiet", `${policy}: ${c.why}`);
      assert.deepEqual(c.foreign.map((f) => f.sha), [foreign]);
      assert.deepEqual(c.mine, []);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a commit the worker made (its transcript shows the git commit) alarms; one made beside it is only logged", async () => {
  const { root, dir, transcript } = sharedCheckout();
  try {
    const before = await refsAt(dir);
    const theirs = commitAt(dir, T0 + 10, "someone else's");
    const mine = commitAt(dir, T0 + 100, "the worker's");
    const files = transcript(bash("t1", T0 + 99, "git add -A && git commit -m \"the worker's\"", `[main ${mine.slice(0, 7)}] the worker's`));
    const c = await commitCheck(dir, before, files, "allowed");
    assert.equal(c.kind, "unpushed", c.why);
    assert.equal(c.sha, mine);
    assert.deepEqual(c.mine.map((m) => m.sha), [mine]);
    assert.deepEqual(c.foreign.map((f) => f.sha), [theirs]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a quiet git commit (no sha printed) is the worker's when it was made while that call ran", async () => {
  const { root, dir, transcript } = sharedCheckout();
  try {
    const before = await refsAt(dir);
    const mine = commitAt(dir, T0 + 101, "quiet");
    const files = transcript(bash("t1", T0 + 100, `git -C ${dir} -c user.name=w commit -q -m quiet`, "", 2));
    const c = await commitCheck(dir, before, files, "allowed");
    assert.equal(c.kind, "unpushed", c.why);
    assert.deepEqual(c.mine.map((m) => m.sha), [mine]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("--commits forbidden: a commit the worker made is a CHARTER VIOLATION, pushed or not", async () => {
  const { root, dir, transcript } = sharedCheckout();
  try {
    const remote = join(root, "remote.git");
    execFileSync("git", ["init", "-q", "--bare", remote]);
    gitIn(dir, "remote", "add", "origin", remote);
    gitIn(dir, "push", "-q", "origin", "main");
    const before = await refsAt(dir);
    const mine = commitAt(dir, T0 + 100, "the worker's");
    const files = transcript(bash("t1", T0 + 99, "git commit -am fix", `[main ${mine.slice(0, 7)}] the worker's`));
    const v = await commitCheck(dir, before, files, "forbidden");
    assert.equal(v.kind, "violation", v.why);
    assert.match(v.why, /charter forbids commits/);
    assert.equal(v.sha, mine);

    gitIn(dir, "push", "-q", "origin", "main");
    assert.equal((await commitCheck(dir, before, files, "forbidden")).kind, "violation", "a pushed commit is still a violation");
    assert.equal((await commitCheck(dir, before, files, "allowed")).kind, "quiet", "allowed, and on a remote: nothing at risk");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("--commits local: the worker's own unpushed commit is expected, not an alarm; an unattributed one still alarms", async () => {
  const { root, dir, transcript } = sharedCheckout();
  try {
    const before = await refsAt(dir);
    const mine = commitAt(dir, T0 + 100, "fix: trigger conditions");
    const files = transcript(bash("t1", T0 + 99, "git commit -am fix", `[main ${mine.slice(0, 7)}] fix: trigger conditions`));
    const c = await commitCheck(dir, before, files, "local");
    assert.equal(c.kind, "local", c.why);
    assert.equal(c.sha, mine, "the rescue ref still goes on the worker's newest commit");
    assert.match(c.why, /unpushed as its charter says/);
    assert.equal((await commitCheck(dir, before, files, "allowed")).kind, "unpushed", "the same commit under the default still alarms");
    assert.equal((await commitCheck(dir, before, null, "local")).kind, "unpushed", "without the transcript it is nobody's, so it alarms");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a subagent's commit is the worker's: its transcript is read too", async () => {
  const { root, dir, folder, transcript } = sharedCheckout();
  try {
    const before = await refsAt(dir);
    const mine = commitAt(dir, T0 + 100, "by a subagent");
    transcript(bash("t1", T0, "ls", "a b"));
    const files = transcript(bash("s1", T0 + 99, "git commit -m x", `[main ${mine.slice(0, 7)}] by a subagent`), join(folder, SESSION, "subagents", "agent-a1.jsonl"));
    assert.equal(files.length, 2);
    assert.equal((await commitCheck(dir, before, files, "allowed")).kind, "unpushed");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("without the worker's transcript nothing can be attributed: every new unpushed commit still alarms", async () => {
  const { root, dir, home } = sharedCheckout();
  try {
    const before = await refsAt(dir);
    commitAt(dir, T0 + 100, "whose?");
    assert.deepEqual(transcriptFiles(home, SESSION), []);
    for (const t of [null, []]) {
      const c = await commitCheck(dir, before, t, "forbidden");
      assert.equal(c.kind, "unpushed", "unknown authorship is never a violation, and never quiet");
      assert.match(c.why, /transcript was not found/);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
