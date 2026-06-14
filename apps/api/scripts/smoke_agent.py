import asyncio
import json
import sys
from pathlib import Path

API_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API_DIR))

from app.config import get_settings  # noqa: E402
from app.planner.agent import build_agent_plan  # noqa: E402

PROMPT = (
    "I just got home and feel tired. Make the room comfortable, suggest something "
    "simple for dinner, and set up a relaxing movie mode."
)


async def main() -> int:
    settings = get_settings()
    routine, trace = await build_agent_plan(PROMPT, settings)
    print("provider:", routine.provider, "mode:", routine.mode)
    print("trace steps:", len(trace))
    for step in trace:
        if step["type"] == "tool_call":
            print(f"  step {step['step']} tool_call -> {step['name']} args={step['args']}")
        else:
            print(f"  step {step['step']} {step['type']}")
    print("actions:", json.dumps([a.model_dump() for a in routine.actions], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
