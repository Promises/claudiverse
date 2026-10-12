#!/bin/sh
# Claudiverse installer: a server, a machine that runs seats, or both.
#
#   curl -fsSL https://raw.githubusercontent.com/Promises/claudiverse/main/install/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/Promises/claudiverse/main/install/install.sh | sh -s -- --help
#
# Run it again to update what it installed. Reference: docs/reference/installers.md.
set -eu

SCRIPT=install
USAGE='Usage: install.sh [options]

Sets up a Claudiverse server (and its web panel), or connects a machine that
runs Claude Code seats to a server, or both: a server, then this machine as
its first seat machine. Run it again to update.

What to do (asked when there is a terminal):
  --server                    set up a server (Docker Compose)
  --machine                   connect a machine to a server
  --with-seat                 with --server: then set up a machine for seats
                              and start a first seat

Where:
  --target local|ssh|context  where it runs (default: this machine).
                              context (a Docker context) is for --server only
  --ssh USER@HOST             the remote machine, for --target ssh
  --port N                    its SSH port (default 22)
  --identity FILE             the SSH key (default: your ssh config; a password
                              is asked for, or read from CV_SSH_PASSWORD)
  --context NAME              the Docker context, for --target context
  --seat-target local|ssh     with --with-seat: this machine (default) or one
                              over SSH (--ssh, --port, --identity name it)

The server:
  --dir DIR                   where the code lives (default ~/claudiverse)
  --host NAME                 the address browsers and machines reach it at
                              (default: this machine'"'"'s address)
  --api-port N                the API port (default 4000)
  --web-port N                the web panel port (default 8080)
  --project NAME              the Compose project name (default claudiverse)
  --email EMAIL               with --with-seat: the account to create with the
                              setup code (or to sign in with); its password
                              is asked for, or read from CV_LOGIN_PASSWORD

A machine:
  --url URL                   the server'"'"'s API address, e.g. http://host:4000
  --join CODE                 a join code from the web panel'"'"'s Add a machine
  --login EMAIL               instead of a join code: sign in (the password is
                              asked for, or read from CV_LOGIN_PASSWORD)
  --name NAME                 this machine'"'"'s name (default: its hostname)
  --roots DIRS                folders seats may work in, comma-separated
                              (default ~/projects)
  --pool-only yes|no          seats use the server'"'"'s account pool, not this
                              machine'"'"'s own claude login (default yes)
  --service-label NAME        the launchd label / systemd unit / OpenRC service
                              (default no.claudiverse.host-agent /
                              claudiverse-host-agent): a second agent on one
                              machine needs its own

Both:
  --ref REF                   the branch or tag to install (default main)
  --repo URL                  the git repository (default the public one)
  --no-install                install no packages: fail if one is missing
  --yes                       go ahead without asking (needed without a terminal)
  --dry-run                   print the plan; change nothing
  --json                      a machine-readable result on stdout at the end
  --help

Secrets are never flags: CV_SUDO_PASSWORD, CV_SSH_PASSWORD and
CV_LOGIN_PASSWORD are read from the environment when there is no terminal.
Exit codes: 0 done, 1 a step failed, 2 a missing or bad flag, 3 an
unsupported system or a missing prerequisite, 4 declined or refused, 5 the
join code or sign-in was refused.'

# ---- common ----
EX_STEP=1 EX_USAGE=2 EX_UNSUPPORTED=3 EX_DECLINED=4 EX_JOIN=5
STEP=start
INTERACTIVE='' JSON='' DRY_RUN='' YES='' NO_INSTALL='' SECRETS_STDIN='' SELF_DELETE=''
REMOTE_RUN='' TARGET='' SSH_DEST='' SSH_PORT='' SSH_KEY='' SCRIPT_URL='' REF='' REPO='' DIR=''
TMPS='' JSON_FIELDS='' PLAN='' SUDO='' STTY_SAVED=''
DEFAULT_REPO=https://github.com/Promises/claudiverse.git
RAW=https://raw.githubusercontent.com/Promises/claudiverse

# Messages go to stderr when --json, so stdout is the JSON alone.
say() { if [ -n "$JSON" ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }
step() { STEP=$1; say "==> $1"; }
plan() { PLAN="$PLAN
  - $*"; }

json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t' '  '; }
json_str() { if [ -n "$1" ]; then printf '"%s"' "$(json_esc "$1")"; else printf null; fi; }
# json_set KEY RAW_JSON_VALUE
json_set() { JSON_FIELDS="$JSON_FIELDS,\"$1\":$2"; }
json_out() {
  [ -n "$JSON" ] || return 0
  printf '{"ok":%s,"script":"%s","exit_code":%s%s' "$1" "$SCRIPT" "$2" "$JSON_FIELDS"
  [ -n "${3:-}" ] && printf ',"error":%s,"failed_step":%s' "$(json_str "$3")" "$(json_str "$STEP")"
  printf '}\n'
}

die() {
  code=$1; shift
  restore_tty
  printf 'error: %s\n  (failed at step: %s)\n' "$*" "$STEP" >&2
  json_out false "$code" "$*"
  exit "$code"
}

cleanup() {
  restore_tty
  for f in $TMPS; do rm -rf "$f"; done
  [ -n "$SELF_DELETE" ] && rm -f "$0"
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# tmp VAR: a private temp file (wiped on exit) in VAR.
tmp() {
  _t=$(mktemp "${TMPDIR:-/tmp}/cv-install.XXXXXX") || die "$EX_STEP" "cannot make a temp file"
  chmod 600 "$_t"
  TMPS="$TMPS $_t"
  eval "$1=\$_t"
}

has() { command -v "$1" >/dev/null 2>&1; }

# A terminal to ask on: /dev/tty, which `curl | sh` leaves free (stdin is the script).
tty_ok() { (exec </dev/tty) 2>/dev/null; }

restore_tty() { if [ -n "$STTY_SAVED" ]; then stty "$STTY_SAVED" </dev/tty 2>/dev/null || true; STTY_SAVED=; fi; }

# ask VAR "Question" DEFAULT --flag: a flag given wins; then the terminal;
# then the default; without any, a missing flag is an error, never a hang.
ask() {
  eval "_cur=\${$1:-}"
  [ -n "$_cur" ] && return 0
  if [ -n "$INTERACTIVE" ]; then
    while :; do
      if [ -n "$3" ]; then printf '%s [%s]: ' "$2" "$3" >/dev/tty; else printf '%s: ' "$2" >/dev/tty; fi
      IFS= read -r _ans </dev/tty || _ans=
      [ -n "$_ans" ] || _ans=$3
      [ -n "$_ans" ] && break
      printf '  (an answer is needed)\n' >/dev/tty
    done
    eval "$1=\$_ans"
  elif [ -n "$3" ]; then
    eval "$1=\$3"
  else
    die "$EX_USAGE" "missing $4 (without a terminal, every answer that has no default needs its flag)"
  fi
}

# ask_secret VAR "Prompt" ENVNAME: from the environment, else typed with no
# echo on the terminal. Never a flag, never logged.
ask_secret() {
  eval "_cur=\${$3:-}"
  if [ -n "$_cur" ]; then eval "$1=\$_cur"; return 0; fi
  if [ -n "$INTERACTIVE" ]; then
    printf '%s' "$2" >/dev/tty
    STTY_SAVED=$(stty -g </dev/tty)
    stty -echo </dev/tty
    IFS= read -r _ans </dev/tty || _ans=
    restore_tty
    printf '\n' >/dev/tty
    eval "$1=\$_ans"
  else
    die "$EX_USAGE" "missing the secret $3: set it in the environment (secrets are never flags)"
  fi
}

# yesno "Question" DEFAULT(y|n): interactive only.
yesno() {
  printf '%s [%s] ' "$1" "$([ "$2" = y ] && echo Y/n || echo y/N)" >/dev/tty
  IFS= read -r _a </dev/tty || _a=
  [ -n "$_a" ] || _a=$2
  case $_a in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# The summary, then go or stop.
confirm() {
  say ""
  say "This will:$PLAN"
  say ""
  if [ -n "$DRY_RUN" ]; then
    say "(dry run: nothing was changed)"
    json_set dry_run true
    _pl=$(printf '%s\n' "$PLAN" | sed -n 's/^  - //p' | while IFS= read -r _x; do printf ',%s' "$(json_str "$_x")"; done)
    json_set plan "[${_pl#,}]"
    json_out true 0
    exit 0
  fi
  [ -n "$YES" ] && return 0
  if [ -n "$INTERACTIVE" ]; then
    yesno "Go ahead?" y || die "$EX_DECLINED" "stopped at your answer; nothing was changed"
  else
    die "$EX_USAGE" "pass --yes to go ahead without a terminal (or --dry-run to see the plan)"
  fi
}

# Common flags; anything else goes to the script's own parse.
common_flag() {
  case $1 in
    --target) TARGET=$2 ;; --ssh) SSH_DEST=$2 ;; --port) SSH_PORT=$2 ;; --identity) SSH_KEY=$2 ;;
    --script-url) SCRIPT_URL=$2 ;; --ref) REF=$2 ;; --repo) REPO=$2 ;; --dir) DIR=$2 ;;
    *) return 1 ;;
  esac
}
common_switch() {
  case $1 in
    --yes) YES=1 ;; --dry-run) DRY_RUN=1 ;; --json) JSON=1 ;; --no-install) NO_INSTALL=1 ;;
    --secrets-stdin) SECRETS_STDIN=1 ;; --self-delete) SELF_DELETE=1 ;; --remote) REMOTE_RUN=1 ;;
    --help|-h) printf '%s\n' "$USAGE"; exit 0 ;;
    *) return 1 ;;
  esac
}

