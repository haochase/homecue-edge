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

Before running hardware/browser loops, the repository-level preflight can check
the host and optional phone prerequisites without changing service or ADB state:

```powershell
& ..\..\scripts\check-dev-env.ps1
& ..\..\scripts\check-dev-env.ps1 -Required -RequirePhone
```

Use the phone loop when an Android phone is connected by USB and the API plus
Vite dev server are already running on the host.

```powershell
& ..\..\scripts\check-phone-loop.ps1
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
showing raw image non-retention. The wrapper then runs
`npm run phone:evidence:check` against that raw JSON, so the phone command fails
if `facingMode=user`, Chinese text integrity, speech readiness, raw-image
non-retention, runtime health, or ESP32-style synchronization evidence is
missing.

To validate existing phone evidence without reopening Android Chrome:

```powershell
npm run phone:evidence:check -- ..\..\assets\demo\phone-loop.json http://127.0.0.1:5173 http://127.0.0.1:8723 http://127.0.0.1:9222
npm run phone:evidence:selftest
```

## Desktop Browser Loop

Use the desktop loop when the API plus Vite dev server are running and you want
to verify the computer-side browser workflow without phone hardware:

```powershell
& ..\..\scripts\check-desktop-loop.ps1
& ..\..\scripts\check-chrome-loop.ps1
& ..\..\scripts\selftest-browser-wrapper-paths.ps1
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
blank-like screenshot evidence. The wrapper validates the raw loop JSON and
screenshot files before returning success.
Relative direct-wrapper `-OutputPath` and `-ScreenshotDir` values are resolved
from the repository root; the wrapper path self-test verifies that behavior
without opening a browser. Direct desktop and Chrome wrappers also share a
named local lock around API-mutating loop steps, so accidental parallel starts
queue instead of racing the same execution state.

For a one-command computer-side loop that covers both bundled Playwright
Chromium and installed Windows Chrome without phone hardware:

```powershell
& ..\..\scripts\check-computer-loop.ps1
& ..\..\scripts\check-computer-loop.ps1 -SelfTest
& ..\..\scripts\check-computer-loop.ps1 -DryRun
npm run computer:result:check -- ..\..\assets\tmp\computer-loop-check.json
npm run computer:result:selftest
```

This wrapper runs the full loop with `-IncludeChrome`, writes isolated
computer-loop evidence under `assets/tmp/computer-loop/<run-id>/`, then
revalidates the saved desktop + Windows Chrome evidence through
`check-browser-evidence.ps1 -RequireDesktop -RequireChrome`. It also writes a
machine-readable `computer-loop-check.json` with the full-loop command, browser
evidence command, summary/report paths, and browser-evidence result JSON path.
That result also includes a compact `proofSummary` with the summary run id,
desktop/Windows Chrome pass flags, browser-parity status, screenshot counts,
Chinese text-integrity counts (`required/missing/mojibake`), external execution
source, and the report/summary/browser-evidence paths.
`npm run computer:result:check` prints that compact proof line after validation
so a successful saved-result check is readable without manually opening the
JSON.
The wrapper validates that result JSON before returning success. Use `-DryRun`
to inspect those paths and commands without starting services or opening
browsers. By default dry-run only prints the plan and does not overwrite the
stable `assets/tmp/computer-loop-check.json`; pass `-ResultJsonPath` when you
want a dry-run result JSON for automation. `computer:result:selftest` replays
positive and negative result JSON cases so phone-only drift, missing nested
browser evidence, mismatched summary paths, or embedded browser-evidence content
that differs from the referenced JSON file fail closed. The result checker also
reads the referenced summary JSON directly and verifies desktop + Windows Chrome
ran, phone did not run, browser parity passed, `proofSummary` matches the
referenced summary and browser-evidence result, summary manifest paths match the
browser-evidence plan, and the raw desktop/Windows Chrome JSON files share the
summary run id and expected browser roles. It also verifies that
`plan.outputs.resultJsonPath` is the file being checked and that the saved
command arguments still match the planned output paths, timeout options, and
browser-evidence gates. Keep custom report, summary, and browser evidence result
paths inside `-OutputDir`; the result checker rejects split output roots.

## Full Loop

From the `apps/web` directory, use the full loop wrapper to start the API and Vite
dev server when needed, then run the requested desktop, phone, and Windows
Chrome loop set:

```powershell
& ..\..\scripts\check-full-loop.ps1
& ..\..\scripts\check-full-loop.ps1 -IncludeChrome -IncludePhone -StepTimeoutSeconds 180
& ..\..\scripts\check-full-loop.ps1 -DryRun
```

