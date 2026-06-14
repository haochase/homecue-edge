import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from fastapi.testclient import TestClient


API_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API_DIR))

from app.config import get_settings
from app.main import app


OUTPUT_DIR = API_DIR.parents[1] / "assets" / "demo" / "qwen-verification"
OUTPUT_FILE = OUTPUT_DIR / "latest.json"
PROMPT = (
    "I just got home and feel tired. Make the room comfortable, suggest something simple for dinner, "
    "and set up a relaxing movie mode."
)


def main() -> int:
    settings = get_settings()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    if not settings.qwen_api_key:
        OUTPUT_FILE.write_text(
            json.dumps(
                {
                    "status": "skipped",
                    "reason": "QWEN_API_KEY is not configured.",
                    "checked_at": now_iso(),
                    "expected_provider": "qwen",
                },
                indent=2,
                ensure_ascii=True,
            ),
            encoding="utf-8",
        )
        print(f"Qwen verification skipped. Configure QWEN_API_KEY, then rerun. Wrote {OUTPUT_FILE}")
        return 0

    client = TestClient(app)
    client.post("/devices/reset")

    response = client.post(
        "/plan",
        json={"prompt": PROMPT, "network_mode": "online"},
    )
    response.raise_for_status()
    payload = response.json()
    routine = payload["routine"]
    execution = payload["execution"]

    if routine["provider"] != "qwen":
        raise RuntimeError(f"Expected qwen provider, got {routine['provider']!r}")

    evidence = {
        "status": "passed",
        "checked_at": now_iso(),
        "model": settings.qwen_model,
        "api_base": settings.qwen_api_base,
        "planner_provider": routine["provider"],
        "routine_mode": routine["mode"],
        "action_count": len(routine["actions"]),
        "suggestion_count": len(routine["suggestions"]),
        "accepted_action_count": sum(1 for item in execution if item["accepted"]),
        "rejected_action_count": sum(1 for item in execution if not item["accepted"]),
        "routine": routine,
        "execution": execution,
    }

    OUTPUT_FILE.write_text(json.dumps(evidence, indent=2, ensure_ascii=True), encoding="utf-8")
    print(f"Qwen verification passed. Wrote {OUTPUT_FILE}")
    return 0


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


if __name__ == "__main__":
    raise SystemExit(main())
