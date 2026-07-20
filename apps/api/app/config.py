import os
from functools import lru_cache
from pathlib import Path
from typing import Literal

from dotenv import dotenv_values
from pydantic_settings import BaseSettings, SettingsConfigDict


_ENV_PATH = Path(__file__).resolve().parents[1] / ".env"

_DEFAULT_API_BASE = "https://dashscope.aliyuncs.com/compatible-mode/v1"
_DEFAULT_MODEL = "qwen-plus"
_DEFAULT_TTS_API_BASE = "https://dashscope.aliyuncs.com/api/v1"
_DEFAULT_TTS_MODEL = "qwen3-tts-flash"
_DEFAULT_TTS_VOICE = "Cherry"
_DEFAULT_MIMO_TTS_API_BASE = "https://mimo-compatible.example.invalid/v1"
_DEFAULT_MIMO_TTS_MODEL = "mimo-v2.5-tts"
_DEFAULT_MIMO_TTS_VOICE = "mimo_default"
_DEFAULT_VOICE_CHAT_MEMORY_DB = Path(__file__).resolve().parents[3] / "runtime" / "voice-chat.sqlite"


class Settings(BaseSettings):
    qwen_api_key: str = ""
    qwen_api_base: str = _DEFAULT_API_BASE
    qwen_model: str = _DEFAULT_MODEL
    planner_provider: Literal["auto", "mock", "qwen"] = "auto"
    active_provider: Literal["qwen", "mimo"] = "qwen"
    voice_chat_tts_provider: Literal["windows", "dashscope", "mimo", "auto"] = "windows"
    voice_chat_tts_api_key: str = ""
    voice_chat_tts_api_base: str = _DEFAULT_TTS_API_BASE
    voice_chat_tts_model: str = _DEFAULT_TTS_MODEL
    voice_chat_tts_voice: str = _DEFAULT_TTS_VOICE
    voice_chat_tts_language_type: str = "Chinese"
    voice_chat_asr_provider: Literal["auto", "mimo", "windows", "faster_whisper", "disabled"] = "auto"
    voice_chat_asr_model: str = "base"
    voice_chat_asr_language: str = "zh-CN"
    voice_chat_memory_db: str = ""
    voice_chat_access_token: str = ""

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


def _normalize_tts_provider(raw: str | None) -> Literal["windows", "dashscope", "mimo", "auto"]:
    candidate = (raw or "").strip().lower()
    if candidate in {"windows", "dashscope", "mimo", "auto"}:
        return candidate  # type: ignore[return-value]
    return "windows"


def _normalize_asr_provider(raw: str | None) -> Literal["auto", "mimo", "windows", "faster_whisper", "disabled"]:
    candidate = (raw or "").strip().lower().replace("-", "_")
    if candidate in {"auto", "mimo", "windows", "faster_whisper", "disabled"}:
        return candidate  # type: ignore[return-value]
    if candidate in {"whisper", "fasterwhisper"}:
        return "faster_whisper"
    return "auto"


def _tts_kwargs_from_env(env: dict[str, str]) -> dict:
    provider = _normalize_tts_provider(env.get("VOICE_CHAT_TTS_PROVIDER"))
    if provider == "mimo":
        api_key = (env.get("VOICE_CHAT_TTS_API_KEY") or env.get("MIMO_API_KEY") or "").strip()
        api_base = (env.get("VOICE_CHAT_TTS_API_BASE") or env.get("MIMO_API_BASE") or _DEFAULT_MIMO_TTS_API_BASE).strip()
        model = (env.get("VOICE_CHAT_TTS_MODEL") or _DEFAULT_MIMO_TTS_MODEL).strip()
        voice = (env.get("VOICE_CHAT_TTS_VOICE") or _DEFAULT_MIMO_TTS_VOICE).strip()
    elif provider in {"dashscope", "auto"}:
        api_key = (
            env.get("VOICE_CHAT_TTS_API_KEY")
            or env.get("DASHSCOPE_API_KEY")
            or env.get("QWEN_API_KEY")
            or ""
        ).strip()
        api_base = (env.get("VOICE_CHAT_TTS_API_BASE") or _DEFAULT_TTS_API_BASE).strip()
        model = (env.get("VOICE_CHAT_TTS_MODEL") or _DEFAULT_TTS_MODEL).strip()
        voice = (env.get("VOICE_CHAT_TTS_VOICE") or _DEFAULT_TTS_VOICE).strip()
    else:
        api_key = (env.get("VOICE_CHAT_TTS_API_KEY") or "").strip()
        api_base = (env.get("VOICE_CHAT_TTS_API_BASE") or _DEFAULT_TTS_API_BASE).strip()
        model = (env.get("VOICE_CHAT_TTS_MODEL") or _DEFAULT_TTS_MODEL).strip()
        voice = (env.get("VOICE_CHAT_TTS_VOICE") or _DEFAULT_TTS_VOICE).strip()

    return {
        "voice_chat_tts_provider": provider,
        "voice_chat_tts_api_key": api_key,
        "voice_chat_tts_api_base": api_base,
        "voice_chat_tts_model": model,
        "voice_chat_tts_voice": voice,
        "voice_chat_tts_language_type": (env.get("VOICE_CHAT_TTS_LANGUAGE_TYPE") or "Chinese").strip(),
    }


def _voice_chat_kwargs_from_env(env: dict[str, str]) -> dict:
    return {
        "voice_chat_asr_provider": _normalize_asr_provider(env.get("VOICE_CHAT_ASR_PROVIDER")),
        "voice_chat_asr_model": (env.get("VOICE_CHAT_ASR_MODEL") or "base").strip(),
        "voice_chat_asr_language": (env.get("VOICE_CHAT_ASR_LANGUAGE") or "zh-CN").strip(),
        "voice_chat_memory_db": (env.get("VOICE_CHAT_MEMORY_DB") or str(_DEFAULT_VOICE_CHAT_MEMORY_DB)).strip(),
        "voice_chat_access_token": (
            env.get("VOICE_CHAT_ACCESS_TOKEN")
            or env.get("HOMECUE_VOICE_CHAT_ACCESS_TOKEN")
            or ""
        ).strip(),
    }


def _settings_from_prefix(env: dict[str, str], prefix: str) -> Settings:
    active_provider: Literal["qwen", "mimo"] = "mimo" if prefix.lower() == "mimo" else "qwen"
    return Settings(
        qwen_api_key=(env.get(f"{prefix}_API_KEY") or "").strip(),
        qwen_api_base=(env.get(f"{prefix}_API_BASE") or _DEFAULT_API_BASE).strip(),
        qwen_model=(env.get(f"{prefix}_MODEL") or _DEFAULT_MODEL).strip(),
        planner_provider=_normalize_provider(env.get(f"{prefix}_PLANNER_PROVIDER")),
        active_provider=active_provider,
        **_tts_kwargs_from_env(env),
        **_voice_chat_kwargs_from_env(env),
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
        **_tts_kwargs_from_env(env),
        **_voice_chat_kwargs_from_env(env),
    )
