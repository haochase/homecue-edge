# Scripts

Local helper scripts for HomeCue Edge.

```powershell
.\scripts\scan-secrets.ps1 -All -IncludeUntracked
.\scripts\scan-secrets.ps1 -Staged
.\scripts\selftest-scan-secrets.ps1
```

Scans tracked files plus untracked, non-ignored working-tree files for
secret-shaped tokens and non-technical public-repo boundary violations. Use
`-Staged` for the pre-commit view of staged blobs. The self-test creates and
removes a temporary untracked marker file to prove `-IncludeUntracked` catches
new files before they are staged.

```powershell
.\scripts\check-local.ps1
```

Runs the public-repo scan, patch whitespace check, API dependency install,
Python compile, API tests, the firmware flow contract check, full-loop path
planning self-test, browser evidence dry-run planning self-test, computer-loop
and device-loop dry-run planning self-tests, then web dependency install, lint, and build. This
is the main local gate and mirrors CI for software checks while also catching
firmware contract drift.
The API pytest step uses a repo-local cache and basetemp under ignored
`assets/tmp/pytest/` so Windows temp-directory permissions do not pollute the
gate output.

```powershell
.\scripts\check-local.ps1 -SkipFirmware
```

Skips the static firmware contract check when you are validating only the API and web console.

```powershell
.\scripts\check-dev-env.ps1
.\scripts\check-dev-env.ps1 -Required -RequirePhone
.\scripts\selftest-dev-env.ps1
```

Runs a read-only development environment preflight. It checks Node/npm, required
API/web repo files, Windows Chrome, loop port state, optional ADB, and an
optional authorized Android device, then writes
`assets/tmp/dev-env-check.json`. The script does not start services, grant
permissions, or change ADB reverse/forward mappings. Add `-Required` to fail on
missing required desktop/browser items, and add `-RequirePhone` when phone-loop
hardware must be present. The self-test uses a missing ADB path to verify
optional-phone checks warn while required-phone checks fail and still write the
expected JSON contract.

```powershell
.\scripts\start-dev.ps1
```

Starts the FastAPI edge gateway on `http://127.0.0.1:8723` and the Vite web console on `http://127.0.0.1:5173`.

```powershell
.\scripts\check-full-loop.ps1
.\scripts\check-full-loop.ps1 -IncludePhone
.\scripts\check-full-loop.ps1 -IncludeChrome -IncludePhone
.\scripts\check-full-loop.ps1 -IncludeChrome -IncludePhone -StepTimeoutSeconds 180
.\scripts\check-full-loop.ps1 -IncludeChrome -IncludePhone -IncludeEsp32Serial -Esp32Port COM7 -Esp32SerialSeconds 45
.\scripts\check-full-loop.ps1 -DryRun
.\scripts\check-computer-loop.ps1
.\scripts\check-computer-loop-latest.ps1
.\scripts\check-computer-loop-latest.ps1 -SelfTest -MaxAgeMinutes 30
.\scripts\check-computer-loop.ps1 -ResultJsonPath .\assets\tmp\computer-loop-check-latest.json
.\scripts\check-computer-loop.ps1 -SelfTest
.\scripts\check-computer-loop.ps1 -DryRun
.\scripts\check-device-loop.ps1
.\scripts\check-device-loop-latest.ps1 -SelfTest -MaxAgeMinutes 30
.\scripts\check-device-loop.ps1 -DryRun
.\scripts\check-desktop-loop.ps1 -DryRun
.\scripts\check-chrome-loop.ps1 -DryRun
.\scripts\selftest-browser-wrapper-paths.ps1
.\scripts\selftest-computer-loop-plan.ps1
.\scripts\selftest-device-loop-plan.ps1
.\scripts\selftest-full-loop-path-plan.ps1
npm --prefix apps/web run computer:result:check -- ..\..\assets\tmp\computer-loop-check.json
npm --prefix apps/web run computer:result:check -- ..\..\assets\tmp\computer-loop-check-latest.json
npm --prefix apps/web run computer:result:check:latest -- --max-age-minutes 30
npm --prefix apps/web run computer:result:check:latest
npm --prefix apps/web run device:result:check -- ..\..\assets\tmp\device-loop-check.json
npm --prefix apps/web run device:result:check -- ..\..\assets\tmp\device-loop-check-latest.json
npm --prefix apps/web run device:result:check:latest -- --max-age-minutes 30
npm --prefix apps/web run device:result:check:latest
npm --prefix apps/web run result-validator-cli:selftest
npm --prefix apps/web run computer:result:selftest
npm --prefix apps/web run device:result:selftest
```

