"""WebSocket voice-chat flow for live ESP32-style sessions."""

from __future__ import annotations

import json
import wave
from io import BytesIO
import uuid
from typing import Any, Iterator

from fastapi import HTTPException, WebSocket, WebSocketDisconnect

from app.config import Settings
from app.voice_chat import build_voice_chat_reply, stream_reply_wav_segments, synthesize_reply_wav, transcribe_wav_bytes


PROTOCOL_NAME = "homecue.voice.v1"
REPLY_AUDIO_CHUNK_BYTES = 16 * 1024
SUPPORTED_AUDIO_PARAMS = {
    "format": "wav",
    "sample_rate": 16000,
    "channels": 1,
    "frame_duration": 60,
}


def _normalize_audio_params(value: Any, fallback: dict[str, Any]) -> dict[str, Any]:
    params = dict(fallback)
    if not isinstance(value, dict):
        return params

    audio_format = str(value.get("format") or params["format"]).strip().lower()
    if audio_format in {"wav", "pcm", "pcm_s16le"}:
        params["format"] = "pcm_s16le" if audio_format == "pcm" else audio_format

    for key in ("sample_rate", "channels", "frame_duration"):
        try:
            parsed = int(value.get(key, params[key]))
        except (TypeError, ValueError):
            continue
        if parsed > 0:
            params[key] = parsed
    return params


def _pcm_s16le_to_wav(audio: bytes, sample_rate: int, channels: int) -> bytes:
    buffer = BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(max(1, channels))
        wav.setsampwidth(2)
        wav.setframerate(max(8000, sample_rate))
        wav.writeframes(audio)
    return buffer.getvalue()


def _truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _session_id_from_message(payload: dict[str, Any], fallback: str | None = None) -> str:
    candidate = str(payload.get("session_id") or "").strip()
    if 8 <= len(candidate) <= 64 and all(ch.isalnum() or ch in "_-" for ch in candidate):
        return candidate
    return fallback or uuid.uuid4().hex


def _normalize_reply_audio_transport(value: Any, fallback: str) -> str:
    candidate = str(value or "").strip().lower()
    if candidate in {"websocket_binary", "websocket_binary_chunked", "websocket_binary_stream"}:
        return candidate
    return fallback


def _client_label_from_message(payload: dict[str, Any], field: str, fallback: str | None = None) -> str | None:
    candidate = str(payload.get(field) or "").strip()
    if candidate:
        return candidate[:96]
    return fallback


def _transcript_text_from_message(payload: dict[str, Any]) -> str:
    return str(payload.get("text") or payload.get("transcript") or "").strip()


async def _send_error(websocket: WebSocket, code: str, detail: Any) -> None:
    await websocket.send_json({"type": "error", "code": code, "detail": str(detail)})


def _next_nonempty_chunk(chunks: Iterator[bytes]) -> bytes | None:
    for chunk in chunks:
        if chunk:
            return chunk
    return None


async def _send_streaming_reply_audio(websocket: WebSocket, text: str, settings: Settings, session_id: str) -> bool:
    audio = stream_reply_wav_segments(text, settings)
    if audio is None:
        return False

    chunks = iter(audio.chunks)
    try:
        first_chunk = _next_nonempty_chunk(chunks)
    except Exception:  # noqa: BLE001 - keep the voice session alive if provider streaming fails.
        return False

    if first_chunk is None:
        return False

    chunk_count = 1
    byte_count = len(first_chunk)
    await websocket.send_json(
        {
            "type": "tts",
            "state": "audio",
            "status": "ready",
            "format": "wav",
            "url": "",
            "bytes": 0,
            "transport": "websocket_binary_stream",
            "chunk_size": 0,
            "chunk_count": 0,
            "provider": audio.provider,
            "model": audio.model,
            "voice": audio.voice,
            "session_id": session_id,
        }
    )
    await websocket.send_bytes(first_chunk)

    try:
        for chunk in chunks:
            if not chunk:
                continue
            chunk_count += 1
            byte_count += len(chunk)
            await websocket.send_bytes(chunk)
    except Exception as error:  # noqa: BLE001 - report provider stream errors over the protocol.
        await _send_error(websocket, "tts_failed", error)

    await websocket.send_json(
        {
            "type": "tts",
            "state": "audio_done",
            "format": "wav",
            "bytes": byte_count,
            "transport": "websocket_binary_stream",
            "chunk_count": chunk_count,
            "session_id": session_id,
        }
    )
    return True


