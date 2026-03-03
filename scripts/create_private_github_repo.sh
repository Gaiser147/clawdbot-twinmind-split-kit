#!/usr/bin/env bash
set -euo pipefail

OWNER=""
OWNER_TYPE="auto"
REPO="clawdbot-twinmind-split-kit"
VISIBILITY="private"
AUTH_MODE="ssh"
TOKEN_ENV="GITHUB_TOKEN"
DRY_RUN=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --owner <github-user-or-org>      Required
  --owner-type user|org|auto        Default: auto
  --repo <name>                     Default: clawdbot-twinmind-split-kit
  --visibility private|public        Default: private
  --auth-mode ssh|pat                Default: ssh
  --token-env <ENV_NAME>             Default: GITHUB_TOKEN
  --dry-run
  -h, --help

Behavior:
  - Uses GitHub CLI (gh) if available and authenticated.
  - Falls back to GitHub REST API with token from --token-env.
  - Never stores credentials in files.
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
    --owner-type)
      OWNER_TYPE="$2"; shift 2 ;;
    --repo)
      REPO="$2"; shift 2 ;;
    --visibility)
      VISIBILITY="$2"; shift 2 ;;
    --auth-mode)
      AUTH_MODE="$2"; shift 2 ;;
    --token-env)
      TOKEN_ENV="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "Unknown argument: $1" ;;
  esac
done

[[ -n "$OWNER" ]] || err "--owner is required"
[[ "$VISIBILITY" == "private" || "$VISIBILITY" == "public" ]] || err "Invalid --visibility"
[[ "$AUTH_MODE" == "ssh" || "$AUTH_MODE" == "pat" ]] || err "Invalid --auth-mode"
[[ "$OWNER_TYPE" == "user" || "$OWNER_TYPE" == "org" || "$OWNER_TYPE" == "auto" ]] || err "Invalid --owner-type"

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    GH_CMD=(gh repo create "${OWNER}/${REPO}" "--${VISIBILITY}" --confirm)
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] ${GH_CMD[*]}"
    else
      "${GH_CMD[@]}"
    fi

    if [[ "$AUTH_MODE" == "ssh" ]]; then
      echo "Remote URL: git@github.com:${OWNER}/${REPO}.git"
    else
      echo "Remote URL: https://github.com/${OWNER}/${REPO}.git"
    fi
    exit 0
  fi
fi

TOKEN="${!TOKEN_ENV:-}"
[[ -n "$TOKEN" ]] || err "GitHub token not found in env var: $TOKEN_ENV"

API_URL=""
if [[ "$OWNER_TYPE" == "org" ]]; then
  API_URL="https://api.github.com/orgs/${OWNER}/repos"
elif [[ "$OWNER_TYPE" == "user" ]]; then
  API_URL="https://api.github.com/user/repos"
else
  API_URL="https://api.github.com/orgs/${OWNER}/repos"
fi

PAYLOAD_ORG="{\"name\":\"${REPO}\",\"private\":$([[ "$VISIBILITY" == "private" ]] && echo true || echo false)}"
PAYLOAD_USER="$PAYLOAD_ORG"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] curl -X POST $API_URL (token via $TOKEN_ENV)"
  echo "[dry-run] fallback API if org endpoint fails: https://api.github.com/user/repos"
else
  STATUS=$(curl -sS -o /tmp/tm_repo_create_resp.json -w "%{http_code}" \
    -X POST "$API_URL" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$PAYLOAD_ORG")

  if [[ "$STATUS" != "201" ]]; then
    STATUS2=$(curl -sS -o /tmp/tm_repo_create_resp.json -w "%{http_code}" \
      -X POST "https://api.github.com/user/repos" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$PAYLOAD_USER")
    [[ "$STATUS2" == "201" ]] || {
      cat /tmp/tm_repo_create_resp.json >&2
      err "GitHub API create failed (status $STATUS/$STATUS2)"
    }
  fi
fi

if [[ "$AUTH_MODE" == "ssh" ]]; then
  echo "Remote URL: git@github.com:${OWNER}/${REPO}.git"
else
  echo "Remote URL: https://github.com/${OWNER}/${REPO}.git"
fi
