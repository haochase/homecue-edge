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
home-scene VLM inference. Regression checks assert that image payloads are not
returned by the API and that loop evidence reports `raw_image_retained=false`.

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

## Phone Loop Check

With the API and web dev server running, a USB-connected unlocked Android phone
can run the mobile multimodal loop with minimal manual steps:

```powershell
.\scripts\check-phone-loop.ps1
```

The script configures ADB reverse ports and Android Chrome DevTools, then checks
Chinese UI text, speech-input readiness, front-camera preference, scene capture,
the `/vision/scene` suggested-prompt handoff into propose-only planning, and
the ESP32-style `/execute` synchronization path. Phone evidence also records
that the scene privacy summary reports no raw image retention.

For a computer-side browser check without phone hardware:

```powershell
.\scripts\check-desktop-loop.ps1
```

This launches desktop Chromium and verifies the Chinese UI, propose/confirm
flow, scene suggested-prompt handoff, offline fallback, and ESP32-style
execution synchronization. The desktop loop writes current-step screenshots
next to its ignored JSON evidence so the Markdown report does not rely on stale
screen captures. The screenshot proof requires the six expected step images and
unique image digests so repeated or stale captures fail the loop. Standalone
desktop and Chrome wrappers also validate their raw loop JSON and screenshot
files before returning success. Desktop and Windows Chrome checks also send a
sentinel image payload and fail if
`/vision/scene` echoes it back or marks it retained.
They also validate key Chinese phrases and fail on common mojibake markers so
desktop evidence covers page localization integrity, not just selector presence.
The initial desktop viewport must keep the top bar plus the prompt, context,
scene, and plan panels visible, so the proof catches first-screen layout
regressions before screenshots are summarized.
Responsive checks also verify mobile, tablet, and desktop widths for horizontal
overflow, button text overflow, and overlapping core panels.

To minimize manual setup, run the full loop wrapper. It starts the API and Vite
dev server if they are not already running, runs the desktop loop, then writes a
Markdown report to `assets/demo/full-loop-report.md`:

```powershell
.\scripts\check-full-loop.ps1
.\scripts\check-full-loop.ps1 -IncludeChrome -IncludePhone -StepTimeoutSeconds 180
```

Add `-IncludePhone` when an unlocked Android phone is connected by USB and
Chrome debugging is available. The phone wrapper closes old HomeCue Android
Chrome test tabs before launching the current target so repeated runs do not
reuse stale page state.

Add `-IncludeChrome` to also verify the loop in installed Windows Chrome with an
isolated temporary profile. The summary validator requires this run to report
`windows-chrome` with a custom executable, so the Chrome gate cannot be
satisfied by the bundled Playwright Chromium run. Chrome evidence also records
sanitized executable identity fields from Windows version metadata, including
the file name, source kind, product name, company name, and product version, but
not the local absolute executable path. The summary also compares the runtime
Chrome user-agent major version with the executable product major version.

The full wrapper also checks that the running API passes the Chinese
`/vision/scene` contract. If the port is occupied by an older managed uvicorn
process, it restarts that process before running browser checks.
The generated JSON summary is validated against the original desktop, Windows
Chrome, and phone JSON evidence, including screenshot hashes and Chinese text
integrity / first-viewport visibility / responsive layout fields. The evidence
manifest must also list every screenshot path declared by the raw browser JSON.
Screenshot byte counts and digests recorded inside raw browser JSON must also
match the final evidence manifest. Desktop Chromium and Windows Chrome
screenshots must come from their own browser-specific evidence directories. JSON
evidence labels and file paths must be unique, and raw desktop/Chrome browser
identity fields must match their manifest role. Windows Chrome evidence must
identify `chrome.exe` with Google Chrome product metadata and matching runtime /
executable major versions. Browser environment fields such as user agent,
language, viewport, headed/channel mode, and raw page origin are cross-checked
against the original browser JSON evidence.
When Windows Chrome is required, the validator recomputes desktop/Chrome parity
from the summarized loop fields rather than trusting the reported parity flag.
It also checks each loop's started/finished timestamps against the raw evidence
and requires the report generation time to be no earlier than completed loops.
Loop page URLs must share the summary app origin and carry the same API base in
their query string, with raw evidence checked against the same URLs.
After a successful full-loop run, `npm run summary:selftest` in `apps/web`
replays the validator against the current summary plus generated bad summaries
under ignored `assets/tmp/` to prove the Chrome identity, version, origin, and
manifest-uniqueness guards fail closed. `npm run desktop:evidence:selftest`
does the same for raw desktop/Chrome loop JSON and screenshot evidence.
`check-full-loop.ps1 -IncludeChrome` runs both self-tests automatically after
`summary:check`.

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
