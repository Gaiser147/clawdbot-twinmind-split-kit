# Configuration Reference

## Pflichtvariablen (Runtime)

| Variable | Pflicht | Zweck |
|---|---|---|
| `TWINMIND_REFRESH_TOKEN` | Ja | TwinMind Auth-Refresh fuer ID-Token |
| `TWINMIND_FIREBASE_API_KEY` | Ja | Firebase Secure Token API-Key fuer Token-Refresh |

Ohne diese beiden Werte kann der Wrapper keine TwinMind-Requests stabil ausfuehren.

## Optional haeufig genutzt

| Variable | Zweck |
|---|---|
| `TWINMIND_API_BASE` | TwinMind API Basis-URL |
| `TWINMIND_API_ENDPOINT` | TwinMind Endpoint-Path |
| `TWINMIND_VERCEL_BYPASS` | Optionaler Bypass Header-Wert |
| `TWINMIND_USER_AGENT` | Eigener User-Agent |

## Split/Executor-Konfiguration

| Variable | Zweck |
|---|---|
| `ORCH_ROUTING_MODE` | `legacy` oder `strict_split` |
| `ORCH_EXECUTOR_PROVIDER` | Executor-Typ (`codex_cli`, `openai`, `openai_codex`, `codex`, weitere HTTP-Provider) |
| `ORCH_EXECUTOR_MODEL` | Modellname fuer den Executor |
| `ORCH_EXECUTOR_BASE_URL` | HTTP-Basis fuer Chat-Completions (`<base>/chat/completions`) |
| `ORCH_EXECUTOR_API_KEY` | Generischer API-Key fuer HTTP-Executor |
| `ORCH_EXECUTOR_MAX_STEPS` | Step-Limit im Executor-Loop |
| `ORCH_EXECUTOR_MAX_TOOL_CALLS` | Tool-Call-Limit im Executor-Loop |
| `ORCH_EXECUTOR_USE_TWINMIND_PLANNER` | TwinMind-Planner-Brief aktivieren/deaktivieren |

## Modellprofile (ohne Codeaenderung)

### Profil A: Codex Default (aus Skripten)

```env
ORCH_EXECUTOR_PROVIDER=codex_cli
ORCH_EXECUTOR_MODEL=gpt-5.3-codex
```

Hinweise:
- benoetigt lokale `codex` CLI und Auth.
- `ORCH_EXECUTOR_BASE_URL`/`ORCH_EXECUTOR_API_KEY` werden in diesem Profil nicht benoetigt.
- fuer `gpt-5.3-codex` im Default-Split-Pfad wird die Codex-CLI-OAuth-Session genutzt.

### Profil B: OpenAI-kompatibler HTTP-Executor (z. B. Gemini-kompatibles Endpoint)

```env
ORCH_EXECUTOR_PROVIDER=openai
ORCH_EXECUTOR_MODEL=<dein-modellname>
ORCH_EXECUTOR_BASE_URL=<dein-openai-kompatibles-base-url>
ORCH_EXECUTOR_API_KEY=<dein-api-key>
```

Hinweise:
- `ORCH_EXECUTOR_BASE_URL` muss ein Endpoint sein, der `chat/completions` im OpenAI-Format akzeptiert.
- fuer Provider `openai`/`openai_codex`/`codex` kann alternativ auch `OPENAI_API_KEY` genutzt werden.

<details>
<summary><strong>Wer gewinnt bei Key-Konflikten?</strong></summary>

Bei `openai`-artigen Providern wird in dieser Reihenfolge aufgeloest:
1. expliziter `--executor-api-key` (oder daraus aufgeloester `ORCH_EXECUTOR_API_KEY`)
2. `OPENAI_API_KEY`
3. `ORCH_EXECUTOR_API_KEY` (env)
4. Codex OAuth aus lokalem Auth-Profil

Bei `codex_cli` wird nicht ueber HTTP-Key aufgeloest, sondern lokal ueber die Codex-CLI-Auth ausgefuehrt.

</details>

## Clawdbot config paths, die der Converter patched
- `agents.defaults.model.primary`
- `agents.defaults.models.twinmind-cli/default`
- `agents.defaults.cliBackends.twinmind-cli`

## Backend defaults, die der Converter schreibt
- command: `python3`
- script: `<kit-root>/vendor/twinmind_orchestrator.py`
- output: `json`
- sessionArg: `--session-id`
- serialize: `true`
- migration default args enthalten aktuell:
  - `--routing-mode strict_split`
  - `--executor-provider codex_cli`
  - `--executor-model gpt-5.3-codex`

## Wichtige Grenzen der aktuellen Skripte
- Converter/Replica setzen aktuell Codex-Defaultwerte.
- Andere Modelle werden danach manuell ueber `.env`/Backend-Args konfiguriert.
- Skripte installieren keine externen Dependencies.

Siehe:
- `analysis/config_matrix.json`
- `templates/clawdbot.patch.template.json`
- [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md)
