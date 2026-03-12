#!/usr/bin/env bash
set -euo pipefail

MODE="plan"
CONFIG_PATH=""
ENV_PATH=""
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR=""
REPORT_JSON=""
MIGRATION_ID=""
UPDATE_ID=""
PATCH_ENV=0
YES=0
FORCE_SPLIT_DEFAULT=0
SYNC_CONFIG=0
SYNC_ENV_TEMPLATE=0
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
  --mode plan|apply|rollback|update-plan|update-apply|update-rollback

Core options:
  --config <path>                   Optional; auto-detects clawdbot/openclaw/moltbook/moltbot config when omitted
  --env <path>                      Optional; defaults to sibling .env next to detected config
  --kit-root <path>                 Default: script parent directory
  --backup-dir <path>               Default: <kit-root>/backups
  --report-json <path>              Default: <kit-root>/reports/<convert|update>-<id>.json
  --migration-id <id>               Optional in plan/apply; required for rollback
  --update-id <id>                  Optional in update-plan/update-apply; required for update-rollback

Behavior flags:
  --patch-env                       Append non-secret defaults from templates/env.append.template during migration apply
  --force-split-default             Set backend args to '--mode tool_bridge' (default migration mode is conversation)
  --sync-config 0|1                 Update flow only; sync managed twinmind-cli backend infrastructure fields (default: 0)
  --sync-env-template 0|1           Update flow only; append missing env template keys (default: 0)
  --yes                             Required for apply/rollback modes
  -h, --help

Notes:
  - plan/apply/rollback: initial migration lifecycle
  - update-plan/update-apply/update-rollback: post-migration runtime update lifecycle
  - update-apply is runtime-only by default; config/env sync are opt-in
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

mode_family() {
  case "$MODE" in
    plan|apply|rollback) echo "migration" ;;
    update-plan|update-apply|update-rollback) echo "update" ;;
    *) echo "unknown" ;;
  esac
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

copy_runtime_backup_into_dir() {
  local backup_dir="$1"
  local vendor_file
  mkdir -p "$backup_dir"
  for vendor_file in "${RUNTIME_VENDOR_FILES[@]}"; do
    if [[ -f "$TARGET_RUNTIME_DIR/$vendor_file" ]]; then
      cp "$TARGET_RUNTIME_DIR/$vendor_file" "$backup_dir/$vendor_file"
    fi
  done
}

restore_runtime_backup_from_dir() {
  local backup_dir="$1"
  local vendor_file
  mkdir -p "$TARGET_RUNTIME_DIR"
  for vendor_file in "${RUNTIME_VENDOR_FILES[@]}"; do
    [[ -f "$backup_dir/$vendor_file" ]] || err "Runtime backup missing file: $backup_dir/$vendor_file"
    cp "$backup_dir/$vendor_file" "$TARGET_RUNTIME_DIR/$vendor_file"
  done
}

