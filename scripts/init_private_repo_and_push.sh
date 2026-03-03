#!/usr/bin/env bash
set -euo pipefail

OWNER=""
REPO="clawdbot-twinmind-split-kit"
BRANCH="main"
AUTH_MODE="ssh"
DRY_RUN=1

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --owner <github-user-or-org>      Required
  --repo <name>                     Default: clawdbot-twinmind-split-kit
  --branch <name>                   Default: main
  --auth-mode ssh|pat               Default: ssh
  --dry-run 0|1                     Default: 1
  -h, --help

Flow:
  1) Create private repository
  2) Initialize local git repo (if needed)
  3) Commit current kit
  4) Safe push with secret scan
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      OWNER="$2"; shift 2 ;;
    --repo)
      REPO="$2"; shift 2 ;;
    --branch)
      BRANCH="$2"; shift 2 ;;
    --auth-mode)
      AUTH_MODE="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "Unknown argument: $1" ;;
  esac
done

[[ -n "$OWNER" ]] || err "--owner is required"

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREATE_SCRIPT="$KIT_ROOT/scripts/create_private_github_repo.sh"
PUSH_SCRIPT="$KIT_ROOT/scripts/safe_push.sh"

[[ -x "$CREATE_SCRIPT" ]] || err "Missing executable: $CREATE_SCRIPT"
[[ -x "$PUSH_SCRIPT" ]] || err "Missing executable: $PUSH_SCRIPT"

if [[ "$AUTH_MODE" == "ssh" ]]; then
  REMOTE_URL="git@github.com:${OWNER}/${REPO}.git"
else
  REMOTE_URL="https://github.com/${OWNER}/${REPO}.git"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[dry-run] $CREATE_SCRIPT --owner $OWNER --repo $REPO --visibility private --auth-mode $AUTH_MODE --dry-run"
  echo "[dry-run] cd $KIT_ROOT && git init && git add . && git commit -m 'Initial twinmind split kit'"
  echo "[dry-run] $PUSH_SCRIPT --remote $REMOTE_URL --branch $BRANCH"
  exit 0
fi

"$CREATE_SCRIPT" --owner "$OWNER" --repo "$REPO" --visibility private --auth-mode "$AUTH_MODE"

cd "$KIT_ROOT"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init
fi

if [[ -n "$(git status --porcelain)" ]]; then
  git add .
  git commit -m "Initial twinmind split kit"
fi

"$PUSH_SCRIPT" --remote "$REMOTE_URL" --branch "$BRANCH"