# A remote run gets its secrets on stdin, one NAME=value a line: never in
# argv or the remote environment.
read_secrets() {
  [ -n "$SECRETS_STDIN" ] || return 0
  while IFS= read -r _l; do
    case $_l in
      CV_SUDO_PASSWORD=*) CV_SUDO_PASSWORD=${_l#*=} ;;
      CV_LOGIN_PASSWORD=*) CV_LOGIN_PASSWORD=${_l#*=} ;;
      CV_JOIN_CODE=*) JOIN=${_l#*=} ;;
    esac
  done
}

# The platform: OS_FAMILY macos | debian | arch | alpine | fedora | rhel.
detect_os() {
  OS_ID='' OS_LIKE='' OS_NAME=''
  case $(uname -s) in
    Darwin) OS_FAMILY=macos; OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null)"; return 0 ;;
    Linux) ;;
    *) die "$EX_UNSUPPORTED" "$(uname -s) is not supported: Linux (Debian, Ubuntu, Arch, Alpine, Fedora, RHEL/Rocky/Alma) or macOS" ;;
  esac
  [ -r /etc/os-release ] || die "$EX_UNSUPPORTED" "no /etc/os-release: cannot tell which Linux this is"
  OS_ID=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
  OS_LIKE=$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"')
  OS_NAME=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')
  case " $OS_ID " in
    " alpine ") OS_FAMILY=alpine ;;
    " arch "|" archarm "|" manjaro "|" endeavouros ") OS_FAMILY=arch ;;
    " fedora ") OS_FAMILY=fedora ;;
    " debian "|" ubuntu ") OS_FAMILY=debian ;;
    *)
      case " $OS_LIKE " in
        *" rhel "*|*" centos "*) OS_FAMILY=rhel ;;
        *" fedora "*) OS_FAMILY=fedora ;;
        *" debian "*|*" ubuntu "*) OS_FAMILY=debian ;;
        *" arch "*) OS_FAMILY=arch ;;
        *) die "$EX_UNSUPPORTED" "$OS_NAME is not supported: Debian, Ubuntu, Arch, Alpine, Fedora, RHEL/Rocky/Alma, macOS" ;;
      esac ;;
  esac
}

# SUDO: how to run as root ("" when root). A password is typed on the
# terminal (sudo asks there itself, saying for what), or read from
# CV_SUDO_PASSWORD without one.
sudo_pw() { printf '%s\n' "$CV_SUDO_PASSWORD" | sudo -S -p '' "$@"; }
need_root() {
  if [ "$(id -u)" = 0 ]; then SUDO=''; return 0; fi
  # Decided once. Without a terminal sudo caches a password per parent
  # process, so a later `sudo -n true` can succeed here and still fail in a
  # pipeline's subshell (MEASURED: the setup code was never read, "sudo: a
  # password is required" in each try). A password given is always passed.
  [ -z "$SUDO" ] || return 0
  has sudo || die "$EX_UNSUPPORTED" "$1 needs root: run this as root, or install sudo"
  if [ -n "${CV_SUDO_PASSWORD:-}" ]; then
    sudo_pw true 2>/dev/null || die "$EX_STEP" "sudo refused the password in CV_SUDO_PASSWORD for $(id -un)@$(hostname)"
    SUDO=sudo_pw
  elif sudo -n true 2>/dev/null; then
    SUDO=sudo
  elif [ -n "$INTERACTIVE" ]; then
    sudo -v -p "sudo password for $(id -un)@$(hostname) (to $1): " </dev/tty || die "$EX_STEP" "sudo did not accept a password"
    SUDO=sudo
  else
    die "$EX_USAGE" "$1 needs sudo on $(id -un)@$(hostname): set CV_SUDO_PASSWORD, or run as root"
  fi
}

# pkg_install PACKAGES: with the platform's package manager.
APT_UPDATED=
pkg_install() {
  case $OS_FAMILY in
    debian)
      # apt's output is shown only when it fails: on success it is noise
      # ("debconf: delaying package configuration" on every minimal image).
      tmp APTLOG
      if [ -z "$APT_UPDATED" ]; then
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq >"$APTLOG" 2>&1 \
          || { cat "$APTLOG" >&2; die "$EX_STEP" "apt-get update failed"; }
        APT_UPDATED=1
      fi
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >"$APTLOG" 2>&1 \
        || { cat "$APTLOG" >&2; die "$EX_STEP" "apt-get could not install $*"; } ;;
    arch) $SUDO pacman -Sy --noconfirm --needed "$@" >/dev/null ;;
    alpine) $SUDO apk add --no-cache -q "$@" ;;
    fedora|rhel) $SUDO dnf install -y -q "$@" >/dev/null ;;
    macos) brew install "$@" ;;
  esac
}

# Where packages come from, in the plan: the distribution's own name.
pkg_source() { case $OS_FAMILY in macos) echo Homebrew ;; *) echo "${OS_ID:-$OS_FAMILY} packages" ;; esac; }

# fetch URL FILE
fetch() { curl -fsSL --retry 3 "$1" -o "$2" || die "$EX_STEP" "could not download $1"; }

# git_sync DIR: clone, or update a clean clone to REF. Local edits stop it.
git_sync() {
  if [ -d "$1/.git" ]; then
    if [ -n "$(git -C "$1" status --porcelain --untracked-files=no)" ]; then
      die "$EX_STEP" "$1 has local changes; commit or stash them, then run this again"
    fi
    git -C "$1" fetch -q origin "$REF" || die "$EX_STEP" "git fetch of $REF from $(git -C "$1" remote get-url origin) failed"
    git -C "$1" checkout -q --detach FETCH_HEAD
    UPDATED=true
  else
    [ ! -e "$1" ] || [ -z "$(ls -A "$1")" ] || die "$EX_STEP" "$1 exists and is not a clone; choose another --dir"
    git clone -q --branch "$REF" "$REPO" "$1" || die "$EX_STEP" "git clone of $REPO ($REF) failed"
    UPDATED=false
  fi
}

