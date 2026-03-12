# TwinMind Split Kit
![repo banner](https://raw.githubusercontent.com/Gaiser147/clawdbot-twinmind-split-kit/refs/heads/main/Drawing%2010%20(2).png)

TwinMind Split Kit adds the TwinMind wrapper backend to an existing Clawdbot-style setup and gives you four practical entry points:

1. understand the architecture
2. build a safe local replica plan
3. patch a live config with rollback artifacts
4. let a terminal AI drive the same flow through repo-owned scripts

If you already migrated an install earlier, the repo also supports a separate **inspect -> update-plan -> update-apply -> update-rollback** flow for later TwinMind runtime updates.

## [Easy Setup for Terminal AI Tools](./prompts/terminal-ai-easy-setup.md)

<table>
<tr>
<td valign="top">

> Start here if you want Codex, Claude Code, Gemini CLI, or another terminal agent to clone this repo and drive the migration for you.

</td>
<td align="right" valign="top" width="120">
  <img src="https://raw.githubusercontent.com/Gaiser147/clawdbot-twinmind-split-kit/refs/heads/main/logoTermAI.png" alt="Terminal AI easy setup icon" width="96">
</td>
</tr>
</table>

**Copy/paste this prompt into your terminal AI**

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

<details>
<summary><strong>Click to expand the safe AI-driven flow and fast path</strong></summary>

**Fast path**

```bash
scripts/ai_easy_setup.sh preflight
scripts/ai_easy_setup.sh plan
scripts/ai_easy_setup.sh apply --yes
```

Safe flow:

1. clone the repo and `cd` into it
2. run `scripts/ai_easy_setup.sh inspect`
3. if the install is already TwinMind-managed, continue with `update-plan`
4. if the install is not yet TwinMind-managed, continue with `preflight` then `plan`
5. stop and review the summary
6. run `update-apply --yes` or `apply --yes` only after explicit confirmation
7. let the wrapper run the smoke test automatically
8. use the linked prompt page if you want the same flow in a cleaner standalone copy block

</details>

<details>
<summary><strong>Click to expand limits and prerequisites</strong></summary>

- Linux + local shell only
- the scripts do not fetch secrets for you
- missing TwinMind secrets, missing `codex`, or missing `timeout` should stop the flow early
- OpenClaw / Moltbook / Moltbot are only supported when they still use the same Clawdbot-style config shape
- Telegram and other non-WhatsApp channels remain best effort for plain text only

</details>

## Before you choose a path

This repo does not change your live setup by itself, but these commands do write files:

- `scripts/convert_clawdbot_to_split.sh --mode apply`
- `scripts/bootstrap_clawdbot_replica.sh --mode apply`
- `scripts/ai_easy_setup.sh apply --yes`
- `scripts/ai_easy_setup.sh replica --yes`

Everything else in the documented flow is non-mutating.

## Support levels and limits

| Target | Support level in this repo | What that means |
|---|---|---|
| Clawdbot config/runtime | supported | primary target for migration, replica, runbook, rollback |
| OpenClaw config paths | limited support | converter can auto-detect common `openclaw` config filenames and patch the same Clawdbot-style JSON shape |
| Moltbook/Moltbot config paths | limited support | converter can auto-detect common `moltbook`/`moltbot` config filenames and patch the same Clawdbot-style JSON shape |
| WhatsApp gateway usage | supported | wrapper has explicit inbound parsing and reply-target handling for WhatsApp metadata |
| Telegram or other non-WhatsApp gateways | best effort for plain text only | no Telegram-specific transport handling, auto-targeting, or docs-tested migration path |

## Quickstart

### Already migrated? Update here

Use this path if the target config was already migrated to the TwinMind wrapper and you want to refresh the copied runtime later.

Inspect first:

```bash
/root/twinmind-split-kit/scripts/inspect_twinmind_install.sh --print-json
```

Or through the AI-friendly wrapper:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh inspect --print-json
```

Plan the update:

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh --mode update-plan
```

Apply only after reviewing the plan:

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode update-apply \
  --yes
```

Rollback a prior update with its update id:

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode update-rollback \
  --update-id <update-id> \
  --yes
```

Default behavior is runtime-only. Config and env syncing stay opt-in during updates.

### Path 1: Understand the system first

Read these in order:

1. [docs/00-start-here.md](./docs/00-start-here.md)
2. [docs/03-split-routing.md](./docs/03-split-routing.md)
3. [docs/10-model-profiles-and-credentials.md](./docs/10-model-profiles-and-credentials.md)

Use this path if you want the mental model before touching config.

### Path 2: Safe trial with a local replica

Use this if you want to inspect the generated backend shape without patching the live runtime.

Plan the replica:

```bash
/root/twinmind-split-kit/scripts/bootstrap_clawdbot_replica.sh \
  --mode plan \
  --target-root /root/.clawdbot-replica
```

Create the replica:

```bash
/root/twinmind-split-kit/scripts/bootstrap_clawdbot_replica.sh \
  --mode apply \
  --target-root /root/.clawdbot-replica \
  --yes
```

Or use the wrapper:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh replica
/root/twinmind-split-kit/scripts/ai_easy_setup.sh replica --yes
```

Then continue with:

1. [docs/06-operations-runbook.md](./docs/06-operations-runbook.md)
2. [docs/09-script-reference.md](./docs/09-script-reference.md)

### Path 3: Live migration

Use this only when you are ready to patch the real config.

If the install is already TwinMind-managed, stop and use the update path above instead of re-running migration.

Preflight:

1. `python3` exists
2. `sha256sum` exists
3. `timeout` exists
4. Python `requests` is installed for the wrapper runtime
5. your TwinMind runtime secrets are available locally
6. if you keep the default Codex executor, `codex` CLI is installed and logged in

Always start with a dry plan:

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh --mode plan
```

Apply only after the plan looks correct:

```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh \
  --mode apply \
  --yes
```

Then run the post-migration smoke test in [docs/05-migration-guide.md](./docs/05-migration-guide.md).

### Path 4: Wrapper for humans and terminal AI tools

Use this if you want one entrypoint for inspect, preflight, plan/apply orchestration, update orchestration, replica planning, and smoke testing.

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh inspect
/root/twinmind-split-kit/scripts/ai_easy_setup.sh preflight
/root/twinmind-split-kit/scripts/ai_easy_setup.sh plan
/root/twinmind-split-kit/scripts/ai_easy_setup.sh apply --yes
```

Existing TwinMind-managed installs should use:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh inspect
/root/twinmind-split-kit/scripts/ai_easy_setup.sh update-plan
/root/twinmind-split-kit/scripts/ai_easy_setup.sh update-apply --yes
```

Optional flags:

- `--mode <name>` as an alias for the positional mode argument
- `--print-json` if you want only the final JSON summary
- `--target-root <path>` for a replica location
- `--query <text>` to override the smoke-test prompt

### Path 5: Update an already migrated install

Use this only when the target is already TwinMind-managed and you want to sync newer vendored runtime files into that install.

Inspect first:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh inspect
```

Plan the update:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh update-plan
```

Apply only after reviewing the plan:

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh update-apply --yes
```

Defaults:

- runtime-only update
- `clawdbot.json` is left untouched unless you opt into `--sync-config 1`
- `.env` template keys are left untouched unless you opt into `--sync-env-template 1`
- `update-apply` runs the smoke test afterwards

## Important provider/model rule

The migration script writes explicit backend args into `clawdbot.json` such as:

- `--executor-provider codex_cli`
- `--executor-model gpt-5.3-codex`

The backend parser uses explicit CLI args first, then env, then built-in defaults. That means changing only `ORCH_EXECUTOR_PROVIDER` or `ORCH_EXECUTOR_MODEL` in `.env` will not switch a migrated setup away from Codex. Edit the backend args first, then set the matching env vars for URL/keys if needed.

Details: [docs/10-model-profiles-and-credentials.md](./docs/10-model-profiles-and-credentials.md)

## What the scripts actually change

`convert_clawdbot_to_split.sh` patches the default CLI backend to call:

- `python3 <target-app-root>/clawd/skills/twinmind-orchestrator/scripts/twinmind_orchestrator.py`
- backend `--mode conversation`
- `--routing-mode strict_split`
- executor defaults `codex_cli` + `gpt-5.3-codex`

It also writes migration artifacts:

- `reports/convert-<migration-id>.json`
- `backups/clawdbot.json.<migration-id>.bak`
- `manifests/migration-<migration-id>.json`

## Recommended reading map

| Goal | Read this |
|---|---|
| understand wrapper and split modes | [docs/00-start-here.md](./docs/00-start-here.md), [docs/02-wrapper-architecture.md](./docs/02-wrapper-architecture.md), [docs/03-split-routing.md](./docs/03-split-routing.md) |
| patch a live system | [docs/05-migration-guide.md](./docs/05-migration-guide.md), [docs/08-rollback.md](./docs/08-rollback.md) |
| run a safe replica or do daily ops | [docs/06-operations-runbook.md](./docs/06-operations-runbook.md) |
| debug failures | [docs/07-troubleshooting.md](./docs/07-troubleshooting.md) |
| inspect script behavior and limits | [docs/09-script-reference.md](./docs/09-script-reference.md) |
| switch executor profiles safely | [docs/10-model-profiles-and-credentials.md](./docs/10-model-profiles-and-credentials.md) |
| source TwinMind secrets safely | [docs/11-token-sourcing-safe.md](./docs/11-token-sourcing-safe.md) |

## Required runtime secrets

- `TWINMIND_REFRESH_TOKEN`
- `TWINMIND_FIREBASE_API_KEY`

How to obtain and store them safely: [docs/11-token-sourcing-safe.md](./docs/11-token-sourcing-safe.md)

## Safety rules

- run `plan` before `apply`
- keep secrets out of git
- keep runtime secrets in local `.env` files only
- do not treat the replica flow as proof that live migration already happened

## Repo structure

- [docs/](./docs/) onboarding, migration, operations, troubleshooting
- [prompts/](./prompts/) copy/paste prompts for terminal AI setup flows
- [scripts/](./scripts/) migration and bootstrap helpers
- [vendor/](./vendor/) wrapper runtime used by the patched backend
- [templates/](./templates/) patch/env templates
- [manifests/](./manifests/) migration schema and generated manifests
- [analysis/](./analysis/) implementation notes and review artifacts

## Provenance

- [vendor/PROVENANCE.md](./vendor/PROVENANCE.md)
