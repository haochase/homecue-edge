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

    if any(word in hint for word in ["tired", "dark", "night", "sofa", "累", "疲惫", "晚上", "夜间", "沙发", "偏暗"]):
        scene = "low-energy evening arrival"
        confidence = 0.78
        suggested_prompt = (
            "用户像是在疲惫一天后回到家。请准备一个安静、低负担、暖光且尽量少打扰的家庭流程。"
        )
    elif any(word in hint for word in ["guest", "family", "child", "dinner"]):
        scene = "shared family activity"
        confidence = 0.72
        suggested_prompt = (
            "房间可能有多人使用。请保持建议适合家庭，说明设备变化，并避免打扰性动作。"
        )
    else:
        scene = "ordinary home context"
        confidence = 0.62
        suggested_prompt = "使用当前房间上下文和用户偏好摘要，提出一个可逆的舒适流程。"

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
