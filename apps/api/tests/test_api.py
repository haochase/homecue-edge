import asyncio
import wave
from io import BytesIO

import httpx
from fastapi import HTTPException
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.config import Settings
from app.context import BASE_CONTEXT
from app.main import app
from app.planner import agent, service
from app import voice_chat as voice_chat_module
from app.schemas import Routine


client = TestClient(app)


FINAL_ROUTINE_JSON = (
    '{"mode": "qwen_agent_reasoning", "summary": "Agent settled the room.",'
    ' "privacy_summary": "Only edge summaries were used.",'
    ' "reasoning": ["Checked context", "Validated actions"],'
    ' "actions": [{"device": "light", "command": "set_scene", "value": "warm"}],'
    ' "suggestions": [{"type": "comfort", "title": "Dim lights", "detail": "Warm scene."}]}'
)


def _tool_call_response(name="get_device_states", args="{}"):
    return {
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        {"id": "call_1", "type": "function", "function": {"name": name, "arguments": args}}
                    ],
                }
            }
        ]
    }


def _final_response(content=FINAL_ROUTINE_JSON):
    return {"choices": [{"message": {"role": "assistant", "content": content}}]}


def _agent_settings():
    return Settings(qwen_api_key="test-key", planner_provider="auto")


def _wav_bytes(samples, sample_rate=16000, channels=1):
    buffer = BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"".join(int(sample).to_bytes(2, "little", signed=True) for sample in samples))
    return buffer.getvalue()


def test_prepare_wav_for_asr_trims_and_limits_peak():
    samples = [0] * 6400
    samples.extend([32000, -32000, 12000, -12000] * 400)
    samples.extend([0] * 6400)

    prepared = voice_chat_module._prepare_wav_for_asr(_wav_bytes(samples))

    with wave.open(BytesIO(prepared), "rb") as wav:
        frames = wav.readframes(wav.getnframes())
        prepared_samples = [
            int.from_bytes(frames[index : index + 2], "little", signed=True)
            for index in range(0, len(frames), 2)
        ]

    assert len(prepared_samples) < len(samples)
    assert max(abs(sample) for sample in prepared_samples) <= 28000


class _FakeEsp32Response:
    def __init__(self, payload, status_code=200):
        self._payload = payload
        self.status_code = status_code

    def raise_for_status(self):
        if self.status_code >= 400:
            request = httpx.Request("GET", "http://esp32.local")
            response = httpx.Response(self.status_code, request=request)
            raise httpx.HTTPStatusError("bad status", request=request, response=response)

    def json(self):
        return self._payload


class _FakeEsp32Client:
    urls: list[str] = []

    def __init__(self, timeout):
        self.timeout = timeout

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return False

    async def get(self, url):
        self.urls.append(url)
        if url.endswith("/health"):
            return _FakeEsp32Response({"status": "ok", "es8311_ready": True})
        return _FakeEsp32Response({"ok": True, "mode": "all", "seconds": 8})


def test_health_defaults_to_mock_without_qwen_key():
    response = client.get("/health")

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ok"
    assert payload["planner_provider"] == "mock"
    assert payload["qwen_configured"] is False
    assert payload["active_provider"] == "mock"


def test_health_reports_active_provider_when_configured(monkeypatch):
    monkeypatch.setattr(
        "app.main.get_settings",
        lambda: Settings(qwen_api_key="test-key", qwen_model="mimo-v2.5-pro", active_provider="mimo"),
    )

    response = client.get("/health")

    assert response.status_code == 200
    payload = response.json()
    assert payload["planner_provider"] == "mimo"
    assert payload["active_provider"] == "mimo"
    assert payload["model"] == "mimo-v2.5-pro"


def test_voice_chat_status_reports_runtime_without_secrets(monkeypatch, tmp_path):
    monkeypatch.setattr(
        "app.main.get_settings",
        lambda: Settings(
            qwen_api_key="test-key",
            qwen_model="mimo-v2.5-pro",
            active_provider="mimo",
            voice_chat_tts_provider="mimo",
            voice_chat_tts_api_key="tts-key",
            voice_chat_tts_model="mimo-v2.5-tts",
            voice_chat_tts_voice="Mia",
            voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"),
        ),
    )

    response = client.get("/voice-chat/status")

    assert response.status_code == 200
    payload = response.json()
    assert payload["provider"] == "mimo"
    assert payload["model"] == "mimo-v2.5-pro"
    assert payload["tts"] == {
        "provider": "mimo",
        "model": "mimo-v2.5-tts",
        "voice": "Mia",
        "configured": True,
    }
    assert payload["memory"]["sqlite_enabled"] is True
    assert payload["asr"]["provider"] == "auto"
    assert payload["asr"]["model"] == "base"
    assert payload["asr"]["language"] == "zh-CN"
    assert payload["asr"]["effective_provider"] == "mimo"
    assert payload["asr"]["mimo_available"] is True
    assert payload["realtime"]["websocket"] is True
    assert payload["realtime"]["pcm_s16le"] is True
    assert payload["realtime"]["stt_partial_events"] is True
    assert payload["realtime"]["audio_partial_asr"] is False
    assert payload["realtime"]["mimo_streaming_tts"] is True
    assert payload["realtime"]["opus_stream"] is False
    assert payload["realtime"]["full_duplex"] is False
    assert "tts-key" not in response.text


def test_voice_api_requires_access_token_when_configured(monkeypatch):
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(voice_chat_access_token="secret-token"))

    unauthenticated = client.get("/voice-chat/status")
    health = client.get("/health")
    bearer = client.get("/voice-chat/status", headers={"Authorization": "Bearer secret-token"})
    header = client.get("/voice-chat/status", headers={"X-HomeCue-Token": "secret-token"})
    query = client.get("/voice-chat/status?access_token=secret-token")

    assert unauthenticated.status_code == 401
    assert unauthenticated.headers["www-authenticate"] == "Bearer"
    assert health.status_code == 200
    assert bearer.status_code == 200
    assert header.status_code == 200
    assert query.status_code == 200


def test_voice_diag_api_requires_access_token_when_configured(monkeypatch):
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(voice_chat_access_token="secret-token"))
    monkeypatch.setattr("app.main.httpx.AsyncClient", _FakeEsp32Client)

    response = client.get("/esp32/diag/health?base_url=http://192.0.2.100")
    authorized = client.get(
        "/esp32/diag/health?base_url=http://192.0.2.100",
        headers={"Authorization": "Bearer secret-token"},
    )

    assert response.status_code == 401
    assert authorized.status_code != 401


def test_voice_reply_audio_url_carries_access_token_when_configured(monkeypatch, tmp_path):
    audio_path = tmp_path / "reply.wav"
    audio_path.write_bytes(b"RIFF0000WAVE")
    settings = Settings(voice_chat_access_token="secret-token")

    monkeypatch.setattr("app.main.get_settings", lambda: settings)
    monkeypatch.setattr(
        "app.main.synthesize_reply_wav",
        lambda text, settings: voice_chat_module.ReplyAudioResult(
            path=audio_path,
            provider="test",
            model="test-model",
            voice="test-voice",
        ),
    )

    response = client.post(
        "/voice-chat",
        json={"text": "hello", "reply_audio": True},
        headers={"Authorization": "Bearer secret-token"},
    )

    assert response.status_code == 200
    assert response.json()["reply_audio"]["url"].endswith("?access_token=secret-token")


def test_voice_chat_tts_returns_reply_audio(monkeypatch, tmp_path):
    audio_path = tmp_path / "wake-ack.wav"
    audio_path.write_bytes(b"RIFF0000WAVE")
    settings = Settings(voice_chat_access_token="secret-token")

    monkeypatch.setattr("app.main.get_settings", lambda: settings)
    monkeypatch.setattr(
        "app.main.synthesize_reply_wav",
        lambda text, settings: voice_chat_module.ReplyAudioResult(
            path=audio_path,
            provider="mimo",
            model="mimo-v2.5-tts",
            voice="Mia",
        ),
    )

    response = client.get(
        "/voice-chat/tts?text=for%20you%20sir%2C%20always",
        headers={"Authorization": "Bearer secret-token"},
    )

    assert response.status_code == 200
    assert response.json() == {
        "text": "for you sir, always",
        "reply_audio": {
            "target": "esp32-speaker",
            "status": "ready",
            "url": "/voice-chat/audio/wake-ack.wav?access_token=secret-token",
            "provider": "mimo",
            "model": "mimo-v2.5-tts",
            "voice": "Mia",
        },
    }


