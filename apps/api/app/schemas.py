from typing import Literal

from pydantic import BaseModel, Field


class PlanRequest(BaseModel):
    prompt: str
    network_mode: Literal["online", "weak", "offline"] = "online"
    agent_mode: bool = False
    # When False the gateway only proposes the routine (with a read-only
    # pre-check) and does NOT mutate device state. Defaults to True so the
    # existing web console behaviour is unchanged.
    execute: bool = True


class DeviceAction(BaseModel):
    device: str
    command: str
    value: str | int | float | bool


class ExecuteRequest(BaseModel):
    # The human-in-the-loop confirmed subset of actions to actually run.
    actions: list[DeviceAction] = Field(default_factory=list)


class VoiceChatRequest(BaseModel):
    # Text mode lets scripts and tests exercise MiMo/TTS before ESP32 WAV upload
    # is wired. WAV upload uses the same /voice-chat endpoint with raw bytes.
    text: str = ""
    speak: bool = False
    reply_audio: bool = False
    session_id: str | None = None
    reset_session: bool = False
    user_id: str | None = None
    device_id: str | None = None


class VoiceChatTaskRequest(BaseModel):
    title: str
    detail: str = ""
    due_text: str = ""
    due_at: float | None = None
    recurrence: str | None = None
    user_id: str | None = None
    device_id: str | None = None


class VoiceChatTaskUpdateRequest(BaseModel):
    title: str | None = None
    detail: str | None = None
    due_text: str | None = None
    due_at: float | None = None
    recurrence: str | None = None
    status: Literal["open", "done", "cancelled"] | None = None
    reminded: bool | None = None


class Esp32SpeakerTestRequest(BaseModel):
    base_url: str
    seconds: int = Field(default=8, ge=1, le=10)
    mode: Literal["all", "both", "left", "right", "sweep"] = "all"


class Suggestion(BaseModel):
    type: str
    title: str
    detail: str


class Routine(BaseModel):
    mode: str
    summary: str
    privacy_summary: str
    reasoning: list[str] = Field(default_factory=list)
    actions: list[DeviceAction] = Field(default_factory=list)
    suggestions: list[Suggestion] = Field(default_factory=list)
    source_prompt: str
    provider: str = "mock"
