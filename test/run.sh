#!/usr/bin/env bash
# Tests for install.sh. Plain bash, no framework. Every test runs install.sh with its own throwaway $HOME.
#
#   test/run.sh [filter]      run tests whose name contains <filter>
#   SKIP_NETWORK=1            skip tests that need api.github.com / github.com
#   BASH_BIN=/bin/bash        bash used to run install.sh (CI uses macOS /bin/bash 3.2)
# shellcheck disable=SC2030,SC2031 # tests change HOME and globals inside subshells on purpose
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL=$ROOT/install.sh
BASH_BIN=${BASH_BIN:-bash}
FILTER=${1:-}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

passed=0 failed=0 skipped=0

ok() {
  passed=$((passed + 1))
  printf '    ok    %s\n' "$*"
}
not_ok() {
  failed=$((failed + 1))
  printf '    FAIL  %s\n' "$*"
  if [[ -n ${OUT:-} && -f $OUT ]]; then sed 's/^/          | /' "$OUT" | tail -n 15; fi
}
check() { # check <description> <command...>
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else not_ok "$desc"; fi
}
output_has() { grep -qF -- "$1" "$OUT"; }
output_lacks() { ! grep -qF -- "$1" "$OUT"; }

new_home() {
  H=$(mktemp -d "$WORK/home.XXXXXX")
  mkdir -p "$H/.gh"
}

