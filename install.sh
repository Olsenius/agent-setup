#!/usr/bin/env bash
# agent-setup: turn a fresh VM, VPS, or container into an agent host for a private vault repo.
#
#   curl -fsSL https://raw.githubusercontent.com/olsenius/agent-setup/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/olsenius/agent-setup/main/install.sh | bash -s -- --help
#
# https://github.com/olsenius/agent-setup (MIT). This file contains no secrets.
# Only definitions live at the top level; all work happens in main(), called on the last line,
# so a partially downloaded script does nothing.
# shellcheck disable=SC2034 # temporary: globals used by steps added in later phases

AGENT_SETUP_VERSION="0.1.0"
DEFAULT_REPO="olsenius/agent"
KEY_BASENAME="olsenius-agent_ed25519"
KEY_TITLE_PREFIX="olsenius-agent"
SUPPORTED_CONTRACT="1"
META_URL="https://api.github.com/meta"
# github.com SSH host key fingerprints (Ed25519, ECDSA, RSA), as published in "GitHub's SSH key fingerprints":
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# Verified 2026-09-27. The known-hosts CI job fails if GitHub rotates them.
GITHUB_FINGERPRINTS="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"

# ---------------------------------------------------------------------------------------------------------
# Output

C_RESET="" C_BOLD="" C_RED="" C_YELLOW="" C_GREEN=""
setup_colors() {
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_RED=$'\033[31m' C_YELLOW=$'\033[33m' C_GREEN=$'\033[32m'
  fi
}

info() { printf '%s\n' "$*"; }
step() { printf '%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
  local code=$1
  shift
  printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit "$code"
}
is_dry() { [[ $DRY_RUN == 1 ]]; }
would() { printf '[dry-run] would %s\n' "$*"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------------------------------------------------
# Temp files: registered here, removed on EXIT, INT, and TERM.

TMP_PATHS=()
cleanup() {
  local p
  for p in ${TMP_PATHS[@]+"${TMP_PATHS[@]}"}; do rm -rf "$p"; done
}
# make_temp <dir>: create a mode-600 temp file in <dir>; path in $REPLY.
make_temp() {
  REPLY=$(mktemp "$1/.agent-setup.XXXXXX")
  TMP_PATHS+=("$REPLY")
}

# ---------------------------------------------------------------------------------------------------------
# Usage

usage() {
  cat <<'EOF'
agent-setup: make this host an agent host for a private vault repo.

Usage:
  curl -fsSL https://raw.githubusercontent.com/olsenius/agent-setup/main/install.sh | bash
  curl -fsSL .../install.sh | bash -s -- [options]

Examples:
  # gh logged in as repo admin: generate key, register it, clone, link
  curl -fsSL .../install.sh | bash
  # flags through a pipe need `bash -s --`
  curl -fsSL .../install.sh | bash -s -- --agent chief-of-staff,vigilo --tools grok --host grok-box
  # existing deploy key from a file
  curl -fsSL .../install.sh | bash -s -- --key-file /run/secrets/olsenius-agent --agent codex
  # existing deploy key injected as a secret (AGENT_DEPLOY_KEY_B64 set by the platform's secret store)
  curl -fsSL .../install.sh | AGENT=chief-of-staff AGENT_HOST=grok-box TOOLS=grok bash
  # inspect only
  curl -fsSL .../install.sh | bash -s -- --status

Options (flag / environment variable; flags win):
  --repo OWNER/NAME     AGENT_REPO             private repo (default: olsenius/agent)
  --repo-dir PATH       REPO_DIR               clone location (default: ~/agent)
  --agent A,B           AGENT                  agents to register (kebab-case)
  --host NAME           AGENT_HOST             stable host name (default: hostname -s)
  --tools A,B           TOOLS                  tools to link: claude,codex,hermes,openclaw,grok (default: auto)
  --key-file PATH       AGENT_DEPLOY_KEY_FILE  existing private deploy key
                        AGENT_DEPLOY_KEY       existing private key, OpenSSH format, multi-line
                        AGENT_DEPLOY_KEY_B64   same, base64-encoded
  --replace-key         AGENT_REPLACE_KEY=1    let a supplied key replace a different key on disk
  --read-only           AGENT_READ_ONLY=1      register a read-only deploy key (automatic path)
  --timeout DUR         AGENT_GRANT_TIMEOUT    wait for a manual grant, e.g. 90s, 15m, 1h (default: 15m)
                        AGENT_NONINTERACTIVE=1 never prompt, even if a terminal is available
                        AGENT_ALLOW_ROOT=1     allow running as root (containers)
  --no-register                                skip scripts/agent-register.sh
  --no-link                                    skip scripts/tool-link.sh
  --status                                     print state and exit (0 = all OK, 1 = something missing)
  --dry-run                                    print actions without changing anything
  --print-pubkey                               ensure a key exists, print public key and fingerprint, exit
  --version                                    print version
  --help                                       this help

Private keys are never accepted as command-line arguments (visible in ps and shell history).

Exit codes: 0 ok, 1 missing dependency / invalid option / private-repo script failed,
2 timed out waiting for a manual grant, 3 refused to run as root, 4 supplied key rejected,
5 GitHub host key verification failed, 6 deploy key title exists with a different key,
7 REPO_DIR exists but is not a clone of the repo.
EOF
}

# ---------------------------------------------------------------------------------------------------------
# Options

need_value() {
  [[ $# -ge 2 && -n $2 && $2 != --* ]] || die 1 "$1 needs a value"
}

# parse_duration <90s|15m|1h|90>: seconds in $REPLY.
parse_duration() {
  local n=${1%[smh]} unit=${1##*[0-9]}
  [[ $n =~ ^[0-9]+$ ]] || die 1 "invalid duration: $1 (use e.g. 90s, 15m, 1h)"
  case $unit in
    "" | s) REPLY=$n ;;
    m) REPLY=$((n * 60)) ;;
    h) REPLY=$((n * 3600)) ;;
    *) die 1 "invalid duration: $1" ;;
  esac
}

