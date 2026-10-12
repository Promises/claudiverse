// node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import { footerMode, dialogOpen, CYCLE } from "../lib/mode.mjs";

const rule = "─".repeat(40);
const footer = (line) => `⏺ some answer\n${rule}\n❯ \n${rule}\n  ⚠ claudiverse-seat: claudiverse · x\n  ${line}\n`;

test("the footer names the mode in force; none means default", () => {
  assert.equal(footerMode(footer("⏵⏵ accept edits on (shift+tab to cycle) · ← for agents")), "acceptEdits");
  assert.equal(footerMode(footer("⏸ plan mode on (shift+tab to cycle)")), "plan");
  assert.equal(footerMode(footer("⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt")), "auto");
  assert.equal(footerMode(footer("? for shortcuts")), "default");
  assert.deepEqual(CYCLE, ["default", "acceptEdits", "plan", "auto"]);
});

test("a transcript quoting the words is not the footer", () => {
  const quoted = "⏺ I turned auto mode on (shift+tab to cycle) for you yesterday\n" + "line\n".repeat(10) + footer("? for shortcuts");
  assert.equal(footerMode(quoted), "default");
});

test("an open dialog is seen; a plain prompt is not", () => {
  assert.ok(dialogOpen(footer("? for shortcuts") + " Do you want to proceed?\n ❯ 1. Yes\n Esc to cancel\n"));
  assert.ok(dialogOpen("☐ Colour\n ❯ 1. Red\nEnter to select · ↑/↓ to navigate · Esc to cancel\n"));
  assert.ok(!dialogOpen(footer("⏵⏵ auto mode on (shift+tab to cycle)")));
});