Use `check-computer-loop.ps1` for the highest-automation computer-side check
when no phone hardware is needed. It runs `check-full-loop.ps1 -IncludeChrome`
against bundled Chromium and installed Windows Chrome, writes isolated
computer-loop evidence under `assets/tmp/computer-loop/<run-id>/`, then
revalidates the saved desktop + Windows Chrome evidence through
`check-browser-evidence.ps1 -RequireDesktop -RequireChrome`. It also writes a
machine-readable `computer-loop-check.json` with the full-loop command, browser
evidence command, summary/report paths, and browser-evidence result JSON path.
That result also includes a compact `proofSummary` with the summary run id,
desktop/Windows Chrome pass flags, browser-parity status, screenshot counts,
source branch/commit/dirty state plus status-line count and status hash, Chinese
text-integrity counts (`required/missing/mojibake`), external execution source
and source mode, and the report/summary/browser-evidence paths plus raw
desktop/Chrome/phone/dev-env/web-readiness JSON and screenshot directories.
Computer-only runs record the skipped phone path as `__phone_not_run__.json`;
this proof is intentionally desktop + Chrome only and does not replace a
`-IncludePhone` capture or ESP32 serial hardware proof.
The desktop and Windows Chrome browser loops verify ESP32-style execution sync
through an API-simulated room-terminal event with
`sourceMode=api-simulated-room-terminal`; real ESP32 serial proof is only
claimed by `check-device-loop.ps1` / `check-esp32-serial-log.ps1` evidence.
`npm run computer:result:check` prints that compact proof line after validation
so a successful saved-result check is readable without manually opening the JSON;
the line includes `phone=not-run`, `phoneEvidence=__phone_not_run__.json`,
`source=branch@commit/dirty#statusCount:statusHash`,
`externalMode=api-simulated-room-terminal`, `devEnvEvidence=...`,
`webReadinessEvidence=...`, and the checked summary path.
The wrapper validates that result JSON before returning success. Use `-DryRun`
to inspect those paths and commands without starting services or opening
browsers. By default dry-run only prints the plan and does not overwrite the
stable `assets/tmp/computer-loop-check.json`; pass `-ResultJsonPath` when you
want a dry-run result JSON for automation. Add `--max-age-minutes N` to
`npm run computer:result:check`, or pass `-MaxAgeMinutes N` to
`check-computer-loop.ps1` / `check-computer-loop-latest.ps1`, when a demo or
handoff must prove the saved result was generated within the last N minutes.
The wrapper option is also forwarded into the nested browser-evidence recheck,
so the computer-loop result and its browser-evidence result record the same
freshness requirement. The default checker still accepts older saved evidence
when source state and manifests match.
`result-validator-cli:selftest` covers the shared saved-result checker CLI
parsing and freshness gate before the browser/computer result validators reuse
it.
`selftest-computer-loop-plan.ps1` covers that dry-run contract without
hardware, and `computer:result:selftest`
replays positive and negative result JSON cases so phone-only drift, missing
nested browser evidence, mismatched summary paths, missing computer-only
`expectedEvidence.phoneEvidence` sentinels, source-state drift, or embedded
browser-evidence content that differs from the referenced JSON file fail closed.
The result checker also reads the referenced summary JSON directly and verifies
desktop + Windows Chrome ran, phone did not run, browser parity passed,
`proofSummary` matches the referenced summary and browser-evidence result,
the desktop/Chrome external sync mode is explicitly API-simulated,
summary manifest paths match the browser-evidence plan, browser evidence carries
the `Web Readiness JSON` manifest path, top-level proof paths match the nested
browser evidence, and the skipped phone evidence sentinel matches across layers.
The referenced `Dev Environment JSON` and `Web Readiness JSON` raw files must
keep their narrow field sets and match the summary environment block. The raw
desktop/Windows Chrome JSON files must also share the summary run id and expected
browser roles. It also verifies that
`plan.outputs.resultJsonPath` is the file being checked and that the saved
command arguments still match the planned output paths, timeout options, and
browser-evidence gates. The saved plan must still point at
`scripts/check-full-loop.ps1` and `scripts/check-browser-evidence.ps1`, and the
saved plan and its nested option, output, gate, command, and expected-evidence
objects reject unknown fields. When `plan.options.maxAgeMinutes` is set, the
browser-evidence command must include the matching `-MaxAgeMinutes` argument,
and the embedded browser-evidence plan must record the same value. The top-level
result must contain exactly the ordered `computer full loop` and
`saved browser evidence recheck` entries with only their expected fields. The
embedded browser-evidence result, its nested plan, and its nested checks are
also treated as manifests: command order, names, required flags, allowed fields,
and optional self-test commands must match the computer-only plan. Failed
results keep the same narrow failure manifest. Keep
custom report, summary, and browser evidence result paths inside `-OutputDir`;
the result checker rejects split output roots.

