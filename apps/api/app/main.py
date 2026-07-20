import ipaddress
import secrets
from urllib.parse import urlencode, urlparse

import httpx
from fastapi import FastAPI, HTTPException, Request, WebSocket
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse

from app.config import get_settings
from app.context import BASE_CONTEXT
from app.devices import DeviceStore
from app.planner.service import build_plan_with_trace
from app.planner.tools import validate_action
from app.schemas import (
    Esp32SpeakerTestRequest,
    ExecuteRequest,
    PlanRequest,
    VoiceChatRequest,
    VoiceChatTaskRequest,
    VoiceChatTaskUpdateRequest,
)
from app.voice_chat import (
    ReplyAudioResult,
    VOICE_CHAT_AUDIO_DIR,
    build_voice_chat_reply,
    create_voice_chat_task,
    get_voice_chat_session_turns,
    list_due_voice_chat_tasks,
    list_voice_chat_memories,
    list_voice_chat_moods,
    list_voice_chat_sessions,
    list_voice_chat_tasks,
    speak_on_pc,
    synthesize_reply_wav,
    transcribe_wav_bytes,
    update_voice_chat_task,
    voice_chat_asr_status,
)
from app.voice_chat_ws import run_voice_chat_websocket


app = FastAPI(title="HomeCue Edge API", version="0.1.0")
device_store = DeviceStore()

_VOICE_AUTH_PATHS = {"/voice"}
_VOICE_AUTH_PREFIXES = ("/voice-chat", "/esp32/diag")


def _voice_access_token() -> str:
    return get_settings().voice_chat_access_token.strip()


def _protected_voice_path(path: str) -> bool:
    return path in _VOICE_AUTH_PATHS or any(path.startswith(prefix) for prefix in _VOICE_AUTH_PREFIXES)


def _bearer_value(header_value: str) -> str:
    scheme, _, value = header_value.strip().partition(" ")
    if scheme.lower() != "bearer" or not value:
        return ""
    return value.strip()


def _request_token(request: Request) -> str:
    auth_value = _bearer_value(request.headers.get("authorization", ""))
    if auth_value:
        return auth_value
    header_value = request.headers.get("x-homecue-token", "").strip()
    if header_value:
        return header_value
    return (request.query_params.get("access_token") or request.query_params.get("token") or "").strip()


def _websocket_token(websocket: WebSocket) -> str:
    auth_value = _bearer_value(websocket.headers.get("authorization", ""))
    if auth_value:
        return auth_value
    header_value = websocket.headers.get("x-homecue-token", "").strip()
    if header_value:
        return header_value
    return (websocket.query_params.get("access_token") or websocket.query_params.get("token") or "").strip()


def _token_matches(candidate: str, expected: str) -> bool:
    return bool(candidate) and secrets.compare_digest(candidate, expected)


@app.middleware("http")
async def voice_access_token_middleware(request: Request, call_next):
    expected = _voice_access_token()
    if (
        expected
        and request.method != "OPTIONS"
        and _protected_voice_path(request.url.path)
        and not _token_matches(_request_token(request), expected)
    ):
        return JSONResponse(
            {"detail": "Voice API access token required."},
            status_code=401,
            headers={"WWW-Authenticate": "Bearer"},
        )
    return await call_next(request)


def _normalize_esp32_base_url(base_url: str) -> str:
    candidate = base_url.strip().rstrip("/")
    parsed = urlparse(candidate)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="ESP32 base_url must be an http(s) URL.")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise HTTPException(status_code=400, detail="ESP32 base_url must not include credentials, query, or fragment.")
    host = parsed.hostname or ""
    try:
        address = ipaddress.ip_address(host)
        allowed = address.is_private or address.is_loopback or address.is_link_local
    except ValueError:
        allowed = host in {"localhost"} or host.endswith(".local")
    if not allowed:
        raise HTTPException(status_code=400, detail="ESP32 base_url must target a local or private-network host.")
    return candidate


async def _get_esp32_json(url: str, timeout: float = 15.0) -> dict:
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.get(url)
            response.raise_for_status()
            payload = response.json()
    except httpx.HTTPStatusError as error:
        raise HTTPException(status_code=502, detail=f"ESP32 returned HTTP {error.response.status_code}.") from error
    except (httpx.HTTPError, ValueError) as error:
        raise HTTPException(status_code=502, detail=f"ESP32 diagnostic request failed: {error}") from error
    if not isinstance(payload, dict):
        raise HTTPException(status_code=502, detail="ESP32 diagnostic response was not a JSON object.")
    return payload


