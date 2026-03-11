#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}/twinmind-split-kit"
REPORT_DIR="$TMP_BASE/reports"
MODE=""
CONFIG_PATH=""
ENV_PATH=""
TARGET_ROOT=""
MIGRATION_ID="easy-$(date -u +%Y%m%dT%H%M%SZ)"
PATCH_ENV=0
FORCE_SPLIT_DEFAULT=0
YES=0
QUERY=""
PRINT_JSON=0
CONFIG_PATH_EXPLICIT=0
ENV_PATH_EXPLICIT=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") <mode> [options]
       $(basename "$0") --mode <mode> [options]

Modes:
  preflight   Validate prerequisites, target detection, and converter plan viability
  plan        Run converter dry-run with an external report path
  replica     Run replica plan by default, or replica apply with --yes
  apply       Run live migration and then the smoke test
  smoke-test  Run the migration smoke test directly

Options:
  --mode <name>                   Alias for the positional mode argument
  --config <path>                 Optional; auto-detects target config when omitted
  --env <path>                    Optional; defaults to sibling .env next to config
  --target-root <path>            For replica mode; default: /tmp-based unique path
  --migration-id <id>             Default: easy-<utc timestamp>
  --report-dir <path>             Default: ${TMPDIR:-/tmp}/twinmind-split-kit/reports
  --patch-env                     Pass through to converter apply
  --force-split-default           Pass through to converter plan/apply
  --query <text>                  Optional custom smoke-test query
  --print-json                    Print only the final JSON summary
  --yes                           Required for live apply; enables replica apply
  -h, --help
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

report_path_for() {
  local name="$1"
  printf '%s/%s-%s.json' "$REPORT_DIR" "$name" "$MIGRATION_ID"
}

emit_report() {
  local label="$1"
  local report_json="$2"
  if [[ "$PRINT_JSON" -ne 1 ]]; then
    echo "$label"
    echo "Report: $report_json"
  fi
  python3 - "$report_json" <<'PY2'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    print(json.dumps(json.load(handle), ensure_ascii=False, indent=2))
PY2
}

