// Is a worker waiting at a dialog of Claude Code's own, before its first turn?
// cv-runner looks at the worker's pane for the first minutes after a spawn, so
// a seat stopped at "trust this folder?" is escalated in under a minute, not
// after the 30 min CPU-silence rule. Pure; split out of cv-runner for testing.
//
// MEASURED 2026-10-13/14: two runner workers sat 35 min at the trust dialog
// (2.1.296) before the CPU rule fired.

// Each dialog is recognised by several of its own lines, all near the bottom
// of the pane: one phrase alone could be a worker printing a file that
// contains it. Seen on 2.1.296 (the incident's capture, a fresh config).
const DIALOGS = [
  { kind: "trust", all: [/Quick safety check|Do you trust the files in this folder/, /Yes, I trust this folder|Yes, proceed/, /Enter to confirm|Esc to cancel/] },
  { kind: "first-run setup", all: [/Dark mode/, /Light mode/, /To change this later, run \/theme|Choose the text style|Let's get started/] },
  { kind: "login", all: [/Select login method|Choose a login method/, /Claude account|Anthropic Console/] },
  { kind: "bypass-permissions confirmation", all: [/Bypass Permissions mode/, /Yes, I accept|No, exit/] },
];

const TAIL_LINES = 40;
const RULE = /^\s*[─━]{10,}/;
// A dialog's lines carry no secrets, but a quote is redacted anyway.
const SECRET = [
  [/(token|secret|password)(["']?\s*[=:]\s*)\S+/gi, "$1$2[redacted]"],
  [/(Bearer\s+)\S+/g, "$1[redacted]"],
  [/sk-ant-[\w-]+|github_pat_\w+|\bgh[pousr]_\w+/g, "[redacted]"],
];

const redact = (line) => SECRET.reduce((l, [re, to]) => l.replace(re, to), line);

// The dialog `pane` (a capture-pane text) shows, as {kind, excerpt}, or null.
// The excerpt is the dialog itself: from below the rule over it, never the
// shell lines above (a launch line carries a seat token), and redacted.
export function startupDialog(pane) {
  const lines = String(pane ?? "").replace(/\s+$/, "").split("\n").slice(-TAIL_LINES);
  const text = lines.join("\n");
  const dialog = DIALOGS.find((d) => d.all.every((re) => re.test(text)));
  if (!dialog) return null;

  const first = lines.findIndex((l) => dialog.all[0].test(l));
  let start = Math.max(0, first - 4);
  for (let i = first; i >= start; i--) if (RULE.test(lines[i])) { start = i + 1; break; }
  const excerpt = lines
    .slice(start)
    .map((l) => redact(l.trim()).slice(0, 160))
    .filter(Boolean)
    .slice(0, 14)
    .join("\n");
  return { kind: dialog.kind, excerpt };
}

// What a startup watch decides at `now` (ms) from the worker's `pane`, given
// what it saw before (`seen`: {kind, at} or null) and when the worker was
// spawned. A dialog still there on a second look, at least `confirmMs` after
// the first, is escalated, once. Returns {seen, escalate: {kind, excerpt,
// afterS} | null}.
export function watchStartup(seen, pane, now, spawnedAt, confirmMs = 15_000) {
  const d = startupDialog(pane);
  if (!d) return { seen: null, escalate: null };
  if (!seen || seen.kind !== d.kind) return { seen: { kind: d.kind, at: now }, escalate: null };
  if (seen.done || now - seen.at < confirmMs) return { seen, escalate: null };
  return { seen: { ...seen, done: true }, escalate: { ...d, afterS: Math.round((now - spawnedAt) / 1000) } };
}
