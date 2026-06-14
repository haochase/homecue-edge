# HomeCue Edge

[![CI](https://github.com/haochase/homecue-edge/actions/workflows/ci.yml/badge.svg)](https://github.com/haochase/homecue-edge/actions/workflows/ci.yml)

HomeCue Edge is a privacy-aware home edge agent prototype for context-rich smart home scenarios. It reads local home context, summarizes sensitive data on the edge, plans actions with an OpenAI-compatible LLM (or a deterministic fallback), and executes them through a guarded device simulator. A companion ESP32-S3 firmware turns the same flow into a physical, human-in-the-loop terminal.

## Core Loop

```text
home context -> local privacy summary -> LLM planning or agent tools -> structured actions -> guarded execution
```

## Project Shape

```text
homecue-edge/
  apps/
    api/              FastAPI edge gateway and device simulator
    web/              React + Vite control console
  firmware/
    esp32-audio/      ESP32-S3-AUDIO-Board human-in-the-loop firmware
  scripts/            Local helper scripts
  .github/workflows/  CI (API tests + web lint/build) and static Pages build
```

## Architecture

- **Edge gateway (`apps/api`)** — FastAPI service exposing `/health`, `/context`, `/devices`, `/plan`, `/execute`, `/voice`, `/devices/reset`. It builds a privacy summary from local context, routes planning by network mode (online / weak / offline) and provider, and guards every device action through a single allow-list policy.
- **Agent tool-calling** — A multi-step planner (`get_home_context`, `get_device_states`, `propose_actions`) produces an auditable `trace`. Actions are pre-checked read-only before any execution.
- **Propose / execute split** — `/plan` with `execute=false` only proposes (with a read-only precheck); `/execute` runs a user-confirmed subset. This enables human-in-the-loop confirmation.
- **Web console (`apps/web`)** — React UI for prompt input, network mode, agent trace, propose-only flow, and a device simulator that polls `/devices`.
- **Firmware (`firmware/esp32-audio`)** — ESP32-S3 terminal: voice/button input proposes a plan, RGB shows state, physical keys confirm or reject before execution.

## Provider Configuration

The planner uses an OpenAI-compatible chat completions API. Configure it in `apps/api/.env` (copy from `.env.example`):

- `ACTIVE_PROVIDER` selects the active provider profile.
- Each provider supplies `*_API_KEY`, `*_API_BASE`, `*_MODEL`, `*_PLANNER_PROVIDER`.

Planner modes:

- `mock`: always use the deterministic demo planner.
- `qwen`: require the cloud provider and raise on failure.
- `auto`: use the cloud provider when a key is configured, otherwise fall back to mock.

Offline network mode always uses the local fallback routine. Weak-network mode keeps cached local context and marks the routine as weak-network reasoning.

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

Open the Vite URL and keep the API on `http://localhost:8723`. For a public no-backend preview, run the web console with `?demo=static`.

## Hardware Firmware

`firmware/esp32-audio` targets the Waveshare ESP32-S3-AUDIO-Board (dual mic, ES7210/ES8311, RGB ring, user keys). It connects over Wi-Fi to the gateway, proposes a plan via `/plan` (`execute=false`), and confirms or rejects through physical keys via `/execute`. See `firmware/esp32-audio/README.md` for the full flashing and setup guide. Wi-Fi credentials and the PC address go in a git-ignored `secrets.h` (copy from `secrets.h.example`).

## Local Check

```powershell
.\scripts\check-local.ps1
```

This runs API dependency install, Python compile, API tests, and web lint/build. GitHub Actions runs the same API tests and web lint/build on pushes and pull requests via `.github/workflows/ci.yml`.

## License

MIT License. See `LICENSE`.
