from app.schemas import Routine


def build_mock_plan(prompt: str) -> Routine:
    return Routine(
        mode="mock_cloud_reasoning",
        summary="Prepare a low-effort evening routine that helps the user settle in at home.",
        privacy_summary="Only home state, mood label, weather, and schedule summaries are used for planning.",
        reasoning=[
            "User sounds tired, so the routine should reduce decisions and keep the room calm.",
            "Rainy weather and evening time suggest warm light, mild temperature, and quiet media.",
            "A later project review means reminders should be gentle and not interrupt rest.",
        ],
        actions=[
            {"device": "light", "command": "set_scene", "value": "warm"},
            {"device": "ac", "command": "set_temperature", "value": 26},
            {"device": "projector", "command": "set_mode", "value": "cinema"},
            {"device": "speaker", "command": "play", "value": "soft ambient"},
            {"device": "reminder", "command": "set", "value": "Review project notes at 21:10"},
        ],
        suggestions=[
            {"type": "meal", "title": "Tomato egg noodles", "detail": "Fast, warm, and low effort."},
            {"type": "movie", "title": "Quiet sci-fi night", "detail": "Pick a familiar film to avoid decision fatigue."},
        ],
        source_prompt=prompt,
        provider="mock",
    )


def build_fallback_plan(prompt: str) -> Routine:
    return Routine(
        mode="offline_fallback",
        summary="Cloud is unavailable, so HomeCue Edge runs a local comfort routine.",
        privacy_summary="No cloud request is made in offline mode.",
        reasoning=[
            "Offline mode uses a safe local rule set.",
            "The routine keeps comfort actions simple and reversible.",
        ],
        actions=[
            {"device": "light", "command": "set_scene", "value": "warm"},
            {"device": "ac", "command": "set_temperature", "value": 26},
            {"device": "reminder", "command": "set", "value": "Cloud planning unavailable; basic home routine active."},
        ],
        suggestions=[
            {"type": "meal", "title": "Simple warm dinner", "detail": "Use a low-effort pantry option."},
        ],
        source_prompt=prompt,
        provider="local_fallback",
    )
