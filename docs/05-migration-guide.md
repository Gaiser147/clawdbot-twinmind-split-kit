# Migration Guide

## Objective
Patch an existing local Linux Clawdbot config so it uses the TwinMind wrapper backend.

## Script
- `scripts/convert_clawdbot_to_split.sh`

## Modes
- `plan`: compute and report patch scope only.
- `apply`: backup + patch + manifest generation.
- `rollback`: restore from previous backup manifest.

## Plan first
```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode plan \
  --config /root/.clawdbot/clawdbot.json
```

## Apply
```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode apply \
  --yes \
  --config /root/.clawdbot/clawdbot.json
```

Optional env default append:
```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode apply \
  --yes \
  --patch-env
```

Optional forced default bridge mode:
```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode apply \
  --yes \
  --force-split-default
```

## Outputs
- report: `reports/convert-<migration-id>.json`
- backup: `backups/clawdbot.json.<migration-id>.bak`
- manifest: `manifests/migration-<migration-id>.json`

## Idempotency
Repeated apply with the same target shape is a no-op at field level.