# --- the remote half -----------------------------------------------------------
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Run this script on SSH_DEST, streamed over one SSH connection (a password,
# if the host wants one, is typed once: ssh asks for it on the terminal, or
# reads CV_SSH_PASSWORD through an askpass helper without one).
run_remote() {
  has ssh || die "$EX_UNSUPPORTED" "ssh is not installed here"
  [ -n "$SSH_DEST" ] || die "$EX_USAGE" "missing --ssh USER@HOST"
  case $SSH_PORT in ''|*[!0-9]*) die "$EX_USAGE" "--port must be a number" ;; esac
  # This script's own text: the file it runs from, or the published one.
  if [ -f "$0" ] && grep -q "^SCRIPT=$SCRIPT\$" "$0" 2>/dev/null; then
    SELF=$0
  else
    tmp SELF
    fetch "${SCRIPT_URL:-$RAW/${REF:-main}/install/$SCRIPT.sh}" "$SELF"
  fi
  CMD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cv-ssh.XXXXXX"); TMPS="$TMPS $CMD_DIR"
  set -- -p "$SSH_PORT" -o ControlPath="$CMD_DIR/cm"
  [ -n "$SSH_KEY" ] && set -- "$@" -i "$SSH_KEY"
  if [ -n "$INTERACTIVE" ]; then
    step "connect to $SSH_DEST (port $SSH_PORT)"
    ssh "$@" -o ControlMaster=yes -o ControlPersist=900 -fN "$SSH_DEST" </dev/tty || die "$EX_STEP" "ssh to $SSH_DEST failed"
  else
    step "connect to $SSH_DEST (port $SSH_PORT)"
    if [ -n "${CV_SSH_PASSWORD:-}" ]; then
      ASKPASS="$CMD_DIR/askpass"
      printf '#!/bin/sh\nprintf "%%s\\n" "$CV_SSH_PASSWORD"\n' > "$ASKPASS"; chmod 700 "$ASKPASS"
      CV_SSH_PASSWORD=$CV_SSH_PASSWORD SSH_ASKPASS=$ASKPASS SSH_ASKPASS_REQUIRE=force DISPLAY=none \
        ssh "$@" -o StrictHostKeyChecking=accept-new -o ControlMaster=yes -o ControlPersist=900 -fN "$SSH_DEST" </dev/null \
        || die "$EX_STEP" "ssh to $SSH_DEST failed (the password in CV_SSH_PASSWORD, or the host)"
      rm -f "$ASKPASS"
    else
      ssh "$@" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ControlMaster=yes -o ControlPersist=900 -fN "$SSH_DEST" </dev/null \
        || die "$EX_STEP" "ssh to $SSH_DEST failed: no key it accepts, and no CV_SSH_PASSWORD"
    fi
  fi
  rc=0
  RTMP=$(ssh "$@" "$SSH_DEST" 'mktemp /tmp/cv-install.XXXXXX') || die "$EX_STEP" "could not make a temp file on $SSH_DEST"
  ssh "$@" "$SSH_DEST" "cat > $RTMP && chmod 700 $RTMP" < "$SELF" || die "$EX_STEP" "could not copy the installer to $SSH_DEST"
  REMOTE="sh $RTMP --target local --remote --self-delete $REMOTE_ARGS"
  step "run on $SSH_DEST"
  if [ -n "$INTERACTIVE" ] && [ -z "${CV_JOIN_CODE:-}" ]; then
    ssh -tt "$@" "$SSH_DEST" "$REMOTE" </dev/tty; rc=$?
  else
    { [ -n "${CV_SUDO_PASSWORD:-}" ] && printf 'CV_SUDO_PASSWORD=%s\n' "$CV_SUDO_PASSWORD"
      [ -n "${CV_LOGIN_PASSWORD:-}" ] && printf 'CV_LOGIN_PASSWORD=%s\n' "$CV_LOGIN_PASSWORD"
      [ -n "${CV_JOIN_CODE:-}" ] && printf 'CV_JOIN_CODE=%s\n' "$CV_JOIN_CODE"
      true; } | ssh "$@" "$SSH_DEST" "$REMOTE --secrets-stdin"; rc=$?
  fi
  if [ -n "${RUN_REMOTE_RETURN:-}" ]; then
    # The caller goes on (a first seat there): it needs that machine's home.
    REMOTE_HOME=$(ssh "$@" "$SSH_DEST" 'printf "%s" "$HOME"' 2>/dev/null) || REMOTE_HOME=
    ssh "$@" -O exit "$SSH_DEST" 2>/dev/null || true
    return "$rc"
  fi
  ssh "$@" -O exit "$SSH_DEST" 2>/dev/null || true
  trap - EXIT; cleanup
  exit "$rc"
}

# Every flag the remote half needs, but where: it runs there as local.
remote_args() {
  REMOTE_ARGS=
  while [ $# -gt 0 ]; do
    case $1 in
      --target|--ssh|--port|--identity|--script-url) shift ;;
      --context) die "$EX_USAGE" "--context and --target ssh do not go together" ;;
      *) REMOTE_ARGS="$REMOTE_ARGS $(q "$1")" ;;
    esac
    shift
  done
}
# ---- common: end ----

# --- the API --------------------------------------------------------------------------
# api METHOD PATH [BODY_FILE] [TOKEN]: API_STATUS and API_BODY. A token goes
# to curl on stdin (-K -), never on its command line.
api() {
  tmp _out
  _tok=${4:-}
  set -- -sS -o "$_out" -w '%{http_code}' -X "$1" -H 'content-type: application/json' --max-time 30 "$URL$2" ${3:+--data @"$3"}
  if [ -n "$_tok" ]; then
    API_STATUS=$(printf 'header = "Authorization: Bearer %s"\n' "$_tok" | curl -K - "$@" 2>/dev/null) || API_STATUS=000
  else
    API_STATUS=$(curl "$@" </dev/null 2>/dev/null) || API_STATUS=000
  fi
  API_BODY=$(cat "$_out")
}
# jfield JSON KEY: a string field (ids, tokens, codes: no escaped quotes in them).
jfield() { printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1; }
api_error() { _e=$(jfield "$API_BODY" error); printf '%s' "${_e:-HTTP $API_STATUS}"; }
# body FILE KEY VALUE ...: a JSON object of strings, in a private temp file.
body() {
  tmp "$1"; eval "_f=\$$1"; shift
  _sep='{'
  { while [ $# -ge 2 ]; do printf '%s"%s":%s' "$_sep" "$1" "$(json_str "$2")"; _sep=,; shift 2; done; printf '}'; } > "$_f"
}

# --- flags -----------------------------------------------------------------------------
MODE='' WITH_SEAT='' SEAT_TARGET='' CONTEXT='' HOST='' API_PORT='' WEB_PORT='' PROJECT='' EMAIL=''
URL='' JOIN='' LOGIN_EMAIL='' NAME='' ROOTS='' POOL_ONLY='' SERVICE_LABEL=''
parse() {
  while [ $# -gt 0 ]; do
    case $1 in
      --server) MODE=server; shift; continue ;;
      --machine) MODE=machine; shift; continue ;;
      --with-seat) WITH_SEAT=1; shift; continue ;;
    esac
    if common_switch "$1"; then shift; continue; fi
    case $1 in --*) [ $# -ge 2 ] || die "$EX_USAGE" "$1 needs a value" ;; esac
    if common_flag "$1" "$2"; then shift 2; continue; fi
    case $1 in
      --mode) MODE=$2 ;; --seat-target) SEAT_TARGET=$2 ;; --context) CONTEXT=$2 ;; --host) HOST=$2 ;;
      --api-port) API_PORT=$2 ;; --web-port) WEB_PORT=$2 ;; --project) PROJECT=$2 ;; --email) EMAIL=$2 ;;
      --url) URL=$2 ;; --join) JOIN=$2 ;; --login) LOGIN_EMAIL=$2 ;; --name) NAME=$2 ;; --roots) ROOTS=$2 ;;
      --pool-only) POOL_ONLY=$2 ;; --service-label) SERVICE_LABEL=$2 ;;
      *) die "$EX_USAGE" "unknown flag $1 (see --help)" ;;
    esac
    shift 2
  done
}

