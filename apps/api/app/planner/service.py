from app.config import Settings
from app.context import build_privacy_summary
from app.planner.agent import build_agent_plan
from app.planner.mock import build_fallback_plan, build_mock_plan
from app.planner.qwen import build_qwen_plan
from app.schemas import Routine


async def build_plan_with_trace(
    prompt: str,
    network_mode: str,
    context: dict,
    settings: Settings,
    agent_mode: bool = False,
) -> tuple[Routine, list[dict]]:
    if network_mode == "offline":
        return build_fallback_plan(prompt), []

    provider = settings.planner_provider
    can_use_qwen = bool(settings.qwen_api_key) and provider in {"auto", "qwen"}

    trace: list[dict] = []

    if agent_mode and can_use_qwen:
        try:
            routine, trace = await build_agent_plan(prompt, settings)
        except Exception:
            if provider == "qwen":
                raise
            routine = build_mock_plan(prompt)
            routine.mode = "mock_after_agent_error"
            trace = [
                {
                    "step": 0,
                    "type": "error",
                    "content": "Agent planning failed; falling back to local mock plan.",
                }
            ]
    elif can_use_qwen:
        try:
            routine = await build_qwen_plan(prompt, build_privacy_summary(context), settings)
        except Exception:
            if provider == "qwen":
                raise
            routine = build_mock_plan(prompt)
            routine.mode = "mock_after_qwen_error"
    else:
        routine = build_mock_plan(prompt)

    if network_mode == "weak":
        routine.mode = "weak_network_cached_context"
        routine.reasoning.insert(0, "Weak-network mode uses cached local context and compact cloud reasoning.")

    return routine, trace


async def build_plan(prompt: str, network_mode: str, context: dict, settings: Settings) -> Routine:
    """Backward-compatible entry point returning just the routine (default, non-agent flow)."""
    routine, _trace = await build_plan_with_trace(prompt, network_mode, context, settings, agent_mode=False)
    return routine
