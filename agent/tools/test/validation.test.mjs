// node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import { validationExemption, isValidationTask } from "../cv-validation.mjs";

test("a production row that merely uses the words gets its validator (#1750)", () => {
  // Shaped like #1750's title ("… re-check its tip …"), skipped on 2026-10-07:
  // the old case-insensitive /\bRE-CHECK\b/i exempted it.
  assert.equal(validationExemption({ id: 1750, title: "198FA0: promote the last two and re-check its tip against master" }), null);
  assert.equal(validationExemption({ id: 1, title: "validate the arena regen after rebase" }), null);
  assert.equal(validationExemption({ id: 2, title: "CLOSE SHORT tail of 1CA080 (free text, not a validator)" }), null);
});

test("real validations are exempt", () => {
  assert.match(validationExemption({ title: "VALIDATE #1720 — PumpDialogVoiceSystem" }), /title/);
  assert.match(validationExemption({ title: "⛔ NOT lorem-w4 … — VALIDATE #1224" }), /title/);
  assert.match(validationExemption({ title: "CASE (b) VALIDATE #1197 on the rebased tip" }), /title/);
  assert.match(validationExemption({ title: "re-check of #1750", validatesTaskId: 1750 }), /validates_task_id=1750/);
});

test("gates and opted-out rows are exempt; the number is required in a mid-title match", () => {
  assert.match(validationExemption({ title: "f-127 POST-LANDING GATE" }), /gate/);
  assert.match(validationExemption({ title: "analysis", body: "… NO-AUTO-VALIDATE …" }), /NO-AUTO-VALIDATE/);
  assert.equal(validationExemption({ title: "write the VALIDATE step into the brief" }), null);
});

test("isValidationTask is unchanged: the row field or the prefix", () => {
  assert.equal(isValidationTask({ title: "VALIDATE #5 — x" }), true);
  assert.equal(isValidationTask({ title: "x", validatesTaskId: 5 }), true);
  assert.equal(isValidationTask({ title: "re-check x" }), false);
});

test("a task from the runner's explicit validation lane gets none; production still does (#1785)", () => {
  const lanes = { validateLane: "lorem-analysis" };
  // #1776: a gate-discharge row in the validator lane, titled without "VALIDATE #n".
  assert.match(validationExemption({ id: 1776, title: "OBJDIFF UNIT-REPORT DISCHARGE (M1-only): 11 promotions", lane: "lorem-analysis" }, lanes), /validation lane #lorem-analysis/);
  assert.equal(validationExemption({ id: 1768, title: "P2 PROMOTE 16E980", lane: "lorem-tasks-deep" }, lanes), null);
  // No explicit validation lane: nothing is inferred, even for the runner's own lane.
  assert.equal(validationExemption({ id: 1776, title: "OBJDIFF UNIT-REPORT DISCHARGE", lane: "lorem-analysis" }), null);
});
