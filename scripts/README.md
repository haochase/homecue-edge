# Scripts

Local helper scripts for HomeCue Edge.

```powershell
.\scripts\check-local.ps1
```

Runs API dependency install, Python compile, API tests, the firmware flow contract check, then web dependency install, lint, and build. This is the main local gate and mirrors CI for software checks while also catching firmware contract drift.

```powershell
.\scripts\check-local.ps1 -SkipFirmware
```

Skips the static firmware contract check when you are validating only the API and web console.

```powershell
.\scripts\start-dev.ps1
```

Starts the FastAPI edge gateway on `http://127.0.0.1:8723` and the Vite web console on `http://127.0.0.1:5173`.

```powershell
.\scripts\check-full-loop.ps1
.\scripts\check-full-loop.ps1 -IncludePhone
.\scripts\check-full-loop.ps1 -IncludeChrome -IncludePhone
.\scripts\check-full-loop.ps1 -IncludeChrome -IncludePhone -StepTimeoutSeconds 180
```

Starts the API and Vite dev server when they are not already listening, runs the
desktop browser loop, then writes `assets/demo/full-loop-report.md` and the
machine-readable `assets/demo/full-loop-report.json` summary. Add
`-IncludeChrome` to verify an isolated Windows Chrome profile, and add
`-IncludePhone` to run the Android Chrome phone loop after the desktop loop when
an unlocked USB-debugging phone is connected; the phone wrapper closes old
HomeCue/local test tabs from previous runs before opening the current target.
Before browser checks, the wrapper
verifies the running API can classify the default Chinese home-scene hint through
`/vision/scene`; when the port is occupied by an older managed uvicorn process,
it restarts that process and fails if the refreshed API still does not satisfy
the contract. Desktop and Windows Chrome loops write per-step screenshots to
ignored `assets/demo/*-screens/` folders and the report uses only the screenshot
paths recorded in the current JSON evidence. Browser loops also fail on
unexpected console errors, page exceptions, failed requests, or HTTP 4xx/5xx
responses. They verify that each screenshot is a non-empty PNG with plausible
dimensions and image data, and the report summarizes runtime-health and
screenshot-evidence counts. Desktop and Windows Chrome evidence also records
browser environment details such as user agent family, viewport, pixel ratio,
and media/speech API availability. Windows Chrome evidence also includes
sanitized executable identity fields from Windows version metadata, without
recording the local absolute executable path, and the summary compares the
runtime Chrome user-agent major version with the executable product major
version. The report step validates the required JSON evidence before exiting
successfully, so a missing or failed desktop, Chrome, or phone loop cannot be
hidden by a generated Markdown summary.
When `-SkipDesktop`
or optional phone/Chrome checks are omitted, the wrapper passes an explicit
`__*_not_run__.json` sentinel so old evidence from a previous run is not reused.
Relative `-ReportPath` values are resolved from the repository root.
Relative `-ReportPath` and `-SummaryPath` values are resolved from the
repository root. Use `-StepTimeoutSeconds` to bound each browser or phone child
loop and clean up its process tree if device automation hangs.
Each full-loop run also stamps desktop, phone, and Chrome JSON evidence with a
shared run id; the report gate fails when required evidence files do not share
that id. When both desktop Chromium and installed Windows Chrome are included,
the report gate also checks browser parity for core UI, privacy, layout, runtime
health, screenshot, and execution-sync results. The report's evidence manifest
lists each JSON and screenshot artifact with byte size and a short SHA-256 digest
so local proof files can be tied back to the generated report. The JSON summary
uses the same validated evidence and includes top-level `success`, `runId`,
browser parity, per-loop status, runtime-health counts, screenshot summaries,
and validation errors for downstream automation. After writing the summary, the
wrapper runs `npm run summary:check` with matching phone/Chrome requirements so
schema or contract drift fails the full-loop gate immediately. That checker
also re-reads every present manifest file and recomputes byte size plus the
short SHA-256 digest, then cross-checks the desktop, Windows Chrome, and phone
summary fields against their original JSON evidence so stale or edited evidence
files are caught.
Browser environment fields such as user agent, language, viewport,
headed/channel mode, and raw page origin are cross-checked against the original
browser JSON evidence.
Run `npm run summary:selftest` from `apps/web` after a successful full-loop run
to replay the validator against generated bad summaries under ignored
`assets/tmp/`.

