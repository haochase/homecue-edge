import asyncio

from fastapi.testclient import TestClient

from app.config import Settings
from app.context import BASE_CONTEXT
from app.main import app
from app.planner import agent, service
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


def test_health_defaults_to_mock_without_qwen_key():
    response = client.get("/health")

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ok"
    assert payload["planner_provider"] == "mock"
    assert payload["qwen_configured"] is False


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
    response = client.post("/voice", content=b"not-a-real-wav")

    # faster-whisper is an optional dependency and not installed in CI/tests.
    assert response.status_code == 501
    assert "not enabled" in response.json()["detail"]