Use `check-device-loop.ps1` for the highest-automation physical-device proof
when an Android handset and ESP32 hardware are connected. It delegates to
`check-full-loop.ps1 -IncludePhone -IncludeChrome -IncludeEsp32Serial
-IsolateEvidence`, writes isolated report, summary, browser JSON, ESP32 serial
log, and ESP32 result JSON under `assets/tmp/device-loop/<run-id>/`, then
revalidates saved desktop + phone + Windows Chrome evidence through
`check-browser-evidence.ps1 -RequireDesktop -RequirePhone -RequireChrome` and
revalidates the saved ESP32 serial log through
`check-esp32-serial-log.ps1 -LogPath ... -RequireInteraction -Required`. The
wrapper writes `assets/tmp/device-loop-check.json` by default; use
`check-device-loop-latest.ps1` to force the stable
`assets/tmp/device-loop-check-latest.json` path for a handoff or demo. The
compact `proofSummary` includes desktop, phone, Chrome, browser-parity,
front-camera, speech, text-integrity, screenshot, source-state, and ESP32
saved-log proof paths. The wrapper validates that saved result JSON before
returning success. `npm run device:result:check` verifies the full-loop command
still includes phone, Windows Chrome, ESP32 serial, and isolated evidence gates,
checks the referenced report/summary/browser-evidence files, compares embedded
browser evidence with the referenced JSON, requires phone evidence in the nested
browser proof, and rechecks both the live ESP32 serial result JSON and saved-log
result JSON against the captured serial log markers. Add `--max-age-minutes N`
to reject stale saved device-loop results during demos or handoffs.
`selftest-device-loop-plan.ps1` covers the dry-run contract without starting
browsers, ADB, or serial hardware, and `device:result:selftest` replays positive
and negative saved-result cases for source-state drift, missing device gates,
missing phone evidence, ESP32 serial failures, and missing serial log markers.

Starts the API and Vite dev server when they are not already listening, then
runs the requested desktop, phone, and Windows Chrome loops. Complete desktop +
phone + Windows Chrome runs write `assets/demo/full-loop-report.md` and the
machine-readable `assets/demo/full-loop-report.json` summary by default. Pass
`-IsolateEvidence` when a complete physical-device run should keep its report,
summary, desktop/phone/Chrome JSON, screenshots, preflight JSON, web-readiness
JSON, and ESP32 serial proof under the `-PartialEvidenceDir` run folder instead
of overwriting demo artifacts. Partial runs, including desktop-only or
Chrome-only smoke checks, default to an ignored per-run folder under
`assets/tmp/full-loop-partial/<run-id>/`. Add
`-IncludeChrome` to verify an isolated Windows Chrome profile, and add
`-IncludePhone` to run the Android Chrome phone loop after the desktop loop when
an unlocked USB-debugging phone is connected; the phone wrapper closes old
HomeCue/local test tabs from previous runs before opening the current target
and then validates the raw phone JSON with `npm run phone:evidence:check`.
The full-loop wrapper runs `check-dev-env.ps1 -Required` before starting browser
automation, and adds `-RequirePhone` when `-IncludePhone` is set. Use
`-SkipPreflight` only when an equivalent preflight has already verified the
current host, browser, and phone state. The generated JSON summary includes the
preflight result and validates the raw `assets/tmp/dev-env-check.json` manifest
entry, so host/browser/ADB readiness is retained with the loop evidence.
That phone evidence gate requires front-camera `facingMode=user`, Chinese text
integrity, speech readiness, scene privacy non-retention, clean runtime health,
and ESP32-style execution sync before the phone loop is accepted.
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
Skipped desktop or Chrome screenshot directories also use explicit
`__*_screens_not_run__` sentinels for the same reason.
Partial runs also isolate their default report, summary, preflight JSON, loop
JSON, and screenshot files under the same per-run temp directory.
Relative wrapper paths, including direct desktop/Chrome `-OutputPath` and
`-ScreenshotDir` values plus full-loop `-ReportPath` and `-SummaryPath` values,
are resolved from the repository root. Use `-StepTimeoutSeconds` to bound each
browser or phone child loop and clean up its process tree if device automation
hangs.
Direct desktop and Chrome wrappers also share a named local mutex around the
API-mutating loop steps, with `-SharedStateLockTimeoutSeconds` controlling how
long a second wrapper waits before failing. This keeps accidental parallel
starts from racing `/execute` and `/execution/latest` state.
Use `-DryRun` to print the planned paths, sentinels, and self-test gates as JSON
without starting services or touching ADB/Chrome. The
`selftest-full-loop-path-plan.ps1` script exercises that dry-run mode for
desktop-only, complete desktop + phone + Chrome, Chrome-only skip-preflight, and
custom report/summary paths; `selftest-browser-wrapper-paths.ps1` verifies the
direct desktop/Chrome wrapper output and screenshot path contracts without
hardware.
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
browser JSON evidence. The summary JSON is also treated as a strict manifest:
top-level, environment, loop, browser-parity, and evidence entry objects reject
unknown fields so stale side-channel proof cannot silently ride along with a
passing summary. Raw preflight and web-readiness JSON evidence must keep the
same narrow field sets when they are referenced by the manifest; the saved
browser/computer result checkers repeat those raw environment checks so a final
result recheck does not depend only on a prior `summary:check` run.
Run `npm run summary:selftest` from `apps/web` after a successful full-loop run
to replay the validator against generated bad summaries under ignored
`assets/tmp/`, including summary and raw environment field-boundary regressions.
The full-loop wrapper runs that self-test automatically after `summary:check`
when `-IncludeChrome` is set. `npm run report:selftest` replays the report
generator against generated bad phone JSON so weak front-camera proof cannot be
summarized as a passing report; the full-loop wrapper runs it only for a
complete desktop + phone + Windows Chrome evidence run. The
`desktop:evidence:selftest` command replays the raw desktop/Chrome evidence
validator against generated bad loop JSON, including root/checks field-boundary
regressions; `-IncludeChrome` also runs it automatically. The
`phone:evidence:selftest` command replays the phone raw
evidence validator against generated bad phone JSON for front-camera,
localized-text, and ESP32-sync regressions; `-IncludePhone` runs it
automatically.
Use `npm run summary:selftest -- <summary-json>` to target an isolated partial
or computer-loop summary instead of the default demo summary.

