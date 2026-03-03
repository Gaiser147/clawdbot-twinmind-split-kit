# Operations Runbook

## Daily operator checks
1. Verify wrapper script path exists.
2. Verify required env token is present.
3. Verify backend output mode remains `json`.
4. Verify no accidental config drift in `clawdbot.json`.

## Build a reproducible replica
Plan:
```bash
/root/twinmind-split-kit/scripts/bootstrap_clawdbot_replica.sh \
  --mode plan \
  --target-root /root/.clawdbot-replica
```

Apply:
```bash
/root/twinmind-split-kit/scripts/bootstrap_clawdbot_replica.sh \
  --mode apply \
  --target-root /root/.clawdbot-replica \
  --yes
```

## What replica script creates
- `clawd/skills/twinmind-orchestrator/scripts/*`
- `.clawdbot/clawdbot.json`
- `.clawdbot/.env.example`

## Manual post-apply steps
1. Fill real secrets in runtime `.env` (not in repo).
2. Validate wrapper invocation manually.
3. Confirm logs and session continuity behavior.
