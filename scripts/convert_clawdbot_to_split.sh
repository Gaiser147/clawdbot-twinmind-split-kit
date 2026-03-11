#!/usr/bin/env bash
set -euo pipefail

MODE="plan"
CONFIG_PATH=""
ENV_PATH=""
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR=""
REPORT_JSON=""
MIGRATION_ID=""
PATCH_ENV=0
YES=0
FORCE_SPLIT_DEFAULT=0
CONFIG_PATH_EXPLICIT=0
ENV_PATH_EXPLICIT=0
TARGET_APP_ROOT=""
TARGET_RUNTIME_DIR=""
TARGET_RUNTIME_SCRIPT=""
RUNTIME_VENDOR_FILES=(
  "twinmind_orchestrator.py"
  "twinmind_memory_sync.py"
  "twinmind_memory_query.py"
)

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Modes:
  --mode plan|apply|rollback        Default: plan

Core options:
  --config <path>                   Optional; auto-detects clawdbot/openclaw/moltbook/moltbot config when omitted
  --env <path>                      Optional; defaults to sibling .env next to detected config
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
  - apply: validates config shape, copies runtime into target app tree, writes config + backups + manifest
  - rollback: restores from manifest backup after checksum drift checks
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing command: $1"
}

ts_compact() {
  date -u +"%Y%m%dT%H%M%SZ"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

json_get() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, key = sys.argv[1:3]
with open(path, 'r', encoding='utf-8') as handle:
    data = json.load(handle)
value = data.get(key, "")
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

resolve_config_and_env() {
  local home_root="${HOME:-/root}"
  local -a config_candidates=(
    "$home_root/.clawdbot/clawdbot.json"
    "$home_root/.openclaw/clawdbot.json"
    "$home_root/.openclaw/openclaw.json"
    "$home_root/.moltbook/moltbook.json"
    "$home_root/.moltbook/clawdbot.json"
    "$home_root/.moltbook/openclaw.json"
    "$home_root/.moltbot/moltbot.json"
    "$home_root/.moltbot/clawdbot.json"
    "$home_root/.moltbot/openclaw.json"
    "$home_root/.config/clawdbot/clawdbot.json"
    "$home_root/.config/openclaw/clawdbot.json"
    "$home_root/.config/openclaw/openclaw.json"
    "$home_root/.config/moltbook/moltbook.json"
    "$home_root/.config/moltbook/clawdbot.json"
    "$home_root/.config/moltbook/openclaw.json"
    "$home_root/.config/moltbot/moltbot.json"
    "$home_root/.config/moltbot/clawdbot.json"
    "$home_root/.config/moltbot/openclaw.json"
  )
  local detected_config=""
  local detected_env=""

  if [[ "$CONFIG_PATH_EXPLICIT" -eq 1 ]]; then
    detected_config="$CONFIG_PATH"
  else
    for candidate in "${config_candidates[@]}"; do
      if [[ -f "$candidate" ]]; then
        detected_config="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$detected_config" ]]; then
    err "Could not auto-detect config. Pass --config explicitly."
  fi

  if [[ "$ENV_PATH_EXPLICIT" -eq 1 ]]; then
    detected_env="$ENV_PATH"
  else
    detected_env="$(dirname "$detected_config")/.env"
  fi

  CONFIG_PATH="$detected_config"
  ENV_PATH="$detected_env"
}

resolve_target_layout() {
  local config_dir base
  config_dir="$(dirname "$CONFIG_PATH")"
  base="$(basename "$config_dir")"

  case "$base" in
    .clawdbot|.openclaw|.moltbook|.moltbot)
      TARGET_APP_ROOT="$(dirname "$config_dir")"
      ;;
    *)
      TARGET_APP_ROOT="$config_dir"
      ;;
  esac

  TARGET_RUNTIME_DIR="$TARGET_APP_ROOT/clawd/skills/twinmind-orchestrator/scripts"
  TARGET_RUNTIME_SCRIPT="$TARGET_RUNTIME_DIR/twinmind_orchestrator.py"
}

verify_runtime_sources() {
  local vendor_file
  for vendor_file in "${RUNTIME_VENDOR_FILES[@]}"; do
    [[ -f "$KIT_ROOT/vendor/$vendor_file" ]] || err "Missing vendor file: $KIT_ROOT/vendor/$vendor_file"
  done
}

