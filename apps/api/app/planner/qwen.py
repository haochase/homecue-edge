import json

import httpx

from app.config import Settings
from app.schemas import Routine


SYSTEM_PROMPT = """
You are HomeCue Edge, a privacy-aware home EdgeAgent planner.
Return only strict JSON with this shape:
{
  "mode": "qwen_cloud_reasoning",
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
Use only the provided privacy summary. Do not ask for raw private data.
Write all user-visible JSON text fields in Simplified Chinese: summary,
privacy_summary, reasoning, suggestions.title, suggestions.detail, and any
reminder text in actions.value. Keep only enum-like fields and device commands
in the allowed English tokens below.
Allowed actions:
- light set_scene: warm, bright, night
- ac set_temperature: number
- projector set_mode: cinema, standby
- speaker play: playlist name
- reminder set: reminder message
"""


async def _chat_completion(payload: dict, settings: Settings) -> dict:
    """Low-level OpenAI-compatible /chat/completions call shared by the single-turn
    planner and the multi-step agent loop."""
    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            f"{settings.qwen_api_base.rstrip('/')}/chat/completions",
            headers={
                "Authorization": f"Bearer {settings.qwen_api_key}",
                "Content-Type": "application/json",
            },
            json=payload,
        )
        response.raise_for_status()
        return response.json()


async def build_qwen_plan(prompt: str, privacy_summary: dict, settings: Settings) -> Routine:
    payload = {
        "model": settings.qwen_model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT.strip()},
            {
                "role": "user",
                "content": json.dumps(
                    {"user_prompt": prompt, "privacy_summary": privacy_summary},
                    ensure_ascii=True,
                ),
            },
        ],
        "temperature": 0.3,
        "response_format": {"type": "json_object"},
    }

    data = await _chat_completion(payload, settings)

    content = data["choices"][0]["message"]["content"]
    decoded = json.loads(content)
    decoded["source_prompt"] = prompt
    decoded["provider"] = "qwen"
    decoded.setdefault("mode", "qwen_cloud_reasoning")

    return Routine.model_validate(decoded)
