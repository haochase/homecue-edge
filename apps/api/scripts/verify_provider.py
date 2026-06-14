"""Quick connectivity check for the active OpenAI-compatible provider.

Reads the active provider from .env via app.config.get_settings(), performs one
real /chat/completions call, and reports only the HTTP status and a short,
non-sensitive snippet. It never prints the API key.
"""

import sys
from pathlib import Path

import httpx

API_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API_DIR))

from app.config import get_settings  # noqa: E402


def main() -> int:
    settings = get_settings()
    if not settings.qwen_api_key:
        print("NO_KEY: active provider has no API key configured.")
        return 2

    base = settings.qwen_api_base.rstrip("/")
    print(f"Provider base: {base}")
    print(f"Model: {settings.qwen_model}")

    payload = {
        "model": settings.qwen_model,
        "messages": [
            {"role": "system", "content": "Reply with strict JSON only."},
            {"role": "user", "content": 'Return {"ping":"pong"} as JSON.'},
        ],
        "temperature": 0.0,
    }

    try:
        with httpx.Client(timeout=30) as client:
            response = client.post(
                f"{base}/chat/completions",
                headers={
                    "Authorization": f"Bearer {settings.qwen_api_key}",
                    "Content-Type": "application/json",
                },
                json=payload,
            )
    except Exception as error:  # noqa: BLE001
        print(f"REQUEST_FAILED: {type(error).__name__}: {error}")
        return 3

    print(f"HTTP {response.status_code}")
    if response.status_code != 200:
        print(f"BODY_SNIPPET: {response.text[:300]}")
        return 4

    data = response.json()
    content = data["choices"][0]["message"].get("content", "")
    print(f"OK content snippet: {content[:120]!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