# --- the server ------------------------------------------------------------------------
server_flow() {
  step "check the system"
  detect_os
  say "  $OS_NAME, $(id -un)@$(hostname)"
  json_set os "$(json_str "$OS_NAME")"

  DOCKER=docker
  if [ "$TARGET" = context ]; then
    ask CONTEXT "Docker context" "" --context
    has docker || die "$EX_UNSUPPORTED" "--target context needs the docker CLI here"
    case $(docker context inspect "$CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) in
      "") die "$EX_USAGE" "no Docker context named $CONTEXT (docker context ls)" ;;
      *colima*) die "$EX_DECLINED" "$CONTEXT is a colima context: claudiverse does not deploy into colima VMs. Use Docker Desktop, OrbStack or a remote Docker host" ;;
    esac
    DOCKER="docker --context $CONTEXT"
  fi

  NEED_DOCKER='' NEED_GIT='' NEED_CURL=''
  has git || NEED_GIT=1
  has curl || NEED_CURL=1
  if [ "$TARGET" = local ]; then
    if ! has docker || ! docker compose version >/dev/null 2>&1; then NEED_DOCKER=1; fi
    if [ "$OS_FAMILY" = macos ]; then
      [ -z "$NEED_DOCKER" ] || die "$EX_UNSUPPORTED" "Docker is not running here. On macOS install Docker Desktop (https://www.docker.com/products/docker-desktop/) or OrbStack (https://orbstack.dev), start it, and run this again"
      case $(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null) in
        *colima*) die "$EX_DECLINED" "the current Docker context is colima's: claudiverse does not deploy into colima VMs. Switch to Docker Desktop or OrbStack (docker context use ...)" ;;
      esac
      has git || die "$EX_UNSUPPORTED" "git is missing: xcode-select --install, or brew install git"
    fi
  fi
  if [ -n "$NEED_DOCKER$NEED_GIT$NEED_CURL" ] && [ -n "$NO_INSTALL" ]; then
    die "$EX_UNSUPPORTED" "missing:${NEED_DOCKER:+ docker (with the compose plugin)}${NEED_GIT:+ git}${NEED_CURL:+ curl} (and --no-install)"
  fi
  [ -z "$NEED_GIT$NEED_CURL" ] || plan "install${NEED_GIT:+ git}${NEED_CURL:+ curl} ($(pkg_source))"
  if [ -n "$NEED_DOCKER" ]; then
    case $OS_FAMILY in
      debian) plan "install Docker from Docker's own repository (docker-ce and the compose plugin)" ;;
      fedora|rhel) plan "install Docker from Docker's own repository (docker-ce and the compose plugin; podman-docker, if present, is replaced)" ;;
      arch) plan "install docker, docker-compose and docker-buildx (pacman), and start docker" ;;
      alpine) plan "install docker, docker-cli-compose and docker-cli-buildx (apk), and start docker with OpenRC" ;;
    esac
  fi

  DIR=${DIR:-$HOME/claudiverse}
  case $OS_FAMILY in
    macos) _addr=$(ipconfig getifaddr en0 2>/dev/null || hostname) ;;
    *) _addr=$( (hostname -I 2>/dev/null || hostname -i 2>/dev/null) | awk '{print $1}'); [ -n "$_addr" ] || _addr=$(hostname) ;;
  esac
  ask DIR "Install into" "$DIR" --dir
  ask HOST "The address browsers and machines reach this server at" "$_addr" --host
  ask API_PORT "API port" 4000 --api-port
  ask WEB_PORT "Web panel port" 8080 --web-port
  PROJECT=${PROJECT:-claudiverse}
  for _p in "$API_PORT" "$WEB_PORT"; do case $_p in ''|*[!0-9]*) die "$EX_USAGE" "ports are numbers: $_p" ;; esac; done
  API_URL="http://$HOST:$API_PORT"
  WEB_URL="http://$HOST:$WEB_PORT"

  if [ -d "$DIR/.git" ]; then plan "update $DIR to $REF (git fetch + checkout), keeping .env and the data"
  else plan "clone $REPO ($REF) into $DIR"; fi
  if [ -f "$DIR/.env" ]; then plan "keep $DIR/.env as it is"
  else plan "write $DIR/.env: new SECRET_KEY_BASE and CV_VAULT_KEY, API $API_URL, web panel $WEB_URL"; fi
  plan "build and start the stack: docker compose -p $PROJECT up -d --build${CONTEXT:+ (context $CONTEXT)}"
  plan "wait for $API_URL/api/health, then show the setup code"
}

