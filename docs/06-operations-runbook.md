# Operations Runbook

This page covers safe replica work and ongoing operator checks. It is not the live patch procedure; for that use [05-migration-guide.md](./05-migration-guide.md).

## Safe replica workflow

Use the replica when you want to inspect generated files, backend args, or env templates without touching the live runtime.

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

The replica creates a separate directory tree with placeholder config and example env files. It does not migrate your live setup. The generated config points at the copied runtime inside the replica tree, not back at the kit checkout.

For terminal AI tools, the same flow can be wrapped with:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh \
  --mode replica \
  --target-root /tmp/twinmind-split-replica \
  --print-json
```

That wrapper writes the replica into a temp-like target by default and returns a machine-readable report.

## What the replica contains

- `clawd/skills/twinmind-orchestrator/scripts/*`
- `.clawdbot/clawdbot.json`
- `.clawdbot/.env.example`
- backend args pinned to `codex_cli` + `gpt-5.3-codex`

## Routine operator checks

1. the backend script path still exists under `clawd/skills/twinmind-orchestrator/scripts`
2. required TwinMind tokens are present
3. backend output remains `json`
4. no accidental drift happened in `clawdbot.json`
5. the effective executor profile is still the intended one

## Profile-specific preflight

### Codex profile

Check:

1. `codex` is in `PATH` or `ORCH_EXECUTOR_CODEX_BIN` points to it
2. Codex auth is still valid
3. the model in the backend args matches the intended Codex model

### HTTP/OpenAI-compatible profile

Check:

1. backend args no longer pin `--executor-provider codex_cli`
2. `ORCH_EXECUTOR_BASE_URL` points at a working OpenAI-compatible endpoint
3. API auth is present
4. the requested model exists on that endpoint

## Verify which executor path is active

Inspect the latest wrapper log:

```bash
CFG="${CFG:-$HOME/.clawdbot/clawdbot.json}"
RUNTIME_ROOT="$(dirname "$CFG")"
LATEST="$(ls -1t "$RUNTIME_ROOT"/twinmind-orchestrator/logs/*.jsonl | head -n 1)"
rg -n 'executor_request|executor_response|router_decision' "$LATEST"
```

Interpretation:

- Codex path: `executor_request` shows `provider=codex_cli`
- HTTP path: `executor_request` shows the HTTP provider and a request URL
- split path: `router_decision` shows `split_executor_bridge`
- conversation path: `router_decision` shows `twinmind_conversation`

## Changing profiles safely

When switching away from the migration default, change the backend args first and env second.

1. edit `agents.defaults.cliBackends.twinmind-cli.args`
2. replace `--executor-provider` and `--executor-model`
3. add/set `ORCH_EXECUTOR_BASE_URL` and API key env vars if the new profile is HTTP-based
4. run the smoke test from [05-migration-guide.md](./05-migration-guide.md)

## Channel limitations to remember

- WhatsApp is the only channel with explicit inbound metadata parsing and reply-target handling in the wrapper.
- Non-WhatsApp gateways may still work for plain text, but route-specific behavior should be treated as unverified.
- Telegram is not a documented transport target in this repo.

## Shared runtime prerequisites

- Python `requests` is installed for the copied `twinmind_orchestrator.py` runtime under the target app tree
- `TWINMIND_REFRESH_TOKEN` is set
- `TWINMIND_FIREBASE_API_KEY` is set

## Deep references

- [07-troubleshooting.md](./07-troubleshooting.md)
- [09-script-reference.md](./09-script-reference.md)
- [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md)
- [11-token-sourcing-safe.md](./11-token-sourcing-safe.md)
