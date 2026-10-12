// A running seat's permission mode, switched the way a person at its terminal
// does: Shift+Tab cycles default → acceptEdits → plan → auto → default
// (measured on 2.1.292). A plugin cannot set the live mode (no such call in
// its API; the /config row only writes the saved default), and Remote Control's
// channel is Claude Code's own. The footer names the mode in force.

// The footer's mode line ("⏵⏵ auto mode on (shift+tab to cycle)"); none in
// default mode. Only the last lines are read, so a transcript that quotes the
// words cannot be taken for the footer.
const FOOTER = /(accept edits|plan mode|auto mode) on \(shift\+tab to cycle\)/;
const MODES = { "accept edits": "acceptEdits", "plan mode": "plan", "auto mode": "auto" };

export const CYCLE = ["default", "acceptEdits", "plan", "auto"];

export function footerMode(pane) {
  const tail = pane.trimEnd().split("\n").slice(-6).join("\n");
  const m = tail.match(FOOTER);
  return m ? MODES[m[1]] : "default";
}

// A dialog is open (a permission prompt, a question, a menu): Shift+Tab would
// act on it, so the mode is not switched then.
export const dialogOpen = (pane) => /Do you want to proceed\?|Enter to select|Esc to cancel/.test(pane.trimEnd().split("\n").slice(-25).join("\n"));