def test_voice_chat_websocket_requires_access_token_when_configured(monkeypatch):
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(voice_chat_access_token="secret-token"))

    try:
        with client.websocket_connect("/voice-chat/ws"):
            raise AssertionError("unauthenticated websocket unexpectedly connected")
    except WebSocketDisconnect as error:
        assert error.code == 1008


def test_voice_chat_websocket_accepts_access_token_query(monkeypatch):
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(voice_chat_access_token="secret-token"))

    with client.websocket_connect("/voice-chat/ws?access_token=secret-token") as websocket:
        websocket.send_json({"type": "hello", "version": 1, "transport": "websocket", "reply_audio": False})
        hello = websocket.receive_json()

    assert hello["type"] == "hello"


def test_esp32_diag_health_proxies_board_json(monkeypatch):
    _FakeEsp32Client.urls = []
    monkeypatch.setattr("app.main.httpx.AsyncClient", _FakeEsp32Client)

    response = client.get("/esp32/diag/health?base_url=http://192.0.2.100")

    assert response.status_code == 200
    payload = response.json()
    assert payload["base_url"] == "http://192.0.2.100"
    assert payload["health"]["status"] == "ok"
    assert _FakeEsp32Client.urls == ["http://192.0.2.100/health"]


def test_esp32_diag_speaker_test_proxies_mode_and_seconds(monkeypatch):
    _FakeEsp32Client.urls = []
    monkeypatch.setattr("app.main.httpx.AsyncClient", _FakeEsp32Client)

    response = client.post(
        "/esp32/diag/speaker-test",
        json={"base_url": "http://192.0.2.100/", "seconds": 8, "mode": "all"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["base_url"] == "http://192.0.2.100"
    assert payload["speaker_test"]["ok"] is True
    assert payload["human_audible_confirmation_required"] is True
    assert _FakeEsp32Client.urls == ["http://192.0.2.100/speaker-test?seconds=8&mode=all"]


def test_esp32_diag_rejects_invalid_base_url():
    response = client.get("/esp32/diag/health?base_url=file:///tmp/device")

    assert response.status_code == 400


def test_esp32_diag_rejects_public_base_url():
    response = client.get("/esp32/diag/health?base_url=https://example.com")

    assert response.status_code == 400


def test_settings_default_voice_chat_memory_db(monkeypatch):
    from app import config as config_module

    monkeypatch.delenv("VOICE_CHAT_MEMORY_DB", raising=False)
    settings = config_module._settings_from_prefix({"MIMO_API_KEY": "test-key"}, "MIMO")

    assert settings.voice_chat_memory_db.endswith("runtime\\voice-chat.sqlite") or settings.voice_chat_memory_db.endswith(
        "runtime/voice-chat.sqlite"
    )


def test_settings_load_voice_chat_access_token_from_env():
    from app import config as config_module

    settings = config_module._settings_from_prefix(
        {"MIMO_API_KEY": "test-key", "VOICE_CHAT_ACCESS_TOKEN": " secret-token "},
        "MIMO",
    )

    assert settings.voice_chat_access_token == "secret-token"


def test_mock_plan_updates_devices():
    client.post("/devices/reset")

    response = client.post(
        "/plan",
        json={"prompt": "I am home and tired", "network_mode": "online"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["routine"]["provider"] == "mock"
    assert payload["routine"]["mode"] == "mock_cloud_reasoning"
    assert all(item["accepted"] for item in payload["execution"])
    assert payload["devices"]["light"]["state"] == "on"
    assert payload["devices"]["projector"]["mode"] == "cinema"


def test_weak_network_keeps_cached_context_mode():
    client.post("/devices/reset")

    response = client.post(
        "/plan",
        json={"prompt": "I am home and tired", "network_mode": "weak"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["routine"]["provider"] == "mock"
    assert payload["routine"]["mode"] == "weak_network_cached_context"
    assert "Weak-network mode" in payload["routine"]["reasoning"][0]


def test_offline_plan_uses_local_fallback():
    client.post("/devices/reset")

    response = client.post(
        "/plan",
        json={"prompt": "I am home and tired", "network_mode": "offline"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["routine"]["provider"] == "local_fallback"
    assert payload["routine"]["mode"] == "offline_fallback"
    assert all(item["accepted"] for item in payload["execution"])
    assert payload["devices"]["reminder"]["state"] == "scheduled"


def test_reset_devices_returns_default_state():
    client.post(
        "/plan",
        json={"prompt": "I am home and tired", "network_mode": "online"},
    )

    response = client.post("/devices/reset")

    assert response.status_code == 200
    payload = response.json()
    assert payload["light"]["state"] == "off"
    assert payload["projector"]["mode"] == "standby"


def test_device_store_rejects_unsafe_action():
    from app.devices import DeviceStore

    store = DeviceStore()
    result = store.apply_action({"device": "ac", "command": "set_temperature", "value": 8})

    assert result.accepted is False
    assert result.reason == "action not allowed by edge policy"
    assert store.all()["ac"]["temperature"] == 24


def test_auto_provider_falls_back_after_qwen_error(monkeypatch):
    async def fail_qwen_plan(prompt, privacy_summary, settings):
        raise RuntimeError("qwen unavailable")

    monkeypatch.setattr(service, "build_qwen_plan", fail_qwen_plan)

    routine = asyncio.run(
        service.build_plan(
            "I am home and tired",
            "online",
            BASE_CONTEXT,
            Settings(qwen_api_key="test-key", planner_provider="auto"),
        )
    )

    assert routine.provider == "mock"
    assert routine.mode == "mock_after_qwen_error"


def test_required_qwen_provider_raises_after_qwen_error(monkeypatch):
    async def fail_qwen_plan(prompt, privacy_summary, settings):
        raise RuntimeError("qwen unavailable")

    monkeypatch.setattr(service, "build_qwen_plan", fail_qwen_plan)

    try:
        asyncio.run(
            service.build_plan(
                "I am home and tired",
                "online",
                BASE_CONTEXT,
                Settings(qwen_api_key="test-key", planner_provider="qwen"),
            )
        )
    except RuntimeError as error:
        assert str(error) == "qwen unavailable"
    else:
        raise AssertionError("Expected required Qwen provider to raise.")


def test_qwen_provider_success_path(monkeypatch):
    async def fake_qwen_plan(prompt, privacy_summary, settings):
        return Routine(
            mode="qwen_cloud_reasoning",
            summary="Qwen planned a routine.",
            privacy_summary="Only local summary was used.",
            reasoning=["Use comfort preferences.", "Keep actions reversible."],
            actions=[{"device": "light", "command": "set_scene", "value": "warm"}],
            suggestions=[{"type": "comfort", "title": "Dim lights", "detail": "Use a warm scene."}],
            source_prompt=prompt,
            provider="qwen",
        )

    monkeypatch.setattr(service, "build_qwen_plan", fake_qwen_plan)

    routine = asyncio.run(
        service.build_plan(
            "I am home and tired",
            "online",
            BASE_CONTEXT,
            Settings(qwen_api_key="test-key", planner_provider="qwen"),
        )
    )

    assert routine.provider == "qwen"
    assert routine.mode == "qwen_cloud_reasoning"
    assert routine.actions[0].device == "light"


def test_agent_mode_runs_tool_loop(monkeypatch):
    responses = [_tool_call_response(), _final_response()]

    async def fake_chat_completion(payload, settings):
        return responses.pop(0)

    monkeypatch.setattr(agent, "_chat_completion", fake_chat_completion)

    routine, trace = asyncio.run(
        service.build_plan_with_trace(
            "I am home and tired", "online", BASE_CONTEXT, _agent_settings(), agent_mode=True
        )
    )

    assert routine.provider == "qwen_agent"
    assert routine.mode == "qwen_agent_reasoning"
    assert any(step["type"] == "tool_call" for step in trace)
    assert any(step["type"] == "final" for step in trace)


def test_agent_trace_records_steps(monkeypatch):
    responses = [
        _tool_call_response(name="get_home_context"),
        _tool_call_response(
            name="propose_actions",
            args='{"actions": [{"device": "light", "command": "set_scene", "value": "warm"}]}',
        ),
        _final_response(),
    ]

    async def fake_chat_completion(payload, settings):
        return responses.pop(0)

    monkeypatch.setattr(agent, "_chat_completion", fake_chat_completion)

    _routine, trace = asyncio.run(
        service.build_plan_with_trace(
            "I am home and tired", "online", BASE_CONTEXT, _agent_settings(), agent_mode=True
        )
    )

    assert len(trace) >= 2
    assert all("type" in step for step in trace)
    assert all("step" in step for step in trace)


def test_mock_agent_mode_returns_deterministic_tool_trace():
    routine, trace = asyncio.run(
        service.build_plan_with_trace(
            "I am home and tired",
            "online",
            BASE_CONTEXT,
            Settings(planner_provider="mock"),
            agent_mode=True,
        )
    )

    tool_steps = [step for step in trace if step["type"] == "tool_call"]

    assert routine.provider == "mock"
    assert routine.mode == "mock_agent_reasoning"
    assert [step["name"] for step in tool_steps] == [
        "get_home_context",
        "get_device_states",
        "propose_actions",
    ]
    assert tool_steps[-1]["result"]["accepted_count"] == len(routine.actions)
    assert tool_steps[-1]["result"]["rejected_count"] == 0
    assert trace[-1]["type"] == "final"


def test_agent_max_steps_falls_back(monkeypatch):
    async def always_tool_call(payload, settings):
        return _tool_call_response()

    monkeypatch.setattr(agent, "_chat_completion", always_tool_call)

    routine, trace = asyncio.run(
        service.build_plan_with_trace(
            "I am home and tired", "online", BASE_CONTEXT, _agent_settings(), agent_mode=True
        )
    )

    assert routine.provider == "mock"
    assert routine.mode == "agent_max_steps_fallback"
    assert any(step["type"] == "max_steps_reached" for step in trace)


def test_propose_actions_validation_is_readonly():
    from app.devices import DEFAULT_DEVICES, DeviceStore
    from app.planner.tools import propose_actions

    store = DeviceStore()
    before = {key: dict(value) for key, value in store.all().items()}

    result = propose_actions(
        [
            {"device": "light", "command": "set_scene", "value": "warm"},
            {"device": "ac", "command": "set_temperature", "value": 8},
        ]
    )

    assert result["accepted_count"] == 1
    assert result["rejected_count"] == 1
    # Neither the live store nor the module defaults were mutated.
    assert store.all() == before
    assert DEFAULT_DEVICES["light"]["state"] == "off"


def test_plan_default_mode_unchanged():
    client.post("/devices/reset")

    response = client.post(
        "/plan",
        json={"prompt": "I am home and tired", "network_mode": "online"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["routine"]["provider"] == "mock"
    assert payload["routine"]["mode"] == "mock_cloud_reasoning"
    assert payload["trace"] == []


def test_plan_without_execute_flag_executes_by_default():
    client.post("/devices/reset")

    response = client.post(
        "/plan",
        json={"prompt": "I am home and tired", "network_mode": "online"},
    )

    assert response.status_code == 200
    payload = response.json()
    # Omitting `execute` must keep the original behaviour: actions are applied.
    assert payload["executed"] is True
    assert all(item["accepted"] for item in payload["execution"])
    assert payload["devices"]["light"]["state"] == "on"
    assert payload["devices"]["projector"]["mode"] == "cinema"


def test_plan_execute_false_proposes_without_changing_devices():
    client.post("/devices/reset")

    response = client.post(
        "/plan",
        json={"prompt": "I am home and tired", "network_mode": "online", "execute": False},
    )

    assert response.status_code == 200
    payload = response.json()
    # Propose-only: nothing executed, device state untouched.
    assert payload["executed"] is False
    assert payload["execution"] == []
    assert payload["devices"]["light"]["state"] == "off"
    assert payload["devices"]["projector"]["mode"] == "standby"
    # But a read-only pre-check is returned for the human-in-the-loop preview.
    assert len(payload["precheck"]) == len(payload["routine"]["actions"])
    assert all("accepted" in item and "reason" in item for item in payload["precheck"])
    assert all(item["accepted"] for item in payload["precheck"])


def test_execute_endpoint_runs_confirmed_actions():
    client.post("/devices/reset")

    response = client.post(
        "/execute",
        json={"actions": [{"device": "light", "command": "set_scene", "value": "warm"}]},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["execution"][0]["accepted"] is True
    assert payload["devices"]["light"]["state"] == "on"
    assert payload["devices"]["light"]["scene"] == "warm"


def test_execute_endpoint_rejects_disallowed_action():
    client.post("/devices/reset")

    response = client.post(
        "/execute",
        json={"actions": [{"device": "ac", "command": "set_temperature", "value": 8}]},
    )

    assert response.status_code == 200
    payload = response.json()
    result = payload["execution"][0]
    assert result["accepted"] is False
    assert result["reason"] == "action not allowed by edge policy"
    # Guard prevented the unsafe change.
    assert payload["devices"]["ac"]["temperature"] == 24


def test_voice_returns_501_when_transcription_disabled():
    original = voice_chat_module.transcribe_wav_with_windows_speech
    voice_chat_module.transcribe_wav_with_windows_speech = lambda path, settings=None: None

    try:
        response = client.post("/voice", content=b"not-a-real-wav")
    finally:
        voice_chat_module.transcribe_wav_with_windows_speech = original

    # faster-whisper is an optional dependency and not installed in CI/tests.
    assert response.status_code == 501
    assert "not enabled" in response.json()["detail"]


def test_voice_can_use_windows_speech_asr(monkeypatch):
    monkeypatch.setattr(
        voice_chat_module,
        "transcribe_wav_with_windows_speech",
        lambda path, settings=None: voice_chat_module.SpeechResult(text="你好小千", language="zh-CN"),
    )

    response = client.post("/voice", content=b"not-a-real-wav")

    assert response.status_code == 200
    assert response.json() == {"text": "你好小千", "language": "zh-CN"}


def test_voice_returns_422_when_asr_hears_no_speech(monkeypatch):
    monkeypatch.setattr(
        voice_chat_module,
        "transcribe_wav_with_windows_speech",
        lambda path, settings=None: voice_chat_module.SpeechResult(text="", language="zh-CN"),
    )

    response = client.post("/voice", content=b"not-a-real-wav")

    assert response.status_code == 422
    assert "did not detect speech" in response.json()["detail"]


def test_voice_respects_disabled_asr_provider(monkeypatch):
    monkeypatch.setattr(
        "app.main.get_settings",
        lambda: Settings(voice_chat_asr_provider="disabled"),
    )

    response = client.post("/voice", content=b"not-a-real-wav")

    assert response.status_code == 501
    assert "disabled" in response.json()["detail"]


def test_voice_can_require_faster_whisper_asr(monkeypatch):
    monkeypatch.setattr(
        voice_chat_module,
        "transcribe_wav_with_faster_whisper",
        lambda path, settings=None: voice_chat_module.SpeechResult(text="whisper text", language="zh"),
    )
    monkeypatch.setattr(
        "app.main.get_settings",
        lambda: Settings(voice_chat_asr_provider="faster_whisper", voice_chat_asr_model="tiny"),
    )

    response = client.post("/voice", content=b"not-a-real-wav")

    assert response.status_code == 200
    assert response.json() == {"text": "whisper text", "language": "zh"}


def test_voice_chat_text_without_model_returns_mock_reply():
    response = client.post("/voice-chat", json={"text": "你好小千", "speak": False})

    assert response.status_code == 200
    payload = response.json()
    assert payload["text"] == "你好小千"
    assert payload["provider"] == "mock"
    assert payload["reply"]
    assert payload["tts"]["status"] == "skipped"


def test_voice_chat_text_uses_configured_model(monkeypatch):
    async def fake_chat_completion(payload, settings):
        assert payload["model"] == "mimo-v2.5-pro"
        assert payload["messages"][-1]["content"] == "你好小千"
        return {"choices": [{"message": {"content": "我在，想聊点什么？"}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(qwen_api_key="test-key", qwen_model="mimo-v2.5-pro"))

    response = client.post("/voice-chat", json={"text": "你好小千", "speak": False})

    assert response.status_code == 200
    payload = response.json()
    assert payload["reply"] == "我在，想聊点什么？"
    assert payload["provider"] == "mimo"


def test_voice_chat_returns_session_metadata():
    voice_chat_module.clear_voice_chat_sessions()

    response = client.post("/voice-chat", json={"text": "你好小千", "speak": False})

    assert response.status_code == 200
    payload = response.json()
    assert payload["session_id"]
    assert payload["turn_index"] == 1


def test_voice_chat_session_carries_previous_turns(monkeypatch):
    voice_chat_module.clear_voice_chat_sessions()
    requests = []
    replies = ["第一轮", "第二轮"]

    async def fake_chat_completion(payload, settings):
        requests.append(payload)
        return {"choices": [{"message": {"content": replies[len(requests) - 1]}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(qwen_api_key="test-key", qwen_model="mimo-v2.5-pro"))

    first = client.post("/voice-chat", json={"text": "第一句", "speak": False})
    session_id = first.json()["session_id"]
    second = client.post("/voice-chat", json={"text": "第二句", "session_id": session_id, "speak": False})

    assert second.status_code == 200
    assert second.json()["session_id"] == session_id
    assert second.json()["turn_index"] == 2
    messages = requests[1]["messages"]
    assert messages[-3:] == [
        {"role": "user", "content": "第一句"},
        {"role": "assistant", "content": "第一轮"},
        {"role": "user", "content": "第二句"},
    ]


def test_voice_chat_memory_db_recovers_context_after_session_cache_clear(monkeypatch, tmp_path):
    voice_chat_module.clear_voice_chat_sessions()
    settings = Settings(
        qwen_api_key="test-key",
        qwen_model="mimo-v2.5-pro",
        voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"),
    )
    requests = []
    replies = ["first reply", "second reply"]

    async def fake_chat_completion(payload, settings):
        requests.append(payload)
        return {"choices": [{"message": {"content": replies[len(requests) - 1]}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr("app.main.get_settings", lambda: settings)

    first = client.post(
        "/voice-chat",
        json={"text": "first user", "user_id": "home-user", "device_id": "esp32-terminal-a"},
    )
    session_id = first.json()["session_id"]
    voice_chat_module.clear_voice_chat_sessions()
    second = client.post(
        "/voice-chat",
        json={
            "text": "second user",
            "session_id": session_id,
            "user_id": "home-user",
            "device_id": "esp32-terminal-b",
        },
    )

    assert second.status_code == 200
    assert second.json()["session_id"] == session_id
    assert second.json()["turn_index"] == 2
    assert requests[1]["messages"][-3:] == [
        {"role": "user", "content": "first user"},
        {"role": "assistant", "content": "first reply"},
        {"role": "user", "content": "second user"},
    ]
    history = voice_chat_module.get_voice_chat_session_turns(settings, session_id)
    assert [turn["user_text"] for turn in history] == ["first user", "second user"]
    assert history[0]["user_id"] == "home-user"
    assert history[0]["device_id"] == "esp32-terminal-a"
    assert history[1]["device_id"] == "esp32-terminal-b"


def test_voice_chat_injects_same_user_long_term_context(monkeypatch, tmp_path):
    voice_chat_module.clear_voice_chat_sessions()
    settings = Settings(
        qwen_api_key="test-key",
        qwen_model="mimo-v2.5-pro",
        voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"),
    )
    requests = []

    async def fake_chat_completion(payload, settings):
        requests.append(payload)
        return {"choices": [{"message": {"content": f"reply {len(requests)}"}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr("app.main.get_settings", lambda: settings)

    first = client.post(
        "/voice-chat",
        json={
            "text": "记住我喜欢暖光，明天提醒我检查鱼缸，我今天有点焦虑。",
            "user_id": "home-user",
            "device_id": "browser-console",
        },
    )
    voice_chat_module.clear_voice_chat_sessions()
    second = client.post(
        "/voice-chat",
        json={"text": "我现在回来了。", "user_id": "home-user", "device_id": "esp32-audio-board"},
    )

    assert first.status_code == 200
    assert second.status_code == 200
    context_messages = [
        item["content"]
        for item in requests[1]["messages"]
        if item["role"] == "system" and "Long-term user context" in item["content"]
    ]
    assert len(context_messages) == 1
    context = context_messages[0]
    assert "Recent memories:" in context
    assert "暖光" in context
    assert "Open tasks:" in context
    assert "检查鱼缸" in context
    assert "Recent mood signals:" in context
    assert "焦虑" in context
    assert requests[1]["messages"][-1] == {"role": "user", "content": "我现在回来了。"}


def test_voice_chat_session_history_endpoints_return_persisted_turns(monkeypatch, tmp_path):
    voice_chat_module.clear_voice_chat_sessions()
    settings = Settings(voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"))
    monkeypatch.setattr("app.main.get_settings", lambda: settings)

    response = client.post(
        "/voice-chat",
        json={"text": "hello memory", "user_id": "web-user", "device_id": "browser-console"},
    )
    session_id = response.json()["session_id"]

    detail = client.get(f"/voice-chat/sessions/{session_id}")
    listing = client.get("/voice-chat/sessions?limit=5")

    assert detail.status_code == 200
    assert detail.json()["session_id"] == session_id
    assert detail.json()["turns"][0]["user_text"] == "hello memory"
    assert detail.json()["turns"][0]["user_id"] == "web-user"
    assert detail.json()["turns"][0]["device_id"] == "browser-console"
    assert listing.status_code == 200
    assert listing.json()["sessions"][0]["session_id"] == session_id
    assert listing.json()["sessions"][0]["turn_count"] == 1


def test_voice_chat_extracts_memory_task_and_mood(monkeypatch, tmp_path):
    voice_chat_module.clear_voice_chat_sessions()
    settings = Settings(voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"))
    monkeypatch.setattr("app.main.get_settings", lambda: settings)

    response = client.post(
        "/voice-chat",
        json={
            "text": "记住我喜欢安静的灯光，明天提醒我检查鱼缸，我今天有点焦虑",
            "user_id": "home-user",
            "device_id": "esp32-kitchen",
        },
    )

    assert response.status_code == 200
    memories = client.get("/voice-chat/memories?user_id=home-user").json()["memories"]
    tasks = client.get("/voice-chat/tasks?user_id=home-user").json()["tasks"]
    moods = client.get("/voice-chat/moods?user_id=home-user").json()["moods"]

    assert memories[0]["memory_type"] == "preference"
    assert "安静的灯光" in memories[0]["content"]
    assert tasks[0]["status"] == "open"
    assert "检查鱼缸" in tasks[0]["title"]
    assert tasks[0]["due_text"] == "明天"
    assert tasks[0]["recurrence"] == ""
    assert tasks[0]["due_at"] is not None
    assert tasks[0]["reminded_at"] is None
    assert moods[0]["mood"] == "焦虑"
    assert moods[0]["valence"] == -1


def test_voice_chat_memory_and_task_lists_are_deduped(monkeypatch, tmp_path):
    voice_chat_module.clear_voice_chat_sessions()
    settings = Settings(voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"))
    monkeypatch.setattr("app.main.get_settings", lambda: settings)
    text = "\u8bb0\u4f4f\u6211\u559c\u6b22\u5b89\u9759\u7684\u706f\u5149\uff0c\u660e\u5929\u63d0\u9192\u6211\u68c0\u67e5\u9c7c\u7f38"

    first = client.post(
        "/voice-chat",
        json={"text": text, "user_id": "home-user", "device_id": "esp32-kitchen"},
    )
    second = client.post(
        "/voice-chat",
        json={"text": text, "user_id": "home-user", "device_id": "browser-console"},
    )

    memories = client.get("/voice-chat/memories?user_id=home-user").json()["memories"]
    tasks = client.get("/voice-chat/tasks?user_id=home-user").json()["tasks"]
    moods = client.get("/voice-chat/moods?user_id=home-user").json()["moods"]

    assert first.status_code == 200
    assert second.status_code == 200
    assert len(memories) == 1
    assert len(tasks) == 1
    assert len(moods) == 1
    assert memories[0]["device_id"] == "browser-console"
    assert tasks[0]["device_id"] == "browser-console"
    assert memories[0]["session_id"] == second.json()["session_id"]
    assert tasks[0]["session_id"] == second.json()["session_id"]


def test_voice_chat_task_endpoints_create_and_update(monkeypatch, tmp_path):
    settings = Settings(voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"))
    monkeypatch.setattr("app.main.get_settings", lambda: settings)

    created = client.post(
        "/voice-chat/tasks",
        json={
            "title": "检查门窗",
            "detail": "离家前确认",
            "due_text": "今晚",
            "user_id": "home-user",
            "device_id": "browser-console",
        },
    )
    task = created.json()["task"]
    updated = client.patch(f"/voice-chat/tasks/{task['task_id']}", json={"status": "done"})
    all_tasks = client.get("/voice-chat/tasks?user_id=home-user&status=all").json()["tasks"]

    assert created.status_code == 200
    assert task["title"] == "检查门窗"
    assert task["due_text"] == "今晚"
    assert task["recurrence"] == ""
    assert updated.status_code == 200
    assert updated.json()["task"]["status"] == "done"
    assert all_tasks[0]["status"] == "done"


def test_voice_chat_due_task_queue_and_mark_reminded(monkeypatch, tmp_path):
    settings = Settings(voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"))
    monkeypatch.setattr("app.main.get_settings", lambda: settings)
    due_at = 1_700_000_000.0

    created = client.post(
        "/voice-chat/tasks",
        json={
            "title": "播放提醒",
            "due_text": "现在",
            "due_at": due_at,
            "user_id": "home-user",
        },
    )
    future = client.post(
        "/voice-chat/tasks",
        json={
            "title": "明天提醒",
            "due_text": "明天",
            "due_at": due_at + 3600,
            "user_id": "home-user",
        },
    )

    due = client.get(f"/voice-chat/tasks/due?user_id=home-user&now={due_at + 10}&mark_reminded=true")
    second_due = client.get(f"/voice-chat/tasks/due?user_id=home-user&now={due_at + 10}")

    assert created.status_code == 200
    assert future.status_code == 200
    assert due.status_code == 200
    assert [task["title"] for task in due.json()["tasks"]] == ["播放提醒"]
    assert due.json()["tasks"][0]["reminded_at"] is not None
    assert second_due.json()["tasks"] == []


def test_voice_chat_daily_task_reschedules_after_reminder(monkeypatch, tmp_path):
    settings = Settings(voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"))
    monkeypatch.setattr("app.main.get_settings", lambda: settings)
    due_at = 1_700_000_000.0

    created = client.post(
        "/voice-chat/tasks",
        json={
            "title": "每天提醒我喝水",
            "due_text": "每天早上",
            "due_at": due_at,
            "user_id": "home-user",
        },
    )

    first_due = client.get(f"/voice-chat/tasks/due?user_id=home-user&now={due_at + 1}&mark_reminded=true")
    after_first = client.get(f"/voice-chat/tasks/due?user_id=home-user&now={due_at + 1}")
    next_day = client.get(f"/voice-chat/tasks/due?user_id=home-user&now={due_at + 24 * 60 * 60 + 1}")
    tasks = client.get("/voice-chat/tasks?user_id=home-user").json()["tasks"]

    assert created.status_code == 200
    assert created.json()["task"]["recurrence"] == "daily"
    assert first_due.status_code == 200
    assert first_due.json()["tasks"][0]["title"] == "每天提醒我喝水"
    assert first_due.json()["tasks"][0]["recurrence"] == "daily"
    assert first_due.json()["tasks"][0]["due_at"] == due_at + 24 * 60 * 60
    assert first_due.json()["tasks"][0]["reminded_at"] == due_at + 1
    assert after_first.json()["tasks"] == []
    assert next_day.json()["tasks"][0]["title"] == "每天提醒我喝水"
    assert tasks[0]["due_at"] == due_at + 24 * 60 * 60
    assert tasks[0]["status"] == "open"


def test_voice_chat_extracts_daily_recurring_task_from_turn(monkeypatch, tmp_path):
    voice_chat_module.clear_voice_chat_sessions()
    settings = Settings(voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"))
    monkeypatch.setattr("app.main.get_settings", lambda: settings)

    response = client.post(
        "/voice-chat",
        json={
            "text": "每天晚上提醒我检查门窗",
            "user_id": "home-user",
            "device_id": "esp32-kitchen",
        },
    )
    tasks = client.get("/voice-chat/tasks?user_id=home-user").json()["tasks"]

    assert response.status_code == 200
    assert tasks[0]["recurrence"] == "daily"
    assert tasks[0]["due_text"] == "每天晚上"
    assert tasks[0]["due_at"] is not None
    assert "检查门窗" in tasks[0]["title"]


def test_voice_chat_due_audio_returns_reply_audio(monkeypatch, tmp_path):
    settings = Settings(voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"))
    wav_path = tmp_path / "reminder.wav"
    wav_path.write_bytes(b"RIFF" + b"\0" * 64)
    monkeypatch.setattr("app.main.get_settings", lambda: settings)
    monkeypatch.setattr(
        "app.main.synthesize_reply_wav",
        lambda text, settings: voice_chat_module.ReplyAudioResult(
            path=wav_path,
            provider="mimo",
            model="mimo-v2.5-tts",
            voice="Mia",
        ),
    )
    due_at = 1_700_000_000.0
    client.post(
        "/voice-chat/tasks",
        json={
            "title": "检查鱼缸",
            "due_text": "现在",
            "due_at": due_at,
            "user_id": "home-user",
        },
    )

    response = client.get(f"/voice-chat/tasks/due-audio?user_id=home-user&now={due_at + 1}")
    second = client.get(f"/voice-chat/tasks/due-audio?user_id=home-user&now={due_at + 1}")

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ready"
    assert payload["task"]["title"] == "检查鱼缸"
    assert payload["text"] == "提醒：检查鱼缸。时间：现在。"
    assert payload["reply_audio"]["status"] == "ready"
    assert payload["reply_audio"]["url"] == "/voice-chat/audio/reminder.wav"
    assert payload["reply_audio"]["provider"] == "mimo"
    assert second.json()["status"] == "empty"


def test_voice_chat_due_text_parser_is_deterministic():
    base = 1_700_000_000.0
    assert voice_chat_module.parse_voice_task_due_at("10分钟后", base) == base + 600
    assert voice_chat_module.parse_voice_task_due_at("2小时以后", base) == base + 7200
    assert voice_chat_module.parse_voice_task_due_at("明天", base) is not None


def test_voice_chat_can_request_pc_tts(monkeypatch):
    monkeypatch.setattr("app.main.speak_on_pc", lambda text: "played")

    response = client.post("/voice-chat", json={"text": "你好小千", "speak": True})

    assert response.status_code == 200
    assert response.json()["tts"]["status"] == "played"


def test_voice_chat_can_return_esp32_reply_audio(monkeypatch, tmp_path):
    wav_path = tmp_path / "reply.wav"
    wav_path.write_bytes(b"RIFF" + b"\0" * 64)
    monkeypatch.setattr("app.main.VOICE_CHAT_AUDIO_DIR", tmp_path)
    monkeypatch.setattr(
        "app.main.synthesize_reply_wav",
        lambda text, settings: voice_chat_module.ReplyAudioResult(
            path=wav_path,
            provider="windows",
            model="System.Speech.Synthesis.SpeechSynthesizer",
            voice="default",
        ),
    )

    response = client.post("/voice-chat", json={"text": "你好小千", "reply_audio": True})

    assert response.status_code == 200
    payload = response.json()
    assert payload["reply_audio"] == {
        "target": "esp32-speaker",
        "status": "ready",
        "url": "/voice-chat/audio/reply.wav",
        "provider": "windows",
        "model": "System.Speech.Synthesis.SpeechSynthesizer",
        "voice": "default",
    }

    audio = client.get(payload["reply_audio"]["url"])
    assert audio.status_code == 200
    assert audio.headers["content-type"].startswith("audio/wav")
    assert audio.content.startswith(b"RIFF")


def test_voice_chat_can_use_dashscope_reply_audio(monkeypatch, tmp_path):
    def fake_post(url, headers, json, timeout):
        assert url == "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        assert headers["Authorization"] == "Bearer tts-key"
        assert json["model"] == "qwen3-tts-flash"
        assert json["input"]["voice"] == "Cherry"
        assert json["input"]["language_type"] == "Chinese"

        class Response:
            def raise_for_status(self):
                return None

            def json(self):
                return {"output": {"audio": {"url": "https://example.test/dashscope.wav"}}}

        return Response()

    def fake_download(url, target):
        assert url == "https://example.test/dashscope.wav"
        target.write_bytes(b"RIFF" + b"\0" * 64)
        return True

    monkeypatch.setattr(voice_chat_module, "VOICE_CHAT_AUDIO_DIR", tmp_path)
    monkeypatch.setattr(voice_chat_module.httpx, "post", fake_post)
    monkeypatch.setattr(voice_chat_module, "_download_wav_from_url", fake_download)

    audio = voice_chat_module.synthesize_reply_wav(
        "你好，我是小千。",
        Settings(qwen_api_key="test-key", voice_chat_tts_provider="dashscope", voice_chat_tts_api_key="tts-key"),
    )

    assert audio is not None
    assert audio.path.exists()
    assert audio.path.read_bytes().startswith(b"RIFF")
    assert audio.provider == "dashscope"
    assert audio.model == "qwen3-tts-flash"
    assert audio.voice == "Cherry"


def test_voice_chat_can_use_mimo_reply_audio(monkeypatch, tmp_path):
    import base64

    wav_bytes = b"RIFF" + b"\0" * 64

    def fake_post(url, headers, json, timeout):
        assert url == "https://mimo-compatible.example.invalid/v1/chat/completions"
        assert headers["Authorization"] == "Bearer mimo-tts-key"
        assert json["model"] == "mimo-v2.5-tts"
        assert json["messages"] == [{"role": "assistant", "content": "hello"}]
        assert json["audio"]["voice"] == "茉莉"
        assert json["audio"]["format"] == "wav"

        class Response:
            def raise_for_status(self):
                return None

            def json(self):
                return {
                    "choices": [
                        {
                            "message": {
                                "audio": {
                                    "data": base64.b64encode(wav_bytes).decode("ascii"),
                                }
                            }
                        }
                    ]
                }

        return Response()

    monkeypatch.setattr(voice_chat_module, "VOICE_CHAT_AUDIO_DIR", tmp_path)
    monkeypatch.setattr(voice_chat_module.httpx, "post", fake_post)

    audio = voice_chat_module.synthesize_reply_wav(
        "hello",
        Settings(
            voice_chat_tts_provider="mimo",
            voice_chat_tts_api_key="mimo-tts-key",
            voice_chat_tts_api_base="https://mimo-compatible.example.invalid/v1",
            voice_chat_tts_model="mimo-v2.5-tts",
            voice_chat_tts_voice="茉莉",
        ),
    )

    assert audio is not None
    assert audio.path.exists()
    assert audio.path.read_bytes() == wav_bytes
    assert audio.provider == "mimo"
    assert audio.model == "mimo-v2.5-tts"
    assert audio.voice == "茉莉"


def test_voice_chat_can_use_mimo_asr(monkeypatch):
    import base64

    def fake_post(url, headers, json, timeout):
        assert url == "https://mimo-compatible.example.invalid/v1/chat/completions"
        assert headers["Authorization"] == "Bearer mimo-key"
        assert json["model"] == "mimo-v2.5-asr"
        content = json["messages"][0]["content"]
        assert len(content) == 1
        audio = content[0]["input_audio"]
        assert content[0]["type"] == "input_audio"
        assert audio["format"] == "wav"
        assert audio["data"].startswith("data:audio/wav;base64,")
        assert base64.b64decode(audio["data"].split(",", 1)[1]) == b"RIFF" + b"\0" * 64

        class Response:
            def raise_for_status(self):
                return None

            def json(self):
                return {"choices": [{"message": {"content": "ni hao"}}]}

        return Response()

    monkeypatch.setattr(voice_chat_module.httpx, "post", fake_post)

    result = voice_chat_module.transcribe_wav_with_mimo(
        b"RIFF" + b"\0" * 64,
        Settings(
            qwen_api_key="mimo-key",
            qwen_api_base="https://mimo-compatible.example.invalid/v1",
            voice_chat_asr_model="mimo-v2.5-asr",
        ),
    )

    assert result == voice_chat_module.SpeechResult(text="ni hao", language="zh-CN")


def test_voice_chat_auto_asr_prefers_mimo(monkeypatch):
    calls = []

    def fake_mimo(audio, settings=None):
        calls.append((audio, settings.voice_chat_asr_provider if settings else ""))
        return voice_chat_module.SpeechResult(text="mimo heard", language="zh-CN")

    monkeypatch.setattr(voice_chat_module, "transcribe_wav_with_mimo", fake_mimo)
    monkeypatch.setattr(
        voice_chat_module,
        "transcribe_wav_with_windows_speech",
        lambda path, settings=None: voice_chat_module.SpeechResult(text="windows heard", language="zh-CN"),
    )

    result = voice_chat_module.transcribe_wav_bytes(
        b"RIFF" + b"\0" * 64,
        Settings(qwen_api_key="mimo-key", voice_chat_asr_provider="auto"),
    )

    assert result == voice_chat_module.SpeechResult(text="mimo heard", language="zh-CN")
    assert calls and calls[0][1] == "auto"


def test_voice_chat_wav_requires_asr_when_no_text():
    original = voice_chat_module.transcribe_wav_with_windows_speech
    voice_chat_module.transcribe_wav_with_windows_speech = lambda path, settings=None: None

    try:
        response = client.post("/voice-chat", content=b"not-a-real-wav")
    finally:
        voice_chat_module.transcribe_wav_with_windows_speech = original

    assert response.status_code == 501
    assert "not enabled" in response.json()["detail"]


def test_voice_chat_websocket_text_session(monkeypatch):
    voice_chat_module.clear_voice_chat_sessions()
    requests = []
    replies = ["first reply", "second reply"]

    async def fake_chat_completion(payload, settings):
        requests.append(payload)
        return {"choices": [{"message": {"content": replies[len(requests) - 1]}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(qwen_api_key="test-key", qwen_model="mimo-v2.5-pro"))

    with client.websocket_connect("/voice-chat/ws") as websocket:
        websocket.send_json({"type": "hello", "version": 1, "transport": "websocket", "reply_audio": False})
        hello = websocket.receive_json()
        session_id = hello["session_id"]

        assert hello["type"] == "hello"
        assert hello["transport"] == "websocket"
        assert hello["features"]["binary_wav"] is True
        assert hello["features"]["stt_partial"] is True
        assert hello["features"]["stt_final"] is True
        assert hello["features"]["opus_stream"] is False
        assert session_id

        websocket.send_json({"type": "listen", "state": "start"})
        assert websocket.receive_json() == {"type": "listen", "state": "started", "session_id": session_id}
        websocket.send_json({"type": "listen", "state": "text", "text": "first user"})
        websocket.send_json({"type": "listen", "state": "stop"})

        assert websocket.receive_json() == {"type": "stt", "state": "final", "text": "first user", "language": "text"}
        assert websocket.receive_json() == {"type": "llm", "state": "start", "session_id": session_id}
        first_llm = websocket.receive_json()
        first_ready = websocket.receive_json()

        assert first_llm["type"] == "llm"
        assert first_llm["state"] == "stop"
        assert first_llm["text"] == "first reply"
        assert first_llm["provider"] == "mimo"
        assert first_llm["session_id"] == session_id
        assert first_llm["turn_index"] == 1
        assert first_ready == {"type": "listen", "state": "ready", "session_id": session_id, "turn_index": 1}

        websocket.send_json({"type": "listen", "state": "start"})
        assert websocket.receive_json() == {"type": "listen", "state": "started", "session_id": session_id}
        websocket.send_json({"type": "listen", "state": "text", "text": "second user"})
        websocket.send_json({"type": "listen", "state": "stop"})

        assert websocket.receive_json() == {"type": "stt", "state": "final", "text": "second user", "language": "text"}
        assert websocket.receive_json() == {"type": "llm", "state": "start", "session_id": session_id}
        second_llm = websocket.receive_json()
        second_ready = websocket.receive_json()

        assert second_llm["session_id"] == session_id
        assert second_llm["turn_index"] == 2
        assert second_llm["text"] == "second reply"
        assert second_ready == {"type": "listen", "state": "ready", "session_id": session_id, "turn_index": 2}

    assert requests[1]["messages"][-3:] == [
        {"role": "user", "content": "first user"},
        {"role": "assistant", "content": "first reply"},
        {"role": "user", "content": "second user"},
    ]


def test_voice_chat_websocket_accepts_partial_and_final_transcripts(monkeypatch):
    voice_chat_module.clear_voice_chat_sessions()

    async def fake_chat_completion(payload, settings):
        return {"choices": [{"message": {"content": "partial flow reply"}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(qwen_api_key="test-key", qwen_model="mimo-v2.5-pro"))

    with client.websocket_connect("/voice-chat/ws") as websocket:
        websocket.send_json({"type": "hello", "version": 1, "transport": "websocket", "reply_audio": False})
        hello = websocket.receive_json()

        websocket.send_json({"type": "listen", "state": "start"})
        assert websocket.receive_json()["state"] == "started"
        websocket.send_json({"type": "listen", "state": "partial", "text": "hello"})
        partial = websocket.receive_json()
        websocket.send_json({"type": "listen", "state": "final", "text": "hello xiaoqian"})
        final_ack = websocket.receive_json()
        websocket.send_json({"type": "listen", "state": "stop"})

        final = websocket.receive_json()
        llm_start = websocket.receive_json()
        llm_stop = websocket.receive_json()
        ready = websocket.receive_json()

    assert hello["features"]["stt_partial"] is True
    assert partial == {
        "type": "stt",
        "state": "partial",
        "text": "hello",
        "language": "partial",
        "session_id": hello["session_id"],
    }
    assert final_ack == {
        "type": "stt",
        "state": "final",
        "text": "hello xiaoqian",
        "language": "text",
        "session_id": hello["session_id"],
    }
    assert final == {"type": "stt", "state": "final", "text": "hello xiaoqian", "language": "text"}
    assert llm_start["state"] == "start"
    assert llm_stop["text"] == "partial flow reply"
    assert ready["state"] == "ready"


def test_voice_chat_websocket_persists_device_identity(monkeypatch, tmp_path):
    voice_chat_module.clear_voice_chat_sessions()
    settings = Settings(
        qwen_api_key="test-key",
        qwen_model="mimo-v2.5-pro",
        voice_chat_memory_db=str(tmp_path / "voice-chat.sqlite"),
    )

    async def fake_chat_completion(payload, settings):
        return {"choices": [{"message": {"content": "stored reply"}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr("app.main.get_settings", lambda: settings)

    with client.websocket_connect("/voice-chat/ws") as websocket:
        websocket.send_json(
            {
                "type": "hello",
                "version": 1,
                "transport": "websocket",
                "user_id": "home-user",
                "device_id": "esp32-board",
            }
        )
        hello = websocket.receive_json()
        websocket.send_json({"type": "listen", "state": "start"})
        websocket.receive_json()
        websocket.send_json({"type": "listen", "state": "text", "text": "remember this"})
        websocket.send_json({"type": "listen", "state": "stop"})
        websocket.receive_json()
        websocket.receive_json()
        websocket.receive_json()
        ready = websocket.receive_json()

    assert hello["user_id"] == "home-user"
    assert hello["device_id"] == "esp32-board"
    history = voice_chat_module.get_voice_chat_session_turns(settings, ready["session_id"])
    assert history[0]["user_text"] == "remember this"
    assert history[0]["assistant_text"] == "stored reply"
    assert history[0]["user_id"] == "home-user"
    assert history[0]["device_id"] == "esp32-board"


def test_voice_chat_websocket_accepts_binary_wav(monkeypatch):
    voice_chat_module.clear_voice_chat_sessions()
    settings = Settings(
        qwen_api_key="test-key",
        qwen_model="mimo-v2.5-pro",
        voice_chat_asr_provider="windows",
    )
    captured = {}

    def fake_transcribe(audio, settings=None):
        captured["asr_provider"] = settings.voice_chat_asr_provider if settings else ""
        return voice_chat_module.SpeechResult(text=f"{len(audio)} bytes heard", language="test")

    monkeypatch.setattr(
        "app.voice_chat_ws.transcribe_wav_bytes",
        fake_transcribe,
    )

    async def fake_chat_completion(payload, settings):
        return {"choices": [{"message": {"content": "binary reply"}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr("app.main.get_settings", lambda: settings)

    with client.websocket_connect("/voice-chat/ws") as websocket:
        websocket.send_json({"type": "hello", "transport": "websocket"})
        session_id = websocket.receive_json()["session_id"]
        websocket.send_json({"type": "listen", "state": "start"})
        assert websocket.receive_json()["state"] == "started"
        websocket.send_bytes(b"RIFF" + b"\0" * 12)
        websocket.send_json({"type": "listen", "state": "stop"})

        assert websocket.receive_json() == {"type": "stt", "state": "final", "text": "16 bytes heard", "language": "test"}
        assert websocket.receive_json() == {"type": "llm", "state": "start", "session_id": session_id}
        llm = websocket.receive_json()
        ready = websocket.receive_json()

    assert llm["text"] == "binary reply"
    assert ready["turn_index"] == 1
    assert captured["asr_provider"] == "windows"


def test_voice_chat_websocket_accepts_binary_pcm(monkeypatch):
    voice_chat_module.clear_voice_chat_sessions()
    captured_audio = {}

    def fake_transcribe(audio, settings=None):
        captured_audio["bytes"] = audio
        return voice_chat_module.SpeechResult(text="pcm heard", language="test")

    monkeypatch.setattr("app.voice_chat_ws.transcribe_wav_bytes", fake_transcribe)

    async def fake_chat_completion(payload, settings):
        return {"choices": [{"message": {"content": "pcm reply"}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(qwen_api_key="test-key", qwen_model="mimo-v2.5-pro"))

    with client.websocket_connect("/voice-chat/ws") as websocket:
        websocket.send_json(
            {
                "type": "hello",
                "transport": "websocket",
                "audio_params": {"format": "pcm_s16le", "sample_rate": 16000, "channels": 1},
            }
        )
        hello = websocket.receive_json()
        assert hello["features"]["binary_pcm_s16le"] is True
        assert hello["audio_params"]["format"] == "pcm_s16le"

        websocket.send_json({"type": "listen", "state": "start"})
        assert websocket.receive_json()["state"] == "started"
        websocket.send_bytes(b"\0\0\1\0" * 800)
        websocket.send_json({"type": "listen", "state": "stop"})

        assert websocket.receive_json() == {"type": "stt", "state": "final", "text": "pcm heard", "language": "test"}
        assert websocket.receive_json()["state"] == "start"
        llm = websocket.receive_json()
        ready = websocket.receive_json()

    assert captured_audio["bytes"].startswith(b"RIFF")
    assert llm["text"] == "pcm reply"
    assert ready["turn_index"] == 1


def test_voice_chat_websocket_defaults_to_wav_mono():
    with client.websocket_connect("/voice-chat/ws") as websocket:
        websocket.send_json({"type": "hello", "transport": "websocket"})
        hello = websocket.receive_json()

    assert hello["audio_params"]["format"] == "wav"
    assert hello["audio_params"]["channels"] == 1


def test_voice_chat_websocket_keeps_session_ready_when_asr_no_match(monkeypatch):
    voice_chat_module.clear_voice_chat_sessions()

    def fake_transcribe(audio, settings=None):
        raise HTTPException(status_code=422, detail="Voice transcription did not detect speech.")

    monkeypatch.setattr("app.voice_chat_ws.transcribe_wav_bytes", fake_transcribe)
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(qwen_api_key="test-key", qwen_model="mimo-v2.5-pro"))

    with client.websocket_connect("/voice-chat/ws") as websocket:
        websocket.send_json(
            {
                "type": "hello",
                "transport": "websocket",
                "audio_params": {"format": "pcm_s16le", "sample_rate": 16000, "channels": 1},
            }
        )
        hello = websocket.receive_json()
        websocket.send_json({"type": "listen", "state": "start"})
        assert websocket.receive_json()["state"] == "started"
        websocket.send_bytes(b"\0\0" * 800)
        websocket.send_json({"type": "listen", "state": "stop"})

        no_match = websocket.receive_json()
        ready = websocket.receive_json()
        websocket.send_json({"type": "ping"})
        pong = websocket.receive_json()

    assert no_match["type"] == "stt"
    assert no_match["state"] == "no_match"
    assert no_match["session_id"] == hello["session_id"]
    assert ready == {"type": "listen", "state": "ready", "session_id": hello["session_id"], "turn_index": 0}
    assert pong == {"type": "pong", "session_id": hello["session_id"]}


def test_voice_chat_websocket_can_return_binary_reply_audio(monkeypatch, tmp_path):
    voice_chat_module.clear_voice_chat_sessions()
    wav_path = tmp_path / "reply.wav"
    wav_path.write_bytes(b"RIFF" + b"\0" * 64)

    async def fake_chat_completion(payload, settings):
        return {"choices": [{"message": {"content": "audio reply"}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr(
        "app.voice_chat_ws.synthesize_reply_wav",
        lambda text, settings: voice_chat_module.ReplyAudioResult(
            path=wav_path,
            provider="windows",
            model="System.Speech.Synthesis.SpeechSynthesizer",
            voice="default",
        ),
    )
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(qwen_api_key="test-key", qwen_model="mimo-v2.5-pro"))

    with client.websocket_connect("/voice-chat/ws") as websocket:
        websocket.send_json(
            {
                "type": "hello",
                "transport": "websocket",
                "reply_audio": True,
                "reply_audio_transport": "websocket_binary",
            }
        )
        hello = websocket.receive_json()
        assert hello["features"]["reply_audio_binary"] is True

        websocket.send_json({"type": "listen", "state": "start"})
        assert websocket.receive_json()["state"] == "started"
        websocket.send_json({"type": "listen", "state": "text", "text": "say hi"})
        websocket.send_json({"type": "listen", "state": "stop"})

        assert websocket.receive_json()["type"] == "stt"
        assert websocket.receive_json()["state"] == "start"
        assert websocket.receive_json()["state"] == "stop"
        assert websocket.receive_json() == {"type": "tts", "state": "start", "session_id": hello["session_id"]}
        audio_event = websocket.receive_json()
        audio_bytes = websocket.receive_bytes()
        done_event = websocket.receive_json()
        stop_event = websocket.receive_json()
        ready = websocket.receive_json()

    assert audio_event["type"] == "tts"
    assert audio_event["state"] == "audio"
    assert audio_event["transport"] == "websocket_binary"
    assert audio_event["url"] == ""
    assert audio_event["provider"] == "windows"
    assert audio_bytes.startswith(b"RIFF")
    assert done_event["state"] == "audio_done"
    assert done_event["transport"] == "websocket_binary"
    assert stop_event["state"] == "stop"
    assert ready["state"] == "ready"


def test_voice_chat_websocket_can_chunk_binary_reply_audio(monkeypatch, tmp_path):
    voice_chat_module.clear_voice_chat_sessions()
    wav_path = tmp_path / "reply.wav"
    wav_bytes = b"RIFF" + (b"\1" * (40 * 1024))
    wav_path.write_bytes(wav_bytes)

    async def fake_chat_completion(payload, settings):
        return {"choices": [{"message": {"content": "chunked audio reply"}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr(
        "app.voice_chat_ws.synthesize_reply_wav",
        lambda text, settings: voice_chat_module.ReplyAudioResult(
            path=wav_path,
            provider="mimo",
            model="mimo-v2.5-tts",
            voice="Mia",
        ),
    )
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(qwen_api_key="test-key", qwen_model="mimo-v2.5-pro"))

    with client.websocket_connect("/voice-chat/ws") as websocket:
        websocket.send_json(
            {
                "type": "hello",
                "transport": "websocket",
                "reply_audio": True,
                "reply_audio_transport": "websocket_binary_chunked",
            }
        )
        hello = websocket.receive_json()
        assert hello["features"]["reply_audio_chunked"] is True

        websocket.send_json({"type": "listen", "state": "start"})
        assert websocket.receive_json()["state"] == "started"
        websocket.send_json({"type": "listen", "state": "text", "text": "say hi"})
        websocket.send_json({"type": "listen", "state": "stop"})

        assert websocket.receive_json()["type"] == "stt"
        assert websocket.receive_json()["state"] == "start"
        assert websocket.receive_json()["state"] == "stop"
        assert websocket.receive_json() == {"type": "tts", "state": "start", "session_id": hello["session_id"]}
        audio_event = websocket.receive_json()
        chunks = [websocket.receive_bytes() for _ in range(audio_event["chunk_count"])]
        done_event = websocket.receive_json()
        stop_event = websocket.receive_json()
        ready = websocket.receive_json()

    assert audio_event["transport"] == "websocket_binary_chunked"
    assert audio_event["chunk_size"] == 16 * 1024
    assert audio_event["chunk_count"] == 3
    assert audio_event["bytes"] == len(wav_bytes)
    assert b"".join(chunks) == wav_bytes
    assert done_event["state"] == "audio_done"
    assert done_event["transport"] == "websocket_binary_chunked"
    assert done_event["chunk_count"] == 3
    assert stop_event["state"] == "stop"
    assert ready["state"] == "ready"


def test_mimo_tts_sse_audio_chunks_are_decoded():
    import base64
    import json

    first = b"RIFF" + b"\0" * 64
    second = b"RIFF" + b"\1" * 64
    event = json.dumps(
        {
            "choices": [
                {"delta": {"audio": {"data": base64.b64encode(first).decode("ascii")}}},
                {"delta": {"audio": {"data": base64.b64encode(second).decode("ascii")}}},
            ]
        }
    )

    assert list(voice_chat_module._mimo_tts_audio_chunks_from_sse_data(event)) == [first, second]
    assert list(voice_chat_module._mimo_tts_audio_chunks_from_sse_data("[DONE]")) == []


def test_voice_chat_websocket_can_stream_mimo_reply_audio(monkeypatch):
    voice_chat_module.clear_voice_chat_sessions()
    wav_segments = [b"RIFF" + b"\1" * 64, b"RIFF" + b"\2" * 64]

    async def fake_chat_completion(payload, settings):
        return {"choices": [{"message": {"content": "streamed audio reply"}}]}

    monkeypatch.setattr(voice_chat_module, "_chat_completion", fake_chat_completion)
    monkeypatch.setattr(
        "app.voice_chat_ws.stream_reply_wav_segments",
        lambda text, settings: voice_chat_module.ReplyAudioStreamResult(
            chunks=iter(wav_segments),
            provider="mimo",
            model="mimo-v2.5-tts",
            voice="Mia",
        ),
    )
    monkeypatch.setattr("app.main.get_settings", lambda: Settings(qwen_api_key="test-key", qwen_model="mimo-v2.5-pro"))

    with client.websocket_connect("/voice-chat/ws") as websocket:
        websocket.send_json(
            {
                "type": "hello",
                "transport": "websocket",
                "reply_audio": True,
                "reply_audio_transport": "websocket_binary_stream",
            }
        )
        hello = websocket.receive_json()
        assert hello["features"]["reply_audio_stream"] is True

        websocket.send_json({"type": "listen", "state": "start"})
        assert websocket.receive_json()["state"] == "started"
        websocket.send_json({"type": "listen", "state": "text", "text": "say hi"})
        websocket.send_json({"type": "listen", "state": "stop"})

        assert websocket.receive_json()["type"] == "stt"
        assert websocket.receive_json()["state"] == "start"
        assert websocket.receive_json()["state"] == "stop"
        assert websocket.receive_json() == {"type": "tts", "state": "start", "session_id": hello["session_id"]}
        audio_event = websocket.receive_json()
        first_chunk = websocket.receive_bytes()
        second_chunk = websocket.receive_bytes()
        done_event = websocket.receive_json()
        stop_event = websocket.receive_json()
        ready = websocket.receive_json()

    assert audio_event["transport"] == "websocket_binary_stream"
    assert audio_event["bytes"] == 0
    assert audio_event["chunk_count"] == 0
    assert audio_event["provider"] == "mimo"
    assert audio_event["model"] == "mimo-v2.5-tts"
    assert audio_event["voice"] == "Mia"
    assert first_chunk == wav_segments[0]
    assert second_chunk == wav_segments[1]
    assert done_event["state"] == "audio_done"
    assert done_event["transport"] == "websocket_binary_stream"
    assert done_event["bytes"] == sum(len(chunk) for chunk in wav_segments)
    assert done_event["chunk_count"] == 2
    assert stop_event["state"] == "stop"
    assert ready["state"] == "ready"