write_json_report() {
  local path="$1"
  local payload="$2"
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$payload" <<'PY2'
import json, sys
path, payload = sys.argv[1:3]
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(json.loads(payload), handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY2
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
  local candidate=""

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

  [[ -n "$detected_config" ]] || return 1

  if [[ "$ENV_PATH_EXPLICIT" -eq 1 ]]; then
    detected_env="$ENV_PATH"
  else
    detected_env="$(dirname "$detected_config")/.env"
  fi

  CONFIG_PATH="$detected_config"
  ENV_PATH="$detected_env"
  return 0
}

load_key_from_env_file() {
  local env_file="$1"
  local key="$2"
  if [[ -f "$env_file" ]]; then
    grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2-
  fi
}

check_python_module() {
  local module="$1"
  python3 - "$module" <<'PY2' >/dev/null 2>&1
import importlib, sys
importlib.import_module(sys.argv[1])
PY2
}

detected_target_name() {
  if [[ "$CONFIG_PATH" == *".openclaw"* || "$CONFIG_PATH" == *"/openclaw.json" ]]; then
    echo "openclaw"
  elif [[ "$CONFIG_PATH" == *".moltbook"* || "$CONFIG_PATH" == *"/moltbook.json" ]]; then
    echo "moltbook"
  elif [[ "$CONFIG_PATH" == *".moltbot"* || "$CONFIG_PATH" == *"/moltbot.json" ]]; then
    echo "moltbot"
  else
    echo "clawdbot"
  fi
}

run_quiet_command() {
  local tmp_log rc
  tmp_log="$(mktemp)"
  if "$@" >"$tmp_log" 2>&1; then
    rm -f "$tmp_log"
    return 0
  fi
  rc=$?
  cat "$tmp_log" >&2 || true
  rm -f "$tmp_log"
  return "$rc"
}

run_converter_plan() {
  local report_json="$1"
  local -a cmd=("$KIT_ROOT/scripts/convert_clawdbot_to_split.sh" --mode plan --config "$CONFIG_PATH" --report-json "$report_json" --migration-id "$MIGRATION_ID")
  if [[ "$ENV_PATH_EXPLICIT" -eq 1 || -f "$ENV_PATH" ]]; then
    cmd+=(--env "$ENV_PATH")
  fi
  if [[ "$FORCE_SPLIT_DEFAULT" -eq 1 ]]; then
    cmd+=(--force-split-default)
  fi
  run_quiet_command "${cmd[@]}"
}

run_converter_apply() {
  local report_json="$1"
  local -a cmd=("$KIT_ROOT/scripts/convert_clawdbot_to_split.sh" --mode apply --config "$CONFIG_PATH" --report-json "$report_json" --migration-id "$MIGRATION_ID" --yes)
  if [[ "$ENV_PATH_EXPLICIT" -eq 1 || -f "$ENV_PATH" ]]; then
    cmd+=(--env "$ENV_PATH")
  fi
  if [[ "$PATCH_ENV" -eq 1 ]]; then
    cmd+=(--patch-env)
  fi
  if [[ "$FORCE_SPLIT_DEFAULT" -eq 1 ]]; then
    cmd+=(--force-split-default)
  fi
  run_quiet_command "${cmd[@]}"
}

run_preflight() {
  local report_json="$1"
  local plan_report="$2"
  if ! resolve_config_and_env; then
    write_json_report "$report_json" '{"mode":"preflight","ok":false,"errors":["Could not auto-detect config. Pass --config explicitly."]}'
    return 10
  fi

  local detected_target support_level plan_status=0 plan_stderr=""
  local -a missing=() warnings=()
  local tmp_plan_err
  tmp_plan_err="$(mktemp)"

  detected_target="$(detected_target_name)"
  support_level="supported"
  if [[ "$detected_target" != "clawdbot" ]]; then
    support_level="limited"
  fi

  need_cmd git || missing+=("git")
  need_cmd python3 || missing+=("python3")
  need_cmd sha256sum || missing+=("sha256sum")
  need_cmd timeout || missing+=("timeout")
  check_python_module requests || missing+=("python:requests")

  local refresh_token="${TWINMIND_REFRESH_TOKEN:-}"
  local firebase_api_key="${TWINMIND_FIREBASE_API_KEY:-}"
  if [[ -z "$refresh_token" ]]; then
    refresh_token="$(load_key_from_env_file "$ENV_PATH" TWINMIND_REFRESH_TOKEN || true)"
  fi
  if [[ -z "$firebase_api_key" ]]; then
    firebase_api_key="$(load_key_from_env_file "$ENV_PATH" TWINMIND_FIREBASE_API_KEY || true)"
  fi
  [[ -n "$refresh_token" ]] || missing+=("TWINMIND_REFRESH_TOKEN")
  [[ -n "$firebase_api_key" ]] || missing+=("TWINMIND_FIREBASE_API_KEY")

  if ! need_cmd codex; then
    missing+=("codex")
  elif [[ ! -f "${HOME:-/root}/.codex/auth.json" && ! -f "${HOME:-/root}/.codex/auth-profiles.json" ]]; then
    warnings+=("codex auth could not be verified from the standard auth files")
  fi

  if ! run_converter_plan "$plan_report" >/dev/null 2>"$tmp_plan_err"; then
    plan_status=20
    plan_stderr="$(cat "$tmp_plan_err")"
    warnings+=("converter plan validation failed")
  fi
  rm -f "$tmp_plan_err"

  local payload
  payload="$(python3 - "$CONFIG_PATH" "$ENV_PATH" "$detected_target" "$support_level" "$plan_report" "$plan_status" "$plan_stderr" "$(printf '%s\n' "${missing[@]}")" "$(printf '%s\n' "${warnings[@]}")" <<'PY2'
import datetime as dt, json, sys
config_path, env_path, detected_target, support_level, plan_report, plan_status, plan_stderr, missing_raw, warnings_raw = sys.argv[1:10]
missing = [line for line in missing_raw.splitlines() if line.strip()]
warnings = [line for line in warnings_raw.splitlines() if line.strip()]
errors = []
if int(plan_status):
    errors.append(plan_stderr.strip() or 'converter plan validation failed')
report = {
    'timestamp_utc': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'mode': 'preflight',
    'ok': (not missing) and int(plan_status) == 0,
    'detected_config': config_path,
    'detected_env': env_path,
    'detected_target': detected_target,
    'support_level': support_level,
    'plan_report': plan_report,
    'missing': missing,
    'warnings': warnings,
    'errors': errors,
}
print(json.dumps(report, ensure_ascii=False))
PY2
)"
  write_json_report "$report_json" "$payload"

  if [[ ${#missing[@]} -gt 0 ]]; then
    return 1
  fi
  if [[ "$plan_status" -ne 0 ]]; then
    return "$plan_status"
  fi
}

run_plan() {
  local report_json="$1"
  resolve_config_and_env || err "Could not auto-detect config. Pass --config explicitly."
  run_converter_plan "$report_json"
}

run_replica() {
  local report_json="$1"
  local bootstrap_mode="plan"
  if [[ "$YES" -eq 1 ]]; then
    bootstrap_mode="apply"
  fi
  if [[ -z "$TARGET_ROOT" ]]; then
    TARGET_ROOT="$TMP_BASE/replica-$MIGRATION_ID"
  fi
  local -a cmd=("$KIT_ROOT/scripts/bootstrap_clawdbot_replica.sh" --mode "$bootstrap_mode" --target-root "$TARGET_ROOT" --report-json "$report_json")
  if [[ "$bootstrap_mode" == "apply" ]]; then
    cmd+=(--yes)
  fi
  run_quiet_command "${cmd[@]}"
}

run_smoke() {
  local report_json="$1"
  resolve_config_and_env || err "Could not auto-detect config. Pass --config explicitly."
  local -a cmd=("$KIT_ROOT/scripts/smoke_test_migration.sh" --config "$CONFIG_PATH" --report-json "$report_json")
  if [[ -n "$QUERY" ]]; then
    cmd+=(--query "$QUERY")
  fi
  run_quiet_command "${cmd[@]}"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

if [[ "$1" == "--mode" ]]; then
  [[ $# -ge 2 ]] || err "--mode requires an argument"
  MODE="$2"
  shift 2
else
  case "$1" in
    preflight|plan|replica|apply|smoke-test)
      MODE="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "First argument must be one of: preflight, plan, replica, apply, smoke-test"
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ -z "$MODE" ]] || err "Mode already set"
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
    --target-root)
      TARGET_ROOT="$2"
      shift 2
      ;;
    --migration-id)
      MIGRATION_ID="$2"
      shift 2
      ;;
    --report-dir)
      REPORT_DIR="$2"
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
    --query)
      QUERY="$2"
      shift 2
      ;;
    --print-json)
      PRINT_JSON=1
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