def _reply_audio_payload(status: str, audio: ReplyAudioResult | None = None, access_token: str = "") -> dict:
    url = f"/voice-chat/audio/{audio.path.name}" if audio else ""
    if url and access_token:
        url = f"{url}?{urlencode({'access_token': access_token})}"
    return {
        "target": "esp32-speaker",
        "status": status,
        "url": url,
        "provider": audio.provider if audio else "",
        "model": audio.model if audio else "",
        "voice": audio.voice if audio else "",
    }


def _voice_chat_status_payload() -> dict:
    settings = get_settings()
    return {
        "provider": settings.active_provider if settings.qwen_api_key else "mock",
        "model": settings.qwen_model,
        "tts": {
            "provider": settings.voice_chat_tts_provider,
            "model": settings.voice_chat_tts_model,
            "voice": settings.voice_chat_tts_voice,
            "configured": bool(settings.voice_chat_tts_api_key) or settings.voice_chat_tts_provider == "windows",
        },
        "memory": {
            "sqlite_enabled": bool(settings.voice_chat_memory_db.strip()),
        },
        "asr": voice_chat_asr_status(settings),
        "realtime": {
            "websocket": True,
            "pcm_s16le": True,
            "stt_partial_events": True,
            "audio_partial_asr": False,
            "mimo_streaming_tts": settings.voice_chat_tts_provider == "mimo",
            "opus_stream": False,
            "full_duplex": False,
        },
    }


app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"^http://(localhost|127\.0\.0\.1|10\.\d+\.\d+\.\d+|172\.(1[6-9]|2\d|3[0-1])\.\d+\.\d+|192\.168\.\d+\.\d+):\d+$",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health() -> dict:
    settings = get_settings()
    provider = settings.planner_provider
    if provider == "auto" and settings.qwen_api_key:
        provider = settings.active_provider
    elif provider == "auto":
        provider = "mock"

    return {
        "status": "ok",
        "service": "homecue-edge-api",
        "planner_provider": provider,
        "qwen_configured": bool(settings.qwen_api_key),
        "active_provider": settings.active_provider if settings.qwen_api_key else "mock",
        "model": settings.qwen_model,
    }


@app.get("/voice-chat/status")
def voice_chat_status() -> dict:
    return _voice_chat_status_payload()


@app.get("/esp32/diag/health")
async def esp32_diag_health(base_url: str) -> dict:
    board_base_url = _normalize_esp32_base_url(base_url)
    payload = await _get_esp32_json(f"{board_base_url}/health", timeout=10.0)
    return {"base_url": board_base_url, "health": payload}


@app.post("/esp32/diag/speaker-test")
async def esp32_diag_speaker_test(request: Esp32SpeakerTestRequest) -> dict:
    board_base_url = _normalize_esp32_base_url(request.base_url)
    url = f"{board_base_url}/speaker-test?seconds={request.seconds}&mode={request.mode}"
    payload = await _get_esp32_json(url, timeout=max(20.0, request.seconds + 15.0))
    return {
        "base_url": board_base_url,
        "speaker_test": payload,
        "human_audible_confirmation_required": True,
    }


@app.get("/context")
def get_context() -> dict:
    return BASE_CONTEXT


@app.get("/devices")
def get_devices() -> dict:
    return device_store.all()


@app.post("/plan")
async def plan(request: PlanRequest) -> dict:
    routine, trace = await build_plan_with_trace(
        request.prompt,
        request.network_mode,
        BASE_CONTEXT,
        get_settings(),
        request.agent_mode,
    )

    # Read-only pre-check of every proposed action against the edge policy.
    # This never mutates device state, so it is safe in both propose and
    # execute mode and gives the hardware/web a preview of guard decisions.
    precheck = [validate_action(action.model_dump()) for action in routine.actions]

    execution: list[dict] = []
    if request.execute:
        # Original behaviour: run the routine through the single guarded path.
        for action in routine.actions:
            result = device_store.apply_action(action.model_dump())
            execution.append(result.to_dict())

    return {
        "context": BASE_CONTEXT,
        "routine": routine.model_dump(),
        "execution": execution,
        "precheck": precheck,
        "executed": request.execute,
        "devices": device_store.all(),
        "trace": trace,
    }


