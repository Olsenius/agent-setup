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
  # Never leave an admin token behind if we logged gh in and then failed before the normal logout prompt.
  if [[ ${GH_LOGGED_IN_BY_US:-0} == 1 ]]; then gh auth logout --hostname github.com </dev/null >/dev/null 2>&1 || true; fi
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
# Deploy key. The private key is never printed: only the public key and its fingerprint.

ensure_ssh_dir() {
  [[ -d $SSH_DIR ]] && return 0
  if is_dry; then
    would "create $SSH_DIR (mode 700)"
  else
    mkdir -m 700 "$SSH_DIR"
  fi
}

# pubkey_of <private key file>: "type base64" on stdout; fails if malformed or passphrase-protected.
pubkey_of() {
  local out
  out=$(ssh-keygen -y -P '' -f "$1" 2>/dev/null </dev/null) || return 1
  [[ -n $out ]] || return 1
  printf '%s\n' "$out" | awk '{ print $1 " " $2 }'
}

# fingerprint <"type base64">: SHA256 fingerprint.
fingerprint() {
  local t
  make_temp "${TMPDIR:-/tmp}"
  t=$REPLY
  printf '%s\n' "$1" >"$t"
  ssh-keygen -lf "$t" 2>/dev/null | awk '{ print $2 }'
  rm -f "$t"
}

b64_decode() {
  if base64 -d </dev/null >/dev/null 2>&1; then base64 -d; else base64 -D; fi
}

write_pub() {
  printf '%s %s\n' "$1" "$KEY_TITLE" >"$PUB.tmp"
  chmod 644 "$PUB.tmp"
  mv "$PUB.tmp" "$PUB"
}

# install_supplied_key <file|env|b64>
install_supplied_key() {
  local kind=$1 dir tmp value pub existing stamp
  if is_dry; then dir=${TMPDIR:-/tmp}; else
    ensure_ssh_dir
    dir=$SSH_DIR
  fi
  make_temp "$dir"
  tmp=$REPLY
  case $kind in
    file)
      [[ -r $OPT_KEY_FILE ]] || die 4 "cannot read key file: $OPT_KEY_FILE"
      tr -d '\r' <"$OPT_KEY_FILE" >"$tmp"
      KEY_SOURCE="key file $OPT_KEY_FILE"
      ;;
    env)
      value=$AGENT_DEPLOY_KEY
      # Some secret stores flatten newlines to a literal \n.
      if [[ $value != *$'\n'* && $value == *'\n'* ]]; then value=${value//\\n/$'\n'}; fi
      printf '%s' "$value" | tr -d '\r' >"$tmp"
      KEY_SOURCE="AGENT_DEPLOY_KEY"
      ;;
    b64)
      if ! printf '%s' "$AGENT_DEPLOY_KEY_B64" | tr -d '\r\n\t ' | b64_decode >"$tmp" 2>/dev/null; then
        die 4 "AGENT_DEPLOY_KEY_B64 is not valid base64"
      fi
      tr -d '\r' <"$tmp" >"$tmp.lf" && mv "$tmp.lf" "$tmp"
      KEY_SOURCE="AGENT_DEPLOY_KEY_B64"
      ;;
  esac
  unset AGENT_DEPLOY_KEY AGENT_DEPLOY_KEY_B64 value
  if [[ -n $(tail -c 1 "$tmp") ]]; then printf '\n' >>"$tmp"; fi
  chmod 600 "$tmp"

  pub=$(pubkey_of "$tmp") ||
    die 4 "key is invalid or has a passphrase; deploy keys for agents must be passphrase-less"
  [[ $pub == "ssh-ed25519 "* ]] ||
    die 4 "key type is ${pub%% *}; only ssh-ed25519 deploy keys are accepted (what the vault's tooling mints)"

  if [[ -f $KEY ]]; then
    existing=$(pubkey_of "$KEY" || true)
    if [[ $existing == "$pub" ]]; then
      KEY_SOURCE="$KEY_SOURCE (same as existing key)"
      PUBKEY=$pub
      if [[ ! -f $PUB ]] && ! is_dry; then write_pub "$pub"; fi
      return 0
    fi
    if [[ $OPT_REPLACE != 1 ]]; then
      die 4 "supplied key differs from the existing $KEY
  existing: $(fingerprint "${existing:-unreadable}")
  supplied: $(fingerprint "$pub")
