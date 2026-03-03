#!/usr/bin/env bash
set -euo pipefail

REMOTE_URL=""
BRANCH="main"
SCAN_SECRETS=1
BLOCK_ON_FINDINGS=1
ALLOW_DIRTY=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --remote <git-url>                Optional: set origin URL before push
  --branch <name>                   Default: main
  --scan-secrets 0|1                Default: 1
  --block-on-findings 0|1           Default: 1
  --allow-dirty 0|1                 Default: 0
  -h, --help
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      REMOTE_URL="$2"; shift 2 ;;
    --branch)
      BRANCH="$2"; shift 2 ;;
    --scan-secrets)
      SCAN_SECRETS="$2"; shift 2 ;;
    --block-on-findings)
      BLOCK_ON_FINDINGS="$2"; shift 2 ;;
    --allow-dirty)
      ALLOW_DIRTY="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "Unknown argument: $1" ;;
  esac
done

command -v git >/dev/null 2>&1 || err "git is required"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || err "Run this inside a git repository"

if [[ "$ALLOW_DIRTY" != "1" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    err "Working tree is dirty. Commit or stash before safe push, or use --allow-dirty 1"
  fi
fi

if [[ "$SCAN_SECRETS" == "1" ]]; then
  TMP_FINDINGS="$(mktemp)"
  trap 'rm -f "$TMP_FINDINGS"' EXIT

  mapfile -t tracked_files < <(git ls-files)
  if [[ "${#tracked_files[@]}" -gt 0 ]]; then
    rg -n -S \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'AIza[0-9A-Za-z\-_]{35}' \
      -e 'sk-[A-Za-z0-9]{20,}' \
      -e 'ghp_[A-Za-z0-9]{36}' \
      -e 'github_pat_[A-Za-z0-9_]+' \
      -e '-----BEGIN (RSA|EC|OPENSSH|DSA) PRIVATE KEY-----' \
      -e 'xox[baprs]-[A-Za-z0-9-]+' \
      -e 'Bearer [A-Za-z0-9._-]{20,}' \
      -e '(?i)(api[_-]?key|token|secret|password)["'"'"'[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9._-]{16,}["'"'"']' \
      -- "${tracked_files[@]}" > "$TMP_FINDINGS" || true
  fi

  if [[ -s "$TMP_FINDINGS" ]]; then
    echo "Potential secret findings:" >&2
    cat "$TMP_FINDINGS" >&2
    if [[ "$BLOCK_ON_FINDINGS" == "1" ]]; then
      err "Secret scan failed"
    fi
  fi
fi

if [[ -n "$REMOTE_URL" ]]; then
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE_URL"
  else
    git remote add origin "$REMOTE_URL"
  fi
fi

git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || git branch "$BRANCH"

git push -u origin "$BRANCH"

echo "Safe push completed."
