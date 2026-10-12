#!/usr/bin/env bash
#
# cv-spawn.sh — spawn an interactive (patched) claudiverse Claude Code instance
# in a detached tmux session, mirrored to the claudiverse server and driveable
# via cv_send / cv_tail / cv_status.
#
# Hands-off: sets CLAUDIVERSE_SKIP_TRUST=1 (patch 011) so the instance boots
# straight to the REPL with NO first-run "trust this folder?" gate, and NO edit
# to the shared global ~/.claude.json. The interactive sidecar (patch 002) does
# the mirror+drive; this script just allocates the tmux PTY + process lifecycle.
#
# This is the canonical spawn primitive: cv-runner and each machine's host agent
# (agent/host, "New seat" in the app) run THIS script, so
# there is one source of truth for how an instance launches. (The server's old
# POST /api/spawn, which ran it on the server's own host, is gone.)
#
# Usage:
#   cv-spawn.sh <working_dir> [options]
#
# Options:
#   --title  T     session title (default: basename of working_dir)
#   --mcp    CFG   path to an extra --mcp-config (e.g. worker.mcp.json); repeatable
#   --mode   MODE  --permission-mode: auto|acceptEdits|plan|default (default: auto)
#   --effort L     reasoning effort: low|medium|high|xhigh|max (default: binary's own)
#   --model  M     model to run this instance on (default: the binary's own default).
#                  NOTE: --mode and --model are different things and the names invite
#                  confusing them. --mode is the PERMISSION mode; --model is the model.
#   --prompt "..." initial prompt passed to the REPL at launch (optional)
#   --prompt-file F  the same, read from file F (a prompt over 128 KiB cannot be
#                  one argument on Linux); F is copied and may be deleted after
#   --token  TOK   bearer token (default: $CLAUDIVERSE_TOKEN, else extracted from --mcp)
#   --url    URL   server base url (default: $CLAUDIVERSE_URL or http://localhost:4010)
#   --bin    PATH  claude binary (default: $CLAUDIVERSE_BIN or patch-ref/claude)
#   --fleet  F     the fleet this seat belongs to (e.g. lorem-fleet); shown and grouped by
#                  in the app. Default: none.
#   --resume ID    resume Claude Code conversation ID (a session uuid) instead of
#                  starting a new one. Run it in the conversation's ORIGINAL
#                  working_dir: Claude Code keeps transcripts per project folder.
#   --origin O     how the seat was started: spawn (default) | runner | manual | profile.
#                  Runner seats may not request a human (cv_request_human).
#   --profile ID   the seat profile this seat is started from (a host agent's
#                  start_profile), with --revision N, the profile revision:
#                  the seat registers them, and the server fills its fleet,
#                  notify and origin from the profile.
#   --host NAME    the machine name the seat reports (the host agent's name);
#                  default: the runtime's own (hostname).
#   --debug        CLAUDIVERSE_DEBUG=1 in the seat.
#   --config-dir D Claude Code's config folder for this seat (CLAUDE_CONFIG_DIR),
#                  with its auto-updater off: a seat that must not share ~/.claude
#                  (a pilot with its own plugins and login). A fresh config dir
#                  otherwise runs the updater, which repoints ~/.local/bin/claude.
#   --pooled       model requests go through the server's proxy, which sends them
#                  with a pool account and fails over on a spent one. The seat
#                  keeps its own login (feature flags, so mods load); the proxy
#                  replaces it on model calls (X-Claudiverse-Pool) and does not
#                  record them (X-Claudiverse-Observe: off; the seat mirrors
#                  itself). A pooled seat's model calls stop while the server
#                  is down.
#   --pool-only    for a machine with NO Claude Code login of its own: the seat
#                  logs in with the pool's placeholder (CLAUDE_CODE_OAUTH_TOKEN=
#                  cv-pool, which the proxy swaps for a pool account), and is
#                  --pooled. Nothing about it works while the server is down.
#                  The mod loads all the same (measured on stock 2.1.296).
#   --oauth-token-file F
#                  the seat logs in with the long-lived token in F (`claude
#                  setup-token`), as CLAUDE_CODE_OAUTH_TOKEN, instead of the
#                  config dir's refreshing login. Read by the seat's shell at
#                  launch, so the token is never on a command line. For slots
#                  that share one config dir: a rejected refresh blanks the
#                  shared login for all of them (measured 2026-10-06, M1 pilot).
#
# Defaults from the environment, for a caller that cannot pass flags (a
# cv-runner slot, whose launcher exports them; the runner's env reaches this
# script): CV_SPAWN_ORIGIN, CV_SPAWN_POOLED=1, CV_SPAWN_CONFIG_DIR,
# CV_SPAWN_OAUTH_TOKEN_FILE, CV_SPAWN_POOL_ONLY=1. Flags win.
#
# Notes:
#  - 'auto' mode is the recommended default for unattended spawns: it runs the
#    permission-classifier guardrail (auto-approves safe ops, gates risky ones).
#  - The token is passed as an env var on the launch line (same as the rest of
#    the fleet) — visible via `ps`/the tmux pane. Acceptable for a trusted host;
#    harden later (temp env file) if needed.
#  - Initial --prompt is passed as a positional arg to the interactive REPL. If a
#    given build doesn't honor that, inject it via cv_send after the instance
#    reports idle instead.
#
set -euo pipefail