parse_args() {
  OPT_REPO=${AGENT_REPO:-$DEFAULT_REPO}
  OPT_DIR=${REPO_DIR:-$HOME/agent}
  OPT_AGENTS=${AGENT:-}
  OPT_HOST=${AGENT_HOST:-}
  OPT_TOOLS=${TOOLS:-}
  OPT_KEY_FILE=${AGENT_DEPLOY_KEY_FILE:-}
  OPT_REPLACE=${AGENT_REPLACE_KEY:-0}
  OPT_READ_ONLY=${AGENT_READ_ONLY:-0}
  OPT_TIMEOUT=${AGENT_GRANT_TIMEOUT:-15m}
  NO_REGISTER=0 NO_LINK=0 DRY_RUN=0 MODE=install

  while (($#)); do
    if [[ $1 == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
    case $1 in
      --repo) need_value "$@" && OPT_REPO=$2 && shift ;;
      --repo-dir) need_value "$@" && OPT_DIR=$2 && shift ;;
      --agent) need_value "$@" && OPT_AGENTS=$2 && shift ;;
      --host) need_value "$@" && OPT_HOST=$2 && shift ;;
      --tools) need_value "$@" && OPT_TOOLS=$2 && shift ;;
      --key-file) need_value "$@" && OPT_KEY_FILE=$2 && shift ;;
      --timeout) need_value "$@" && OPT_TIMEOUT=$2 && shift ;;
      --replace-key) OPT_REPLACE=1 ;;
      --read-only) OPT_READ_ONLY=1 ;;
      --no-register) NO_REGISTER=1 ;;
      --no-link) NO_LINK=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --status) MODE=status ;;
      --print-pubkey) MODE=print-pubkey ;;
      --version)
        info "agent-setup $AGENT_SETUP_VERSION"
        exit 0
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die 1 "unknown option: $1 (see --help)" ;;
    esac
    shift
  done

  [[ $OPT_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 1 "invalid --repo: $OPT_REPO (want owner/name)"
  case $OPT_DIR in \~ | \~/*) OPT_DIR=$HOME${OPT_DIR#\~} ;; esac
  local a
  IFS=, read -r -a AGENT_LIST <<<"$OPT_AGENTS"
  for a in ${AGENT_LIST[@]+"${AGENT_LIST[@]}"}; do
    [[ $a =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die 1 "invalid agent name: '$a' (kebab-case: a-z, 0-9, -)"
  done
  [[ -z $OPT_TOOLS || $OPT_TOOLS =~ ^[a-z0-9,-]+$ ]] || die 1 "invalid --tools: $OPT_TOOLS"
  case $OPT_KEY_FILE in \~/*) OPT_KEY_FILE=$HOME/${OPT_KEY_FILE#\~/} ;; esac
  parse_duration "$OPT_TIMEOUT"
  GRANT_TIMEOUT=$REPLY

  # Test-only: AGENT_SETUP_REPO_URL points the clone at another URL (e.g. file:///tmp/fake-vault.git) so the
  # flow can be tested without GitHub. It does not bypass key validation.
  CLONE_URL=${AGENT_SETUP_REPO_URL:-git@github.com:$OPT_REPO.git}
}

# ---------------------------------------------------------------------------------------------------------
# Preflight and host

REQUIRED_CMDS="git ssh ssh-keygen curl base64 hostname"

missing_deps() {
  local c out=""
  for c in $REQUIRED_CMDS; do
    command -v "$c" >/dev/null 2>&1 || out="$out $c"
  done
  printf '%s' "${out# }"
}

install_hint() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "sudo apt-get update && sudo apt-get install -y git openssh-client curl coreutils hostname"
  elif command -v dnf >/dev/null 2>&1; then
    echo "sudo dnf install -y git openssh-clients curl coreutils hostname"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk add bash git openssh-client openssh-keygen curl coreutils"
  elif command -v brew >/dev/null 2>&1; then
    echo "brew install git curl"
  else
    echo "install: $REQUIRED_CMDS"
  fi
}

preflight() {
  if [[ $(id -u) -eq 0 && ${AGENT_ALLOW_ROOT:-} != 1 ]]; then
    die 3 "refusing to run as root; run as the user the agents run as (containers: AGENT_ALLOW_ROOT=1)"
  fi
  [[ $MODE == status ]] && return 0
  local missing
  missing=$(missing_deps)
  if [[ -n $missing ]]; then
    die 1 "missing: $missing. Install with: $(install_hint)"
  fi
}

resolve_host() {
  local raw
  if [[ -n $OPT_HOST ]]; then
    raw=$OPT_HOST HOST_SOURCE="AGENT_HOST"
  else
    raw=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true) HOST_SOURCE="hostname"
  fi
  [[ $raw =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "invalid host name '$raw'; set AGENT_HOST (or --host) to [A-Za-z0-9._-]"
  HOST=$(lower "$raw")
  EPHEMERAL=0
  if [[ $HOST_SOURCE == hostname ]] &&
    [[ $HOST =~ ^[0-9a-f]{12,}$ || $HOST =~ ^(runner|codespaces|cursor|buildkitsandbox|ip-[0-9]|localhost$) ]]; then
    EPHEMERAL=1
    warn "host name '$HOST' looks ephemeral; set AGENT_HOST (or --host) to a stable name"
  fi
  SSH_DIR=$HOME/.ssh
  KEY=$SSH_DIR/$KEY_BASENAME
  PUB=$KEY.pub
  KEY_TITLE=$KEY_TITLE_PREFIX@$HOST
}

# ---------------------------------------------------------------------------------------------------------
# Steps (filled in by later phases)

resolve_key() { :; }
setup_known_hosts() { :; }
ensure_access() { :; }
clone_or_update() { :; }
apply_config() { :; }
run_private_scripts() { :; }
print_status() { :; }

# ---------------------------------------------------------------------------------------------------------

main() {
  set -euo pipefail
  case $- in *x*) set +x ;; esac # never trace: keys pass through variables
  umask 077
  setup_colors
  parse_args "$@"
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT
  trap 'cleanup; exit 143' TERM
  preflight
  resolve_host

  if [[ $MODE == status ]]; then
    print_status
    exit $?
  fi

  step "Deploy key"
  resolve_key
  step "GitHub host keys"
  setup_known_hosts
  step "Repo access"
  ensure_access
  step "Clone"
  clone_or_update
  step "Git config"
  apply_config
  run_private_scripts
  if is_dry; then
    info "Dry run complete: nothing was changed."
  fi
}

# Sourced (tests): define functions only. Executed or piped: run.
if (return 0 2>/dev/null); then return 0; fi
main "$@"
