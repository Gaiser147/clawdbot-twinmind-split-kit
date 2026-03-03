# QA Checklist

- [x] Package is fully separated from live installation paths.
- [x] TwinMind wrapper scripts are vendored with provenance.
- [x] Migration script supports plan/apply/rollback.
- [x] Migration writes backups and manifest.
- [x] Replica script creates reproducible target structure.
- [x] GitHub private repo script exists with auth fallback.
- [x] Safe push script scans secrets before push.
- [x] Security policy and ignore rules block common credential leaks.
- [x] Documentation covers architecture, routing, operations, troubleshooting, rollback.
- [x] Scripts validated with static syntax checks (`bash -n`).