# run_install [VAR=value...] [-- args...]: run install.sh isolated from the caller's environment.
# Sets RC and OUT (combined stdout and stderr).
run_install() {
  local envs=()
  while (($#)) && [[ $1 != -- ]]; do
    envs+=("$1")
    shift
  done
  if (($#)); then shift; fi
  OUT=$(mktemp "$WORK/out.XXXXXX")
  local root_ok=""
  if [[ $(id -u) -eq 0 ]]; then root_ok="AGENT_ALLOW_ROOT=1"; fi
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u AGENT -u AGENT_HOST -u TOOLS -u AGENT_REPO \
    -u REPO_DIR -u AGENT_DEPLOY_KEY -u AGENT_DEPLOY_KEY_B64 -u AGENT_DEPLOY_KEY_FILE -u SSH_AUTH_SOCK \
    -u AGENT_SETUP_REPO_URL \
    HOME="$H" GH_CONFIG_DIR="$H/.gh" AGENT_NONINTERACTIVE=1 NO_COLOR=1 AGENT_REPO=example/fake-vault \
    AGENT_HOST=test-host STUB_LOG="$WORK/stub.log" $root_ok ${envs[@]+"${envs[@]}"} \
    "$BASH_BIN" "$INSTALL" "$@" </dev/null >"$OUT" 2>&1
  RC=$?
}

perm() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
snapshot() { (cd "$1" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort); }
fp_of() { ssh-keygen -lf "$1" | awk '{ print $2 }'; }
throwaway_key() { # throwaway_key <path> [type] [passphrase]
  ssh-keygen -q -t "${2:-ed25519}" -N "${3:-}" -C throwaway -f "$1" </dev/null
}

run_test() { # run_test <name> <function>
  if [[ -n $FILTER && $1 != *"$FILTER"* ]]; then return 0; fi
  printf '  %s\n' "$1"
  OUT=""
  "$2"
}
skip_network() {
  if [[ ${SKIP_NETWORK:-} == 1 ]]; then
    skipped=$((skipped + 1))
    printf '    skip  needs network (SKIP_NETWORK=1)\n'
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------------------------------------

t_help_version() {
  new_home
  run_install -- --help
  check "--help exits 0" [ "$RC" -eq 0 ]
  check "--help shows usage" output_has "Usage:"
  run_install -- --version
  check "--version exits 0" [ "$RC" -eq 0 ]
  check "--version prints version" output_has "agent-setup "
  run_install -- --no-such-flag
  check "unknown option exits 1" [ "$RC" -eq 1 ]
}

t_dry_run() {
  new_home
  local before after
  before=$(snapshot "$H")
  run_install -- --dry-run --agent alpha --tools hermes
  after=$(snapshot "$H")
  check "--dry-run exits 0" [ "$RC" -eq 0 ]
  check "--dry-run leaves \$HOME untouched" [ "$before" == "$after" ]
  check "--dry-run reports what it would do" output_has "[dry-run] would"
}

t_generated_key() {
  new_home
  run_install -- --print-pubkey
  check "exit 0" [ "$RC" -eq 0 ]
  check ".ssh dir is 700" [ "$(perm "$H/.ssh")" == 700 ]
  check "private key is 600" [ "$(perm "$H/.ssh/olsenius-agent_ed25519")" == 600 ]
  check "public key is 644" [ "$(perm "$H/.ssh/olsenius-agent_ed25519.pub")" == 644 ]
  check "public key is ed25519 titled olsenius-agent@test-host" \
    grep -q '^ssh-ed25519 .* olsenius-agent@test-host$' "$H/.ssh/olsenius-agent_ed25519.pub"
  check "prints the public key" output_has "ssh-ed25519 "
  local first
  first=$(cat "$H/.ssh/olsenius-agent_ed25519.pub")
  run_install -- --print-pubkey
  check "re-run keeps the same key" [ "$first" == "$(cat "$H/.ssh/olsenius-agent_ed25519.pub")" ]
}

# assert_installed <source key file>: key installed with the same fingerprint, private body never printed.
assert_installed() {
  local src=$1 secret
  check "exit 0" [ "$RC" -eq 0 ]
  check "installed with the same fingerprint" \
    [ "$(fp_of "$H/.ssh/olsenius-agent_ed25519")" == "$(fp_of "$src")" ]
  check "private key is 600" [ "$(perm "$H/.ssh/olsenius-agent_ed25519")" == 600 ]
  check "public key is 644" [ "$(perm "$H/.ssh/olsenius-agent_ed25519.pub")" == 644 ]
  secret=$(sed -n '3p' "$src")
  check "private key body never appears in the output" output_lacks "$secret"
  check "no leftover temp files in ~/.ssh" [ -z "$(find "$H/.ssh" -name '.agent-setup.*')" ]
}

t_key_b64() {
  new_home
  throwaway_key "$WORK/b64key"
  run_install "AGENT_DEPLOY_KEY_B64=$(base64 <"$WORK/b64key" | tr -d '\n')" -- --print-pubkey
  assert_installed "$WORK/b64key"
}

t_key_env_and_file() {
  new_home
  throwaway_key "$WORK/envkey"
  run_install "AGENT_DEPLOY_KEY=$(cat "$WORK/envkey")" -- --print-pubkey
  assert_installed "$WORK/envkey"

  new_home
  run_install "AGENT_DEPLOY_KEY=$(sed 's/$/\r/' "$WORK/envkey")" -- --print-pubkey
  check "AGENT_DEPLOY_KEY with CRLF" [ "$RC" -eq 0 ]
  assert_installed "$WORK/envkey"

  new_home
  throwaway_key "$WORK/filekey"
  sed 's/$/\r/' "$WORK/filekey" >"$WORK/filekey.crlf"
  run_install -- --key-file "$WORK/filekey.crlf" --print-pubkey
  check "--key-file with CRLF" [ "$RC" -eq 0 ]
  assert_installed "$WORK/filekey"
}

t_key_rejected() {
  new_home
  throwaway_key "$WORK/k1"
  run_install "AGENT_DEPLOY_KEY=$(cat "$WORK/k1")" "AGENT_DEPLOY_KEY_B64=$(base64 <"$WORK/k1" | tr -d '\n')" \
    -- --print-pubkey
  check "two key sources: exit 4" [ "$RC" -eq 4 ]
  check "two key sources: names them" output_has "AGENT_DEPLOY_KEY_B64"

  new_home
  throwaway_key "$WORK/rsa" rsa
  run_install -- --key-file "$WORK/rsa" --print-pubkey
  check "RSA key: exit 4" [ "$RC" -eq 4 ]
  check "RSA key: not installed" [ ! -e "$H/.ssh/olsenius-agent_ed25519" ]
  check "RSA key: body never printed" output_lacks "$(sed -n '3p' "$WORK/rsa")"

  new_home
  throwaway_key "$WORK/pass" ed25519 "correct horse"
  run_install -- --key-file "$WORK/pass" --print-pubkey
  check "passphrase-protected key: exit 4" [ "$RC" -eq 4 ]
  check "passphrase-protected key: explains why" output_has "passphrase"
}

t_key_replace() {
  new_home
  throwaway_key "$WORK/old"
  throwaway_key "$WORK/new"
  run_install -- --key-file "$WORK/old" --print-pubkey
  run_install -- --key-file "$WORK/new" --print-pubkey
  check "different key without --replace-key: exit 4" [ "$RC" -eq 4 ]
  check "different key without --replace-key: existing key kept" \
    [ "$(fp_of "$H/.ssh/olsenius-agent_ed25519")" == "$(fp_of "$WORK/old")" ]
  check "different key: prints both fingerprints" output_has "$(fp_of "$WORK/old")"
  run_install -- --key-file "$WORK/new" --replace-key --print-pubkey
  check "--replace-key: exit 0" [ "$RC" -eq 0 ]
  check "--replace-key: new key installed" [ "$(fp_of "$H/.ssh/olsenius-agent_ed25519")" == "$(fp_of "$WORK/new")" ]
  local backup
  backup=$(find "$H/.ssh" -name 'olsenius-agent_ed25519.bak-*' | head -n 1)
  check "--replace-key: old key backed up" [ -n "$backup" ]
  if [[ -n $backup ]]; then check "--replace-key: backup is the old key" [ "$(fp_of "$backup")" == "$(fp_of "$WORK/old")" ]; fi
  run_install -- --key-file "$WORK/new" --print-pubkey
  check "same key again: exit 0" [ "$RC" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------------------

FIXTURE=$ROOT/test/fixtures/make-fake-vault.sh

# fake_vault [--no-contract]: fresh bare repo; path in $VAULT, clone URL in $VAULT_URL, empty stub log.
fake_vault() {
  local d
  d=$(mktemp -d "$WORK/vault.XXXXXX")
  VAULT=$("$FIXTURE" "$d" "$@")
  VAULT_URL="file://$VAULT"
  : >"$WORK/stub.log"
}
stub_log_has() { grep -qF -- "$1" "$WORK/stub.log"; }
stub_calls() { grep -c "^$1 " "$WORK/stub.log" || true; }
cfg() { git -C "$H/agent" config --local --get "$1"; }
cksum_of() { cksum <"$1" | awk '{ print $1 }'; }

t_full_flow() {
  new_home
  fake_vault
  run_install "AGENT_SETUP_REPO_URL=$VAULT_URL" "TOOLS=hermes,grok" -- --agent alpha,beta
  check "exit 0" [ "$RC" -eq 0 ]
  check "cloned to ~/agent" [ -f "$H/agent/README.md" ]
  check "core.sshCommand" [ "$(cfg core.sshCommand)" == "ssh -i ~/.ssh/olsenius-agent_ed25519 -o IdentitiesOnly=yes" ]
  check "user.name" [ "$(cfg user.name)" == test-host ]
  check "user.email" [ "$(cfg user.email)" == test-host@olsenius-agent.local ]
  check "core.hooksPath" [ "$(cfg core.hooksPath)" == .githooks ]
  check "agentrepo.role" [ "$(cfg agentrepo.role)" == agent ]
  check "agent-register.sh alpha with AGENT_HOST" stub_log_has "agent-register args=alpha AGENT_HOST=test-host AGENT="
  check "agent-register.sh beta with AGENT_HOST" stub_log_has "agent-register args=beta AGENT_HOST=test-host AGENT="
  check "agent-sync.sh pull with AGENT and AGENT_HOST" stub_log_has "agent-sync args=pull AGENT=alpha AGENT_HOST=test-host"
  check "tool-link.sh with TOOLS and AGENT_HOST" stub_log_has "tool-link args= TOOLS=hermes,grok AGENT_HOST=test-host AGENT="
  check "AGENT_HOST saved for later syncs" grep -qx "AGENT_HOST=test-host" "$H/.config/olsenius-agent/env"
  check "no known_hosts needed for file:// URL" output_has "known_hosts: not needed"
}

t_idempotent() {
  new_home
  fake_vault
  run_install "AGENT_SETUP_REPO_URL=$VAULT_URL" -- --agent alpha --tools hermes
  local head config commits calls
  head=$(git -C "$H/agent" rev-parse HEAD)
  commits=$(git -C "$H/agent" rev-list --count HEAD)
  config=$(cksum_of "$H/agent/.git/config")
  calls=$(stub_calls agent-register)
  run_install "AGENT_SETUP_REPO_URL=$VAULT_URL" -- --agent alpha --tools hermes
  check "re-run exit 0" [ "$RC" -eq 0 ]
  check "no new commits" [ "$(git -C "$H/agent" rev-list --count HEAD)" -eq "$commits" ]
  check "HEAD unchanged" [ "$(git -C "$H/agent" rev-parse HEAD)" == "$head" ]
  check "git config unchanged" [ "$(cksum_of "$H/agent/.git/config")" == "$config" ]
  check "reports 0 config changes" output_has "git config: 0 value(s) changed"
  check "stubs called again" [ "$(stub_calls agent-register)" -gt "$calls" ]
  check "the key was reused" output_has "existing key"
}

t_unrelated_repo_dir() {
  new_home
  fake_vault
  mkdir -p "$H/other"
  git -C "$H/other" init -q
  git -C "$H/other" remote add origin https://github.com/someone/else.git
  local before
  before=$(snapshot "$H/other")
  run_install "AGENT_SETUP_REPO_URL=$VAULT_URL" -- --repo-dir "$H/other"
  check "exit 7" [ "$RC" -eq 7 ]
  check "unrelated repo untouched" [ "$(snapshot "$H/other")" == "$before" ]

  mkdir -p "$H/notgit"
  echo keep >"$H/notgit/file"
  run_install "AGENT_SETUP_REPO_URL=$VAULT_URL" -- --repo-dir "$H/notgit"
  check "non-empty non-git dir: exit 7" [ "$RC" -eq 7 ]
}

t_missing_contract() {
  new_home
  fake_vault --no-contract
  run_install "AGENT_SETUP_REPO_URL=$VAULT_URL" -- --agent alpha --tools hermes
  check "exit 0" [ "$RC" -eq 0 ]
  check "warns about the contract" output_has "setup-contract is missing"
  check "agent-register.sh not called" [ "$(stub_calls agent-register)" -eq 0 ]
  check "tool-link.sh not called" [ "$(stub_calls tool-link)" -eq 0 ]
}

t_manual_grant_timeout() {
  new_home
  local start=$SECONDS
  run_install "AGENT_SETUP_REPO_URL=file://$WORK/no-such-repo.git" -- --timeout 2s --no-register --no-link
  check "no access and no gh admin: exit 2" [ "$RC" -eq 2 ]
  check "prints the grant command with the public key" output_has "scripts/access-grant.sh --pubkey - --host test-host"
  check "prints the gh equivalent" output_has "gh repo deploy-key add"
  check "says to re-run" output_has "re-run after granting"
  check "respects --timeout" [ $((SECONDS - start)) -lt 20 ]
}

# known_hosts_in <home> [META_URL]: run only the known_hosts step of install.sh (sourced) in a subshell.
known_hosts_in() {
  (
    # shellcheck source=install.sh
    source "$INSTALL"
    set -euo pipefail
    HOME=$1 DRY_RUN=0 SSH_DIR=$1/.ssh CLONE_URL=git@github.com:example/fake-vault.git
    if [[ -n ${2:-} ]]; then META_URL=$2; fi
    setup_known_hosts
  ) >"$OUT" 2>&1
}

github_fps_match() { # every fingerprint in known_hosts is one of the hardcoded GitHub fingerprints
  local expected fp n=0
  expected=$(bash -c "source '$INSTALL'; echo \"\$GITHUB_FINGERPRINTS\"")
  for fp in $(ssh-keygen -lf "$H/.ssh/known_hosts" | awk '{ print $2 }'); do
    case " $expected " in *" $fp "*) n=$((n + 1)) ;; *) return 1 ;; esac
  done
  [[ $n -eq 3 ]]
}

t_known_hosts() {
  skip_network && return 0
  new_home
  OUT=$(mktemp "$WORK/out.XXXXXX")
  known_hosts_in "$H"
  check "from api.github.com/meta: exit 0" [ $? -eq 0 ]
  check "3 github.com keys matching GitHub's published fingerprints" github_fps_match
  known_hosts_in "$H"
  check "re-run adds nothing" [ "$(wc -l <"$H/.ssh/known_hosts" | tr -d ' ')" -eq 3 ]

  new_home
  known_hosts_in "$H" "https://invalid.invalid/meta"
  check "ssh-keyscan fallback: exit 0" [ $? -eq 0 ]
  check "ssh-keyscan fallback: warns" output_has "falling back to ssh-keyscan"
  check "ssh-keyscan fallback: fingerprints verified" github_fps_match
}

t_known_hosts_mismatch() {
  skip_network && return 0
  new_home
  OUT=$(mktemp "$WORK/out.XXXXXX")
  (
    # shellcheck source=install.sh
    source "$INSTALL"
    set -euo pipefail
    HOME=$H DRY_RUN=0 SSH_DIR=$H/.ssh CLONE_URL=git@github.com:example/fake-vault.git
    META_URL="https://invalid.invalid/meta" GITHUB_FINGERPRINTS="SHA256:not-githubs-key"
    setup_known_hosts
  ) >"$OUT" 2>&1
  check "fingerprint mismatch: exit 5" [ $? -eq 5 ]
  check "fingerprint mismatch: nothing written" [ ! -s "$H/.ssh/known_hosts" ]
}

# ---------------------------------------------------------------------------------------------------------

# shellcheck disable=SC2016 # expands in the child bash
echo "install.sh tests (bash: $("$BASH_BIN" -c 'echo $BASH_VERSION'))"
run_test "1 help and version" t_help_version
run_test "2 dry-run" t_dry_run
run_test "3 generated key" t_generated_key
run_test "4 key from AGENT_DEPLOY_KEY_B64" t_key_b64
run_test "5 key from AGENT_DEPLOY_KEY and --key-file" t_key_env_and_file
run_test "6 rejected keys" t_key_rejected
run_test "7 replace key" t_key_replace
run_test "8 full flow against a fake vault" t_full_flow
run_test "9 re-run is idempotent" t_idempotent
run_test "10 REPO_DIR is an unrelated repo" t_unrelated_repo_dir
run_test "11 missing setup contract" t_missing_contract
run_test "manual grant timeout" t_manual_grant_timeout
run_test "known_hosts from api.github.com/meta and fallback" t_known_hosts
run_test "known_hosts fingerprint mismatch" t_known_hosts_mismatch

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[[ $failed -eq 0 ]]
