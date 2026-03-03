#!/usr/bin/env python3
"""
TwinMind Orchestrator

Two operating modes:
  - conversation (default): normal TwinMind chat responses (no forced JSON protocol)
  - tool_bridge: deterministic JSON wrapper loop with local tool execution

The default conversation mode avoids prompt/protocol collisions that can lead
to "Declined" or non-JSON failures in gateway usage.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import requests


DEFAULT_API_BASE = "https://api.thirdear.live"
DEFAULT_ENDPOINT = "/api/py/twinmind/chrome"
DEFAULT_FIREBASE_API_KEY = ""
DEFAULT_USER_AGENT = "TwinMind/1.0.64"
BRAVE_SEARCH_URL = "https://api.search.brave.com/res/v1/web/search"
DEFAULT_EXECUTOR_PROVIDER = "codex_cli"
DEFAULT_EXECUTOR_MODEL = "gpt-5.3-codex"
DEFAULT_EXECUTOR_BASE_URL = "https://api.openai.com/v1"
AUTH_PROFILE_PATHS = [
    "/root/.clawdbot/agents/main/agent/auth-profiles.json",
    "/root/.codex/auth-profiles.json",
]

STATE_DIR = Path("/root/.clawdbot/twinmind-orchestrator")
LOCK_PATH = STATE_DIR / "run.lock"
SESSIONS_PATH = STATE_DIR / "sessions.json"
LOG_DIR = STATE_DIR / "logs"
MEMORY_DIR = STATE_DIR / "memory"
MEMORY_INDEX_PATH = MEMORY_DIR / "index.json"
MEMORY_STATE_PATH = MEMORY_DIR / "state.json"

ENV_PATHS = [
    "/root/.clawdbot/.env",
    "/root/.env",
    ".env",
]

HEARTBEAT_PATHS = [
    "/root/clawd/HEARTBEAT.md",
    "/root/HEARTBEAT.md",
    "HEARTBEAT.md",
]

LOCAL_PROFILE_PATHS = [
    "/root/.clawdbot/twinmind-profile.local.json",
    "/root/.clawdbot/twinmind-profile.local.txt",
]
PERSONAL_MEMORY_PIPELINE = "/root/.clawdbot/scripts/personal-memory-pipeline.py"

TOOL_EXPLICIT_RE = re.compile(
    r"\b(tool|tools|toolcall|tool call|skill_run|shell|read_file|terminal|command|befehl|datei|file|ls|cat|rg|grep|bash)\b",
    re.I,
)
TOOL_ACTION_RE = re.compile(
    r"\b(zeige|list|liste|prüf|pruef|check|hol|fetch|lese|read|öffne|oeffne|open|suche|search|sende|send|erstelle|create|ändere|aendere|update|lösche|loesche|delete|run|starte|execute|führe|fuehre)\b",
    re.I,
)
LIVE_DOMAIN_RE = re.compile(
    r"\b(sharezone|schulcloud|vertretungsplan|vertretung|hausaufgaben|homework|remind|reminder|erinnerung|news|nachrichten|tech-?news|aktuell|memory|memories|youtube|youtu\.be|video|transkript|untertitel|subtitle|captions)\b",
    re.I,
)
LOCAL_SYSTEM_RE = re.compile(
    r"\b(datei|file|ordner|folder|terminal|shell|command|befehl|prozess|log|logs|config|konfiguration)\b",
    re.I,
)
TOOL_FORCE_PHRASE_RE = re.compile(r"\b(nutze|use)\b.*\b(tool|tools|skill_run|shell)\b", re.I)
MEDIA_ATTACHED_RE = re.compile(
    r"^\s*\[media attached(?:\s+\d+/\d+)?:\s*(?P<payload>.+?)\]\s*$",
    re.I,
)
PDF_PLACEHOLDER_RE = re.compile(r"<media:(?:document|attachment)>", re.I)


def load_env_files(paths: List[str]) -> None:
    for path in paths:
        try:
            if not path or not os.path.exists(path):
                continue
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
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


def getenv(name: str, default: Optional[str] = None) -> Optional[str]:
    val = os.getenv(name)
    if val is None or val == "":
        return default
    return val


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def local_now_iso() -> str:
    return dt.datetime.now().isoformat(timespec="seconds")


def ensure_state_dirs() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    MEMORY_DIR.mkdir(parents=True, exist_ok=True)


def is_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def acquire_lock() -> None:
    ensure_state_dirs()
    # Best-effort single-run lock to avoid overlapping tool executions.
    # In gateway mode, overlapping user messages can happen; instead of failing
    # immediately, wait briefly for the active run to finish.
    wait_sec = float(getenv("TWINMIND_LOCK_WAIT_SEC", "25") or "25")
    deadline = time.time() + max(0.0, wait_sec)
    while LOCK_PATH.exists():
        try:
            data = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
            pid = int(data.get("pid") or 0)
        except Exception:
            pid = 0
        if pid and is_pid_alive(pid):
            if time.time() >= deadline:
                raise RuntimeError(f"Already running (pid {pid}).")
            time.sleep(0.25)
            continue
        # stale lock
        try:
            LOCK_PATH.unlink()
        except Exception:
            break
    LOCK_PATH.write_text(json.dumps({"pid": os.getpid(), "started_at": utc_now_iso()}, ensure_ascii=False), encoding="utf-8")


def release_lock() -> None:
    try:
        if LOCK_PATH.exists():
            LOCK_PATH.unlink()
    except Exception:
        pass


def load_sessions() -> Dict[str, str]:
    if not SESSIONS_PATH.exists():
        return {}
    try:
        return json.loads(SESSIONS_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_sessions(sessions: Dict[str, str]) -> None:
    ensure_state_dirs()
    try:
        SESSIONS_PATH.write_text(json.dumps(sessions, ensure_ascii=False, indent=2), encoding="utf-8")
    except Exception:
        pass


def get_user_key() -> str:
    override = (getenv("TWINMIND_USER_KEY_OVERRIDE") or "").strip()
    if override:
        return override
    # Best-effort stable key per chat/user. Clawdbot may set these env vars; if not, fallback.
    chat = getenv("CLAWDBOT_CHAT_ID")
    user = getenv("CLAWDBOT_USER_ID")
    if chat and user:
        return f"{chat}:{user}"
    if chat:
        return f"chat:{chat}"
    if user:
        return f"user:{user}"
    return "default"


def derive_user_key_from_query(user_query: str) -> str:
    q = (user_query or "").strip()
    if not q:
        return ""
    # Common inbound format used by gateway auto-reply:
    # [WhatsApp +49123... 2026-...Z] message
    m = re.search(r"^\[\s*WhatsApp\s+([^\]\s]+)", q, re.I)
    if m:
        return f"wa:{m.group(1).strip()}"
    # System heartbeat/cron prompts should not share conversation state with user chats.
    if re.search(r"\bHEARTBEAT\.md\b|\bHEARTBEAT_OK\b", q, re.I):
        return "system:heartbeat"
    if re.search(r"\bcron\b", q, re.I):
        return "system:cron"
    return ""


def infer_origin_chat_id() -> str:
    """
    Best-effort extraction of the current chat id when invoked via Clawdbot gateway.
    Different gateway versions/providers may expose different env var names.
    """
    for k in (
        "CLAWDBOT_CHAT_ID",
        "CLAWDBOT_TARGET",
        "CLAWDBOT_TO",
        "CLAWDBOT_WHATSAPP_TARGET",
        "WHATSAPP_TARGET",
        "CLAWDBOT_CONTEXT_CHAT_ID",
    ):
        v = (getenv(k) or "").strip()
        if not v:
            continue
        if v.endswith("@g.us") or v.endswith("@c.us"):
            return v
    return ""


def infer_origin_target_from_request_text(user_query: str) -> str:
    """
    Some inbound channels embed metadata into the user message, e.g.:
      "[WhatsApp +49123456789 2026-...Z] message..."
    In those cases, env vars may not contain a chat id, but we can still reply
    by targeting the phone number.
    """
    if not user_query:
        return ""
    m = re.search(r"\[\s*WhatsApp\s+(\+?\d{8,})\b", user_query, re.I)
    if m:
        return m.group(1).strip()
    return ""


def get_brave_api_key() -> Optional[str]:
    """
    Prefer env; fallback to the existing daily-tech-news script constant if present.
    This avoids hardcoding secrets in multiple places and keeps the wrapper working
    even if cron doesn't source /root/.clawdbot/.env.
    """
    key = (getenv("BRAVE_API_KEY") or "").strip()
    if key:
        return key
    try:
        p = Path("/root/.clawdbot/scripts/daily-tech-news.py")
        if p.exists():
            txt = p.read_text(encoding="utf-8", errors="ignore")
            m = re.search(r'BRAVE_API_KEY\s*=\s*"([^"]+)"', txt)
            if m:
                return m.group(1).strip()
    except Exception:
        pass
    return None


def strip_channel_prefix(user_query: str) -> str:
    # Remove "[WhatsApp +49... ...] " prefix used by web-auto-reply.
    return re.sub(r"^\[\s*WhatsApp\s+[^\]]+\]\s*", "", (user_query or "").strip(), flags=re.I)


def sanitize_inbound_query(user_query: str) -> str:
    """
    Remove transport wrappers/noise while preserving user intent.
    """
    q = user_query or ""
    q = q.replace("\r\n", "\n").replace("\r", "\n")
    # Remove gateway status line wrapper, e.g.:
    # "System: [2026-..Z] WhatsApp gateway connected."
    q = re.sub(r"(?im)^\s*System:\s*\[[^\]]+\][^\n]*\n?", "", q)

    # If message contains embedded WhatsApp metadata block, keep only user text.
    # Typical format:
    # [WhatsApp +491... 2026-..Z] <optional text>
    # <message body>
    # [message_id: ...]
    lines = q.split("\n")
    wa_idx = -1
    for idx, line in enumerate(lines):
        if re.search(r"^\s*\[\s*WhatsApp\s+[^\]]+\]", line, re.I):
            wa_idx = idx
            break
    if wa_idx >= 0:
        inline = re.sub(r"^\s*\[\s*WhatsApp\s+[^\]]+\]\s*", "", lines[wa_idx], flags=re.I).strip()
        rest = lines[wa_idx + 1 :]
        cleaned_rest = []
        for line in rest:
            if re.search(r"^\s*\[(message_id|chat_id|sender|from|to):", line, re.I):
                continue
            cleaned_rest.append(line)
        body = "\n".join(cleaned_rest).strip()
        q = "\n".join([x for x in [inline, body] if x]).strip() or inline or body or q

    # Remove trailing metadata lines.
    q = re.sub(r"(?im)^\s*\[message_id:[^\]]+\]\s*$", "", q)
    q = re.sub(r"(?im)^\s*\[(chat_id|sender|from|to):[^\]]+\]\s*$", "", q)
    # Also support direct prefix-only format.
    q = strip_channel_prefix(q)

    # Some transports echo previous tool-call blocks back to the model.
    q = re.sub(r"(?is)^\s*\[Tool Call:[^\]]*\]\s*Arguments:\s*\{.*?\}\s*", "", q)
    q = re.sub(r"(?is)^\s*TOOL_RESULT\s+\{.*?\}\s*", "", q)
    # Optional sentinel to force tool mode; strip from user-visible query.
    q = re.sub(r"\bTM_TOOL_MODE\s*=\s*1\b", "", q, flags=re.I)
    return q.strip()


def parse_media_paths_from_query(text: str) -> List[Tuple[str, str]]:
    """
    Parse media note lines produced by buildInboundMediaNote(), e.g.:
      [media attached: /root/.clawdbot/media/inbound/file.pdf (application/pdf)]
    Returns (path, mime) tuples.
    """
    out: List[Tuple[str, str]] = []
    if not text:
        return out
    for line in text.splitlines():
        m = MEDIA_ATTACHED_RE.match((line or "").strip())
        if not m:
            continue
        payload = (m.group("payload") or "").strip()
        if " | " in payload:
            payload = payload.split(" | ", 1)[0].strip()
        mm = re.match(r"^(?P<path>/.+?)(?:\s+\((?P<mime>[^)]+)\))?$", payload)
        if not mm:
            continue
        path = (mm.group("path") or "").strip()
        mime = (mm.group("mime") or "").strip().lower()
        if not path:
            continue
        out.append((path, mime))
    return out


def parse_whatsapp_timestamp(raw_query: str) -> Optional[float]:
    if not raw_query:
        return None
    m = re.search(r"\[\s*WhatsApp\s+[^\]]+\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?Z?)\]", raw_query, re.I)
    if not m:
        return None
    raw = (m.group(1) or "").strip()
    if not raw:
        return None
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    # fromisoformat expects seconds in some variants.
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?:\+00:00)?", raw):
        raw = raw.replace("+00:00", "") + ":00+00:00"
    try:
        parsed = dt.datetime.fromisoformat(raw)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.timestamp()
    except Exception:
        return None


def find_recent_inbound_pdf(raw_query: str) -> Optional[str]:
    base = Path((getenv("TWINMIND_INBOUND_MEDIA_DIR", "/root/.clawdbot/media/inbound") or "/root/.clawdbot/media/inbound").strip())
    if not base.exists() or not base.is_dir():
        return None
    try:
        candidates = [p for p in base.glob("*.pdf") if p.is_file()]
    except Exception:
        return None
    if not candidates:
        return None

    ts = parse_whatsapp_timestamp(raw_query)
    if ts is None:
        latest = max(candidates, key=lambda p: p.stat().st_mtime)
        return str(latest)

    max_delta_sec = int(getenv("TWINMIND_PDF_FALLBACK_MAX_DELTA_SEC", "7200") or "7200")
    best = min(candidates, key=lambda p: abs(p.stat().st_mtime - ts))
    delta = abs(best.stat().st_mtime - ts)
    if delta > max_delta_sec:
        return None
    return str(best)


def run_llmwhisperer_extract(file_path: str) -> Tuple[str, str]:
    script = (getenv("TWINMIND_LLMWHISPERER_SCRIPT", "/root/clawd/skills/llmwhisperer/scripts/llmwhisperer") or "").strip()
    if not script or not os.path.exists(script):
        return "", "llmwhisperer script not found"
    timeout_sec = int(getenv("TWINMIND_PDF_EXTRACT_TIMEOUT_SEC", "180") or "180")
    poll_sec = int(getenv("TWINMIND_PDF_EXTRACT_POLL_SEC", "3") or "3")
    cmd = ["python3", script, file_path, "--timeout", str(timeout_sec), "--poll", str(poll_sec)]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=max(timeout_sec + 30, 60), env=os.environ.copy())
    except subprocess.TimeoutExpired:
        return "", f"llmwhisperer timeout after {timeout_sec}s"
    except Exception as e:
        return "", f"llmwhisperer exec error: {e}"
    if p.returncode != 0:
        err = (p.stderr or p.stdout or f"exit {p.returncode}").strip()
        return "", safe_truncate(err, 600)
    text = (p.stdout or "").strip()
    if not text:
        return "", "llmwhisperer returned empty output"
    return text, ""


def maybe_enrich_pdf_query(raw_query: str, sanitized_query: str) -> Tuple[str, Dict[str, Any]]:
    meta: Dict[str, Any] = {"detected": False}
    sq = (sanitized_query or "").strip()
    if not PDF_PLACEHOLDER_RE.search(sq):
        return sq, meta

    meta["detected"] = True
    selected_pdf = ""
    source = ""
    attachments = parse_media_paths_from_query(raw_query) + parse_media_paths_from_query(sq)
    for path, mime in attachments:
        is_pdf = path.lower().endswith(".pdf") or ("pdf" in mime)
        if not is_pdf:
            continue
        if os.path.exists(path):
            selected_pdf = path
            source = "media_note"
            break

    if not selected_pdf:
        fallback = find_recent_inbound_pdf(raw_query)
        if fallback and os.path.exists(fallback):
            selected_pdf = fallback
            source = "recent_inbound_fallback"

    if not selected_pdf:
        meta.update({"status": "no_pdf_path"})
        return sq, meta

    extracted, err = run_llmwhisperer_extract(selected_pdf)
    if err:
        meta.update({"status": "extract_failed", "error": err, "file_path": selected_pdf, "source": source})
        return sq, meta

    max_chars = int(getenv("TWINMIND_PDF_EXTRACT_MAX_CHARS", "14000") or "14000")
    extracted_trimmed = safe_truncate(extracted, max_chars).strip()
    base = PDF_PLACEHOLDER_RE.sub("", sq).strip()
    if not base:
        base = "Bitte analysiere dieses PDF-Dokument."
    enriched = (
        f"{base}\n\n"
        f"[PDF_EXTRACT file=\"{selected_pdf}\"]\n"
        f"{extracted_trimmed}\n"
        f"[/PDF_EXTRACT]"
    ).strip()
    meta.update(
        {
            "status": "enriched",
            "file_path": selected_pdf,
            "source": source,
            "extract_chars": len(extracted),
            "used_chars": len(extracted_trimmed),
        }
    )
    return enriched, meta


def is_tool_mode_requested(user_query: str) -> bool:
    if (getenv("TWINMIND_FORCE_TOOL_BRIDGE", "0") or "0").strip() == "1":
        return True
    q = user_query or ""
    if re.search(r"\bTM_TOOL_MODE\s*=\s*1\b", q, re.I):
        return True
    if not q.strip():
        return False
    if TOOL_EXPLICIT_RE.search(q):
        return True

    # Dynamic intent: action requests touching local systems or live app domains.
    has_action = bool(TOOL_ACTION_RE.search(q))
    has_local_system = bool(LOCAL_SYSTEM_RE.search(q))
    has_live_domain = bool(LIVE_DOMAIN_RE.search(q))
    if has_action and (has_local_system or has_live_domain):
        return True

    # Question-style intents often omit explicit tool words.
    if re.search(
        r"\b(was|welche|welcher|welches|what|which|show)\b.*\b(vertretungsplan|hausaufgaben|homework|reminder|erinnerung|news|nachrichten|memories)\b",
        q,
        re.I,
    ):
        return True
    return False


def should_force_tool_for_request(user_query: str) -> bool:
    q = (user_query or "").strip()
    if not q:
        return False
    if TOOL_FORCE_PHRASE_RE.search(q):
        return True
    return bool(LIVE_DOMAIN_RE.search(q))


def load_local_profile_text() -> str:
    custom = (getenv("TWINMIND_LOCAL_PROFILE_PATH") or "").strip()
    paths: List[str] = []
    if custom:
        paths.append(custom)
    paths.extend(LOCAL_PROFILE_PATHS)

    for raw in paths:
        p = Path(raw).expanduser()
        if not p.exists() or not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        if not text.strip():
            continue
        if p.suffix.lower() == ".json":
            try:
                obj = json.loads(text)
            except Exception:
                continue
            if isinstance(obj, str):
                return obj.strip()
            if isinstance(obj, dict):
                lines: List[str] = []
                identity = str(obj.get("identity") or "").strip()
                style = str(obj.get("style") or "").strip()
                user_profile = str(obj.get("user_profile") or "").strip()
                if identity:
                    lines.append(f"Identity: {identity}")
                if style:
                    lines.append(f"Style: {style}")
                if user_profile:
                    lines.append(user_profile)
                rules = obj.get("rules")
                if isinstance(rules, list):
                    clean_rules = [str(x).strip() for x in rules if str(x).strip()]
                    if clean_rules:
                        lines.append("Rules:")
                        lines.extend(f"- {r}" for r in clean_rules[:20])
                return "\n".join(lines).strip()
            continue
        return text.strip()
    return ""


def merged_user_profile(base_profile: str) -> str:
    base = (base_profile or "").strip()
    local = load_local_profile_text()
    if not local:
        return base
    if not base:
        return local
    return f"{base}\n\n{local}".strip()


def should_skip_memory_pipeline_for_query(user_query: str) -> bool:
    q = (user_query or "").strip()
    if not q:
        return True
    if is_heartbeat_request(q):
        return True
    if re.match(r"^\s*(?:\[cron:[^\]]+\]\s*)?⏰\s*Reminder:", q):
        return True
    if re.search(r"/root/\.clawdbot/scripts/schulcloud-daily\.sh\b|\bschulcloud[- ]daily\b", q, re.I):
        return True
    return False


def safe_json_loads(raw: str) -> Optional[Dict[str, Any]]:
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            return obj
    except Exception:
        pass
    first = extract_first_json_object(raw or "")
    if first:
        try:
            obj2 = json.loads(first)
            if isinstance(obj2, dict):
                return obj2
        except Exception:
            return None
    return None


def extract_transcript_excerpt_from_executor_answer(executor_answer: str) -> Tuple[str, str]:
    """
    Best-effort extraction of a transcript snippet from structured executor output.
    This lets TwinMind finalizer reason over source content instead of only a short
    executor summary for media-heavy tasks (e.g. YouTube).
    """
    raw = (executor_answer or "").strip()
    if not raw:
        return "", ""
    obj = safe_json_loads(raw)
    if not isinstance(obj, dict):
        return "", ""
    artifacts = obj.get("artifacts")
    if not isinstance(artifacts, dict):
        return "", ""
    transcript_path = str(
        artifacts.get("transcript_path")
        or artifacts.get("transcript")
        or ""
    ).strip()
    if not transcript_path or not transcript_path.startswith("/"):
        return "", ""
    if not os.path.exists(transcript_path):
        return "", transcript_path
    max_chars = int(getenv("ORCH_FINALIZER_TRANSCRIPT_MAX_CHARS", "12000") or "12000")
    max_chars = max(800, min(max_chars, 50000))
    try:
        data = Path(transcript_path).read_text(encoding="utf-8", errors="replace")
    except Exception:
        return "", transcript_path
    return safe_truncate((data or "").strip(), max_chars), transcript_path


def load_dynamic_memory_context(user_query: str, log_path: Path) -> Tuple[str, Dict[str, Any]]:
    enabled = (getenv("ORCH_DYNAMIC_MEMORY_ENABLED", "1") or "1").strip() == "1"
    if not enabled:
        return "", {"enabled": False, "reason": "disabled"}
    if should_skip_memory_pipeline_for_query(user_query):
        return "", {"enabled": False, "reason": "skipped_system_query"}

    script = (getenv("ORCH_DYNAMIC_MEMORY_SCRIPT", PERSONAL_MEMORY_PIPELINE) or PERSONAL_MEMORY_PIPELINE).strip()
    if not script or (not os.path.exists(script)):
        write_log(log_path, {"event": "memory_context_missing_script", "path": script})
        return "", {"enabled": False, "reason": "script_missing"}

    timeout_sec = int(getenv("ORCH_DYNAMIC_MEMORY_CONTEXT_TIMEOUT_SEC", "8") or "8")
    max_chars = int(getenv("ORCH_DYNAMIC_MEMORY_CONTEXT_MAX_CHARS", "3200") or "3200")
    cmd = [
        "python3",
        script,
        "context",
        "--query",
        (user_query or ""),
        "--max-chars",
        str(max(800, max_chars)),
        "--json",
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=max(2, timeout_sec), env=os.environ.copy())
    except subprocess.TimeoutExpired:
        write_log(log_path, {"event": "memory_context_error", "error": f"timeout after {timeout_sec}s"})
        return "", {"enabled": True, "error": f"timeout after {timeout_sec}s"}
    except Exception as e:
        write_log(log_path, {"event": "memory_context_error", "error": safe_truncate(str(e), 400)})
        return "", {"enabled": True, "error": safe_truncate(str(e), 300)}

    payload = safe_json_loads((proc.stdout or "").strip())
    if not payload:
        err_preview = safe_truncate((proc.stderr or proc.stdout or "").strip(), 400)
        write_log(log_path, {"event": "memory_context_error", "error": "invalid_json", "preview": err_preview})
        return "", {"enabled": True, "error": "invalid_json"}

    if not bool(payload.get("ok")):
        write_log(log_path, {"event": "memory_context_error", "error": safe_truncate(str(payload.get("error") or "unknown"), 400)})
        return "", {"enabled": True, "error": str(payload.get("error") or "unknown")}

    ctx = str(payload.get("text") or "").strip()
    meta_obj = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
    write_log(log_path, {"event": "memory_context_loaded", "chars": len(ctx), "meta": meta_obj})
    return ctx, {"enabled": True, **meta_obj}


def ingest_dynamic_memory_turn(
    *,
    user_query: str,
    assistant_answer: str,
    session_id: str,
    route: str,
    log_path: Path,
) -> None:
    enabled = (getenv("ORCH_DYNAMIC_MEMORY_ENABLED", "1") or "1").strip() == "1"
    if not enabled:
        return
    if should_skip_memory_pipeline_for_query(user_query):
        return
    if not (user_query or "").strip():
        return

    script = (getenv("ORCH_DYNAMIC_MEMORY_SCRIPT", PERSONAL_MEMORY_PIPELINE) or PERSONAL_MEMORY_PIPELINE).strip()
    if not script or (not os.path.exists(script)):
        return

    timeout_sec = int(getenv("ORCH_DYNAMIC_MEMORY_INGEST_TIMEOUT_SEC", "8") or "8")
    payload = {
        "user_query": safe_truncate((user_query or "").strip(), 18000),
        "assistant_answer": safe_truncate((assistant_answer or "").strip(), 18000),
    }
    cmd = [
        "python3",
        script,
        "ingest",
        "--session-id",
        str(session_id or ""),
        "--route",
        str(route or ""),
        "--json",
    ]
    try:
        proc = subprocess.run(
            cmd,
            input=json.dumps(payload, ensure_ascii=False),
            capture_output=True,
            text=True,
            timeout=max(2, timeout_sec),
            env=os.environ.copy(),
        )
    except Exception as e:
        write_log(log_path, {"event": "memory_ingest_error", "error": safe_truncate(str(e), 400)})
        return

    obj = safe_json_loads((proc.stdout or "").strip())
    if not obj:
        write_log(
            log_path,
            {
                "event": "memory_ingest_error",
                "error": "invalid_json",
                "preview": safe_truncate((proc.stderr or proc.stdout or "").strip(), 400),
            },
        )
        return
    if not bool(obj.get("ok")):
        write_log(log_path, {"event": "memory_ingest_error", "error": safe_truncate(str(obj.get("error") or "unknown"), 400)})
        return
    write_log(
        log_path,
        {
            "event": "memory_ingest_ok",
            "route": route,
            "added": obj.get("added"),
            "updated": obj.get("updated"),
            "facts_active": obj.get("facts_active"),
        },
    )


def apply_memory_context_to_query(user_query: str, memory_context: str) -> str:
    clean_query = (user_query or "").strip()
    mem = (memory_context or "").strip()
    if not mem:
        return clean_query
    return (
        "PERSISTENT_USER_MEMORY (internal context; use only when relevant):\n"
        + mem
        + "\n\nCURRENT_USER_REQUEST:\n"
        + clean_query
    ).strip()


def extract_image_understanding(text: str) -> Optional[Dict[str, str]]:
    """
    If Clawdbot media-understanding is enabled, inbound image messages are rewritten into:
      [Image]
      User text:
      ...
      Description:
      ...
    We can answer deterministically from that without involving TwinMind tool-protocol prompts
    (TwinMind often treats those prompts as injection and replies "Declined.").
    """
    if not text:
        return None
    t = text.strip()
    m = re.search(
        r"(?is)\[Image[^\]]*\]\s*(?:User text:\s*(?P<user>.*?))?\s*Description:\s*(?P<desc>.*?)(?:\n\n\[|\Z)",
        t,
    )
    if not m:
        return None
    desc = (m.group("desc") or "").strip()
    if not desc:
        return None
    user = (m.group("user") or "").strip()
    return {"user_text": user, "description": desc}


def parse_one_time_reminder(user_query: str) -> Optional[Tuple[str, str]]:
    """
    Best-effort parse for common natural language reminders.
    Returns (message, when) where 'when' is compatible with create-reminder.sh.
    We only hard-handle relative "in X ..." reliably; other formats fall back to LLM.
    """
    q = strip_channel_prefix(user_query)
    low = q.lower()
    # Support common phrasings:
    # - "remind me in 5min ..."
    # - "erinnere mich in 5 minuten ..."
    # - "stelle einen reminder in 5min"
    # - "erinnerung in 10min"
    if not re.search(r"\b(remind me|reminder|erinnere|erinnerung)\b", low):
        return None

    # Relative: in 20min / in 20 Minuten / in 2 Stunden / in 1h / in 3 days
    m = re.search(
        r"\bin\s*([0-9]+)\s*(min|mins|minute|minutes|minuten|m|h|hour|hours|stunde|stunden|d|day|days|tag|tage)\b",
        low,
    )
    if not m:
        return None
    amount = m.group(1)
    unit = m.group(2)
    unit_norm = unit
    if unit in ("min", "mins", "minute", "minutes", "minuten", "m"):
        unit_norm = "minutes"
    elif unit in ("h", "hour", "hours", "stunde", "stunden"):
        unit_norm = "hours"
    elif unit in ("d", "day", "days", "tag", "tage"):
        unit_norm = "days"
    when = f"in {amount} {unit_norm}"

    # Message: take text after the "in X unit" phrase.
    rest = q[m.end() :].strip()
    rest = re.sub(r"^(dass|das|dran|daran|,|:|-)\s+", "", rest, flags=re.I)
    rest = rest.strip()
    if not rest:
        # No payload after the time, so use a generic reminder message.
        rest = ""
    # If it still contains the leading remind phrase, strip it.
    rest = re.sub(r"^(bitte\s+)?(remind me|reminder|erinnere( mich)?|erinnerung)\b", "", rest, flags=re.I).strip()
    rest = rest.strip(" ,:-")
    if not rest:
        rest = "Reminder"
    return rest, when


def is_heartbeat_request(user_query: str) -> bool:
    q = (user_query or "")
    if re.search(r"\bheartbeat_ok\b", q, re.I):
        return True
    if not re.search(r"heartbeat\.md", q, re.I):
        return False
    return bool(re.search(r"\b(read|check|follow|poll|scan|review|process|cycle|respond|reply|lies|pruef|prüf)\b", q, re.I))


def resolve_heartbeat_path() -> Optional[Path]:
    paths: List[str] = []
    env_path = (getenv("TWINMIND_HEARTBEAT_PATH") or "").strip()
    if env_path:
        paths.append(env_path)
    paths.extend(HEARTBEAT_PATHS)
    seen = set()
    for raw in paths:
        p = Path(raw).expanduser()
        key = str(p.resolve()) if p.exists() else str(p)
        if key in seen:
            continue
        seen.add(key)
        if p.exists() and p.is_file():
            return p
    return None


def extract_open_heartbeat_items(markdown_text: str, max_items: int = 8) -> List[str]:
    items: List[str] = []
    for line in (markdown_text or "").splitlines():
        m = re.match(r"^\s*(?:[-*+]|\d+\.)\s+\[\s\]\s*(.*?)\s*$", line)
        if not m:
            continue
        label = (m.group(1) or "").strip()
        items.append(label or "(empty task)")
        if len(items) >= max_items:
            break
    return items


def evaluate_heartbeat_status() -> Tuple[str, Dict[str, Any]]:
    p = resolve_heartbeat_path()
    if not p:
        return "HEARTBEAT_OK", {"file_found": False}
    try:
        content = p.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        return "HEARTBEAT_OK", {"file_found": True, "path": str(p), "read_error": str(e)}

    open_items = extract_open_heartbeat_items(content)
    if not open_items:
        return "HEARTBEAT_OK", {"file_found": True, "path": str(p), "open_items": 0}

    lines = ["HEARTBEAT_NEEDS_ATTENTION", f"open_items={len(open_items)}"]
    lines.extend(f"- {item}" for item in open_items)
    return "\n".join(lines), {"file_found": True, "path": str(p), "open_items": len(open_items)}


def is_provider_refusal(text: str) -> bool:
    if not text:
        return False
    low = text.lower()
    patterns = [
        "declined",
        "cannot comply",
        "can't comply",
        "cannot assist with that",
        "can't assist with that",
        "cannot provide that",
        "unable to comply",
        "policy violation",
        "not configured for",
    ]
    return any(p in low for p in patterns)


def tool_result_message(result: Dict[str, Any], default_ok: str = "OK") -> str:
    out = (result.get("stdout") or "").strip()
    err_out = (result.get("stderr") or "").strip()
    if not out and result.get("error"):
        out = f"Error: {result.get('error')}".strip()
    if not out and err_out:
        out = err_out
    if not out:
        out = default_ok
    return out


def youtube_partial_fallback_message(yt_obj: Dict[str, Any]) -> str:
    video = yt_obj.get("video") if isinstance(yt_obj.get("video"), dict) else {}
    diagnostics = yt_obj.get("diagnostics") if isinstance(yt_obj.get("diagnostics"), dict) else {}
    title = str(video.get("title") or "").strip()
    warning = str(yt_obj.get("warning") or "").strip()
    diag_msg = str(diagnostics.get("message") or "").strip()
    actions = diagnostics.get("next_actions") if isinstance(diagnostics.get("next_actions"), list) else []
    clean_actions = [str(a).strip() for a in actions if str(a).strip()]

    lead = "Ich konnte den Video-Inhalt aktuell nicht zuverlässig extrahieren."
    if title:
        lead = f'Ich konnte den Inhalt von "{title}" aktuell nicht zuverlässig extrahieren.'
    reason = warning or diag_msg or "YouTube blockiert den automatisierten Zugriff (Bot-/Login-Check)."
    lines = [lead, "", f"Grund: {reason}"]
    if clean_actions:
        lines.append("")
        lines.append("Nächste Schritte:")
        lines.extend([f"- {item}" for item in clean_actions[:3]])
    return "\n".join(lines).strip()


def infer_weekday_from_query(query: str) -> Optional[str]:
    q = (query or "").lower()
    mapping = [
        ("monday", [r"\bmonday\b", r"\bmontag\b"]),
        ("tuesday", [r"\btuesday\b", r"\bdienstag\b"]),
        ("wednesday", [r"\bwednesday\b", r"\bmittwoch\b"]),
        ("thursday", [r"\bthursday\b", r"\bdonnerstag\b"]),
        ("friday", [r"\bfriday\b", r"\bfreitag\b"]),
    ]
    for day, pats in mapping:
        if any(re.search(p, q, re.I) for p in pats):
            return day
    return None


def infer_sharezone_skill(user_query: str) -> Optional[Tuple[str, Dict[str, Any]]]:
    q = strip_channel_prefix(user_query)
    low = q.lower()
    if not re.search(r"\b(sharezone|hausaufgaben|aufgaben|homework|stundenplan|kurse|kurs|fächer|faecher|lessons|classes)\b", low):
        return None

    if re.search(r"\b(klassen|klasse|classes|class)\b", low):
        return "sharezone.list_classes", {}
    if re.search(r"\b(kurse|kurs|fächer|faecher|courses|subjects)\b", low):
        return "sharezone.list_courses", {}
    if re.search(r"\b(hausaufgaben|aufgaben|homework)\b", low):
        return "sharezone.list_homework", {"all": bool(re.search(r"\b(alle|all)\b", low))}
    if re.search(r"\b(stundenplan|stunden|unterricht|lessons|lesson)\b", low):
        weekday = infer_weekday_from_query(low)
        args: Dict[str, Any] = {}
        if weekday:
            args["weekday"] = weekday
        return "sharezone.list_lessons", args
    return None


def infer_twinmind_memory_skill(user_query: str) -> Optional[Tuple[str, Dict[str, Any]]]:
    q = sanitize_inbound_query(user_query)
    low = q.lower()
    has_memory_noun = bool(re.search(r"\b(memory|memories|meeting|meetings|notiz|notizen|aufzeichnung|aufzeichnungen)\b", low))
    has_twinmind = bool(re.search(r"\btwinmind\b", low))
    if not has_memory_noun and not has_twinmind:
        return None

    if re.search(r"\b(sync|synchron|synchronize|aktualisier|aktualisieren|refresh|neu laden|neu\s+einlesen)\b", low):
        return "twinmind.memory_sync", {}

    mid = ""
    m_uuid = re.search(r"\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b", low, re.I)
    if m_uuid:
        mid = m_uuid.group(1)
    elif re.search(r"\b(memory|meeting)\s*id\b", low):
        m_any = re.search(r"\b(?:memory|meeting)\s*id[:\s]+([A-Za-z0-9._:-]{6,})\b", q, re.I)
        if m_any:
            mid = m_any.group(1).strip()
    if mid:
        return "twinmind.memory_get", {"id": mid}

    if re.search(r"\b(suche|search|find|finde|frage|query|worum|welche|welcher|was|wie|wann|wer|warum|wieso)\b", low) or "?" in q:
        query_text = re.sub(
            r"\b(twinmind|memory|memories|meeting|meetings|notiz|notizen|aufzeichnung|aufzeichnungen|suche|search|finde?|query)\b",
            " ",
            q,
            flags=re.I,
        )
        query_text = re.sub(r"\s+", " ", query_text).strip(" :-")
        if not query_text:
            query_text = q
        return "twinmind.memory_search", {"query": query_text, "limit": 5}

    # Default for generic memory requests: refresh index first.
    if has_memory_noun:
        return "twinmind.memory_sync", {}
    return None


def get_session_id(explicit: Optional[str], new_session: bool) -> str:
    if explicit:
        return explicit
    sessions = load_sessions()
    key = get_user_key()
    if new_session or key not in sessions:
        sid = str(uuid.uuid4())
        sessions[key] = sid
        save_sessions(sessions)
        return sid
    return sessions[key]


def get_id_token(refresh_token: str, firebase_api_key: str) -> str:
    url = f"https://securetoken.googleapis.com/v1/token?key={firebase_api_key}"
    payload = {"grant_type": "refresh_token", "refresh_token": refresh_token}
    r = requests.post(url, data=payload, timeout=30)
    if r.status_code != 200:
        raise RuntimeError(f"Token refresh failed: {r.status_code} {r.text}")
    token = r.json().get("id_token")
    if not token:
        raise RuntimeError("Token refresh failed: missing id_token")
    return token


def sse_last_content(resp: requests.Response, read_timeout_sec: int, debug: bool = False) -> Tuple[str, Dict[str, int]]:
    """
    Read TwinMind SSE stream and return the last full RunResponseContent content.
    """
    last = ""
    events: Dict[str, int] = {}
    # Important: resp.iter_lines() can block forever if the server streams bytes
    # without newline boundaries. We therefore parse SSE from iter_content()
    # and enforce an overall deadline ourselves.
    deadline = time.time() + float(read_timeout_sec)
    buf = b""
    for chunk in resp.iter_content(chunk_size=4096):
        if time.time() > deadline:
            if last.strip():
                events["timeout_partial"] = events.get("timeout_partial", 0) + 1
                return last.strip(), events
            raise TimeoutError(f"SSE read timeout after {read_timeout_sec}s")
        if not chunk:
            continue
        buf += chunk
        # Process complete lines
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            raw = raw.strip()
            if not raw:
                continue
            line = raw.decode("utf-8", errors="replace")
            if not line.startswith("data: "):
                continue
            data = line[6:].strip()
            if data == "[DONE]":
                return last.strip(), events
            try:
                obj = json.loads(data)
            except Exception:
                continue
            ev = obj.get("event") or ""
            if ev:
                events[ev] = events.get(ev, 0) + 1
            if debug and ev:
                meta = {k: v for k, v in obj.items() if k not in ("content",)}
                print(f"[twinmind:event] {ev} meta={meta}", file=sys.stderr)
            if obj.get("event") == "RunResponseContent" and isinstance(obj.get("content"), str):
                last = obj["content"]

    # Stream ended without explicit DONE. Try to parse remaining partial line once.
    if buf:
        tail = buf.strip().decode("utf-8", errors="replace")
        if tail.startswith("data: "):
            data = tail[6:].strip()
            if data and data != "[DONE]":
                try:
                    obj = json.loads(data)
                    ev = obj.get("event") or ""
                    if ev:
                        events[ev] = events.get(ev, 0) + 1
                    if obj.get("event") == "RunResponseContent" and isinstance(obj.get("content"), str):
                        last = obj["content"]
                except Exception:
                    pass

    if time.time() > deadline and not last.strip():
        raise TimeoutError(f"SSE read timeout after {read_timeout_sec}s")
    return last.strip(), events


def extract_first_json_object(text: str) -> Optional[str]:
    """
    Extract first {...} JSON object from text, tolerating code fences and leading/trailing prose.
    Uses a brace counter scan to handle nested braces.
    """
    if not text:
        return None
    t = text.strip()
    # Strip ```json fences if present
    fence = re.search(r"```(?:json)?\s*(\{.*\})\s*```", t, flags=re.S | re.I)
    if fence:
        t = fence.group(1).strip()

    # Find first balanced JSON object
    start = t.find("{")
    if start < 0:
        return None
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(t)):
        ch = t[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return t[start : i + 1].strip()
    return None


def find_balanced_json_objects(text: str) -> List[str]:
    out: List[str] = []
    if not text:
        return out
    n = len(text)
    i = 0
    while i < n:
        if text[i] != "{":
            i += 1
            continue
        start = i
        depth = 0
        in_str = False
        esc = False
        j = i
        while j < n:
            ch = text[j]
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
            else:
                if ch == '"':
                    in_str = True
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        out.append(text[start : j + 1])
                        i = j + 1
                        break
            j += 1
        else:
            i = start + 1
    return out


def normalize_protocol_object(obj: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    if not isinstance(obj, dict):
        return None

    action = str(obj.get("action") or obj.get("type") or obj.get("intent") or "").strip().lower()
    if not action:
        if "tool_call" in obj or "tool_calls" in obj or "tool" in obj:
            action = "tool_call"
        elif any(k in obj for k in ("answer", "final", "response", "message", "content")):
            action = "final"

    if action in ("final", "answer", "response", "respond"):
        answer = obj.get("answer")
        if answer is None:
            for key in ("final", "response", "message", "content"):
                if key in obj and obj.get(key) is not None:
                    answer = obj.get(key)
                    break
        if isinstance(answer, (dict, list)):
            answer = json.dumps(answer, ensure_ascii=False)
        answer_text = str(answer or "").strip()
        if not answer_text:
            return None
        return {"action": "final", "answer": answer_text}

    if action in ("tool_call", "tool", "call_tool", "use_tool"):
        call = obj
        if isinstance(obj.get("tool_call"), dict):
            call = obj.get("tool_call") or {}
        elif isinstance(obj.get("tool_calls"), list) and obj.get("tool_calls"):
            first = obj.get("tool_calls")[0]
            if isinstance(first, dict):
                call = first

        tool = str(
            call.get("tool")
            or call.get("name")
            or call.get("function")
            or call.get("command")
            or ""
        ).strip()
        args = call.get("args")
        if args is None:
            args = call.get("arguments")
        if args is None:
            args = call.get("params")
        if args is None:
            args = call.get("parameters")

        if isinstance(args, str):
            raw = args.strip()
            if raw.startswith("{") and raw.endswith("}"):
                try:
                    parsed = json.loads(raw)
                    if isinstance(parsed, dict):
                        args = parsed
                except Exception:
                    args = {"value": raw}
            else:
                args = {"value": raw}
        elif args is None:
            args = {}
        elif not isinstance(args, dict):
            args = {"value": str(args)}

        # Accept direct curated action names as shorthand; normalize to skill_run.
        if tool and tool not in {"shell", "read_file", "web_search", "web_fetch", "skill_run"}:
            if re.match(r"^(sharezone|schulcloud|remind_me|twinmind)\.", tool):
                args = {"skill": tool, "args": args if isinstance(args, dict) else {}}
                tool = "skill_run"

        # If tool name is omitted but a skill name is present, infer skill_run.
        skill_hint = str(call.get("skill") or obj.get("skill") or "").strip()
        if not tool and skill_hint:
            tool = "skill_run"
            args = {"skill": skill_hint, "args": args if isinstance(args, dict) else {}}

        if not tool:
            return None
        call_id = str(call.get("id") or obj.get("id") or uuid.uuid4())
        return {"action": "tool_call", "id": call_id, "tool": tool, "args": args}

    return None


def parse_protocol_output(raw: str) -> Tuple[Optional[Dict[str, Any]], str]:
    """
    Returns (obj, err). err is empty on success.
    """
    candidates: List[Dict[str, Any]] = []
    try:
        direct = json.loads(raw)
        if isinstance(direct, dict):
            candidates.append(direct)
    except Exception:
        pass

    first = extract_first_json_object(raw)
    if first:
        try:
            obj = json.loads(first)
            if isinstance(obj, dict):
                candidates.append(obj)
        except Exception:
            pass

    for chunk in find_balanced_json_objects(raw):
        try:
            obj = json.loads(chunk)
            if isinstance(obj, dict):
                candidates.append(obj)
        except Exception:
            continue

    seen = set()
    uniq: List[Dict[str, Any]] = []
    for cand in candidates:
        key = json.dumps(cand, ensure_ascii=False, sort_keys=True)
        if key in seen:
            continue
        seen.add(key)
        uniq.append(cand)

    if not uniq:
        return None, "No JSON object found in model output."

    for cand in uniq:
        norm = normalize_protocol_object(cand)
        if norm is None:
            continue
        if norm.get("action") == "final":
            if not isinstance(norm.get("answer"), str) or not norm.get("answer", "").strip():
                continue
            return norm, ""
        if norm.get("action") == "tool_call":
            tool = norm.get("tool")
            if not isinstance(tool, str) or not tool.strip():
                continue
            args = norm.get("args")
            if args is None:
                norm["args"] = {}
            elif not isinstance(args, dict):
                norm["args"] = {"value": str(args)}
            if "id" not in norm or not isinstance(norm.get("id"), str):
                norm["id"] = str(uuid.uuid4())
            return norm, ""

    return None, "Missing/invalid action. Expected action=tool_call or action=final."


def build_tool_catalog(allow_shell: bool) -> List[Dict[str, Any]]:
    skill_actions = [
        # Sharezone (read-only)
        "sharezone.list_courses",
        "sharezone.list_classes",
        "sharezone.list_homework",
        "sharezone.list_lessons",
        # Schulcloud (read-only + send)
        "schulcloud.get_substitution_plan",
        "schulcloud.send_substitution_plan",
        # Schulcloud (cron): check latest PDF and send only if changed (or if --force used)
        "schulcloud.check_and_send",
        # Reminders (safe writes)
        "remind_me.set",
        "remind_me.set_recurring",
        "remind_me.list",
        # Sharezone (writes; blocked unless --allow-writes 1)
        "sharezone.add_homework",
        "sharezone.add_event",
        "sharezone.cancel_lesson",
        # TwinMind memory cache
        "twinmind.memory_sync",
        "twinmind.memory_search",
        "twinmind.memory_get",
        # YouTube understanding
        "youtube.get_transcript",
        "youtube.summarize",
        "youtube.job_status",
    ]
    tools: List[Dict[str, Any]] = []
    if allow_shell:
        tools.append(
            {
                "tool": "shell",
                "args_schema": {"cmd": "string", "cwd": "string(optional)", "timeout_sec": "int(optional)"},
                "notes": "Run a local shell command (subject to policy). Prefer skill_run when possible; shell is less reliable.",
            }
        )
    tools.append(
        {
            "tool": "read_file",
            "args_schema": {"path": "string", "max_bytes": "int(optional)"},
            "notes": "Read a local file and return its contents (truncated).",
        }
    )
    tools.append(
        {
            "tool": "web_search",
            "args_schema": {"query": "string", "count": "int(optional, 1-10)"},
            "notes": "Search the public web (no JS). Use this for current events / tech news. Returns titles, urls, snippets.",
        }
    )
    tools.append(
        {
            "tool": "web_fetch",
            "args_schema": {"url": "string", "max_chars": "int(optional)"},
            "notes": "Fetch a URL and return text (HTML stripped). Does not execute JavaScript.",
        }
    )
    tools.append(
        {
            "tool": "skill_run",
            "args_schema": {"skill": f"one of: {', '.join(skill_actions)}", "args": "object"},
            "notes": "Run a curated skill action (preferred: most reliable).",
        }
    )
    return tools


def build_protocol_prompt(tool_catalog: List[Dict[str, Any]], allow_writes: bool) -> str:
    policy = "writes_allowed" if allow_writes else "read_only_default"
    return (
        "TOOL PROTOCOL.\n"
        "Return exactly one JSON object and nothing else.\n"
        "Allowed JSON shapes:\n"
        '  {"action":"tool_call","id":"<uuid>","tool":"<tool>","args":{...}}\n'
        '  {"action":"final","answer":"..."}\n'
        "Policy: " + policy + "\n"
        "Use tool calls when helpful or required to answer accurately.\n"
        "Prefer tool=skill_run when it can accomplish the task; use tool=shell only for simple safe read-only commands.\n"
        "Do not fabricate tool results.\n"
        "Example (preferred):\n"
        '{"action":"tool_call","id":"<uuid>","tool":"skill_run","args":{"skill":"sharezone.list_courses","args":{}}}\n'
        "If the user asks for the Vertretungsplan / Schulcloud plan, use skill_run with:\n"
        '- "schulcloud.get_substitution_plan" (show summary in chat)\n'
        '- "schulcloud.send_substitution_plan" (post to configured WhatsApp target)\n'
        "If the request contains a YouTube URL, prefer skill_run with:\n"
        '- "youtube.summarize" for content understanding / summary requests\n'
        '- "youtube.get_transcript" when the user explicitly asks for transcript text\n'
        '- "youtube.job_status" when the user asks for progress of an async job\n'
        "Available tools:\n"
        + json.dumps(tool_catalog, ensure_ascii=False)
        + "\n"
        "If the wrapper provides TOOL_RESULT, continue by either calling another tool or returning final.\n"
        "Do not wrap JSON in markdown code fences.\n"
    )


def mk_request_payload(
    query: str,
    session_id: str,
    model_name: str,
    provider: str,
    reasoning_budget: int,
    reasoning_enabled: bool,
    search_all_memories: bool,
    search_web: bool,
    current_context: Dict[str, Any],
    user_profile: str,
) -> Dict[str, Any]:
    return {
        "query": query,
        "session_id": session_id,
        "tap_to_get_answer": False,
        "summarize_my_tab": False,
        "proactive_suggestion": False,
        "user_metadata": {"timezone": "Europe/Berlin"},
        "meeting_metadata": None,
        "user_profile": user_profile or "",
        "reasoning_enabled": bool(reasoning_enabled),
        "search_web": bool(search_web),
        "device": "chrome",
        "current_context": current_context,
        "current_transcript": "",
        "user_tags": [],
        "search_all_memories": bool(search_all_memories),
        "model_name": model_name,
        "provider": provider,
        "reasoning_budget_tokens": int(reasoning_budget),
    }


def is_transient_http(status_code: int) -> bool:
    return status_code in (429, 500, 502, 503, 504)


def http_post_stream(url: str, headers: Dict[str, str], payload: Dict[str, Any], timeout_sec: int) -> requests.Response:
    # requests timeout is (connect, read)
    return requests.post(url, headers=headers, json=payload, stream=True, timeout=(30, timeout_sec))


def safe_truncate(s: str, limit: int) -> str:
    if s is None:
        return ""
    if len(s) <= limit:
        return s
    return s[:limit] + f"\n[truncated {len(s) - limit} chars]"


def shell_policy_check(cmd: str, allow_writes: bool) -> Tuple[bool, str]:
    if allow_writes:
        return True, ""

    # hard blocks: common write/unsafe operations
    lower = cmd.lower()
    blocked_patterns = [
        r"\btouch\b",
        r"\bmkdir\b",
        r"\bln\b",
        r"\btruncate\b",
        r"\bvi\b",
        r"\bnano\b",
        r"\brm\b",
        r"\bmv\b",
        r"\bcp\b",
        r"\bdd\b",
        r"\bmkfs\b",
        r"\bchmod\b",
        r"\bchown\b",
        r"\bsystemctl\b",
        r"\bservice\b",
        r"\breboot\b",
        r"\bshutdown\b",
        r"\bpkill\b",
        r"\bkill\b",
        r"\bcrontab\b",
        r"\bapt\b",
        r"\bdnf\b",
        r"\byum\b",
        r"\bpacman\b",
        r"\bnpm\s+install\b",
        r"\bpip\s+install\b",
        r"\bgit\s+commit\b",
        r"\bgit\s+push\b",
        r"\bcurl\s+.*\s-x\s+(post|put|delete)\b",
        r"\bwget\s+.*--post-data\b",
        r"\bsudo\b",
        r">",  # redirection
        r"\btee\b",
        r"\bsed\s+-i\b",
    ]
    for pat in blocked_patterns:
        if re.search(pat, lower):
            return False, f"Blocked by read-only policy (pattern: {pat}). Use --allow-writes 1 to override."

    # Heuristic: block likely mutating subcommands even when invoked via python/scripts
    mutating_words = [" add-", " create", " cancel", " confirm", " deny", " delete", " send "]
    if "python" in lower or "/root/clawd/skills/" in lower:
        for w in mutating_words:
            if w in lower:
                return False, f"Blocked by read-only policy (suspected mutating operation: {w.strip()})."

    return True, ""


def tool_shell(args: Dict[str, Any], allow_writes: bool, tool_timeout_sec: int) -> Dict[str, Any]:
    cmd = str(args.get("cmd") or "").strip()
    if not cmd:
        return {"ok": False, "error": "Missing args.cmd"}
    ok, reason = shell_policy_check(cmd, allow_writes=allow_writes)
    if not ok:
        return {"ok": False, "error": reason}

    cwd = args.get("cwd")
    timeout = int(args.get("timeout_sec") or tool_timeout_sec)
    try:
        p = subprocess.run(
            cmd,
            shell=True,
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=os.environ.copy(),
        )
        return {
            "ok": True,
            "exit_code": p.returncode,
            "stdout": safe_truncate(p.stdout or "", 20000),
            "stderr": safe_truncate(p.stderr or "", 20000),
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"shell timeout after {timeout}s"}
    except Exception as e:
        return {"ok": False, "error": f"shell error: {e}"}


def tool_read_file(args: Dict[str, Any]) -> Dict[str, Any]:
    path = str(args.get("path") or "").strip()
    if not path:
        return {"ok": False, "error": "Missing args.path"}
    max_bytes = int(args.get("max_bytes") or 20000)
    try:
        data = Path(path).read_bytes()
        return {"ok": True, "path": path, "bytes": len(data), "content": safe_truncate(data.decode("utf-8", "replace"), max_bytes)}
    except Exception as e:
        return {"ok": False, "error": f"read_file error: {e}"}


def tool_web_search(args: Dict[str, Any]) -> Dict[str, Any]:
    """
    Lightweight web search via Brave Search API.
    This is a deterministic alternative to scraping JS-heavy sources (e.g. Google News).
    """
    query = str(args.get("query") or args.get("q") or "").strip()
    if not query:
        return {"ok": False, "error": "Missing args.query"}
    count = int(args.get("count") or 5)
    count = max(1, min(count, 10))

    api_key = get_brave_api_key()
    if not api_key:
        return {"ok": False, "error": "BRAVE_API_KEY not configured (env or daily-tech-news.py missing)."}

    try:
        r = requests.get(
            BRAVE_SEARCH_URL,
            headers={"X-Subscription-Token": api_key, "User-Agent": "clawdbot-twinmind-wrapper/1.0"},
            params={"q": query, "count": count},
            timeout=20,
        )
        if r.status_code != 200:
            return {"ok": False, "error": f"Brave search error: HTTP {r.status_code}: {safe_truncate(r.text, 800)}"}
        data = r.json()
        results = []
        for it in (data.get("web") or {}).get("results") or []:
            results.append(
                {
                    "title": (it.get("title") or "").strip(),
                    "url": (it.get("url") or "").strip(),
                    "description": (it.get("description") or "").strip(),
                }
            )
        return {"ok": True, "query": query, "count": count, "results": results}
    except Exception as e:
        return {"ok": False, "error": f"web_search error: {e}"}


def tool_web_fetch(args: Dict[str, Any]) -> Dict[str, Any]:
    """
    Fetch a URL and return a text approximation (HTML stripped).
    This does NOT run JavaScript.
    """
    url = str(args.get("url") or "").strip()
    if not (url.startswith("http://") or url.startswith("https://")):
        return {"ok": False, "error": "Missing/invalid args.url (must start with http/https)"}
    max_chars = int(args.get("max_chars") or 20000)
    max_chars = max(500, min(max_chars, 50000))
    try:
        r = requests.get(url, timeout=30, headers={"User-Agent": "clawdbot-web-fetch/1.0"})
        ctype = (r.headers.get("content-type") or "").lower()
        body = r.text or ""
        if "text/html" in ctype or "<html" in body.lower():
            # Strip scripts/styles and tags; keep it simple and deterministic.
            body = re.sub(r"(?is)<(script|style)[^>]*>.*?</\\1>", " ", body)
            body = re.sub(r"(?is)<[^>]+>", " ", body)
            body = re.sub(r"\\s+", " ", body).strip()
        return {"ok": True, "url": url, "status": r.status_code, "content_type": ctype, "text": safe_truncate(body, max_chars)}
    except Exception as e:
        return {"ok": False, "error": f"web_fetch error: {e}"}


def tool_skill_run(args: Dict[str, Any], allow_writes: bool, tool_timeout_sec: int) -> Dict[str, Any]:
    skill = str(args.get("skill") or "").strip()
    sargs = args.get("args") or {}
    if not skill:
        return {"ok": False, "error": "Missing args.skill"}
    if not isinstance(sargs, dict):
        return {"ok": False, "error": "args.args must be an object"}

    sharezone = "/root/clawd/skills/sharezone/scripts/sharezone_client.py"
    schulcloud = "/root/clawd/skills/brandenburg-schulcloud/scripts/schulcloud_plan.py"
    remind_one = "/root/clawd/skills/remind-me/create-reminder.sh"
    remind_rec = "/root/clawd/skills/remind-me/create-recurring.sh"
    memory_sync = "/root/clawd/skills/twinmind-orchestrator/scripts/twinmind_memory_sync.py"
    memory_query = "/root/clawd/skills/twinmind-orchestrator/scripts/twinmind_memory_query.py"
    youtube_intel = "/root/clawd/skills/youtube-intel/scripts/youtube_intel.py"

    # Read-only actions
    if skill == "sharezone.list_courses":
        cmd = ["python3", sharezone, "list-courses"]
    elif skill == "sharezone.list_classes":
        cmd = ["python3", sharezone, "list-classes"]
    elif skill == "sharezone.list_homework":
        cmd = ["python3", sharezone, "list-homework"]
        if bool(sargs.get("all")):
            cmd.append("--all")
    elif skill == "sharezone.list_lessons":
        cmd = ["python3", sharezone, "list-lessons"]
        weekday = sargs.get("weekday")
        if weekday:
            cmd += ["--weekday", str(weekday)]

    # Write actions (require allow_writes)
    elif skill == "sharezone.add_homework":
        if not allow_writes:
            return {"ok": False, "error": "Blocked by read-only policy. Re-run with --allow-writes 1."}
        cmd = [
            "python3",
            sharezone,
            "add-homework",
            "--course",
            str(sargs.get("course") or ""),
            "--title",
            str(sargs.get("title") or ""),
            "--description",
            str(sargs.get("description") or ""),
            "--due",
            str(sargs.get("due") or ""),
        ]
    elif skill == "sharezone.add_event":
        if not allow_writes:
            return {"ok": False, "error": "Blocked by read-only policy. Re-run with --allow-writes 1."}
        cmd = [
            "python3",
            sharezone,
            "add-event",
            "--course",
            str(sargs.get("course") or ""),
            "--title",
            str(sargs.get("title") or ""),
            "--date",
            str(sargs.get("date") or ""),
            "--start",
            str(sargs.get("start") or ""),
            "--end",
            str(sargs.get("end") or ""),
        ]
        detail = sargs.get("detail")
        if detail:
            cmd += ["--detail", str(detail)]
        place = sargs.get("place")
        if place:
            cmd += ["--place", str(place)]
        etype = sargs.get("type")
        if etype:
            cmd += ["--type", str(etype)]
        if bool(sargs.get("notify")):
            cmd.append("--notify")
    elif skill == "sharezone.cancel_lesson":
        if not allow_writes:
            return {"ok": False, "error": "Blocked by read-only policy. Re-run with --allow-writes 1."}
        cmd = [
            "python3",
            sharezone,
            "cancel-lesson",
            "--lesson-id",
            str(sargs.get("lesson_id") or ""),
            "--date",
            str(sargs.get("date") or ""),
        ]
        if bool(sargs.get("notify")):
            cmd.append("--notify")
    # Schulcloud actions
    elif skill in ("schulcloud.get_substitution_plan", "schulcloud.get_plan"):
        # Produce a summary text without sending WhatsApp messages and without Sharezone sync.
        cmd = ["python3", schulcloud]
    elif skill in ("schulcloud.send_substitution_plan", "schulcloud.send_plan"):
        # Trigger the configured WhatsApp send (target comes from env / .env).
        # This is allowed even when allow_writes is false, because it is a messaging side-effect,
        # not a filesystem mutation. Sharezone sync is still gated by env (SHAREZONE_SYNC).
        cmd = ["python3", schulcloud]
        if bool(sargs.get("force")):
            cmd.append("--force")
    elif skill == "schulcloud.check_and_send":
        # Cron-safe: check and send only if changed (no --force).
        cmd = ["python3", schulcloud]
    # Reminders
    elif skill == "remind_me.set":
        # Safe write: creates a one-time cron job for the user. Allow even in read-only mode.
        msg = str(sargs.get("message") or sargs.get("text") or "").strip()
        when = str(sargs.get("when") or "").strip()

        # Accept legacy/alternate schemas from LLMs:
        # - {"delay_minutes": 5, "message": "..."}
        # - {"delay_seconds": 300, "message": "..."}
        # - {"minutes": 5, "message": "..."}
        if not when:
            dm = sargs.get("delay_minutes", sargs.get("minutes"))
            ds = sargs.get("delay_seconds", sargs.get("seconds"))
            try:
                if dm is not None and str(dm).strip() != "":
                    when = f"in {int(dm)} minutes"
                elif ds is not None and str(ds).strip() != "":
                    secs = int(ds)
                    mins = max(1, int(round(secs / 60.0)))
                    when = f"in {mins} minutes"
            except Exception:
                when = ""

        if not msg:
            msg = "Reminder"
        if not when:
            return {"ok": False, "error": "remind_me.set requires args.when (or args.delay_minutes/args.delay_seconds) and args.message"}
        cmd = ["bash", remind_one, msg, when]
    elif skill == "remind_me.set_recurring":
        # Safe write: creates a recurring cron job for the user. Allow even in read-only mode.
        msg = str(sargs.get("message") or "").strip()
        schedule = str(sargs.get("schedule") or "").strip()
        if not msg or not schedule:
            return {"ok": False, "error": "remind_me.set_recurring requires args.message and args.schedule"}
        cmd = ["bash", remind_rec, msg, schedule]
    elif skill == "remind_me.list":
        # Read-only: show recent reminder log + pending cron jobs.
        cmd = ["bash", "-lc", "test -f \"$HOME/clawd/reminders.md\" && tail -n 50 \"$HOME/clawd/reminders.md\" || echo \"(no reminders log yet)\""]
    elif skill == "twinmind.memory_sync":
        cmd = ["python3", memory_sync]
        limit = sargs.get("limit")
        max_pages = sargs.get("max_pages")
        if limit is not None and str(limit).strip():
            cmd += ["--limit", str(limit)]
        if max_pages is not None and str(max_pages).strip():
            cmd += ["--max-pages", str(max_pages)]
        if bool(sargs.get("distinct_by_meeting")):
            cmd.append("--distinct-by-meeting")
        if bool(sargs.get("raw")):
            cmd.append("--raw")
        if bool(sargs.get("json")):
            cmd.append("--json")
    elif skill == "twinmind.memory_search":
        query_text = str(sargs.get("query") or "").strip()
        if not query_text:
            return {"ok": False, "error": "twinmind.memory_search requires args.query"}
        cmd = ["python3", memory_query, "search", "--query", query_text]
        limit = sargs.get("limit")
        if limit is not None and str(limit).strip():
            cmd += ["--limit", str(limit)]
        if bool(sargs.get("json")):
            cmd.append("--json")
    elif skill == "twinmind.memory_get":
        memory_id = str(sargs.get("id") or sargs.get("memory_id") or "").strip()
        if not memory_id:
            return {"ok": False, "error": "twinmind.memory_get requires args.id"}
        cmd = ["python3", memory_query, "get", "--id", memory_id]
        if bool(sargs.get("json")):
            cmd.append("--json")
    elif skill == "youtube.get_transcript":
        url = str(sargs.get("url") or sargs.get("video_url") or "").strip()
        if not url:
            return {"ok": False, "error": "youtube.get_transcript requires args.url"}
        cmd = ["python3", youtube_intel, "get-transcript", "--url", url]
        language = str(sargs.get("language") or "").strip()
        if language:
            cmd += ["--language", language]
        max_chars = sargs.get("max_chars")
        if max_chars is not None and str(max_chars).strip():
            cmd += ["--max-chars", str(max_chars)]
    elif skill == "youtube.summarize":
        url = str(sargs.get("url") or sargs.get("video_url") or "").strip()
        if not url:
            return {"ok": False, "error": "youtube.summarize requires args.url"}
        cmd = ["python3", youtube_intel, "summarize", "--url", url]
        question = str(sargs.get("question") or "").strip()
        if question:
            cmd += ["--question", question]
        language = str(sargs.get("language") or "").strip()
        if language:
            cmd += ["--language", language]
        detail_level = str(sargs.get("detail_level") or "").strip()
        if detail_level:
            cmd += ["--detail-level", detail_level]
        max_points = sargs.get("max_points")
        if max_points is not None and str(max_points).strip():
            cmd += ["--max-points", str(max_points)]
        if bool(sargs.get("force_async")):
            cmd.append("--force-async")
    elif skill == "youtube.job_status":
        job_id = str(sargs.get("job_id") or "").strip()
        if not job_id:
            return {"ok": False, "error": "youtube.job_status requires args.job_id"}
        cmd = ["python3", youtube_intel, "job-status", "--job-id", job_id]
    else:
        return {"ok": False, "error": f"Unknown skill action: {skill}"}

    timeout = int(sargs.get("timeout_sec") or tool_timeout_sec)
    try:
        env = os.environ.copy()
        # For "get" mode, ensure we don't send outbound messages or change Sharezone.
        if skill in ("schulcloud.get_substitution_plan", "schulcloud.get_plan"):
            env["SCHULCLOUD_WHATSAPP_TARGET"] = ""
            env["SHAREZONE_SYNC"] = "0"
            env["SCHULCLOUD_ONLY_ON_CHANGE"] = "0"
        # For the cron-safe "check_and_send", keep only-on-change enabled.
        if skill == "schulcloud.check_and_send":
            env.setdefault("SCHULCLOUD_ONLY_ON_CHANGE", "1")
        # For "send" mode, if invoked from a live WhatsApp chat via the gateway,
        # send back to the originating chat by default.
        if skill in ("schulcloud.send_substitution_plan", "schulcloud.send_plan"):
            env["SCHULCLOUD_PRINT_SEND_RESULT"] = "0"
            explicit_target = (str(sargs.get("target") or "")).strip()
            if explicit_target:
                env["SCHULCLOUD_WHATSAPP_TARGET"] = explicit_target
            else:
                chat_id = infer_origin_chat_id()
                if chat_id:
                    env["SCHULCLOUD_WHATSAPP_TARGET"] = chat_id
        # For reminder skills, pass an explicit delivery target if we can infer one.
        if skill in ("remind_me.set", "remind_me.set_recurring"):
            env.setdefault("REMINDER_CHANNEL", "whatsapp")
            explicit_to = (str(sargs.get("to") or "")).strip()
            if explicit_to:
                env["REMINDER_TO"] = explicit_to
            else:
                origin = (str(sargs.get("origin") or "")).strip()
                if origin:
                    env["REMINDER_TO"] = origin
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return {
            "ok": p.returncode == 0,
            "exit_code": p.returncode,
            "stdout": safe_truncate(p.stdout or "", 20000),
            "stderr": safe_truncate(p.stderr or "", 20000),
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"skill_run timeout after {timeout}s"}
    except Exception as e:
        return {"ok": False, "error": f"skill_run error: {e}"}


def execute_tool(tool: str, args: Dict[str, Any], allow_writes: bool, tool_timeout_sec: int) -> Dict[str, Any]:
    if tool == "shell":
        # If TwinMind tries to run a known skill script via shell, rewrite it into skill_run (more reliable).
        cmd = str(args.get("cmd") or "")
        sharezone_rewrites = {
            "list-courses": "sharezone.list_courses",
            "list-classes": "sharezone.list_classes",
            "list-homework": "sharezone.list_homework",
            "list-lessons": "sharezone.list_lessons",
            "add-homework": "sharezone.add_homework",
            "add-event": "sharezone.add_event",
            "cancel-lesson": "sharezone.cancel_lesson",
        }
        if "/root/clawd/skills/sharezone/scripts/sharezone_client.py" in cmd:
            m = re.search(r"sharezone_client\.py\s+([a-z-]+)", cmd)
            if m and m.group(1) in sharezone_rewrites:
                rewritten = {
                    "skill": sharezone_rewrites[m.group(1)],
                    "args": {},
                }
                result = tool_skill_run(rewritten, allow_writes=allow_writes, tool_timeout_sec=tool_timeout_sec)
                result["rewritten_from_shell"] = True
                result["original_cmd"] = safe_truncate(cmd, 500)
                return result
        return tool_shell(args, allow_writes=allow_writes, tool_timeout_sec=tool_timeout_sec)
    if tool == "read_file":
        return tool_read_file(args)
    if tool == "web_search":
        return tool_web_search(args)
    if tool == "web_fetch":
        return tool_web_fetch(args)
    if tool == "skill_run":
        return tool_skill_run(args, allow_writes=allow_writes, tool_timeout_sec=tool_timeout_sec)
    return {"ok": False, "error": f"Unknown tool: {tool}"}


@dataclass
class OrchestratorConfig:
    mode: str
    api_base: str
    endpoint: str
    model_name: str
    provider: str
    reasoning_budget: int
    reasoning_enabled: bool
    search_all_memories: bool
    search_web: bool
    max_steps: int
    max_tool_calls: int
    repair_attempts: int
    llm_timeout_sec: int
    tool_timeout_sec: int
    allow_shell: bool
    allow_writes: bool
    debug: bool
    user_profile: str
    routing_mode: str
    executor_provider: str
    executor_model: str
    executor_base_url: str
    executor_api_key: str
    executor_timeout_sec: int
    executor_max_steps: int
    executor_max_tool_calls: int
    executor_max_output_tokens: int
    executor_reasoning_effort: str
    executor_use_twinmind_planner: bool


def write_log(log_path: Path, entry: Dict[str, Any]) -> None:
    entry = dict(entry)
    entry.setdefault("ts", utc_now_iso())
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


def call_twinmind(
    cfg: OrchestratorConfig,
    id_token: str,
    session_id: str,
    query: str,
    current_context: Dict[str, Any],
    log_path: Path,
) -> Tuple[str, Dict[str, int], int, str]:
    url = f"{cfg.api_base}{cfg.endpoint}"
    headers = {
        "Authorization": f"Bearer {id_token}",
        "Content-Type": "application/json",
        "User-Agent": getenv("TWINMIND_USER_AGENT", DEFAULT_USER_AGENT) or DEFAULT_USER_AGENT,
    }
    bypass = getenv("TWINMIND_VERCEL_BYPASS")
    if bypass:
        headers["x-vercel-protection-bypass"] = bypass

    payload = mk_request_payload(
        query=query,
        session_id=session_id,
        model_name=cfg.model_name,
        provider=cfg.provider,
        reasoning_budget=cfg.reasoning_budget,
        reasoning_enabled=cfg.reasoning_enabled,
        search_all_memories=cfg.search_all_memories,
        search_web=cfg.search_web,
        current_context=current_context,
        user_profile=cfg.user_profile,
    )

    write_log(log_path, {"event": "llm_request", "url": url, "session_id": session_id, "query_preview": query[:500], "payload_meta": {"model_name": cfg.model_name, "provider": cfg.provider}})

    # Retry transient errors. Keep retries small so gateway replies do not stall.
    retry_count = int(getenv("TWINMIND_LLM_RETRIES", "0") or "0")
    retry_count = max(0, min(retry_count, 3))
    max_attempts = retry_count + 1
    backoff = 1.0
    last_status = 0
    last_body = ""
    for attempt in range(0, max_attempts):
        try:
            resp = http_post_stream(url, headers=headers, payload=payload, timeout_sec=cfg.llm_timeout_sec)
            last_status = resp.status_code
            if resp.status_code == 401:
                # caller should refresh token
                return "", {}, 401, resp.text[:500]
            if resp.status_code != 200:
                last_body = resp.text[:1000]
                if is_transient_http(resp.status_code) and attempt < (max_attempts - 1):
                    time.sleep(backoff)
                    backoff *= 2
                    continue
                return "", {}, resp.status_code, last_body
            raw, events = sse_last_content(resp, read_timeout_sec=cfg.llm_timeout_sec, debug=cfg.debug)
            write_log(log_path, {"event": "llm_response", "session_id": session_id, "status": resp.status_code, "events": events, "raw_preview": raw[:1000]})
            return raw, events, 200, ""
        except Exception as e:
            last_body = str(e)
            write_log(log_path, {"event": "llm_attempt_error", "session_id": session_id, "attempt": attempt + 1, "error": safe_truncate(last_body, 800)})
            # For SSE timeouts after HTTP 200, avoid long retry loops.
            if last_status == 200 and "SSE read timeout" in last_body:
                return "", {}, 200, last_body[:1000]
            if attempt < (max_attempts - 1):
                time.sleep(backoff)
                backoff *= 2
                continue
            return "", {}, last_status or 0, last_body[:1000]
    return "", {}, last_status, last_body[:1000]


def call_twinmind_with_refresh(
    cfg: OrchestratorConfig,
    id_token: str,
    refresh_token: str,
    firebase_api_key: str,
    session_id: str,
    query: str,
    current_context: Dict[str, Any],
    log_path: Path,
) -> Tuple[str, Dict[str, int], int, str, str]:
    raw, events, status, err = call_twinmind(cfg, id_token, session_id, query, current_context, log_path)
    new_id_token = id_token
    if status == 401:
        try:
            new_id_token = get_id_token(refresh_token, firebase_api_key)
        except Exception as e:
            return raw, events, status, f"{err} | token_refresh_failed: {e}", id_token
        raw, events, status, err = call_twinmind(cfg, new_id_token, session_id, query, current_context, log_path)
    return raw, events, status, err, new_id_token


def _coerce_openai_message_text(value: Any) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, dict):
        for key in ("text", "content", "reasoning_content", "reasoning"):
            v = value.get(key)
            if isinstance(v, str) and v.strip():
                return v.strip()
        return ""
    if isinstance(value, list):
        chunks: List[str] = []
        for part in value:
            txt = _coerce_openai_message_text(part)
            if txt:
                chunks.append(txt)
        return "\n".join(chunks).strip()
    return ""


def extract_openai_chat_text(payload: Dict[str, Any]) -> str:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        return ""
    first = choices[0] if isinstance(choices[0], dict) else {}
    msg = first.get("message") if isinstance(first, dict) else {}
    if not isinstance(msg, dict):
        return ""

    # Prefer assistant content; then fall back to vendor-specific reasoning fields.
    for key in ("content", "reasoning_content", "reasoning"):
        txt = _coerce_openai_message_text(msg.get(key))
        if txt:
            return txt
    return ""


def _parse_expiry_timestamp(value: Any) -> Optional[float]:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        val = float(value)
        if val > 1e12:
            val = val / 1000.0
        return val
    if isinstance(value, str):
        raw = value.strip()
        if not raw:
            return None
        if re.fullmatch(r"\d+(?:\.\d+)?", raw):
            val = float(raw)
            if val > 1e12:
                val = val / 1000.0
            return val
        try:
            parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=dt.timezone.utc)
            return parsed.timestamp()
        except Exception:
            return None
    return None


def _load_codex_oauth_access_token() -> Tuple[str, str]:
    preferred_profile = (getenv("ORCH_EXECUTOR_CODEX_PROFILE", "openai-codex:codex-cli") or "openai-codex:codex-cli").strip()
    for profile_path in AUTH_PROFILE_PATHS:
        try:
            if not os.path.exists(profile_path):
                continue
            with open(profile_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, dict):
                continue
            profiles = data.get("profiles")
            if not isinstance(profiles, dict):
                continue
            selected: Optional[Dict[str, Any]] = None
            if preferred_profile in profiles and isinstance(profiles.get(preferred_profile), dict):
                selected = profiles.get(preferred_profile)
            if selected is None:
                for name, profile in profiles.items():
                    if not isinstance(profile, dict):
                        continue
                    low_name = str(name).lower()
                    if low_name.startswith("openai-codex:") or low_name.startswith("openai:"):
                        selected = profile
                        break
            if not selected:
                continue
            creds = selected.get("credentials") if isinstance(selected.get("credentials"), dict) else selected
            if not isinstance(creds, dict):
                continue
            access = str(creds.get("access") or creds.get("access_token") or "").strip()
            if not access:
                continue
            expires_at = _parse_expiry_timestamp(creds.get("expires") or creds.get("expires_at"))
            if expires_at is not None and expires_at <= (time.time() + 30):
                return "", f"Codex OAuth token expired in {profile_path}; refresh Codex auth."
            return access, ""
        except Exception:
            continue
    return "", "Missing Codex OAuth token in auth profiles."


def resolve_executor_api_key(cfg: OrchestratorConfig) -> Tuple[str, str]:
    provider = (cfg.executor_provider or "").strip().lower()
    explicit = (cfg.executor_api_key or "").strip()
    if provider in {"openai_codex", "openai", "codex"}:
        if explicit and (not explicit.startswith("nvapi-")):
            return explicit, ""
        openai_key = (getenv("OPENAI_API_KEY", "") or "").strip()
        if openai_key:
            return openai_key, ""
        orch_key = (getenv("ORCH_EXECUTOR_API_KEY", "") or "").strip()
        if orch_key and (not orch_key.startswith("nvapi-")):
            return orch_key, ""
        oauth_access, oauth_err = _load_codex_oauth_access_token()
        if oauth_access:
            return oauth_access, ""
        return "", oauth_err or "Missing OPENAI_API_KEY / Codex OAuth token."
    if explicit:
        return explicit, ""
    if provider in {"glm_nvidia", "nvidia", "nvidia_glm"}:
        key = (getenv("ORCH_EXECUTOR_API_KEY", "") or "").strip() or (getenv("NVIDIA_API_KEY", "") or "").strip()
        if key:
            return key, ""
        return "", "Missing NVIDIA_API_KEY / ORCH_EXECUTOR_API_KEY"
    generic = (getenv("ORCH_EXECUTOR_API_KEY", "") or "").strip()
    if generic:
        return generic, ""
    return "", "Missing ORCH_EXECUTOR_API_KEY"


def call_executor(
    cfg: OrchestratorConfig,
    session_id: str,
    query: str,
    current_context: Dict[str, Any],
    log_path: Path,
) -> Tuple[str, Dict[str, int], int, str]:
    provider = (cfg.executor_provider or "").strip().lower()
    if provider in {"codex_cli", "codex-cli"}:
        codex_bin = (getenv("ORCH_EXECUTOR_CODEX_BIN", "codex") or "codex").strip()
        resolved_bin = shutil.which(codex_bin) or codex_bin
        sandbox_mode = (getenv("ORCH_EXECUTOR_CODEX_SANDBOX", "read-only") or "read-only").strip()
        codex_cwd = (getenv("ORCH_EXECUTOR_CODEX_CWD", "/root") or "/root").strip()
        system_prompt = (
            "You are the tool executor model. "
            "Follow the TOOL PROTOCOL in the user message strictly and return exactly one JSON object."
        )
        user_content = (
            f"{query}\n\n"
            "EXECUTOR_CONTEXT_JSON:\n"
            + json.dumps(current_context or {}, ensure_ascii=False)
        )
        prompt = (
            "SYSTEM:\n"
            + system_prompt
            + "\n\nUSER:\n"
            + user_content
            + "\n\nIMPORTANT:\n"
            + "Return ONLY one JSON object. Do not run shell commands or external tools."
        )
        retries = int(getenv("ORCH_EXECUTOR_RETRIES", "1") or "1")
        retries = max(0, min(retries, 3))
        max_attempts = retries + 1
        backoff = 1.0
        last_err = ""
        for attempt in range(0, max_attempts):
            out_path = ""
            try:
                with tempfile.NamedTemporaryFile(prefix="orch-executor-", suffix=".txt", delete=False) as tmp:
                    out_path = tmp.name
                cmd: List[str] = [
                    resolved_bin,
                    "exec",
                    "--skip-git-repo-check",
                    "--sandbox",
                    sandbox_mode,
                    "--output-last-message",
                    out_path,
                ]
                if (cfg.executor_model or "").strip():
                    cmd += ["--model", cfg.executor_model.strip()]
                cmd += [prompt]

                write_log(
                    log_path,
                    {
                        "event": "executor_request",
                        "executor": {"provider": cfg.executor_provider, "model": cfg.executor_model, "bin": resolved_bin, "sandbox": sandbox_mode},
                        "session_id": session_id,
                        "query_preview": safe_truncate(query, 500),
                    },
                )

                proc = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=int(cfg.executor_timeout_sec),
                    cwd=codex_cwd if os.path.isdir(codex_cwd) else None,
                )
                raw = ""
                try:
                    if out_path and os.path.exists(out_path):
                        raw = Path(out_path).read_text(encoding="utf-8", errors="replace").strip()
                except Exception:
                    raw = ""
                if not raw:
                    raw = (proc.stdout or "").strip()
                if proc.returncode != 0:
                    last_err = safe_truncate((proc.stderr or proc.stdout or "").strip(), 1200)
                    if attempt < (max_attempts - 1):
                        time.sleep(backoff)
                        backoff *= 2
                        continue
                    write_log(
                        log_path,
                        {
                            "event": "executor_response",
                            "status": 502,
                            "error_preview": safe_truncate(last_err, 500),
                            "session_id": session_id,
                        },
                    )
                    return "", {}, 502, (last_err or "codex_cli executor failed")
                write_log(
                    log_path,
                    {
                        "event": "executor_response",
                        "status": 200,
                        "session_id": session_id,
                        "raw_preview": safe_truncate(raw, 800),
                    },
                )
                return raw, {}, 200, ""
            except subprocess.TimeoutExpired:
                last_err = f"codex_cli timed out after {int(cfg.executor_timeout_sec)}s"
                if attempt < (max_attempts - 1):
                    time.sleep(backoff)
                    backoff *= 2
                    continue
                return "", {}, 504, last_err
            except Exception as e:
                last_err = safe_truncate(str(e), 1000)
                if attempt < (max_attempts - 1):
                    time.sleep(backoff)
                    backoff *= 2
                    continue
                return "", {}, 502, last_err
            finally:
                try:
                    if out_path and os.path.exists(out_path):
                        os.unlink(out_path)
                except Exception:
                    pass
        return "", {}, 502, (last_err or "codex_cli executor failed")

    base = (cfg.executor_base_url or "").strip().rstrip("/")
    if not base:
        return "", {}, 500, "Missing executor base URL"
    api_key, key_err = resolve_executor_api_key(cfg)
    if not api_key:
        return "", {}, 401, key_err

    url = f"{base}/chat/completions"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "User-Agent": getenv("TWINMIND_USER_AGENT", DEFAULT_USER_AGENT) or DEFAULT_USER_AGENT,
    }
    system_prompt = (
        "You are the tool executor model. "
        "Follow the TOOL PROTOCOL in the user message strictly and return exactly one JSON object."
    )
    user_content = (
        f"{query}\n\n"
        "EXECUTOR_CONTEXT_JSON:\n"
        + json.dumps(current_context or {}, ensure_ascii=False)
    )
    payload: Dict[str, Any] = {
        "model": cfg.executor_model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content},
        ],
        "temperature": 0,
        "max_tokens": int(cfg.executor_max_output_tokens),
    }
    reasoning_effort = (cfg.executor_reasoning_effort or "").strip().lower()
    if reasoning_effort in {"minimal", "low", "medium", "high"} and (cfg.executor_provider or "").strip().lower() in {"openai_codex", "openai", "codex"}:
        payload["reasoning"] = {"effort": reasoning_effort}

    write_log(
        log_path,
        {
            "event": "executor_request",
            "executor": {"provider": cfg.executor_provider, "model": cfg.executor_model, "url": url},
            "session_id": session_id,
            "query_preview": safe_truncate(query, 500),
        },
    )

    retries = int(getenv("ORCH_EXECUTOR_RETRIES", "1") or "1")
    retries = max(0, min(retries, 3))
    max_attempts = retries + 1
    backoff = 1.0
    last_status = 0
    last_body = ""

    for attempt in range(0, max_attempts):
        try:
            resp = requests.post(url, headers=headers, json=payload, timeout=(20, int(cfg.executor_timeout_sec)))
            last_status = int(resp.status_code)
            if resp.status_code != 200:
                last_body = safe_truncate(resp.text or "", 1200)
                if is_transient_http(resp.status_code) and attempt < (max_attempts - 1):
                    time.sleep(backoff)
                    backoff *= 2
                    continue
                write_log(
                    log_path,
                    {
                        "event": "executor_response",
                        "status": resp.status_code,
                        "error_preview": last_body[:500],
                        "session_id": session_id,
                    },
                )
                return "", {}, int(resp.status_code), last_body

            data = resp.json() if resp.content else {}
            answer = extract_openai_chat_text(data if isinstance(data, dict) else {})
            usage_raw = data.get("usage") if isinstance(data, dict) else {}
            usage = {
                "input": int((usage_raw or {}).get("prompt_tokens") or 0),
                "output": int((usage_raw or {}).get("completion_tokens") or 0),
                "total": int((usage_raw or {}).get("total_tokens") or 0),
            }
            if not answer:
                # Return a compact machine-readable fallback for repair handling.
                answer = safe_truncate(json.dumps(data, ensure_ascii=False), 1200)
            write_log(
                log_path,
                {
                    "event": "executor_response",
                    "status": 200,
                    "session_id": session_id,
                    "usage": usage,
                    "raw_preview": safe_truncate(answer, 800),
                },
            )
            return answer, usage, 200, ""
        except Exception as e:
            last_body = str(e)
            if attempt < (max_attempts - 1):
                time.sleep(backoff)
                backoff *= 2
                continue
            return "", {}, (last_status or 0), safe_truncate(last_body, 1000)

    return "", {}, last_status, safe_truncate(last_body, 1000)


def build_repair_prompt(err: str, last_output: str) -> str:
    # Keep it short and extremely explicit.
    return (
        "REPAIR: Your last output did not match the required JSON protocol.\n"
        f"Error: {err}\n"
        "Return ONLY ONE JSON object, no markdown, no prose.\n"
        "Reminder: wrapper tools ARE available; do not claim they are unavailable.\n"
        "Valid examples:\n"
        '{"action":"tool_call","id":"<uuid>","tool":"shell","args":{"cmd":"ls -la","cwd":"/root"}}\n'
        '{"action":"final","answer":"..."}\n'
        "Your last output was:\n"
        + safe_truncate(last_output, 1500)
    )


def main() -> None:
    load_env_files(ENV_PATHS)
    parser = argparse.ArgumentParser(description="TwinMind Orchestrator (conversation + optional tool-call bridge)")
    # Support both explicit flag and positional query so this script can be used
    # as a Clawdbot CLI backend (which appends the prompt as the last argv token).
    parser.add_argument("--query", required=False, help="User query / task")
    parser.add_argument("query_pos", nargs="?", help="User query / task (positional)")
    parser.add_argument("--session-id", default=None)
    parser.add_argument("--new-session", action="store_true")
    parser.add_argument(
        "--mode",
        choices=["conversation", "tool_bridge"],
        default=getenv("TWINMIND_MODE", "conversation") or "conversation",
        help="conversation=plain TwinMind chat (default), tool_bridge=strict JSON tool protocol.",
    )
    parser.add_argument("--model-name", default=getenv("TWINMIND_MODEL_NAME", "claude-opus-4-6"))
    parser.add_argument("--provider", default=getenv("TWINMIND_PROVIDER", "anthropic"))
    parser.add_argument("--reasoning-budget", type=int, default=int(getenv("TWINMIND_REASONING_BUDGET", "8000") or "8000"))
    parser.add_argument("--reasoning-enabled", type=int, default=int(getenv("TWINMIND_REASONING_ENABLED", "1") or "1"))
    parser.add_argument("--search-web", type=int, default=int(getenv("TWINMIND_SEARCH_WEB", "1") or "1"))
    parser.add_argument("--search-memories", type=int, default=int(getenv("TWINMIND_SEARCH_MEMORIES", "1") or "1"))
    parser.add_argument("--max-steps", type=int, default=int(getenv("TWINMIND_MAX_STEPS", "8") or "8"))
    parser.add_argument("--max-tool-calls", type=int, default=int(getenv("TWINMIND_MAX_TOOL_CALLS", "6") or "6"))
    parser.add_argument("--repair-attempts", type=int, default=int(getenv("TWINMIND_REPAIR_ATTEMPTS", "2") or "2"))
    parser.add_argument("--llm-timeout-sec", type=int, default=int(getenv("TWINMIND_LLM_TIMEOUT_SEC", "120") or "120"))
    parser.add_argument("--tool-timeout-sec", type=int, default=int(getenv("TWINMIND_TOOL_TIMEOUT_SEC", "120") or "120"))
    parser.add_argument("--allow-shell", type=int, default=int(getenv("TWINMIND_ALLOW_SHELL", "1") or "1"))
    parser.add_argument("--allow-writes", type=int, default=int(getenv("TWINMIND_ALLOW_WRITES", "0") or "0"))
    parser.add_argument("--debug", type=int, default=int(getenv("TWINMIND_DEBUG", "0") or "0"))
    parser.add_argument("--user-profile", default=getenv("TWINMIND_USER_PROFILE", ""))
    parser.add_argument(
        "--routing-mode",
        choices=["legacy", "strict_split"],
        default=getenv("ORCH_ROUTING_MODE", "strict_split") or "strict_split",
        help="legacy=single-model bridge, strict_split=TwinMind planner/finalizer + external executor.",
    )
    parser.add_argument("--executor-provider", default=getenv("ORCH_EXECUTOR_PROVIDER", DEFAULT_EXECUTOR_PROVIDER) or DEFAULT_EXECUTOR_PROVIDER)
    parser.add_argument("--executor-model", default=getenv("ORCH_EXECUTOR_MODEL", DEFAULT_EXECUTOR_MODEL) or DEFAULT_EXECUTOR_MODEL)
    parser.add_argument(
        "--executor-base-url",
        default=getenv("ORCH_EXECUTOR_BASE_URL", DEFAULT_EXECUTOR_BASE_URL) or DEFAULT_EXECUTOR_BASE_URL,
    )
    parser.add_argument("--executor-api-key", default=getenv("ORCH_EXECUTOR_API_KEY", "") or "")
    parser.add_argument("--executor-timeout-sec", type=int, default=int(getenv("ORCH_EXECUTOR_TIMEOUT_SEC", "90") or "90"))
    parser.add_argument("--executor-max-steps", type=int, default=int(getenv("ORCH_EXECUTOR_MAX_STEPS", "6") or "6"))
    parser.add_argument(
        "--executor-max-tool-calls",
        type=int,
        default=int(getenv("ORCH_EXECUTOR_MAX_TOOL_CALLS", "8") or "8"),
    )
    parser.add_argument(
        "--executor-max-output-tokens",
        type=int,
        default=int(getenv("ORCH_EXECUTOR_MAX_OUTPUT_TOKENS", "1200") or "1200"),
    )
    parser.add_argument(
        "--executor-reasoning-effort",
        default=getenv("ORCH_EXECUTOR_REASONING_EFFORT", "medium") or "medium",
    )
    parser.add_argument(
        "--executor-use-twinmind-planner",
        type=int,
        default=int(getenv("ORCH_EXECUTOR_USE_TWINMIND_PLANNER", "1") or "1"),
    )
    parser.add_argument(
        "--output",
        choices=["text", "json"],
        default=getenv("TWINMIND_OUTPUT", "text") or "text",
        help="Output format for stdout (text or json). Use json for Clawdbot CLI backend session continuity.",
    )
    args = parser.parse_args()

    raw_user_query = (str(args.query or args.query_pos or "")).strip()
    if not raw_user_query:
        parser.error("missing query: provide --query or a positional query argument")
    user_query = raw_user_query
    sanitized_query = sanitize_inbound_query(raw_user_query) or raw_user_query

    derived_key = derive_user_key_from_query(raw_user_query)
    if derived_key:
        os.environ["TWINMIND_USER_KEY_OVERRIDE"] = derived_key
    run_session_id = get_session_id(args.session_id, bool(args.new_session))

    ensure_state_dirs()
    log_path = LOG_DIR / f"{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}.jsonl"
    dynamic_memory_context_text, dynamic_memory_meta = load_dynamic_memory_context(sanitized_query, log_path)

    def emit_and_exit(
        message: str,
        code: int = 0,
        session_id: Optional[str] = None,
        *,
        ingest_memory: bool = True,
        memory_route: str = "",
    ) -> None:
        """
        Clawdbot uses this script as a JSON CLI backend. Non-zero exits can crash
        the gateway (unhandled failover errors). In JSON output mode, always exit 0.
        """
        sid = session_id or run_session_id
        text_out = (message or "").strip()
        if ingest_memory and text_out:
            ingest_dynamic_memory_turn(
                user_query=sanitized_query,
                assistant_answer=text_out,
                session_id=sid,
                route=(memory_route or "unknown"),
                log_path=log_path,
            )
        if str(args.output).lower() == "json":
            print(json.dumps({"message": text_out, "session_id": sid}, ensure_ascii=False))
            sys.exit(0)
        print(text_out)
        sys.exit(code)

    if is_heartbeat_request(user_query):
        message, meta = evaluate_heartbeat_status()
        write_log(log_path, {"event": "router_decision", "route": "heartbeat_fastpath"})
        write_log(
            log_path,
            {
                "event": "job_provider_selected",
                "provider": "local-heartbeat-check",
                "reason": "heartbeat_request",
                "meta": meta,
            },
        )
        emit_and_exit(message, code=0, ingest_memory=False, memory_route="heartbeat_fastpath")

    # If an inbound message included an image and media-understanding injected a
    # textual description, answer from that directly. This avoids TwinMind's
    # upstream refusals for image messages.
    img = extract_image_understanding(user_query)
    if img:
        write_log(log_path, {"event": "router_decision", "route": "image_fastpath"})
        desc = img["description"].strip()
        # Prefer the user's original text if present; otherwise answer generically.
        q = (img.get("user_text") or "").strip()
        if q:
            message = f"{desc}"
        else:
            message = f"Bildbeschreibung:\n{desc}"
        emit_and_exit(message, code=0, ingest_memory=False, memory_route="image_fastpath")

    # Cron reminder passthrough: avoid LLM usage for simple scheduled reminder deliveries.
    if re.match(r"^\s*(?:\[cron:[^\]]+\]\s*)?⏰\s*Reminder:", user_query):
        stripped_query = re.sub(r"^\s*\[cron:[^\]]+\]\s*", "", user_query).strip()
        write_log(log_path, {"event": "router_decision", "route": "reminder_cron_passthrough"})
        write_log(log_path, {"event": "job_provider_selected", "provider": "local-template", "reason": "cron_reminder_passthrough"})
        emit_and_exit(stripped_query, code=0, ingest_memory=False, memory_route="reminder_cron_passthrough")

    # Fast-path: Schulcloud cron runs should be deterministic and must not depend
    # on any upstream LLM behavior.
    if re.search(r"/root/\.clawdbot/scripts/schulcloud-daily\.sh\b", user_query) or re.search(r"\bschulcloud[- ]daily\b", user_query, re.I):
        write_log(log_path, {"event": "router_decision", "route": "schulcloud_cron_fastpath"})
        write_log(log_path, {"event": "job_provider_selected", "provider": "local-skill-run", "reason": "cron_schulcloud"})
        try:
            acquire_lock()
        except Exception as e:
            emit_and_exit(f"Busy: {e}", code=4, ingest_memory=False, memory_route="schulcloud_cron_fastpath")
        try:
            result = tool_skill_run(
                {"skill": "schulcloud.check_and_send", "args": {}},
                allow_writes=False,
                tool_timeout_sec=int(args.tool_timeout_sec or 120),
            )
            out = tool_result_message(result, default_ok="OK")
            emit_and_exit(out, code=0, ingest_memory=False, memory_route="schulcloud_cron_fastpath")
        finally:
            release_lock()

    cfg = OrchestratorConfig(
        mode=str(args.mode),
        api_base=getenv("TWINMIND_API_BASE", DEFAULT_API_BASE) or DEFAULT_API_BASE,
        endpoint=getenv("TWINMIND_API_ENDPOINT", DEFAULT_ENDPOINT) or DEFAULT_ENDPOINT,
        model_name=str(args.model_name),
        provider=str(args.provider),
        reasoning_budget=int(args.reasoning_budget),
        reasoning_enabled=bool(int(args.reasoning_enabled)),
        search_all_memories=bool(int(args.search_memories)),
        search_web=bool(int(args.search_web)),
        max_steps=int(args.max_steps),
        max_tool_calls=int(args.max_tool_calls),
        repair_attempts=int(args.repair_attempts),
        llm_timeout_sec=int(args.llm_timeout_sec),
        tool_timeout_sec=int(args.tool_timeout_sec),
        allow_shell=bool(int(args.allow_shell)),
        allow_writes=bool(int(args.allow_writes)),
        debug=bool(int(args.debug)),
        user_profile=merged_user_profile(str(args.user_profile or "")),
        routing_mode=str(args.routing_mode),
        executor_provider=str(args.executor_provider),
        executor_model=str(args.executor_model),
        executor_base_url=str(args.executor_base_url),
        executor_api_key=str(args.executor_api_key or ""),
        executor_timeout_sec=int(args.executor_timeout_sec),
        executor_max_steps=int(args.executor_max_steps),
        executor_max_tool_calls=int(args.executor_max_tool_calls),
        executor_max_output_tokens=int(args.executor_max_output_tokens),
        executor_reasoning_effort=str(args.executor_reasoning_effort or ""),
        executor_use_twinmind_planner=bool(int(args.executor_use_twinmind_planner)),
    )
    strict_split = cfg.routing_mode == "strict_split"

    # Fast-path: for certain local-system requests we can deterministically invoke
    # the correct skill without spending LLM tokens. This also avoids occasional
    # SSE stalls in the upstream TwinMind service.
    if (not strict_split) and re.search(r"\b(vertretungsplan|vertretung)\b", user_query, re.I):
        write_log(log_path, {"event": "router_decision", "route": "schulcloud_skill_fastpath"})
        # In interactive gateway chats, users almost always expect the plan image.
        # Default to "send" in that case; keep "get" for CLI usage.
        origin_target = infer_origin_chat_id() or infer_origin_target_from_request_text(user_query)
        is_live_chat = bool(origin_target)
        wants_text_only = bool(re.search(r"\b(nur|only)\b.*\b(text|zusammenfassung|summary)\b|\bohne\s+bild\b", user_query, re.I))
        skill = "schulcloud.send_substitution_plan" if (is_live_chat and not wants_text_only) else "schulcloud.get_substitution_plan"
        if re.search(r"\b(schick|sende|send|poste|post|bild|pdf)\b", user_query, re.I):
            skill = "schulcloud.send_substitution_plan"
        sargs: Dict[str, Any] = {}
        if skill.startswith("schulcloud.send_") and origin_target:
            sargs["target"] = origin_target
        result = tool_skill_run({"skill": skill, "args": sargs}, allow_writes=cfg.allow_writes, tool_timeout_sec=cfg.tool_timeout_sec)
        out = tool_result_message(result, default_ok=("✅" if skill.startswith("schulcloud.send_") else "OK"))
        emit_and_exit(out, code=0, session_id=run_session_id, memory_route="schulcloud_skill_fastpath")

    # Fast-path: one-time reminders (relative "in X ...").
    parsed = parse_one_time_reminder(sanitized_query)
    if (not strict_split) and parsed:
        write_log(log_path, {"event": "router_decision", "route": "reminder_fastpath"})
        msg, when = parsed
        origin_target = infer_origin_chat_id() or infer_origin_target_from_request_text(user_query)
        sargs: Dict[str, Any] = {"message": msg, "when": when}
        if origin_target:
            sargs["origin"] = origin_target
        result = tool_skill_run({"skill": "remind_me.set", "args": sargs}, allow_writes=True, tool_timeout_sec=cfg.tool_timeout_sec)
        out = tool_result_message(result, default_ok="OK")
        emit_and_exit(out, code=0, session_id=run_session_id, memory_route="reminder_fastpath")

    sharezone_route = infer_sharezone_skill(sanitized_query)
    if (not strict_split) and sharezone_route:
        skill, sargs = sharezone_route
        write_log(log_path, {"event": "router_decision", "route": "sharezone_fastpath", "skill": skill})
        result = tool_skill_run({"skill": skill, "args": sargs}, allow_writes=cfg.allow_writes, tool_timeout_sec=cfg.tool_timeout_sec)
        out = tool_result_message(result, default_ok="Keine Daten gefunden.")
        emit_and_exit(out, code=0, session_id=run_session_id, memory_route="sharezone_fastpath")

    memory_route = infer_twinmind_memory_skill(sanitized_query)
    if (not strict_split) and memory_route:
        skill, sargs = memory_route
        write_log(log_path, {"event": "router_decision", "route": "twinmind_memory_fastpath", "skill": skill})
        result = tool_skill_run({"skill": skill, "args": sargs}, allow_writes=cfg.allow_writes, tool_timeout_sec=cfg.tool_timeout_sec)
        out = tool_result_message(result, default_ok="OK")
        emit_and_exit(out, code=0, session_id=run_session_id, memory_route="twinmind_memory_fastpath")

    refresh_token = getenv("TWINMIND_REFRESH_TOKEN")
    explicit_tool_intent = is_tool_mode_requested(raw_user_query) or is_tool_mode_requested(sanitized_query)
    if strict_split and should_force_tool_for_request(sanitized_query):
        explicit_tool_intent = True

    conversation_query = sanitized_query
    pdf_query_meta: Dict[str, Any] = {}
    if cfg.mode == "conversation" and not explicit_tool_intent:
        conversation_query, pdf_query_meta = maybe_enrich_pdf_query(raw_user_query, sanitized_query)
        if pdf_query_meta.get("detected"):
            write_log(
                log_path,
                {
                    "event": "pdf_preprocess",
                    "meta": {
                        "status": pdf_query_meta.get("status"),
                        "source": pdf_query_meta.get("source"),
                        "file_path": pdf_query_meta.get("file_path"),
                        "extract_chars": pdf_query_meta.get("extract_chars"),
                        "used_chars": pdf_query_meta.get("used_chars"),
                        "error": safe_truncate(str(pdf_query_meta.get("error") or ""), 500),
                    },
                },
            )

    if cfg.mode == "conversation" and not explicit_tool_intent:
        write_log(log_path, {"event": "router_decision", "route": "twinmind_conversation"})
        if not refresh_token:
            emit_and_exit("Error: Missing TWINMIND_REFRESH_TOKEN", code=2, memory_route="twinmind_conversation")
        try:
            acquire_lock()
        except Exception as e:
            emit_and_exit(f"Busy: {e}", code=4, memory_route="twinmind_conversation")
        session_id = run_session_id
        firebase_api_key = getenv("TWINMIND_FIREBASE_API_KEY", DEFAULT_FIREBASE_API_KEY) or DEFAULT_FIREBASE_API_KEY
        try:
            id_token = get_id_token(refresh_token, firebase_api_key)
            write_log(
                log_path,
                {
                    "event": "start",
                    "session_id": session_id,
                    "config": {
                        "mode": cfg.mode,
                        "model_name": cfg.model_name,
                        "provider": cfg.provider,
                        "search_web": cfg.search_web,
                        "search_all_memories": cfg.search_all_memories,
                    },
                },
            )
            clean_query = apply_memory_context_to_query(conversation_query, dynamic_memory_context_text)
            current_context = {
                "mode": "conversation",
                "local_time": local_now_iso(),
                "wrapper_policy": {"allow_writes": cfg.allow_writes, "allow_shell": cfg.allow_shell},
                "dynamic_memory_context": dynamic_memory_context_text,
                "dynamic_memory_meta": dynamic_memory_meta,
            }

            raw, events, status, err = call_twinmind(cfg, id_token, session_id, clean_query, current_context, log_path)
            if status == 401:
                id_token = get_id_token(refresh_token, firebase_api_key)
                raw, events, status, err = call_twinmind(cfg, id_token, session_id, clean_query, current_context, log_path)

            if status != 200:
                write_log(log_path, {"event": "llm_error", "status": status, "error": err, "mode": "conversation"})
                emit_and_exit(f"TwinMind API error: {status} {err}", code=2, session_id=session_id, memory_route="twinmind_conversation")

            answer = (raw or "").strip()
            if not answer:
                # Some upstream runs complete without a final response text.
                # Do one fast second pass (no web-search) before returning a generic message.
                write_log(log_path, {"event": "empty_llm_response", "session_id": session_id, "mode": "conversation"})
                fb_provider = (getenv("TWINMIND_EMPTY_FALLBACK_PROVIDER", "") or "").strip()
                fb_model = (getenv("TWINMIND_EMPTY_FALLBACK_MODEL", "") or "").strip()
                fb_cfg = replace(
                    cfg,
                    provider=(fb_provider or cfg.provider),
                    model_name=(fb_model or cfg.model_name),
                    search_web=False,
                    llm_timeout_sec=int(getenv("TWINMIND_EMPTY_FALLBACK_TIMEOUT_SEC", str(min(cfg.llm_timeout_sec, 55))) or str(min(cfg.llm_timeout_sec, 55))),
                )
                raw2, _, status2, err2 = call_twinmind(fb_cfg, id_token, session_id, clean_query, current_context, log_path)
                if status2 == 200 and (raw2 or "").strip():
                    answer = (raw2 or "").strip()
                    write_log(
                        log_path,
                        {
                            "event": "empty_response_fallback_success",
                            "session_id": session_id,
                            "provider": fb_cfg.provider,
                            "model_name": fb_cfg.model_name,
                            "search_web": fb_cfg.search_web,
                        },
                    )
                else:
                    write_log(
                        log_path,
                        {
                            "event": "empty_response_fallback_failed",
                            "session_id": session_id,
                            "status": status2,
                            "error": safe_truncate(err2 or "", 500),
                        },
                    )
            if not answer:
                answer = "Ich konnte gerade keine Antwort generieren. Bitte versuche es erneut."

            if is_provider_refusal(answer):
                write_log(log_path, {"event": "provider_refusal", "session_id": session_id, "preview": answer[:500]})
                fallback = infer_sharezone_skill(sanitized_query)
                if fallback:
                    skill, sargs = fallback
                    write_log(log_path, {"event": "fallback_triggered", "fallback": "skill_run", "skill": skill})
                    result = tool_skill_run({"skill": skill, "args": sargs}, allow_writes=cfg.allow_writes, tool_timeout_sec=cfg.tool_timeout_sec)
                    answer = tool_result_message(result, default_ok="Keine Daten gefunden.")

            emit_and_exit(answer, code=0, session_id=session_id, memory_route="twinmind_conversation")
        finally:
            release_lock()

    if cfg.mode == "conversation" and explicit_tool_intent:
        write_log(log_path, {"event": "router_decision", "route": "tool_bridge_override", "reason": "explicit_tool_intent"})

    if not refresh_token:
        emit_and_exit("Error: Missing TWINMIND_REFRESH_TOKEN", code=2, memory_route="tool_bridge")

    write_log(
        log_path,
        {
            "event": "router_decision",
            "route": ("split_executor_bridge" if strict_split else "twinmind_tool_bridge"),
            "routing_mode": cfg.routing_mode,
        },
    )

    # If the request is explicitly about local systems/apps (e.g. Sharezone), require at least one tool call.
    # This avoids "I can't access" refusals that ignore wrapper tools.
    force_tool_for_request = should_force_tool_for_request(sanitized_query)

    try:
        acquire_lock()
    except Exception as e:
        emit_and_exit(f"Busy: {e}", code=4, memory_route="tool_bridge")

    session_id = run_session_id

    tool_catalog = build_tool_catalog(allow_shell=cfg.allow_shell)
    protocol = build_protocol_prompt(tool_catalog, allow_writes=cfg.allow_writes)

    # Rolling history; keep small to reduce prompt bloat.
    history: List[Dict[str, Any]] = []

    firebase_api_key = getenv("TWINMIND_FIREBASE_API_KEY", DEFAULT_FIREBASE_API_KEY) or DEFAULT_FIREBASE_API_KEY
    id_token = ""

    tool_calls = 0
    repairs_left = cfg.repair_attempts
    last_raw = ""

    try:
        id_token = get_id_token(refresh_token, firebase_api_key)
        write_log(
            log_path,
            {
                "event": "start",
                "session_id": session_id,
                "config": {
                    "mode": cfg.mode,
                    "model_name": cfg.model_name,
                    "provider": cfg.provider,
                    "max_steps": cfg.max_steps,
                    "allow_shell": cfg.allow_shell,
                    "allow_writes": cfg.allow_writes,
                    "routing_mode": cfg.routing_mode,
                    "executor_provider": cfg.executor_provider,
                    "executor_model": cfg.executor_model,
                },
            },
        )

        def twinmind_finalize_user_message(
            *,
            executor_answer: str,
            executor_error: str = "",
            fallback: str = "",
        ) -> str:
            nonlocal id_token
            compact_steps: List[Dict[str, Any]] = []
            for item in history[-8:]:
                t = str(item.get("type") or "")
                if t == "tool_call":
                    compact_steps.append(
                        {
                            "step": item.get("step"),
                            "type": "tool_call",
                            "tool": item.get("tool"),
                            "args_preview": safe_truncate(json.dumps(item.get("args") or {}, ensure_ascii=False), 240),
                        }
                    )
                elif t == "tool_result":
                    r = item.get("result") or {}
                    compact_steps.append(
                        {
                            "step": item.get("step"),
                            "type": "tool_result",
                            "tool": item.get("tool"),
                            "ok": r.get("ok"),
                            "exit_code": r.get("exit_code"),
                            "error": safe_truncate(str(r.get("error") or ""), 200),
                            "stdout_preview": safe_truncate(str(r.get("stdout") or ""), 240),
                        }
                    )
                elif t == "protocol_error":
                    compact_steps.append({"step": item.get("step"), "type": "protocol_error", "error": safe_truncate(str(item.get("error") or ""), 200)})
            transcript_excerpt, transcript_path = extract_transcript_excerpt_from_executor_answer(executor_answer or "")
            summary_payload = {
                "user_request": sanitized_query,
                "executor_answer": safe_truncate(executor_answer or "", 12000),
                "executor_error": safe_truncate(executor_error or "", 1200),
                "tool_calls": tool_calls,
                "recent_steps": compact_steps,
            }
            if transcript_excerpt:
                summary_payload["transcript_excerpt"] = transcript_excerpt
            if transcript_path:
                summary_payload["transcript_path"] = transcript_path
            final_prompt = (
                "Du bist die User-Kommunikationsschicht.\n"
                "Formuliere eine klare, kurze Antwort an den User basierend auf den Ausführungsergebnissen.\n"
                "Falls executor_error gesetzt ist: erkläre den Fehler präzise und nenne den nächsten sinnvollen Schritt.\n"
                "Antworte in der Sprache des Users.\n\n"
                + (f"PERSISTENT_USER_MEMORY:\n{dynamic_memory_context_text}\n\n" if dynamic_memory_context_text else "")
                + "EXECUTION_SUMMARY_JSON:\n"
                + json.dumps(summary_payload, ensure_ascii=False)
            )
            ctx = {
                "mode": "finalizer",
                "local_time": local_now_iso(),
                "wrapper_policy": {"allow_writes": cfg.allow_writes, "allow_shell": cfg.allow_shell},
                "dynamic_memory_context": dynamic_memory_context_text,
                "dynamic_memory_meta": dynamic_memory_meta,
            }
            rawf, _, statusf, errf, id_token = call_twinmind_with_refresh(
                cfg=cfg,
                id_token=id_token,
                refresh_token=refresh_token,
                firebase_api_key=firebase_api_key,
                session_id=session_id,
                query=final_prompt,
                current_context=ctx,
                log_path=log_path,
            )
            if statusf == 200 and (rawf or "").strip():
                write_log(log_path, {"event": "planner_finalized_response", "session_id": session_id, "status": 200})
                finalized = rawf.strip()
                if executor_error:
                    mentions_error = bool(
                        re.search(
                            r"\b(error|fehler|status|quota|token|auth|401|403|404|429|ausf|executor|tool)\b",
                            finalized,
                            re.I,
                        )
                    )
                    if not mentions_error and fallback:
                        return fallback
                return finalized
            write_log(
                log_path,
                {
                    "event": "planner_finalized_response_failed",
                    "session_id": session_id,
                    "status": statusf,
                    "error": safe_truncate(errf or "", 500),
                },
            )
            return fallback or executor_answer or "Die Tool-Ausführung ist fehlgeschlagen. Bitte versuche es erneut."

        planner_brief = ""
        if strict_split and cfg.executor_use_twinmind_planner:
            planner_prompt = (
                "Erstelle einen kurzen Ausführungsplan für einen Tool-Executor.\n"
                "Format: 3-6 knappe Bulletpoints, nur relevante Schritte.\n"
                "Fokus: welche Informationen müssen geholt/geschrieben werden und wann Antwort fertig ist.\n\n"
                + (f"PERSISTENT_USER_MEMORY:\n{dynamic_memory_context_text}\n\n" if dynamic_memory_context_text else "")
                + f"USER_REQUEST:\n{sanitized_query}"
            )
            planner_ctx = {
                "mode": "planner",
                "local_time": local_now_iso(),
                "wrapper_policy": {"allow_writes": cfg.allow_writes, "allow_shell": cfg.allow_shell},
                "dynamic_memory_context": dynamic_memory_context_text,
                "dynamic_memory_meta": dynamic_memory_meta,
            }
            rawp, _, statusp, errp, id_token = call_twinmind_with_refresh(
                cfg=cfg,
                id_token=id_token,
                refresh_token=refresh_token,
                firebase_api_key=firebase_api_key,
                session_id=session_id,
                query=planner_prompt,
                current_context=planner_ctx,
                log_path=log_path,
            )
            if statusp == 200 and (rawp or "").strip():
                planner_brief = safe_truncate("\n".join((rawp or "").strip().splitlines()[:8]), 800)
                write_log(log_path, {"event": "planner_brief_ready", "session_id": session_id, "preview": planner_brief[:600]})
            else:
                write_log(
                    log_path,
                    {
                        "event": "planner_brief_failed",
                        "session_id": session_id,
                        "status": statusp,
                        "error": safe_truncate(errp or "", 500),
                    },
                )
                planner_brief = ""

        max_steps = cfg.executor_max_steps if strict_split else cfg.max_steps
        max_tool_calls = cfg.executor_max_tool_calls if strict_split else cfg.max_tool_calls

        # Initial request: embed protocol in query for compliance.
        query = (
            protocol
            + "\n\n"
            + f"Current time: {local_now_iso()} (local)\n"
            + "TM_TOOL_MODE=1\n"
            + (f"PERSISTENT_USER_MEMORY:\n{dynamic_memory_context_text}\n\n" if dynamic_memory_context_text else "")
            + (f"PLANNER_BRIEF:\n{planner_brief}\n\n" if planner_brief else "")
            + "USER_REQUEST: "
            + sanitized_query
        )

        for step in range(1, max_steps + 1):
            current_context = {
                "wrapper_protocol": protocol,
                "wrapper_policy": {"allow_writes": cfg.allow_writes, "allow_shell": cfg.allow_shell},
                "wrapper_history": history[-10:],
                "dynamic_memory_context": dynamic_memory_context_text,
                "dynamic_memory_meta": dynamic_memory_meta,
            }

            if strict_split:
                raw, events, status, err = call_executor(cfg, session_id, query, current_context, log_path)
                last_raw = raw or err or ""
            else:
                raw, events, status, err, id_token = call_twinmind_with_refresh(
                    cfg=cfg,
                    id_token=id_token,
                    refresh_token=refresh_token,
                    firebase_api_key=firebase_api_key,
                    session_id=session_id,
                    query=query,
                    current_context=current_context,
                    log_path=log_path,
                )
                last_raw = raw or err or ""

            if status != 200:
                if strict_split:
                    write_log(log_path, {"event": "executor_failed", "status": status, "error": safe_truncate(err, 1000), "step": step})
                    answer = twinmind_finalize_user_message(
                        executor_answer="",
                        executor_error=f"{cfg.executor_provider} executor failed with status {status}: {err}",
                        fallback=f"Tool-Ausführung fehlgeschlagen ({status}). {safe_truncate(err, 300)}",
                    )
                    emit_and_exit(answer, code=0, session_id=session_id, memory_route="split_executor_bridge")
                write_log(log_path, {"event": "llm_error", "status": status, "error": err})
                emit_and_exit(f"TwinMind API error: {status} {err}", code=2, session_id=session_id, memory_route="twinmind_tool_bridge")

            obj, perr = parse_protocol_output(raw)
            if perr:
                write_log(log_path, {"event": "protocol_error", "step": step, "error": perr, "raw_preview": raw[:1000]})
                if repairs_left > 0:
                    repairs_left -= 1
                    query = protocol + "\n\n" + build_repair_prompt(perr, raw)
                    history.append({"step": step, "type": "protocol_error", "error": perr})
                    continue
                # Never hard-fail: a non-zero exit can crash the gateway process
                # (unhandled failover error). Degrade to a plain answer instead.
                if strict_split:
                    answer = twinmind_finalize_user_message(
                        executor_answer="",
                        executor_error=f"Executor returned invalid protocol output: {perr}",
                        fallback="Die Tool-Ausführung lieferte ein ungültiges Ergebnisformat.",
                    )
                    emit_and_exit(answer, code=0, session_id=session_id, memory_route="split_executor_bridge")
                answer = (raw or "").strip() or "Sorry — the AI returned an invalid response format. Please try again."
                write_log(log_path, {"event": "final_lenient", "step": step, "answer_preview": answer[:1000]})
                emit_and_exit(answer, code=0, session_id=session_id, memory_route="twinmind_tool_bridge")

            assert obj is not None
            if obj["action"] == "final":
                answer = obj["answer"].strip()
                if force_tool_for_request and tool_calls == 0:
                    # Treat as protocol violation: for these requests we need to actually call tools at least once.
                    perr2 = "Final answer provided without using required tools for this request. Call an appropriate tool first."
                    write_log(log_path, {"event": "protocol_error", "step": step, "error": perr2, "raw_preview": raw[:1000]})
                    if repairs_left > 0:
                        repairs_left -= 1
                        query = protocol + "\n\n" + build_repair_prompt(perr2, raw)
                        history.append({"step": step, "type": "protocol_error", "error": perr2})
                        continue
                    # Degrade to the model-provided final answer to keep the gateway alive.
                    force_tool_for_request = False
                write_log(log_path, {"event": "final", "step": step, "answer_preview": answer[:1000]})
                if strict_split:
                    answer = twinmind_finalize_user_message(executor_answer=answer)
                emit_and_exit(
                    answer,
                    code=0,
                    session_id=session_id,
                    memory_route=("split_executor_bridge" if strict_split else "twinmind_tool_bridge"),
                )

            if obj["action"] == "tool_call":
                tool_calls += 1
                if tool_calls > max_tool_calls:
                    write_log(log_path, {"event": "limit", "reason": "max_tool_calls", "max": max_tool_calls})
                    if strict_split:
                        answer = twinmind_finalize_user_message(
                            executor_answer="",
                            executor_error=f"Tool-call limit reached ({max_tool_calls})",
                            fallback="Tool-Limit erreicht. Bitte Anfrage eingrenzen oder in kleinere Schritte aufteilen.",
                        )
                        emit_and_exit(answer, code=0, session_id=session_id, memory_route="split_executor_bridge")
                    emit_and_exit("Tool-call limit reached; aborting.", code=3, session_id=session_id, memory_route="twinmind_tool_bridge")

                tool = obj["tool"]
                targs = obj.get("args") or {}
                call_id = obj.get("id") or str(uuid.uuid4())

                write_log(log_path, {"event": "tool_call", "step": step, "tool": tool, "id": call_id, "args_preview": safe_truncate(json.dumps(targs, ensure_ascii=False), 1500)})
                if tool == "skill_run":
                    req_skill = str((targs or {}).get("skill") or "").strip()
                    if req_skill.startswith("youtube."):
                        write_log(
                            log_path,
                            {
                                "event": "youtube_ingest_start",
                                "step": step,
                                "id": call_id,
                                "skill": req_skill,
                                "url": safe_truncate(str(((targs or {}).get("args") or {}).get("url") or ""), 300),
                            },
                        )

                result = execute_tool(tool, targs, allow_writes=cfg.allow_writes, tool_timeout_sec=cfg.tool_timeout_sec)
                write_log(log_path, {"event": "tool_result", "step": step, "tool": tool, "id": call_id, "ok": bool(result.get("ok")), "result_preview": safe_truncate(json.dumps(result, ensure_ascii=False), 1500)})
                if tool == "skill_run":
                    req_skill_done = str((targs or {}).get("skill") or "").strip()
                    if req_skill_done.startswith("youtube."):
                        yt_obj = safe_json_loads(str(result.get("stdout") or "").strip() or "")
                        yt_status = str((yt_obj or {}).get("status") or "")
                        yt_job = str((yt_obj or {}).get("job_id") or "")
                        write_log(
                            log_path,
                            {
                                "event": "youtube_ingest_done",
                                "step": step,
                                "id": call_id,
                                "skill": req_skill_done,
                                "ok": bool(result.get("ok")),
                                "status": yt_status,
                                "job_id": yt_job,
                            },
                        )

                history.append({"step": step, "type": "tool_call", "tool": tool, "id": call_id, "args": targs})
                history.append({"step": step, "type": "tool_result", "tool": tool, "id": call_id, "result": {"ok": result.get("ok"), "exit_code": result.get("exit_code"), "stdout": safe_truncate(result.get("stdout") or "", 4000), "stderr": safe_truncate(result.get("stderr") or "", 2000), "error": result.get("error")}})

                # In strict split, for YouTube skill outputs we finalize immediately
                # through TwinMind so the "brain" writes the user-facing answer.
                if strict_split and tool == "skill_run":
                    req_skill_strict = str((targs or {}).get("skill") or "").strip()
                    if req_skill_strict.startswith("youtube."):
                        out = tool_result_message(result, default_ok="OK")
                        yt_obj = safe_json_loads(str(result.get("stdout") or "").strip() or "")
                        yt_status = str((yt_obj or {}).get("status") or "")
                        yt_warning = str((yt_obj or {}).get("warning") or "").strip()
                        yt_diag = (yt_obj or {}).get("diagnostics") if isinstance((yt_obj or {}).get("diagnostics"), dict) else {}
                        yt_diag_msg = str((yt_diag or {}).get("message") or "").strip()
                        err_msg = ""
                        fallback_msg = out or "YouTube-Verarbeitung fehlgeschlagen."
                        if (not bool(result.get("ok"))) or int(result.get("exit_code") or 0) != 0:
                            err_msg = (
                                str(result.get("error") or "").strip()
                                or str(result.get("stderr") or "").strip()
                                or "youtube skill failed"
                            )
                        elif yt_status == "partial":
                            err_msg = yt_warning or yt_diag_msg or "youtube ingest partial"
                            if isinstance(yt_obj, dict):
                                fallback_msg = youtube_partial_fallback_message(yt_obj)
                        write_log(log_path, {"event": "youtube_short_circuit_finalizer", "step": step, "skill": req_skill_strict})
                        answer = twinmind_finalize_user_message(
                            executor_answer=out,
                            executor_error=err_msg,
                            fallback=fallback_msg,
                        )
                        emit_and_exit(answer, code=0, session_id=session_id, memory_route="split_executor_bridge")

                # Short-circuit for "skill_run": the skill scripts already produce a
                # user-facing result, and some TwinMind runs occasionally fail to
                # provide a follow-up "final" after the tool result. Returning
                # immediately avoids hanging the gateway / CLI backend.
                if (not strict_split) and tool == "skill_run":
                    out = (result.get("stdout") or "").strip()
                    err_out = (result.get("stderr") or "").strip()
                    if not out and result.get("error"):
                        out = f"Error: {result.get('error')}".strip()
                    if not out and err_out:
                        out = err_out
                    if not out:
                        out = "OK"
                    write_log(log_path, {"event": "final_after_skill_run", "step": step, "answer_preview": out[:1000]})
                    emit_and_exit(out, code=0, session_id=session_id, memory_route="twinmind_tool_bridge")

                query = protocol + "\n\n" + "TOOL_RESULT " + json.dumps({"id": call_id, "tool": tool, **result}, ensure_ascii=False)
                continue

        write_log(log_path, {"event": "limit", "reason": "max_steps", "max": max_steps, "last_raw_preview": safe_truncate(last_raw, 1500)})
        if strict_split:
            answer = twinmind_finalize_user_message(
                executor_answer="",
                executor_error=f"Step limit reached ({max_steps})",
                fallback="Schrittlimit erreicht. Bitte Anfrage präziser formulieren.",
            )
            emit_and_exit(answer, code=0, session_id=session_id, memory_route="split_executor_bridge")
        emit_and_exit("Step limit reached; aborting.", code=3, session_id=session_id, memory_route="twinmind_tool_bridge")
    finally:
        release_lock()


if __name__ == "__main__":
    main()