DEFAULT_BIN="$HOME/.local/bin/claude"

CLAUDE_BIN="${CLAUDIVERSE_BIN:-$DEFAULT_BIN}"
URL="${CLAUDIVERSE_URL:-http://localhost:4010}"
TOKEN="${CLAUDIVERSE_TOKEN:-}"
MODE="auto"
# Empty = inherit whatever the binary defaults to. Deliberately NOT given a default
# model string: pinning one in the spawn primitive would silently override every
# caller, including the ones that never asked for a model.
MODEL=""
# Effort level: low|medium|high|xhigh|max. Empty = the binary's default, same
# reasoning as MODEL — do not pin a default here and silently override callers.
EFFORT=""
FLEET=""
ORIGIN="${CV_SPAWN_ORIGIN:-spawn}"
TITLE=""
PROMPT=""
PROMPT_FROM=""
RESUME=""
PROFILE=""
REVISION=""
HOSTNAME_ARG=""
DEBUG=""
POOLED="${CV_SPAWN_POOLED:-}"
POOL_ONLY="${CV_SPAWN_POOL_ONLY:-}"
CONFIG_DIR="${CV_SPAWN_CONFIG_DIR:-}"
OAUTH_FILE="${CV_SPAWN_OAUTH_TOKEN_FILE:-}"
MCPS=()

if [ $# -lt 1 ]; then
  echo "usage: cv-spawn.sh <working_dir> [--title T] [--mcp CFG] [--mode MODE] [--prompt ... | --prompt-file F] [--token TOK] [--url URL] [--bin PATH]" >&2
  exit 2
fi
WORKDIR="$1"; shift

while [ $# -gt 0 ]; do
  case "$1" in
    --title)  TITLE="$2"; shift 2;;
    --mcp)    MCPS+=("$2"); shift 2;;
    --mode)   MODE="$2"; shift 2;;
    --model)  MODEL="$2"; shift 2;;
    --effort) EFFORT="$2"; shift 2;;
    --fleet)  FLEET="$2"; shift 2;;
    --origin) ORIGIN="$2"; shift 2;;
    --prompt) PROMPT="$2"; shift 2;;
    --prompt-file) PROMPT_FROM="$2"; shift 2;;
    --resume) RESUME="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --revision) REVISION="$2"; shift 2;;
    --host)   HOSTNAME_ARG="$2"; shift 2;;
    --debug)  DEBUG=1; shift;;
    --pooled) POOLED=1; shift;;
    --pool-only) POOL_ONLY=1; shift;;
    --config-dir) CONFIG_DIR="$2"; shift 2;;
    --oauth-token-file) OAUTH_FILE="$2"; shift 2;;
    --token)  TOKEN="$2"; shift 2;;
    --url)    URL="$2"; shift 2;;
    --bin)    CLAUDE_BIN="$2"; shift 2;;
    *) echo "cv-spawn: unknown arg: $1" >&2; exit 2;;
  esac
done

# Resolve & validate working dir.
WORKDIR_ABS="$(cd "$WORKDIR" 2>/dev/null && pwd)" || { echo "cv-spawn: no such dir: $WORKDIR" >&2; exit 1; }
TITLE="${TITLE:-$(basename "$WORKDIR_ABS")}"

# Validate binary.
[ -x "$CLAUDE_BIN" ] || { echo "cv-spawn: claude binary not executable: $CLAUDE_BIN" >&2; exit 1; }