inspect_managed_install() {
  local output_path="$1"
  python3 - "$CONFIG_PATH" "$output_path" <<'PY'
import json
import os
import sys
from pathlib import Path

config_path, output_path = sys.argv[1:3]
with open(config_path, 'r', encoding='utf-8') as handle:
    data = json.load(handle)

result = {
    "config_path": config_path,
    "managed_install": False,
    "errors": [],
    "warnings": [],
    "backend_exists": False,
    "runtime_script": "",
    "runtime_dir": "",
    "runtime_root": "",
    "workspace_root": "",
    "backend_mode": "",
    "backend_command": "",
    "backend_args": [],
    "target_app_root": "",
}

if not isinstance(data, dict):
    result["errors"].append("Config root must be a JSON object")
else:
    backend = (
        data.get("agents", {})
        .get("defaults", {})
        .get("cliBackends", {})
        .get("twinmind-cli")
    )
    if backend is None:
        result["errors"].append("agents.defaults.cliBackends.twinmind-cli missing")
    elif not isinstance(backend, dict):
        result["errors"].append("agents.defaults.cliBackends.twinmind-cli must be an object")
    else:
        result["backend_exists"] = True
        result["backend_command"] = str(backend.get("command") or "")
        args = backend.get("args")
        if not isinstance(args, list):
            result["errors"].append("twinmind-cli.args must be a list")
            args = []
        result["backend_args"] = args
        runtime_script = ""
        for item in args:
            sval = str(item or "")
            if sval.endswith("twinmind_orchestrator.py"):
                runtime_script = sval
                break
        def value_after(flag: str) -> str:
            for idx, item in enumerate(args):
                if str(item) == flag and idx + 1 < len(args):
                    return str(args[idx + 1])
            return ""
        result["runtime_script"] = runtime_script
        result["runtime_dir"] = str(Path(runtime_script).parent) if runtime_script else ""
        result["runtime_root"] = value_after("--runtime-root")
        result["workspace_root"] = value_after("--workspace-root")
        result["backend_mode"] = value_after("--mode")
        if result["workspace_root"]:
            result["target_app_root"] = str(Path(result["workspace_root"]).parent)
        elif result["runtime_root"]:
            result["target_app_root"] = str(Path(result["runtime_root"]).parent)

        command_ok = os.path.basename(result["backend_command"]).startswith("python") if result["backend_command"] else False
        runtime_ok = bool(runtime_script)
        rr_ok = bool(result["runtime_root"])
        wr_ok = bool(result["workspace_root"])
        if not command_ok:
            result["warnings"].append("twinmind-cli command is not a python executable")
        if command_ok and runtime_ok and rr_ok and wr_ok:
            result["managed_install"] = True
        else:
            if not runtime_ok:
                result["errors"].append("twinmind_orchestrator.py missing from backend args")
            if not rr_ok:
                result["errors"].append("--runtime-root missing from backend args")
            if not wr_ok:
                result["errors"].append("--workspace-root missing from backend args")

with open(output_path, 'w', encoding='utf-8') as handle:
    json.dump(result, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY
}

build_runtime_checksums() {
  local runtime_dir="$1"
  local output_path="$2"
  python3 - "$runtime_dir" "$KIT_ROOT/vendor" "$output_path" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

runtime_dir, vendor_dir, output_path = sys.argv[1:4]
files = [
    "twinmind_orchestrator.py",
    "twinmind_memory_sync.py",
    "twinmind_memory_query.py",
]

def sha(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

payload = {"runtime": {}, "vendor": {}, "changed_files": [], "missing_runtime_files": []}
for name in files:
    rp = Path(runtime_dir) / name
    vp = Path(vendor_dir) / name
    payload["vendor"][name] = sha(vp) if vp.exists() else ""
    if rp.exists():
        payload["runtime"][name] = sha(rp)
        if payload["runtime"][name] != payload["vendor"][name]:
            payload["changed_files"].append(name)
    else:
        payload["runtime"][name] = ""
        payload["missing_runtime_files"].append(name)
        payload["changed_files"].append(name)
payload["update_available"] = bool(payload["changed_files"])
with open(output_path, 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY
}

git_head_or_empty() {
  git -C "$KIT_ROOT" rev-parse HEAD 2>/dev/null || true
}

build_update_config_patch() {
  local output_config="$1"
  local output_report="$2"
  python3 - "$CONFIG_PATH" "$output_config" "$output_report" <<'PY'
import copy
import json
import os
import sys
from pathlib import Path

config_path, output_config, output_report = sys.argv[1:4]
with open(config_path, 'r', encoding='utf-8') as handle:
    data = json.load(handle)

if not isinstance(data, dict):
    raise SystemExit("Config root must be a JSON object")

backend = (
    data.get("agents", {})
    .get("defaults", {})
    .get("cliBackends", {})
    .get("twinmind-cli")
)
if not isinstance(backend, dict):
    raise SystemExit("agents.defaults.cliBackends.twinmind-cli must exist as an object for update sync")
args = backend.get("args")
if not isinstance(args, list) or not args:
    raise SystemExit("twinmind-cli.args must exist as a non-empty list for update sync")

runtime_script = ""
for item in args:
    sval = str(item or "")
    if sval.endswith("twinmind_orchestrator.py"):
        runtime_script = sval
        break
if not runtime_script:
    raise SystemExit("twinmind_orchestrator.py missing from backend args")

config_dir = os.path.dirname(config_path)
runtime_root = config_dir
workspace_root = os.path.join(os.path.dirname(config_dir), "clawd") if os.path.basename(config_dir).startswith('.') else os.path.join(config_dir, "clawd")

patched_fields = []
new_backend = copy.deepcopy(backend)

def set_flag(args_list, flag, value):
    for idx, item in enumerate(args_list):
        if str(item) == flag and idx + 1 < len(args_list):
            if str(args_list[idx + 1]) != value:
                args_list[idx + 1] = value
            return
    args_list.extend([flag, value])

new_args = [str(x) for x in args]
new_args[0] = runtime_script
set_flag(new_args, "--runtime-root", runtime_root)
set_flag(new_args, "--workspace-root", workspace_root)
new_backend["command"] = "python3"
new_backend["args"] = new_args
new_backend["output"] = "json"
new_backend["input"] = "arg"
new_backend["sessionArg"] = "--session-id"
new_backend["sessionMode"] = "always"
new_backend["serialize"] = True

if backend != new_backend:
    data["agents"]["defaults"]["cliBackends"]["twinmind-cli"] = new_backend
    patched_fields.append({
        "path": "agents.defaults.cliBackends.twinmind-cli",
        "old": backend,
        "new": new_backend,
    })

with open(output_config, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
with open(output_report, 'w', encoding='utf-8') as handle:
    json.dump({"changed": bool(patched_fields), "patched_fields": patched_fields}, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY
}

append_missing_env_template_keys() {
  local env_path="$1"
  local keys_out="$2"
  local created=0
  local -a patched_keys=()
  local template_path="$KIT_ROOT/templates/env.append.template"
  [[ -f "$template_path" ]] || err "Missing template: $template_path"

  if [[ ! -f "$env_path" ]]; then
    mkdir -p "$(dirname "$env_path")"
    : > "$env_path"
    chmod 600 "$env_path" || true
    created=1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    local key="${line%%=*}"
    [[ -z "$key" ]] && continue
    if ! grep -qE "^${key}=" "$env_path"; then
      echo "$line" >> "$env_path"
      patched_keys+=("$key")
    fi
  done < "$template_path"

  python3 - "$keys_out" "$created" "$(printf '%s\n' "${patched_keys[@]}")" <<'PY'
import json
import sys
path, created, keys = sys.argv[1:4]
payload = {
    "env_created": bool(int(created)),
    "patched_keys": [line for line in keys.splitlines() if line.strip()],
}
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
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
    --update-id)
      UPDATE_ID="$2"
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
    --sync-config)
      SYNC_CONFIG="$2"
      shift 2
      ;;
    --sync-env-template)
      SYNC_ENV_TEMPLATE="$2"
      shift 2
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
  plan|apply|rollback|update-plan|update-apply|update-rollback) ;;
  *) err "Invalid --mode: $MODE" ;;
esac

case "$SYNC_CONFIG" in 0|1) ;; *) err "--sync-config must be 0 or 1" ;; esac
case "$SYNC_ENV_TEMPLATE" in 0|1) ;; *) err "--sync-env-template must be 0 or 1" ;; esac

