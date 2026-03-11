#!/usr/bin/env bash
set -euo pipefail

MODE="plan"
TARGET_ROOT="/root/.clawdbot-replica"
SOURCE_KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_JSON=""
YES=0
WRITE_ENV_TEMPLATE=1
WRITE_CLAWDBOT_CONFIG=1
RUNTIME_VENDOR_FILES=(
  "twinmind_orchestrator.py"
  "twinmind_memory_sync.py"
  "twinmind_memory_query.py"
)

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --mode plan|apply                 Default: plan
  --target-root <path>              Default: /root/.clawdbot-replica
  --source-kit <path>               Default: script parent directory
  --report-json <path>              Default: <source-kit>/reports/bootstrap-<ts>.json
  --write-env-template 0|1          Default: 1
  --write-clawdbot-config 0|1       Default: 1
  --yes                             Required for apply
  -h, --help
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

ts_compact() {
  date -u +"%Y%m%dT%H%M%SZ"
}

verify_runtime_sources() {
  local vendor_file
  for vendor_file in "${RUNTIME_VENDOR_FILES[@]}"; do
    [[ -f "$SOURCE_KIT/vendor/$vendor_file" ]] || err "Missing vendor file: $SOURCE_KIT/vendor/$vendor_file"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --target-root)
      TARGET_ROOT="$2"
      shift 2
      ;;
    --source-kit)
      SOURCE_KIT="$2"
      shift 2
      ;;
    --report-json)
      REPORT_JSON="$2"
      shift 2
      ;;
    --write-env-template)
      WRITE_ENV_TEMPLATE="$2"
      shift 2
      ;;
    --write-clawdbot-config)
      WRITE_CLAWDBOT_CONFIG="$2"
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
  plan|apply) ;;
  *) err "Invalid --mode: $MODE" ;;
esac

if [[ -z "$REPORT_JSON" ]]; then
  mkdir -p "$SOURCE_KIT/reports"
  REPORT_JSON="$SOURCE_KIT/reports/bootstrap-$(ts_compact).json"
fi

VENDOR_DIR="$SOURCE_KIT/vendor"
verify_runtime_sources

TARGET_RUNTIME_DIR="$TARGET_ROOT/clawd/skills/twinmind-orchestrator/scripts"
TARGET_RUNTIME_SCRIPT="$TARGET_RUNTIME_DIR/twinmind_orchestrator.py"
TARGET_CLAWDBOT_DIR="$TARGET_ROOT/.clawdbot"
TARGET_CONFIG="$TARGET_CLAWDBOT_DIR/clawdbot.json"
TARGET_ENV_EXAMPLE="$TARGET_CLAWDBOT_DIR/.env.example"

python3 - "$REPORT_JSON" "$MODE" "$TARGET_ROOT" "$TARGET_RUNTIME_DIR" "$TARGET_RUNTIME_SCRIPT" "$TARGET_CONFIG" "$TARGET_ENV_EXAMPLE" "$WRITE_ENV_TEMPLATE" "$WRITE_CLAWDBOT_CONFIG" <<'PY'
import json, sys, datetime
(
  report_path,
  mode,
  target_root,
  target_runtime_dir,
  target_runtime_script,
  target_config,
  target_env_example,
  write_env,
  write_cfg,
) = sys.argv[1:10]
report = {
  "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "mode": mode,
  "target_root": target_root,
  "target_runtime_dir": target_runtime_dir,
  "target_runtime_script": target_runtime_script,
  "runtime_vendor_files": [
    "twinmind_orchestrator.py",
    "twinmind_memory_sync.py",
    "twinmind_memory_query.py",
  ],
  "actions": [
    {"type": "mkdir", "path": target_runtime_dir},
    {"type": "copy", "src": "vendor/twinmind_orchestrator.py", "dst": f"{target_runtime_dir}/twinmind_orchestrator.py"},
    {"type": "copy", "src": "vendor/twinmind_memory_sync.py", "dst": f"{target_runtime_dir}/twinmind_memory_sync.py"},
    {"type": "copy", "src": "vendor/twinmind_memory_query.py", "dst": f"{target_runtime_dir}/twinmind_memory_query.py"},
  ],
  "write_env_template": bool(int(write_env)),
  "write_clawdbot_config": bool(int(write_cfg)),
}
if bool(int(write_cfg)):
  report["actions"].append({"type": "write", "path": target_config})
