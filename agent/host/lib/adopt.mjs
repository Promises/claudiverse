// Adopt: put a Claude Code seat someone started by hand under a profile, so the
// app can stop, start and restart it. The agent finds the seat's process,
// stops exactly that process, and the server then starts the profile, which
// resumes the same conversation in a tmux session this agent runs.
//
// Finding the process: Claude Code writes <config dir>/sessions/<pid>.json for
// every process it runs (pid, sessionId, cwd, procStart, tmux, status), and
// removes it on exit. The patched binary writes them too (2.1.286, measured).
// procStart is ps's lstart IN UTC: "Sat Oct  3 08:18:54 2026" for a process
// `ps -o lstart=` shows as 10:18:54 in Oslo.
//
// Matching: by conversation id first. A patched seat's server row can carry a
// STALE id (ipsum-admin's row said 6d9b917b…, its process d7dba841…), so a seat no
// id matches may be matched by its tmux session name AND folder instead; the
// operator confirms that match in the app (matched_by says which it was).

import fs from "node:fs";
import path from "node:path";
import { SESSION_ID } from "./rules.mjs";

// Every session record in `configDirs`, newest first. A record that cannot
// be read or is missing its pid or sessionId is skipped.
export function sessionRecords(configDirs) {
  const out = [];
  for (const dir of new Set(configDirs.filter(Boolean))) {
    const sessions = path.join(dir, "sessions");
    let names = [];
    try {
      names = fs.readdirSync(sessions).filter((n) => /^\d+\.json$/.test(n));
    } catch {
      continue;
    }
    for (const n of names) {
      try {
        const r = JSON.parse(fs.readFileSync(path.join(sessions, n), "utf8"));
        if (Number.isInteger(r.pid) && typeof r.sessionId === "string" && SESSION_ID.test(r.sessionId))
          out.push({ ...r, configDir: dir, file: path.join(sessions, n) });
      } catch {
        // half-written or removed while reading: not a seat we can act on
      }
    }
  }
  return out.sort((a, b) => (b.startedAt || 0) - (a.startedAt || 0));
}

// The tmux SESSION name in a record's "ipsum-admin:@199.%199".
export const tmuxSession = (tmux) => (typeof tmux === "string" && tmux.includes(":") ? tmux.slice(0, tmux.indexOf(":")) : null);

// The one record this seat is: by conversation id, else by tmux session name
// plus folder. { record, matchedBy } | { none: reason } | { several: reason }.
// `alive(pid)` drops records of processes that are gone.
export function matchSeat(records, { sessionIds = [], title, cwd }, alive = () => true) {
  const live = records.filter((r) => alive(r.pid));
  const ids = new Set(sessionIds.filter((s) => typeof s === "string").map((s) => s.toLowerCase()));
  const byId = live.filter((r) => ids.has(r.sessionId.toLowerCase()));
  const pick = (list, matchedBy, what) => {
    const pids = new Set(list.map((r) => r.pid));
    if (pids.size === 1) return { record: list[0], matchedBy };
    return { several: `${pids.size} running processes match its ${what} (pids ${[...pids].join(", ")}); adopt one by hand` };
  };
  if (byId.length) return pick(byId, "session_id", "conversation id");
  if (title && cwd) {
    const byTmux = live.filter((r) => tmuxSession(r.tmux) === title && r.cwd === cwd);
    if (byTmux.length) return pick(byTmux, "tmux_title", "tmux session name and folder");
  }
  return { none: `no running Claude Code process here has its conversation id${title ? `, or runs in a tmux session named ${title} in its folder` : ""}` };
}

// cv-runner slots running on this machine, from `ps -axo args=` output. A
// runner's workers are named <slot>-t<task>: those belong to the runner.
export function runnerSlots(psArgs) {
  const slots = new Set();
  for (const line of psArgs.split("\n")) {
    if (!line.includes("cv-runner.mjs")) continue;
    const m = line.match(/--slot\s+(\S+)/);
    if (m) slots.add(m[1]);
  }
  return slots;
}

export const runnerWorker = (title, slots) => [...slots].some((s) => typeof title === "string" && title.startsWith(`${s}-t`));

// procStart and `TZ=UTC ps -o lstart=` name the same instant: the pid was not
// reused by another process since the record was written.
export const sameStart = (procStart, lstart) =>
  typeof procStart === "string" && typeof lstart === "string" && procStart.trim().replace(/\s+/g, " ") === lstart.trim().replace(/\s+/g, " ");

// The tmux session names in `tmux list-sessions -F "#{session_name}"`'s result
// ({code, stdout, stderr}). No tmux server, as after a reboot, is no sessions;
// any other failure is null: tmux could not say.
export function tmuxNames({ code, stdout, stderr }) {
  if (code === 0) return stdout.split("\n").filter(Boolean);
  return /no server running|error connecting to .*No such file or directory/i.test(stderr) ? [] : null;
}
