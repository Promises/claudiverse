// node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { startupDialog, watchStartup } from "../cv-startup.mjs";

// Panes as tmux captured them from Claude Code 2.1.296: the incident's worker
// (its seat token and paths replaced), a fresh config's first run, and a seat
// at its prompt.
const pane = (name) => fs.readFileSync(new URL(`./fixtures/startup/${name}`, import.meta.url), "utf8");

test("the incident's worker: the trust dialog, quoted from the dialog down, never the launch line above it", () => {
  const d = startupDialog(pane("trust-2.1.296.txt"));
  assert.equal(d.kind, "trust");
  assert.match(d.excerpt, /^Accessing workspace:\n\/Users\/me\/Documents\/projects\/lorem\/lorem-repo\nQuick safety check/);
  assert.match(d.excerpt, /❯ No, exit\nYes, I trust this folder/);
  assert.doesNotMatch(d.excerpt, /FAKEseatTOKEN|CLAUDIVERSE_TOKEN|ANTHROPIC_/);
});

test("a fresh config's first-run setup is a dialog; a seat at its prompt is not", () => {
  assert.equal(startupDialog(pane("first-run-2.1.296.txt")).kind, "first-run setup");
  assert.equal(startupDialog(pane("prompt-2.1.296.txt")), null);
});

test("a worker printing the dialog's words is not at the dialog: all of its lines must show", () => {
  const output = ["⏺ Read(cv-startup.mjs)", '  { kind: "trust", all: [/Quick safety check|…/', "  … 40 more lines", "❯ "].join("\n");
  assert.equal(startupDialog(output), null);
});

test("a dialog is escalated on a second look at least 15 s later, once; one that goes away is forgotten", () => {
  const t0 = 1_000_000, spawned = t0 - 20_000, trust = pane("trust-2.1.296.txt");
  let w = watchStartup(null, trust, t0, spawned);
  assert.equal(w.escalate, null, "one look is not enough: it may be drawing, or answered");
  w = watchStartup(w.seen, trust, t0 + 10_000, spawned);
  assert.equal(w.escalate, null);
  w = watchStartup(w.seen, trust, t0 + 15_000, spawned);
  assert.equal(w.escalate.kind, "trust");
  assert.equal(w.escalate.afterS, 35);
  assert.equal(watchStartup(w.seen, trust, t0 + 30_000, spawned).escalate, null, "once");
  assert.equal(watchStartup(w.seen, pane("prompt-2.1.296.txt"), t0 + 45_000, spawned).seen, null);
});