Use --replace-key (or AGENT_REPLACE_KEY=1) to replace it; the old pair is kept as .bak-<timestamp>."
    fi
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    if is_dry; then
      would "back up $KEY and $PUB to *.bak-$stamp"
    else
      mv "$KEY" "$KEY.bak-$stamp"
      if [[ -f $PUB ]]; then mv "$PUB" "$PUB.bak-$stamp"; fi
      info "backed up the previous key pair to $KEY.bak-$stamp"
    fi
  fi
  PUBKEY=$pub
  if is_dry; then
    would "install the supplied key at $KEY"
    return 0
  fi
  mv "$tmp" "$KEY"
  write_pub "$pub"
}

generate_key() {
  KEY_SOURCE="generated"
  if is_dry; then
    would "generate an ed25519 key at $KEY"
    PUBKEY=""
    return 0
  fi
  ensure_ssh_dir
  ssh-keygen -q -t ed25519 -N '' -C "$KEY_TITLE" -f "$KEY" </dev/null
  chmod 600 "$KEY"
  chmod 644 "$PUB"
  PUBKEY=$(pubkey_of "$KEY")
}

use_existing_key() {
  KEY_SOURCE="existing key"
  PUBKEY=$(pubkey_of "$KEY") ||
    die 4 "$KEY is invalid or has a passphrase; move it away or supply a key with --replace-key"
  [[ $PUBKEY == "ssh-ed25519 "* ]] || die 4 "$KEY is not an ed25519 key"
  if [[ ! -f $PUB ]] && ! is_dry; then write_pub "$PUBKEY"; fi
}

resolve_key() {
  local sources=""
  [[ -z $OPT_KEY_FILE ]] || sources="$sources --key-file/AGENT_DEPLOY_KEY_FILE"
  [[ -z ${AGENT_DEPLOY_KEY:-} ]] || sources="$sources AGENT_DEPLOY_KEY"
  [[ -z ${AGENT_DEPLOY_KEY_B64:-} ]] || sources="$sources AGENT_DEPLOY_KEY_B64"
  case $sources in
    *" "*" "*) die 4 "more than one key source set:$sources; supply exactly one" ;;
    *--key-file*) install_supplied_key file ;;
    *AGENT_DEPLOY_KEY_B64*) install_supplied_key b64 ;;
    *AGENT_DEPLOY_KEY*) install_supplied_key env ;;
    *) if [[ -f $KEY ]]; then use_existing_key; else generate_key; fi ;;
  esac
  unset AGENT_DEPLOY_KEY AGENT_DEPLOY_KEY_B64
  if [[ -n $PUBKEY ]]; then info "key: $KEY ($KEY_SOURCE), $(fingerprint "$PUBKEY")"; fi
}

# ---------------------------------------------------------------------------------------------------------
# Steps (filled in by later phases)

