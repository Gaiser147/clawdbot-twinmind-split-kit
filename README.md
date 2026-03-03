# TwinMind Split Kit

Self-contained package for:
- documenting TwinMind wrapper + split logic,
- migrating standard Linux Clawdbot installs to wrapper-backed routing,
- generating a reproducible replica layout,
- preparing safe push to a private GitHub repository.

This kit is intentionally separate from live runtime paths.

## Layout
- `docs/` complete operator + developer documentation
- `vendor/` vendored wrapper scripts
- `scripts/` migration/bootstrap/github tooling
- `templates/` patch/env templates
- `manifests/` schema and generated migration manifests
- `analysis/` code mapping artifacts and line references

## Safety Rules
- No script auto-runs migration.
- Always run `plan` first.
- Never commit real credentials.
- Use `scripts/safe_push.sh` before every push.

## Quick Start

### 1) Review and plan migration
```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode plan \
  --config /root/.clawdbot/clawdbot.json
```

### 2) Apply migration (manual)
```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode apply \
  --yes \
  --config /root/.clawdbot/clawdbot.json
```

### 3) Rollback by migration id
```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode rollback \
  --migration-id <migration-id> \
  --yes
```

### 4) Build a reproducible replica layout
```bash
/root/twinmind-split-kit/scripts/bootstrap_clawdbot_replica.sh \
  --mode plan \
  --target-root /root/.clawdbot-replica
```

```bash
/root/twinmind-split-kit/scripts/bootstrap_clawdbot_replica.sh \
  --mode apply \
  --target-root /root/.clawdbot-replica \
  --yes
```

## Private GitHub Repository Workflow

### Create private repository
If `gh` is installed and authenticated:
```bash
/root/twinmind-split-kit/scripts/create_private_github_repo.sh \
  --owner <your-github-user> \
  --repo clawdbot-twinmind-split-kit \
  --visibility private
```

If `gh` is not available, set token in environment and use API fallback:
```bash
export GITHUB_TOKEN=__YOUR_TOKEN__
/root/twinmind-split-kit/scripts/create_private_github_repo.sh \
  --owner <your-github-user> \
  --repo clawdbot-twinmind-split-kit \
  --visibility private \
  --owner-type user
```

### Safe push
```bash
cd /root/twinmind-split-kit
git init
git add .
git commit -m "Initial twinmind split kit"
/root/twinmind-split-kit/scripts/safe_push.sh \
  --remote git@github.com:<your-github-user>/clawdbot-twinmind-split-kit.git \
  --branch main
```

## Documentation Index
- `docs/01-overview.md`
- `docs/02-wrapper-architecture.md`
- `docs/03-split-routing.md`
- `docs/04-config-reference.md`
- `docs/05-migration-guide.md`
- `docs/06-operations-runbook.md`
- `docs/07-troubleshooting.md`
- `docs/08-rollback.md`
- `docs/09-script-reference.md`

## Provenance
See `vendor/PROVENANCE.md` for source paths and checksums of vendored scripts.

### One-shot dry-run helper
```bash
/root/twinmind-split-kit/scripts/init_private_repo_and_push.sh \
  --owner <your-github-user> \
  --repo clawdbot-twinmind-split-kit \
  --dry-run 1
```

## Required Runtime Secrets
- `TWINMIND_REFRESH_TOKEN`
- `TWINMIND_FIREBASE_API_KEY`

Set them in your runtime `.env` (never commit this file).
