# Model Profiles and Credential Mapping

Back: [README](../README.md) | Next: [11-token-sourcing-safe.md](./11-token-sourcing-safe.md)

This page explains how executor selection really works in the wrapper and how to switch profiles without fighting backend arg precedence.

## Short version

- script defaults are `codex_cli` + `gpt-5.3-codex`
- migrated configs pin provider/model in backend CLI args
- backend precedence is `CLI args > env > built-in defaults`
- therefore provider/model switching after migration requires editing backend args, not only `.env`

## The precedence rule that matters

`vendor/twinmind_orchestrator.py` defines executor settings from CLI arguments whose defaults come from env vars. In practice that means:

1. if the backend config passes `--executor-provider` or `--executor-model`, those values win
2. env vars are used only when the backend config does not pass those args
3. built-in defaults apply only when neither CLI args nor env vars provide a value

The migration and replica scripts both write explicit args for:

- `--executor-provider codex_cli`
- `--executor-model gpt-5.3-codex`

So this will not switch a migrated setup by itself:

```env
ORCH_EXECUTOR_PROVIDER=openai
ORCH_EXECUTOR_MODEL=<other-model>
```

You must change the backend args first.

## Profile 1: Codex CLI default

### Effective backend shape

```text
--executor-provider codex_cli
--executor-model gpt-5.3-codex
```

### Requirements

- `codex` is installed and reachable
- Codex auth is valid on the same machine/user as the wrapper runtime
- the chosen Codex model is available to that account

### Auth behavior

For `codex_cli`, the wrapper uses local `codex exec`. HTTP API keys are not the main auth path for this profile.

## Profile 2: HTTP / OpenAI-compatible executor

### When this profile works

Use this only after you have replaced the pinned backend args.

Example target state:

```text
--executor-provider openai
--executor-model <your-model>
```

Matching env:

```env
ORCH_EXECUTOR_BASE_URL=<openai-compatible-base-url>
ORCH_EXECUTOR_API_KEY=<api-key>
```

The scripts do not pin `--executor-base-url`, so leaving that in `.env` is fine.

## Safe switching procedure

1. edit `agents.defaults.cliBackends.twinmind-cli.args` in the live config
2. replace `--executor-provider` and `--executor-model`
3. set `ORCH_EXECUTOR_BASE_URL` and auth env vars if the new provider is HTTP-based
4. rerun the smoke test from [05-migration-guide.md](./05-migration-guide.md)
5. confirm `executor_request` in the log shows the intended provider/model

## HTTP auth resolution inside the wrapper

Once the provider is an HTTP-style executor such as `openai`, `openai_codex`, or `codex`, auth resolution is:

1. `cfg.executor_api_key` if present
2. `OPENAI_API_KEY`
3. `ORCH_EXECUTOR_API_KEY`
4. Codex OAuth access token from the local auth profile

Important nuance: if the backend config ever passes `--executor-api-key`, that value will also beat env vars for the same reason as provider/model.

## Variable mapping

| Variable | Meaning |
|---|---|
| `ORCH_ROUTING_MODE` | `legacy` or `strict_split` when not pinned by backend args |
| `ORCH_EXECUTOR_PROVIDER` | executor type when not pinned by backend args |
| `ORCH_EXECUTOR_MODEL` | executor model when not pinned by backend args |
| `ORCH_EXECUTOR_BASE_URL` | HTTP base URL for `/chat/completions` |
| `ORCH_EXECUTOR_API_KEY` | generic executor API key |
| `OPENAI_API_KEY` | fallback key for OpenAI-like HTTP providers |

## Common mistakes

- changing only `.env` after a migrated config already pins provider/model
- assuming replica changes affect the live runtime
- assuming Telegram or another gateway transport changes executor selection behavior

## Related docs

- [04-config-reference.md](./04-config-reference.md)
- [05-migration-guide.md](./05-migration-guide.md)
- [06-operations-runbook.md](./06-operations-runbook.md)
- [07-troubleshooting.md](./07-troubleshooting.md)
