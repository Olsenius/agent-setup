# agent-setup

```bash
curl -fsSL https://raw.githubusercontent.com/olsenius/agent-setup/main/install.sh | bash
```

One script, `install.sh`, that turns a fresh VM, VPS, or Cursor-hosted box into a working agent host for the
private repo `olsenius/agent` (a shared Obsidian vault with agent skills). It needs no secrets from this repo:
each host gets its own GitHub deploy key, generated on the host or injected by the platform's secret store.

## Usage

```bash
# Interactive or automatic (gh logged in as repo admin): generate key, register it, clone, link
curl -fsSL https://raw.githubusercontent.com/olsenius/agent-setup/main/install.sh | bash

# With flags (`bash -s --` is required to pass flags through a pipe)
curl -fsSL .../install.sh | bash -s -- --agent chief-of-staff,vigilo --tools grok --host grok-box

# Existing deploy key from a file
curl -fsSL .../install.sh | bash -s -- --key-file /run/secrets/olsenius-agent --agent codex

# Existing deploy key from an injected secret (Cursor, cloud-init, CI)
#   AGENT_DEPLOY_KEY_B64 is set by the platform's secret store, not typed on the command line
curl -fsSL .../install.sh | AGENT=chief-of-staff,vigilo AGENT_HOST=grok-box TOOLS=grok bash

# Inspect only
curl -fsSL .../install.sh | bash -s -- --status
```

## What it does

Every step is idempotent: re-running converges on the same state.

1. **Preflight:** refuses to run as root (unless `AGENT_ALLOW_ROOT=1`), checks `git`, `ssh`, `ssh-keygen`,
   `curl`, `base64`, `hostname`, and prints the install command for your OS if one is missing. Never uses `sudo`.
2. **Host name:** `AGENT_HOST` or `hostname -s`, lowercased. Ephemeral-looking names get a hint to set `AGENT_HOST`.
3. **Deploy key** at `~/.ssh/olsenius-agent_ed25519`, from (first match): `--key-file`, `AGENT_DEPLOY_KEY`,
   `AGENT_DEPLOY_KEY_B64`, an existing key, or a newly generated ed25519 key. Supplied keys must be
   passphrase-less ed25519 keys; a different key already on disk is only replaced with `--replace-key`
   (the old pair is kept as `.bak-<timestamp>`).
4. **`known_hosts`:** github.com keys from `https://api.github.com/meta`; if that fails, `ssh-keyscan` with every
   fingerprint checked against GitHub's published values (hardcoded in the script).
5. **Access check:** `git ls-remote` with the key. If it already works (typical for a supplied key), skip to 7.
6. **Grant:** with `gh` logged in as a repo admin, the key is registered as deploy key `olsenius-agent@<host>`.
   Otherwise the script prints the public key and the admin commands, then polls every 10 s until access works
   (no TTY needed, so it works under `curl | bash`). With a terminal and `gh` installed but logged out, it offers
   `gh auth login` first, and logs out again at the end.
7. **Clone** to `~/agent`, or `git pull --rebase --autostash` an existing clone (never reset, never force-push).
   A directory that is not a clone of the repo is left alone (exit 7).
8. **Repo-local git config:** `core.sshCommand` (this key only), `user.name`/`user.email` for the host,
   `core.hooksPath .githooks`, `agentrepo.role agent`.
9. **Setup contract:** checks `scripts/.setup-contract` in the clone (see below).
10. **Register agents:** `scripts/agent-register.sh <agent>` for each `--agent`.
11. **Link tools:** `scripts/tool-link.sh` (skills and personas into Hermes, OpenClaw, ...).
12. **Summary:** the status table and next steps.

### Never

`sudo`; personal SSH keys or any other key in `~/.ssh`; broad PATs; printing a private key; force-push;
`git reset --hard`; writing outside `REPO_DIR`, `~/.ssh/olsenius-agent_ed25519*`, `~/.ssh/known_hosts`,
`~/.config/olsenius-agent/`, and what `tool-link.sh` manages; modifying in-repo symlinks.