async def _send_file_reply_audio(
    websocket: WebSocket,
    text: str,
    settings: Settings,
    session_id: str,
    reply_audio_transport: str,
) -> None:
    audio = synthesize_reply_wav(text, settings)
    if audio is None:
        await websocket.send_json(
            {
                "type": "tts",
                "state": "audio",
                "status": "unavailable",
                "format": "wav",
                "session_id": session_id,
            }
        )
        return

    binary_transport = reply_audio_transport
    if binary_transport == "websocket_binary_stream":
        binary_transport = "websocket_binary_chunked"
    audio_payload = (
        audio.path.read_bytes() if binary_transport in {"websocket_binary", "websocket_binary_chunked"} else b""
    )
    chunk_count = (
        (len(audio_payload) + REPLY_AUDIO_CHUNK_BYTES - 1) // REPLY_AUDIO_CHUNK_BYTES
        if binary_transport == "websocket_binary_chunked" and audio_payload
        else (1 if audio_payload else 0)
    )
    await websocket.send_json(
        {
            "type": "tts",
            "state": "audio",
            "status": "ready",
            "format": "wav",
            "url": "" if audio_payload else f"/voice-chat/audio/{audio.path.name}",
            "bytes": audio.path.stat().st_size,
            "transport": binary_transport if audio_payload else "url",
            "chunk_size": REPLY_AUDIO_CHUNK_BYTES if binary_transport == "websocket_binary_chunked" else 0,
            "chunk_count": chunk_count,
            "provider": audio.provider,
            "model": audio.model,
            "voice": audio.voice,
            "session_id": session_id,
        }
    )
    if not audio_payload:
        return

    if binary_transport == "websocket_binary_chunked":
        for offset in range(0, len(audio_payload), REPLY_AUDIO_CHUNK_BYTES):
            await websocket.send_bytes(audio_payload[offset : offset + REPLY_AUDIO_CHUNK_BYTES])
    else:
        await websocket.send_bytes(audio_payload)
    await websocket.send_json(
        {
            "type": "tts",
            "state": "audio_done",
            "format": "wav",
            "bytes": len(audio_payload),
            "transport": binary_transport,
            "chunk_count": chunk_count,
            "session_id": session_id,
        }
    )


async def _complete_turn(
    websocket: WebSocket,
    settings: Settings,
    *,
    pending_text: str,
    pending_audio: bytes,
    audio_params: dict[str, Any],
    session_id: str | None,
    user_id: str | None,
    device_id: str | None,
    reply_audio: bool,
    reply_audio_transport: str,
    reset_session: bool,
) -> tuple[str | None, bool]:
    speech_text = pending_text.strip()
    language = "text"

    if not speech_text:
        if not pending_audio:
            await _send_error(websocket, "empty_turn", "No text or WAV audio was received for this turn.")
            return session_id, reset_session
        try:
            if audio_params.get("format") == "pcm_s16le":
                wav_audio = _pcm_s16le_to_wav(
                    pending_audio,
                    int(audio_params.get("sample_rate", 16000)),
                    int(audio_params.get("channels", 1)),
                )
            else:
                wav_audio = pending_audio
            speech = transcribe_wav_bytes(wav_audio, settings)
        except HTTPException as error:
            if error.status_code == 422:
                await websocket.send_json(
                    {
                        "type": "stt",
                        "state": "no_match",
                        "text": "",
                        "language": "",
                        "session_id": session_id or "",
                        "detail": str(error.detail),
                    }
                )
                await websocket.send_json(
                    {
                        "type": "listen",
                        "state": "ready",
                        "session_id": session_id or "",
                        "turn_index": 0,
                    }
                )
                return session_id, reset_session
            await _send_error(websocket, "asr_failed", error.detail)
            return session_id, reset_session
        speech_text = speech.text
        language = speech.language

    await websocket.send_json({"type": "stt", "state": "final", "text": speech_text, "language": language})
    await websocket.send_json({"type": "llm", "state": "start", "session_id": session_id or ""})

    try:
        reply, provider, next_session_id, turn_index = await build_voice_chat_reply(
            speech_text,
            settings,
            session_id=session_id,
            reset_session=reset_session,
            user_id=user_id,
            device_id=device_id,
        )
    except HTTPException as error:
        await _send_error(websocket, "llm_failed", error.detail)
        return session_id, reset_session

    await websocket.send_json(
        {
            "type": "llm",
            "state": "stop",
            "text": reply,
            "provider": provider,
            "session_id": next_session_id,
            "turn_index": turn_index,
        }
    )

    if reply_audio:
        await websocket.send_json({"type": "tts", "state": "start", "session_id": next_session_id})
        streamed = False
        if reply_audio_transport == "websocket_binary_stream":
            streamed = await _send_streaming_reply_audio(websocket, reply, settings, next_session_id)
        if not streamed:
            await _send_file_reply_audio(websocket, reply, settings, next_session_id, reply_audio_transport)
        await websocket.send_json({"type": "tts", "state": "stop", "session_id": next_session_id})

    await websocket.send_json(
        {
            "type": "listen",
            "state": "ready",
            "session_id": next_session_id,
            "turn_index": turn_index,
        }
    )
    return next_session_id, False


