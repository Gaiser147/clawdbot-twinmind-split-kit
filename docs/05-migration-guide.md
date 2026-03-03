# Migration Guide

## Objective
Patch an existing local Linux Clawdbot config so it uses the TwinMind wrapper backend.

## Script
- `scripts/convert_clawdbot_to_split.sh`

## Modes
- `plan`: compute and report patch scope only.
- `apply`: backup + patch + manifest generation.
- `rollback`: restore from previous backup manifest.

## Preflight (vorher pruefen)
1. `python3` ist vorhanden.
2. `sha256sum` ist vorhanden.
3. Wrapper-Runtime-Abhaengigkeit `requests` ist installiert.
4. Wenn `strict_split` mit Codex-Executor genutzt wird: `codex` CLI ist installiert und eingeloggt.

Hinweis:
- Der Converter installiert keine Abhaengigkeiten automatisch.

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

## Was der Converter standardmaessig setzt
- `--routing-mode strict_split`
- `--executor-provider codex_cli`
- `--executor-model gpt-5.3-codex`
- backend mode default bleibt `conversation` (ausser `--force-split-default`)

## Alternatives Modell nach Migration aktivieren (manuell)
Der Converter bleibt unveraendert auf Codex-Default. Wenn du z. B. Gemini nutzen willst:
1. Migration normal ausfuehren.
2. Danach `ORCH_EXECUTOR_*` Werte in Runtime `.env` oder Backend-Args anpassen.
3. Mit Runbook-Checks verifizieren, dass der neue Executor aktiv ist.

Beispiel (OpenAI-kompatibles Profil):
```env
ORCH_EXECUTOR_PROVIDER=openai
ORCH_EXECUTOR_MODEL=<dein-modellname>
ORCH_EXECUTOR_BASE_URL=<dein-openai-kompatibles-base-url>
ORCH_EXECUTOR_API_KEY=<dein-api-key>
```

## Outputs
- report: `reports/convert-<migration-id>.json`
- backup: `backups/clawdbot.json.<migration-id>.bak`
- manifest: `manifests/migration-<migration-id>.json`

## Idempotency
Repeated apply with the same target shape is a no-op at field level.

Weiter:
- [04-config-reference.md](./04-config-reference.md)
- [06-operations-runbook.md](./06-operations-runbook.md)
- [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md)