# True when the clone goes over SSH to github.com (the normal case; tests use file:// URLs).
uses_github_ssh() {
  [[ $CLONE_URL == git@github.com:* || $CLONE_URL == ssh://git@github.com/* ]]
}

# github_host_keys: "type base64" lines for github.com. Prefers GitHub's published list over TLS; falls back to
# ssh-keyscan and then requires every key to match GITHUB_FINGERPRINTS (exit 5 on any mismatch).
github_host_keys() {
  local meta keys line fp
  if meta=$(curl -fsSL --max-time 20 "$META_URL" 2>/dev/null); then
    keys=$(grep -oE '"(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+"' <<<"$meta" | tr -d '"' || true)
    if [[ -n $keys ]]; then
      printf '%s\n' "$keys"
      return 0
    fi
  fi
  warn "could not read ssh_keys from $META_URL; falling back to ssh-keyscan with fingerprint verification"
  keys=$(ssh-keyscan -t ed25519,ecdsa,rsa github.com 2>/dev/null </dev/null |
    awk '$1 == "github.com" { print $2 " " $3 }' || true)
  [[ -n $keys ]] || die 5 "ssh-keyscan returned no host keys for github.com"
  while IFS= read -r line; do
    fp=$(fingerprint "$line")
    case " $GITHUB_FINGERPRINTS " in
      *" $fp "*) ;;
      *) die 5 "github.com host key $fp does not match GitHub's published fingerprints; aborting" ;;
    esac
  done <<<"$keys"
  printf '%s\n' "$keys"
}

setup_known_hosts() {
  local kh=$SSH_DIR/known_hosts keys line added=0
  if ! uses_github_ssh; then
    info "known_hosts: not needed for $CLONE_URL"
    return 0
  fi
  if is_dry; then
    would "add github.com host keys from $META_URL to $kh"
    return 0
  fi
  keys=$(github_host_keys)
  ensure_ssh_dir
  touch "$kh"
  while IFS= read -r line; do
    if ! grep -qxF "github.com $line" "$kh"; then
      printf 'github.com %s\n' "$line" >>"$kh"
      added=$((added + 1))
    fi
  done <<<"$keys"
  info "known_hosts: $added github.com key(s) added, $(($(wc -l <<<"$keys") - added)) already present"
}
# ---------------------------------------------------------------------------------------------------------
# Access

git_ssh_command() {
  printf 'ssh -i "%s" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15' "$KEY"
}

has_access() {
  GIT_SSH_COMMAND=$(git_ssh_command) git ls-remote "$CLONE_URL" HEAD >/dev/null 2>&1 </dev/null
}

tty_available() {
  [[ ${AGENT_NONINTERACTIVE:-} != 1 ]] && (: </dev/tty) 2>/dev/null
}

# ask <question> <default y|n>: read the answer from /dev/tty (never stdin: stdin may be the piped script).
ask() {
  local answer hint="[y/N]"
  [[ $2 == y ]] && hint="[Y/n]"
  printf '%s %s ' "$1" "$hint" >/dev/tty
  read -r answer </dev/tty || answer=""
  answer=${answer:-$2}
  [[ $answer == [yY]* ]]
}

gh_is_admin() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 </dev/null || return 1
  [[ $(gh api "repos/$OPT_REPO" --jq .permissions.admin 2>/dev/null </dev/null) == true ]]
}

GH_LOGGED_IN_BY_US=0
maybe_gh_login() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 </dev/null && return 1
  tty_available || return 1
  ask "gh is installed but not logged in. Log in as a repo admin to register the key automatically?" n || return 1
  gh auth login </dev/tty >/dev/tty 2>&1 || return 1
  GH_LOGGED_IN_BY_US=1
}

maybe_gh_logout() {
  [[ $GH_LOGGED_IN_BY_US == 1 ]] || return 0
  if tty_available && ! ask "Log gh out again, so the admin token does not stay on this host?" y; then
    GH_LOGGED_IN_BY_US=0
    warn "gh stays logged in on this host"
    return 0
  fi
  GH_LOGGED_IN_BY_US=0
  gh auth logout --hostname github.com </dev/null >/dev/null 2>&1 || warn "gh auth logout failed"
  info "gh: logged out"
}

wait_for_access() { # wait_for_access <seconds> <interval>
  local deadline=$((SECONDS + $1)) nap
  while ! has_access; do
    ((SECONDS < deadline)) || return 1
    nap=$2
    if ((deadline - SECONDS < nap)); then nap=$((deadline - SECONDS)); fi
    if ((nap > 0)); then sleep "$nap"; fi
  done
}