# Token: env/flag, else extract CLAUDIVERSE_TOKEN from the first --mcp config.
if [ -z "$TOKEN" ] && [ "${#MCPS[@]}" -gt 0 ] && command -v jq >/dev/null 2>&1; then
  TOKEN="$(jq -r '.. | .CLAUDIVERSE_TOKEN? // empty' "${MCPS[0]}" 2>/dev/null | head -1)"
fi
[ -n "$TOKEN" ] || { echo "cv-spawn: no token — set \$CLAUDIVERSE_TOKEN, pass --token, or pass --mcp with a token" >&2; exit 1; }

# Refuse to clobber an existing session of the same title. EXACT match ("="):
# a bare target falls back to a prefix match, so seat "ipsum-fleet" would be refused
# whenever "ipsum-admin" runs.
if tmux has-session -t "=$TITLE" 2>/dev/null; then
  echo "cv-spawn: tmux session '$TITLE' already exists (kill it first: tmux kill-session -t $TITLE)" >&2
  exit 1
fi

# --- Anthropic account pool (AnthropicAuths) ---------------------------------
#
# NOTHING TO DO HERE. cv-spawn used to lease an account and pass
# CLAUDE_CODE_OAUTH_TOKEN on the launch line. That moved INTO the binary:
# SidecarClient leases at module init whenever CLAUDIVERSE_TOKEN is set, which
# covers every session — runner-spawned workers, hand-launched seats, and
# long-lived ones like the watcher — instead of only the ones that came through
# this script.
#
# Removed rather than kept as a belt-and-braces second path: two mechanisms
# doing the same job drift, and the launch-line version only ever covered a
# subset. The binary still honours a pre-set CLAUDE_CODE_OAUTH_TOKEN, so an
# external pre-lease remains possible if something ever needs one.

[ -z "$CONFIG_DIR" ] || [ -d "$CONFIG_DIR" ] || { echo "cv-spawn: --config-dir is not a folder: $CONFIG_DIR" >&2; exit 2; }
[ -z "$OAUTH_FILE" ] || [ -s "$OAUTH_FILE" ] || { echo "cv-spawn: --oauth-token-file is missing or empty: $OAUTH_FILE" >&2; exit 2; }
[ -z "$POOLED" ] || [ "$POOLED" = 1 ] || { echo "cv-spawn: CV_SPAWN_POOLED must be 1 or unset" >&2; exit 2; }
[ -z "$POOL_ONLY" ] || [ "$POOL_ONLY" = 1 ] || { echo "cv-spawn: CV_SPAWN_POOL_ONLY must be 1 or unset" >&2; exit 2; }
if [ -n "$POOL_ONLY" ]; then
  [ -z "$OAUTH_FILE" ] || { echo "cv-spawn: --pool-only and --oauth-token-file are two different logins; give one" >&2; exit 2; }
  POOLED=1
fi

# They reach the shell line: integers only.
for v in "$PROFILE" "$REVISION"; do
  [[ -z "$v" || "$v" =~ ^[0-9]{1,12}$ ]] || { echo "cv-spawn: --profile/--revision must be integers, got: $v" >&2; exit 2; }
done

# One variable, newline-separated "Name: value" lines (measured on 2.1.289:
# all three arrive).
POOL_ENV=""
if [ -n "$POOLED" ]; then
  HDRS="X-Claudiverse-Token: $TOKEN"$'\n'"X-Claudiverse-Pool: 1"$'\n'"X-Claudiverse-Observe: off"
  POOL_ENV="ANTHROPIC_BASE_URL=$(printf %q "${URL%/}/proxy/seat/$TITLE") ANTHROPIC_CUSTOM_HEADERS=$(printf %q "$HDRS") "
fi

# Build the launch command (quoted so paths/prompts with spaces survive).
LAUNCH="cd $(printf %q "$WORKDIR_ABS") && \
CLAUDIVERSE_TITLE=$(printf %q "$TITLE") \
CLAUDIVERSE_ORIGIN=$(printf %q "$ORIGIN") \
${FLEET:+CLAUDIVERSE_FLEET=$(printf %q "$FLEET") }\
${PROFILE:+CLAUDIVERSE_PROFILE=$PROFILE CLAUDIVERSE_TMUX=$(printf %q "$TITLE") }\
${REVISION:+CLAUDIVERSE_PROFILE_REVISION=$REVISION }\
${HOSTNAME_ARG:+CLAUDIVERSE_HOST=$(printf %q "$HOSTNAME_ARG") }\
${DEBUG:+CLAUDIVERSE_DEBUG=1 }\
${POOL_ENV}\
${CONFIG_DIR:+CLAUDE_CONFIG_DIR=$(printf %q "$CONFIG_DIR") DISABLE_AUTOUPDATER=1 }\
${OAUTH_FILE:+CLAUDE_CODE_OAUTH_TOKEN=\"\$(cat $(printf %q "$OAUTH_FILE"))\" }\
${POOL_ONLY:+CLAUDE_CODE_OAUTH_TOKEN=cv-pool }\
CLAUDIVERSE_SKIP_TRUST=1 \
CLAUDIVERSE_URL=$(printf %q "$URL") \
CLAUDIVERSE_TOKEN=$(printf %q "$TOKEN") \
$(printf %q "$CLAUDE_BIN")"
for cfg in ${MCPS[@]+"${MCPS[@]}"}; do
  LAUNCH="$LAUNCH --mcp-config $(printf %q "$cfg")"