## Onboarding scenarios

1. **Admin present on the host** (`gh` logged in as repo admin): run the one-liner. Fully automatic.
2. **No `gh` on the host:** run the one-liner. It prints the public key and two equivalent commands; run one on the
   admin machine (`scripts/access-grant.sh --pubkey - --host <name>` in the private repo, or
   `gh repo deploy-key add`). The script notices the grant within 10 s and continues by itself.
3. **Pre-minted key injected as a secret** (Cursor boxes, cloud-init): on the admin machine, in the private repo,
   run `scripts/access-grant.sh --mint --host <name>`. It registers the deploy key and prints the private key once,
   base64-encoded. Store that value as `AGENT_DEPLOY_KEY_B64` in the platform's secret store, set
   `AGENT_HOST=<name>`, and run the one-liner non-interactively.

## Options

Every option is a flag and an environment variable; flags win.

| Flag | Env | Default | Meaning |
|---|---|---|---|
| `--repo owner/name` | `AGENT_REPO` | `olsenius/agent` | Private repo to clone |
| `--repo-dir PATH` | `REPO_DIR` | `~/agent` | Clone location |
| `--agent a,b` | `AGENT` | none | Agents to register (comma-separated, kebab-case) |
| `--host NAME` | `AGENT_HOST` | `hostname -s` | Stable host name for key title and namespaces |
| `--tools a,b` | `TOOLS` | auto-detect | Passed to `tool-link.sh` (`claude,codex,hermes,openclaw,grok`) |
| `--key-file PATH` | `AGENT_DEPLOY_KEY_FILE` | none | Existing private deploy key to use |
| — | `AGENT_DEPLOY_KEY` | none | Existing private key, OpenSSH format, multi-line |
| — | `AGENT_DEPLOY_KEY_B64` | none | Same, base64-encoded |
| `--replace-key` | `AGENT_REPLACE_KEY=1` | off | Let a supplied key replace a different key on disk |
| `--read-only` | `AGENT_READ_ONLY=1` | off | Register a read-only deploy key (automatic path) |
| `--timeout DUR` | `AGENT_GRANT_TIMEOUT` | `15m` | How long to wait for a manual grant (`90s`, `15m`, `1h`) |
| — | `AGENT_NONINTERACTIVE=1` | off | Never prompt, even with a terminal |
| — | `AGENT_ALLOW_ROOT=1` | off | Allow running as root (containers) |
| `--no-register` | | off | Skip `agent-register.sh` |
| `--no-link` | | off | Skip `tool-link.sh` |
| `--status` | | | Print state and exit: 0 if everything is OK, 1 otherwise |
| `--dry-run` | | | Print every action without changing anything (and without network calls) |
| `--print-pubkey` | | | Ensure a key exists, print its public key and fingerprint, exit |
| `--version` | | | Print version |
| `--help` | | | Usage with examples |

There are deliberately no flags that take a private key: arguments are visible in `ps` and shell history.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (or nothing to do) |
| 1 | Missing dependency, invalid option, or a private-repo script failed |
| 2 | Timed out waiting for a manual grant |
| 3 | Refused to run as root |
| 4 | Supplied key invalid, wrong type, conflicting sources, or conflicts with the existing key |
| 5 | GitHub host key verification failed |
| 6 | Deploy key title exists with a different key |
| 7 | `REPO_DIR` exists but is not a clone of the repo |

## Contract with the private repo

`install.sh` relies only on this interface of `olsenius/agent`, versioned in `scripts/.setup-contract` (currently `1`):

- `scripts/agent-register.sh <agent>`: idempotent, honors `AGENT_HOST`.
- `scripts/tool-link.sh [--status] [--dry-run]`: honors `TOOLS`, idempotent.
- `scripts/agent-sync.sh pull`: honors `AGENT` and `AGENT_HOST`.