Complete desktop + phone + Windows Chrome runs write
`assets/demo/full-loop-report.md` plus the machine-readable
`assets/demo/full-loop-report.json`. Partial runs default to a per-run ignored
folder under `assets/tmp/full-loop-partial/<run-id>/`, which keeps smoke-check
evidence from replacing the latest complete demo artifacts. `-DryRun` prints
the planned evidence paths and gates as JSON without starting services or
touching ADB/Chrome, and `scripts\selftest-full-loop-path-plan.ps1` uses that
mode to cover path planning without hardware.

The full-loop wrapper runs the repository preflight first. It uses
`check-dev-env.ps1 -Required` by default and adds `-RequirePhone` when
`-IncludePhone` is set, so missing Node/npm, repo files, Windows Chrome, ADB, or
an authorized phone fail before browser automation starts. Use `-SkipPreflight`
only after running an equivalent check separately. The full-loop JSON summary
records that preflight and validates the raw `assets/tmp/dev-env-check.json`
entry through the same evidence manifest as browser, Chrome, phone, and
screenshot artifacts.

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
`assets/tmp/` to prove these guards fail closed. The
`report:selftest` command replays the report generator against source evidence
and generated bad phone JSON so weak front-camera proof cannot be summarized as
a passing report. The
`desktop:evidence:selftest` command does the same for raw desktop/Chrome loop
JSON and screenshot evidence. The `phone:evidence:selftest` command does the
same for raw Android Chrome evidence, covering front-camera, localized text, and
ESP32 sync failures. The full-loop wrapper runs the phone self-test when
`-IncludePhone` is set, runs the desktop/summary self-tests when
`-IncludeChrome` is set, and runs the report self-test only for a complete
desktop + phone + Windows Chrome evidence run. Use
`npm run summary:selftest -- <summary-json>` to target an isolated partial or
computer-loop summary instead of the default demo summary.

To re-check an existing complete evidence set without starting services,
opening Chrome, changing ADB state, or touching the ESP32, run from the
`apps/web` directory:

```powershell
& ..\..\scripts\check-browser-evidence.ps1
& ..\..\scripts\check-browser-evidence.ps1 -RequireDesktop
& ..\..\scripts\check-browser-evidence.ps1 -RequireChrome -RequirePhone
& ..\..\scripts\check-browser-evidence.ps1 -RequireChrome -RequirePhone -SelfTest
& ..\..\scripts\check-browser-evidence.ps1 -DryRun
& ..\..\scripts\check-browser-evidence.ps1 -RequireDesktop -RequireChrome -RequirePhone -ResultJsonPath ..\..\assets\tmp\browser-evidence-check.json
npm run browser:evidence-result:check -- ..\..\assets\tmp\browser-evidence-check.json
npm run browser:evidence-result:selftest
```

The script reuses the same raw desktop, Windows Chrome, phone, and summary
validators that the full-loop wrapper uses. By default it reads
`assets/demo/full-loop-report.json` and infers which loop evidence is required
from the saved summary. Because the default demo summary can reference a
mutable local `assets/tmp/dev-env-check.json`, the default path is first copied
to an ignored self-contained snapshot under `assets/tmp/browser-evidence-default-summary/`;
explicit `-SummaryPath` values remain strict and are not rewritten. It resolves
JSON evidence paths and screenshot
directories from the summary evidence manifest, which keeps custom or partial
summary captures re-checkable without hand-entering every path. If the manifest
lists browser JSON but not screenshots, the script reads that raw JSON to infer
the screenshot directory. If a required phone, Chrome, or desktop loop
contradicts the saved summary, the script fails before falling back to any
default demo artifact. `-SelfTest` also replays the validator negative cases
against generated bad evidence under ignored `assets/tmp/`. `-DryRun` prints the
inferred evidence and self-test plan as JSON without reading screenshot
directories or running npm validators. Add `-ResultJsonPath` to save a
machine-readable validation result with the inferred plan and executed check
commands for CI, local automation, or demo handoff notes. The browser evidence
result checker revalidates that saved JSON against the referenced summary,
required evidence, screenshot directories, loop success flags, browser parity,
raw desktop/Windows Chrome run ids, browser roles, and self-test gates without
opening browsers. In validate mode it also prints a compact
`Browser evidence proof summary` line with loop status, browser parity,
screenshot counts, self-test state, external execution source, and the summary
path.