done
LAUNCH="$LAUNCH --permission-mode $(printf %q "$MODE")"
# Claude Code's own name for the session (its /resume picker, terminal title,
# Remote Control) is the seat's title too; without --name it derives one from
# the folder ("standalone-carol-49" for the seat standalone-carol). A binary
# without the flag is launched as before.
"$CLAUDE_BIN" --help 2>/dev/null | grep -q -- '--name <name>' && LAUNCH="$LAUNCH --name $(printf %q "$TITLE")"
# --model is APPENDED ONLY IF ASKED FOR. An empty MODEL must not emit `--model ""`,
# which the binary would read as an explicit empty model rather than as "unset".
[ -n "$MODEL" ] && LAUNCH="$LAUNCH --model $(printf %q "$MODEL")"
[ -n "$EFFORT" ] && LAUNCH="$LAUNCH --effort $(printf %q "$EFFORT")"
# A session uuid only: it reaches the shell line, so nothing else is let through.
if [ -n "$RESUME" ]; then
  printf '%s' "$RESUME" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
    || { echo "cv-spawn: --resume needs a session uuid, got: $RESUME" >&2; exit 2; }
  LAUNCH="$LAUNCH --resume $(printf %q "$RESUME")"
fi

# THE PROMPT GOES VIA A FILE, NEVER INLINE ON THE COMMAND LINE.
#
# MEASURED: a launch line carrying the prompt inline arrived at the pane cut to
# exactly 1013 chars — twice, at the identical character, leaving zsh parked on
# an unterminated quote with no process, no error, and this script reporting
# success. 1013 is MAX_CANON (1024), the tty's CANONICAL-mode line limit.
#
# It only bites when the tty is in canonical mode — i.e. when no shell line
# editor owns it. An idle zsh at a prompt holds the tty in RAW mode, where the
# limit does not apply, which is why ~10 controls sending 4,000-14,670 chars to
# a settled pane ALL passed and could not reproduce this. The two real failures
# both sent into a canonical-mode tty: once while zsh was still starting, once
# while a child process (`clear`) held the terminal.
#
# Rather than keep racing the tty mode, make the payload irrelevant: the prompt
# is written to a file and expanded by the shell INSIDE the pane, so the line
# actually typed stays a few hundred bytes and fits under 1024 either way.
# `rm -f` runs after the process exits, so the pane cleans up after itself.
#
# 🔴 AND THE PROMPT IS NOT AN ARGUMENT EITHER: the seat gets a short prompt that
# @-attaches the file. Expanding the file into argv put a whole task brief
# (~68 KB) on every worker's command line, where `pkill -f` matches it: one
# worker's `pkill -f "landing_gate.sh usa --strict"`, meant for its own gate,
# SIGTERMed three other workers whose briefs contained that text (MEASURED
# 2026-10-06 17:56:59, M1 w2/w3/w4; BSD pkill spares its own ancestors, so the
# killer survived). Claude Code attaches an @file in the first prompt, but a
# large one is often READ instead (a Read tool call), and a read outside the
# seat's folders asks permission: the seat would sit at the prompt. So the
# file lives in its own folder, granted with --add-dir. Measured on 2.1.291.
PROMPT_FILE=""
# --prompt-file: the prompt as a file, for a caller whose prompt may be too big
# for one argument (Linux caps one argv string at 128 KiB; cv-runner's briefs
# reached it, "spawn E2BIG", 2026-10-08). It is copied, so the caller may
# delete its own file once this returns.
if [ -n "$PROMPT_FROM" ]; then
  [ -f "$PROMPT_FROM" ] && [ -s "$PROMPT_FROM" ] || { echo "cv-spawn: --prompt-file $PROMPT_FROM is missing or empty" >&2; exit 2; }
  [ -z "$PROMPT" ] || { echo "cv-spawn: give --prompt or --prompt-file, not both" >&2; exit 2; }
