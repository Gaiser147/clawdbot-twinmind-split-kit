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
- `.env` only if env backup exists in manifest

## Verification checklist
1. Compare current config checksum with backup checksum.
2. Verify backend references are restored to pre-migration state.
3. Confirm runtime responds as before migration.
