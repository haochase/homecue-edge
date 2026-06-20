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

This runs public-repo scanning, patch whitespace checks, API dependency install,
Python compile, API tests, firmware contract checks, full-loop path planning
self-tests, browser evidence dry-run planning self-tests, computer-loop dry-run
planning self-tests, and web lint/build. GitHub Actions runs the API tests and web lint/build on pushes and pull requests via
`.github/workflows/ci.yml`.
The local API test step uses a repo-local pytest cache and basetemp under
ignored `assets/tmp/pytest/` to avoid Windows temp-directory permission noise.

For public-repo safety before staging or committing local work:

```powershell
.\scripts\scan-secrets.ps1 -All -IncludeUntracked
.\scripts\scan-secrets.ps1 -Staged
.\scripts\selftest-scan-secrets.ps1
```

`-All -IncludeUntracked` scans tracked files plus untracked, non-ignored files
in the working tree, so newly added scripts and docs are checked before they are
staged. The self-test creates and removes a temporary untracked marker file to
prove that this mode catches new files before they enter the index.

For a faster read-only preflight before hardware/browser loop work:

```powershell
.\scripts\check-dev-env.ps1
.\scripts\check-dev-env.ps1 -Required -RequirePhone
.\scripts\selftest-dev-env.ps1
```

This does not start services or change ADB/Chrome state. It checks Node/npm,
repo files needed by the API and web app, Windows Chrome, loop ports, optional
ADB, and an optional authorized Android device. It writes a machine-readable
snapshot to `assets/tmp/dev-env-check.json`; use `-Required -RequirePhone` when
the full phone/Chrome loop is expected to run next. The self-test verifies the
optional-phone WARN path and required-phone FAIL path without disconnecting
hardware.

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
that the scene privacy summary reports no raw image retention. The wrapper
immediately validates the raw phone JSON via `npm run phone:evidence:check`, so
front-camera `facingMode=user`, Chinese text integrity, speech readiness,
privacy state, runtime health, and ESP32-style sync must all be present before
the phone command exits successfully.

For a computer-side browser check without phone hardware:

```powershell
.\scripts\check-desktop-loop.ps1
.\scripts\check-chrome-loop.ps1
.\scripts\selftest-browser-wrapper-paths.ps1
```

This launches desktop Chromium and verifies the Chinese UI, propose/confirm
flow, scene suggested-prompt handoff, offline fallback, and ESP32-style
execution synchronization. The desktop loop writes current-step screenshots
next to its ignored JSON evidence so the Markdown report does not rely on stale
screen captures. The screenshot proof requires the six expected step images and
unique image digests so repeated or stale captures fail the loop. Standalone
desktop and Chrome wrappers also validate their raw loop JSON and screenshot
files before returning success, including root/checks field-boundary checks so
unexpected raw-evidence fields fail closed. Desktop and Windows Chrome checks
also send a sentinel image payload and fail if
`/vision/scene` echoes it back or marks it retained.
They also validate key Chinese phrases and fail on common mojibake markers so
desktop evidence covers page localization integrity, not just selector presence.
The initial desktop viewport must keep the top bar plus the prompt, context,
scene, and plan panels visible, so the proof catches first-screen layout
regressions before screenshots are summarized.
Responsive checks also verify mobile, tablet, and desktop widths for horizontal
overflow, button text overflow, and overlapping core panels.
Relative direct-wrapper `-OutputPath` and `-ScreenshotDir` values are resolved
from the repository root; the wrapper path self-test checks that contract
without opening a browser. Direct desktop and Chrome wrappers also share a
named local lock around the API-mutating loop steps, so accidental parallel
starts queue instead of racing the same execution state.

For a one-command computer-side loop that covers both bundled Playwright
Chromium and installed Windows Chrome without phone hardware:

```powershell
.\scripts\check-computer-loop.ps1
.\scripts\check-computer-loop.ps1 -SelfTest
.\scripts\check-computer-loop.ps1 -DryRun
npm --prefix apps/web run computer:result:check -- ..\..\assets\tmp\computer-loop-check.json
npm --prefix apps/web run computer:result:selftest
```