copy_runtime_into_target() {
  local vendor_file
  mkdir -p "$TARGET_RUNTIME_DIR"
  for vendor_file in "${RUNTIME_VENDOR_FILES[@]}"; do
    cp "$KIT_ROOT/vendor/$vendor_file" "$TARGET_RUNTIME_DIR/$vendor_file"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --config)
      CONFIG_PATH="$2"
      CONFIG_PATH_EXPLICIT=1
      shift 2
      ;;
    --env)
      ENV_PATH="$2"
      ENV_PATH_EXPLICIT=1
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
if [[ "$MODE" != "rollback" ]]; then
  resolve_config_and_env
  resolve_target_layout
fi

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
  EXPECTED_CONFIG_SHA="$(json_get "$MANIFEST_PATH" after_checksum)"
  EXPECTED_ENV_SHA="$(json_get "$MANIFEST_PATH" env_after_checksum)"
  ENV_CREATED="$(json_get "$MANIFEST_PATH" env_created)"

  [[ -n "$TARGET_CONFIG_PATH" ]] || err "Manifest missing target_config_path"
  [[ -f "$BACKUP_CONFIG_PATH" ]] || err "Config backup not found: $BACKUP_CONFIG_PATH"
  [[ -f "$TARGET_CONFIG_PATH" ]] || err "Config drift detected: target config missing at $TARGET_CONFIG_PATH"

  if [[ -n "$EXPECTED_CONFIG_SHA" ]]; then
    CURRENT_CONFIG_SHA="$(sha256_file "$TARGET_CONFIG_PATH")"
    [[ "$CURRENT_CONFIG_SHA" == "$EXPECTED_CONFIG_SHA" ]] || err "Config drift detected at $TARGET_CONFIG_PATH; refusing rollback."
  fi

  if [[ -n "$TARGET_ENV_PATH" && -f "$TARGET_ENV_PATH" && -n "$EXPECTED_ENV_SHA" ]]; then
    CURRENT_ENV_SHA="$(sha256_file "$TARGET_ENV_PATH")"
    [[ "$CURRENT_ENV_SHA" == "$EXPECTED_ENV_SHA" ]] || err "Env drift detected at $TARGET_ENV_PATH; refusing rollback."
  fi

  if [[ "$ENV_CREATED" == "true" && -n "$TARGET_ENV_PATH" && ! -f "$TARGET_ENV_PATH" && -n "$EXPECTED_ENV_SHA" ]]; then
    err "Env drift detected: manifest expects created env at $TARGET_ENV_PATH but file is missing."
  fi

  ROLLBACK_STAMP="$(ts_compact)"
  PRE_ROLLBACK_COPY="$BACKUP_DIR/clawdbot.json.pre-rollback.${MIGRATION_ID}.${ROLLBACK_STAMP}.bak"
  cp "$TARGET_CONFIG_PATH" "$PRE_ROLLBACK_COPY"
  cp "$BACKUP_CONFIG_PATH" "$TARGET_CONFIG_PATH"

  ROLLBACK_ENV_ACTION="skipped"
  PRE_ROLLBACK_ENV_COPY=""
  if [[ -n "$TARGET_ENV_PATH" ]]; then
    if [[ -n "$BACKUP_ENV_PATH" && -f "$BACKUP_ENV_PATH" ]]; then
      if [[ -f "$TARGET_ENV_PATH" ]]; then
        PRE_ROLLBACK_ENV_COPY="$BACKUP_DIR/env.pre-rollback.${MIGRATION_ID}.${ROLLBACK_STAMP}.bak"
        cp "$TARGET_ENV_PATH" "$PRE_ROLLBACK_ENV_COPY"
      fi
      cp "$BACKUP_ENV_PATH" "$TARGET_ENV_PATH"
      ROLLBACK_ENV_ACTION="restored_backup"
    elif [[ "$ENV_CREATED" == "true" && -f "$TARGET_ENV_PATH" ]]; then
      PRE_ROLLBACK_ENV_COPY="$BACKUP_DIR/env.pre-rollback.${MIGRATION_ID}.${ROLLBACK_STAMP}.bak"
      cp "$TARGET_ENV_PATH" "$PRE_ROLLBACK_ENV_COPY"
      rm -f "$TARGET_ENV_PATH"
      ROLLBACK_ENV_ACTION="removed_created_env"
    fi
  fi

  python3 - "$REPORT_JSON" "$MIGRATION_ID" "$MANIFEST_PATH" "$PRE_ROLLBACK_COPY" "$TARGET_CONFIG_PATH" "$ROLLBACK_ENV_ACTION" "$PRE_ROLLBACK_ENV_COPY" "$TARGET_ENV_PATH" <<'PY'
import datetime
import json
import sys

