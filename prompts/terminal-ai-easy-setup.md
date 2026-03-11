# Terminal AI Easy Setup Prompt

Use this prompt in Codex, Claude Code, Gemini CLI, or a similar terminal-based coding agent.

## Copy/paste prompt

```text
Clone and set up the TwinMind Split Kit for this machine, but do it safely.

Repository:
https://github.com/Gaiser147/clawdbot-twinmind-split-kit.git

Required behavior:
1. Clone the repo locally if it is not already present.
2. `cd` into the repo root before running any script.
3. Read the README briefly and use the repo’s automation scripts instead of inventing your own migration flow.
4. Run:
   - scripts/ai_easy_setup.sh preflight --print-json
   - scripts/ai_easy_setup.sh plan --print-json
5. Summarize:
   - detected target type and config path
   - whether required TwinMind secrets are present
   - whether the config shape is compatible
   - what the migration would change
6. Do not run apply yet. Stop and wait for explicit confirmation after showing the plan result.
7. If I confirm, run:
   - scripts/ai_easy_setup.sh apply --yes --print-json
8. After apply, report whether the smoke test passed and include the log/report path used for verification.

Hard safety rules:
- Never run apply before plan.
- If TwinMind secrets are missing, stop and say exactly which ones are missing.
- If `codex` or `timeout` is missing, stop and say so; this repo needs them for the default migration + smoke-test flow.
- If the detected config is not Clawdbot-compatible, stop instead of patching random JSON.
- Do not claim that editing only `.env` changes the executor provider/model after migration. Check backend args first.
- Do not claim full Telegram or non-WhatsApp support. Treat non-WhatsApp as best effort for plain text only.
- Treat Moltbook/Moltbot as limited support only when the config shape matches the Clawdbot-style schema.
- Keep reports outside the repo worktree when the scripts support that.

Optional safe trial:
- If I ask for a replica first, run `scripts/ai_easy_setup.sh replica --print-json`.
- Only run `scripts/ai_easy_setup.sh replica --yes --print-json` if I explicitly want the local replica tree written.
```

## Expected flow

1. `preflight`
2. `plan`
3. human confirmation
4. `apply`
5. `smoke-test`

## Fast path

```bash
scripts/ai_easy_setup.sh preflight
scripts/ai_easy_setup.sh plan
scripts/ai_easy_setup.sh apply --yes
```

## What the AI should not improvise

- custom migration scripts
- hand-edited config patches before the repo scripts run
- provider/model switch assumptions based only on `.env`
- unsupported channel guarantees
