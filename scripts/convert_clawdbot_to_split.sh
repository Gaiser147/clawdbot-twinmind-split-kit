#!/usr/bin/env bash
set -euo pipefail

MODE="plan"
CONFIG_PATH="/root/.clawdbot/clawdbot.json"
ENV_PATH="/root/.clawdbot/.env"
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR=""
REPORT_JSON=""
MIGRATION_ID=""
PATCH_ENV=0
YES=0
FORCE_SPLIT_DEFAULT=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Modes:
  --mode plan|apply|rollback        Default: plan

Core options:
  --config <path>                   Default: /root/.clawdbot/clawdbot.json
  --env <path>                      Default: /root/.clawdbot/.env
  --kit-root <path>                 Default: script parent directory
  --backup-dir <path>               Default: <kit-root>/backups
  --report-json <path>              Default: <kit-root>/reports/convert-<ts>.json
  --migration-id <id>               Optional in plan/apply; required for rollback

Behavior flags:
  --patch-env                       Append non-secret defaults from templates/env.append.template
  --force-split-default             Set backend args to '--mode tool_bridge' (default is conversation)
  --yes                             Required for apply/rollback
  -h, --help

Notes:
  - plan: no changes to target config; writes report only
  - apply: writes config + backups + manifest
  - rollback: restores from manifest backup
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing command: $1"
}

iso_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ts_compact() {
  date -u +"%Y%m%dT%H%M%SZ"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
p = sys.argv[1]
k = sys.argv[2]
with open(p, 'r', encoding='utf-8') as f:
    d = json.load(f)
print(d.get(k, ""))
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --env)
      ENV_PATH="$2"
      shift 2
      ;;
    --kit-root)
      KIT_ROOT="$2"
      shift 2
      ;;
    --backup-dir)
      BACKUP_DIR="$2"
      shift 2
      ;;
    --report-json)
      REPORT_JSON="$2"
      shift 2
      ;;
    --migration-id)
      MIGRATION_ID="$2"
      shift 2
      ;;
    --patch-env)
      PATCH_ENV=1
      shift
      ;;
    --force-split-default)
      FORCE_SPLIT_DEFAULT=1
      shift
      ;;
    --yes)
      YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      ;;
  esac
done

case "$MODE" in
  plan|apply|rollback) ;;
  *) err "Invalid --mode: $MODE" ;;
esac

need_cmd python3
need_cmd sha256sum

[[ -n "$BACKUP_DIR" ]] || BACKUP_DIR="$KIT_ROOT/backups"
mkdir -p "$BACKUP_DIR" "$KIT_ROOT/manifests" "$KIT_ROOT/reports"

if [[ -z "$MIGRATION_ID" ]]; then
  MIGRATION_ID="mig-$(ts_compact)"
fi

if [[ -z "$REPORT_JSON" ]]; then
  REPORT_JSON="$KIT_ROOT/reports/convert-${MIGRATION_ID}.json"
fi

if [[ "$MODE" == "rollback" ]]; then
  [[ "$YES" -eq 1 ]] || err "Rollback requires --yes"
  MANIFEST_PATH="$KIT_ROOT/manifests/migration-${MIGRATION_ID}.json"
  [[ -f "$MANIFEST_PATH" ]] || err "Manifest not found: $MANIFEST_PATH"

  BACKUP_CONFIG_PATH="$(json_get "$MANIFEST_PATH" backup_config_path)"
  BACKUP_ENV_PATH="$(json_get "$MANIFEST_PATH" backup_env_path)"
  TARGET_CONFIG_PATH="$(json_get "$MANIFEST_PATH" target_config_path)"
  TARGET_ENV_PATH="$(json_get "$MANIFEST_PATH" target_env_path)"

  [[ -n "$TARGET_CONFIG_PATH" ]] || err "Manifest missing target_config_path"
  [[ -f "$BACKUP_CONFIG_PATH" ]] || err "Config backup not found: $BACKUP_CONFIG_PATH"

  ROLLBACK_STAMP="$(ts_compact)"
  PRE_ROLLBACK_COPY="$BACKUP_DIR/clawdbot.json.pre-rollback.${MIGRATION_ID}.${ROLLBACK_STAMP}.bak"
  cp "$TARGET_CONFIG_PATH" "$PRE_ROLLBACK_COPY"
  cp "$BACKUP_CONFIG_PATH" "$TARGET_CONFIG_PATH"

  if [[ -n "$BACKUP_ENV_PATH" && -f "$BACKUP_ENV_PATH" && -n "$TARGET_ENV_PATH" ]]; then
    cp "$BACKUP_ENV_PATH" "$TARGET_ENV_PATH"
  fi

  python3 - "$REPORT_JSON" "$MIGRATION_ID" "$MANIFEST_PATH" "$PRE_ROLLBACK_COPY" "$TARGET_CONFIG_PATH" <<'PY'
