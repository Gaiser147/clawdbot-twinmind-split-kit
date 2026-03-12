# Live Migration Guide

This page is only for patching a real local config. If you want a safe dry-run environment first, use [06-operations-runbook.md](./06-operations-runbook.md).

If the target install is already TwinMind-managed, do not re-run migration. Use `inspect`, `update-plan`, `update-apply`, and `update-rollback` instead.

## Objective

Patch an existing Clawdbot/OpenClaw/Moltbook/Moltbot-style config so it calls a copied `twinmind_orchestrator.py` runtime inside the target app tree and writes rollback artifacts.

## Scripts

- `scripts/convert_clawdbot_to_split.sh`
- `scripts/ai_easy_setup.sh` for the guided `preflight -> plan -> apply -> smoke-test` wrapper
- `scripts/smoke_test_migration.sh` for reusable verification

## AI-assisted setup wrapper

If you want a terminal AI tool to drive the migration, use the repo-owned prompt in [../prompts/terminal-ai-easy-setup.md](../prompts/terminal-ai-easy-setup.md) and let it call:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh --mode inspect --print-json
/root/twinmind-split-kit/scripts/ai_easy_setup.sh --mode preflight --print-json
/root/twinmind-split-kit/scripts/ai_easy_setup.sh --mode plan --print-json
```

If inspect reports an existing TwinMind-managed install, the AI should switch to:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh --mode update-plan --print-json
```

Only after you explicitly approve the plan should it run:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh --mode apply --yes --print-json
```

For an existing TwinMind-managed install, approval should instead trigger:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh --mode update-apply --yes --print-json
```

That wrapper still delegates the real patching work to `convert_clawdbot_to_split.sh`; it does not implement a second migration path.

## Modes

- `plan`: inspect what would change
- `apply`: back up and patch the target config
- `rollback`: restore from a prior manifest
- `update-plan`: inspect what a later TwinMind runtime refresh would change
- `update-apply`: update an already TwinMind-managed install
- `update-rollback`: restore a prior update

## Preflight

1. `python3` is installed.
2. `sha256sum` is installed.
3. Python `requests` is installed for the wrapper runtime.
4. Runtime secrets are available locally: `TWINMIND_REFRESH_TOKEN` and `TWINMIND_FIREBASE_API_KEY`.
5. If you keep the default executor profile, `codex` CLI is installed and authenticated.

The script does not install dependencies for you.

`apply` also copies these runtime files into `<target-app-root>/clawd/skills/twinmind-orchestrator/scripts` before updating the backend path:

- `twinmind_orchestrator.py`
- `twinmind_memory_sync.py`
- `twinmind_memory_query.py`

The migration fails fast if `agents` or `agents.defaults` is missing or not an object. Missing deeper objects under that validated subtree are still created when needed.

## Plan first

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh --mode plan
```

If `--config` is omitted, the script auto-detects common config paths, including:

- `~/.clawdbot/clawdbot.json`
- `~/.openclaw/clawdbot.json`
- `~/.openclaw/openclaw.json`
- `~/.moltbook/moltbook.json`
- `~/.moltbot/moltbot.json`
- `~/.config/openclaw/clawdbot.json`
- `~/.config/openclaw/openclaw.json`
- `~/.config/moltbook/moltbook.json`
- `~/.config/moltbot/moltbot.json`

If `--env` is omitted, the neighboring `.env` next to the detected config is used.

If you want the same flow in a machine-readable wrapper for a terminal AI tool, use:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh --mode plan --print-json
```

For a later TwinMind runtime refresh on an already managed install, use:

```bash
/root/twinmind-split-kit/scripts/inspect_twinmind_install.sh --print-json
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh --mode update-plan
```

The default update flow is runtime-only. Config-sync and env-template-sync are opt-in.

## Apply

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode apply \
  --yes
```

Optional additions:

- append non-secret env defaults: `--patch-env`
- default backend mode `tool_bridge` instead of `conversation`: `--force-split-default`

## Later updates

Use this path only after the install is already TwinMind-managed.

Inspect the install first:

```bash
/root/twinmind-split-kit/scripts/inspect_twinmind_install.sh --print-json
```

Plan the update:

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh --mode update-plan
```

Apply the update after review:

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode update-apply \
  --yes