mkdir -p "$REPORT_DIR"

case "$MODE" in
  preflight)
    PREFLIGHT_REPORT="$(report_path_for preflight)"
    PREFLIGHT_PLAN_REPORT="$(report_path_for preflight-plan)"
    if run_preflight "$PREFLIGHT_REPORT" "$PREFLIGHT_PLAN_REPORT"; then
      emit_report "Preflight completed." "$PREFLIGHT_REPORT"
      exit 0
    else
      status=$?
      emit_report "Preflight failed." "$PREFLIGHT_REPORT"
      exit "$status"
    fi
    ;;
  plan)
    PLAN_REPORT="$(report_path_for plan)"
    run_plan "$PLAN_REPORT"
    python3 - "$PLAN_REPORT" <<'PY2'
import json, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as handle:
    raw = json.load(handle)
with open(path, 'w', encoding='utf-8') as handle:
    json.dump({'ok': True, 'mode': 'plan', 'plan': raw}, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY2
    emit_report "Plan completed." "$PLAN_REPORT"
    ;;
  replica)
    REPLICA_REPORT="$(report_path_for replica)"
    run_replica "$REPLICA_REPORT"
    REPLICA_MODE_VALUE="plan"
    if [[ "$YES" -eq 1 ]]; then
      REPLICA_MODE_VALUE="apply"
    fi
    python3 - "$REPLICA_REPORT" "$REPLICA_MODE_VALUE" <<'PY2'
