# Rollback

This page covers two separate rollback paths:

- migration rollback after the initial TwinMind patch
- update rollback after a later TwinMind runtime refresh

Use the one that matches the artifact written by the script you actually ran.

## Migration rollback

## Preconditions
- A prior successful apply exists.
- Manifest is present in `manifests/migration-<id>.json`.

## Execute rollback
```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode rollback \
  --migration-id <migration-id> \
  --yes
```

## What rollback restores
- `clawdbot.json` from recorded backup path
- `.env` from backup if one existed before migration
- a migration-created `.env` is removed again when it still matches the applied checksum

## What rollback does not remove automatically

- copied runtime files under `<target-app-root>/clawd/skills/twinmind-orchestrator/scripts`

Rollback restores config and env state. It does not currently delete the copied runtime files from the target app tree for you.

## Update rollback

For later runtime updates, use the separate update manifest and update rollback mode:

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode update-rollback \
  --update-id <update-id> \
  --yes
```

Update rollback restores:

- vendored runtime files from `backups/runtime-<update-id>/`
- `clawdbot.json` only if the update used `--sync-config 1`
- `.env` only if the update used `--sync-env-template 1`

Update rollback refuses to run if the installed runtime files drifted from the manifest-recorded post-update checksums.

## Verification checklist
1. Rollback refuses to run if `clawdbot.json` drifted from the manifest `after_checksum`.
2. If migration managed `.env`, rollback also checks the recorded env checksum before restoring or deleting it.
3. Verify backend references are restored to pre-migration state.
4. Confirm runtime responds as before migration.

## Update rollback

Use this path only for an install that was already TwinMind-managed and later updated through `update-apply`.

### Preconditions
- A prior successful update exists.
- Manifest is present in `manifests/update-<update-id>.json`.

### Execute update rollback
```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode update-rollback \
  --update-id <update-id> \
  --yes
```

### What update rollback restores
- copied TwinMind runtime files from the recorded runtime backup
- `clawdbot.json` only if that specific update used config sync
- `.env` only if that specific update used env-template sync and the recorded checksum rules still match

### Default behavior reminder

The default update flow is runtime-only. If you ran `update-apply` without opt-in sync flags, update rollback primarily restores the copied runtime files and does not need to touch config or env.

### Verification checklist
1. Confirm the runtime file checksums match the backed-up pre-update values.
2. If config sync was part of the update, verify the managed TwinMind backend fields were restored.
3. If env-template sync was part of the update, verify env drift checks passed before restore/delete.
4. Re-run your normal smoke test after rollback.
