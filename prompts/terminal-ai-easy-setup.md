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
4. First determine whether this machine already has a TwinMind-managed install:
   - scripts/ai_easy_setup.sh inspect --print-json
5. If inspect says this is already a TwinMind-managed install:
   - run scripts/ai_easy_setup.sh update-plan --print-json
   - summarize the detected install, runtime root, and whether an update is available
   - do not run update-apply yet; wait for explicit confirmation
   - if I confirm, run scripts/ai_easy_setup.sh update-apply --yes --print-json
6. If inspect says this is not yet a TwinMind-managed install:
   - run scripts/ai_easy_setup.sh preflight --print-json
   - run scripts/ai_easy_setup.sh plan --print-json
   - summarize detected target type, config path, required TwinMind secrets, config-shape compatibility, and what migration would change
   - do not run apply yet; wait for explicit confirmation
   - if I confirm, run scripts/ai_easy_setup.sh apply --yes --print-json
7. After update-apply or apply, report whether the smoke test passed and include the log/report path used for verification.

Hard safety rules:
- Never run apply before plan.
- Never re-run migration on an install that inspect already identifies as TwinMind-managed. Use inspect/update-plan/update-apply/update-rollback instead.
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

1. `inspect`
2. either `update-plan` or `preflight` + `plan`
3. human confirmation
4. either `update-apply` or `apply`
5. `smoke-test`

## Fast path

```bash
scripts/ai_easy_setup.sh inspect
# if already managed:
scripts/ai_easy_setup.sh update-plan
scripts/ai_easy_setup.sh update-apply --yes
# otherwise:
scripts/ai_easy_setup.sh preflight
scripts/ai_easy_setup.sh plan
scripts/ai_easy_setup.sh apply --yes
```

## What the AI should not improvise

- custom migration scripts
- custom update scripts
- hand-edited config patches before the repo scripts run
- re-migrating an already TwinMind-managed install
- provider/model switch assumptions based only on `.env`
- unsupported channel guarantees