need_cmd python3
need_cmd sha256sum
verify_runtime_sources

if [[ "$MODE" != "rollback" && "$MODE" != "update-rollback" ]]; then
  resolve_config_and_env
  resolve_target_layout
fi

[[ -n "$BACKUP_DIR" ]] || BACKUP_DIR="$KIT_ROOT/backups"
mkdir -p "$BACKUP_DIR" "$KIT_ROOT/manifests" "$KIT_ROOT/reports"

if [[ -z "$MIGRATION_ID" ]]; then
  MIGRATION_ID="mig-$(ts_compact)"
fi
if [[ -z "$UPDATE_ID" ]]; then
  UPDATE_ID="upd-$(ts_compact)"
fi
if [[ -z "$REPORT_JSON" ]]; then
  if [[ "$(mode_family)" == "update" ]]; then
    REPORT_JSON="$KIT_ROOT/reports/update-${UPDATE_ID}.json"
  else
    REPORT_JSON="$KIT_ROOT/reports/convert-${MIGRATION_ID}.json"
  fi
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

if [[ "$MODE" == "update-rollback" ]]; then
  [[ "$YES" -eq 1 ]] || err "Update rollback requires --yes"
  MANIFEST_PATH="$KIT_ROOT/manifests/update-${UPDATE_ID}.json"
  [[ -f "$MANIFEST_PATH" ]] || err "Update manifest not found: $MANIFEST_PATH"

  TARGET_CONFIG_PATH="$(json_get "$MANIFEST_PATH" target_config_path)"
  TARGET_ENV_PATH="$(json_get "$MANIFEST_PATH" target_env_path)"
  TARGET_RUNTIME_DIR="$(json_get "$MANIFEST_PATH" target_runtime_dir)"
  TARGET_RUNTIME_SCRIPT="$(json_get "$MANIFEST_PATH" target_runtime_script)"
  RUNTIME_BACKUP_DIR="$(json_get "$MANIFEST_PATH" runtime_backup_dir)"
  SYNC_CONFIG_MANIFEST="$(json_get "$MANIFEST_PATH" sync_config)"
  SYNC_ENV_MANIFEST="$(json_get "$MANIFEST_PATH" sync_env_template)"
  CONFIG_BACKUP_PATH="$(json_get "$MANIFEST_PATH" backup_config_path)"
  BACKUP_ENV_PATH="$(json_get "$MANIFEST_PATH" backup_env_path)"
  EXPECTED_CONFIG_SHA="$(json_get "$MANIFEST_PATH" config_after_checksum)"
  EXPECTED_ENV_SHA="$(json_get "$MANIFEST_PATH" env_after_checksum)"
  ENV_CREATED="$(json_get "$MANIFEST_PATH" env_created)"
  RUNTIME_AFTER_JSON="$(json_get "$MANIFEST_PATH" runtime_after_checksums)"

  [[ -d "$RUNTIME_BACKUP_DIR" ]] || err "Runtime backup dir not found: $RUNTIME_BACKUP_DIR"
  [[ -n "$TARGET_RUNTIME_DIR" ]] || err "Manifest missing target_runtime_dir"

  python3 - "$TARGET_RUNTIME_DIR" "$RUNTIME_AFTER_JSON" <<'PY'
