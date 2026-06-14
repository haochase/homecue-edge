BASE_CONTEXT = {
    "home": {
        "room": "living room",
        "time": "19:35",
        "weather": "light rain, 18C",
        "occupancy": "user just arrived home",
    },
    "user": {
        "mood": "tired",
        "preference": "warm lighting, quiet movie nights, simple meals",
        "privacy_policy": "raw calendar and sensor data stay local; only summaries are sent to cloud reasoning",
    },
    "schedule": [
        {"time": "21:30", "title": "short project review"},
        {"time": "23:30", "title": "sleep target"},
    ],
}


def build_privacy_summary(context: dict) -> dict:
    return {
        "home": {
            "room": context["home"]["room"],
            "time": context["home"]["time"],
            "weather": context["home"]["weather"],
            "occupancy": context["home"]["occupancy"],
        },
        "user": {
            "mood": context["user"]["mood"],
            "preference": context["user"]["preference"],
        },
        "schedule_summary": "2 evening items; next reminder is a short project review at 21:30",
        "privacy_note": "Raw local data is not sent. This payload is a compact edge-side summary.",
    }
