# Configuration Reference

## Required env
- `TWINMIND_REFRESH_TOKEN`
- `TWINMIND_FIREBASE_API_KEY`

## Common optional env
- `TWINMIND_API_BASE`
- `TWINMIND_API_ENDPOINT`
- `TWINMIND_VERCEL_BYPASS`
- `TWINMIND_USER_AGENT`

## Split/executor env
- `ORCH_ROUTING_MODE`
- `ORCH_EXECUTOR_PROVIDER`
- `ORCH_EXECUTOR_MODEL`
- `ORCH_EXECUTOR_BASE_URL`
- `ORCH_EXECUTOR_API_KEY`
- `ORCH_EXECUTOR_MAX_STEPS`
- `ORCH_EXECUTOR_MAX_TOOL_CALLS`
- `ORCH_EXECUTOR_USE_TWINMIND_PLANNER`

## Clawdbot config paths patched by converter
- `agents.defaults.model.primary`
- `agents.defaults.models.twinmind-cli/default`
- `agents.defaults.cliBackends.twinmind-cli`

## Backend defaults written by converter
- command: `python3`
- script: `<kit-root>/vendor/twinmind_orchestrator.py`
- output: `json`
- sessionArg: `--session-id`
- serialize: `true`

See `analysis/config_matrix.json` and `templates/clawdbot.patch.template.json`.
