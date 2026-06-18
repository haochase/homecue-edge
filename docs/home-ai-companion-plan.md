# Home AI Companion Branch Plan

This branch separates the whole-home AI companion direction from the original
HomeCue Edge demo prototype. The goal is to keep the public repo technical and
reviewable while allowing the new product line to evolve around phone input,
home-scene vision understanding, voice/text interaction, and ESP32 edge
terminals.

## Why This Branch Exists

The original HomeCue Edge line is a demo-oriented edge-agent project:

- Smart-home context is mostly structured text.
- The planner focuses on propose/confirm/execute safety.
- ESP32 is a physical human-in-the-loop terminal.
- Proof artifacts are organized around demo readiness.

The Home AI companion line has a different product center:

- The phone becomes the primary multimodal sensor and interaction surface.
- Visual scene understanding becomes a first-class input, not a stretch goal.
- ESP32 terminals become low-cost room satellites.
- The product story is whole-home perception, privacy summaries, device
  orchestration, and recoverable automation.

## External Model Direction

The branch is designed for a home-scene vision-language model adapter. The
public repo does not vendor model weights or hard-code provider-specific
credentials. The default implementation keeps a mock-compatible adapter so CI
and local development work without downloading large models or adding private
credentials.

The adapter can later be replaced by a local GGUF runtime, a LAN model server,
or an OpenAI-compatible multimodal endpoint while keeping the same response
contract.

## Product Direction

Working name: **Home AI Companion**.

P0 target with existing hardware:

- Android phone opens the web console through ADB reverse.
- Phone Chrome grants microphone and camera permissions for local testing.
- `/vision/scene` accepts a phone camera frame or text hint and returns a compact
  scene label, privacy summary, observations, and planner prompt.
- `/plan` remains propose/execute separated.
- ESP32 still supports serial/button guarded execution.

P1 target after P0 is stable:

- Replace the mock vision adapter with a local home-scene VLM service.
- Add phone still-frame capture in the web console.
- Feed the `/vision/scene.suggested_prompt` into `/plan` without raw image
  retention.
- Add regression tests that assert raw images are not persisted by default.

P2 target after a model/runtime choice is proven:

- Evaluate local GGUF inference vs. LAN model server.
- Add room-specific ESP32 satellite identity.
- Support multiple room summaries and conflict handling.

## Architecture Delta

```text
phone camera/mic/text
  -> phone web console
  -> /vision/scene
  -> privacy-safe scene summary
  -> /plan execute=false
  -> phone or ESP32 confirmation
  -> /execute guarded device actions
```

The key boundary is that visual input is summarized before planning. The planner
does not need raw image bytes to propose a device routine.

## Current Implementation

This branch adds:

- `POST /vision/scene`
- `VisionSceneRequest`
- `VisionSceneResponse`
- `app.vision.analyze_scene()`
- API tests for the privacy-safe scene response

The current provider is `mock_home_vlm_adapter`. It is intentionally
deterministic and dependency-free. A real adapter can later keep the same
response contract.

Example:

```powershell
Invoke-RestMethod http://127.0.0.1:8723/vision/scene `
  -Method Post `
  -ContentType application/json `
  -Body '{"room":"living room","camera":"phone","text_hint":"tired on sofa at night"}'
```

Expected planning handoff:

```text
scene: low-energy evening arrival
privacy_summary.raw_image_retained: false
suggested_prompt: User appears to be settling in after a tiring day...
```

## Separation Rules

- Keep submission-specific artifacts out of this branch unless they are generic
  technical evidence.
- Keep private planning notes outside the public repo.
- Do not commit API keys, local absolute paths, or model weights.
- Use this branch for home-scene companion development and leave the original
  demo line to its own branch/history.