import json, sys
path, replica_mode = sys.argv[1:3]
with open(path, 'r', encoding='utf-8') as handle:
    raw = json.load(handle)
with open(path, 'w', encoding='utf-8') as handle:
    json.dump({'ok': True, 'mode': 'replica', 'replica_mode': replica_mode, 'replica': raw}, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY2
    emit_report "Replica completed." "$REPLICA_REPORT"
    ;;
  apply)
    [[ "$YES" -eq 1 ]] || err "Apply requires --yes"
    PREFLIGHT_REPORT="$(report_path_for preflight)"
    PREFLIGHT_PLAN_REPORT="$(report_path_for preflight-plan)"
    if ! run_preflight "$PREFLIGHT_REPORT" "$PREFLIGHT_PLAN_REPORT"; then
      status=$?
      emit_report "Preflight failed." "$PREFLIGHT_REPORT"
      exit "$status"
    fi
    APPLY_REPORT="$(report_path_for apply)"
    run_converter_apply "$APPLY_REPORT"
    SMOKE_REPORT="$(report_path_for smoke-test)"
    APPLY_SUMMARY_REPORT="$(report_path_for apply-summary)"
    if ! run_smoke "$SMOKE_REPORT"; then
      status=$?
      python3 - "$APPLY_SUMMARY_REPORT" "$APPLY_REPORT" "$SMOKE_REPORT" <<'PY2'
import json, sys
summary_path, apply_path, smoke_path = sys.argv[1:4]
with open(apply_path, 'r', encoding='utf-8') as handle:
    apply_raw = json.load(handle)
with open(smoke_path, 'r', encoding='utf-8') as handle:
    smoke_raw = json.load(handle)
with open(summary_path, 'w', encoding='utf-8') as handle:
    json.dump({'ok': False, 'mode': 'apply', 'apply': apply_raw, 'smoke_test': smoke_raw}, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY2
      emit_report "Apply finished, but smoke test failed." "$APPLY_SUMMARY_REPORT"
      exit "$status"
    fi
    python3 - "$APPLY_SUMMARY_REPORT" "$APPLY_REPORT" "$SMOKE_REPORT" <<'PY2'
import json, sys
summary_path, apply_path, smoke_path = sys.argv[1:4]
with open(apply_path, 'r', encoding='utf-8') as handle:
    apply_raw = json.load(handle)
with open(smoke_path, 'r', encoding='utf-8') as handle:
    smoke_raw = json.load(handle)
with open(summary_path, 'w', encoding='utf-8') as handle:
    json.dump({'ok': True, 'mode': 'apply', 'apply': apply_raw, 'smoke_test': smoke_raw}, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY2
    emit_report "Apply completed." "$APPLY_SUMMARY_REPORT"
    ;;
  smoke-test)
    SMOKE_REPORT="$(report_path_for smoke-test)"
    run_smoke "$SMOKE_REPORT"
    python3 - "$SMOKE_REPORT" <<'PY2'
import json, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as handle:
    raw = json.load(handle)
with open(path, 'w', encoding='utf-8') as handle:
    json.dump({'ok': bool(raw.get('ok')), 'mode': 'smoke-test', 'smoke_test': raw}, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY2
    emit_report "Smoke test completed." "$SMOKE_REPORT"
    ;;
  *)
    err "Invalid mode: $MODE"
    ;;
esac