import json, sys
from pathlib import Path
runtime_dir = Path(sys.argv[1])
expected = json.loads(sys.argv[2]) if sys.argv[2].strip() else {}
for name, expected_sha in expected.items():
    path = runtime_dir / name
    if not path.exists():
        raise SystemExit(f"Runtime drift detected: missing {path}")
    import hashlib
    h = hashlib.sha256(path.read_bytes()).hexdigest()
    if expected_sha and h != expected_sha:
        raise SystemExit(f"Runtime drift detected at {path}; refusing update rollback.")
PY

  if [[ "$SYNC_CONFIG_MANIFEST" == "true" ]]; then
    [[ -f "$CONFIG_BACKUP_PATH" ]] || err "Config backup not found: $CONFIG_BACKUP_PATH"
    [[ -f "$TARGET_CONFIG_PATH" ]] || err "Config drift detected: target config missing at $TARGET_CONFIG_PATH"
    if [[ -n "$EXPECTED_CONFIG_SHA" ]]; then
      CURRENT_CONFIG_SHA="$(sha256_file "$TARGET_CONFIG_PATH")"
      [[ "$CURRENT_CONFIG_SHA" == "$EXPECTED_CONFIG_SHA" ]] || err "Config drift detected at $TARGET_CONFIG_PATH; refusing update rollback."
    fi
  fi

  if [[ "$SYNC_ENV_MANIFEST" == "true" ]]; then
    if [[ -n "$TARGET_ENV_PATH" && -f "$TARGET_ENV_PATH" && -n "$EXPECTED_ENV_SHA" ]]; then
      CURRENT_ENV_SHA="$(sha256_file "$TARGET_ENV_PATH")"
      [[ "$CURRENT_ENV_SHA" == "$EXPECTED_ENV_SHA" ]] || err "Env drift detected at $TARGET_ENV_PATH; refusing update rollback."
    fi
    if [[ "$ENV_CREATED" == "true" && -n "$TARGET_ENV_PATH" && ! -f "$TARGET_ENV_PATH" && -n "$EXPECTED_ENV_SHA" ]]; then
      err "Env drift detected: update manifest expects created env at $TARGET_ENV_PATH but file is missing."
    fi
  fi

  UPDATE_STAMP="$(ts_compact)"
  PRE_ROLLBACK_RUNTIME_DIR="$BACKUP_DIR/runtime.pre-update-rollback.${UPDATE_ID}.${UPDATE_STAMP}"
  copy_runtime_backup_into_dir "$PRE_ROLLBACK_RUNTIME_DIR"
  restore_runtime_backup_from_dir "$RUNTIME_BACKUP_DIR"

  PRE_ROLLBACK_COPY=""
  ROLLBACK_ENV_ACTION="skipped"
  PRE_ROLLBACK_ENV_COPY=""
  if [[ "$SYNC_CONFIG_MANIFEST" == "true" ]]; then
    PRE_ROLLBACK_COPY="$BACKUP_DIR/clawdbot.json.pre-update-rollback.${UPDATE_ID}.${UPDATE_STAMP}.bak"
    cp "$TARGET_CONFIG_PATH" "$PRE_ROLLBACK_COPY"
    cp "$CONFIG_BACKUP_PATH" "$TARGET_CONFIG_PATH"
  fi
  if [[ "$SYNC_ENV_MANIFEST" == "true" && -n "$TARGET_ENV_PATH" ]]; then
    if [[ -n "$BACKUP_ENV_PATH" && -f "$BACKUP_ENV_PATH" ]]; then
      if [[ -f "$TARGET_ENV_PATH" ]]; then
        PRE_ROLLBACK_ENV_COPY="$BACKUP_DIR/env.pre-update-rollback.${UPDATE_ID}.${UPDATE_STAMP}.bak"
        cp "$TARGET_ENV_PATH" "$PRE_ROLLBACK_ENV_COPY"
      fi
      cp "$BACKUP_ENV_PATH" "$TARGET_ENV_PATH"
      ROLLBACK_ENV_ACTION="restored_backup"
    elif [[ "$ENV_CREATED" == "true" && -f "$TARGET_ENV_PATH" ]]; then
      PRE_ROLLBACK_ENV_COPY="$BACKUP_DIR/env.pre-update-rollback.${UPDATE_ID}.${UPDATE_STAMP}.bak"
      cp "$TARGET_ENV_PATH" "$PRE_ROLLBACK_ENV_COPY"
      rm -f "$TARGET_ENV_PATH"
      ROLLBACK_ENV_ACTION="removed_created_env"
    fi
  fi

  python3 - "$REPORT_JSON" "$UPDATE_ID" "$MANIFEST_PATH" "$PRE_ROLLBACK_RUNTIME_DIR" "$PRE_ROLLBACK_COPY" "$PRE_ROLLBACK_ENV_COPY" "$TARGET_RUNTIME_DIR" "$TARGET_CONFIG_PATH" "$TARGET_ENV_PATH" "$ROLLBACK_ENV_ACTION" <<'PY'
