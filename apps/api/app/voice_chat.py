"""Voice-chat helpers for the ESP32 terminal flow.

The first production target is a PC-assisted loop:

ESP32 wake/record -> POST audio to the API -> ASR -> OpenAI-compatible chat
model -> optional PC-side TTS playback. ESP32 speaker playback can then consume
the returned text or future audio bytes once the ES8311 output path is wired.
"""

import base64
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
import wave
from dataclasses import dataclass
from datetime import datetime, timedelta
from io import BytesIO
from pathlib import Path
from typing import Iterator, Literal

import httpx
from fastapi import HTTPException

from app.config import Settings
from app.planner.qwen import _chat_completion


VOICE_CHAT_AUDIO_DIR = Path(os.getenv("HOMECUE_VOICE_CHAT_AUDIO_DIR", tempfile.gettempdir())) / "homecue-voice-chat-audio"
VOICE_CHAT_AUDIO_TTL_SECONDS = 15 * 60
VOICE_CHAT_SESSION_TTL_SECONDS = 30 * 60
VOICE_CHAT_MAX_CONTEXT_TURNS = 6
VOICE_CHAT_MEMORY_CONTEXT_LIMIT = 4
VOICE_CHAT_TASK_CONTEXT_LIMIT = 4
VOICE_CHAT_MOOD_CONTEXT_LIMIT = 3
VOICE_CHAT_CONTEXT_VALUE_CHARS = 160
VOICE_CHAT_DEFAULT_USER_ID = "default"
VOICE_CHAT_SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
VOICE_CHAT_SESSIONS: dict[str, "VoiceChatSession"] = {}
VOICE_CHAT_TASK_STATUSES = {"open", "done", "cancelled"}
VOICE_CHAT_TASK_RECURRENCES = {"", "daily", "weekly"}
VOICE_CHAT_MEMORY_KEYWORDS = ("记住", "记一下", "提醒我记得", "我喜欢", "我不喜欢", "我的")
VOICE_CHAT_TASK_KEYWORDS = ("提醒我", "记得", "待办", "帮我", "定时", "闹钟")
VOICE_CHAT_NEGATIVE_MOOD_KEYWORDS = ("难过", "焦虑", "生气", "烦", "累", "压力", "担心", "害怕")
VOICE_CHAT_POSITIVE_MOOD_KEYWORDS = ("开心", "高兴", "舒服", "轻松", "满意", "喜欢", "期待")
VOICE_CHAT_RELATIVE_TIME_RE = re.compile(r"(\d+)\s*(分钟|小时|天)(后|以后)")
VOICE_CHAT_TIME_OF_DAY = (
    ("早上", 8),
    ("上午", 9),
    ("中午", 12),
    ("下午", 15),
    ("今晚", 20),
    ("晚上", 20),
)

VOICE_CHAT_SYSTEM_PROMPT = """
You are XiaoQian, the friendly Chinese voice assistant running on a HomeCue Edge
ESP32 terminal. Keep replies concise, natural, and suitable to speak aloud.
Prefer Simplified Chinese. If the user asks for smart-home control, explain what
you can do and keep safety/human confirmation boundaries clear.
Reply with exactly one short spoken sentence. Do not use markdown, numbered
lists, or emoji.
For voice-chat replies that will be played on an embedded speaker, stay under
20 Chinese characters.
"""


@dataclass
class SpeechResult:
    text: str
    language: str = "unknown"


@dataclass
class ReplyAudioResult:
    path: Path
    provider: str
    model: str
    voice: str


@dataclass
class ReplyAudioStreamResult:
    chunks: Iterator[bytes]
    provider: str
    model: str
    voice: str


@dataclass
class VoiceChatTurn:
    user: str
    assistant: str
    user_id: str = VOICE_CHAT_DEFAULT_USER_ID
    device_id: str = ""
    created_at: float = 0.0
    turn_index: int = 0


@dataclass
class VoiceChatSession:
    session_id: str
    turns: list[VoiceChatTurn]
    updated_at: float
    turn_index: int = 0


def cleanup_voice_chat_sessions(now: float | None = None) -> None:
    """Drop stale in-memory voice sessions."""
    cutoff = (now or time.time()) - VOICE_CHAT_SESSION_TTL_SECONDS
    stale = [session_id for session_id, session in VOICE_CHAT_SESSIONS.items() if session.updated_at < cutoff]
    for session_id in stale:
        VOICE_CHAT_SESSIONS.pop(session_id, None)


def clear_voice_chat_sessions() -> None:
    """Test/dev helper for resetting in-memory voice session state."""
    VOICE_CHAT_SESSIONS.clear()


def _normalize_voice_chat_session_id(session_id: str | None) -> str | None:
    candidate = (session_id or "").strip()
    if not candidate:
        return None
    return candidate if VOICE_CHAT_SESSION_ID_RE.fullmatch(candidate) else None


def _normalize_voice_chat_label(value: str | None, fallback: str, max_length: int = 96) -> str:
    candidate = str(value or "").strip()
    if not candidate:
        return fallback
    return candidate[:max_length]


def _memory_db_path(settings: Settings) -> Path | None:
    raw_path = settings.voice_chat_memory_db.strip()
    if not raw_path:
        return None
    return Path(raw_path).expanduser()


def _open_memory_db(settings: Settings) -> sqlite3.Connection | None:
    db_path = _memory_db_path(settings)
    if db_path is None:
        return None

    conn: sqlite3.Connection | None = None
    try:
        db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute("PRAGMA journal_mode=WAL")
        _ensure_memory_schema(conn)
        return conn
    except (OSError, sqlite3.Error):
        if conn is not None:
            conn.close()
        return None


