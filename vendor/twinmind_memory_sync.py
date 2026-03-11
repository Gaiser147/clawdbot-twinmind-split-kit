#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Tuple

import requests


DEFAULT_API_BASE = "https://api.thirdear.live"
DEFAULT_FIREBASE_API_KEY = ""
DEFAULT_USER_AGENT = "TwinMind/1.0.64"
DEFAULT_RUNTIME_ROOT = Path("/root/.clawdbot")


def detect_runtime_root() -> Path:
    for key in ("TWINMIND_RUNTIME_ROOT", "CLAWDBOT_RUNTIME_ROOT"):
        raw = (os.getenv(key) or "").strip()
        if raw:
            return Path(raw).expanduser()
    cfg_path = (os.getenv("CLAWDBOT_CONFIG_PATH") or "").strip()
    if cfg_path:
        return Path(cfg_path).expanduser().parent
    return DEFAULT_RUNTIME_ROOT


RUNTIME_ROOT = detect_runtime_root()
ENV_PATHS = [
    str(RUNTIME_ROOT / ".env"),
    str(RUNTIME_ROOT.parent / ".env"),
    ".env",
]

STATE_DIR = RUNTIME_ROOT / "twinmind-orchestrator" / "memory"
INDEX_PATH = STATE_DIR / "index.json"
STATE_PATH = STATE_DIR / "state.json"
RAW_DIR = STATE_DIR / "raw"


