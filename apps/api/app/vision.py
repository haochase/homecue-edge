from app.schemas import VisionSceneRequest, VisionSceneResponse


def analyze_scene(request: VisionSceneRequest) -> VisionSceneResponse:
    """Return a privacy-safe scene summary for the planner.

    This branch keeps the interface model-ready while the local default stays
    deterministic. A later adapter can replace this mock with a home-scene VLM,
    a GGUF local server, or a cloud VLM without changing the planner contract.
    """

    hint = request.text_hint.strip().lower()
    observations = [
        f"input_camera={request.camera}",
        f"room={request.room}",
    ]

    if request.image_base64:
        observations.append("image frame provided")
    else:
        observations.append("no raw image retained")

    if any(word in hint for word in ["tired", "dark", "night", "sofa"]):
        scene = "low-energy evening arrival"
        confidence = 0.78
        suggested_prompt = (
            "User appears to be settling in after a tiring day. Prepare a calm, "
            "low-effort home routine with warm light and minimal interruptions."
        )
    elif any(word in hint for word in ["guest", "family", "child", "dinner"]):
        scene = "shared family activity"
        confidence = 0.72
        suggested_prompt = (
            "The room appears to be used by multiple people. Keep suggestions "
            "family-safe, explain device changes, and avoid disruptive actions."
        )
    else:
        scene = "ordinary home context"
        confidence = 0.62
        suggested_prompt = (
            "Use the current room context and user preference summary to propose "
            "a reversible comfort routine."
        )

    if hint:
        observations.append(f"text_hint={request.text_hint[:120]}")

    return VisionSceneResponse(
        provider="mock_home_vlm_adapter",
        scene=scene,
        confidence=confidence,
        observations=observations,
        privacy_summary={
            "room": request.room,
            "scene": scene,
            "raw_image_retained": False,
            "faces_identified": False,
            "note": "Only a compact scene label and observations are passed to planning.",
        },
        suggested_prompt=suggested_prompt,
        model_route="home-scene VLM adapter placeholder",
    )