This wrapper runs the full loop with `-IncludeChrome`, writes isolated
computer-loop evidence under `assets/tmp/computer-loop/<run-id>/`, then
revalidates the saved desktop + Windows Chrome evidence through
`check-browser-evidence.ps1 -RequireDesktop -RequireChrome`. It also writes a
machine-readable `computer-loop-check.json` with the full-loop command, browser
evidence command, summary/report paths, and browser-evidence result JSON path.
That result also includes a compact `proofSummary` with the summary run id,
desktop/Windows Chrome pass flags, browser-parity status, screenshot counts,
web-readiness strategy, Chinese text-integrity counts
(`required/missing/mojibake`), external execution source, and the
report/summary/browser-evidence paths plus raw desktop/Chrome/phone/web-readiness
JSON and screenshot directories. Computer-only runs record the skipped phone
path as `__phone_not_run__.json`.
`npm run computer:result:check` prints that compact proof line after validation
so a successful saved-result check is readable without manually opening the JSON;
the line includes `phone=not-run`, `phoneEvidence=__phone_not_run__.json`, and
the checked summary path.
The wrapper validates that result JSON before returning success. Use `-DryRun`
to inspect those paths and commands without starting services or opening
browsers. By default dry-run only prints the plan and does not overwrite the
stable `assets/tmp/computer-loop-check.json`; pass `-ResultJsonPath` when you
want a dry-run result JSON for automation. `computer:result:selftest` replays
positive and negative result JSON cases so phone-only drift, missing nested
browser evidence, mismatched summary paths, missing computer-only
`expectedEvidence.phoneEvidence` sentinels, or embedded browser-evidence content
that differs from the referenced JSON file fail closed. The result checker also
reads the referenced summary JSON directly and verifies desktop + Windows Chrome
ran, phone did not run, browser parity passed, `proofSummary` matches the
referenced summary and browser-evidence result, summary manifest paths match the
browser-evidence plan, browser evidence carries the `Web Readiness JSON`
manifest path, top-level proof paths match the nested browser evidence, and the
skipped phone evidence sentinel matches across layers. The raw desktop/Windows
Chrome JSON files must also share the summary run id and expected browser roles.
It also verifies that
`plan.outputs.resultJsonPath` is the file being checked and that the saved
command arguments still match the planned output paths, timeout options, and
browser-evidence gates. The saved plan must still point at
`scripts/check-full-loop.ps1` and `scripts/check-browser-evidence.ps1`, and the
saved plan and its nested option, output, gate, command, and expected-evidence
objects reject unknown fields. The top-level result must contain exactly the
ordered `computer full loop` and `saved browser evidence recheck` entries with
only their expected fields. The embedded browser-evidence result, its nested
plan, and its nested checks are also treated as manifests: command order, names,
required flags, allowed fields, and optional self-test commands must match the
computer-only plan. Failed results keep the same narrow failure manifest. Keep
custom report, summary, and browser evidence result paths inside `-OutputDir`;
the result checker rejects split output roots.

To minimize manual setup, run the full loop wrapper. It starts the API and Vite
dev server if they are not already running, then runs the requested browser,
Chrome, and phone loop set:

```powershell
.\scripts\check-full-loop.ps1
.\scripts\check-full-loop.ps1 -IncludeChrome -IncludePhone -StepTimeoutSeconds 180
.\scripts\check-full-loop.ps1 -DryRun
```

Complete desktop + phone + Windows Chrome runs write reusable demo evidence to
`assets/demo/full-loop-report.md` and `assets/demo/full-loop-report.json`.
Partial runs, such as desktop-only or Chrome-only smoke checks, default to an
ignored per-run folder under `assets/tmp/full-loop-partial/<run-id>/` so they do
not overwrite the latest complete demo evidence. Pass `-ReportPath` and
`-SummaryPath` when you intentionally want a specific output path. Use
`-DryRun` to print the planned evidence paths and gates as JSON without
starting services or touching ADB/Chrome; `scripts\selftest-full-loop-path-plan.ps1`
uses this mode to keep path-isolation behavior covered by a cheap local test.

