# Home AI Companion

[![CI](https://github.com/haochase/homecue-edge/actions/workflows/ci.yml/badge.svg)](https://github.com/haochase/homecue-edge/actions/workflows/ci.yml)

This branch is the home-scene companion evolution of HomeCue Edge. It keeps the
guarded smart-home agent loop, but moves the product center toward a multimodal
whole-home AI companion: phone input, visual scene summaries, voice/text
interaction, and ESP32 room terminals.

The branch is intentionally separate from the earlier demo line so the two
product stories do not mix. See
[`docs/home-ai-companion-plan.md`](docs/home-ai-companion-plan.md) for the
branch plan and home-scene VLM integration path.

## Core Loop

```text
phone/room inputs -> local privacy summary -> scene/planner reasoning -> proposed actions -> guarded execution
```

## Project Shape

```text
homecue-edge/
  apps/
    api/              FastAPI edge gateway, vision adapter, and device simulator
    web/              React + Vite control console
  firmware/
    esp32-audio/      ESP32-S3-AUDIO-Board human-in-the-loop firmware
  scripts/            Local helper scripts
  docs/               Branch architecture notes
  .github/workflows/  CI (API tests + web lint/build) and static Pages build
```

## Architecture

- **Edge gateway (`apps/api`)**: FastAPI service exposing `/health`, `/context`,
  `/devices`, `/plan`, `/execute`, `/voice`, `/vision/scene`, and
  `/devices/reset`. It builds privacy summaries from local context, routes
  planning by network mode, and guards every device action through a single
  allow-list policy.
- **Vision scene adapter (`POST /vision/scene`)**: A home-scene VLM-compatible
  contract that converts phone/room visual hints into a compact scene label,
  privacy summary, and planner prompt. The default provider is deterministic
  and dependency-free; a local GGUF service can replace it later without
  changing the planner contract.
- **Agent tool-calling**: A multi-step planner (`get_home_context`,
  `get_device_states`, `propose_actions`) produces an auditable `trace`.
  Actions are pre-checked read-only before any execution.
- **Propose / execute split**: `/plan` with `execute=false` only proposes with a
  read-only precheck; `/execute` runs a user-confirmed subset. This enables
  human-in-the-loop confirmation.
- **Web console (`apps/web`)**: React UI for prompt input, network mode, agent
  trace, propose-only flow, and a device simulator that polls `/devices` plus
  `/execution/latest` so phone UI reflects ESP32 or other hardware
  confirmations.
- **Firmware (`firmware/esp32-audio`)**: ESP32-S3 terminal: voice/button input
  proposes a plan, RGB shows state, physical keys confirm or reject before
  execution.

## Provider Configuration

The planner uses an OpenAI-compatible chat completions API. Configure it in
`apps/api/.env` (copy from `.env.example`):

- `ACTIVE_PROVIDER` selects the active provider profile.
- Each provider supplies `*_API_KEY`, `*_API_BASE`, `*_MODEL`,
  `*_PLANNER_PROVIDER`.

Planner modes:

- `mock`: always use the deterministic demo planner.
- `qwen`: require the cloud provider and raise on failure.
- `auto`: use the cloud provider when a key is configured, otherwise fall back
  to mock.

Offline network mode always uses the local fallback routine. Weak-network mode
keeps cached local context and marks the routine as weak-network reasoning.

## Vision Scene API

```powershell
Invoke-RestMethod http://127.0.0.1:8723/vision/scene `
  -Method Post `
  -ContentType application/json `
  -Body '{"room":"living room","camera":"phone","text_hint":"tired on sofa at night"}'
```

The response contains a privacy-safe `scene`, `observations`,
`privacy_summary`, and `suggested_prompt`. The current implementation is
`mock_home_vlm_adapter`; it is a stable adapter point for later local
home-scene VLM inference.

## Local Development

Run the API:

```powershell
cd apps/api
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
uvicorn app.main:app --reload --port 8723
```

Run the web console:

```powershell
cd apps/web
npm install
npm run dev
```

Open the Vite URL and keep the API on `http://localhost:8723`. For a public
no-backend preview, run the web console with `?demo=static`.

## Hardware Firmware

`firmware/esp32-audio` targets the Waveshare ESP32-S3-AUDIO-Board (dual mic,
ES7210/ES8311, RGB ring, user keys). It connects over Wi-Fi to the gateway,
proposes a plan via `/plan` (`execute=false`), and confirms or rejects through
physical keys via `/execute`. See `firmware/esp32-audio/README.md` for the full
flashing and setup guide. Wi-Fi credentials and the PC address go in a
git-ignored `secrets.h` (copy from `secrets.h.example`).

## Local Check

```powershell
.\scripts\check-local.ps1
```

This runs API dependency install, Python compile, API tests, and web lint/build.
GitHub Actions runs the same API tests and web lint/build on pushes and pull
requests via `.github/workflows/ci.yml`.

## Contributing & Security

This repository is public and holds technical content only. Before committing,
run the privacy/secret scanner:

```powershell
pwsh ./scripts/scan-secrets.ps1
pwsh ./scripts/scan-secrets.ps1 -Staged
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full pre-commit flow and how to
install the git hook, and [`AGENTS.md`](AGENTS.md) for the rules that apply to
human contributors and AI coding agents.

## License

MIT License. See `LICENSE`.