auto_grant() {
  local existing pubfile
  existing=$(gh repo deploy-key list --repo "$OPT_REPO" --json title,key \
    --jq ".[] | select(.title == \"$KEY_TITLE\") | .key" </dev/null)
  if [[ -n $existing ]]; then
    if [[ $(awk '{ print $1 " " $2 }' <<<"$existing") == "$PUBKEY" ]]; then
      info "deploy key '$KEY_TITLE' is already registered"
    else
      die 6 "a deploy key titled '$KEY_TITLE' exists with a different key. Revoke it first, from the private repo:
  scripts/access-revoke.sh $HOST
or with gh:
  gh repo deploy-key list --repo $OPT_REPO    # find the id
  gh repo deploy-key delete <id> --repo $OPT_REPO"
    fi
  else
    make_temp "${TMPDIR:-/tmp}"
    pubfile=$REPLY
    printf '%s %s\n' "$PUBKEY" "$KEY_TITLE" >"$pubfile"
    if [[ $OPT_READ_ONLY == 1 ]]; then
      gh repo deploy-key add "$pubfile" --repo "$OPT_REPO" --title "$KEY_TITLE" </dev/null >/dev/null
    else
      gh repo deploy-key add "$pubfile" --repo "$OPT_REPO" --title "$KEY_TITLE" --allow-write </dev/null >/dev/null
    fi
    info "registered deploy key '$KEY_TITLE' ($([[ $OPT_READ_ONLY == 1 ]] && echo read-only || echo read-write))"
  fi
  wait_for_access 60 5 || die 2 "deploy key registered, but access still fails after 60s; re-run in a minute"
}

manual_grant() {
  local write_flag="" ro_flag=""
  if [[ $OPT_READ_ONLY == 1 ]]; then ro_flag=" --read-only"; else write_flag=" --allow-write"; fi
  cat <<EOF

This host needs access to $OPT_REPO. On the admin machine, run ONE of:

  # in a clone of the private repo
  echo '$PUBKEY $KEY_TITLE' | scripts/access-grant.sh --pubkey - --host $HOST$ro_flag

  # or with gh only
  echo '$PUBKEY $KEY_TITLE' > $KEY_TITLE.pub
  gh repo deploy-key add $KEY_TITLE.pub --repo $OPT_REPO --title $KEY_TITLE$write_flag

Public key fingerprint: $(fingerprint "$PUBKEY")
Waiting up to $OPT_TIMEOUT for access (checking every 10s; Ctrl-C to stop, then re-run later)...
EOF
  wait_for_access "$GRANT_TIMEOUT" 10 || die 2 "timed out after $OPT_TIMEOUT waiting for access; re-run after granting"
  info "access granted"
}

ensure_access() {
  if is_dry; then
    would "check access with git ls-remote $CLONE_URL, and register the key or wait for a grant if needed"
    return 0
  fi
  if has_access; then
    info "access: the key can read $OPT_REPO"
    return 0
  fi
  if gh_is_admin || { maybe_gh_login && gh_is_admin; }; then
    auto_grant
  else
    manual_grant
  fi
}
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
  if [[ $MODE == print-pubkey ]]; then
    if [[ -n $PUBKEY ]]; then
      info "$PUBKEY $KEY_TITLE"
      info "fingerprint: $(fingerprint "$PUBKEY")"
    fi
    exit 0
  fi
  step "GitHub host keys"
  setup_known_hosts
  step "Repo access"
  ensure_access
  step "Clone"
  clone_or_update
  step "Git config"
  apply_config
  run_private_scripts
  maybe_gh_logout
  if is_dry; then
    info "Dry run complete: nothing was changed."
  fi
}

# Sourced (tests): define functions only. Executed or piped: run.
if (return 0 2>/dev/null); then return 0; fi
main "$@"