(
    report_path,
    migration_id,
    manifest_path,
    pre_config_copy,
    restored_target,
    env_action,
    pre_env_copy,
    target_env,
) = sys.argv[1:9]
report = {
    "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mode": "rollback",
    "migration_id": migration_id,
    "manifest": manifest_path,
    "pre_rollback_backup": pre_config_copy,
    "pre_rollback_env_backup": pre_env_copy,
    "restored_target_config": restored_target,
    "target_env_path": target_env,
    "env_rollback_action": env_action,
    "status": "rolled_back",
}
with open(report_path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY

  echo "Rollback completed."
  echo "Report: $REPORT_JSON"
  exit 0
fi

verify_runtime_sources

[[ -f "$CONFIG_PATH" ]] || err "Config not found: $CONFIG_PATH"
python3 - "$CONFIG_PATH" <<'PY' >/dev/null
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    json.load(handle)
PY

TMP_AFTER="$(mktemp)"
TMP_PLAN="$(mktemp)"
trap 'rm -f "$TMP_AFTER" "$TMP_PLAN"' EXIT

python3 - "$CONFIG_PATH" "$TMP_AFTER" "$TMP_PLAN" "$TARGET_RUNTIME_SCRIPT" "$TARGET_APP_ROOT" "$TARGET_RUNTIME_DIR" "$FORCE_SPLIT_DEFAULT" "$PATCH_ENV" <<'PY'
import copy
import json
import os
import sys
from datetime import datetime, timezone

(
    config_path,
    after_path,
    plan_path,
    runtime_script,
    target_app_root,
    target_runtime_dir,
    force_split,
    patch_env,
) = sys.argv[1:9]
force_split = force_split == "1"
patch_env = patch_env == "1"

with open(config_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

if not isinstance(data, dict):
    raise SystemExit("Config root must be a JSON object")

patched_fields = []
validation_errors = []


def get_path(obj, path):
    cur = obj
    for part in path:
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur


def set_path(obj, path, value):
    cur = obj
    for part in path[:-1]:
        nxt = cur.get(part)
        if nxt is None:
            nxt = {}
            cur[part] = nxt
        elif not isinstance(nxt, dict):
            raise TypeError(f"{'.'.join(path[:-1])} must be an object")
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


def require_object(path):
    value = get_path(data, path)
    if not isinstance(value, dict):
        validation_errors.append(f"{'.'.join(path)} must exist as an object")


def ensure_optional_object(path):
    value = get_path(data, path)
    if value is not None and not isinstance(value, dict):
        validation_errors.append(f"{'.'.join(path)} must be an object when present")


def merge_dict(existing, managed):
    if existing is None:
        existing = {}
    if not isinstance(existing, dict):
        raise TypeError("managed merge target must be an object")
    merged = copy.deepcopy(existing)
    merged.update(managed)
    return merged


require_object(["agents"])
require_object(["agents", "defaults"])
ensure_optional_object(["agents", "defaults", "model"])
ensure_optional_object(["agents", "defaults", "models"])
ensure_optional_object(["agents", "defaults", "cliBackends"])
ensure_optional_object(["models"])

if validation_errors:
    raise SystemExit("; ".join(validation_errors))

backend_mode = "tool_bridge" if force_split else "conversation"
runtime_root = os.path.dirname(config_path)
workspace_root = os.path.join(target_app_root, "clawd")
backend_args = [
    runtime_script,
    "--runtime-root", runtime_root,
    "--workspace-root", workspace_root,
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
if models_obj is None:
    models_obj = {}
    set_path(data, models_path, models_obj)
elif not isinstance(models_obj, dict):
    raise SystemExit("agents.defaults.models must be an object")

current_tm_model = models_obj.get("twinmind-cli/default")
if current_tm_model is not None and not isinstance(current_tm_model, dict):
    raise SystemExit("agents.defaults.models.twinmind-cli/default must be an object when present")
new_tm_model = merge_dict(current_tm_model, {"alias": "tm"}) if current_tm_model is not None else {"alias": "tm"}
if current_tm_model != new_tm_model:
    models_obj["twinmind-cli/default"] = new_tm_model
    patched_fields.append({
        "path": "agents.defaults.models.twinmind-cli/default",
        "old": current_tm_model,
        "new": new_tm_model,
    })

backend_defaults = {
    "command": "python3",
    "args": backend_args,
    "output": "json",
    "input": "arg",
    "sessionArg": "--session-id",
    "sessionMode": "always",
    "serialize": True,
}
current_backend = get_path(data, ["agents", "defaults", "cliBackends", "twinmind-cli"])
if current_backend is not None and not isinstance(current_backend, dict):
    raise SystemExit("agents.defaults.cliBackends.twinmind-cli must be an object when present")
new_backend = merge_dict(current_backend, backend_defaults) if current_backend is not None else backend_defaults
patch(["agents", "defaults", "cliBackends", "twinmind-cli"], new_backend)

if get_path(data, ["models", "mode"]) is None:
    patch(["models", "mode"], "merge")

plan = {
    "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mode": "plan_or_apply",
    "target_config_path": config_path,
    "target_app_root": target_app_root,
    "target_runtime_dir": target_runtime_dir,
    "target_runtime_script": runtime_script,
    "runtime_vendor_files": [
        "twinmind_orchestrator.py",
        "twinmind_memory_sync.py",
        "twinmind_memory_query.py",
    ],
    "force_split_default": force_split,
    "patch_env": patch_env,
    "changed": bool(patched_fields),
    "patched_fields": patched_fields,
}

with open(after_path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")

with open(plan_path, "w", encoding="utf-8") as handle:
    json.dump(plan, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
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

copy_runtime_into_target

BACKUP_ENV_PATH=""
ENV_CREATED=0
ENV_BEFORE_SHA=""
if [[ "$PATCH_ENV" -eq 1 && -f "$ENV_PATH" ]]; then
  BACKUP_ENV_PATH="$BACKUP_DIR/env.${MIGRATION_ID}.bak"
  cp "$ENV_PATH" "$BACKUP_ENV_PATH"
  ENV_BEFORE_SHA="$(sha256_file "$ENV_PATH")"
fi

cp "$TMP_AFTER" "$CONFIG_PATH"

ENV_PATCHED_KEYS=()
if [[ "$PATCH_ENV" -eq 1 ]]; then
  TEMPLATE_PATH="$KIT_ROOT/templates/env.append.template"
  [[ -f "$TEMPLATE_PATH" ]] || err "Missing template: $TEMPLATE_PATH"

  if [[ ! -f "$ENV_PATH" ]]; then
    mkdir -p "$(dirname "$ENV_PATH")"
    : > "$ENV_PATH"
    chmod 600 "$ENV_PATH" || true
    ENV_CREATED=1
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
ENV_AFTER_SHA=""
if [[ "$PATCH_ENV" -eq 1 && -f "$ENV_PATH" ]]; then
  ENV_AFTER_SHA="$(sha256_file "$ENV_PATH")"
fi
MANIFEST_PATH="$KIT_ROOT/manifests/migration-${MIGRATION_ID}.json"

python3 - "$MANIFEST_PATH" "$MIGRATION_ID" "$CONFIG_PATH" "$ENV_PATH" "$BACKUP_CONFIG_PATH" "$BACKUP_ENV_PATH" "$BEFORE_SHA" "$AFTER_SHA" "$ENV_BEFORE_SHA" "$ENV_AFTER_SHA" "$REPORT_JSON" "$PATCH_ENV" "$KIT_ROOT" "$FORCE_SPLIT_DEFAULT" "$TARGET_APP_ROOT" "$TARGET_RUNTIME_DIR" "$TARGET_RUNTIME_SCRIPT" "$ENV_CREATED" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    manifest_path,
    migration_id,
    target_config_path,
    target_env_path,
    backup_config_path,
    backup_env_path,
    before_sha,
    after_sha,
    env_before_sha,
    env_after_sha,
    report_json,
    patch_env,
    kit_root,
    force_split,
    target_app_root,
    target_runtime_dir,
    target_runtime_script,
    env_created,
) = sys.argv[1:19]

with open(report_json, "r", encoding="utf-8") as handle:
    report = json.load(handle)

manifest = {
    "migration_id": migration_id,
    "created_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mode": "apply",
    "target_config_path": target_config_path,
    "target_env_path": target_env_path,
    "target_app_root": target_app_root,
    "target_runtime_dir": target_runtime_dir,
    "target_runtime_script": target_runtime_script,
    "runtime_vendor_files": [
        "twinmind_orchestrator.py",
        "twinmind_memory_sync.py",
        "twinmind_memory_query.py",
    ],
    "backup_config_path": backup_config_path,
    "backup_env_path": backup_env_path,
    "before_checksum": before_sha,
    "after_checksum": after_sha,
    "env_before_checksum": env_before_sha,
    "env_after_checksum": env_after_sha,
    "patched_fields": report.get("patched_fields", []),
    "patch_env": bool(int(patch_env)),
    "env_created": bool(int(env_created)),
    "force_split_default": bool(int(force_split)),
    "kit_root": kit_root,
    "status": "applied",
}

with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY

echo "Apply completed."
echo "Report: $REPORT_JSON"
echo "Manifest: $MANIFEST_PATH"

if [[ "${#ENV_PATCHED_KEYS[@]}" -gt 0 ]]; then
  echo "Patched env keys: ${ENV_PATCHED_KEYS[*]}"
fi
