# Script Reference

## `scripts/convert_clawdbot_to_split.sh`
Purpose: migrate existing `~/.clawdbot/clawdbot.json` to TwinMind wrapper backend.

### Modes
- `plan`: no target mutation, writes patch report.
- `apply`: creates backups, patches config, writes manifest.
- `rollback`: restores target from manifest backup.

### Important flags
- `--patch-env`: append non-secret defaults from template.
- `--force-split-default`: set backend runtime mode to tool bridge by default.

## `scripts/bootstrap_clawdbot_replica.sh`
Purpose: generate a reproducible local replica structure with vendored wrapper scripts and placeholder config.

### Modes
- `plan`: emits planned actions report.
- `apply`: writes files under `--target-root`.

## `scripts/create_private_github_repo.sh`
Purpose: create private GitHub repo safely.

### Behavior
- preferred path: `gh repo create` if available/authenticated.
- fallback path: GitHub REST API with env token.

## `scripts/safe_push.sh`
Purpose: push while enforcing secret scan gate.

### Safety
- scans tracked files for common secret patterns.
- blocks push by default when findings are present.

## `scripts/init_private_repo_and_push.sh`
Purpose: one-shot orchestrator for repo creation + local git init/commit + safe push.

### Default
- dry-run enabled by default.
