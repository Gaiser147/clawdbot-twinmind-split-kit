#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List


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


INDEX_PATH = detect_runtime_root() / "twinmind-orchestrator" / "memory" / "index.json"


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


def tokenize(text: str) -> List[str]:
    toks = re.findall(r"[a-zA-Z0-9äöüÄÖÜß]{3,}", (text or "").lower())
    # preserve order, remove duplicates
    seen = set()
    out: List[str] = []
    for tok in toks:
        if tok in seen:
            continue
        seen.add(tok)
        out.append(tok)
    return out


def score_item(query: str, tokens: List[str], item: Dict[str, Any]) -> int:
    hay = "\n".join(
        [
            str(item.get("title") or ""),
            str(item.get("summary") or ""),
            str(item.get("text") or ""),
        ]
    ).lower()
    score = 0
    q = (query or "").lower().strip()
    if q and q in hay:
        score += 100
    for tok in tokens:
        if tok in hay:
            score += 12
    # slight preference for newer entries when scores tie
    updated = str(item.get("updated_at") or "")
    if updated:
        score += 1
    return score


def cmd_search(query: str, limit: int, as_json: bool) -> int:
    index = load_index()
    if not index:
        msg = "No indexed memories found. Run twinmind_memory_sync.py first."
        if as_json:
            print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False))
            return 0
        print(msg, file=sys.stderr)
        return 1

    tokens = tokenize(query)
    ranked: List[Dict[str, Any]] = []
    for item in index:
        score = score_item(query, tokens, item)
        if score <= 0:
            continue
        ranked.append({"score": score, "item": item})
    ranked.sort(key=lambda x: (int(x["score"]), str((x["item"] or {}).get("updated_at") or "")), reverse=True)
    picked = ranked[: max(1, int(limit))]

    if as_json:
        out = []
        for entry in picked:
            item = entry["item"]
            out.append(
                {
                    "score": entry["score"],
                    "id": item.get("id"),
                    "title": item.get("title"),
                    "summary": item.get("summary"),
                    "updated_at": item.get("updated_at"),
                }
            )
        print(json.dumps({"ok": True, "query": query, "results": out}, ensure_ascii=False))
        return 0

    if not picked:
        print("No matching memories found.")
        return 0

    print(f"Matches for: {query}")
    for entry in picked:
        item = entry["item"]
        print(f"- [{entry['score']}] {item.get('id')} | {item.get('title')}")
        if item.get("updated_at"):
            print(f"  updated: {item.get('updated_at')}")
        summary = str(item.get("summary") or "").strip()
        if summary:
            print(f"  summary: {summary[:280]}")
    return 0


def cmd_get(memory_id: str, as_json: bool) -> int:
    index = load_index()
    if not index:
        msg = "No indexed memories found. Run twinmind_memory_sync.py first."
        if as_json:
            print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False))
            return 0
        print(msg, file=sys.stderr)
        return 1

    target = (memory_id or "").strip()
    found = None
    for item in index:
        if str(item.get("id") or "") == target:
            found = item
            break

    if not found:
        if as_json:
            print(json.dumps({"ok": False, "error": f"Memory id not found: {target}"}, ensure_ascii=False))
            return 0
        print(f"Memory id not found: {target}", file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps({"ok": True, "memory": found}, ensure_ascii=False))
        return 0

    print(f"id: {found.get('id')}")
    print(f"title: {found.get('title')}")
    if found.get("updated_at"):
        print(f"updated_at: {found.get('updated_at')}")
    if found.get("start_time") or found.get("end_time"):
        print(f"time: {found.get('start_time') or ''} -> {found.get('end_time') or ''}".strip())
    print("")
    print(found.get("text") or found.get("summary") or "")
    return 0


def cmd_list(limit: int, as_json: bool) -> int:
    index = load_index()
    items = index[: max(1, int(limit))]
    if as_json:
        print(json.dumps({"ok": True, "count": len(items), "items": items}, ensure_ascii=False))
        return 0
    if not items:
        print("No indexed memories found.")
        return 0
    for item in items:
        print(f"- {item.get('id')} | {item.get('title')} | {item.get('updated_at') or ''}")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Query local TwinMind memory index")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_search = sub.add_parser("search", help="Search local memory index")
    p_search.add_argument("--query", required=True)
    p_search.add_argument("--limit", type=int, default=5)
    p_search.add_argument("--json", action="store_true")

    p_get = sub.add_parser("get", help="Get one memory by id")
    p_get.add_argument("--id", required=True)
    p_get.add_argument("--json", action="store_true")

    p_list = sub.add_parser("list", help="List indexed memories")
    p_list.add_argument("--limit", type=int, default=20)
    p_list.add_argument("--json", action="store_true")

    args = parser.parse_args()
    if args.cmd == "search":
        sys.exit(cmd_search(args.query, args.limit, bool(args.json)))
    if args.cmd == "get":
        sys.exit(cmd_get(args.id, bool(args.json)))
    if args.cmd == "list":
        sys.exit(cmd_list(args.limit, bool(args.json)))
    sys.exit(2)


if __name__ == "__main__":
    main()
