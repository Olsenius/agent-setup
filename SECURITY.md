# Security

`install.sh` is meant to be piped to bash on fresh hosts, so what it touches is deliberately small and fixed.
This repository contains no keys, tokens, host names, or other secrets.

## What the script reads

- The environment variables and flags listed in the README.
- A private deploy key supplied by `--key-file` / `AGENT_DEPLOY_KEY_FILE`, `AGENT_DEPLOY_KEY`, or
  `AGENT_DEPLOY_KEY_B64` (unset from the environment right after use).
- `~/.ssh/olsenius-agent_ed25519` and `~/.ssh/olsenius-agent_ed25519.pub`.
- `~/.ssh/known_hosts` (to avoid duplicate entries).
- `https://api.github.com/meta` (GitHub's published SSH host keys), or `ssh-keyscan github.com` as a fallback
  verified against hardcoded fingerprints.
- The private repo clone (`~/agent` by default), including `scripts/.setup-contract`.
- `gh` state, only through `gh auth status`, `gh api repos/<repo>`, and `gh repo deploy-key list`.

## What the script writes

- `~/.ssh/` (created with mode 700 if missing).
- `~/.ssh/olsenius-agent_ed25519` (600) and `.pub` (644); on `--replace-key`, the previous pair is renamed to
  `*.bak-<UTC timestamp>`. Temp files for key validation are created in `~/.ssh` with mode 600 and removed on exit.
- `~/.ssh/known_hosts`: `github.com` lines are appended if missing.
- `~/.config/olsenius-agent/env`: `AGENT_HOST=<name>`, only when the host name was given explicitly.
- The clone directory (`REPO_DIR`): `git clone` or `git pull --rebase --autostash`, and repo-local git config
  (`core.sshCommand`, `user.name`, `user.email`, `core.hooksPath`, `agentrepo.role`).
- Whatever the private repo's `scripts/agent-register.sh` and `scripts/tool-link.sh` do (vault commits for new
  agent workspaces; links from agent tools such as `~/.hermes/skills/vault/` into the clone).
- GitHub: one deploy key titled `olsenius-agent@<host>`, only on the automatic path with an admin `gh` login.

## What the script never does

- Use `sudo`, or run as root without `AGENT_ALLOW_ROOT=1`.
- Read, use, or modify any other file in `~/.ssh` besides `known_hosts`.
- Print or log a private key (only public keys and SHA256 fingerprints), or run with `set -x`.
- Accept a private key as a command-line argument.
- Use broad personal access tokens, force-push, or `git reset --hard`.
- Touch a directory that is not a clone of the configured repo.
- Change the private repo's in-repo symlinks, hooks, or protected files.
- Leave a `gh` login behind that it created itself (it logs out at the end, or on failure).

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository: **Security → Report a vulnerability**
(https://github.com/olsenius/agent-setup/security/advisories/new). Please do not open a public issue for
security problems.