server_act() {
  if [ -n "$NEED_DOCKER$NEED_GIT$NEED_CURL" ]; then
    step "install prerequisites"
    need_root "install Docker and git"
    [ -z "$NEED_GIT$NEED_CURL" ] || pkg_install ${NEED_GIT:+git} ${NEED_CURL:+curl} ca-certificates
    if [ -n "$NEED_DOCKER" ]; then
      case $OS_FAMILY in
        debian)
          tmp GETDOCKER; fetch https://get.docker.com "$GETDOCKER"
          $SUDO sh "$GETDOCKER" >/dev/null 2>&1 || die "$EX_STEP" "Docker's installer (get.docker.com) failed" ;;
        fedora|rhel)
          if rpm -q podman-docker >/dev/null 2>&1; then say "  podman-docker is installed: replacing it with Docker's docker-ce"; fi
          _os=$([ "$OS_FAMILY" = fedora ] && echo fedora || echo rhel)
          tmp DREPO; fetch "https://download.docker.com/linux/$_os/docker-ce.repo" "$DREPO"
          $SUDO install -m 0644 "$DREPO" /etc/yum.repos.d/docker-ce.repo
          $SUDO dnf install -y -q --allowerasing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null \
            || die "$EX_STEP" "dnf could not install docker-ce" ;;
        arch) pkg_install docker docker-compose docker-buildx ;;
        alpine) pkg_install docker docker-cli-compose docker-cli-buildx ;;
      esac
      if [ "$OS_FAMILY" = alpine ]; then
        $SUDO rc-update add docker default >/dev/null 2>&1 || true
        $SUDO rc-service docker start >/dev/null 2>&1 || true
      elif has systemctl && [ -d /run/systemd/system ]; then
        $SUDO systemctl enable --now docker >/dev/null 2>&1 || die "$EX_STEP" "could not start the docker service"
      else
        die "$EX_STEP" "Docker is installed, but there is no systemd or OpenRC here to start it"
      fi
      for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do $SUDO docker info >/dev/null 2>&1 && break; sleep 2; done
      if [ "$(id -u)" != 0 ]; then
        $SUDO usermod -aG docker "$(id -un)" 2>/dev/null || $SUDO addgroup "$(id -un)" docker 2>/dev/null || true
        say "  added $(id -un) to the docker group: log out and in again (or run 'newgrp docker') to use docker without sudo"
      fi
    fi
  fi
  if [ "$TARGET" = local ] && ! $DOCKER info >/dev/null 2>&1; then
    need_root "run docker"
    $SUDO docker info >/dev/null 2>&1 || die "$EX_STEP" "docker is not running"
    DOCKER="$SUDO docker"
  fi

  step "get the code"
  git_sync "$DIR"
  SERVER_UPDATED=$UPDATED

  if [ ! -f "$DIR/.env" ]; then
    step "write .env"
    [ -f "$DIR/.env.example" ] || die "$EX_STEP" "$DIR/.env.example is missing: is $REPO the claudiverse repository?"
    _skb=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
    _vault=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    ( umask 077
      awk -v skb="$_skb" -v vault="$_vault" -v host="$HOST" -v port="$API_PORT" -v web="$WEB_PORT" -v api="$API_URL" '
        /^SECRET_KEY_BASE=/ { print "SECRET_KEY_BASE=" skb; next }
        /^CV_VAULT_KEY=/    { print "CV_VAULT_KEY=" vault; next }
        /^PHX_HOST=/        { print "PHX_HOST=" host; next }
        /^PORT=/            { print "PORT=" port; next }
        /^WEB_PORT=/        { print "WEB_PORT=" web; next }
        /^VITE_API_URL=/    { print "VITE_API_URL=" api; next }
        { print }' "$DIR/.env.example" > "$DIR/.env" )
    for _k in SECRET_KEY_BASE CV_VAULT_KEY PHX_HOST PORT WEB_PORT VITE_API_URL; do
      grep -q "^$_k=." "$DIR/.env" || die "$EX_STEP" ".env.example has no $_k= line to fill in"
    done
    say "  CV_VAULT_KEY encrypts the Anthropic tokens the server stores: back up $DIR/.env"
  else
    _v=$(sed -n 's/^PORT=//p' "$DIR/.env"); API_PORT=${_v:-$API_PORT}
    _v=$(sed -n 's/^WEB_PORT=//p' "$DIR/.env"); WEB_PORT=${_v:-$WEB_PORT}
    _v=$(sed -n 's/^VITE_API_URL=//p' "$DIR/.env"); API_URL=${_v:-$API_URL}
    _v=$(sed -n 's/^PHX_HOST=//p' "$DIR/.env"); WEB_URL="http://${_v:-$HOST}:$WEB_PORT"
  fi

  step "build and start the server (the first build takes a few minutes)"
  # The build's output goes to a log, not the screen: on a terminal one line
  # shows the time and the step it is on; on failure the log's end is shown
  # with its path. Outside the clone, so it never dirties it.
  BUILD_LOG=${XDG_STATE_HOME:-$HOME/.local/state}/claudiverse/build.log
  mkdir -p "$(dirname "$BUILD_LOG")"
  ( cd "$DIR" && $DOCKER compose -p "$PROJECT" -f compose.yml --env-file .env up -d --build ) >"$BUILD_LOG" 2>&1 </dev/null &
  _pid=$! _s=0
  while kill -0 "$_pid" 2>/dev/null; do
    if [ -n "$INTERACTIVE" ]; then
      _l=$(grep -E '^#[0-9]+ \[' "$BUILD_LOG" 2>/dev/null | tail -1 | sed 's/^#[0-9]* //' | cut -c1-80)
      printf '\r\033[K  %ss  %s' "$_s" "$_l" >/dev/tty
    fi
    sleep 1; _s=$((_s + 1))
  done
  [ -z "$INTERACTIVE" ] || printf '\r\033[K' >/dev/tty
  if wait "$_pid"; then
    say "  built and started in ${_s}s (the build's log: $BUILD_LOG)"
  else
    tail -n 25 "$BUILD_LOG" >&2
    die "$EX_STEP" "docker compose up failed; its whole log is $BUILD_LOG"
  fi

  step "wait for the API"
  _base="http://127.0.0.1:$API_PORT"
  [ "$TARGET" = context ] && _base=$API_URL
  _ok=
  for _i in $(seq 1 120); do
    if curl -fsS "$_base/api/health" >/dev/null 2>&1; then _ok=1; break; fi
    sleep 3
  done
  [ -n "$_ok" ] || die "$EX_STEP" "$_base/api/health did not answer within 6 minutes: docker compose -p $PROJECT logs server"
  LOCAL_API=$_base

  step "the setup code"
  SETUP_CODE='' SET_UP=false
  case $(curl -fsS "$_base/api/setup" 2>/dev/null || echo '{}') in
    *'"setup_needed":false'*) SET_UP=true ;;
    *)
      # The server logs the code just after its API answers: give it a minute.
      for _i in $(seq 1 30); do
        SETUP_CODE=$( (cd "$DIR" && $DOCKER compose -p "$PROJECT" -f compose.yml logs server 2>/dev/null) | grep -oE '[A-Z2-7]{4}(-[A-Z2-7]{4}){7}' | tail -1 || true)
        [ -z "$SETUP_CODE" ] || break
        sleep 2
      done ;;
  esac

  json_set dir "$(json_str "$DIR")"
  json_set api_url "$(json_str "$API_URL")"
  json_set web_url "$(json_str "$WEB_URL")"
  json_set setup_code "$(json_str "$SETUP_CODE")"
  json_set already_set_up "$SET_UP"
  json_set updated "$SERVER_UPDATED"
  json_set ref "$(json_str "$REF")"

  say ""
  say "The server is up."
  say "  Web panel:  $WEB_URL"
  say "  API:        $API_URL"
  if [ "$SET_UP" = true ]; then
    say "  It already has an account: sign in there."
  elif [ -n "$SETUP_CODE" ]; then
    if [ -n "$WITH_SEAT" ]; then
      say "  Setup code:  $SETUP_CODE (used next to create your account: nothing to copy)"
    else
      say "  SETUP CODE: $SETUP_CODE"
      say "  Open the web panel and create your account with this setup code, then use Add a machine for each machine that runs Claude Code."
    fi
  else
    say "  No setup code in the log yet: docker compose -p $PROJECT logs server | grep -A3 'setup code'"
  fi
}

# --- the account, for --with-seat: create it with the setup code, or sign in ---------------
APP_TOKEN=
account() {
  URL=$LOCAL_API
  if [ "$SET_UP" = false ] && [ -n "$SETUP_CODE" ]; then
    ask EMAIL "Your email, for the new account" "" --email
    ask_secret _pw "A password for $EMAIL on this server (at least 12 characters): " CV_LOGIN_PASSWORD
    if [ -n "$INTERACTIVE" ] && [ -z "${CV_LOGIN_PASSWORD:-}" ]; then
      ask_secret _pw2 "The same password again: " CV_NO_SUCH_VAR
      [ "$_pw" = "$_pw2" ] || die "$EX_USAGE" "the two passwords differ"
    fi
    step "create the account $EMAIL"
    body _b email "$EMAIL" password "$_pw" code "$SETUP_CODE" scope app client installer
    api POST /api/setup "$_b"
  else
    ask EMAIL "Your email on this server" "" --email
    ask_secret _pw "Password for $EMAIL on $URL: " CV_LOGIN_PASSWORD
    step "sign in as $EMAIL"
    body _b email "$EMAIL" password "$_pw" scope app client installer
    api POST /api/auth/login "$_b"
  fi
  _pw= _pw2=
  [ "$API_STATUS" = 200 ] || die "$EX_JOIN" "the server refused: $(api_error)"
  APP_TOKEN=$(jfield "$API_BODY" token)
  [ -n "$APP_TOKEN" ] || die "$EX_STEP" "the server answered without a token"
}
signout() { [ -z "$APP_TOKEN" ] || { api DELETE /api/auth/logout "" "$APP_TOKEN"; APP_TOKEN=; }; }

# mint_join NAME: a one-time join code from this server (JOIN).
mint_join() {
  body _b machine "$1"
  api POST /api/join_codes "$_b" "$APP_TOKEN"
  [ "$API_STATUS" = 201 ] || die "$EX_STEP" "could not make a join code: $(api_error)"
  JOIN=$(jfield "$API_BODY" code)
}

# --- a machine that runs seats ------------------------------------------------------------
CONF_DIR='' CONF=''
node_major() { node -v 2>/dev/null | sed -n 's/^v\([0-9]*\).*/\1/p'; }

# host_online HOSTS_JSON NAME: whether GET /api/hosts lists NAME online. Parsed
# by node, which this machine has by then: a grep for "name" and "online" in
# one object broke when a host gained a nested object between them (the
# server's key order is not fixed).
host_online() {
  printf '%s' "$1" | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let hosts = [];
      try { hosts = JSON.parse(s).hosts || []; } catch {}
      process.exit(hosts.some((h) => h.name === process.argv[1] && h.online === true) ? 0 : 1);
    });' "$2"
}

