#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH=""
PRINT_JSON=0
REPORT_JSON=""
CONFIG_PATH_EXPLICIT=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --config <path>       Optional; auto-detects when omitted
  --report-json <path>  Optional; write the JSON report to this path
  --print-json          Print JSON only
  -h, --help
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

write_json_report() {
  local path="$1"
  local payload="$2"
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$payload" <<'PY'
import json, sys
path, payload = sys.argv[1:3]
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(json.loads(payload), handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
}

resolve_config() {
  local home_root="${HOME:-/root}"
  local -a candidates=(
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
  local candidate=""

  if [[ "$CONFIG_PATH_EXPLICIT" -eq 1 ]]; then
    [[ -f "$CONFIG_PATH" ]] || err "Config not found: $CONFIG_PATH"
    return 0
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      CONFIG_PATH="$candidate"
      return 0
    fi
  done
  err "Could not auto-detect config. Pass --config explicitly."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="$2"
      CONFIG_PATH_EXPLICIT=1
      shift 2
      ;;
    --report-json)
      REPORT_JSON="$2"
      shift 2
      ;;
    --print-json)
      PRINT_JSON=1
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

resolve_config

PAYLOAD="$(python3 - "$CONFIG_PATH" "$KIT_ROOT/vendor" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

config_path, vendor_dir = sys.argv[1:3]
vendor_dir = Path(vendor_dir)
runtime_files = [
    "twinmind_orchestrator.py",
    "twinmind_memory_sync.py",
    "twinmind_memory_query.py",
]

def sha(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

result = {
    "managed_install": False,
    "config_path": config_path,
    "runtime_root": "",
    "workspace_root": "",
    "runtime_dir": "",
    "runtime_script": "",
    "backend_command": "",
    "backend_mode": "",
    "target_app_root": "",
    "installed_checksums": {},
    "vendor_checksums": {},
    "changed_runtime_files": [],
    "missing_runtime_files": [],
    "update_available": False,
    "warnings": [],
    "errors": [],
    "reason": "",
}

try:
    with open(config_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    result["reason"] = "config_not_found"
    result["errors"].append(f"Config not found: {config_path}")
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0)
except json.JSONDecodeError as exc:
    result["reason"] = "invalid_json"
    result["errors"].append(f"Invalid JSON: {exc}")
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0)

if not isinstance(data, dict):
    result["reason"] = "invalid_root"
    result["errors"].append("Config root must be a JSON object")
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0)

backend = (
    data.get("agents", {})
    .get("defaults", {})
    .get("cliBackends", {})
    .get("twinmind-cli")
)
if not isinstance(backend, dict):
    result["reason"] = "missing_twinmind_backend"
    result["errors"].append("agents.defaults.cliBackends.twinmind-cli missing or not an object")
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0)

result["backend_command"] = str(backend.get("command") or "")
args = backend.get("args")
if not isinstance(args, list):
    result["reason"] = "invalid_backend_args"
    result["errors"].append("twinmind-cli.args must be a list")
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0)

def value_after(flag: str) -> str:
    for idx, item in enumerate(args):
        if str(item) == flag and idx + 1 < len(args):
            return str(args[idx + 1])
    return ""

runtime_script = ""
for item in args:
    sval = str(item or "")
    if sval.endswith("twinmind_orchestrator.py"):
        runtime_script = sval
        break

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
runtime_root_ok = bool(result["runtime_root"])
workspace_root_ok = bool(result["workspace_root"])
if not command_ok:
    result["errors"].append("twinmind-cli command is not a python executable")
if not runtime_ok:
    result["errors"].append("twinmind_orchestrator.py missing from backend args")
if not runtime_root_ok:
    result["errors"].append("--runtime-root missing from backend args")
if not workspace_root_ok:
    result["errors"].append("--workspace-root missing from backend args")

runtime_dir = Path(result["runtime_dir"]) if result["runtime_dir"] else None
for name in runtime_files:
    vp = vendor_dir / name
    result["vendor_checksums"][name] = sha(vp) if vp.exists() else ""
    if runtime_dir:
        rp = runtime_dir / name
        if rp.exists():
            result["installed_checksums"][name] = sha(rp)
            if result["installed_checksums"][name] != result["vendor_checksums"][name]:
                result["changed_runtime_files"].append(name)
        else:
            result["installed_checksums"][name] = ""
            result["missing_runtime_files"].append(name)
            result["changed_runtime_files"].append(name)
    else:
        result["installed_checksums"][name] = ""
        result["missing_runtime_files"].append(name)

if runtime_dir and runtime_dir.exists():
    result["managed_install"] = command_ok and runtime_ok and runtime_root_ok and workspace_root_ok and not result["missing_runtime_files"]
else:
    if runtime_ok:
        result["errors"].append(f"Runtime directory not found: {result['runtime_dir']}")

result["update_available"] = bool(result["changed_runtime_files"])
if result["managed_install"]:
    result["reason"] = "managed_install"
else:
    result["reason"] = result["errors"][0] if result["errors"] else "not_twinmind_managed"
print(json.dumps(result, ensure_ascii=False))
PY
)"

if [[ -n "$REPORT_JSON" ]]; then
  write_json_report "$REPORT_JSON" "$PAYLOAD"
fi

if [[ "$PRINT_JSON" -eq 1 ]]; then
  printf '%s\n' "$PAYLOAD"
else
  python3 - "$PAYLOAD" <<'PY'
import json, sys
report = json.loads(sys.argv[1])
print(json.dumps(report, ensure_ascii=False, indent=2))
PY
fi

STATUS="$(python3 - "$PAYLOAD" <<'PY'
import json, sys
report = json.loads(sys.argv[1])
print(0 if report.get("managed_install") else 2)
PY
)"
exit "$STATUS"
