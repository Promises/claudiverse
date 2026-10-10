// requestHuman must keep the HTTP status apart from the body's own "status".
// Run: node test/request-human.test.mjs
// Stubbed server: what requestHuman returns for the two real answers.
import assert from "node:assert/strict";
process.env.CLAUDIVERSE_URL = "http://stub";
const replies = [
  { status: 200, body: { id: 3, status: "open" } },
  { status: 403, body: { error: "this seat may not request a human (its launcher does not set CLAUDIVERSE_NOTIFY=1)" } },
];
globalThis.fetch = async () => { const r = replies.shift(); return { status: r.status, ok: r.status < 300, json: async () => r.body }; };
const cv = await import("../cv-core.mjs");
const ok = await cv.requestHuman("ipsum-admin", "s");
assert.equal(ok.http, 200); assert.equal(ok.status, "open"); assert.equal(ok.id, 3);
const no = await cv.requestHuman("ipsum-orchestrator", "s");
assert.equal(no.http, 403); assert.match(no.error, /may not request/);
console.log("requestHuman: success reads as 200/open, refusal as 403 with its error");