if bool(int(write_env)):
  report["actions"].append({"type": "write", "path": target_env_example})
with open(report_path, "w", encoding="utf-8") as f:
  json.dump(report, f, ensure_ascii=False, indent=2)
  f.write("\n")
PY

if [[ "$MODE" == "plan" ]]; then
  echo "Plan completed."
  echo "Report: $REPORT_JSON"
  exit 0
fi

[[ "$YES" -eq 1 ]] || err "Apply requires --yes"

mkdir -p "$TARGET_RUNTIME_DIR" "$TARGET_CLAWDBOT_DIR"
for vendor_file in "${RUNTIME_VENDOR_FILES[@]}"; do
  cp "$VENDOR_DIR/$vendor_file" "$TARGET_RUNTIME_DIR/$vendor_file"
done

if [[ "$WRITE_CLAWDBOT_CONFIG" == "1" ]]; then
  python3 - "$TARGET_CONFIG" "$TARGET_ROOT" <<'PY'
import json, os, sys
cfg_path, target_root = sys.argv[1:3]
workspace = os.path.join(target_root, "clawd")
orch = os.path.join(target_root, "clawd", "skills", "twinmind-orchestrator", "scripts", "twinmind_orchestrator.py")

cfg = {
  "models": {"mode": "merge"},
  "agents": {
    "defaults": {
      "workspace": workspace,
      "model": {
        "primary": "twinmind-cli/default",
        "fallbacks": ["openai-codex/gpt-5.2"]
      },
      "models": {
        "twinmind-cli/default": {"alias": "tm"},
        "openai-codex/gpt-5.2": {}
      },
      "cliBackends": {
        "twinmind-cli": {
          "command": "python3",
          "args": [
            orch,
            "--runtime-root", os.path.join(target_root, ".clawdbot"),
            "--workspace-root", workspace,
            "--mode", "conversation",
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
            "--executor-use-twinmind-planner", "1"
          ],
          "output": "json",
          "input": "arg",
          "sessionArg": "--session-id",
          "sessionMode": "always",
          "serialize": True
        }
      }
    }
  }
}

with open(cfg_path, "w", encoding="utf-8") as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")
PY
fi

if [[ "$WRITE_ENV_TEMPLATE" == "1" ]]; then
  cat > "$TARGET_ENV_EXAMPLE" <<'ENVEOF'
# Required for TwinMind wrapper
TWINMIND_REFRESH_TOKEN=__REQUIRED__

# Optional TwinMind API settings
TWINMIND_FIREBASE_API_KEY=__REQUIRED__
# TWINMIND_API_BASE=https://api.thirdear.live
# TWINMIND_VERCEL_BYPASS=__OPTIONAL__
# TWINMIND_USER_AGENT=TwinMind/1.0.64

# Split/executor defaults
ORCH_ROUTING_MODE=strict_split
ORCH_EXECUTOR_PROVIDER=codex_cli
ORCH_EXECUTOR_MODEL=gpt-5.3-codex
ORCH_EXECUTOR_REASONING_EFFORT=medium
ORCH_EXECUTOR_USE_TWINMIND_PLANNER=1

# Optional non-codex executor auth
# ORCH_EXECUTOR_API_KEY=__OPTIONAL__
ENVEOF
fi

cat > "$TARGET_ROOT/README.replica.md" <<REPLICA
# Clawdbot Replica (Split + TwinMind Wrapper)

This directory is generated by:
- $0

Contents:
- clawd/skills/twinmind-orchestrator/scripts/*
- .clawdbot/clawdbot.json
- .clawdbot/.env.example

This is a template/replica. Secrets are placeholders and must be set manually.
REPLICA

echo "Replica apply completed."
echo "Report: $REPORT_JSON"
