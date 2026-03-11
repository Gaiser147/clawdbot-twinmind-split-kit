# TwinMind Split Kit
![repo banner](https://raw.githubusercontent.com/Gaiser147/clawdbot-twinmind-split-kit/refs/heads/main/Drawing%2010%20(2).png)

TwinMind Split Kit adds the TwinMind wrapper backend to an existing Clawdbot-style setup and gives you four practical entry points:

1. understand the architecture
2. build a safe local replica plan
3. patch a live config with rollback artifacts
4. let a terminal AI drive the same flow through repo-owned scripts

## [Easy Setup for Terminal AI Tools](./prompts/terminal-ai-easy-setup.md)

> Start here if you want Codex, Claude Code, Gemini CLI, or another terminal agent to clone this repo and drive the migration for you.

**Fast path**

```bash
scripts/ai_easy_setup.sh preflight
scripts/ai_easy_setup.sh plan
scripts/ai_easy_setup.sh apply --yes
```

<details>
<summary><strong>Click to expand the safe AI-driven flow</strong></summary>

1. clone the repo and `cd` into it
2. run `scripts/ai_easy_setup.sh preflight`
3. run `scripts/ai_easy_setup.sh plan`
4. stop and review the summary
5. run `scripts/ai_easy_setup.sh apply --yes` only after explicit confirmation
6. let the wrapper run the smoke test automatically

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

Use this if you want one entrypoint for preflight, plan/apply orchestration, replica planning, and smoke testing.

```bash
/root/twinmind-split-kit/scripts/ai_easy_setup.sh preflight
/root/twinmind-split-kit/scripts/ai_easy_setup.sh plan
/root/twinmind-split-kit/scripts/ai_easy_setup.sh apply --yes
```

Optional flags:

- `--mode <name>` as an alias for the positional mode argument
- `--print-json` if you want only the final JSON summary
- `--target-root <path>` for a replica location
- `--query <text>` to override the smoke-test prompt

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