def _ensure_memory_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS voice_chat_turns (
            session_id TEXT NOT NULL,
            turn_index INTEGER NOT NULL,
            user_text TEXT NOT NULL,
            assistant_text TEXT NOT NULL,
            user_id TEXT NOT NULL DEFAULT 'default',
            device_id TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            PRIMARY KEY (session_id, turn_index)
        )
        """
    )
    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_voice_chat_turns_user_time
        ON voice_chat_turns (user_id, created_at DESC)
        """
    )
    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_voice_chat_turns_session_time
        ON voice_chat_turns (session_id, created_at DESC)
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS voice_chat_memories (
            memory_id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL DEFAULT '',
            session_id TEXT NOT NULL,
            turn_index INTEGER NOT NULL,
            memory_type TEXT NOT NULL,
            content TEXT NOT NULL,
            source_text TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_voice_chat_memories_user_time
        ON voice_chat_memories (user_id, updated_at DESC)
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS voice_chat_tasks (
            task_id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL DEFAULT '',
            session_id TEXT NOT NULL,
            turn_index INTEGER NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL DEFAULT '',
            due_text TEXT NOT NULL DEFAULT '',
            recurrence TEXT NOT NULL DEFAULT '',
            due_at REAL,
            reminded_at REAL,
            status TEXT NOT NULL DEFAULT 'open',
            source_text TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """
    )
    _ensure_column(conn, "voice_chat_tasks", "recurrence", "TEXT NOT NULL DEFAULT ''")
    _ensure_column(conn, "voice_chat_tasks", "due_at", "REAL")
    _ensure_column(conn, "voice_chat_tasks", "reminded_at", "REAL")
    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_voice_chat_tasks_user_status
        ON voice_chat_tasks (user_id, status, updated_at DESC)
        """
    )
    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_voice_chat_tasks_due
        ON voice_chat_tasks (user_id, status, due_at ASC)
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS voice_chat_moods (
            mood_id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL DEFAULT '',
            session_id TEXT NOT NULL,
            turn_index INTEGER NOT NULL,
            mood TEXT NOT NULL,
            valence INTEGER NOT NULL,
            confidence REAL NOT NULL,
            source_text TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_voice_chat_moods_user_time
        ON voice_chat_moods (user_id, created_at DESC)
        """
    )
    conn.commit()


def _ensure_column(conn: sqlite3.Connection, table: str, column: str, definition: str) -> None:
    columns = {str(row["name"]) for row in conn.execute(f"PRAGMA table_info({table})")}
    if column not in columns:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")


def _load_persisted_session(settings: Settings | None, session_id: str) -> tuple[list[VoiceChatTurn], int]:
    if settings is None:
        return [], 0

    conn = _open_memory_db(settings)
    if conn is None:
        return [], 0

    try:
        max_row = conn.execute(
            "SELECT COALESCE(MAX(turn_index), 0) AS max_turn FROM voice_chat_turns WHERE session_id = ?",
            (session_id,),
        ).fetchone()
        rows = conn.execute(
            """
            SELECT turn_index, user_text, assistant_text, user_id, device_id, created_at
            FROM (
                SELECT turn_index, user_text, assistant_text, user_id, device_id, created_at
                FROM voice_chat_turns
                WHERE session_id = ?
                ORDER BY turn_index DESC
                LIMIT ?
            )
            ORDER BY turn_index ASC
            """,
            (session_id, VOICE_CHAT_MAX_CONTEXT_TURNS),
        ).fetchall()
    except sqlite3.Error:
        return [], 0
    finally:
        conn.close()

    turns = [
        VoiceChatTurn(
            user=str(row["user_text"]),
            assistant=str(row["assistant_text"]),
            user_id=str(row["user_id"]),
            device_id=str(row["device_id"]),
            created_at=float(row["created_at"]),
            turn_index=int(row["turn_index"]),
        )
        for row in rows
    ]
    return turns, int(max_row["max_turn"] if max_row is not None else 0)


def _persist_voice_chat_turn(
    settings: Settings,
    session_id: str,
    turn: VoiceChatTurn,
) -> None:
    conn = _open_memory_db(settings)
    if conn is None:
        return

    try:
        conn.execute(
            """
            INSERT OR REPLACE INTO voice_chat_turns (
                session_id, turn_index, user_text, assistant_text, user_id, device_id, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                session_id,
                turn.turn_index,
                turn.user,
                turn.assistant,
                turn.user_id,
                turn.device_id,
                turn.created_at,
            ),
        )
        conn.commit()
    except sqlite3.Error:
        pass
    finally:
        conn.close()


def _strip_leading_marker(text: str, markers: tuple[str, ...]) -> str:
    cleaned = text.strip(" ，。,.!！？?：:")
    for marker in markers:
        index = cleaned.find(marker)
        if index >= 0:
            cleaned = cleaned[index + len(marker) :]
            break
    return cleaned.strip(" ，。,.!！？?：:")


def _classify_memory_type(text: str) -> str:
    if "喜欢" in text:
        return "preference"
    if "不喜欢" in text:
        return "preference"
    if "我的" in text:
        return "profile"
    return "note"


def _extract_memory_candidate(text: str) -> tuple[str, str] | None:
    if not any(keyword in text for keyword in VOICE_CHAT_MEMORY_KEYWORDS):
        return None
    content = _strip_leading_marker(text, VOICE_CHAT_MEMORY_KEYWORDS)
    if len(content) < 2:
        return None
    return _classify_memory_type(text), content[:280]


def parse_voice_task_recurrence(text: str) -> str:
    cleaned = text.strip().lower()
    if not cleaned:
        return ""
    if cleaned in {"daily", "每天", "每日", "天天"}:
        return "daily"
    if cleaned in {"weekly", "每周", "每星期", "每个星期", "每礼拜"}:
        return "weekly"
    if any(marker in text for marker in ("每天", "每日", "天天")):
        return "daily"
    if any(marker in text for marker in ("每周", "每星期", "每个星期", "每礼拜")):
        return "weekly"
    return ""


def _normalize_voice_task_recurrence(value: str | None) -> str:
    recurrence = parse_voice_task_recurrence(value or "")
    if recurrence:
        return recurrence
    candidate = str(value or "").strip().lower()
    if candidate in {"", "none", "once", "one-shot", "single"}:
        return ""
    if candidate not in VOICE_CHAT_TASK_RECURRENCES:
        raise HTTPException(status_code=400, detail="Unsupported task recurrence.")
    return candidate


def _time_of_day_from_text(text: str, default_hour: int) -> tuple[int, int]:
    for marker, hour in VOICE_CHAT_TIME_OF_DAY:
        if marker in text:
            return hour, 0
    return default_hour, 0


def _combine_due_markers(text: str) -> str:
    relative = VOICE_CHAT_RELATIVE_TIME_RE.search(text)
    if relative:
        return relative.group(0)

    recurrence = parse_voice_task_recurrence(text)
    time_marker = next((marker for marker, _ in VOICE_CHAT_TIME_OF_DAY if marker in text), "")
    if recurrence:
        recurrence_marker = "每周" if recurrence == "weekly" else "每天"
        return f"{recurrence_marker}{time_marker}"

    day_marker = next((marker for marker in ("明天", "今天", "下周") if marker in text), "")
    if day_marker and time_marker and time_marker not in day_marker:
        return f"{day_marker}{time_marker}"
    return day_marker or time_marker


def _extract_task_candidate(text: str) -> tuple[str, str, str] | None:
    if not any(keyword in text for keyword in VOICE_CHAT_TASK_KEYWORDS):
        return None
    content = _strip_leading_marker(text, VOICE_CHAT_TASK_KEYWORDS)
    if len(content) < 2:
        return None
    due_text = _combine_due_markers(text)
    recurrence = parse_voice_task_recurrence(text)
    return content[:120], due_text, recurrence


def parse_voice_task_due_at(due_text: str, now: float | None = None) -> float | None:
    text = due_text.strip()
    if not text:
        return None

    base = datetime.fromtimestamp(now or time.time())
    relative = VOICE_CHAT_RELATIVE_TIME_RE.search(text)
    if relative:
        amount = int(relative.group(1))
        unit = relative.group(2)
        if unit == "分钟":
            return (base + timedelta(minutes=amount)).timestamp()
        if unit == "小时":
            return (base + timedelta(hours=amount)).timestamp()
        if unit == "天":
            return (base + timedelta(days=amount)).timestamp()

    hour, minute = _time_of_day_from_text(text, 9)
    if "今天" in text:
        return base.replace(hour=hour, minute=minute, second=0, microsecond=0).timestamp()
    if "今晚" in text or "晚上" in text:
        return base.replace(hour=20, minute=0, second=0, microsecond=0).timestamp()
    if "明天" in text:
        return (base + timedelta(days=1)).replace(hour=hour, minute=minute, second=0, microsecond=0).timestamp()
    if "下周" in text or parse_voice_task_recurrence(text) == "weekly":
        return (base + timedelta(days=7)).replace(hour=hour, minute=minute, second=0, microsecond=0).timestamp()
    if "每天" in text:
        return (base + timedelta(days=1)).replace(hour=hour, minute=minute, second=0, microsecond=0).timestamp()
    return None


def next_recurring_voice_task_due_at(due_at: float | None, recurrence: str, now: float | None = None) -> float | None:
    normalized = _normalize_voice_task_recurrence(recurrence)
    if not normalized or due_at is None:
        return None

    step_seconds = 7 * 24 * 60 * 60 if normalized == "weekly" else 24 * 60 * 60
    now_value = now or time.time()
    if due_at > now_value:
        return due_at
    missed = int((now_value - due_at) // step_seconds) + 1
    return due_at + missed * step_seconds


def _extract_mood_candidate(text: str) -> tuple[str, int, float] | None:
    for keyword in VOICE_CHAT_NEGATIVE_MOOD_KEYWORDS:
        if keyword in text:
            return keyword, -1, 0.7
    for keyword in VOICE_CHAT_POSITIVE_MOOD_KEYWORDS:
        if keyword in text:
            return keyword, 1, 0.65
    return None


def _capture_voice_chat_insights(
    settings: Settings,
    session_id: str,
    turn: VoiceChatTurn,
) -> None:
    conn = _open_memory_db(settings)
    if conn is None:
        return

    try:
        memory = _extract_memory_candidate(turn.user)
        if memory is not None:
            memory_type, content = memory
            now = time.time()
            existing = conn.execute(
                """
                SELECT memory_id
                FROM voice_chat_memories
                WHERE user_id = ? AND memory_type = ? AND content = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
                (turn.user_id, memory_type, content),
            ).fetchone()
            if existing is not None:
                conn.execute(
                    """
                    UPDATE voice_chat_memories
                    SET device_id = ?, session_id = ?, turn_index = ?,
                        source_text = ?, updated_at = ?
                    WHERE memory_id = ?
                    """,
                    (
                        turn.device_id,
                        session_id,
                        turn.turn_index,
                        turn.user,
                        now,
                        str(existing["memory_id"]),
                    ),
                )
            else:
                conn.execute(
                    """
                    INSERT INTO voice_chat_memories (
                        memory_id, user_id, device_id, session_id, turn_index,
                        memory_type, content, source_text, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        uuid.uuid4().hex,
                        turn.user_id,
                        turn.device_id,
                        session_id,
                        turn.turn_index,
                        memory_type,
                        content,
                        turn.user,
                        now,
                        now,
                    ),
                )

        task = _extract_task_candidate(turn.user)
        if task is not None:
            title, due_text, recurrence = task
            now = time.time()
            due_at = parse_voice_task_due_at(due_text or turn.user, now)
            existing = conn.execute(
                """
                SELECT task_id
                FROM voice_chat_tasks
                WHERE user_id = ?
                  AND status = 'open'
                  AND title = ?
                  AND due_text = ?
                  AND COALESCE(recurrence, '') = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
                (turn.user_id, title, due_text, recurrence),
            ).fetchone()
            if existing is not None:
                conn.execute(
                    """
                    UPDATE voice_chat_tasks
                    SET device_id = ?, session_id = ?, turn_index = ?,
                        due_at = COALESCE(?, due_at), source_text = ?, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (
                        turn.device_id,
                        session_id,
                        turn.turn_index,
                        due_at,
                        turn.user,
                        now,
                        str(existing["task_id"]),
                    ),
                )
            else:
                conn.execute(
                    """
                    INSERT INTO voice_chat_tasks (
                        task_id, user_id, device_id, session_id, turn_index,
                        title, detail, due_text, recurrence, due_at, reminded_at, status,
                        source_text, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 'open', ?, ?, ?)
                    """,
                    (
                        uuid.uuid4().hex,
                        turn.user_id,
                        turn.device_id,
                        session_id,
                        turn.turn_index,
                        title,
                        "",
                        due_text,
                        recurrence,
                        due_at,
                        turn.user,
                        now,
                        now,
                    ),
                )

        mood = _extract_mood_candidate(turn.user)
        if mood is not None:
            mood_label, valence, confidence = mood
            conn.execute(
                """
                INSERT INTO voice_chat_moods (
                    mood_id, user_id, device_id, session_id, turn_index,
                    mood, valence, confidence, source_text, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    uuid.uuid4().hex,
                    turn.user_id,
                    turn.device_id,
                    session_id,
                    turn.turn_index,
                    mood_label,
                    valence,
                    confidence,
                    turn.user,
                    time.time(),
                ),
            )
        conn.commit()
    except sqlite3.Error:
        pass
    finally:
        conn.close()


def _limit_query_count(limit: int, default: int, maximum: int) -> int:
    try:
        parsed = int(limit)
    except (TypeError, ValueError):
        return default
    return max(1, min(parsed, maximum))


def _dedupe_key(value: object) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip()).casefold()


def _trim_unique_items(items: list[dict], key_names: tuple[str, ...], limit: int) -> list[dict]:
    seen = set()
    unique = []
    for item in items:
        key = tuple(_dedupe_key(item.get(name)) for name in key_names)
        if key in seen:
            continue
        seen.add(key)
        unique.append(item)
        if len(unique) >= limit:
            break
    return unique


def _task_from_row(row: sqlite3.Row) -> dict:
    due_at = row["due_at"]
    reminded_at = row["reminded_at"]
    recurrence = row["recurrence"] if "recurrence" in row.keys() else ""
    return {
        "task_id": str(row["task_id"]),
        "user_id": str(row["user_id"]),
        "device_id": str(row["device_id"]),
        "session_id": str(row["session_id"]),
        "turn_index": int(row["turn_index"]),
        "title": str(row["title"]),
        "detail": str(row["detail"]),
        "due_text": str(row["due_text"]),
        "recurrence": str(recurrence or ""),
        "due_at": float(due_at) if due_at is not None else None,
        "reminded_at": float(reminded_at) if reminded_at is not None else None,
        "status": str(row["status"]),
        "source_text": str(row["source_text"]),
        "created_at": float(row["created_at"]),
        "updated_at": float(row["updated_at"]),
    }


def list_voice_chat_memories(settings: Settings, user_id: str | None = None, limit: int = 20) -> list[dict]:
    limit = _limit_query_count(limit, 20, 100)
    normalized_user_id = _normalize_voice_chat_label(user_id, VOICE_CHAT_DEFAULT_USER_ID)
    conn = _open_memory_db(settings)
    if conn is None:
        return []

    try:
        row_limit = min(limit * 5, 500)
        rows = conn.execute(
            """
            SELECT memory_id, user_id, device_id, session_id, turn_index,
                   memory_type, content, source_text, created_at, updated_at
            FROM voice_chat_memories
            WHERE user_id = ?
            ORDER BY updated_at DESC
            LIMIT ?
            """,
            (normalized_user_id, row_limit),
        ).fetchall()
    except sqlite3.Error:
        return []
    finally:
        conn.close()

    memories = [
        {
            "memory_id": str(row["memory_id"]),
            "user_id": str(row["user_id"]),
            "device_id": str(row["device_id"]),
            "session_id": str(row["session_id"]),
            "turn_index": int(row["turn_index"]),
            "memory_type": str(row["memory_type"]),
            "content": str(row["content"]),
            "source_text": str(row["source_text"]),
            "created_at": float(row["created_at"]),
            "updated_at": float(row["updated_at"]),
        }
        for row in rows
    ]
    return _trim_unique_items(memories, ("memory_type", "content"), limit)


def list_voice_chat_tasks(
    settings: Settings,
    user_id: str | None = None,
    status: str | None = "open",
    limit: int = 20,
) -> list[dict]:
    limit = _limit_query_count(limit, 20, 100)
    normalized_user_id = _normalize_voice_chat_label(user_id, VOICE_CHAT_DEFAULT_USER_ID)
    normalized_status = str(status or "").strip().lower()
    conn = _open_memory_db(settings)
    if conn is None:
        return []

    try:
        row_limit = min(limit * 5, 500)
        if normalized_status in VOICE_CHAT_TASK_STATUSES:
            rows = conn.execute(
                """
                SELECT task_id, user_id, device_id, session_id, turn_index,
                       title, detail, due_text, recurrence, due_at, reminded_at,
                       status, source_text, created_at, updated_at
                FROM voice_chat_tasks
                WHERE user_id = ? AND status = ?
                ORDER BY updated_at DESC
                LIMIT ?
                """,
                (normalized_user_id, normalized_status, row_limit),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT task_id, user_id, device_id, session_id, turn_index,
                       title, detail, due_text, recurrence, due_at, reminded_at,
                       status, source_text, created_at, updated_at
                FROM voice_chat_tasks
                WHERE user_id = ?
                ORDER BY updated_at DESC
                LIMIT ?
                """,
                (normalized_user_id, row_limit),
            ).fetchall()
    except sqlite3.Error:
        return []
    finally:
        conn.close()

    tasks = [_task_from_row(row) for row in rows]
    return _trim_unique_items(tasks, ("title", "due_text", "recurrence", "status"), limit)


def list_due_voice_chat_tasks(
    settings: Settings,
    user_id: str | None = None,
    now: float | None = None,
    limit: int = 20,
    mark_reminded: bool = False,
) -> list[dict]:
    limit = _limit_query_count(limit, 20, 100)
    normalized_user_id = _normalize_voice_chat_label(user_id, VOICE_CHAT_DEFAULT_USER_ID)
    cutoff = now or time.time()
    conn = _open_memory_db(settings)
    if conn is None:
        return []

    try:
        rows = conn.execute(
            """
            SELECT task_id, user_id, device_id, session_id, turn_index,
                   title, detail, due_text, recurrence, due_at, reminded_at,
                   status, source_text, created_at, updated_at
            FROM voice_chat_tasks
            WHERE user_id = ?
              AND status = 'open'
              AND due_at IS NOT NULL
              AND due_at <= ?
              AND (reminded_at IS NULL OR COALESCE(recurrence, '') != '')
            ORDER BY due_at ASC
            LIMIT ?
            """,
            (normalized_user_id, cutoff, limit),
        ).fetchall()
        tasks = [_task_from_row(row) for row in rows]
        if mark_reminded and tasks:
            now_value = cutoff
            one_shot_updates = []
            recurring_updates = []
            for task in tasks:
                next_due_at = next_recurring_voice_task_due_at(task["due_at"], task["recurrence"], now_value)
                if next_due_at is None:
                    one_shot_updates.append((now_value, now_value, task["task_id"]))
                else:
                    recurring_updates.append((next_due_at, now_value, now_value, task["task_id"]))
                    task["due_at"] = next_due_at
                task["reminded_at"] = now_value
                task["updated_at"] = now_value
            if one_shot_updates:
                conn.executemany(
                    "UPDATE voice_chat_tasks SET reminded_at = ?, updated_at = ? WHERE task_id = ?",
                    one_shot_updates,
                )
            if recurring_updates:
                conn.executemany(
                    "UPDATE voice_chat_tasks SET due_at = ?, reminded_at = ?, updated_at = ? WHERE task_id = ?",
                    recurring_updates,
                )
            conn.commit()
        return tasks
    except sqlite3.Error:
        return []
    finally:
        conn.close()


def create_voice_chat_task(
    settings: Settings,
    title: str,
    detail: str = "",
    due_text: str = "",
    due_at: float | None = None,
    recurrence: str | None = None,
    user_id: str | None = None,
    device_id: str | None = None,
) -> dict:
    conn = _open_memory_db(settings)
    if conn is None:
        raise HTTPException(status_code=501, detail="Voice memory DB is not configured.")

    normalized_title = title.strip()
    if not normalized_title:
        raise HTTPException(status_code=400, detail="Task title is required.")

    now = time.time()
    task_id = uuid.uuid4().hex
    normalized_user_id = _normalize_voice_chat_label(user_id, VOICE_CHAT_DEFAULT_USER_ID)
    normalized_device_id = _normalize_voice_chat_label(device_id, "")
    normalized_due_text = due_text.strip()[:120]
    normalized_recurrence = _normalize_voice_task_recurrence(recurrence) or parse_voice_task_recurrence(
        f"{normalized_due_text} {normalized_title}"
    )
    due_basis = normalized_due_text or normalized_title
    normalized_due_at = due_at if due_at is not None else parse_voice_task_due_at(due_basis, now)
    try:
        conn.execute(
            """
            INSERT INTO voice_chat_tasks (
                task_id, user_id, device_id, session_id, turn_index,
                title, detail, due_text, recurrence, due_at, reminded_at, status,
                source_text, created_at, updated_at
            )
            VALUES (?, ?, ?, '', 0, ?, ?, ?, ?, ?, NULL, 'open', ?, ?, ?)
            """,
            (
                task_id,
                normalized_user_id,
                normalized_device_id,
                normalized_title[:120],
                detail.strip()[:500],
                normalized_due_text,
                normalized_recurrence,
                normalized_due_at,
                normalized_title[:120],
                now,
                now,
            ),
        )
        conn.commit()
    except sqlite3.Error as error:
        raise HTTPException(status_code=500, detail="Failed to create voice task.") from error
    finally:
        conn.close()

    tasks = list_voice_chat_tasks(settings, user_id=normalized_user_id, status="open", limit=100)
    for task in tasks:
        if task["task_id"] == task_id:
            return task
    raise HTTPException(status_code=500, detail="Created voice task could not be loaded.")


def update_voice_chat_task(
    settings: Settings,
    task_id: str,
    *,
    title: str | None = None,
    detail: str | None = None,
    due_text: str | None = None,
    due_at: float | None = None,
    recurrence: str | None = None,
    status: str | None = None,
    reminded: bool | None = None,
) -> dict:
    normalized_task_id = task_id.strip()
    if not normalized_task_id:
        raise HTTPException(status_code=400, detail="Task id is required.")
    normalized_status = str(status or "").strip().lower()
    if status is not None and normalized_status not in VOICE_CHAT_TASK_STATUSES:
        raise HTTPException(status_code=400, detail="Unsupported task status.")

    conn = _open_memory_db(settings)
    if conn is None:
        raise HTTPException(status_code=501, detail="Voice memory DB is not configured.")

    updates = []
    values: list[str | float] = []
    if title is not None:
        cleaned = title.strip()
        if not cleaned:
            raise HTTPException(status_code=400, detail="Task title cannot be empty.")
        updates.append("title = ?")
        values.append(cleaned[:120])
    if detail is not None:
        updates.append("detail = ?")
        values.append(detail.strip()[:500])
    if due_text is not None:
        cleaned_due_text = due_text.strip()[:120]
        updates.append("due_text = ?")
        values.append(cleaned_due_text)
        updates.append("due_at = ?")
        values.append(parse_voice_task_due_at(cleaned_due_text, time.time()))
        if recurrence is None:
            parsed_recurrence = parse_voice_task_recurrence(cleaned_due_text)
            if parsed_recurrence:
                updates.append("recurrence = ?")
                values.append(parsed_recurrence)
    if due_at is not None:
        updates.append("due_at = ?")
        values.append(float(due_at))
    if recurrence is not None:
        updates.append("recurrence = ?")
        values.append(_normalize_voice_task_recurrence(recurrence))
    if status is not None:
        updates.append("status = ?")
        values.append(normalized_status)
    if reminded is not None:
        updates.append("reminded_at = ?")
        values.append(time.time() if reminded else None)

    if not updates:
        conn.close()
        raise HTTPException(status_code=400, detail="No task updates provided.")

    updates.append("updated_at = ?")
    values.append(time.time())
    values.append(normalized_task_id)

    try:
        cursor = conn.execute(
            f"UPDATE voice_chat_tasks SET {', '.join(updates)} WHERE task_id = ?",
            values,
        )
        conn.commit()
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Voice task not found.")
        row = conn.execute(
            """
            SELECT task_id, user_id, device_id, session_id, turn_index,
                   title, detail, due_text, recurrence, due_at, reminded_at,
                   status, source_text, created_at, updated_at
            FROM voice_chat_tasks
            WHERE task_id = ?
            """,
            (normalized_task_id,),
        ).fetchone()
    except HTTPException:
        raise
    except sqlite3.Error as error:
        raise HTTPException(status_code=500, detail="Failed to update voice task.") from error
    finally:
        conn.close()

    if row is None:
        raise HTTPException(status_code=404, detail="Voice task not found.")
    return _task_from_row(row)


def list_voice_chat_moods(settings: Settings, user_id: str | None = None, limit: int = 20) -> list[dict]:
    limit = _limit_query_count(limit, 20, 100)
    normalized_user_id = _normalize_voice_chat_label(user_id, VOICE_CHAT_DEFAULT_USER_ID)
    conn = _open_memory_db(settings)
    if conn is None:
        return []

    try:
        row_limit = min(limit * 5, 500)
        rows = conn.execute(
            """
            SELECT mood_id, user_id, device_id, session_id, turn_index,
                   mood, valence, confidence, source_text, created_at
            FROM voice_chat_moods
            WHERE user_id = ?
            ORDER BY created_at DESC
            LIMIT ?
            """,
            (normalized_user_id, row_limit),
        ).fetchall()
    except sqlite3.Error:
        return []
    finally:
        conn.close()

    moods = [
        {
            "mood_id": str(row["mood_id"]),
            "user_id": str(row["user_id"]),
            "device_id": str(row["device_id"]),
            "session_id": str(row["session_id"]),
            "turn_index": int(row["turn_index"]),
            "mood": str(row["mood"]),
            "valence": int(row["valence"]),
            "confidence": float(row["confidence"]),
            "source_text": str(row["source_text"]),
            "created_at": float(row["created_at"]),
        }
        for row in rows
    ]
    return _trim_unique_items(moods, ("mood", "valence", "source_text"), limit)


def _in_memory_session_history(session_id: str, limit: int) -> list[dict]:
    session = VOICE_CHAT_SESSIONS.get(session_id)
    if session is None:
        return []
    return [
        {
            "session_id": session.session_id,
            "turn_index": turn.turn_index,
            "user_text": turn.user,
            "assistant_text": turn.assistant,
            "user_id": turn.user_id,
            "device_id": turn.device_id,
            "created_at": turn.created_at,
        }
        for turn in session.turns[-limit:]
    ]


def get_voice_chat_session_turns(settings: Settings, session_id: str, limit: int = 50) -> list[dict]:
    normalized = _normalize_voice_chat_session_id(session_id)
    if normalized is None:
        return []

    limit = _limit_query_count(limit, 50, 200)
    conn = _open_memory_db(settings)
    if conn is None:
        return _in_memory_session_history(normalized, limit)

    try:
        rows = conn.execute(
            """
            SELECT turn_index, user_text, assistant_text, user_id, device_id, created_at
            FROM (
                SELECT turn_index, user_text, assistant_text, user_id, device_id, created_at
                FROM voice_chat_turns
                WHERE session_id = ?
                ORDER BY turn_index DESC
                LIMIT ?
            )
            ORDER BY turn_index ASC
            """,
            (normalized, limit),
        ).fetchall()
    except sqlite3.Error:
        return _in_memory_session_history(normalized, limit)
    finally:
        conn.close()

    if not rows:
        return _in_memory_session_history(normalized, limit)
    return [
        {
            "session_id": normalized,
            "turn_index": int(row["turn_index"]),
            "user_text": str(row["user_text"]),
            "assistant_text": str(row["assistant_text"]),
            "user_id": str(row["user_id"]),
            "device_id": str(row["device_id"]),
            "created_at": float(row["created_at"]),
        }
        for row in rows
    ]


def list_voice_chat_sessions(settings: Settings, limit: int = 20) -> list[dict]:
    limit = _limit_query_count(limit, 20, 100)
    conn = _open_memory_db(settings)
    if conn is None:
        summaries = []
        for session in sorted(VOICE_CHAT_SESSIONS.values(), key=lambda item: item.updated_at, reverse=True)[:limit]:
            last_turn = session.turns[-1] if session.turns else None
            summaries.append(
                {
                    "session_id": session.session_id,
                    "turn_index": session.turn_index,
                    "turn_count": len(session.turns),
                    "updated_at": session.updated_at,
                    "user_id": last_turn.user_id if last_turn else "",
                    "device_id": last_turn.device_id if last_turn else "",
                    "last_user_text": last_turn.user if last_turn else "",
                    "last_assistant_text": last_turn.assistant if last_turn else "",
                }
            )
        return summaries

    try:
        rows = conn.execute(
            """
            WITH latest AS (
                SELECT
                    session_id,
                    MAX(turn_index) AS turn_index,
                    COUNT(*) AS turn_count,
                    MAX(created_at) AS updated_at
                FROM voice_chat_turns
                GROUP BY session_id
            )
            SELECT
                latest.session_id,
                latest.turn_index,
                latest.turn_count,
                latest.updated_at,
                turns.user_id,
                turns.device_id,
                turns.user_text,
                turns.assistant_text
            FROM latest
            JOIN voice_chat_turns AS turns
              ON turns.session_id = latest.session_id
             AND turns.turn_index = latest.turn_index
            ORDER BY latest.updated_at DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
    except sqlite3.Error:
        return []
    finally:
        conn.close()

    return [
        {
            "session_id": str(row["session_id"]),
            "turn_index": int(row["turn_index"]),
            "turn_count": int(row["turn_count"]),
            "updated_at": float(row["updated_at"]),
            "user_id": str(row["user_id"]),
            "device_id": str(row["device_id"]),
            "last_user_text": str(row["user_text"]),
            "last_assistant_text": str(row["assistant_text"]),
        }
        for row in rows
    ]


def _get_or_create_voice_chat_session(
    session_id: str | None,
    reset: bool = False,
    settings: Settings | None = None,
) -> VoiceChatSession:
    now = time.time()
    cleanup_voice_chat_sessions(now)
    normalized = _normalize_voice_chat_session_id(session_id)
    if reset or normalized is None:
        normalized = uuid.uuid4().hex

    session = VOICE_CHAT_SESSIONS.get(normalized)
    if session is None or reset:
        turns, turn_index = ([], 0) if reset else _load_persisted_session(settings, normalized)
        session = VoiceChatSession(session_id=normalized, turns=turns, updated_at=now, turn_index=turn_index)
        VOICE_CHAT_SESSIONS[normalized] = session
    else:
        session.updated_at = now
    return session


def _append_voice_chat_turn(
    session: VoiceChatSession,
    user_text: str,
    assistant_text: str,
    user_id: str = VOICE_CHAT_DEFAULT_USER_ID,
    device_id: str = "",
) -> VoiceChatTurn:
    now = time.time()
    session.turn_index += 1
    turn = VoiceChatTurn(
        user=user_text,
        assistant=assistant_text,
        user_id=user_id,
        device_id=device_id,
        created_at=now,
        turn_index=session.turn_index,
    )
    session.turns.append(turn)
    if len(session.turns) > VOICE_CHAT_MAX_CONTEXT_TURNS:
        del session.turns[: len(session.turns) - VOICE_CHAT_MAX_CONTEXT_TURNS]
    session.updated_at = now
    return turn


def transcribe_wav_bytes(audio_bytes: bytes, settings: Settings | None = None) -> SpeechResult:
    """Transcribe raw WAV bytes with the configured optional ASR provider."""
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Empty audio body. POST raw WAV bytes.")

    tmp_path = ""
    try:
        prepared_audio = _prepare_wav_for_asr(audio_bytes)
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp.write(prepared_audio)
            tmp_path = tmp.name
        debug_dir = os.getenv("HOMECUE_ASR_DEBUG_DIR", "").strip()
        if debug_dir:
            debug_path = Path(debug_dir)
            debug_path.mkdir(parents=True, exist_ok=True)
            stamp = int(time.time() * 1000)
            (debug_path / f"asr-input-{stamp}.wav").write_bytes(audio_bytes)
            (debug_path / f"asr-prepared-{stamp}.wav").write_bytes(prepared_audio)

        provider = settings.voice_chat_asr_provider if settings is not None else "auto"
        if provider == "disabled":
            raise HTTPException(status_code=501, detail="Voice transcription is disabled by VOICE_CHAT_ASR_PROVIDER.")

        provider_available = False
        if provider in {"auto", "mimo"}:
            result = transcribe_wav_with_mimo(prepared_audio, settings)
            if result is not None and result.text:
                return result
            provider_available = provider_available or result is not None
            if provider == "mimo":
                if provider_available:
                    raise HTTPException(status_code=422, detail="Voice transcription did not detect speech.")
                raise HTTPException(
                    status_code=501,
                    detail="MiMo ASR is not configured. Set MIMO_API_KEY and VOICE_CHAT_ASR_MODEL=mimo-v2.5-asr.",
                )

        if provider in {"auto", "faster_whisper"}:
            result = transcribe_wav_with_faster_whisper(tmp_path, settings)
            if result is not None and result.text:
                return result
            provider_available = provider_available or result is not None
            if provider == "faster_whisper":
                raise HTTPException(
                    status_code=501,
                    detail="faster-whisper ASR is not available. Install faster-whisper or change VOICE_CHAT_ASR_PROVIDER.",
                )

        if provider in {"auto", "windows"}:
            result = transcribe_wav_with_windows_speech(tmp_path, settings)
            if result is not None and result.text:
                return result
            provider_available = provider_available or result is not None
            if provider == "windows":
                if provider_available:
                    raise HTTPException(status_code=422, detail="Voice transcription did not detect speech.")
                raise HTTPException(status_code=501, detail="Windows Speech Recognition ASR is not available on this host.")

        if provider_available:
            raise HTTPException(status_code=422, detail="Voice transcription did not detect speech.")

        raise HTTPException(
            status_code=501,
            detail=(
                "Voice transcription is not enabled. Install faster-whisper, "
                "enable Windows Speech Recognition ASR, or configure VOICE_CHAT_ASR_PROVIDER."
            ),
        )
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)


def _prepare_wav_for_asr(audio_bytes: bytes) -> bytes:
    """Normalize simple PCM WAV input before handing it to desktop ASR."""
    try:
        with wave.open(BytesIO(audio_bytes), "rb") as source:
            channels = source.getnchannels()
            sample_width = source.getsampwidth()
            sample_rate = source.getframerate()
            frames = source.readframes(source.getnframes())
    except wave.Error:
        return audio_bytes

    if sample_width != 2 or sample_rate <= 0:
        return audio_bytes

    samples = list(int.from_bytes(frames[i : i + 2], "little", signed=True) for i in range(0, len(frames), 2))
    if not samples:
        return audio_bytes

    if channels > 1:
        mono = []
        for i in range(0, len(samples), channels):
            frame = samples[i : i + channels]
            if not frame:
                continue
            mono.append(max(frame, key=lambda value: abs(value)))
        samples = mono
        channels = 1

    window = max(1, sample_rate // 10)
    active_windows = []
    for start in range(0, len(samples), window):
        segment = samples[start : start + window]
        if not segment:
            continue
        mean_abs = sum(abs(value) for value in segment) / len(segment)
        if mean_abs > 500:
            active_windows.append(start)

    if active_windows:
        start = max(0, active_windows[0] - sample_rate // 5)
        end = min(len(samples), active_windows[-1] + window + sample_rate // 5)
        samples = samples[start:end]

    peak = max(abs(value) for value in samples) if samples else 0
    if peak > 0:
        scale = min(1.0, 28000 / peak)
        samples = [max(-32768, min(32767, int(value * scale))) for value in samples]

    payload = b"".join(int(value).to_bytes(2, "little", signed=True) for value in samples)
    buffer = BytesIO()
    with wave.open(buffer, "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(sample_width)
        output.setframerate(sample_rate)
        output.writeframes(payload)
    return buffer.getvalue()


def _mimo_asr_model(settings: Settings | None) -> str:
    model = settings.voice_chat_asr_model.strip() if settings is not None else ""
    return model if model and model != "base" else "mimo-v2.5-asr"


def transcribe_wav_with_mimo(audio_bytes: bytes, settings: Settings | None = None) -> SpeechResult | None:
    if settings is None or not settings.qwen_api_key:
        return None

    model = _mimo_asr_model(settings)
    data_url = "data:audio/wav;base64," + base64.b64encode(audio_bytes).decode("ascii")
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_audio",
                        "input_audio": {"data": data_url, "format": "wav"},
                    }
                ],
            }
        ],
    }

    try:
        response = httpx.post(
            f"{settings.qwen_api_base.rstrip('/')}/chat/completions",
            headers={
                "Authorization": f"Bearer {settings.qwen_api_key}",
                "Content-Type": "application/json",
            },
            json=payload,
            timeout=60,
        )
        response.raise_for_status()
        data = response.json()
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        return None

    text = str(data["choices"][0]["message"].get("content") or "").strip()
    return SpeechResult(text=text, language=settings.voice_chat_asr_language or "unknown") if text else None


def transcribe_wav_with_faster_whisper(wav_path: str, settings: Settings | None = None) -> SpeechResult | None:
    try:
        from faster_whisper import WhisperModel  # type: ignore  # noqa: PLC0415
    except ImportError:
        return None

    model_name = settings.voice_chat_asr_model if settings is not None else "base"
    try:
        model = WhisperModel(model_name, device="cpu", compute_type="int8")
        segments, info = model.transcribe(wav_path)
    except Exception:  # noqa: BLE001 - keep auto provider able to fall back.
        return None

    text = " ".join(segment.text for segment in segments).strip()
    return SpeechResult(text=text, language=getattr(info, "language", "unknown")) if text else None


def transcribe_wav_with_windows_speech(wav_path: str, settings: Settings | None = None) -> SpeechResult | None:
    """Use installed Windows Speech Recognition as a lightweight local ASR."""
    if not sys.platform.startswith("win"):
        return None

    language = settings.voice_chat_asr_language if settings is not None else "zh-CN"
    env = os.environ.copy()
    env["HOMECUE_ASR_WAV"] = wav_path
    env["HOMECUE_ASR_LANGUAGE"] = language
    script = (
        "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
        "$OutputEncoding = [System.Text.Encoding]::UTF8; "
        "Add-Type -AssemblyName System.Speech; "
        "$culture = [System.Globalization.CultureInfo]::GetCultureInfo($env:HOMECUE_ASR_LANGUAGE); "
        "$r = New-Object System.Speech.Recognition.SpeechRecognitionEngine($culture); "
        "try { "
        "$r.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar)); "
        "$r.SetInputToWaveFile($env:HOMECUE_ASR_WAV); "
        "$result = $r.Recognize([TimeSpan]::FromSeconds(15)); "
        "if ($null -eq $result) { exit 2 }; "
        "@{ text = $result.Text; language = $r.RecognizerInfo.Culture.Name } | ConvertTo-Json -Compress "
        "} finally { $r.Dispose() }"
    )
    try:
        proc = subprocess.run(
            ["powershell", "-NoProfile", "-Command", script],
            check=True,
            env=env,
            timeout=30,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except subprocess.CalledProcessError as error:
        if error.returncode == 2:
            return SpeechResult(text="", language=language)
        return None
    except (OSError, subprocess.SubprocessError):
        return None

    try:
        payload = json.loads(proc.stdout or "")
    except json.JSONDecodeError:
        return None

    text = str(payload.get("text") or "").strip()
    returned_language = str(payload.get("language") or language)
    return SpeechResult(text=text, language=returned_language) if text else None


def voice_chat_asr_status(settings: Settings) -> dict:
    try:
        import faster_whisper  # type: ignore  # noqa: F401, PLC0415

        faster_whisper_available = True
    except ImportError:
        faster_whisper_available = False

    windows_available = sys.platform.startswith("win")
    mimo_available = bool(settings.qwen_api_key)
    provider = settings.voice_chat_asr_provider
    effective_provider = "disabled"
    if provider == "disabled":
        effective_provider = "disabled"
    elif provider == "mimo":
        effective_provider = "mimo" if mimo_available else "unavailable"
    elif provider == "faster_whisper":
        effective_provider = "faster_whisper" if faster_whisper_available else "unavailable"
    elif provider == "windows":
        effective_provider = "windows" if windows_available else "unavailable"
    elif mimo_available:
        effective_provider = "mimo"
    elif faster_whisper_available:
        effective_provider = "faster_whisper"
    elif windows_available:
        effective_provider = "windows"
    else:
        effective_provider = "unavailable"

    return {
        "provider": provider,
        "effective_provider": effective_provider,
        "model": settings.voice_chat_asr_model,
        "language": settings.voice_chat_asr_language,
        "mimo_available": mimo_available,
        "faster_whisper_available": faster_whisper_available,
        "windows_available": windows_available,
    }


def _compact_context_value(value: object, max_length: int = VOICE_CHAT_CONTEXT_VALUE_CHARS) -> str:
    cleaned = re.sub(r"\s+", " ", str(value or "")).strip()
    if len(cleaned) <= max_length:
        return cleaned
    return f"{cleaned[: max_length - 1]}..."


def _build_voice_chat_user_context(settings: Settings, user_id: str) -> str:
    """Summarize persisted same-user state for the next spoken reply."""
    memories = list_voice_chat_memories(settings, user_id=user_id, limit=VOICE_CHAT_MEMORY_CONTEXT_LIMIT)
    tasks = list_voice_chat_tasks(settings, user_id=user_id, status="open", limit=VOICE_CHAT_TASK_CONTEXT_LIMIT)
    moods = list_voice_chat_moods(settings, user_id=user_id, limit=VOICE_CHAT_MOOD_CONTEXT_LIMIT)

    if not memories and not tasks and not moods:
        return ""

    lines = [
        (
            "Long-term user context for the current user_id. Use it quietly to personalize the spoken reply; "
            "do not recite this context unless the user asks."
        )
    ]
    if memories:
        lines.append("Recent memories:")
        for memory in memories:
            memory_type = _compact_context_value(memory.get("memory_type"), 32)
            content = _compact_context_value(memory.get("content"))
            device_id = _compact_context_value(memory.get("device_id"), 48)
            suffix = f" via {device_id}" if device_id else ""
            lines.append(f"- {memory_type}: {content}{suffix}")
    if tasks:
        lines.append("Open tasks:")
        for task in tasks:
            title = _compact_context_value(task.get("title"))
            due_text = _compact_context_value(task.get("due_text"), 48)
            recurrence = _compact_context_value(task.get("recurrence"), 24)
            detail_parts = []
            if due_text:
                detail_parts.append(f"due={due_text}")
            if recurrence:
                detail_parts.append(f"recurs={recurrence}")
            suffix = f" ({', '.join(detail_parts)})" if detail_parts else ""
            lines.append(f"- {title}{suffix}")
    if moods:
        lines.append("Recent mood signals:")
        for mood in moods:
            label = _compact_context_value(mood.get("mood"), 48)
            valence = mood.get("valence")
            lines.append(f"- {label} valence={valence}")
    return "\n".join(lines)


async def build_voice_chat_reply(
    text: str,
    settings: Settings,
    session_id: str | None = None,
    reset_session: bool = False,
    user_id: str | None = None,
    device_id: str | None = None,
) -> tuple[str, str, str, int]:
    """Return a spoken-friendly assistant reply, provider, and session metadata."""
    prompt = text.strip()
    if not prompt:
        raise HTTPException(status_code=400, detail="Empty chat text.")

    normalized_user_id = _normalize_voice_chat_label(user_id, VOICE_CHAT_DEFAULT_USER_ID)
    normalized_device_id = _normalize_voice_chat_label(device_id, "")
    session = _get_or_create_voice_chat_session(session_id, reset_session, settings)

    if not settings.qwen_api_key:
        reply = "我已经听到了，但当前没有配置在线聊天模型。"
        turn = _append_voice_chat_turn(session, prompt, reply, normalized_user_id, normalized_device_id)
        _persist_voice_chat_turn(settings, session.session_id, turn)
        _capture_voice_chat_insights(settings, session.session_id, turn)
        return reply, "mock", session.session_id, turn.turn_index

    messages = [{"role": "system", "content": VOICE_CHAT_SYSTEM_PROMPT.strip()}]
    user_context = _build_voice_chat_user_context(settings, normalized_user_id)
    if user_context:
        messages.append({"role": "system", "content": user_context})
    for turn in session.turns[-VOICE_CHAT_MAX_CONTEXT_TURNS:]:
        messages.append({"role": "user", "content": turn.user})
        messages.append({"role": "assistant", "content": turn.assistant})
    messages.append({"role": "user", "content": prompt})

    payload = {
        "model": settings.qwen_model,
        "messages": messages,
        "temperature": 0.4,
        "max_tokens": 180,
    }

    data = await _chat_completion(payload, settings)
    reply = (data["choices"][0]["message"].get("content") or "").strip()
    provider = "mimo" if "mimo" in settings.qwen_model.lower() else "qwen"
    if not reply:
        reply = "我听到了，但这次没有生成有效回复。"
    turn = _append_voice_chat_turn(session, prompt, reply, normalized_user_id, normalized_device_id)
    _persist_voice_chat_turn(settings, session.session_id, turn)
    _capture_voice_chat_insights(settings, session.session_id, turn)
    return reply, provider, session.session_id, turn.turn_index


def speak_on_pc(text: str) -> Literal["played", "unavailable", "empty"]:
    """Play a reply through the Windows default speaker when available."""
    if not text.strip():
        return "empty"

    if not sys.platform.startswith("win"):
        return "unavailable"

    env = os.environ.copy()
    env["HOMECUE_TTS_TEXT"] = text
    script = (
        "Add-Type -AssemblyName System.Speech; "
        "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
        "try { $s.SetOutputToDefaultAudioDevice(); $s.Speak($env:HOMECUE_TTS_TEXT) } "
        "finally { $s.Dispose() }"
    )
    try:
        subprocess.run(
            ["powershell", "-NoProfile", "-Command", script],
            check=True,
            env=env,
            timeout=60,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except (OSError, subprocess.SubprocessError):
        return "unavailable"
    return "played"


def cleanup_voice_chat_audio(now: float | None = None) -> None:
    """Remove old generated TTS WAV files from the runtime cache."""
    if not VOICE_CHAT_AUDIO_DIR.exists():
        return

    cutoff = (now or time.time()) - VOICE_CHAT_AUDIO_TTL_SECONDS
    for path in VOICE_CHAT_AUDIO_DIR.glob("*.wav"):
        try:
            if path.stat().st_mtime < cutoff:
                path.unlink()
        except OSError:
            continue


def _valid_wav_path(path: Path) -> bool:
    try:
        return path.exists() and path.stat().st_size > 44 and path.read_bytes()[:4] == b"RIFF"
    except OSError:
        return False


def _dashscope_tts_endpoint(api_base: str) -> str:
    base = api_base.rstrip("/")
    if "/services/" in base:
        return base
    return f"{base}/services/aigc/multimodal-generation/generation"


def _download_wav_from_url(url: str, wav_path: Path) -> bool:
    try:
        with httpx.stream("GET", url, timeout=60, follow_redirects=True) as response:
            response.raise_for_status()
            with wav_path.open("wb") as output:
                for chunk in response.iter_bytes():
                    output.write(chunk)
    except (httpx.HTTPError, OSError):
        try:
            wav_path.unlink(missing_ok=True)
        except OSError:
            pass
        return False
    return _valid_wav_path(wav_path)


def _synthesize_reply_wav_with_dashscope(text: str, settings: Settings) -> ReplyAudioResult | None:
    if not settings.voice_chat_tts_api_key:
        return None

    VOICE_CHAT_AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    cleanup_voice_chat_audio()
    wav_path = VOICE_CHAT_AUDIO_DIR / f"{uuid.uuid4().hex}.wav"

    payload = {
        "model": settings.voice_chat_tts_model,
        "input": {
            "text": text,
            "voice": settings.voice_chat_tts_voice,
            "language_type": settings.voice_chat_tts_language_type,
        },
    }
    headers = {
        "Authorization": f"Bearer {settings.voice_chat_tts_api_key}",
        "Content-Type": "application/json",
    }
    try:
        response = httpx.post(
            _dashscope_tts_endpoint(settings.voice_chat_tts_api_base),
            headers=headers,
            json=payload,
            timeout=60,
        )
        response.raise_for_status()
        data = response.json()
    except (httpx.HTTPError, ValueError):
        return None

    audio_url = str(data.get("output", {}).get("audio", {}).get("url") or "").strip()
    if not audio_url or not _download_wav_from_url(audio_url, wav_path):
        return None

    return ReplyAudioResult(
        path=wav_path,
        provider="dashscope",
        model=settings.voice_chat_tts_model,
        voice=settings.voice_chat_tts_voice,
    )


def _mimo_tts_endpoint(api_base: str) -> str:
    return f"{api_base.rstrip('/')}/chat/completions"


def _mimo_tts_payload(text: str, settings: Settings, *, stream: bool = False) -> dict:
    payload = {
        "model": settings.voice_chat_tts_model,
        "messages": [{"role": "assistant", "content": text}],
        "audio": {"voice": settings.voice_chat_tts_voice, "format": "wav"},
    }
    if stream:
        payload["stream"] = True
    return payload


def _mimo_tts_headers(settings: Settings) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {settings.voice_chat_tts_api_key}",
        "Content-Type": "application/json",
    }


def _mimo_tts_audio_chunks_from_sse_data(data: str) -> Iterator[bytes]:
    if not data or data == "[DONE]":
        return

    payload = json.loads(data)
    for choice in payload.get("choices") or []:
        delta = choice.get("delta") or {}
        audio = delta.get("audio") or {}
        if not isinstance(audio, dict):
            continue
        audio_data = audio.get("data")
        if audio_data:
            yield base64.b64decode(audio_data, validate=True)


def _iter_mimo_tts_wav_segments(text: str, settings: Settings) -> Iterator[bytes]:
    data_lines: list[str] = []
    with httpx.stream(
        "POST",
        _mimo_tts_endpoint(settings.voice_chat_tts_api_base),
        headers=_mimo_tts_headers(settings),
        json=_mimo_tts_payload(text, settings, stream=True),
        timeout=60,
    ) as response:
        response.raise_for_status()
        for line in response.iter_lines():
            if line == "":
                if data_lines:
                    yield from _mimo_tts_audio_chunks_from_sse_data("".join(data_lines))
                    data_lines = []
                continue
            if line.startswith("data:"):
                data_lines.append(line[5:].strip())

        if data_lines:
            yield from _mimo_tts_audio_chunks_from_sse_data("".join(data_lines))


def stream_reply_wav_segments(text: str, settings: Settings) -> ReplyAudioStreamResult | None:
    """Stream MiMo TTS as independent WAV segments when the provider supports it."""
    if not text.strip() or settings.voice_chat_tts_provider != "mimo" or not settings.voice_chat_tts_api_key:
        return None

    return ReplyAudioStreamResult(
        chunks=_iter_mimo_tts_wav_segments(text, settings),
        provider="mimo",
        model=settings.voice_chat_tts_model,
        voice=settings.voice_chat_tts_voice,
    )


def _synthesize_reply_wav_with_mimo(text: str, settings: Settings) -> ReplyAudioResult | None:
    if not settings.voice_chat_tts_api_key:
        return None

    VOICE_CHAT_AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    cleanup_voice_chat_audio()
    wav_path = VOICE_CHAT_AUDIO_DIR / f"{uuid.uuid4().hex}.wav"

    try:
        response = httpx.post(
            _mimo_tts_endpoint(settings.voice_chat_tts_api_base),
            headers=_mimo_tts_headers(settings),
            json=_mimo_tts_payload(text, settings),
            timeout=60,
        )
        response.raise_for_status()
        data = response.json()
        audio_data = data["choices"][0]["message"]["audio"]["data"]
        wav_path.write_bytes(base64.b64decode(audio_data, validate=True))
    except (httpx.HTTPError, KeyError, IndexError, TypeError, ValueError, OSError):
        try:
            wav_path.unlink(missing_ok=True)
        except OSError:
            pass
        return None

    if not _valid_wav_path(wav_path):
        return None

    return ReplyAudioResult(
        path=wav_path,
        provider="mimo",
        model=settings.voice_chat_tts_model,
        voice=settings.voice_chat_tts_voice,
    )


def _synthesize_reply_wav_with_windows(text: str) -> ReplyAudioResult | None:
    """Generate a WAV reply with Windows TTS and return its local path."""
    if not text.strip() or not sys.platform.startswith("win"):
        return None

    VOICE_CHAT_AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    cleanup_voice_chat_audio()
    wav_path = VOICE_CHAT_AUDIO_DIR / f"{uuid.uuid4().hex}.wav"

    env = os.environ.copy()
    env["HOMECUE_TTS_TEXT"] = text
    env["HOMECUE_TTS_WAV"] = str(wav_path)
    script = (
        "Add-Type -AssemblyName System.Speech; "
        "$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo("
        "16000, "
        "[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, "
        "[System.Speech.AudioFormat.AudioChannel]::Mono"
        "); "
        "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
        "try { "
        "$s.SetOutputToWaveFile($env:HOMECUE_TTS_WAV, $fmt); "
        "$s.Speak($env:HOMECUE_TTS_TEXT) "
        "} finally { $s.Dispose() }"
    )
    try:
        subprocess.run(
            ["powershell", "-NoProfile", "-Command", script],
            check=True,
            env=env,
            timeout=60,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except (OSError, subprocess.SubprocessError):
        try:
            wav_path.unlink(missing_ok=True)
        except OSError:
            pass
        return None

    if not _valid_wav_path(wav_path):
        return None

    return ReplyAudioResult(
        path=wav_path,
        provider="windows",
        model="System.Speech.Synthesis.SpeechSynthesizer",
        voice="default",
    )


def synthesize_reply_wav(text: str, settings: Settings | None = None) -> ReplyAudioResult | None:
    """Generate a WAV reply and return its local path plus TTS metadata."""
    if not text.strip():
        return None

    if settings is None:
        return _synthesize_reply_wav_with_windows(text)

    if settings.voice_chat_tts_provider == "mimo":
        return _synthesize_reply_wav_with_mimo(text, settings)

    if settings.voice_chat_tts_provider in {"dashscope", "auto"}:
        result = _synthesize_reply_wav_with_dashscope(text, settings)
        if result is not None:
            return result
        if settings.voice_chat_tts_provider == "dashscope":
            return None

    return _synthesize_reply_wav_with_windows(text)