@app.post("/execute")
def execute(request: ExecuteRequest) -> dict:
    """Run a human-confirmed subset of actions. The DeviceStore guard remains
    the single source of truth, so disallowed actions are rejected here too."""
    execution = []
    for action in request.actions:
        result = device_store.apply_action(action.model_dump())
        execution.append(result.to_dict())

    return {
        "execution": execution,
        "devices": device_store.all(),
    }


@app.post("/voice")
async def voice(request: Request) -> dict:
    """Transcribe raw uploaded WAV bytes when optional ASR is installed.

    `faster-whisper` is intentionally NOT a hard dependency; if it is missing we
    return 501 so the firmware can gracefully fall back to fixed command words.
    """
    result = transcribe_wav_bytes(await request.body(), get_settings())
    return {"text": result.text, "language": result.language}


@app.post("/voice-chat")
async def voice_chat(request: Request) -> dict:
    """Voice chat endpoint for the ESP32 terminal.

    Accepts either JSON `{"text": "...", "speak": true}` for fast testing, or
    raw WAV bytes for the ESP32 upload path. WAV requests may set
    `?speak=1` to play the reply through the PC's default audio device, or
    `?reply_audio=1` to return a short WAV URL for ESP32 speaker playback.
    """
    content_type = request.headers.get("content-type", "")
    speak = request.query_params.get("speak", "").strip().lower() in {"1", "true", "yes"}
    reply_audio = request.query_params.get("reply_audio", "").strip().lower() in {"1", "true", "yes"}
    session_id = request.query_params.get("session_id")
    reset_session = request.query_params.get("reset_session", "").strip().lower() in {"1", "true", "yes"}
    user_id = request.query_params.get("user_id")
    device_id = request.query_params.get("device_id")
    language = "text"
    settings = get_settings()
    request_access_token = _request_token(request) if _voice_access_token() else ""

    if content_type.startswith("application/json"):
        payload = VoiceChatRequest.model_validate(await request.json())
        text = payload.text
        speak = payload.speak or speak
        reply_audio = payload.reply_audio or reply_audio
        session_id = payload.session_id or session_id
        reset_session = payload.reset_session or reset_session
        user_id = payload.user_id or user_id
        device_id = payload.device_id or device_id
    else:
        speech = transcribe_wav_bytes(await request.body(), settings)
        text = speech.text
        language = speech.language

    reply, provider, session_id, turn_index = await build_voice_chat_reply(
        text,
        settings,
        session_id=session_id,
        reset_session=reset_session,
        user_id=user_id,
        device_id=device_id,
    )
    tts_status = speak_on_pc(reply) if speak else "skipped"
    reply_audio_payload = _reply_audio_payload("skipped")
    if reply_audio:
        audio = synthesize_reply_wav(reply, settings)
        if audio is None:
            reply_audio_payload = _reply_audio_payload("unavailable")
        else:
            reply_audio_payload = _reply_audio_payload("ready", audio, access_token=request_access_token)

    return {
        "text": text,
        "language": language,
        "reply": reply,
        "provider": provider,
        "session_id": session_id,
        "turn_index": turn_index,
        "tts": {"target": "pc-speaker", "status": tts_status},
        "reply_audio": reply_audio_payload,
    }


@app.get("/voice-chat/tts")
def voice_chat_tts(request: Request, text: str) -> dict:
    normalized = text.strip()
    if not normalized:
        raise HTTPException(status_code=400, detail="text is required.")
    if len(normalized) > 160:
        raise HTTPException(status_code=400, detail="text is too long.")

    settings = get_settings()
    request_access_token = _request_token(request) if _voice_access_token() else ""
    audio = synthesize_reply_wav(normalized, settings)
    if audio is None:
        return {
            "text": normalized,
            "reply_audio": _reply_audio_payload("unavailable"),
        }

    return {
        "text": normalized,
        "reply_audio": _reply_audio_payload("ready", audio, access_token=request_access_token),
    }


@app.get("/voice-chat/sessions")
def voice_chat_sessions(limit: int = 20) -> dict:
    return {"sessions": list_voice_chat_sessions(get_settings(), limit=limit)}


