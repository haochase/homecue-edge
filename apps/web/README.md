# HomeCue Edge Web Console

React + Vite control console for the HomeCue Edge demo.

## Local Run

```powershell
npm install
npm run dev
```

The console expects the FastAPI gateway at `http://localhost:8723` by default.

## API Base

Use either an environment variable:

```powershell
$env:VITE_API_BASE="http://127.0.0.1:8723"
npm run dev
```

Or a URL query parameter for scripted capture:

```text
http://127.0.0.1:5173/?apiBase=http://127.0.0.1:18000
```

The query parameter takes precedence over `VITE_API_BASE`.

## Static Demo Mode

For public demos without a running API server, open:

```text
http://127.0.0.1:5173/?demo=static
```

Or build a static-only demo:

```powershell
$env:VITE_STATIC_DEMO="true"
$env:VITE_BASE="/homecue-edge/"
npm run build
```

This mode uses the same UI, local action policy, and demo scenario with static in-browser data. The FastAPI path remains the technical source of truth for local development.

## Production Build

```powershell
npm run build
```

The build output is written to `dist/`.

## Android Phone Loop

Use the phone loop when an Android phone is connected by USB and the API plus
Vite dev server are already running on the host.

```powershell
..\..\scripts\check-phone-loop.ps1
```

The wrapper verifies an authorized ADB device, grants Chrome camera/microphone
permissions when possible, maps phone localhost ports back to the host with
`adb reverse`, exposes Android Chrome DevTools on `127.0.0.1:9222`, closes old
HomeCue/local test tabs from previous runs, and runs:

```powershell
npm run phone:loop -- http://127.0.0.1:5173 http://127.0.0.1:8723 http://127.0.0.1:9222
```

The test opens the console on the phone, verifies the Chinese UI, starts the
speech input control, checks that the camera stream prefers the front camera,
captures one frame for `/vision/scene`, writes the returned suggested prompt
into the planning request, creates a propose-only routine, then simulates an
ESP32 serial confirmation through `/execute`. Evidence is written to the
ignored `assets/demo/phone-loop.json` file, including the scene privacy state
showing raw image non-retention.

## Desktop Browser Loop

Use the desktop loop when the API plus Vite dev server are running and you want
to verify the computer-side browser workflow without phone hardware:

```powershell
..\..\scripts\check-desktop-loop.ps1
```

The test launches Playwright Chromium, verifies the Chinese UI, runs
the `/vision/scene` suggested-prompt handoff, propose-only planning, confirms
the routine from the web UI, checks offline fallback, and simulates an ESP32
serial confirmation through `/execute`. Evidence is written to the ignored
`assets/demo/desktop-loop.json` file, with current-step screenshots in the
ignored `assets/demo/playwright-chromium-screens/` directory. The desktop loop
also sends a sentinel image payload directly to `/vision/scene` and fails if the
API returns that payload or marks it retained. It also fails on unexpected
console errors, page exceptions, failed requests, HTTP 4xx/5xx responses, or
blank-like screenshot evidence.

## Full Loop

From the repository root, use the full loop wrapper to start the API and Vite
dev server when needed, run the desktop loop, and write
`assets/demo/full-loop-report.md` plus the machine-readable
`assets/demo/full-loop-report.json`:

```powershell
.\scripts\check-full-loop.ps1
.\scripts\check-full-loop.ps1 -IncludeChrome -IncludePhone -StepTimeoutSeconds 180
```

Add `-IncludeChrome` to run the same desktop loop in installed Windows Chrome
with an isolated temporary profile. Chrome evidence records sanitized executable
identity fields from Windows version metadata, but not the local absolute
executable path. The summary also compares the runtime Chrome user-agent major
version with the executable product major version. Add `-IncludePhone` to run
the Android phone loop after the desktop loop. The wrapper checks the running
API's Chinese
`/vision/scene` contract first, and restarts an older managed uvicorn process if
that contract is stale. The generated Markdown report reads screenshot paths
from the desktop and Windows Chrome loop JSON files, so each report points at
the screenshots from the current run. The report also summarizes browser
runtime-health counts and desktop screenshot evidence for the desktop, Windows
Chrome, and Android Chrome loops. Desktop and Windows Chrome sections include a
browser environment fingerprint with user-agent family, viewport, pixel ratio,
and media/speech API availability. The report command also fails if any
requested loop evidence is missing, marked unsuccessful, or lacks the required
checks. Use `-StepTimeoutSeconds` to bound each child loop and clean up its
process tree if browser or device automation hangs. When the full-loop wrapper
runs multiple targets, it stamps each JSON evidence file with the same run id
and the report gate verifies they match.
Desktop Chromium and installed Windows Chrome are also compared for core UI,
privacy, layout, runtime-health, screenshot, and execution-sync parity. The
evidence section records each JSON and screenshot file with byte size and a
short SHA-256 digest. The JSON summary is generated from the same validated
evidence and exposes top-level `success`, `runId`, browser parity, per-loop
status, runtime-health counts, screenshot summaries, and validation errors for
automation that should not parse Markdown. The wrapper then runs
`npm run summary:check` with the same phone/Chrome requirements, so schema or
contract drift fails before the full-loop command returns success. The checker
also re-reads every present manifest file and recomputes byte size plus the
short SHA-256 digest, then cross-checks the desktop, Windows Chrome, and phone
summary fields against their original JSON evidence. Raw browser JSON screenshot
file byte counts and digests must also match the final manifest entries. Desktop
Chromium and installed Windows Chrome screenshots are required to come from
separate browser-specific evidence directories. JSON evidence labels and file
paths must be unique, and raw desktop/Chrome browser identity fields must match
their manifest role. Windows Chrome evidence must identify `chrome.exe` with
Google Chrome product metadata and matching runtime / executable major versions.
Browser environment fields such as user agent, language, viewport,
headed/channel mode, and raw page origin are cross-checked against the original
browser JSON evidence.
After a successful full-loop run, `npm run summary:selftest` replays the
validator against the current summary plus generated bad summaries under ignored
`assets/tmp/` to prove these guards fail closed.
