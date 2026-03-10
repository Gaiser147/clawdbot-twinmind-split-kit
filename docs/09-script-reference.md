# Script Reference

## `scripts/convert_clawdbot_to_split.sh`
Purpose: migrate an existing Clawdbot/OpenClaw config to the TwinMind wrapper backend.

### Modes
- `plan`: no target mutation, writes patch report.
- `apply`: creates backups, patches config, writes manifest.
- `rollback`: restores target from manifest backup.

### Important flags
- `--config`: optional; if omitted, the script auto-detects common `clawdbot`/`openclaw` config paths.
- `--patch-env`: append non-secret defaults from template.
- `--force-split-default`: set backend args to `--mode tool_bridge` by default.

### Current default patch behavior
- sets `--routing-mode strict_split`
- sets `--executor-provider codex_cli`
- sets `--executor-model gpt-5.3-codex`
- keeps backend mode default at `conversation` unless `--force-split-default` is used

## `scripts/bootstrap_clawdbot_replica.sh`
Purpose: generate a reproducible local replica structure with vendored wrapper scripts and placeholder config.

### Modes
- `plan`: emits planned actions report.
- `apply`: writes files under `--target-root`.

### Current default profile
- replica config/env defaults target Codex executor profile (`codex_cli` + `gpt-5.3-codex`).

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

## Limitations and operator responsibilities
- Scripts do not auto-install runtime dependencies.
- Scripts currently do not parameterize provider/model during patching.
- Alternative model profiles are configured manually after migration.

See:
- [04-config-reference.md](./04-config-reference.md)
- [05-migration-guide.md](./05-migration-guide.md)
- [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md)