If the contract file is missing or has another version, the installer warns, skips registration and linking, and
exits 0. A missing script is skipped with a warning.

## Security notes

- **Pipe-to-bash** runs whatever the URL serves. To inspect first:
  `curl -fsSL https://raw.githubusercontent.com/olsenius/agent-setup/main/install.sh -o install.sh && less install.sh && bash install.sh`
- **Shell history:** `AGENT_DEPLOY_KEY_B64=... bash` typed interactively lands in your history. Use the platform's
  secret store or `--key-file` instead.
- The private key is never printed or logged; only the public key and its SHA256 fingerprint are shown.
  The script refuses to trace itself (`set -x` is switched off before any key handling).
- **Rotation:** revoke the key title `olsenius-agent@<host>` (`scripts/access-revoke.sh <host>` in the private repo),
  delete `~/.ssh/olsenius-agent_ed25519*` on the host (or supply a new key with `--replace-key`), and re-run.
- Deploy keys that `gh` registers are tied to the admin's `gh` token: if that token is revoked, the keys go too.

See [SECURITY.md](SECURITY.md) for exactly what the script reads and writes.

## Development

```bash
mise install                      # shellcheck, shfmt (pinned in mise.toml)
shellcheck install.sh test/*.sh test/fixtures/*.sh
shfmt -d -i 2 -ci .
test/run.sh                       # all tests
SKIP_NETWORK=1 test/run.sh        # skip tests that need api.github.com / github.com
BASH_BIN=/bin/bash test/run.sh    # run install.sh with macOS bash 3.2
```

Tests run install.sh with a throwaway `$HOME` against a local fake vault
(`test/fixtures/make-fake-vault.sh`). The test-only variable `AGENT_SETUP_REPO_URL` points the clone at that
`file://` URL; it does not bypass key validation and is not meant for real use.
CI runs lint, the tests on Ubuntu, macOS (`/bin/bash` 3.2), and Alpine, and checks GitHub's live host keys
against the hardcoded fingerprints.

## Decisions

Choices not covered by the build spec, recorded so they can be revisited.

- **Host names are lowercased**, matching the private repo's tooling, so key titles and namespaces agree.
- **`AGENT_HOST` is saved** to `~/.config/olsenius-agent/env` when given, and the private repo's scripts read it,
  so later syncs on an ephemeral host keep the same identity without exporting the variable.
- **Top-level code is definitions only**; all work happens in `main()`. When sourced, the script only defines
  functions (the tests use this to run the `known_hosts` step on its own).
- **`known_hosts`:** keys from `api.github.com/meta` (fetched over TLS) are trusted as published and not compared
  with the hardcoded fingerprints, so a GitHub rotation does not break installs; the `known-hosts` CI job catches
  rotations so the fallback's fingerprints can be updated. The step is skipped for non-GitHub (test) URLs.
- **An empty `REPO_DIR`** is treated like a missing one and cloned into.
- **A failed `git pull`** aborts the rebase, warns, and continues with the clone as it was.
- **A failed private-repo script** is reported, the run continues, and the script exits 1 at the end.
- **`--status`:** `WARN` lines (e.g. no agents registered) do not fail it; `MISSING` lines do.
  `tool-link.sh --status` is only called when the setup contract is supported.
- **`--dry-run`** makes no network calls and no changes; it prints what it would do.
- **`AGENT_NONINTERACTIVE=1`** disables all prompts even when a terminal exists (tests, cloud-init).
- **`AGENT_DEPLOY_KEY`** with literal `\n` sequences instead of newlines (some secret stores flatten them) is
  converted back to a multi-line key.
- **After an automatic grant**, the script waits up to 60 s for the new deploy key to take effect.
- **`gh` logout** also happens from the exit trap if the script logged `gh` in and then failed.