machine_flow() {
  step "check the system"
  detect_os
  say "  $OS_NAME, $(id -un)@$(hostname)"
  case $JSON_FIELDS in *'"os":'*) ;; *) json_set os "$(json_str "$OS_NAME")" ;; esac
  CONF=${CLAUDIVERSE_HOST_AGENT_CONFIG:-$HOME/.config/claudiverse/host-agent.json}
  CONF_DIR=$(dirname "$CONF")
  # A claude that runs: ~/.local/bin's first (the native install), then
  # PATH's. A leftover npm install without its native binary is no claude.
  CLAUDE=''
  for _c in "$HOME/.local/bin/claude" "$(command -v claude 2>/dev/null || true)"; do
    if [ -n "$_c" ] && [ -x "$_c" ] && "$_c" --version >/dev/null 2>&1; then CLAUDE=$_c; break; fi
  done

  # What it was set up with before: an update keeps its server and tokens.
  OLD_URL='' OLD_SEAT='' OLD_HOST='' OLD_NAME='' MACHINE_UPDATED=false
  if [ -f "$CONF" ]; then
    MACHINE_UPDATED=true
    _c=$(cat "$CONF")
    OLD_URL=$(jfield "$_c" server); OLD_SEAT=$(jfield "$_c" seat_token); OLD_HOST=$(jfield "$_c" host_token); OLD_NAME=$(jfield "$_c" name)
  fi
  ask URL "The server's API address (e.g. http://my-server:4000)" "$OLD_URL" --url
  URL=${URL%/}
  case $URL in http://*|https://*) ;; *) die "$EX_USAGE" "--url must start with http:// or https://" ;; esac
  REJOIN=
  if [ -n "$JOIN$LOGIN_EMAIL" ] || [ -z "$OLD_HOST" ] || [ "$URL" != "$OLD_URL" ]; then REJOIN=1; fi
  if [ -n "$REJOIN" ] && [ -z "$JOIN$LOGIN_EMAIL" ]; then
    ask JOIN "Join code (the web panel's Add a machine makes one)" "" --join
  fi
  _host=$(hostname | cut -d. -f1 | tr -c 'A-Za-z0-9._\n-' '-')
  ask NAME "This machine's name" "${OLD_NAME:-$_host}" --name
  ask ROOTS "Folders seats may work in (comma-separated)" "$HOME/projects" --roots
  ask POOL_ONLY "Run seats on the server's account pool, not this machine's own claude login? (yes/no)" yes --pool-only
  case $POOL_ONLY in yes|no) ;; *) die "$EX_USAGE" "--pool-only is yes or no" ;; esac
  DIR=${DIR:-$HOME/claudiverse}

  # Prerequisites.
  PKGS='' NEED_NODE='' NEED_CLAUDE='' NEED_BREW=''
  has git || PKGS="$PKGS git"
  has curl || PKGS="$PKGS curl"
  has tmux || PKGS="$PKGS tmux"
  _nm=$(node_major); [ "${_nm:-0}" -ge 22 ] 2>/dev/null || NEED_NODE=1
  [ -n "$CLAUDE" ] || NEED_CLAUDE=1
  if [ "$OS_FAMILY" = alpine ]; then
    has bash || PKGS="$PKGS bash"
    for _p in libgcc libstdc++ ripgrep; do apk info -e "$_p" >/dev/null 2>&1 || PKGS="$PKGS $_p"; done
  fi
  if [ "$OS_FAMILY" = macos ] && [ -n "$PKGS$NEED_NODE" ] && ! has brew; then NEED_BREW=1; fi
  if [ -n "$PKGS$NEED_NODE$NEED_CLAUDE$NEED_BREW" ] && [ -n "$NO_INSTALL" ]; then
    die "$EX_UNSUPPORTED" "missing:$PKGS${NEED_NODE:+ node 22+}${NEED_CLAUDE:+ claude}${NEED_BREW:+ brew} (and --no-install)"
  fi
  [ -z "$NEED_BREW" ] || plan "install Homebrew (its official installer; it asks for your password)"
  [ -z "$PKGS" ] || plan "install$PKGS ($(pkg_source))"
  if [ -n "$NEED_NODE" ]; then
    case $OS_FAMILY in
      macos) plan "install node (Homebrew)" ;;
      arch) plan "install nodejs and npm (pacman)" ;;
      alpine) plan "install nodejs and npm (apk; needs Alpine 3.21+ for Node 22)" ;;
      *) plan "install Node.js 22+ (the distribution's package if new enough, else NodeSource)" ;;
    esac
  fi
  [ -z "$NEED_CLAUDE" ] || plan "install Claude Code (claude.ai/install.sh, into ~/.local/bin)"
  if [ -d "$DIR/.git" ]; then plan "update $DIR to $REF"; else plan "clone $REPO ($REF) into $DIR"; fi
  if [ -n "$REJOIN" ]; then
    plan "join $URL as $NAME${LOGIN_EMAIL:+ (signing in as $LOGIN_EMAIL for a join code)}"
  else
    plan "keep this machine's tokens for $URL"
  fi
  plan "write $CONF (roots: $ROOTS)"
  plan "install the claudiverse-seat mod into Claude Code, and the cv_* tools (npm install)"
  plan "start the host agent as a service"
}

# Node 22+, per platform.
install_node() {
  case $OS_FAMILY in
    macos) brew install node ;;
    arch) pkg_install nodejs npm ;;
    alpine) pkg_install nodejs npm ;;
    debian)
      _cand=$($SUDO apt-cache policy nodejs 2>/dev/null | sed -n 's/^ *Candidate: *\([0-9]*\).*/\1/p')
      if [ "${_cand:-0}" -lt 22 ] 2>/dev/null; then
        tmp NSRC; fetch https://deb.nodesource.com/setup_22.x "$NSRC"
        $SUDO bash "$NSRC" >/dev/null 2>&1 || die "$EX_STEP" "NodeSource's setup for Node 22 failed"
        APT_UPDATED=1
      fi
      pkg_install nodejs ;;
    fedora|rhel)
      $SUDO dnf install -y -q nodejs npm >/dev/null 2>&1 || true
      _nm=$(node_major)
      if [ "${_nm:-0}" -lt 22 ] 2>/dev/null; then
        $SUDO dnf module reset -y -q nodejs >/dev/null 2>&1 || true
        if ! $SUDO dnf module install -y -q nodejs:22/common >/dev/null 2>&1; then
          tmp NSRC; fetch https://rpm.nodesource.com/setup_22.x "$NSRC"
          $SUDO bash "$NSRC" >/dev/null 2>&1 || die "$EX_STEP" "NodeSource's setup for Node 22 failed"
          $SUDO dnf install -y -q nodejs >/dev/null || die "$EX_STEP" "dnf could not install Node 22"
        fi
      fi ;;
  esac
  _nm=$(node_major)
  [ "${_nm:-0}" -ge 22 ] 2>/dev/null || die "$EX_UNSUPPORTED" "Node.js 22 or newer is needed; $OS_NAME's package gives $(node -v 2>/dev/null || echo none)"
}

