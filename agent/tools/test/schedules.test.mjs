// The cv_schedule_* tools: a server refusal reads as a refusal with its
// reason (never as success), and a prompt is shown whole, never cut.
// Run: node test/schedules.test.mjs
// Stubbed server: each call takes the next canned reply and records the request.
import assert from "node:assert/strict";
process.env.CLAUDIVERSE_URL = "http://stub";
const replies = [];
const requests = [];
globalThis.fetch = async (url, init = {}) => {
  requests.push({ url, method: init.method || "GET", body: init.body && JSON.parse(init.body) });
  const r = replies.shift();
  return { status: r.status, ok: r.status < 300, json: async () => r.body };
};
const cv = await import("../cv-core.mjs");
const sched = await import("../cv-schedules.mjs");

// A prompt of 20,000 characters, multi-byte, with line ends and trailing spaces.
const unit = [..."Hei på deg, Æøå! 🙂🚀\r\n\ttab  "];
const prompt = Array.from({ length: 20_000 }, (_, i) => unit[i % unit.length]).join("");
const stored = (text) => ({
  id: 7, name: "weekly-review", target: "ipsum-admin", cron: "0 12 * * 0", tz: "Europe/Oslo", enabled: true,
  next_fire_local: "Sun 2026-10-18 12:00 CEST (Europe/Oslo)", prompt_chars: [...text].length,
  prompt_bytes: Buffer.byteLength(text), prompt_sha256: sched.sha256(text), prompt_preview: [...text].slice(0, 120).join(""),
  prompt: text,
});

// Refusals: each reads as REFUSED with the status and the server's reason.
const refused = [
  [403, { error: "a seat may only schedule prompts for itself: you are ipsum-admin, the target is ipsum-orchestrator" }, /HTTP 403.*may only schedule prompts for itself/],
  [422, { error: "prompt: is 20001 characters; the limit is 20000. Nothing was saved", errors: {} }, /HTTP 422.*20001 characters; the limit is 20000/],
  [422, { error: "cron: must have 5 fields", errors: { cron: ["must have 5 fields"] } }, /HTTP 422.*cron/],
  [400, { error: "which seat? pass self (your seat title); only an app token may omit it" }, /HTTP 400.*pass self/],
  [404, { error: "no schedule nope" }, /HTTP 404.*no schedule nope/],
];
for (const [status, body, expected] of refused) {
  replies.push({ status, body });
  const line = sched.refusal(await cv.scheduleAdd({ self: "ipsum-admin", name: "x" }), "schedule x");
  assert.match(line, /^REFUSED /);
  assert.match(line, expected);
}
for (const call of [() => cv.scheduleUpdate("s", "weekly", { enabled: false }), () => cv.scheduleRemove("s", 7), () => cv.scheduleRuns("s", 7), () => cv.scheduleGet("s", 7), () => cv.scheduleList("s")]) {
  replies.push({ status: 403, body: { error: "schedule weekly targets ipsum-orchestrator; a seat may only manage its own" } });
  assert.match(sched.refusal(await call(), "do it"), /^REFUSED \(HTTP 403\).*may only manage its own/);
}
assert.equal(sched.refusal({ schedule: stored("x") }, "x"), null, "a success is no refusal");

// The requests carry the seat and the change.
assert.deepEqual(requests.at(-5).body, { enabled: false, self: "s" });
assert.equal(requests.at(-5).method, "PATCH");
assert.match(requests.at(-4).url, /\/api\/schedules\/7\?self=s$/);
assert.equal(requests.at(-4).method, "DELETE");

// An add that the server stored exactly says so; one it changed says that loudly.
assert.match(sched.added(stored(prompt), prompt), /stored exactly \(sha256 [0-9a-f]{12}, 20000 chars\)/);
const cut = prompt.slice(0, 1500);
assert.match(sched.added(stored(cut), prompt), /STORED TEXT DIFFERS.*\(20000 chars\).*\(\d+ chars\)/);

// The full prompt is printed verbatim between its marker lines: nothing cut.
const out = sched.fullPrompt(stored(prompt));
const body = out.slice(out.indexOf("\n") + 1, out.lastIndexOf("\n"));
assert.equal(body, prompt);
assert.equal(sched.sha256(body), stored(prompt).prompt_sha256);

// The list line: length, sha and a 120-character preview, marked as cut.
const line = sched.scheduleLine(stored(prompt));
assert.match(line, /20000 chars, \d+ bytes, sha256 [0-9a-f]{12}/);
assert.ok(line.includes(JSON.stringify([...prompt].slice(0, 120).join("")) + "…"));
assert.equal(line.split("\n").length, 2, "line ends in the preview are quoted, not printed");

console.log("cv_schedule_*: refusals read as REFUSED with the server's reason; prompts round-trip whole");
