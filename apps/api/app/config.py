import os
from functools import lru_cache
from pathlib import Path
from typing import Literal

from dotenv import dotenv_values
from pydantic_settings import BaseSettings, SettingsConfigDict


_ENV_PATH = Path(__file__).resolve().parents[1] / ".env"

_DEFAULT_API_BASE = "https://dashscope.aliyuncs.com/compatible-mode/v1"
_DEFAULT_MODEL = "qwen-plus"


class Settings(BaseSettings):
    qwen_api_key: str = ""
    qwen_api_base: str = _DEFAULT_API_BASE
    qwen_model: str = _DEFAULT_MODEL
    planner_provider: Literal["auto", "mock", "qwen"] = "auto"

    # extra="ignore" so multi-provider keys (MIMO_*, ACTIVE_PROVIDER, ...) present in
    # the shared .env do not break direct Settings(...) construction used in tests.
    model_config = SettingsConfigDict(extra="ignore")


def _dotenv_disabled() -> bool:
    return os.getenv("HOMECUE_DISABLE_DOTENV", "").strip().lower() in {"1", "true", "yes"}


def _load_env() -> dict[str, str]:
    """Merge the .env file with the process environment (process wins)."""
    values: dict[str, str] = {}
    if not _dotenv_disabled() and _ENV_PATH.exists():
        values.update({key: value for key, value in dotenv_values(_ENV_PATH).items() if value is not None})
    values.update(os.environ)
    return values


def _normalize_provider(raw: str | None) -> Literal["auto", "mock", "qwen"]:
    candidate = (raw or "").strip().lower()
    if candidate in {"auto", "mock", "qwen"}:
        return candidate  # type: ignore[return-value]
    return "auto"


def _settings_from_prefix(env: dict[str, str], prefix: str) -> Settings:
    return Settings(
        qwen_api_key=(env.get(f"{prefix}_API_KEY") or "").strip(),
        qwen_api_base=(env.get(f"{prefix}_API_BASE") or _DEFAULT_API_BASE).strip(),
        qwen_model=(env.get(f"{prefix}_MODEL") or _DEFAULT_MODEL).strip(),
        planner_provider=_normalize_provider(env.get(f"{prefix}_PLANNER_PROVIDER")),
    )


@lru_cache
def get_settings() -> Settings:
    env = _load_env()
    active = (env.get("ACTIVE_PROVIDER") or "").strip().lower()

    # Preferred path: an explicit active provider selects its prefixed credentials.
    if active in {"qwen", "mimo"}:
        return _settings_from_prefix(env, active.upper())

    # Backward compatibility: legacy flat naming (QWEN_API_KEY + PLANNER_PROVIDER).
    return Settings(
        qwen_api_key=(env.get("QWEN_API_KEY") or "").strip(),
        qwen_api_base=(env.get("QWEN_API_BASE") or _DEFAULT_API_BASE).strip(),
        qwen_model=(env.get("QWEN_MODEL") or _DEFAULT_MODEL).strip(),
        planner_provider=_normalize_provider(env.get("PLANNER_PROVIDER")),
    )