The wrapper runs `check-dev-env.ps1 -Required` first. When `-IncludePhone` is
set, it also requires an authorized Android device before launching browser
automation. Use `-SkipPreflight` only when a separate preflight has already
verified the same host and phone state. The generated summary includes the
preflight JSON and cross-checks it in the evidence manifest so host/browser/ADB
readiness is preserved with the browser and phone proof.

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
against the original browser JSON evidence. The summary JSON is also treated as
a strict manifest: top-level, environment, loop, browser-parity, and evidence
entry objects reject unknown fields so stale side-channel proof cannot silently
ride along with a passing summary. Raw preflight and web-readiness JSON evidence
must keep the same narrow field sets when they are referenced by the manifest.
When Windows Chrome is required, the validator recomputes desktop/Chrome parity
from the summarized loop fields rather than trusting the reported parity flag.
It also checks each loop's started/finished timestamps against the raw evidence
and requires the report generation time to be no earlier than completed loops.
Loop page URLs must share the summary app origin and carry the same API base in
their query string, with raw evidence checked against the same URLs.
After a successful full-loop run, `npm run summary:selftest` in `apps/web`
replays the validator against the current summary plus generated bad summaries
under ignored `assets/tmp/` to prove the summary and raw environment
field-boundary, Chrome identity, version, origin, manifest-uniqueness, and phone
text-integrity guards fail closed.
`npm run report:selftest` replays the report generator against source evidence
and generated bad phone JSON so weak front-camera proof cannot be summarized as
a passing report.
`npm run desktop:evidence:selftest` does the same for raw desktop/Chrome loop
JSON and screenshot evidence. `npm run phone:evidence:selftest` replays the
phone raw evidence validator against generated bad phone JSON for front-camera,
localized text, and ESP32 sync failures. `check-full-loop.ps1 -IncludeChrome`
runs the desktop and summary self-tests automatically after `summary:check`;
`check-full-loop.ps1 -IncludePhone` runs the phone evidence self-test as well.
The report self-test runs automatically only for a complete desktop + phone +
Windows Chrome evidence run. Use `npm run summary:selftest -- <summary-json>`
to target an isolated partial or computer-loop summary instead of the default
demo summary.

To revalidate saved browser evidence without starting services, opening Chrome,
or touching ADB, run:

```powershell
.\scripts\check-browser-evidence.ps1
.\scripts\check-browser-evidence.ps1 -RequireDesktop
.\scripts\check-browser-evidence.ps1 -RequireChrome -RequirePhone
.\scripts\check-browser-evidence.ps1 -RequireChrome -RequirePhone -SelfTest
.\scripts\check-browser-evidence.ps1 -DryRun
.\scripts\check-browser-evidence.ps1 -RequireDesktop -RequireChrome -RequirePhone -ResultJsonPath .\assets\tmp\browser-evidence-check.json
npm --prefix apps/web run browser:evidence-result:check -- ..\..\assets\tmp\browser-evidence-check.json
npm --prefix apps/web run browser:evidence-result:selftest
```

This checks the saved desktop Chromium, installed Windows Chrome, Android Chrome
phone, and full-loop summary JSON plus screenshot manifests. By default it reads
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
default demo artifact. When a loop is not required, the dry-run and saved result
use explicit `__*_not_run__` JSON and screenshot-directory sentinels instead of
pointing at previous demo artifacts. `-SelfTest` also replays the validator
negative cases against generated bad evidence under ignored `assets/tmp/`. `-DryRun` prints the
inferred evidence and self-test plan as JSON without reading screenshot
directories or running npm validators. Add `-ResultJsonPath` to save a
machine-readable validation result with the inferred plan and executed check
commands for CI, local automation, or demo handoff notes. The browser evidence
result checker revalidates that saved JSON against the referenced summary,
required evidence, screenshot directories, loop success flags, browser parity,
web readiness, raw desktop/Windows Chrome run ids, browser roles, and self-test
gates without opening browsers. It also treats the saved `checks` array as a
manifest: required entries, names, command order, required flags, allowed
fields, and optional self-test commands must match the inferred plan. In
validate mode it also prints a compact
`Browser evidence proof summary` line with loop status, browser parity,
web-readiness strategy, screenshot counts, self-test state, external execution
source, and the summary path.

## Contributing & Security

This repository is public and holds technical content only. Before committing,
run the privacy/secret scanner:

```powershell
pwsh ./scripts/scan-secrets.ps1 -All -IncludeUntracked
pwsh ./scripts/scan-secrets.ps1 -Staged
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full pre-commit flow and how to
install the git hook, and [`AGENTS.md`](AGENTS.md) for the rules that apply to
human contributors and AI coding agents.

## License

MIT License. See `LICENSE`.