```powershell
.\scripts\check-chrome-loop.ps1
```

Runs the desktop browser loop against the installed Windows Chrome executable
with an isolated temporary profile under `assets/tmp`.

```powershell
.\scripts\verify-qwen.ps1
```

Runs the configured OpenAI-compatible planner path against the active provider and prints a verification result. Requires a valid key in `apps/api/.env`.

```powershell
.\scripts\check-firmware-env.ps1 -ExpectedPort COM7
```

Prints a read-only ESP32 firmware environment snapshot: `arduino-cli` availability, ESP32 board core, the firmware sketch, local `secrets.h` presence, Arduino library folder, common audio libraries, and detected serial ports. Add `-Required` when the script should fail if `arduino-cli` or required firmware files are missing.

```powershell
.\scripts\check-firmware-flow.ps1 -Required
```

Statically checks the ESP32 firmware flow contract: fixed command prompts exist, `/plan` stays propose-only (`execute=false`), agent tracing remains enabled, physical confirmation gates `/execute`, and the ESP-SR vendor hook stays isolated behind `pollVoiceCommand()`.

```powershell
.\scripts\flash-esp32.ps1 -Port COM7 -Clean
.\scripts\flash-esp32.ps1 -Port COM7 -Upload
```

Compiles the ESP32-S3 firmware with the HomeCue board options (`16MB` flash, `OPI PSRAM`, USB CDC enabled). The first command only builds; the second uploads the latest build to the board. If `arduino-cli` is not on `PATH`, the script also checks the local portable CLI at `%USERPROFILE%\.codex\tools\arduino-cli\arduino-cli.exe`.

```powershell
.\scripts\read-esp32-serial.ps1 -Port COM7 -Seconds 8
.\scripts\read-esp32-serial.ps1 -Port COM7 -Seconds 45 -SendCommand "homecue:plan 0","homecue:execute" -SendAfterSeconds 18
```

Reads a short 115200-baud serial log from the board after upload. Close Arduino IDE Serial Monitor first so the script can open the port. Use `-SendCommand` to exercise the firmware's serial test route (`homecue:plan 0`, `homecue:execute`, `homecue:reject`) without pressing physical keys.

```powershell
.\scripts\check-esp32-serial-log.ps1 -Port COM7 -Seconds 10 -Required
.\scripts\check-esp32-serial-log.ps1 -Port COM7 -Seconds 45 -SkipReset -RequireInteraction -SaveLogPath .\assets\demo\esp32-level4.log -ResultJsonPath .\assets\demo\esp32-level4-check.json
.\scripts\check-esp32-serial-log.ps1 -Port COM7 -Seconds 60 -SkipReset -RequireInteraction -SendCommand "homecue:plan 0","homecue:execute" -SendAfterSeconds 25 -SaveLogPath .\assets\demo\esp32-level4.log -ResultJsonPath .\assets\demo\esp32-level4-check.json -Required
.\scripts\check-esp32-serial-log.ps1 -Port COM7 -Seconds 90 -SkipReset -RequireInteraction -AutoSerialLevel4 -SerialCommandIndex 0 -SaveLogPath .\assets\demo\esp32-level4.log -ResultJsonPath .\assets\demo\esp32-level4-check.json -Required
.\scripts\check-esp32-serial-log.ps1 -LogPath .\sample-esp32.log -Required
```

Reads and checks ESP32 serial output for the HomeCue boot banner, button-route mode, Wi-Fi connection, and `/health` gateway probe. Add `-RequireInteraction` when capturing the Level 4 hardware loop so KEY1/BOOT, voice, or serial-test `/plan` and KEY2/serial-test `/execute` markers become required checks. Use `-AutoSerialLevel4` for unattended proof capture: it sends `homecue:plan N`, waits until `[/plan] proposed ...` appears, then sends `homecue:execute`. Use `-SendCommand` for lower-level manual command injection, `-SaveLogPath` to keep a local proof log, `-ResultJsonPath` to save structured OK/WARN check results, or `-LogPath` to verify a saved serial log without opening the port.