import json, sys, datetime
report_path, mid, manifest_path, pre_copy, target = sys.argv[1:6]
obj = {
    "timestamp_utc": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mode": "rollback",
    "migration_id": mid,
    "manifest": manifest_path,
    "pre_rollback_backup": pre_copy,
    "restored_target_config": target,
    "status": "rolled_back"
}
with open(report_path, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY

  echo "Rollback completed."
  echo "Report: $REPORT_JSON"
  exit 0
fi

[[ -f "$CONFIG_PATH" ]] || err "Config not found: $CONFIG_PATH"
python3 - "$CONFIG_PATH" <<'PY' >/dev/null
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    json.load(f)
PY

TMP_AFTER="$(mktemp)"
TMP_PLAN="$(mktemp)"
trap 'rm -f "$TMP_AFTER" "$TMP_PLAN"' EXIT

python3 - "$CONFIG_PATH" "$TMP_AFTER" "$TMP_PLAN" "$KIT_ROOT" "$FORCE_SPLIT_DEFAULT" <<'PY'
import copy
import json
import os
import sys
from datetime import datetime

config_path, after_path, plan_path, kit_root, force_split = sys.argv[1:6]
force_split = force_split == "1"

with open(config_path, "r", encoding="utf-8") as f:
    data = json.load(f)

before = copy.deepcopy(data)
patched_fields = []


def get_path(d, path):
    cur = d
    for p in path:
        if isinstance(cur, dict) and p in cur:
            cur = cur[p]
        else:
            return None
    return cur


def set_path(d, path, value):
    cur = d
    for p in path[:-1]:
        nxt = cur.get(p)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[p] = nxt
        cur = nxt
    cur[path[-1]] = value


def patch(path, value):
    old = get_path(data, path)
    if old != value:
        set_path(data, path, value)
        patched_fields.append({
            "path": ".".join(path),
            "old": old,
            "new": value,
        })

backend_mode = "tool_bridge" if force_split else "conversation"
backend_args = [
    os.path.join(kit_root, "vendor", "twinmind_orchestrator.py"),
    "--mode", backend_mode,
    "--routing-mode", "strict_split",
    "--search-web", "1",
    "--search-memories", "1",
    "--allow-shell", "0",
    "--allow-writes", "0",
    "--output", "json",
    "--max-steps", "4",
    "--max-tool-calls", "4",
    "--repair-attempts", "1",
    "--llm-timeout-sec", "120",
    "--tool-timeout-sec", "60",
    "--executor-provider", "codex_cli",
    "--executor-model", "gpt-5.3-codex",
    "--executor-max-steps", "4",
    "--executor-max-tool-calls", "6",
    "--executor-use-twinmind-planner", "1",
]

patch(["agents", "defaults", "model", "primary"], "twinmind-cli/default")

models_path = ["agents", "defaults", "models"]
models_obj = get_path(data, models_path)
if not isinstance(models_obj, dict):
    models_obj = {}
    set_path(data, models_path, models_obj)

current_tm_model = models_obj.get("twinmind-cli/default")
new_tm_model = {"alias": "tm"}
if current_tm_model != new_tm_model:
    models_obj["twinmind-cli/default"] = new_tm_model
    patched_fields.append({
        "path": "agents.defaults.models.twinmind-cli/default",
        "old": current_tm_model,
        "new": new_tm_model,
    })

backend_obj = {
    "command": "python3",
    "args": backend_args,
    "output": "json",
    "input": "arg",
    "sessionArg": "--session-id",
    "sessionMode": "always",
    "serialize": True,
}
patch(["agents", "defaults", "cliBackends", "twinmind-cli"], backend_obj)

if get_path(data, ["models", "mode"]) is None:
    patch(["models", "mode"], "merge")

plan = {
    "timestamp_utc": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mode": "plan_or_apply",
    "target_config_path": config_path,
    "kit_root": kit_root,
    "force_split_default": force_split,
    "changed": bool(patched_fields),
    "patched_fields": patched_fields,
}

with open(after_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

with open(plan_path, "w", encoding="utf-8") as f:
    json.dump(plan, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

cp "$TMP_PLAN" "$REPORT_JSON"

if [[ "$MODE" == "plan" ]]; then
  echo "Plan completed."
  echo "Report: $REPORT_JSON"
  exit 0
fi

[[ "$YES" -eq 1 ]] || err "Apply requires --yes"

BACKUP_CONFIG_PATH="$BACKUP_DIR/clawdbot.json.${MIGRATION_ID}.bak"
cp "$CONFIG_PATH" "$BACKUP_CONFIG_PATH"

BACKUP_ENV_PATH=""
if [[ "$PATCH_ENV" -eq 1 ]]; then
  if [[ -f "$ENV_PATH" ]]; then
    BACKUP_ENV_PATH="$BACKUP_DIR/env.${MIGRATION_ID}.bak"
    cp "$ENV_PATH" "$BACKUP_ENV_PATH"
  fi
fi

cp "$TMP_AFTER" "$CONFIG_PATH"

ENV_PATCHED_KEYS=()
if [[ "$PATCH_ENV" -eq 1 ]]; then
  TEMPLATE_PATH="$KIT_ROOT/templates/env.append.template"
  [[ -f "$TEMPLATE_PATH" ]] || err "Missing template: $TEMPLATE_PATH"

  if [[ ! -f "$ENV_PATH" ]]; then
    touch "$ENV_PATH"
    chmod 600 "$ENV_PATH" || true
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    [[ -z "$key" ]] && continue
    if ! grep -qE "^${key}=" "$ENV_PATH"; then
      echo "$line" >> "$ENV_PATH"
      ENV_PATCHED_KEYS+=("$key")
    fi
  done < "$TEMPLATE_PATH"
fi

BEFORE_SHA="$(sha256_file "$BACKUP_CONFIG_PATH")"
AFTER_SHA="$(sha256_file "$CONFIG_PATH")"
MANIFEST_PATH="$KIT_ROOT/manifests/migration-${MIGRATION_ID}.json"

python3 - "$MANIFEST_PATH" "$MIGRATION_ID" "$CONFIG_PATH" "$ENV_PATH" "$BACKUP_CONFIG_PATH" "$BACKUP_ENV_PATH" "$BEFORE_SHA" "$AFTER_SHA" "$REPORT_JSON" "$PATCH_ENV" "$KIT_ROOT" "$FORCE_SPLIT_DEFAULT" <<'PY'
import json
import os
import sys
from datetime import datetime

(
    manifest_path,
    migration_id,
    target_config_path,
    target_env_path,
    backup_config_path,
    backup_env_path,
    before_sha,
    after_sha,
    report_json,
    patch_env,
    kit_root,
    force_split,
) = sys.argv[1:13]

with open(report_json, "r", encoding="utf-8") as f:
    report = json.load(f)

manifest = {
    "migration_id": migration_id,
    "created_at_utc": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mode": "apply",
    "target_config_path": target_config_path,
    "target_env_path": target_env_path,
    "backup_config_path": backup_config_path,
    "backup_env_path": backup_env_path,
    "before_checksum": before_sha,
    "after_checksum": after_sha,
    "patched_fields": report.get("patched_fields", []),
    "patch_env": bool(int(patch_env)),
    "force_split_default": bool(int(force_split)),
    "kit_root": kit_root,
    "status": "applied",
}

with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

echo "Apply completed."
echo "Report: $REPORT_JSON"
echo "Manifest: $MANIFEST_PATH"

if [[ "${#ENV_PATCHED_KEYS[@]}" -gt 0 ]]; then
  echo "Patched env keys: ${ENV_PATCHED_KEYS[*]}"
fi