machine_act() {
  if [ -n "$NEED_BREW" ]; then
    step "install Homebrew"
    [ -n "$INTERACTIVE" ] || die "$EX_UNSUPPORTED" "Homebrew is missing; install it first (https://brew.sh): its installer needs a terminal"
    tmp BREWSH; fetch https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$BREWSH"
    /bin/bash "$BREWSH" </dev/tty || die "$EX_STEP" "Homebrew's installer failed"
    for _b in /opt/homebrew/bin /usr/local/bin; do [ -x "$_b/brew" ] && PATH="$_b:$PATH"; done
  fi
  if [ -n "$PKGS$NEED_NODE" ]; then
    step "install prerequisites"
    [ "$OS_FAMILY" = macos ] || need_root "install packages"
    [ -z "$PKGS" ] || pkg_install $PKGS
    [ -z "$NEED_NODE" ] || install_node
  fi
  if [ -n "$NEED_CLAUDE" ]; then
    step "install Claude Code"
    tmp CLSH; fetch https://claude.ai/install.sh "$CLSH"
    bash "$CLSH" >/dev/null 2>&1 || die "$EX_STEP" "Claude Code's installer failed (claude.ai/install.sh)"
    CLAUDE=$HOME/.local/bin/claude
    [ -x "$CLAUDE" ] || die "$EX_STEP" "Claude Code's installer left no $CLAUDE"
  fi
  CLAUDE_VERSION=$("$CLAUDE" --version 2>/dev/null | cut -d' ' -f1)

  step "get the code"
  git_sync "$DIR"

  if [ -n "$REJOIN" ]; then
    if [ -n "$LOGIN_EMAIL" ] && [ -z "$JOIN" ]; then
      EMAIL=$LOGIN_EMAIL SET_UP=true LOCAL_API=$URL
      account
      mint_join "$NAME"
      signout
    fi
    step "join $URL as $NAME"
    body _b code "$JOIN" machine "$NAME"
    api POST /api/join "$_b"
    case $API_STATUS in
      200) ;;
      000) die "$EX_STEP" "could not reach $URL" ;;
      *) die "$EX_JOIN" "the server refused the join code: $(api_error)" ;;
    esac
    SEAT_TOKEN=$(jfield "$API_BODY" seat_token); HOST_TOKEN=$(jfield "$API_BODY" host_token); NAME=$(jfield "$API_BODY" machine)
    [ -n "$SEAT_TOKEN" ] && [ -n "$HOST_TOKEN" ] || die "$EX_STEP" "the server answered the join without tokens"
  else
    SEAT_TOKEN=$OLD_SEAT HOST_TOKEN=$OLD_HOST
  fi

  # Right after the join: the code is spent, so its tokens are saved before
  # anything else can fail, and a second run goes on from here without one.
  step "write the host agent's config"
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  for _r in $(printf '%s' "$ROOTS" | tr ',' ' '); do mkdir -p "$_r"; done
  # Written by node, which merges into an existing config: tokens reach it in
  # its environment, never on a command line.
  CV_URL=$URL CV_SEAT=$SEAT_TOKEN CV_HOST=$HOST_TOKEN CV_NAME=$NAME CV_ROOTS=$ROOTS CV_DIR=$DIR CV_CLAUDE=$CLAUDE \
  CV_CLAUDE_VERSION=$CLAUDE_VERSION CV_POOL=$POOL_ONLY CV_CONF=$CONF CV_CONF_DIR=$CONF_DIR node -e '
    const fs = require("fs"), e = process.env;
    const read = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };
    const c = read(e.CV_CONF) || {};
    Object.assign(c, { server: e.CV_URL, host_token: e.CV_HOST, seat_token: e.CV_SEAT, name: e.CV_NAME,
      cv_spawn: e.CV_DIR + "/agent/tools/cv-spawn.sh" });
    c.roots = e.CV_ROOTS.split(",").map((r) => r.trim()).filter(Boolean);
    c.runtimes = c.runtimes || {};
    c.runtimes["stock+mod"] = { bin: e.CV_CLAUDE, version: e.CV_CLAUDE_VERSION, ...(e.CV_POOL === "yes" ? { pool_only: true } : {}) };
    c.spawn_runtime = c.spawn_runtime || "stock+mod";
    c.modes = c.modes || ["default", "acceptEdits", "plan", "auto"];
    fs.writeFileSync(e.CV_CONF, JSON.stringify(c, null, 2) + "\n", { mode: 0o600 });
    const cat = e.CV_CONF_DIR + "/mcp-catalog.json";
    if (!read(cat)) fs.writeFileSync(cat, JSON.stringify({ mcpServers: { claudiverse: { command: "node",
      args: [e.CV_DIR + "/agent/tools/cv-mcp.mjs"], env: { CLAUDIVERSE_URL: e.CV_URL, CLAUDIVERSE_TOKEN: e.CV_SEAT } } } }, null, 2) + "\n", { mode: 0o600 });
  ' || die "$EX_STEP" "could not write $CONF"
  chmod 600 "$CONF"

  step "install the seat mod"
  if "$CLAUDE" plugin marketplace list 2>/dev/null | grep -q claudiverse; then
    "$CLAUDE" plugin marketplace update claudiverse >/dev/null 2>&1 || true
  else
    "$CLAUDE" plugin marketplace add "$DIR" >/dev/null || die "$EX_STEP" "claude plugin marketplace add $DIR failed"
  fi
  if "$CLAUDE" plugin list 2>/dev/null | grep -q 'claudiverse-seat@claudiverse'; then
    "$CLAUDE" plugin update claudiverse-seat@claudiverse >/dev/null 2>&1 || true
  else
    "$CLAUDE" plugin install claudiverse-seat@claudiverse >/dev/null || die "$EX_STEP" "claude plugin install claudiverse-seat failed"
  fi
  printf '{"server_url":%s,"seat_token":%s}' "$(json_str "$URL")" "$(json_str "$SEAT_TOKEN")" \
    | "$CLAUDE" plugin configure claudiverse-seat@claudiverse --values-stdin >/dev/null || die "$EX_STEP" "configuring the seat mod failed"

  step "install the cv_* tools"
  ( cd "$DIR/agent/tools" && npm install --no-audit --no-fund --loglevel=error >/dev/null ) || die "$EX_STEP" "npm install in $DIR/agent/tools failed"

  step "start the host agent"
  case $OS_FAMILY in
    macos) SERVICE=launchd ;;
    *) if [ -d /run/systemd/system ]; then SERVICE=systemd; elif has openrc-run || has rc-service; then SERVICE=openrc; else
         die "$EX_UNSUPPORTED" "no systemd and no OpenRC here: the host agent needs one of them to run as a service"; fi ;;
  esac
  _wrap=
  if [ "$SERVICE" != launchd ] && [ "$(id -u)" != 0 ]; then
    need_root "start the host agent's service"
    if [ "$SUDO" = sudo_pw ]; then
      tmp _wrap
      printf '#!/bin/sh\nprintf "%%s\\n" "$CV_SUDO_PASSWORD" | sudo -S -p "" "$@"\n' > "$_wrap"; chmod 700 "$_wrap"
    fi
    if [ "$SERVICE" = systemd ]; then
      $SUDO loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || say "  (could not enable linger: the agent stops when you log out)"
      if [ -z "${XDG_RUNTIME_DIR:-}" ]; then XDG_RUNTIME_DIR=/run/user/$(id -u); export XDG_RUNTIME_DIR; fi
      for _i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$XDG_RUNTIME_DIR/bus" ] && break; sleep 1; done
    fi
  fi
  if [ -n "$SERVICE_LABEL" ]; then
    case $SERVICE_LABEL in *[!A-Za-z0-9._-]*) die "$EX_USAGE" "--service-label is A-Z a-z 0-9 . _ -" ;; esac
  fi
  CV_SUDO_PASSWORD=${CV_SUDO_PASSWORD:-} SUDO=${_wrap:-${SUDO:-sudo}} \
    CLAUDIVERSE_HOST_AGENT_CONFIG=$CONF CV_AGENT_LABEL=${SERVICE_LABEL:-no.claudiverse.host-agent} CV_AGENT_UNIT=${SERVICE_LABEL:-claudiverse-host-agent}.service \
    bash "$DIR/agent/host/install.sh" >&2 || die "$EX_STEP" "the host agent's install.sh failed"

  step "wait for the host agent to come online"
  _online=
  for _i in $(seq 1 30); do
    api GET /api/hosts "" "$SEAT_TOKEN"
    if host_online "$API_BODY" "$NAME"; then _online=1; break; fi
    sleep 2
  done
  [ -n "$_online" ] || die "$EX_STEP" "the host agent did not come online at $URL within a minute; see its log (journalctl --user -u ${SERVICE_LABEL:-claudiverse-host-agent}, or ~/Library/Logs)"

  json_set machine "$(json_str "$NAME")"
  json_set server "$(json_str "$URL")"
  json_set machine_dir "$(json_str "$DIR")"
  json_set service "$(json_str "$SERVICE")"
  json_set agent_online true
  json_set machine_updated "$MACHINE_UPDATED"
  say ""
  say "This machine is connected: $NAME, online at $URL ($SERVICE)."
}

