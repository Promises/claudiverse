#!/usr/bin/env bash
# Install (or remove) the claudiverse host agent as a user service on this
# machine: launchd on macOS, a systemd user unit on Linux.
#
#   ./install.sh               install / update and (re)start
#   ./install.sh --uninstall   stop and remove the service (config is kept)
#
# Needs Node 22+ and tmux. The config lives OUTSIDE this repo, in
# ~/.config/claudiverse/host-agent.json — on first run it is created from the
# example and the script stops so you can fill it in.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/cv-host-agent.mjs"
CONF_DIR="$HOME/.config/claudiverse"
CONF="$CONF_DIR/host-agent.json"
LABEL="no.claudiverse.host-agent"
UNIT="claudiverse-host-agent.service"
OS="$(uname -s)"

uninstall() {
  if [ "$OS" = Darwin ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
  else
    systemctl --user disable --now "$UNIT" 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/$UNIT"
    systemctl --user daemon-reload
  fi
  echo "removed the service (config kept at $CONF)"
}

[ "${1:-}" = "--uninstall" ] && { uninstall; exit 0; }

NODE="$(command -v node || true)"
[ -n "$NODE" ] || { echo "node not found on PATH" >&2; exit 1; }
MAJOR="$("$NODE" -p 'process.versions.node.split(".")[0]')"
[ "$MAJOR" -ge 22 ] || { echo "node $MAJOR is too old: need 22+ (built-in WebSocket)" >&2; exit 1; }
command -v tmux >/dev/null || { echo "tmux not found on PATH" >&2; exit 1; }

if [ ! -f "$CONF" ]; then
  mkdir -p "$CONF_DIR"
  cp "$HERE/host-agent.example.json" "$CONF"
  chmod 600 "$CONF"
  echo "created $CONF from the example — fill it in, then run ./install.sh again"
  exit 0
fi
chmod 600 "$CONF"

# The service's PATH: node's, tmux's and the usual system directories.
SVC_PATH="$(dirname "$NODE"):$(dirname "$(command -v tmux)"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fill() { sed -e "s#@NODE@#$NODE#g" -e "s#@AGENT@#$AGENT#g" -e "s#@PATH@#$SVC_PATH#g" -e "s#@LOG@#$2#g" "$1"; }

if [ "$OS" = Darwin ]; then
  LOG="$HOME/Library/Logs/claudiverse-host-agent.log"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$(dirname "$PLIST")"
  fill "$HERE/service/$LABEL.plist" "$LOG" > "$PLIST"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  # bootout returns before the job is gone; bootstrapping too soon fails with
  # "Bootstrap failed: 5: Input/output error". Wait (up to 10 s) for it to go.
  for _ in $(seq 1 20); do
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
  done
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "running under launchd ($LABEL); log: $LOG"
else
  mkdir -p "$HOME/.config/systemd/user"
  fill "$HERE/service/$UNIT" "" > "$HOME/.config/systemd/user/$UNIT"
  systemctl --user daemon-reload
  # enable, then restart: starts it if stopped, restarts it on an update, and
  # never starts it twice (enable --now + restart did, measured on an Arch host).
  systemctl --user enable "$UNIT"
  systemctl --user restart "$UNIT"
  echo "running under systemd --user ($UNIT); log: journalctl --user -u $UNIT -f"
  loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q yes ||
    echo "note: run 'loginctl enable-linger $USER' so it keeps running without a login session"
fi