async def run_voice_chat_websocket(websocket: WebSocket, settings: Settings) -> None:
    """Run a JSON + binary WAV WebSocket voice-chat session.

    This mirrors the XiaoZhi-style control flow (hello, listen, stt, llm, tts)
    while keeping the current HomeCue audio payload format as WAV until the
    firmware gains Opus streaming.
    """
    await websocket.accept()

    session_id: str | None = None
    user_id: str | None = None
    device_id: str | None = None
    reply_audio = False
    reply_audio_transport = "url"
    reset_session = False
    listening = False
    pending_text = ""
    pending_audio = bytearray()
    audio_params = dict(SUPPORTED_AUDIO_PARAMS)

    while True:
        try:
            message = await websocket.receive()
        except WebSocketDisconnect:
            return

        if message.get("type") == "websocket.disconnect":
            return

        text_frame = message.get("text")
        if text_frame is not None:
            try:
                payload = json.loads(text_frame)
            except json.JSONDecodeError as error:
                await _send_error(websocket, "bad_json", error.msg)
                continue

            if not isinstance(payload, dict):
                await _send_error(websocket, "bad_json", "JSON text frames must contain an object.")
                continue

            msg_type = str(payload.get("type") or "").strip().lower()
            if msg_type == "hello":
                session_id = _session_id_from_message(payload, session_id)
                user_id = _client_label_from_message(payload, "user_id", user_id)
                device_id = _client_label_from_message(payload, "device_id", device_id)
                reply_audio = _truthy(payload.get("reply_audio")) or reply_audio
                reply_audio_transport = _normalize_reply_audio_transport(
                    payload.get("reply_audio_transport"),
                    reply_audio_transport,
                )
                reset_session = _truthy(payload.get("reset_session"))
                audio_params = _normalize_audio_params(payload.get("audio_params"), audio_params)
                await websocket.send_json(
                    {
                        "type": "hello",
                        "transport": "websocket",
                        "protocol": PROTOCOL_NAME,
                        "session_id": session_id,
                        "user_id": user_id or "",
                        "device_id": device_id or "",
                        "audio_params": audio_params,
                        "features": {
                            "text_turn": True,
                            "binary_wav": True,
                            "binary_pcm_s16le": True,
                            "reply_audio_url": True,
                            "reply_audio_binary": True,
                            "reply_audio_chunked": True,
                            "reply_audio_stream": True,
                            "stt_partial": True,
                            "stt_final": True,
                            "opus_stream": False,
                        },
                    }
                )
                continue

            if msg_type == "ping":
                await websocket.send_json({"type": "pong", "session_id": session_id or ""})
                continue

            if msg_type != "listen":
                await _send_error(websocket, "unknown_type", msg_type or "missing")
                continue

            state = str(payload.get("state") or "").strip().lower()
            if state == "start":
                listening = True
                pending_text = ""
                pending_audio.clear()
                session_id = _session_id_from_message(payload, session_id) if payload.get("session_id") else session_id
                user_id = _client_label_from_message(payload, "user_id", user_id)
                device_id = _client_label_from_message(payload, "device_id", device_id)
                reply_audio = _truthy(payload.get("reply_audio")) or reply_audio
                reply_audio_transport = _normalize_reply_audio_transport(
                    payload.get("reply_audio_transport"),
                    reply_audio_transport,
                )
                reset_session = _truthy(payload.get("reset_session")) or reset_session
                audio_params = _normalize_audio_params(payload.get("audio_params"), audio_params)
                await websocket.send_json({"type": "listen", "state": "started", "session_id": session_id or ""})
                continue

            if state in {"partial", "detect"}:
                candidate = _transcript_text_from_message(payload)
                if candidate:
                    await websocket.send_json(
                        {
                            "type": "stt",
                            "state": "partial",
                            "text": candidate,
                            "language": str(payload.get("language") or "partial"),
                            "session_id": session_id or "",
                        }
                    )
                continue

            if state in {"text", "final", "sentence"}:
                candidate = _transcript_text_from_message(payload)
                if candidate:
                    pending_text = candidate
                    if state == "final":
                        await websocket.send_json(
                            {
                                "type": "stt",
                                "state": "final",
                                "text": candidate,
                                "language": str(payload.get("language") or "text"),
                                "session_id": session_id or "",
                            }
                        )
                continue

            if state == "stop":
                listening = False
                session_id, reset_session = await _complete_turn(
                    websocket,
                    settings,
                    pending_text=pending_text,
                    pending_audio=bytes(pending_audio),
                    audio_params=audio_params,
                    session_id=session_id,
                    user_id=user_id,
                    device_id=device_id,
                    reply_audio=reply_audio,
                    reply_audio_transport=reply_audio_transport,
                    reset_session=reset_session,
                )
                pending_text = ""
                pending_audio.clear()
                continue

            await _send_error(websocket, "unknown_listen_state", state or "missing")
            continue

        binary_frame = message.get("bytes")
        if binary_frame is None:
            continue
        if not listening:
            await _send_error(websocket, "audio_outside_listen", "Send listen/start before binary audio.")
            continue
        pending_audio.extend(binary_frame)
