"""Test isolation.

The shared ``apps/api/.env`` holds real provider credentials for local
development. The test-suite must be hermetic and must never read those keys or
touch the network, so we disable .env loading and strip provider variables from
the process environment before any application module resolves settings.
"""

import os

# Must run at import time, before app modules call get_settings().
os.environ["HOMECUE_DISABLE_DOTENV"] = "1"

for _key in (
    "ACTIVE_PROVIDER",
    "QWEN_API_KEY",
    "QWEN_API_BASE",
    "QWEN_MODEL",
    "QWEN_PLANNER_PROVIDER",
    "PLANNER_PROVIDER",
    "MIMO_API_KEY",
    "MIMO_API_BASE",
    "MIMO_MODEL",
    "MIMO_PLANNER_PROVIDER",
):
    os.environ.pop(_key, None)

from app.config import get_settings  # noqa: E402

get_settings.cache_clear()