```

Optional additions:

- synchronize managed backend fields: `--sync-config 1`
- append new non-secret env template keys: `--sync-env-template 1`

Rollback a later update:

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode update-rollback \
  --update-id <update-id> \
  --yes
```

The update flow should not be used as a re-migration shortcut. If `inspect` does not report a TwinMind-managed install, go back to the first migration path on this page.

## What the converter writes by default

The patched backend args include:

- `--mode conversation`
- `--routing-mode strict_split`
- `--executor-provider codex_cli`
- `--executor-model gpt-5.3-codex`

Migration artifacts:

- report: `reports/convert-<migration-id>.json`
- backup: `backups/clawdbot.json.<migration-id>.bak`
- manifest: `manifests/migration-<migration-id>.json`

Existing unknown keys under `agents.defaults.cliBackends.twinmind-cli` are preserved. The migration only overwrites the managed TwinMind backend fields.

## Post-migration smoke test

Reusable helper:

```bash
/root/twinmind-split-kit/scripts/smoke_test_migration.sh --print-json
```

If you are using the AI wrapper flow, this step is already covered by:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh --mode smoke-test --print-json
```

Run the migrated backend exactly as the config now defines it, then inspect the wrapper log. If your live config is not `~/.clawdbot/clawdbot.json`, set `CFG` to the real path first.

### 1. Execute the backend from the patched config

```bash
CFG="${CFG:-$HOME/.clawdbot/clawdbot.json}"
python3 - "$CFG" <<'PY'
import json, subprocess, sys
cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
backend = cfg["agents"]["defaults"]["cliBackends"]["twinmind-cli"]
cmd = [backend["command"], *backend["args"], "Was sind meine aktuellen Sharezone-Hausaufgaben?"]
print("Running:", " ".join(cmd[:-1]), "<query>")
subprocess.run(cmd, check=False)
PY
```

Why this query: it is a tool-intent request, so a migrated `conversation` backend should still override into the split executor path.

### 2. Confirm the expected log events

```bash
RUNTIME_ROOT="$(dirname "$CFG")"
LATEST="$(ls -1t "$RUNTIME_ROOT"/twinmind-orchestrator/logs/*.jsonl | head -n 1)"
rg -n 'router_decision|executor_request|executor_response|final|final_after_skill_run' "$LATEST"
```

Expected signals:

- `tool_bridge_override` or direct `split_executor_bridge`
- `executor_request` with the provider/model you intended
- `executor_response` with status `200`
- `final` or `final_after_skill_run`

If the executor request still shows `provider=codex_cli` after you tried to switch to another provider, read [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md).

## Switching provider/model after migration

Do not rely on `.env` alone for provider/model switching after a live migration.

The backend parser uses this precedence:

1. explicit CLI args in the backend config
2. env vars
3. built-in defaults

Because the migration script writes explicit `--executor-provider codex_cli` and `--executor-model gpt-5.3-codex` args, switching to an HTTP executor requires editing `agents.defaults.cliBackends.twinmind-cli.args` first. Use `.env` for values the scripts do not pin, such as `ORCH_EXECUTOR_BASE_URL` and API keys.

Details and examples: [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md)

## Rollback

Use the manifest written during `apply`:

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode rollback \
  --migration-id <migration-id> \
  --yes
```

See also: [08-rollback.md](./08-rollback.md)

## Later updates

After an installation is already TwinMind-managed, do not run a fresh migration again just to pull newer vendored runtime files. Use the dedicated update flow instead:

```bash
/root/twinmind-split-kit/scripts/inspect_twinmind_install.sh --print-json
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh --mode update-plan
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh --mode update-apply --yes
```

Or through the wrapper:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh inspect --print-json
/root/twinmind-split-kit/scripts/ai_easy_setup.sh update-plan --print-json
/root/twinmind-split-kit/scripts/ai_easy_setup.sh update-apply --yes --print-json
```

Defaults:

- update is **runtime-only**
- config sync is opt-in with `--sync-config 1`
- env template sync is opt-in with `--sync-env-template 1`
- update only works for **TwinMind-managed installs**

For later TwinMind runtime refreshes on an already managed install, use the separate update rollback path described in [08-rollback.md](./08-rollback.md).
