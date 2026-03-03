# Troubleshooting

## Converter fails with invalid JSON
Cause: malformed `clawdbot.json`.
Fix: repair JSON and rerun `--mode plan`.

## Apply rejected due to missing --yes
Cause: safety gate.
Fix: rerun with `--yes`.

## Rollback cannot find manifest
Cause: wrong migration id or missing files.
Fix: check `manifests/` and rerun with exact `--migration-id`.

## GitHub repo creation fails
Cause: no `gh`, missing token, or insufficient permissions.
Fix:
1. install/authenticate `gh`, or
2. export `GITHUB_TOKEN` and use REST fallback.

## safe_push blocked by secret findings
Cause: potential credential pattern detected.
Fix:
1. remove/redact sensitive content,
2. re-run secret scan,
3. push only after clean scan.

## Wrapper runtime errors after migration
Cause: missing `TWINMIND_REFRESH_TOKEN` or unreachable API.
Fix:
1. validate env,
2. check network access,
3. inspect wrapper logs under `.clawdbot`.
