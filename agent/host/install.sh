#!/usr/bin/env bash
# Install (or remove) the claudiverse host agent as a user service on this
# machine: launchd on macOS, a systemd user unit on Linux, an OpenRC service
# on Linux without systemd (Alpine), run as this user.
#
#   ./install.sh               install / update and (re)start
#   ./install.sh --uninstall   stop and remove the service (config is kept)
#
# CV_AGENT_LABEL / CV_AGENT_UNIT name the launchd job / the systemd unit and
# OpenRC service (a second agent on one machine, e.g. a test, must not take
# over the first one's). SUDO is the command OpenRC's root steps run under
# (default sudo; an installer may pass its own). CLAUDIVERSE_HOST_AGENT_CONFIG
# names another config; the service is pinned to the config and HOME it was
# installed with.
#
# Needs Node 22+ and tmux. The config lives OUTSIDE this repo, in
# ~/.config/claudiverse/host-agent.json — on first run it is created from the
# example and the script stops so you can fill it in.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/cv-host-agent.mjs"
CONF="${CLAUDIVERSE_HOST_AGENT_CONFIG:-$HOME/.config/claudiverse/host-agent.json}"
CONF_DIR="$(dirname "$CONF")"
LABEL="${CV_AGENT_LABEL:-no.claudiverse.host-agent}"
UNIT="${CV_AGENT_UNIT:-claudiverse-host-agent.service}"
RC_NAME="${UNIT%.service}-$(id -un)"
SUDO="${SUDO:-sudo}"
[ "$(id -u)" = 0 ] && SUDO=""
OS="$(uname -s)"
# Linux without systemd running (Alpine): OpenRC.
INIT=systemd
[ "$OS" = Darwin ] && INIT=launchd
[ "$OS" != Darwin ] && [ ! -d /run/systemd/system ] && command -v openrc-run >/dev/null 2>&1 && INIT=openrc

uninstall() {
  if [ "$INIT" = launchd ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
  elif [ "$INIT" = openrc ]; then
    $SUDO rc-service "$RC_NAME" stop 2>/dev/null || true
    $SUDO rc-update del "$RC_NAME" default 2>/dev/null || true
    $SUDO rm -f "/etc/init.d/$RC_NAME"
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
fill() {
  sed -e "s#@NODE@#$NODE#g" -e "s#@AGENT@#$AGENT#g" -e "s#@PATH@#$SVC_PATH#g" -e "s#@LOG@#$2#g" \
      -e "s#@LABEL@#$LABEL#g" -e "s#@USER@#$(id -un)#g" -e "s#@HOME@#$HOME#g" -e "s#@CONF@#$CONF#g" "$1"
}

if [ "$INIT" = launchd ]; then
  LOG="$HOME/Library/Logs/$LABEL.log"
  [ "$LABEL" = no.claudiverse.host-agent ] && LOG="$HOME/Library/Logs/claudiverse-host-agent.log"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  fill "$HERE/service/no.claudiverse.host-agent.plist" "$LOG" > "$PLIST"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  # bootout returns before the job is gone; bootstrapping too soon fails with
  # "Bootstrap failed: 5: Input/output error". Wait (up to 10 s) for it to go.
  for _ in $(seq 1 20); do
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
  done
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "running under launchd ($LABEL); log: $LOG"
elif [ "$INIT" = openrc ]; then
  # A system service that runs as this user: OpenRC has no user services.
  LOG="/var/log/$RC_NAME.log"
  TMP="$(mktemp)"
  fill "$HERE/service/claudiverse-host-agent.openrc" "$LOG" > "$TMP"
  $SUDO install -m 0755 "$TMP" "/etc/init.d/$RC_NAME"
  rm -f "$TMP"
  $SUDO touch "$LOG"
  $SUDO chown "$(id -un)" "$LOG"
  $SUDO rc-update add "$RC_NAME" default >/dev/null
  # Stop the agent its pidfile names, whatever OpenRC thinks of it: an agent
  # left by an interrupted install made start fail with "already running".
  $SUDO rc-service "$RC_NAME" stop >/dev/null 2>&1 || true
  $SUDO start-stop-daemon --stop --quiet --pidfile "/run/$RC_NAME.pid" --exec "$NODE" >/dev/null 2>&1 || true
  $SUDO rc-service "$RC_NAME" zap >/dev/null 2>&1 || true
  $SUDO rc-service "$RC_NAME" start >/dev/null
  echo "running under OpenRC ($RC_NAME, as $(id -un)); log: $LOG"
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