# A first seat on the machine just connected, started through the server.
# Not on an update: that machine has its seats already.
first_seat() {
  if [ "${MACHINE_UPDATED:-false}" = true ]; then
    say "This machine was set up before: no new first seat."
    json_set seat null
    return 0
  fi
  # In the first allowed folder: the agent starts seats only inside its roots.
  _path=$(printf '%s' "$ROOTS" | cut -d, -f1)
  step "start a first seat, hello, in $_path"
  body _b path "$_path" title hello
  api POST "/api/hosts/$NAME/spawn" "$_b" "$APP_TOKEN"
  case $API_STATUS in 202) ;; *) say "  could not start it: $(api_error). Start one from the apps' New seat, or with the agent's spawn."; json_set seat null; return 0 ;; esac
  _seen=
  for _i in $(seq 1 45); do
    # The server filters: only running seats titled hello, so any row is it.
    api GET "/api/sessions?title=hello" "" "$APP_TOKEN"
    case $API_BODY in *'"title":"hello"'*) _seen=1; break ;; esac
    sleep 2
  done
  json_set seat "$(json_str hello)"
  json_set seat_registered "$([ -n "$_seen" ] && echo true || echo false)"
  if [ -n "$_seen" ]; then
    say "A first seat, hello, is running on $NAME: open it in the web panel."
  else
    say "The seat hello was started; it has not shown up in the server yet (see the web panel in a minute)."
  fi
}

# --- main ------------------------------------------------------------------------------------
parse "$@"
read_secrets
if [ -z "$YES" ] && [ -z "$SECRETS_STDIN" ] && tty_ok; then INTERACTIVE=1; fi
REF=${REF:-main}
REPO=${REPO:-$DEFAULT_REPO}

say "Claudiverse installer"
if [ -z "$MODE" ]; then
  if [ -n "$INTERACTIVE" ]; then
    printf '\nWhat do you want to do?\n  1) Set up a Claudiverse server\n  2) Connect this or another machine to an existing server\n' >/dev/tty
    ask _what "Choose" 1 --server
    case $_what in 1|server) MODE=server ;; 2|machine) MODE=machine ;; *) die "$EX_USAGE" "choose 1 or 2" ;; esac
  else
    die "$EX_USAGE" "missing --server or --machine (what to do)"
  fi
fi
case $MODE in server|machine) ;; *) die "$EX_USAGE" "--mode is server or machine" ;; esac
json_set mode "$(json_str "$MODE")"
[ "$MODE" = server ] || [ -z "$WITH_SEAT" ] || die "$EX_USAGE" "--with-seat goes with --server"

# A join code was made for the machine that runs the command: no question.
if [ "$MODE" = machine ] && [ -n "$JOIN" ] && [ -z "$TARGET" ]; then TARGET=local; fi
if [ -z "$TARGET" ] && [ -n "$INTERACTIVE" ]; then
  if [ "$MODE" = server ]; then
    printf '\nWhere should the server run?\n  1) this machine\n  2) another machine, over SSH\n  3) an existing Docker context\n' >/dev/tty
  else
    printf '\nWhich machine?\n  1) this machine\n  2) another machine, over SSH\n' >/dev/tty
  fi
  ask _where "Choose" 1 --target
  case $_where in 1) TARGET=local ;; 2) TARGET=ssh ;; 3) TARGET=context ;; *) TARGET=$_where ;; esac
fi
TARGET=${TARGET:-local}
if [ -n "$REMOTE_RUN" ]; then json_set target '"ssh"'; json_set host "$(json_str "$(hostname)")"; else json_set target "$(json_str "$TARGET")"; fi
case $MODE:$TARGET in
  *:local|server:context) ;;
  *:ssh)
    ask SSH_DEST "SSH destination (user@host)" "" --ssh
    ask SSH_PORT "SSH port" 22 --port
    [ "${SEAT_TARGET:-local}" = local ] || die "$EX_USAGE" "with --target ssh the seat machine is that same machine: leave out --seat-target"
    remote_args "$@"
    run_remote ;;
  *) die "$EX_USAGE" "--target must be local or ssh (or context, with --server)" ;;
esac

if [ "$MODE" = machine ]; then
  machine_flow
  confirm
  machine_act
  say "Next: in the web panel, Start a seat on $NAME."
  json_out true 0
  exit 0
fi

# The server, and with --with-seat a machine for its seats.
server_flow
if [ -z "$WITH_SEAT" ] && [ -n "$INTERACTIVE" ] && [ -z "$DRY_RUN" ] && yesno "After the server, set up a machine for seats and start a first seat?" y; then WITH_SEAT=1; fi
SEAT_REMOTE=0
if [ -n "$WITH_SEAT" ]; then
  if [ -z "$SEAT_TARGET" ] && [ -n "$INTERACTIVE" ]; then
    printf '\nWhich machine runs the seats?\n  1) this machine\n  2) another machine, over SSH\n' >/dev/tty
    ask _sw "Choose" 1 --seat-target
    case $_sw in 1) SEAT_TARGET=local ;; 2) SEAT_TARGET=ssh ;; *) SEAT_TARGET=$_sw ;; esac
  fi
  SEAT_TARGET=${SEAT_TARGET:-local}
  case $SEAT_TARGET in
    local) plan "then make this machine a seat machine of the new server, and start a first seat" ;;
    ssh)
      ask SSH_DEST "The seat machine over SSH (user@host)" "" --ssh
      ask SSH_PORT "Its SSH port" 22 --port
      SEAT_REMOTE=1
      plan "then make $SSH_DEST a seat machine of the new server (over SSH), and start a first seat" ;;
    *) die "$EX_USAGE" "--seat-target is local or ssh" ;;
  esac
fi
confirm
server_act
[ -n "$WITH_SEAT" ] || { json_out true 0; exit 0; }

step "set up the seat machine"
account
_name_default=$(hostname | cut -d. -f1 | tr -c 'A-Za-z0-9._\n-' '-')
[ "$SEAT_REMOTE" = 1 ] && _name_default=$(printf '%s' "$SSH_DEST" | sed 's/.*@//' | tr -c 'A-Za-z0-9._\n-' '-')
NAME=${NAME:-$_name_default}
mint_join "$NAME"
URL=$API_URL
if [ "$SEAT_REMOTE" = 1 ]; then
  # The machine half runs there; the join code goes on its stdin with the other secrets.
  REMOTE_ARGS="--machine --yes --url $(q "$URL") --name $(q "$NAME")"
  [ -z "$ROOTS" ] || REMOTE_ARGS="$REMOTE_ARGS --roots $(q "$ROOTS")"
  [ -z "$POOL_ONLY" ] || REMOTE_ARGS="$REMOTE_ARGS --pool-only $(q "$POOL_ONLY")"
  [ -z "$SERVICE_LABEL" ] || REMOTE_ARGS="$REMOTE_ARGS --service-label $(q "$SERVICE_LABEL")"
  REMOTE_ARGS="$REMOTE_ARGS --ref $(q "$REF") --repo $(q "$REPO")"
  CV_JOIN_CODE=$JOIN RUN_REMOTE_RETURN=1 run_remote >&2 || die "$EX_STEP" "setting up $SSH_DEST failed (see above)"
  ROOTS=${ROOTS:-${REMOTE_HOME:-/home/${SSH_DEST%%@*}}/projects}
else
  machine_flow
  machine_act
fi
URL=$LOCAL_API
first_seat
signout
say ""
say "Done. Open the web panel: $WEB_URL"
say "  Sign in as $EMAIL. Add your Claude accounts under Accounts, so seats can answer."
json_out true 0