def load_env_files(paths: List[str]) -> None:
    for path in paths:
        try:
            if not path or not os.path.exists(path):
                continue
            with open(path, "r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    key, value = line.split("=", 1)
                    key = key.strip()
                    value = value.strip().strip('"').strip("'")
                    if key and key not in os.environ:
                        os.environ[key] = value
        except Exception:
            continue


def getenv(name: str, default: str = "") -> str:
    value = os.getenv(name)
    if value is None or value == "":
        return default
    return value


def ensure_dirs() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    RAW_DIR.mkdir(parents=True, exist_ok=True)


def utc_iso_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def get_id_token(refresh_token: str, firebase_api_key: str) -> str:
    url = f"https://securetoken.googleapis.com/v1/token?key={firebase_api_key}"
    payload = {"grant_type": "refresh_token", "refresh_token": refresh_token}
    response = requests.post(url, data=payload, timeout=30)
    if response.status_code != 200:
        raise RuntimeError(f"Token refresh failed: {response.status_code} {response.text[:400]}")
    token = (response.json() or {}).get("id_token")
    if not token:
        raise RuntimeError("Token refresh failed: missing id_token")
    return str(token)


def post_get_memory(
    api_base: str,
    id_token: str,
    bypass: str,
    limit: int,
    offset: int,
    distinct_by_meeting: bool,
) -> Dict[str, Any]:
    url = f"{api_base}/api/v1/get_memory"
    headers = {
        "Authorization": f"Bearer {id_token}",
        "Content-Type": "application/json",
        "User-Agent": getenv("TWINMIND_USER_AGENT", DEFAULT_USER_AGENT),
    }
    if bypass:
        headers["x-vercel-protection-bypass"] = bypass

    payload = {
        "distinctByMeeting": bool(distinct_by_meeting),
        "limit": int(limit),
        "offset": int(offset),
    }
    response = requests.post(url, headers=headers, json=payload, timeout=60)
    if response.status_code != 200:
        raise RuntimeError(f"get_memory failed: {response.status_code} {response.text[:600]}")
    data = response.json()
    if not isinstance(data, dict):
        raise RuntimeError("get_memory returned non-object JSON")
    return data


def first_nonempty(*values: Any) -> str:
    for value in values:
        text = str(value or "").strip()
        if text:
            return text
    return ""


def text_hash(value: str) -> str:
    return hashlib.sha256((value or "").encode("utf-8", errors="ignore")).hexdigest()


def compact(value: str, max_len: int) -> str:
    text = (value or "").replace("\r", "\n")
    text = " ".join(text.split())
    if len(text) <= max_len:
        return text
    return text[: max_len - 3].rstrip() + "..."


def normalize_memory_item(item: Dict[str, Any]) -> Dict[str, Any]:
    summary = item.get("summary") or {}
    if not isinstance(summary, dict):
        summary = {}

    memory_id = first_nonempty(
        item.get("id"),
        item.get("_id"),
        item.get("memory_id"),
        item.get("meeting_id"),
        summary.get("meeting_id"),
    )

    title = first_nonempty(
        summary.get("meeting_title"),
        item.get("meeting_title"),
        item.get("title"),
    )
    summary_text = first_nonempty(
        summary.get("summary"),
        summary.get("summary_text"),
        item.get("summary"),
        item.get("memory"),
        item.get("text"),
    )
    transcript = first_nonempty(
        item.get("transcript"),
        summary.get("transcript"),
    )
    full_text = "\n\n".join([x for x in [summary_text, transcript] if x]).strip()

    start_time = first_nonempty(summary.get("start_time"), item.get("start_time"))
    end_time = first_nonempty(summary.get("end_time"), item.get("end_time"))
    updated_at = first_nonempty(
        item.get("updated_at"),
        item.get("created_at"),
        item.get("timestamp"),
        summary.get("updated_at"),
        start_time,
    )
    source = first_nonempty(summary.get("source"), item.get("source"), "twinmind")

    if not memory_id:
        seed = json.dumps(item, ensure_ascii=False, sort_keys=True)
        memory_id = text_hash(seed)[:24]

    return {
        "id": memory_id,
        "title": title or "Untitled",
        "summary": compact(summary_text, 1200),
        "text": compact(full_text, 12000),
        "start_time": start_time,
        "end_time": end_time,
        "updated_at": updated_at,
        "source": source,
        "fingerprint": text_hash(f"{title}\n{summary_text}\n{transcript}".lower()),
    }


def load_index() -> List[Dict[str, Any]]:
    if not INDEX_PATH.exists():
        return []
    try:
        data = json.loads(INDEX_PATH.read_text(encoding="utf-8"))
    except Exception:
        return []
    if not isinstance(data, list):
        return []
    out: List[Dict[str, Any]] = []
    for item in data:
        if isinstance(item, dict) and item.get("id"):
            out.append(item)
    return out


def save_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def run_sync(limit: int, max_pages: int, distinct_by_meeting: bool, write_raw: bool) -> Dict[str, Any]:
    refresh_token = getenv("TWINMIND_REFRESH_TOKEN")
    if not refresh_token:
        raise RuntimeError("Missing TWINMIND_REFRESH_TOKEN")

    api_base = getenv("TWINMIND_API_BASE", DEFAULT_API_BASE)
    firebase_api_key = getenv("TWINMIND_FIREBASE_API_KEY", DEFAULT_FIREBASE_API_KEY)
    bypass = getenv("TWINMIND_VERCEL_BYPASS")

    id_token = get_id_token(refresh_token, firebase_api_key)

    old_index = load_index()
    old_by_id = {str(item.get("id")): item for item in old_index if item.get("id")}

    merged: Dict[str, Dict[str, Any]] = {}
    raw_pages: List[Dict[str, Any]] = []

    pages = 0
    offset = 0
    while pages < max_pages:
        data = post_get_memory(
            api_base=api_base,
            id_token=id_token,
            bypass=bypass,
            limit=limit,
            offset=offset,
            distinct_by_meeting=distinct_by_meeting,
        )
        memories = data.get("memories") or []
        if not isinstance(memories, list):
            memories = []
        pages += 1

        if write_raw:
            raw_pages.append(
                {
                    "offset": offset,
                    "limit": limit,
                    "count": len(memories),
                    "data": data,
                }
            )

        for mem in memories:
            if not isinstance(mem, dict):
                continue
            norm = normalize_memory_item(mem)
            current = merged.get(norm["id"])
            if current is None:
                merged[norm["id"]] = norm
                continue
            if len(norm.get("text", "")) > len(current.get("text", "")):
                merged[norm["id"]] = norm

        if len(memories) < limit:
            break
        offset += limit

    new_index = sorted(
        merged.values(),
        key=lambda x: str(x.get("updated_at") or ""),
        reverse=True,
    )

    new_ids = []
    changed_ids = []
    for item in new_index:
        mid = str(item.get("id"))
        old_item = old_by_id.get(mid)
        if not old_item:
            new_ids.append(mid)
            continue
        if str(old_item.get("fingerprint") or "") != str(item.get("fingerprint") or ""):
            changed_ids.append(mid)

    removed_ids = sorted(set(old_by_id.keys()) - set(item.get("id") for item in new_index))

    save_json(INDEX_PATH, new_index)
    state = {
        "last_sync_at": utc_iso_now(),
        "count": len(new_index),
        "new_ids": new_ids,
        "changed_ids": changed_ids,
        "removed_ids": removed_ids,
        "pages": pages,
        "distinct_by_meeting": bool(distinct_by_meeting),
    }
    save_json(STATE_PATH, state)

    raw_path = ""
    if write_raw and raw_pages:
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S")
        raw_path_obj = RAW_DIR / f"{stamp}.json"
        save_json(raw_path_obj, raw_pages)
        raw_path = str(raw_path_obj)

    return {
        "ok": True,
        "count": len(new_index),
        "new": len(new_ids),
        "changed": len(changed_ids),
        "removed": len(removed_ids),
        "pages": pages,
        "index_path": str(INDEX_PATH),
        "state_path": str(STATE_PATH),
        "raw_path": raw_path,
    }


def main() -> None:
    load_env_files(ENV_PATHS)
    ensure_dirs()

    parser = argparse.ArgumentParser(description="Sync TwinMind memories to local index")
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--max-pages", type=int, default=10)
    parser.add_argument("--distinct-by-meeting", action="store_true")
    parser.add_argument("--raw", action="store_true", help="Store raw API pages in memory/raw")
    parser.add_argument("--json", action="store_true", help="Print JSON output")
    args = parser.parse_args()

    try:
        result = run_sync(
            limit=max(1, int(args.limit)),
            max_pages=max(1, int(args.max_pages)),
            distinct_by_meeting=bool(args.distinct_by_meeting),
            write_raw=bool(args.raw),
        )
    except Exception as exc:
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
            sys.exit(0)
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(result, ensure_ascii=False))
        return

    print(
        "Memory sync complete: "
        f"count={result['count']} new={result['new']} changed={result['changed']} "
        f"removed={result['removed']} pages={result['pages']}"
    )
    print(f"Index: {result['index_path']}")
    if result.get("raw_path"):
        print(f"Raw: {result['raw_path']}")


if __name__ == "__main__":
    main()
