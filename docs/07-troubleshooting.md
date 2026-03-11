# Troubleshooting

## Migration and rollback

### Converter fails with invalid JSON

Cause: malformed target config.

Fix:

1. repair `clawdbot.json`
2. rerun `--mode plan`

### Apply rejected due to missing `--yes`

Cause: safety gate.

Fix: rerun with `--yes`.

### Rollback cannot find manifest

Cause: wrong migration id or missing files.

Fix:

1. inspect `manifests/`
2. rerun with the exact `--migration-id`

### Auto-detection did not find my config

Cause: config is outside the built-in Clawdbot/OpenClaw search paths.

Fix: pass `--config <path>` explicitly.

Note: OpenClaw support here is limited to compatible config paths and config shape.

## Profile switching and executor issues

### I changed `.env`, but the runtime still uses Codex

Cause: the migrated backend config contains explicit `--executor-provider codex_cli` and `--executor-model gpt-5.3-codex` args. Explicit backend args beat env vars.

Fix:

1. edit `agents.defaults.cliBackends.twinmind-cli.args`
2. change or remove the pinned provider/model args
3. keep `ORCH_EXECUTOR_BASE_URL` and auth in `.env` for HTTP profiles
4. rerun the smoke test from [05-migration-guide.md](./05-migration-guide.md)

### `strict_split` executor fails: `codex_cli executor failed`

Cause: `codex` binary missing, login expired, timeout, or model unavailable.

Fix:

1. verify `codex` exists and is executable
2. verify Codex login for the same machine/user as the wrapper runtime
3. confirm the configured model is available to that account
4. increase executor timeout if needed

### HTTP executor returns `401` or `403`

Cause: wrong key or wrong provider config.

Fix:

1. verify provider/model/base URL match the endpoint you intended
2. verify auth values
3. confirm the endpoint accepts your key scope

### HTTP executor returns `404` or `5xx`

Cause: wrong `ORCH_EXECUTOR_BASE_URL`, wrong model, or upstream outage.

Fix:

1. verify the base URL resolves to a working `/chat/completions` endpoint
2. verify the model name exists there
3. retry after transient upstream failures

### Expected Codex OAuth fallback, but auth is still missing

Cause: no usable local Codex auth profile.

Fix:

1. run Codex login on the same machine/user as the wrapper runtime
2. optionally set `ORCH_EXECUTOR_CODEX_PROFILE`
3. remove conflicting invalid key values
4. retry and inspect the executor auth error in logs

## Runtime prerequisites

### Wrapper runtime error: missing `TWINMIND_REFRESH_TOKEN`

Fix:

1. add `TWINMIND_REFRESH_TOKEN`
2. restart the runtime
3. verify env file loading order

### Wrapper runtime error: Firebase token refresh failed

Fix:

1. set a valid `TWINMIND_FIREBASE_API_KEY`
2. remove trailing spaces or quotes
3. retry and inspect the wrapper log

### Module error: `requests` not found

Fix:

1. install Python `requests` in the runtime environment
2. rerun the preflight checks

## Route and feature behavior

### My smoke test did not hit `split_executor_bridge`

Cause: the request stayed in plain conversation or hit a fastpath.

Fix:

1. use the documented smoke-test query: `Was sind meine aktuellen Sharezone-Hausaufgaben?`
2. confirm the backend is still `--routing-mode strict_split`
3. inspect `router_decision` lines in the latest log

### Audio message says transcription is unavailable

Cause: inbound audio was detected, but no usable transcript block reached the wrapper.

Fix:

1. verify the upstream gateway injects `[Audio] ... Transcript: ...`
2. if STT happens upstream, verify `DEEPGRAM_API_KEY`
3. check the latest log for `audio_stt_unavailable_fastpath`

Quick check:

```bash
CFG="${CFG:-$HOME/.clawdbot/clawdbot.json}"
RUNTIME_ROOT="$(dirname "$CFG")"
LATEST="$(ls -1t "$RUNTIME_ROOT"/twinmind-orchestrator/logs/*.jsonl | head -n 1)"
rg -n 'audio_stt_unavailable_fastpath|routing_adjustment|Transcript:' "$LATEST"
```

### TwinMind web search fails, but local fallback should handle it

Fix:

1. verify `ORCH_TWINMIND_WEBERROR_LOCAL_FALLBACK=1`
2. verify `BRAVE_API_KEY`
3. optionally set `SEARXNG_URL`
4. inspect the log for `fallback_triggered`, `fallback_skipped`, or provider warnings

### Brave search hits rate limits

Fix:

1. increase `ORCH_WEBSEARCH_BRAVE_MIN_INTERVAL_MS`
2. keep retries enabled
3. configure `SEARXNG_URL` as fallback
4. inspect `provider_attempts` in logs or tool output

### WhatsApp says timer/reminder is not available

Cause: the request was routed into `twinmind_conversation` instead of a tool-capable path.

Fix:

1. deploy the current `vendor/twinmind_orchestrator.py`
2. restart the wrapper runtime or gateway
3. verify the latest log shows `tool_bridge_override` with `split_executor_bridge` or `reminder_fastpath`
4. confirm it did not stay in `twinmind_conversation`

Quick check:

```bash
CFG="${CFG:-$HOME/.clawdbot/clawdbot.json}"
RUNTIME_ROOT="$(dirname "$CFG")"
LATEST="$(ls -1t "$RUNTIME_ROOT"/twinmind-orchestrator/logs/*.jsonl | head -n 1)"
rg -n 'router_decision|remind_me|final' "$LATEST"
```

## Channel and platform limits

### Telegram or another non-WhatsApp channel behaves inconsistently

Cause: this wrapper contains explicit transport parsing for WhatsApp metadata, not Telegram-specific gateway semantics.

Fix:

1. treat non-WhatsApp usage as plain-text best effort
2. test route-dependent features manually
3. do not assume auto-target reply behavior outside WhatsApp

### I need Moltbook support

Cause: this repo only supports Moltbook/Moltbot config locations that still use the same Clawdbot-style JSON shape. It does not ship a dedicated Moltbook-specific runtime or transport adapter.

Fix:
1. use this kit only when the Moltbook/Moltbot config still matches the documented Clawdbot-style JSON layout,
2. run `--mode plan` first and inspect the patched keys,
3. if your install uses a different schema or transport layer, treat it as unsupported until you add a dedicated adapter outside the scope of this kit.

## Related docs

- [05-migration-guide.md](./05-migration-guide.md)
- [06-operations-runbook.md](./06-operations-runbook.md)
- [08-rollback.md](./08-rollback.md)
- [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md)
