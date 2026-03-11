# Configuration Reference

## Required runtime variables

| Variable | Required | Purpose |
|---|---|---|
| `TWINMIND_REFRESH_TOKEN` | yes | TwinMind refresh token used to obtain ID tokens |
| `TWINMIND_FIREBASE_API_KEY` | yes | Firebase Secure Token API key for token refresh |

Without these two values, the wrapper cannot execute TwinMind requests reliably.

## Common optional variables

| Variable | Purpose |
|---|---|
| `TWINMIND_API_BASE` | TwinMind API base URL |
| `TWINMIND_API_ENDPOINT` | TwinMind endpoint path |
| `TWINMIND_VERCEL_BYPASS` | optional bypass header value |
| `TWINMIND_USER_AGENT` | custom user agent |

## Media and web-search options

| Variable | Purpose |
|---|---|
| `DEEPGRAM_API_KEY` | upstream/gateway STT for audio; without transcript the wrapper reports `audio_stt_unavailable_fastpath` |
| `ORCH_TWINMIND_WEBERROR_LOCAL_FALLBACK` | enable local web-search fallback on TwinMind web errors |
| `ORCH_WEBSEARCH_BRAVE_MIN_INTERVAL_MS` | minimum spacing between Brave requests |
| `ORCH_WEBSEARCH_BRAVE_MAX_RETRIES` | retry count for Brave on `429`/`5xx`/network errors |
| `ORCH_WEBSEARCH_RETRY_BASE_MS` | initial retry backoff |
| `ORCH_WEBSEARCH_RETRY_MAX_MS` | maximum retry backoff |
| `ORCH_WEBSEARCH_CONTINUE_ON_FAILURE` | allow degraded success instead of hard failure |
| `SEARXNG_URL` | optional fallback endpoint for local web search |
| `SEARXNG_TIMEOUT_SEC` | timeout for SearXNG |
| `SEARXNG_ENGINES` | optional engine list for SearXNG |
| `SEARXNG_LANGUAGE` | optional language for SearXNG |
| `ORCH_WEBSEARCH_SEARXNG_MIN_INTERVAL_MS` | minimum spacing between SearXNG requests |

## Split and executor variables

| Variable | Purpose |
|---|---|
| `ORCH_ROUTING_MODE` | `legacy` or `strict_split` when not pinned by backend args |
| `ORCH_EXECUTOR_PROVIDER` | executor type (`codex_cli`, `openai`, `openai_codex`, `codex`, other HTTP providers) |
| `ORCH_EXECUTOR_MODEL` | executor model name |
| `ORCH_EXECUTOR_BASE_URL` | HTTP base URL; wrapper calls `<base>/chat/completions` |
| `ORCH_EXECUTOR_API_KEY` | generic API key for HTTP executors |
| `ORCH_EXECUTOR_MAX_STEPS` | step limit in the executor loop |
| `ORCH_EXECUTOR_MAX_TOOL_CALLS` | tool-call limit in the executor loop |
| `ORCH_EXECUTOR_USE_TWINMIND_PLANNER` | enable or disable the TwinMind planner brief |

## Precedence: backend args first

The wrapper parser uses explicit CLI args first, then env, then built-in defaults.

That matters because the migration and replica scripts pin these backend args by default:

- `--routing-mode strict_split`
- `--executor-provider codex_cli`
- `--executor-model gpt-5.3-codex`

So editing only `ORCH_EXECUTOR_PROVIDER` or `ORCH_EXECUTOR_MODEL` in `.env` will not change a migrated backend until you also edit the backend args in the config.

## Default profiles written by the scripts

### Profile A: Codex default

```env
ORCH_EXECUTOR_PROVIDER=codex_cli
ORCH_EXECUTOR_MODEL=gpt-5.3-codex
```

Notes:

- requires local `codex` CLI and auth
- `ORCH_EXECUTOR_BASE_URL` is not used in this profile
- `ORCH_EXECUTOR_API_KEY` is not the primary auth path for `codex_cli`

### Profile B: HTTP / OpenAI-compatible executor

```env
ORCH_EXECUTOR_PROVIDER=openai
ORCH_EXECUTOR_MODEL=<your-model>
ORCH_EXECUTOR_BASE_URL=<your-base-url>
ORCH_EXECUTOR_API_KEY=<your-api-key>
```

Notes:

- use this only after changing the pinned backend args
- `OPENAI_API_KEY` can also be used for OpenAI-like providers

## Clawdbot config paths patched by the converter

- `agents.defaults.model.primary`
- `agents.defaults.models.twinmind-cli/default`
- `agents.defaults.cliBackends.twinmind-cli`

## Backend defaults written by the converter

- command: `python3`
- script: `<target-app-root>/clawd/skills/twinmind-orchestrator/scripts/twinmind_orchestrator.py`
- output: `json`
- session arg: `--session-id`
- serialize: `true`

## Current script limits

- converter and replica pin Codex defaults unless you edit the backend args afterward
- scripts do not install external dependencies
- live migration expects an existing `agents.defaults` object and does not create a brand new inactive root tree
- OpenClaw, Moltbook, and Moltbot are supported only for compatible config locations and config shape

See also:

- `analysis/config_matrix.json`
- `templates/clawdbot.patch.template.json`
- [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md)
