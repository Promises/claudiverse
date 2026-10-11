// cv-schedules — how cv-mcp's cv_schedule_* tools word the server's answers
// (server: ScheduleController). Kept apart from cv-mcp so it can be tested.
//
// Two rules:
// - A refusal (any 4xx/5xx) reads as one, with the server's reason. Never as
//   success: several cv_* tools once answered "ok" on a 4xx.
// - A prompt is never cut. A schedule may fire into a brand-new seat, so the
//   prompt is the whole brief; the list shows its length, sha256 and a
//   preview, and cv_schedule_get prints it in full.
import { createHash } from "node:crypto";

export const DEFAULT_TZ = "Europe/Oslo";

export const sha256 = (text) => createHash("sha256").update(text, "utf8").digest("hex");
const sha12 = (hex) => (hex || "").slice(0, 12);
const chars = (text) => [...text].length;

// null when the call succeeded; else the line to show.
export function refusal(r, what) {
  if (!r || !r._failed) return null;
  return `REFUSED (HTTP ${r._status}): could not ${what}: ${r.error || JSON.stringify(r.errors || r)}`;
}

export function scheduleLine(s) {
  const state = s.enabled ? "on" : "PAUSED";
  const next = s.enabled && s.next_fire_local ? `next ${s.next_fire_local}` : "no next fire while paused";
  return (
    `#${s.id} ${s.name} → ${s.target} · ${s.cron} (${s.tz}) · ${state} · ${next}\n` +
    `  prompt: ${s.prompt_chars} chars, ${s.prompt_bytes} bytes, sha256 ${sha12(s.prompt_sha256)} · ` +
    // JSON-quoted, so line ends and tabs in the preview stay on one line.
    `${JSON.stringify(s.prompt_preview)}${s.prompt_chars > [...s.prompt_preview].length ? "…" : ""}`
  );
}

// The full prompt, verbatim, between two marker lines. The text between them
// is exactly the stored prompt; its sha256 is printed to check it against.
export function fullPrompt(s) {
  return (
    `----- prompt of ${s.name}: ${s.prompt_chars} chars, sha256 ${s.prompt_sha256}; verbatim between these lines -----\n` +
    s.prompt +
    `\n----- end of prompt of ${s.name} -----`
  );
}

// After an add: did the server store exactly what was sent?
export function added(s, sentPrompt) {
  const mine = sha256(sentPrompt);
  const check =
    mine === s.prompt_sha256 && chars(sentPrompt) === s.prompt_chars
      ? `stored exactly (sha256 ${sha12(mine)}, ${s.prompt_chars} chars)`
      : `⚠️ STORED TEXT DIFFERS from what was sent: sent sha256 ${sha12(mine)} (${chars(sentPrompt)} chars), stored ${sha12(s.prompt_sha256)} (${s.prompt_chars} chars)`;
  return `scheduled: ${scheduleLine(s)}\n${check}`;
}

export function runLine(r) {
  const parts = [`run #${r.id}`, r.status, `due ${r.due_at}`, `fired ${r.fired_at}`];
  if (r.late) parts.push("LATE");
  if (r.delivered_at) parts.push(`delivered ${r.delivered_at} to session ${r.session_id}`);
  else if (r.session_id) parts.push(`seat session ${r.session_id}`);
  if (r.prompt_sha256) parts.push(`sha256 ${sha12(r.prompt_sha256)}`);
  return parts.join(" · ");
}