fi
if [ -n "$PROMPT" ] || [ -n "$PROMPT_FROM" ]; then
  PROMPT_DIR="${TMPDIR:-/tmp}/cv-prompts"
  mkdir -p "$PROMPT_DIR" || { echo "cv-spawn: cannot create $PROMPT_DIR" >&2; exit 1; }
  PROMPT_FILE="$(mktemp "$PROMPT_DIR/cv-prompt-XXXXXX")" || { echo "cv-spawn: cannot create prompt file" >&2; exit 1; }
  if [ -n "$PROMPT_FROM" ]; then
    cp "$PROMPT_FROM" "$PROMPT_FILE" || { echo "cv-spawn: cannot copy $PROMPT_FROM" >&2; exit 1; }
  else
    printf '%s' "$PROMPT" > "$PROMPT_FILE"
  fi
  # --add-dir takes several folders and would swallow the prompt after it as
  # one more (measured: the seat started with no prompt), so it goes in front
  # of an option that ends its list.
  LAUNCH="${LAUNCH/ --permission-mode / --add-dir $(printf %q "$PROMPT_DIR") --permission-mode }"
  LAUNCH="$LAUNCH $(printf %q "Your instructions are in @$PROMPT_FILE - read all of it and follow it."); rm -f $(printf %q "$PROMPT_FILE")"
fi

# Spawn detached, sized for a sane Ink REPL.
tmux new-session -d -s "$TITLE" -x 220 -y 50

# WAIT FOR THE SHELL TO BE READY BEFORE SENDING ANYTHING.
#
# new-session returns as soon as the PTY exists, not when a shell is reading
# input. Second line of defence behind the prompt-file above: the payload is
# now short enough to survive canonical mode anyway, but an idle prompt is
# still the only state in which send-keys is unconditionally safe.
#
# Deliberately NO `clear` after this gate. A `clear` is a CHILD PROCESS, and
# while it runs the tty drops back to canonical mode — which is precisely the
# window the second observed truncation landed in. Do not add cosmetics here.
#
# The sentinel token is split ("CV" "READY") so the ECHO of this command cannot
# match the test. A readiness check that its own command text satisfies reports
# ready instantly and forever, which is the failure it exists to prevent.
#
# Matched with bash's own [[ == ]] rather than grep on purpose: `grep` is
# shadowed by a wrapper on at least one machine in this fleet and rejects the
# flags you would reach for, which turns this gate into an unconditional
# failure. No external command, nothing to shadow.
ready=0
for _ in $(seq 1 100); do
  tmux send-keys -t "$TITLE" 'printf "CV""READY\n"' Enter
  sleep 0.2
  pane="$(tmux capture-pane -p -t "$TITLE" 2>/dev/null)"
  if [[ "$pane" == *CVREADY* ]]; then ready=1; break; fi
done
[ "$ready" = 1 ] || { echo "cv-spawn: shell in '$TITLE' never became ready (20s)" >&2; tmux kill-session -t "$TITLE" 2>/dev/null; exit 1; }

tmux send-keys -t "$TITLE" "$LAUNCH" Enter

# VERIFY THE LAUNCH ACTUALLY HAPPENED. Until now this script printed "spawned"
# unconditionally, so a truncated command line — which leaves the shell parked
# and no process running — was reported upstream as a SUCCESSFUL SPAWN. The
# caller then waited on a worker that had never started. Exit non-zero instead,
# so a runner's spawn-failure path releases the task rather than hanging on it.
launched=0
for _ in $(seq 1 60); do
  sleep 0.5
  case "$(tmux display-message -p -t "$TITLE" '#{pane_current_command}' 2>/dev/null)" in
    ""|sh|bash|zsh|fish) ;;
    *) launched=1; break;;
  esac
done
if [ "$launched" != 1 ]; then
  echo "cv-spawn: '$TITLE' still at a shell prompt 30s after launch — the command did not start." >&2
  echo "cv-spawn: pane left ALIVE for inspection: tmux attach -t $TITLE" >&2
  exit 1
fi

echo "cv-spawn: spawned '$TITLE'"
echo "  dir:    $WORKDIR_ABS"
echo "  mode:   $MODE"
echo "  verify: cv_status $TITLE   |   attach: tmux attach -t $TITLE   |   kill: tmux kill-session -t $TITLE"