Add `-IncludeEsp32Serial` only when the ESP32-S3-AUDIO-Board is physically
connected and the board's `PC_HOST` points at this PC's LAN IPv4. The wrapper
first ensures the FastAPI gateway is reachable from the LAN; if an existing
managed uvicorn process is only bound to `127.0.0.1`, it restarts that process
on `0.0.0.0:8723` before running the hardware gate. It then runs
`check-firmware-flow.ps1 -Required` and
`check-esp32-serial-log.ps1 -AutoSerialLevel4 -RequireInteraction -Required`.
The serial gate sends `homecue:plan N`, waits for a `/plan` proposal, sends
`homecue:execute`, and saves the proof log plus result JSON under the full-loop
run directory. Without `-IncludeEsp32Serial`, the dry-run plan records explicit
`__esp32_serial_not_run__` sentinels so hardware proof cannot be implied by
browser evidence.

```powershell
.\scripts\check-browser-evidence.ps1
.\scripts\check-browser-evidence.ps1 -RequireDesktop
.\scripts\check-browser-evidence.ps1 -RequireChrome -RequirePhone
.\scripts\check-browser-evidence.ps1 -RequireChrome -RequirePhone -SelfTest
.\scripts\check-browser-evidence.ps1 -DryRun
.\scripts\check-browser-evidence.ps1 -RequireDesktop -RequireChrome -RequirePhone -ResultJsonPath .\assets\tmp\browser-evidence-check.json
.\scripts\check-browser-evidence.ps1 -RequireDesktop -RequireChrome -ResultJsonPath .\assets\tmp\browser-evidence-check.json -MaxAgeMinutes 30
.\scripts\selftest-browser-evidence-plan.ps1
npm --prefix apps/web run browser:evidence-result:check -- ..\..\assets\tmp\browser-evidence-check.json
npm --prefix apps/web run browser:evidence-result:check -- ..\..\assets\tmp\browser-evidence-check.json --max-age-minutes 30
npm --prefix apps/web run result-validator-cli:selftest
npm --prefix apps/web run browser:evidence-result:selftest
```

