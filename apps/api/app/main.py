from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware

from app.config import get_settings
from app.context import BASE_CONTEXT
from app.devices import DeviceStore
from app.planner.service import build_plan_with_trace
from app.planner.tools import validate_action
from app.schemas import ExecuteRequest, PlanRequest


app = FastAPI(title="HomeCue Edge API", version="0.1.0")
device_store = DeviceStore()

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"^http://(localhost|127\.0\.0\.1):\d+$",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health() -> dict:
    settings = get_settings()
    provider = settings.planner_provider
    if provider == "auto" and settings.qwen_api_key:
        provider = "qwen"
    elif provider == "auto":
        provider = "mock"

    return {
        "status": "ok",
        "service": "homecue-edge-api",
        "planner_provider": provider,
        "qwen_configured": bool(settings.qwen_api_key),
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
    try:
        from faster_whisper import WhisperModel  # type: ignore  # noqa: PLC0415
    except ImportError as exc:
        raise HTTPException(
            status_code=501,
            detail=(
                "Voice transcription is not enabled. Install the optional "
                "'faster-whisper' dependency to enable POST /voice."
            ),
        ) from exc

    audio_bytes = await request.body()
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Empty audio body. POST raw WAV bytes.")

    import os
    import tempfile

    tmp_path = ""
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp.write(audio_bytes)
            tmp_path = tmp.name

        model = WhisperModel("base", device="cpu", compute_type="int8")
        segments, info = model.transcribe(tmp_path)
        text = " ".join(segment.text for segment in segments).strip()
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)

    return {"text": text, "language": getattr(info, "language", "unknown")}


@app.post("/devices/reset")
def reset_devices() -> dict:
    return device_store.reset()
