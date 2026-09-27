#!/usr/bin/env bash
# Create a local bare repo that stands in for the private vault repo in tests.
# Usage: test/fixtures/make-fake-vault.sh <dir> [--no-contract]   -> prints the bare repo path
# The stub scripts append their arguments and environment to $STUB_LOG, like the real ones they would be
# idempotent: agent-register.sh creates the workspace folder (untracked) and runs agent-sync.sh pull.
set -euo pipefail

dir=${1:?usage: make-fake-vault.sh <dir> [--no-contract]}
contract=yes
[[ ${2:-} == --no-contract ]] && contract=no
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

work=$dir/vault-src
mkdir -p "$work/scripts"
cd "$work"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }

cat >scripts/agent-register.sh <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "agent-register args=$* AGENT_HOST=${AGENT_HOST:-} AGENT=${AGENT:-}" >>"$STUB_LOG"
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/90 Agents/91 Workspaces/$1@${AGENT_HOST:-unknown}"
AGENT=$1 "$root/scripts/agent-sync.sh" pull
STUB

cat >scripts/tool-link.sh <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "tool-link args=$* TOOLS=${TOOLS:-} AGENT_HOST=${AGENT_HOST:-} AGENT=${AGENT:-}" >>"$STUB_LOG"
if [[ ${1:-} == --status ]]; then echo "OK      stub      all tools linked"; fi
STUB

cat >scripts/agent-sync.sh <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "agent-sync args=$* AGENT=${AGENT:-} AGENT_HOST=${AGENT_HOST:-}" >>"$STUB_LOG"
STUB

chmod +x scripts/*.sh
if [[ $contract == yes ]]; then echo 1 >scripts/.setup-contract; fi
echo "# fake vault" >README.md
git add -A
git commit -q -m "fake vault"
git clone -q --bare "$work" "$dir/vault.git"
rm -rf "$work"
echo "$dir/vault.git"