@app.get("/voice-chat/sessions/{session_id}")
def voice_chat_session(session_id: str, limit: int = 50) -> dict:
    return {
        "session_id": session_id,
        "turns": get_voice_chat_session_turns(get_settings(), session_id, limit=limit),
    }


@app.get("/voice-chat/memories")
def voice_chat_memories(user_id: str | None = None, limit: int = 20) -> dict:
    return {"memories": list_voice_chat_memories(get_settings(), user_id=user_id, limit=limit)}


@app.get("/voice-chat/tasks")
def voice_chat_tasks(user_id: str | None = None, status: str | None = "open", limit: int = 20) -> dict:
    return {"tasks": list_voice_chat_tasks(get_settings(), user_id=user_id, status=status, limit=limit)}


@app.post("/voice-chat/tasks")
def voice_chat_task_create(request: VoiceChatTaskRequest) -> dict:
    return {
        "task": create_voice_chat_task(
            get_settings(),
            title=request.title,
            detail=request.detail,
            due_text=request.due_text,
            due_at=request.due_at,
            recurrence=request.recurrence,
            user_id=request.user_id,
            device_id=request.device_id,
        )
    }


@app.patch("/voice-chat/tasks/{task_id}")
def voice_chat_task_update(task_id: str, request: VoiceChatTaskUpdateRequest) -> dict:
    return {
        "task": update_voice_chat_task(
            get_settings(),
            task_id,
            title=request.title,
            detail=request.detail,
            due_text=request.due_text,
            due_at=request.due_at,
            recurrence=request.recurrence,
            status=request.status,
            reminded=request.reminded,
        )
    }


@app.get("/voice-chat/tasks/due")
def voice_chat_tasks_due(
    user_id: str | None = None,
    now: float | None = None,
    limit: int = 20,
    mark_reminded: bool = False,
) -> dict:
    return {
        "tasks": list_due_voice_chat_tasks(
            get_settings(),
            user_id=user_id,
            now=now,
            limit=limit,
            mark_reminded=mark_reminded,
        )
    }


@app.get("/voice-chat/tasks/due-audio")
def voice_chat_tasks_due_audio(request: Request, user_id: str | None = None, now: float | None = None) -> dict:
    settings = get_settings()
    request_access_token = _request_token(request) if _voice_access_token() else ""
    tasks = list_due_voice_chat_tasks(
        settings,
        user_id=user_id,
        now=now,
        limit=1,
        mark_reminded=True,
    )
    if not tasks:
        return {
            "status": "empty",
            "task": None,
            "reply_audio": _reply_audio_payload("skipped"),
        }

    task = tasks[0]
    due_text = task.get("due_text") or "现在"
    spoken = f"提醒：{task['title']}。时间：{due_text}。"
    audio = synthesize_reply_wav(spoken, settings)
    if audio is None:
        return {
            "status": "audio_unavailable",
            "task": task,
            "text": spoken,
            "reply_audio": _reply_audio_payload("unavailable"),
        }

    return {
        "status": "ready",
        "task": task,
        "text": spoken,
        "reply_audio": _reply_audio_payload("ready", audio, access_token=request_access_token),
    }


@app.get("/voice-chat/moods")
def voice_chat_moods(user_id: str | None = None, limit: int = 20) -> dict:
    return {"moods": list_voice_chat_moods(get_settings(), user_id=user_id, limit=limit)}


@app.websocket("/voice-chat/ws")
async def voice_chat_websocket(websocket: WebSocket) -> None:
    settings = get_settings()
    expected = settings.voice_chat_access_token.strip()
    if expected and not _token_matches(_websocket_token(websocket), expected):
        await websocket.close(code=1008)
        return
    await run_voice_chat_websocket(websocket, settings)


@app.get("/voice-chat/audio/{filename}")
def voice_chat_audio(filename: str) -> FileResponse:
    if "/" in filename or "\\" in filename or not filename.endswith(".wav"):
        raise HTTPException(status_code=404, detail="Audio file not found.")

    path = (VOICE_CHAT_AUDIO_DIR / filename).resolve()
    audio_dir = VOICE_CHAT_AUDIO_DIR.resolve()
    if audio_dir not in path.parents or not path.exists():
        raise HTTPException(status_code=404, detail="Audio file not found.")

    return FileResponse(path, media_type="audio/wav", filename=filename)


@app.post("/devices/reset")
def reset_devices() -> dict:
    return device_store.reset()