import datetime, json, sys
(
  report_path,
  update_id,
  manifest_path,
  pre_runtime_dir,
  pre_config_copy,
  pre_env_copy,
  runtime_dir,
  config_path,
  env_path,
  env_action,
) = sys.argv[1:11]
report = {
  "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "mode": "update-rollback",
  "update_id": update_id,
  "manifest": manifest_path,
  "pre_rollback_runtime_backup_dir": pre_runtime_dir,
  "pre_rollback_backup": pre_config_copy,
  "pre_rollback_env_backup": pre_env_copy,
  "restored_runtime_dir": runtime_dir,
  "restored_target_config": config_path,
  "target_env_path": env_path,
  "env_rollback_action": env_action,
  "status": "rolled_back",
}
with open(report_path, 'w', encoding='utf-8') as handle:
  json.dump(report, handle, ensure_ascii=False, indent=2)
  handle.write('\n')
PY

  echo "Update rollback completed."
  echo "Report: $REPORT_JSON"
  exit 0
fi

[[ -f "$CONFIG_PATH" ]] || err "Config not found: $CONFIG_PATH"
python3 - "$CONFIG_PATH" <<'PY' >/dev/null
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    json.load(handle)
PY

if [[ "$MODE" == "update-plan" || "$MODE" == "update-apply" ]]; then
  TMP_INSPECT="$(mktemp)"
  TMP_RUNTIME="$(mktemp)"
  TMP_UPDATE_CFG="$(mktemp)"
  TMP_UPDATE_CFG_REPORT="$(mktemp)"
  TMP_ENV_KEYS="$(mktemp)"
  trap 'rm -f "$TMP_INSPECT" "$TMP_RUNTIME" "$TMP_UPDATE_CFG" "$TMP_UPDATE_CFG_REPORT" "$TMP_ENV_KEYS"' EXIT

  inspect_managed_install "$TMP_INSPECT"
  MANAGED_INSTALL="$(json_get "$TMP_INSPECT" managed_install)"
  [[ "$MANAGED_INSTALL" == "true" ]] || err "Detected config is not a TwinMind-managed install; use migration apply instead of update."
  TARGET_RUNTIME_SCRIPT="$(json_get "$TMP_INSPECT" runtime_script)"
  TARGET_RUNTIME_DIR="$(json_get "$TMP_INSPECT" runtime_dir)"
  TARGET_APP_ROOT="$(json_get "$TMP_INSPECT" target_app_root)"
  CURRENT_BACKEND_MODE="$(json_get "$TMP_INSPECT" backend_mode)"
  build_runtime_checksums "$TARGET_RUNTIME_DIR" "$TMP_RUNTIME"
  python3 - "$TMP_RUNTIME" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
missing = payload.get("missing_runtime_files", [])
if missing:
    raise SystemExit("TwinMind-managed install is missing runtime files: " + ", ".join(missing))
