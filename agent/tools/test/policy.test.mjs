// node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import { allowedGroup } from "../cv-policy.mjs";

test("a basic seat (worker) gets reporting and shared tools, not the orchestrator set", () => {
  assert.equal(allowedGroup("report", "worker", false), true);
  assert.equal(allowedGroup("full", "worker", false), false);
  assert.equal(allowedGroup("notify", "worker", false), false);
  assert.equal(allowedGroup("other", "worker", false), true);
});

test("notify follows the right to page, whatever the role (a basic seat granted notify)", () => {
  assert.equal(allowedGroup("notify", "worker", true), true);
  assert.equal(allowedGroup("notify", "orchestrator", true), true);
  assert.equal(allowedGroup("notify", "orchestrator", false), false);
  assert.equal(allowedGroup("notify", "delegate", false), false);
});

test("orchestrator and delegate unchanged", () => {
  assert.equal(allowedGroup("full", "orchestrator", false), true);
  assert.equal(allowedGroup("report", "orchestrator", false), false);
  assert.equal(allowedGroup("full", "delegate", false), true);
  assert.equal(allowedGroup("report", "delegate", false), true);
});
