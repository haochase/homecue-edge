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
`adb reverse`, exposes Android Chrome DevTools on `127.0.0.1:9222`, and runs:

```powershell
npm run phone:loop -- http://127.0.0.1:5173 http://127.0.0.1:8723 http://127.0.0.1:9222
```

The test opens the console on the phone, verifies the Chinese UI, starts the
speech input control, checks that the camera stream prefers the front camera,
captures one frame for `/vision/scene`, creates a propose-only routine, then
simulates an ESP32 serial confirmation through `/execute`. Evidence is written
to the ignored `assets/demo/phone-loop.json` file.

## Desktop Browser Loop

Use the desktop loop when the API plus Vite dev server are running and you want
to verify the computer-side browser workflow without phone hardware:

```powershell
..\..\scripts\check-desktop-loop.ps1
```

The test launches Playwright Chromium, verifies the Chinese UI, runs
propose-only planning, confirms the routine from the web UI, checks offline
fallback, and simulates an ESP32 serial confirmation through `/execute`.
Evidence is written to the ignored `assets/demo/desktop-loop.json` file.

## Full Loop

From the repository root, use the full loop wrapper to start the API and Vite
dev server when needed, run the desktop loop, and write
`assets/demo/full-loop-report.md`:

```powershell
.\scripts\check-full-loop.ps1
```

Add `-IncludeChrome` to run the same desktop loop in installed Windows Chrome
with an isolated temporary profile. Add `-IncludePhone` to run the Android phone
loop after the desktop loop.
