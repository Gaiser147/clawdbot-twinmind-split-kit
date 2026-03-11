# Script Reference

This page is the deep reference for script behavior. Use [05-migration-guide.md](./05-migration-guide.md) for live migration steps and [06-operations-runbook.md](./06-operations-runbook.md) for replica/ops flow.

## `scripts/convert_clawdbot_to_split.sh`

Purpose: patch an existing Clawdbot/OpenClaw/Moltbook/Moltbot-style config to use the TwinMind wrapper backend.

### Modes

- `plan`: no mutation, writes a patch report
- `apply`: writes backup, patched config, and manifest
- `rollback`: restores a prior backup from the manifest

### Important flags

- `--config`: optional; auto-detects common Clawdbot/OpenClaw/Moltbook/Moltbot config paths when omitted
- `--env`: optional; defaults to the neighboring `.env`
- `--patch-env`: append non-secret defaults from the template
- `--force-split-default`: patch backend `--mode` to `tool_bridge` instead of `conversation`
- `--migration-id`: optional in `plan` and `apply`, required for `rollback`

### Default patch behavior

The script:

- validates `agents` and `agents.defaults` before patching
- copies runtime files into the target app tree and points backend args at that copied script
- merges managed TwinMind backend fields into `agents.defaults.cliBackends.twinmind-cli` without dropping unrelated keys

The managed backend args include:

- `--mode conversation`
- `--routing-mode strict_split`
- `--executor-provider codex_cli`
- `--executor-model gpt-5.3-codex`

### Outputs

- `reports/convert-<migration-id>.json`
- `backups/clawdbot.json.<migration-id>.bak`
- `manifests/migration-<migration-id>.json`

### Support boundary

- primary target: Clawdbot-style config shape with `agents.defaults`
- path compatibility: Clawdbot, OpenClaw, Moltbook, and Moltbot config locations using the same JSON layout

## `scripts/bootstrap_clawdbot_replica.sh`

Purpose: build a reproducible local replica tree with vendored wrapper files and placeholder config.

### Modes

- `plan`: emit planned actions only
- `apply`: write files under `--target-root`

### Default behavior

- target root defaults to `/root/.clawdbot-replica`
- generated backend args pin `codex_cli` + `gpt-5.3-codex`
- reports include the copied runtime location under `clawd/skills/twinmind-orchestrator/scripts`
- writes `.env.example`, not live secrets

## `scripts/ai_easy_setup.sh`

Purpose: provide one machine-friendly entrypoint for terminal AI tools and human operators who want preflight, plan, replica, apply, and smoke-test in one place.

### Modes

- `preflight`: checks local commands, Python dependency, config shape, and TwinMind secrets
- `plan`: runs the live migration plan and returns a JSON summary
- `replica`: creates a safe local replica under a chosen target root and returns a JSON summary
- `apply`: runs live migration and then the smoke test unless `--no-smoke` is set
- `smoke-test`: delegates directly to `scripts/smoke_test_migration.sh`

### Useful flags

- `--config <path>`
- `--env <path>`
- `--target-root <path>`
- `--report-dir <path>`
- `--print-json`
- `--yes`
- `--no-require-secrets`
- `--no-smoke`

### Behavior notes

- keeps its own reports outside the repo worktree by default under `/tmp/twinmind-split-kit-<timestamp>/`
- does not invent a second migration path; it delegates to the existing converter and replica scripts
- stops early on missing secrets or incompatible config shape for live migration

## `scripts/smoke_test_migration.sh`

Purpose: execute the patched backend from config and verify expected wrapper log signals.

### Success criteria

- detects the patched backend from config
- derives `--runtime-root` from backend args when present
- executes a tool-intent query against the migrated backend
- confirms these log signals in the latest wrapper log:
  - split routing (`tool_bridge_override` or `split_executor_bridge`)
  - `executor_request`
  - `executor_response`
  - `final` or `final_after_skill_run`

### Useful flags

- `--config <path>`
- `--report-json <path>`
- `--query <text>`
- `--log-timeout-sec <sec>`
- `--print-json`

### Current limit

- the smoke query verifies split/executor reachability, not application-specific skills such as Sharezone or Schulcloud

## `scripts/create_private_github_repo.sh`

Purpose: create a private GitHub repo for this kit.

### Behavior

- prefers `gh repo create`
- falls back to GitHub REST API when token auth is available

## `scripts/safe_push.sh`

Purpose: block pushes when tracked files appear to contain secrets.

### Behavior

- scans tracked files for common secret patterns
- blocks push on findings unless you clean them up first

## `scripts/init_private_repo_and_push.sh`

Purpose: one-shot helper for repo creation, local git init/commit, and guarded push.

### Default

- dry-run is enabled by default

## Operator responsibilities and current limits

- scripts do not install runtime dependencies
- scripts do not switch provider/model dynamically during patching
- migrated configs pin provider/model via backend args, so env-only switching is insufficient
- replica flow is for inspection and testing, not proof of live migration
- channel-specific runtime behavior is documented only for WhatsApp; non-WhatsApp transport handling is out of scope here

## See also

- [05-migration-guide.md](./05-migration-guide.md)
- [06-operations-runbook.md](./06-operations-runbook.md)
- [08-rollback.md](./08-rollback.md)
- [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md)