PY

  CONFIG_PATCH_CHANGED="false"
  CONFIG_PATCH_FIELDS='[]'
  if [[ "$SYNC_CONFIG" == "1" ]]; then
    build_update_config_patch "$TMP_UPDATE_CFG" "$TMP_UPDATE_CFG_REPORT"
    CONFIG_PATCH_CHANGED="$(json_get "$TMP_UPDATE_CFG_REPORT" changed)"
    CONFIG_PATCH_FIELDS="$(json_get "$TMP_UPDATE_CFG_REPORT" patched_fields)"
  fi

  ENV_PATCHED_KEYS='[]'
  if [[ "$SYNC_ENV_TEMPLATE" == "1" && -f "$ENV_PATH" ]]; then
    python3 - "$ENV_PATH" "$KIT_ROOT/templates/env.append.template" "$TMP_ENV_KEYS" <<'PY'
import json, sys
from pathlib import Path
env_path = Path(sys.argv[1])
template_path = Path(sys.argv[2])
out = Path(sys.argv[3])
existing = env_path.read_text(encoding='utf-8', errors='replace').splitlines() if env_path.exists() else []
keys = set()
for raw in existing:
    line = raw.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    keys.add(line.split('=', 1)[0].strip())
missing = []
for raw in template_path.read_text(encoding='utf-8', errors='replace').splitlines():
    line = raw.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    key = line.split('=', 1)[0].strip()
    if key and key not in keys:
        missing.append(key)
