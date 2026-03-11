#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH=""
REPORT_JSON=""
QUERY="Nutze Tool-Bridge und antworte exakt mit TEST_OK."
LOG_TIMEOUT_SEC=15
CONFIG_PATH_EXPLICIT=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --config <path>               Optional; auto-detects target config when omitted
  --report-json <path>          Optional; writes a machine-readable result report
  --query <text>                Optional custom smoke-test query
  --log-timeout-sec <seconds>   Default: 15
  --print-json                  Accepted for compatibility; output is JSON either way
  -h, --help
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

resolve_config() {
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
  if [[ "$CONFIG_PATH_EXPLICIT" -eq 1 ]]; then
    [[ -f "$CONFIG_PATH" ]] || return 1
    return 0
  fi
  for candidate in "${config_candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      CONFIG_PATH="$candidate"
      return 0
    fi
  done
  return 1
}

write_report() {
  local path="$1"
  local payload="$2"
  [[ -n "$path" ]] || return 0
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$payload" <<'PY'
import json, sys
path, payload = sys.argv[1:3]
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(json.loads(payload), handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
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
    --query)
      QUERY="$2"
      shift 2
      ;;
    --log-timeout-sec)
      LOG_TIMEOUT_SEC="$2"
      shift 2
      ;;
    --print-json)
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

if ! resolve_config; then
  write_report "$REPORT_JSON" '{"ok":false,"error":"Could not auto-detect config. Pass --config explicitly."}'
  exit 10
fi

RUN_JSON="$(python3 - "$CONFIG_PATH" "$QUERY" <<'PY'
import json, sys
cfg_path, query = sys.argv[1:3]
cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))
backend = (((cfg.get('agents') or {}).get('defaults') or {}).get('cliBackends') or {}).get('twinmind-cli')
if not isinstance(backend, dict):
    raise SystemExit('Missing agents.defaults.cliBackends.twinmind-cli')
command = backend.get('command')
args = backend.get('args')
if not isinstance(command, str) or not command:
    raise SystemExit('Backend command missing')
if not isinstance(args, list):
    raise SystemExit('Backend args missing')
runtime_root = cfg_path.rsplit('/', 1)[0]
print(json.dumps({
    'command': command,
    'args': args,
    'runtime_root': runtime_root,
    'invocation': [command, *args, query],
}, ensure_ascii=False))
PY
)" || {
  msg="Failed to read backend invocation from config: $CONFIG_PATH"
  PAYLOAD="$(python3 - "$CONFIG_PATH" "$msg" <<'PY'
import json, sys
cfg, msg = sys.argv[1:3]
print(json.dumps({
  'ok': False,
  'config': cfg,
  'error': msg,
}, ensure_ascii=False))
PY
)"
  write_report "$REPORT_JSON" "$PAYLOAD"
  exit 11
}

RUNTIME_ROOT="$(python3 - "$RUN_JSON" <<'PY'
import json, sys
print(json.loads(sys.argv[1])['runtime_root'])
PY
)"
LOG_DIR="$RUNTIME_ROOT/twinmind-orchestrator/logs"
mkdir -p "$LOG_DIR"
START_TS="$(date +%s)"
STDOUT_CAPTURE="$(mktemp)"
STDERR_CAPTURE="$(mktemp)"
trap 'rm -f "$STDOUT_CAPTURE" "$STDERR_CAPTURE"' EXIT

set +e
python3 - "$RUN_JSON" <<'PY' >"$STDOUT_CAPTURE" 2>"$STDERR_CAPTURE"
import json, subprocess, sys
run = json.loads(sys.argv[1])
subprocess.run(run['invocation'], check=False)
PY
BACKEND_EXIT=$?
set -e

LATEST_LOG=""
for _ in $(seq 1 "$LOG_TIMEOUT_SEC"); do
  LATEST_LOG="$(python3 - "$LOG_DIR" "$START_TS" <<'PY'
import sys
from pathlib import Path
log_dir = Path(sys.argv[1])
start_ts = float(sys.argv[2])
best = None
best_mtime = -1.0
if log_dir.exists():
    for path in log_dir.glob('*.jsonl'):
        try:
            mtime = path.stat().st_mtime
        except FileNotFoundError:
            continue
        if mtime >= start_ts and mtime > best_mtime:
            best = path
            best_mtime = mtime
print(str(best) if best else '')
PY
)"
  if [[ -n "$LATEST_LOG" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$LATEST_LOG" ]]; then
  PAYLOAD="$(python3 - "$CONFIG_PATH" "$RUNTIME_ROOT" "$STDOUT_CAPTURE" "$STDERR_CAPTURE" "$BACKEND_EXIT" <<'PY'
import json, pathlib, sys
cfg, runtime_root, stdout_path, stderr_path, exit_code = sys.argv[1:6]
stdout = pathlib.Path(stdout_path).read_text(encoding='utf-8', errors='replace')
stderr = pathlib.Path(stderr_path).read_text(encoding='utf-8', errors='replace')
print(json.dumps({
  'ok': False,
  'config': cfg,
  'runtime_root': runtime_root,
  'backend_exit_code': int(exit_code),
  'error': 'No new wrapper log file appeared after backend execution.',
  'stdout': stdout,
  'stderr': stderr,
}, ensure_ascii=False))
PY
)"
  write_report "$REPORT_JSON" "$PAYLOAD"
  echo "$PAYLOAD" | python3 -m json.tool
  exit 21
fi

PAYLOAD="$(python3 - "$CONFIG_PATH" "$RUNTIME_ROOT" "$LATEST_LOG" "$STDOUT_CAPTURE" "$STDERR_CAPTURE" "$BACKEND_EXIT" <<'PY'
import json, pathlib, sys
cfg, runtime_root, log_path, stdout_path, stderr_path, exit_code = sys.argv[1:7]
stdout = pathlib.Path(stdout_path).read_text(encoding='utf-8', errors='replace')
stderr = pathlib.Path(stderr_path).read_text(encoding='utf-8', errors='replace')
entries = []
for line in pathlib.Path(log_path).read_text(encoding='utf-8', errors='replace').splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        entries.append(json.loads(line))
    except Exception:
        continue
router_decisions = [e for e in entries if e.get('event') == 'router_decision']
routes = [str(e.get('route') or '') for e in router_decisions]
executor_requests = [e for e in entries if e.get('event') == 'executor_request']
executor_responses = [e for e in entries if e.get('event') == 'executor_response']
finals = [e for e in entries if e.get('event') in {'final', 'final_after_skill_run'}]
ok = bool(executor_requests and executor_responses and finals and any(r in {'tool_bridge_override', 'split_executor_bridge'} for r in routes))
provider = ''
model = ''
if executor_requests:
    last = executor_requests[-1]
    provider = str(last.get('provider') or '')
    model = str(last.get('model') or '')
result = {
  'ok': ok,
  'config': cfg,
  'runtime_root': runtime_root,
  'log_path': log_path,
  'backend_exit_code': int(exit_code),
  'routes': routes,
  'executor_request_count': len(executor_requests),
  'executor_response_count': len(executor_responses),
  'final_event_count': len(finals),
  'provider': provider,
  'model': model,
  'stdout': stdout,
  'stderr': stderr,
}
if not ok:
    result['error'] = 'Missing one or more expected log signals: split route, executor_request, executor_response, final.'
print(json.dumps(result, ensure_ascii=False))
PY
)"

write_report "$REPORT_JSON" "$PAYLOAD"
echo "$PAYLOAD" | python3 -m json.tool
python3 - "$PAYLOAD" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
sys.exit(0 if obj.get('ok') else 24)
PY
