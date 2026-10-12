# claude-relay.sh — source from ~/.zshrc or ~/.bashrc to run a plain `claude`
# through this machine's claudiverse relay (the host agent's "relay_port").
#
#   source /path/to/claudiverse/agent/host/claude-relay.sh
#
# Only `claude` typed in a shell is affected, and only when nothing set
# ANTHROPIC_BASE_URL already: seats started by cv-spawn or a profile use an
# absolute binary path with their own routing and never pass through here.
# Deliberately NOT settings.json "env": that overrides every session's own
# environment (measured on 2.1.291), seats included.
# The relay falls back to Anthropic directly with your own login whenever the
# server can't serve a request, so `claude` keeps working with no server.
CLAUDIVERSE_RELAY_PORT="${CLAUDIVERSE_RELAY_PORT:-4097}"
# The native install by default. NOT `command claude`: PATH can hold an older
# claude first (measured on the M5: a bun global 2.1.90 ahead of ~/.local/bin).
CLAUDIVERSE_CLAUDE_BIN="${CLAUDIVERSE_CLAUDE_BIN:-$HOME/.local/bin/claude}"
claude() {
  # curl, not /dev/tcp: zsh has no /dev/tcp. /_relay is answered by the relay itself.
  if [ -z "${ANTHROPIC_BASE_URL:-}" ] && curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$CLAUDIVERSE_RELAY_PORT/_relay"; then
    ANTHROPIC_BASE_URL="http://127.0.0.1:$CLAUDIVERSE_RELAY_PORT" "$CLAUDIVERSE_CLAUDE_BIN" "$@"
  else
    "$CLAUDIVERSE_CLAUDE_BIN" "$@"
  fi
}