out.write_text(json.dumps({"patched_keys": missing}, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
PY
    ENV_PATCHED_KEYS="$(json_get "$TMP_ENV_KEYS" patched_keys)"
  elif [[ "$SYNC_ENV_TEMPLATE" == "1" ]]; then
    ENV_PATCHED_KEYS='[]'
  fi

  python3 - "$REPORT_JSON" "$CONFIG_PATH" "$ENV_PATH" "$TARGET_APP_ROOT" "$TARGET_RUNTIME_DIR" "$TARGET_RUNTIME_SCRIPT" "$CURRENT_BACKEND_MODE" "$SYNC_CONFIG" "$SYNC_ENV_TEMPLATE" "$TMP_RUNTIME" "$TMP_INSPECT" "$CONFIG_PATCH_CHANGED" "$CONFIG_PATCH_FIELDS" "$ENV_PATCHED_KEYS" "$UPDATE_ID" "$MODE" <<'PY'
import datetime, json, sys
(
  report_path, config_path, env_path, target_app_root, target_runtime_dir, target_runtime_script,
  backend_mode, sync_config, sync_env_template, runtime_path, inspect_path, cfg_changed,
  cfg_fields, env_keys, update_id, mode_name,
) = sys.argv[1:17]
runtime = json.load(open(runtime_path, 'r', encoding='utf-8'))
inspect = json.load(open(inspect_path, 'r', encoding='utf-8'))
report = {
  "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
  "mode": mode_name,
  "update_id": update_id,
  "target_config_path": config_path,
  "target_env_path": env_path,
  "target_app_root": target_app_root,
  "target_runtime_dir": target_runtime_dir,
  "target_runtime_script": target_runtime_script,
  "managed_install": True,
  "backend_mode": backend_mode,
  "runtime_vendor_files": [
    "twinmind_orchestrator.py",
    "twinmind_memory_sync.py",
    "twinmind_memory_query.py",
  ],
  "runtime_before_checksums": runtime.get("runtime", {}),
  "vendor_checksums": runtime.get("vendor", {}),
  "changed_runtime_files": runtime.get("changed_files", []),
  "missing_runtime_files": runtime.get("missing_runtime_files", []),
  "update_available": bool(runtime.get("update_available")),
  "sync_config": bool(int(sync_config)),
  "sync_env_template": bool(int(sync_env_template)),
  "config_changed": str(cfg_changed).lower() == 'true',
  "patched_fields": json.loads(cfg_fields) if cfg_fields.strip() else [],
  "env_missing_keys": json.loads(env_keys) if env_keys.strip() else [],
  "warnings": inspect.get("warnings", []),
}
with open(report_path, 'w', encoding='utf-8') as handle:
  json.dump(report, handle, ensure_ascii=False, indent=2)
  handle.write('\n')
PY

  if [[ "$MODE" == "update-plan" ]]; then
    echo "Update plan completed."
    echo "Report: $REPORT_JSON"
    exit 0
  fi

  [[ "$YES" -eq 1 ]] || err "Update apply requires --yes"
  RUNTIME_BACKUP_DIR="$BACKUP_DIR/runtime-${UPDATE_ID}"
  copy_runtime_backup_into_dir "$RUNTIME_BACKUP_DIR"
  copy_runtime_into_target

  CONFIG_BACKUP_PATH=""
  CONFIG_BEFORE_SHA=""
  CONFIG_AFTER_SHA=""
  if [[ "$SYNC_CONFIG" == "1" && "$CONFIG_PATCH_CHANGED" == "true" ]]; then
    CONFIG_BACKUP_PATH="$BACKUP_DIR/clawdbot.json.update.${UPDATE_ID}.bak"
    cp "$CONFIG_PATH" "$CONFIG_BACKUP_PATH"
    CONFIG_BEFORE_SHA="$(sha256_file "$CONFIG_PATH")"
    cp "$TMP_UPDATE_CFG" "$CONFIG_PATH"
    CONFIG_AFTER_SHA="$(sha256_file "$CONFIG_PATH")"
  fi

  BACKUP_ENV_PATH=""
  ENV_CREATED=0
  ENV_BEFORE_SHA=""
  ENV_AFTER_SHA=""
  ENV_PATCHED_KEYS_RUNTIME='[]'
  if [[ "$SYNC_ENV_TEMPLATE" == "1" ]]; then
    if [[ -f "$ENV_PATH" ]]; then
      BACKUP_ENV_PATH="$BACKUP_DIR/env.update.${UPDATE_ID}.bak"
      cp "$ENV_PATH" "$BACKUP_ENV_PATH"
      ENV_BEFORE_SHA="$(sha256_file "$ENV_PATH")"
    fi
    append_missing_env_template_keys "$ENV_PATH" "$TMP_ENV_KEYS"
    ENV_CREATED="$(json_get "$TMP_ENV_KEYS" env_created)"
    ENV_PATCHED_KEYS_RUNTIME="$(json_get "$TMP_ENV_KEYS" patched_keys)"
    if [[ -f "$ENV_PATH" ]]; then
      ENV_AFTER_SHA="$(sha256_file "$ENV_PATH")"
    fi
  fi

  build_runtime_checksums "$TARGET_RUNTIME_DIR" "$TMP_RUNTIME"
  MANIFEST_PATH="$KIT_ROOT/manifests/update-${UPDATE_ID}.json"
  python3 - "$MANIFEST_PATH" "$UPDATE_ID" "$CONFIG_PATH" "$ENV_PATH" "$TARGET_APP_ROOT" "$TARGET_RUNTIME_DIR" "$TARGET_RUNTIME_SCRIPT" "$RUNTIME_BACKUP_DIR" "$CONFIG_BACKUP_PATH" "$BACKUP_ENV_PATH" "$CONFIG_BEFORE_SHA" "$CONFIG_AFTER_SHA" "$ENV_BEFORE_SHA" "$ENV_AFTER_SHA" "$SYNC_CONFIG" "$SYNC_ENV_TEMPLATE" "$ENV_CREATED" "$KIT_ROOT" "$TMP_RUNTIME" "$ENV_PATCHED_KEYS_RUNTIME" "$(git_head_or_empty)" <<'PY'
import datetime, json, sys
(
  manifest_path, update_id, config_path, env_path, target_app_root, target_runtime_dir, target_runtime_script,
  runtime_backup_dir, backup_config_path, backup_env_path, config_before_sha, config_after_sha,
  env_before_sha, env_after_sha, sync_config, sync_env_template, env_created, kit_root, runtime_path, env_keys,
  source_repo_head,
) = sys.argv[1:22]
runtime = json.load(open(runtime_path, 'r', encoding='utf-8'))
manifest = {
  "update_id": update_id,
  "created_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
  "mode": "update-apply",
  "target_config_path": config_path,
  "target_env_path": env_path,
  "target_app_root": target_app_root,
  "target_runtime_dir": target_runtime_dir,
  "target_runtime_script": target_runtime_script,
  "runtime_vendor_files": [
    "twinmind_orchestrator.py",
    "twinmind_memory_sync.py",
    "twinmind_memory_query.py",
  ],
  "runtime_backup_dir": runtime_backup_dir,
  "runtime_before_checksums": runtime.get("runtime", {}),
  "runtime_after_checksums": runtime.get("vendor", {}),
  "backup_config_path": backup_config_path,
  "backup_env_path": backup_env_path,
  "config_before_checksum": config_before_sha,
  "config_after_checksum": config_after_sha,
  "env_before_checksum": env_before_sha,
  "env_after_checksum": env_after_sha,
  "sync_config": bool(int(sync_config)),
  "sync_env_template": bool(int(sync_env_template)),
  "env_created": bool(int(env_created)),
  "env_patched_keys": json.loads(env_keys) if env_keys.strip() else [],
  "kit_root": kit_root,
  "source_repo_head": source_repo_head,
  "status": "applied",
}
with open(manifest_path, 'w', encoding='utf-8') as handle:
  json.dump(manifest, handle, ensure_ascii=False, indent=2)
  handle.write('\n')
PY

  python3 - "$REPORT_JSON" "$MANIFEST_PATH" "$TMP_RUNTIME" "$SYNC_CONFIG" "$SYNC_ENV_TEMPLATE" "$CONFIG_PATCH_CHANGED" "$ENV_PATCHED_KEYS_RUNTIME" <<'PY'
import json, sys
report_path, manifest_path, runtime_path, sync_config, sync_env_template, config_changed, env_keys = sys.argv[1:8]
report = json.load(open(report_path, 'r', encoding='utf-8'))
runtime = json.load(open(runtime_path, 'r', encoding='utf-8'))
report.update({
  "mode": "update-apply",
  "status": "applied",
  "manifest_path": manifest_path,
  "runtime_after_checksums": runtime.get("vendor", {}),
  "sync_config": bool(int(sync_config)),
  "sync_env_template": bool(int(sync_env_template)),
  "config_changed": str(config_changed).lower() == 'true',
  "env_patched_keys": json.loads(env_keys) if env_keys.strip() else [],
})
with open(report_path, 'w', encoding='utf-8') as handle:
  json.dump(report, handle, ensure_ascii=False, indent=2)
  handle.write('\n')
PY

  echo "Update apply completed."
  echo "Report: $REPORT_JSON"
  echo "Manifest: $MANIFEST_PATH"
  exit 0
fi

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
        patched_fields.append({"path": ".".join(path), "old": old, "new": value})

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
    patched_fields.append({"path": "agents.defaults.models.twinmind-cli/default", "old": current_tm_model, "new": new_tm_model})

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
  append_missing_env_template_keys "$ENV_PATH" "$TMP_PLAN.envkeys"
  ENV_CREATED="$(json_get "$TMP_PLAN.envkeys" env_created)"
  mapfile -t ENV_PATCHED_KEYS < <(python3 - "$TMP_PLAN.envkeys" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1], 'r', encoding='utf-8')).get('patched_keys', []):
    print(item)
