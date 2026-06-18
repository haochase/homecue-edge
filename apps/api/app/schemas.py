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
    # Optional caller label for cross-device sync. Older ESP32 firmware can omit
    # it and still use the same /execute contract.
    source: str = "external"


class VisionSceneRequest(BaseModel):
    room: str = "living room"
    text_hint: str = ""
    camera: Literal["phone", "esp32-cam", "desktop", "mock"] = "mock"
    image_base64: str = ""


class VisionSceneResponse(BaseModel):
    provider: str
    scene: str
    confidence: float
    observations: list[str] = Field(default_factory=list)
    privacy_summary: dict = Field(default_factory=dict)
    suggested_prompt: str
    model_route: str


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
