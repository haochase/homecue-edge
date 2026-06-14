"""Multi-step, tool-calling agent planner.

Unlike the single-turn planner, this loop lets the model actively call tools
(`get_home_context`, `get_device_states`, `propose_actions`) over several rounds
before committing to a final routine. Every round is recorded into a `trace` so
the decision process is explainable and auditable.
"""

import json

from app.config import Settings
from app.planner.mock import build_mock_plan
from app.planner.qwen import _chat_completion
from app.planner.tools import TOOLS, dispatch_tool
from app.schemas import Routine


MAX_STEPS = 5

AGENT_SYSTEM_PROMPT = """
You are HomeCue Edge, a privacy-aware home EdgeAgent planner running in a controlled tool runtime.

Work in steps. You may call these tools:
- get_home_context(): privacy-safe home/user/schedule summary.
- get_device_states(): current device states you can act on.
- propose_actions(actions): pre-validate candidate actions against the edge safety policy (read-only).

Recommended flow: inspect context and device states, draft actions, pre-validate them with
propose_actions, then output the FINAL plan as a single strict JSON object (no tool call, no prose,
no markdown fences) with this exact shape:
{
  "mode": "qwen_agent_reasoning",
  "summary": "string",
  "privacy_summary": "string",
  "reasoning": ["string"],
  "actions": [
    {"device": "light|ac|projector|speaker|reminder", "command": "string", "value": "string or number"}
  ],
  "suggestions": [
    {"type": "meal|movie|comfort|reminder", "title": "string", "detail": "string"}
  ]
}
Allowed actions:
- light set_scene: warm, bright, night
- ac set_temperature: integer 18-30
- projector set_mode: cinema, standby
- speaker play: soft ambient, focus, none
- reminder set: short reminder message
Only include actions that passed propose_actions. Never request raw private data.
"""


def _extract_json_object(content: str) -> dict:
    """Parse a routine JSON object from model output, tolerating markdown code
    fences and surrounding prose."""
    text = (content or "").strip()

    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text
        if text.lower().startswith("json"):
            text = text[4:]
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # Fall back to the widest {...} span in the message.
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end != -1 and end > start:
        return json.loads(text[start : end + 1])

    raise json.JSONDecodeError("no JSON object found in final message", text or "", 0)


def _parse_args(raw) -> dict:
    if isinstance(raw, dict):
        return raw
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return {}


async def build_agent_plan(prompt: str, settings: Settings) -> tuple[Routine, list[dict]]:
    messages: list[dict] = [
        {"role": "system", "content": AGENT_SYSTEM_PROMPT.strip()},
        {"role": "user", "content": prompt},
    ]
    trace: list[dict] = []

    for step in range(1, MAX_STEPS + 1):
        payload = {
            "model": settings.qwen_model,
            "messages": messages,
            "temperature": 0.3,
            "tools": TOOLS,
            "tool_choice": "auto",
        }
        data = await _chat_completion(payload, settings)
        message = data["choices"][0]["message"]
        tool_calls = message.get("tool_calls")

        if tool_calls:
            # Keep the assistant turn (with its tool_calls) in the conversation.
            messages.append({"role": "assistant", "content": message.get("content") or "", "tool_calls": tool_calls})
            for call in tool_calls:
                function = call.get("function", {})
                name = function.get("name", "")
                args = _parse_args(function.get("arguments"))
                result = dispatch_tool(name, args)
                trace.append(
                    {"step": step, "type": "tool_call", "name": name, "args": args, "result": result}
                )
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call.get("id", ""),
                        "name": name,
                        "content": json.dumps(result, ensure_ascii=True),
                    }
                )
            continue

        # Final answer: a routine JSON object.
        content = message.get("content") or ""
        trace.append({"step": step, "type": "final", "content": content})
        decoded = _extract_json_object(content)
        decoded["source_prompt"] = prompt
        decoded["provider"] = "qwen_agent"
        decoded.setdefault("mode", "qwen_agent_reasoning")
        return Routine.model_validate(decoded), trace

    # Did not converge within MAX_STEPS: fall back to the local mock plan.
    trace.append(
        {
            "step": MAX_STEPS,
            "type": "max_steps_reached",
            "content": "Agent did not converge within MAX_STEPS; falling back to local mock plan.",
        }
    )
    routine = build_mock_plan(prompt)
    routine.mode = "agent_max_steps_fallback"
    return routine, trace