PY
)
  rm -f "$TMP_PLAN.envkeys"
fi

BEFORE_SHA="$(sha256_file "$BACKUP_CONFIG_PATH")"
AFTER_SHA="$(sha256_file "$CONFIG_PATH")"
ENV_AFTER_SHA=""
if [[ "$PATCH_ENV" -eq 1 && -f "$ENV_PATH" ]]; then
  ENV_AFTER_SHA="$(sha256_file "$ENV_PATH")"
fi
MANIFEST_PATH="$KIT_ROOT/manifests/migration-${MIGRATION_ID}.json"
python3 - "$MANIFEST_PATH" "$MIGRATION_ID" "$CONFIG_PATH" "$ENV_PATH" "$BACKUP_CONFIG_PATH" "$BACKUP_ENV_PATH" "$BEFORE_SHA" "$AFTER_SHA" "$ENV_BEFORE_SHA" "$ENV_AFTER_SHA" "$REPORT_JSON" "$PATCH_ENV" "$KIT_ROOT" "$FORCE_SPLIT_DEFAULT" "$TARGET_APP_ROOT" "$TARGET_RUNTIME_DIR" "$TARGET_RUNTIME_SCRIPT" "$ENV_CREATED" <<'PY'
import json, sys
from datetime import datetime, timezone
(
    manifest_path, migration_id, target_config_path, target_env_path, backup_config_path, backup_env_path,
    before_sha, after_sha, env_before_sha, env_after_sha, report_json, patch_env, kit_root,
    force_split, target_app_root, target_runtime_dir, target_runtime_script, env_created,
) = sys.argv[1:19]
report = json.load(open(report_json, 'r', encoding='utf-8'))
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
with open(manifest_path, 'w', encoding='utf-8') as handle:
    json.dump(manifest, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY

echo "Apply completed."
echo "Report: $REPORT_JSON"
echo "Manifest: $MANIFEST_PATH"
if [[ "${#ENV_PATCHED_KEYS[@]}" -gt 0 ]]; then
  echo "Patched env keys: ${ENV_PATCHED_KEYS[*]}"
fi