Revalidates existing desktop, Windows Chrome, Android Chrome phone, and
full-loop summary evidence without starting services, opening browsers, changing
ADB state, or touching the ESP32. Use it after a complete full-loop capture to
prove the saved JSON and screenshot artifacts still satisfy the browser
contracts. By default the script reads `assets/demo/full-loop-report.json` and
infers whether phone, Windows Chrome, or desktop evidence is required from that
summary. Because the default demo summary can reference a mutable local
`assets/tmp/dev-env-check.json`, the default path is first copied to an ignored
self-contained snapshot under `assets/tmp/browser-evidence-default-summary/`;
explicit `-SummaryPath` values remain strict and are not rewritten. It also
resolves JSON evidence paths and screenshot directories from
the summary evidence manifest, falling back to `assets/demo` defaults only when
the manifest does not include them. If the manifest lists the browser JSON but
not screenshots, the script reads that raw JSON to infer its screenshot
directory. If `-RequirePhone`, `-RequireChrome`, or a required desktop loop
contradicts the saved summary, the script fails before falling back to any
default demo artifact. When a loop is not required, the dry-run and saved result
use explicit `__*_not_run__` JSON and screenshot-directory sentinels instead of
pointing at previous demo artifacts. Add `-SelfTest` to also replay the evidence
validator self-tests against generated bad artifacts under ignored `assets/tmp/`. Use
`-DryRun` to print the inferred evidence and self-test plan as JSON without
reading screenshot directories or running npm validators. Add `-ResultJsonPath`
to save a machine-readable validation result with the inferred plan and executed
check commands for CI, local automation, or demo handoff notes. The browser
evidence result checker revalidates that saved JSON against the referenced
summary, required evidence, screenshot directories, loop success flags, browser
parity, web readiness, source branch/commit/worktree status, raw desktop/Windows
Chrome run ids, browser roles, and self-test gates without opening browsers. It
also treats the saved `checks` array as a manifest: required entries, names,
command order, required flags, allowed fields, and optional self-test commands
must match the inferred plan. In validate mode it also prints a
compact `Browser evidence proof summary` line with loop status, browser parity,
web-readiness strategy, source state, screenshot counts, self-test state,
external execution source, and the summary path. The source field includes the
branch, short commit, dirty state, status-line count, and status hash. Pass
`-MaxAgeMinutes N` to the wrapper when it writes a result JSON that must be
fresh, or add `--max-age-minutes N` when rechecking an existing saved
browser-evidence result before a live demo or handoff.
`result-validator-cli:selftest` covers the shared saved-result checker CLI
parsing and freshness gate used by both the browser-evidence and computer-loop
result checkers.
`selftest-browser-evidence-plan.ps1` uses that dry-run mode to verify complete,
desktop-only, Chrome-only, manifest-path, raw-JSON screenshot fallback, and
explicit override planning without hardware.

```powershell
.\scripts\check-chrome-loop.ps1
.\scripts\check-chrome-loop.ps1 -OutputPath .\assets\tmp\chrome-loop.json -ScreenshotDir .\assets\tmp\chrome-screens
```

Runs the desktop browser loop against the installed Windows Chrome executable
with an isolated temporary profile under `assets/tmp`, then validates the raw
loop JSON and screenshot evidence. Relative output and screenshot paths are
resolved from the repository root, and direct desktop/Chrome wrapper runs queue
on the shared browser-loop lock if another wrapper is already mutating API
execution state. Standalone wrapper runs stamp raw evidence with a generated
`desktop-loop-*` or `chrome-loop-*` run id; full-loop invocations still inherit
the shared full-loop run id. Raw loop and summary JSON is emitted as
ASCII-safe JSON, so Windows PowerShell can parse it with
`Get-Content -Raw | ConvertFrom-Json` while UTF-8 JSON readers still recover
the original Chinese labels after parsing.

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
.\scripts\selftest-esp32-serial-result-json.ps1
```

Reads and checks ESP32 serial output for the HomeCue boot banner, button-route mode, Wi-Fi connection, and `/health` gateway probe. Add `-RequireInteraction` when capturing the Level 4 hardware loop so KEY1/BOOT, voice, or serial-test `/plan` and KEY2/serial-test `/execute` markers become required checks. Use `-AutoSerialLevel4` for unattended proof capture: it sends `homecue:plan N`, waits until `[/plan] proposed ...` appears, then sends `homecue:execute`. Use `-SendCommand` for lower-level manual command injection, `-SaveLogPath` to keep a local proof log, `-ResultJsonPath` to save structured OK/WARN check results, or `-LogPath` to verify a saved serial log without opening the port.
Saved ESP32 result JSON is written as UTF-8 without BOM and with non-ASCII text
escaped so downstream public proof validators can treat it as an ASCII-safe
machine artifact. `selftest-esp32-serial-result-json.ps1` checks that contract
without opening the serial port by validating a saved sample log.
