# Operations Runbook

## Daily operator checks
1. Verify wrapper script path exists.
2. Verify required TwinMind env tokens are present.
3. Verify backend output mode remains `json`.
4. Verify no accidental config drift in `clawdbot.json`.
5. Verify selected executor profile is still the intended one.

## Profile-specific preflight

### Codex profile (`ORCH_EXECUTOR_PROVIDER=codex_cli`)
1. `codex` binary is available in `PATH` (or configured via `ORCH_EXECUTOR_CODEX_BIN`).
2. Codex auth is valid (no expired login profile).
3. `ORCH_EXECUTOR_MODEL` matches your intended Codex model.

### HTTP/OpenAI-compatible profile (z. B. Gemini-compatible endpoint)
1. `ORCH_EXECUTOR_PROVIDER` is `openai`/`openai_codex`/`codex` or your HTTP provider.
2. `ORCH_EXECUTOR_BASE_URL` is reachable and supports chat completions.
3. API key is set (`ORCH_EXECUTOR_API_KEY` and/or `OPENAI_API_KEY`).
4. `ORCH_EXECUTOR_MODEL` exists on your endpoint.

### Shared runtime prerequisites
1. Python dependency `requests` is installed for `vendor/twinmind_orchestrator.py`.
2. `TWINMIND_REFRESH_TOKEN` and `TWINMIND_FIREBASE_API_KEY` are set.

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

## How to verify which executor path is active
1. Inspect effective backend args/env (`ORCH_EXECUTOR_PROVIDER`, `ORCH_EXECUTOR_MODEL`).
2. Check wrapper logs for executor events:
   - Codex profile: executor event contains `provider=codex_cli`
   - HTTP profile: executor event contains target `url` under `executor_request`
3. Confirm route events (`router_decision`, `split_executor_bridge`) align with expected mode.

<details>
<summary><strong>Warum kann ein Request trotz strict_split nicht den Executor erreichen?</strong></summary>

Typische Ursachen:
- Request landet in Fastpath und umgeht Split-Loop.
- Runtime bleibt in `conversation` ohne Tool-Intent.
- `--force-split-default` wurde nicht genutzt und es fehlt expliziter Tool-Intent.

</details>

## Manual post-apply steps
1. Fill real secrets in runtime `.env` (not in repo).
2. Validate wrapper invocation manually.
3. Confirm logs and session continuity behavior.

Weiter:
- [07-troubleshooting.md](./07-troubleshooting.md)
- [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md)
- [11-token-sourcing-safe.md](./11-token-sourcing-safe.md)
