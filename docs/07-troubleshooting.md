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

## Wrapper runtime error: Missing TWINMIND_REFRESH_TOKEN
Cause: refresh token not set in runtime `.env`.
Fix:
1. add `TWINMIND_REFRESH_TOKEN`,
2. restart runtime,
3. verify environment load order.

## Wrapper runtime error: Firebase token refresh failed
Cause: missing/invalid `TWINMIND_FIREBASE_API_KEY`.
Fix:
1. set valid `TWINMIND_FIREBASE_API_KEY`,
2. verify no trailing spaces/quotes,
3. retry request and inspect wrapper log event.

## strict_split executor fails: codex_cli executor failed
Cause: `codex` binary missing, not authenticated, timed out, or model not available.
Fix:
1. verify `codex` CLI is installed and executable,
2. verify Codex login/auth profile,
3. confirm `ORCH_EXECUTOR_MODEL` exists for your account,
4. increase executor timeout if needed.

## strict_split HTTP executor returns 401/403
Cause: wrong key or wrong provider config.
Fix:
1. validate `ORCH_EXECUTOR_PROVIDER`,
2. validate `ORCH_EXECUTOR_API_KEY` / `OPENAI_API_KEY`,
3. ensure endpoint accepts your key scope.

## Codex OAuth fallback expected, but auth still missing
Cause: no valid local Codex auth profile for OAuth fallback.
Fix:
1. run Codex CLI login on the same machine/user as wrapper runtime,
2. optionally set `ORCH_EXECUTOR_CODEX_PROFILE` to the intended profile name,
3. remove conflicting invalid API-key values in `.env`,
4. retry and inspect executor auth error in logs.

## strict_split HTTP executor returns 404/5xx
Cause: wrong `ORCH_EXECUTOR_BASE_URL` or upstream outage.
Fix:
1. verify base URL (must resolve to working chat-completions endpoint),
2. verify model name exists,
3. retry after transient outage.

## Module error: requests not found
Cause: Python dependency `requests` missing.
Fix:
1. install `requests` in the Python environment used by wrapper,
2. rerun preflight checks.

## Migration worked, but Gemini is not used
Cause: converter still patched Codex defaults.
Fix:
1. manually set `ORCH_EXECUTOR_PROVIDER` + `ORCH_EXECUTOR_MODEL` + URL/key profile,
2. verify executor_request logs show HTTP profile instead of `codex_cli`.

## Audio message says transcription is unavailable
Cause: inbound audio was detected, but the wrapper did not receive a usable transcript block.
Fix:
1. verify the upstream gateway really injects `[Audio] ... Transcript: ...`,
2. if STT should happen on the gateway, verify `DEEPGRAM_API_KEY`,
3. check latest log route:
   - expected on failure: `audio_stt_unavailable_fastpath`
4. quick check:
```bash
LATEST="$(ls -1t /root/.clawdbot/twinmind-orchestrator/logs/*.jsonl | head -n 1)"
rg -n 'audio_stt_unavailable_fastpath|routing_adjustment|Transcript:' "$LATEST"
```

## TwinMind web search fails, but local fallback should handle it
Cause: TwinMind returned HTTP error / \"web search unavailable\" and local fallback was disabled or misconfigured.
Fix:
1. verify `ORCH_TWINMIND_WEBERROR_LOCAL_FALLBACK=1`,
2. verify `BRAVE_API_KEY`,
3. optionally set `SEARXNG_URL` as second fallback,
4. inspect latest log for:
   - `fallback_triggered`
   - `fallback_skipped`
   - Brave/SearXNG errors in `warnings` or `provider_attempts`

## Brave search hits rate limits
Cause: wrapper is exceeding Brave quota cadence.
Fix:
1. increase `ORCH_WEBSEARCH_BRAVE_MIN_INTERVAL_MS`,
2. keep `ORCH_WEBSEARCH_BRAVE_MAX_RETRIES` > 0,
3. configure `SEARXNG_URL` so the wrapper can fail over,
4. inspect `provider_attempts` in the tool result or wrapper logs.

## WhatsApp says timer/reminder is not available
Cause: reminder query was routed into `twinmind_conversation` instead of tool-capable split path.
Fix:
1. deploy latest `vendor/twinmind_orchestrator.py` from this repo,
2. restart gateway/wrapper runtime,
3. verify latest log route:
   - expected: `tool_bridge_override` + `split_executor_bridge` or `reminder_fastpath`
   - not expected: `twinmind_conversation` for reminder/timer intent
4. quick check command:
```bash
LATEST="$(ls -1t /root/.clawdbot/twinmind-orchestrator/logs/*.jsonl | head -n 1)"
rg -n '"router_decision"|remind_me|final' "$LATEST"
```

Weiter:
- [04-config-reference.md](./04-config-reference.md)
- [05-migration-guide.md](./05-migration-guide.md)
- [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md)
