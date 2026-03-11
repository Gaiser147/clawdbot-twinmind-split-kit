# Rollback

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

## Verification checklist
1. Rollback refuses to run if `clawdbot.json` drifted from the manifest `after_checksum`.
2. If migration managed `.env`, rollback also checks the recorded env checksum before restoring or deleting it.
3. Verify backend references are restored to pre-migration state.
4. Confirm runtime responds as before migration.
