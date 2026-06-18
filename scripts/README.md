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
```

Starts the API and Vite dev server when they are not already listening, runs the
desktop browser loop, then writes `assets/demo/full-loop-report.md`. Add
`-IncludeChrome` to verify an isolated Windows Chrome profile, and add
`-IncludePhone` to run the Android Chrome phone loop after the desktop loop when
an unlocked USB-debugging phone is connected. Before browser checks, the wrapper
verifies the running API can classify the default Chinese home-scene hint through
`/vision/scene`; when the port is occupied by an older managed uvicorn process,
it restarts that process and fails if the refreshed API still does not satisfy
the contract. Desktop and Windows Chrome loops write per-step screenshots to
ignored `assets/demo/*-screens/` folders and the report uses only the screenshot
paths recorded in the current JSON evidence.

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
