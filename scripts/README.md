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
.\scripts\start-software-demo.ps1 -FreshState
```

Starts the same local services with a deterministic, cloud-independent demo
profile. It disables `.env` loading for the child API process, uses the mock
planner, Windows TTS, disabled ASR, and an isolated SQLite database under
`.runtime\software-demo`. Use `-FreshState` before a rehearsal to clear only
that demo database. The normal `start-dev.ps1` behavior is unchanged.

```powershell
.\scripts\test-software-demo-profile.ps1
```

Checks the software demo profile contract without starting services or deleting
state. This check is also part of `check-local.ps1`.

```powershell
.\scripts\deploy-api-ubuntu.ps1 -Remote edge-host -RemoteDir '~/homecue-edge-api' -Port 8723 -PipIndexUrl https://pypi.tuna.tsinghua.edu.cn/simple
```

Deploys `apps/api` to an Ubuntu LAN host over SSH, installs/reuses a remote
virtualenv, uploads `apps/api/.env` without printing secrets, writes a user-level
systemd service, and restarts it on `0.0.0.0:<Port>`. The deployed env forces
SQLite memory and generated voice audio into the remote `data` directory. After
restart, the script verifies `/health` and `/voice-chat/status` from the remote
host. If `VOICE_CHAT_ACCESS_TOKEN` is present in the uploaded env, verification
uses it as a bearer token without printing the value. Use
`-VerifyResultJsonPath` to save the verification JSON, `-VerifyBaseUrl` to check
a LAN/tunnel URL instead of `127.0.0.1`, or `-SkipVerify` for package-only
deploys. The 2026-06-16 LAN proof used `edge-host` at
`http://192.0.2.101:8723`.

```powershell
.\scripts\verify-qwen.ps1
```

Runs the configured OpenAI-compatible planner path against the active provider and prints a verification result. Requires a valid key in `apps/api/.env`.

```powershell
.\scripts\check-voice-system-readiness.ps1 -ApiBase http://127.0.0.1:8723 -Required
.\scripts\check-voice-system-readiness.ps1 -ApiBase http://127.0.0.1:8723 -UbuntuApiBase http://192.0.2.101:8723
```

Checks the local voice-chat runtime without requiring ESP32 hardware. It
verifies `/health`, `/voice-chat/status`, a MiMo text turn, the text
`/voice-chat/ws` protocol using `user_id=home-user` and
`device_id=readiness-script`, a binary `pcm_s16le` WebSocket turn generated
from Windows TTS, a MiMo TTS WebSocket binary-stream downlink, SQLite
memory/task/mood extraction, and `/voice-chat/tasks/due-audio` with MiMo TTS
metadata. This is the fastest way to prove the API, MiMo dialogue, MiMo TTS
voice, Windows ASR availability, SQLite state, WebSocket identity echo,
upstream binary PCM framing, and downstream TTS audio framing before retrying
board-speaker tests. It does not prove physical ESP32 speaker audibility.

```powershell
.\scripts\check-companion-available-hardware.ps1 -Required
.\scripts\check-companion-available-hardware.ps1 -SkipEsp32 -Required
.\scripts\check-companion-available-hardware.ps1 -GrantChromeMediaPermissions -Required
```

Runs the low-cost companion hardware loop currently available on one PC, one
USB-connected Android phone, and one ESP32 board. It verifies local API/Web
health, opens the phone Chrome app through ADB, checks the main HomeCue UI,
checks `phone-probe.html` for secure context, API access through `adb reverse`,
microphone access, and camera access, then runs the ESP32 `AutoSerialLevel4`
guarded plan/execute proof and snapshots `/devices`. Use `-SkipEsp32` for a
fast phone/browser/API permission check. Use `-GrantChromeMediaPermissions`
only when the test phone Chrome has not already been granted Android
microphone/camera runtime permissions. The script does not inspect or save
unrelated Chrome tabs.

```powershell
.\scripts\check-proof-readiness.ps1
.\scripts\check-proof-readiness.ps1 -SkipPortProbe -ResultJsonPath $env:TEMP\homecue-proof-readiness.json
.\scripts\check-proof-readiness.ps1 -ResultJsonPath $env:TEMP\homecue-proof-readiness.json -ResultMarkdownPath $env:TEMP\homecue-proof-readiness.md
.\scripts\check-proof-readiness.ps1 -ResultJsonPath $env:TEMP\homecue-proof-readiness.json -ResultMarkdownPath $env:TEMP\homecue-proof-readiness.md -FailOnBlockingGaps
.\scripts\check-proof-readiness.ps1 -SkipSecretScan -SkipPortProbe -SkipProofInventory
.\scripts\check-readiness-schema.ps1 -ReadinessJsonPath $env:TEMP\homecue-proof-readiness.json -Required
.\scripts\check-readiness-regression.ps1 -Required
.\scripts\check-release-gate-snapshot.ps1 -IntentJsonPath $env:TEMP\homecue-working-tree-intent.json -ProofInventoryJsonPath $env:TEMP\homecue-proof-inventory.json -ReadinessJsonPath $env:TEMP\homecue-proof-readiness.json -PortStateJsonPath $env:TEMP\homecue-esp32-port.json -PortSchemaJsonPath $env:TEMP\homecue-esp32-port-schema.json -ResultJsonPath $env:TEMP\homecue-release-gate-snapshot.json -Required
.\scripts\check-release-gate-snapshot-schema.ps1 -ReleaseSnapshotJsonPath $env:TEMP\homecue-release-gate-snapshot.json -ReleaseSnapshotMarkdownPath $env:TEMP\homecue-release-gate-snapshot.md -Required
```

Summarizes the local release proof state without reading secrets: Git clean/sync status, the all-files plus untracked privacy scan result, public `.env.example` safety, working-tree intent classification, proof inventory summary, Qwen verification JSON, Alibaba usage image directory, ESP32 Level 4 proof JSON, the older generated readiness snapshot, and the current ESP32 port state. The public env example check verifies required API/TTS example keys are present while key/token fields stay blank and no local filesystem paths or token-shaped values are exposed. The working-tree intent check verifies dirty files are assigned to known review buckets before staging. The proof inventory summary records local voice/media evidence status and the `xiaoqian` wake-model gap inside readiness JSON while keeping Alibaba usage images as the external cloud proof blocker. The result JSON also includes `evidence.releaseGaps`, `evidence.releaseGapSummary`, `evidence.gateOutcome`, and `evidence.nextActions`, so a submission/release review can distinguish blocking cloud/repository gaps from non-blocking hardware voice follow-ups, quickly count remaining blockers, and see the current gate mode's expected exit code. The top-level JSON also repeats `gateOutcome` for automation clients. The script intentionally reports warnings when release evidence is missing or stale; add `-Required` only for a final blocking gate. Use `-SkipSecretScan`, `-SkipWorkingTreeIntent`, or `-SkipProofInventory` only when you are debugging unrelated proof checks and have already run the skipped gate separately.

Add `-ResultMarkdownPath` when you need a human-readable action report for a release review. The Markdown report mirrors the same evidence snapshot, release gap summary, release gaps, and check list as the JSON output; it is a report artifact, not proof by itself.

Add `-FailOnBlockingGaps` only when a final release or submission gate should fail with a non-zero exit code while `evidence.releaseGapSummary.blockingCount` is greater than zero. Normal hourly readiness checks should usually omit it so the script can report blockers without interrupting other review work.

Read `gateOutcome.status`, `gateOutcome.reason`, and `gateOutcome.expectedExitCode` when another script needs to know how the current run mode should behave: default not-ready checks report `warn` with expected exit code `0`, `-Required` failures report expected exit code `1`, and `-FailOnBlockingGaps` failures report expected exit code `2`. This field is a gate result summary, not a proof artifact.

Run only one readiness check with port probing at a time. The ESP32 serial port is exclusive; if you compare normal and strict modes in one session, run them sequentially or add `-SkipPortProbe` to the second command.
When `-SkipPortProbe` is set, readiness does not add an `esp32-port` release gap; run `check-esp32-port-state.ps1` separately if the current serial-port state matters for a hardware proof.

Run `check-readiness-schema.ps1` against a generated readiness JSON when changing readiness output fields. It verifies that top-level `gateOutcome`, `evidence.gateOutcome`, `readyForRelease`, `releaseGaps`, `releaseGapSummary`, and `nextActions` stay internally consistent, including the expected exit code implied by the current gate reason. It also checks that blocking/follow-up IDs in the summary match the detailed `releaseGaps`, and that `gateOutcome.blockingGapIds` matches the release gap summary.

Run `check-readiness-regression.ps1` when changing readiness gate behavior. It sequentially runs default readiness, strict readiness, and the schema checker for both outputs, then verifies each readiness process exits with `gateOutcome.expectedExitCode`. It also checks that default and strict runs report the same release gap summary and that default/strict mode semantics stay distinct: report-only checks keep blocking gaps as `warn/0`, while strict release gates turn the same blocking gaps into `fail/2`. It skips ESP32 port probing by default so default/strict comparisons do not contend for the serial port; add `-ProbePort` only when the current hardware-port state is part of the regression you want to inspect.

Run `check-release-gate-snapshot.ps1` after the separate intent, proof, readiness, port, and port-schema checks have already written JSON files. It only reads those files and writes one machine-readable release snapshot with `repo`, `proof`, `readiness`, `hardware`, `readyForSubmit`, `blockers`, and `operationalBlockers` sections. The `proof` section includes Alibaba usage image count plus candidate count, valid-image name/length details, invalid-image count, invalid-image name/length/reason details, minimum bytes, signature-required status, and Alibaba manual content-review status so report readers can see which files clear the local image-file gate and whether a human has confirmed the required visible/masked fields. `blockers` tracks release/submission blockers such as dirty worktree, missing Alibaba proof, or missing Alibaba manual proof review; `operationalBlockers` tracks current-run follow-ups such as a missing ESP32 serial port that prevents fresh hardware proof. This is an aggregation artifact for reports and submission review; it does not scan secrets, open serial ports, or replace any underlying proof check.

Run `check-release-gate-snapshot-schema.ps1` against a generated release snapshot JSON, optionally with its Markdown report. It verifies the snapshot keeps `readyForSubmit`, release blockers, operational blockers, next actions, repo/proof/readiness/hardware sections, Alibaba valid/invalid image detail sets, Alibaba manual content-review status, proof signal status values (`OK` / `WARN`), `proof.readyForExternalRelease` derivation, `readiness.readyForRelease` derivation from blocking gaps, readiness blocking/follow-up gap counts and IDs, and Markdown report sections consistent. It is a read-only contract check over report artifacts and does not scan secrets, open serial ports, or call the network.

```powershell
.\scripts\check-proof-inventory.ps1
.\scripts\check-proof-inventory.ps1 -ResultJsonPath $env:TEMP\homecue-proof-inventory.json
```

Builds a read-only inventory of local proof files under `assets\demo`: Qwen verification, Alibaba usage images, Alibaba manual content review, ESP32 Level 4 guarded execute proof, WebSocket voice-chat protocol proof, ESP32 board voice-chat speaker proof, ESP32 board WebSocket voice-chat proof, `xiaoqian` wake-model proof, submission gallery upload assets, and the local video upload asset. Alibaba usage image candidates must use a supported image extension, be at least 1024 bytes, and match the PNG/JPEG/WebP file signature; valid and invalid image details are emitted separately for release snapshot reports. `readyForExternalRelease` requires Qwen proof, at least one valid Alibaba proof image, and `assets\demo\alibaba-proof\alibaba-proof-review.json` confirming the saved image shows Qwen/DashScope, non-zero usage, date/range, region cue, and masked private details. It makes the evidence boundary explicit: local voice/media proof can strengthen the project story, but it does not replace cloud usage image proof; a syntactically valid image alone also does not replace human content review.

```powershell
.\scripts\prepare-alibaba-proof-intake.ps1
.\scripts\prepare-alibaba-proof-intake.ps1 -ResultJsonPath $env:TEMP\homecue-alibaba-proof-intake.json -ResultMarkdownPath $env:TEMP\homecue-alibaba-proof-intake.md -Required
```

Creates the gitignored `assets\demo\alibaba-proof` drop folder and writes a local intake guide plus `alibaba-proof-review.template.local.json` there without creating placeholder screenshots. Use it before a manual Alibaba Cloud / Model Studio capture session so the required visible fields, privacy masking rules, accepted image extensions, manual review marker, and post-capture verification commands are available next to the proof folder. It is an intake helper only; `check-proof-inventory.ps1`, strict proof readiness, and release snapshot checks still decide whether the saved images and review marker are usable.

```powershell
.\scripts\check-working-tree-intent.ps1
.\scripts\check-working-tree-intent.ps1 -ResultJsonPath $env:TEMP\homecue-working-tree-intent.json
```

Groups the current dirty working tree into review buckets before staging or committing. This is a read-only helper for the public repo boundary: it separates ESP32 voice/recovery tooling, voice-chat runtime helpers including board WebSocket voice-chat tests, proof readiness scripts, safety files, app code, release docs, and local proof evidence, then flags anything that needs manual classification. Public `.example` templates such as `firmware/esp32-audio/secrets.h.example` are allowed when they contain placeholder values only; this does not replace `scan-secrets.ps1`, so run both before any commit.

```powershell
.\scripts\scan-secrets.ps1 -All -IncludeUntracked
.\scripts\scan-secrets.ps1 -All -IncludeUntracked -ResultJsonPath $env:TEMP\homecue-secret-scan.json
.\scripts\scan-secrets.ps1 -Staged
```

Scans public-repo content for secret-shaped tokens and private/non-technical keywords. `-All -IncludeUntracked` is the pre-staging safety pass for newly created scripts or docs; `-Staged` is the final commit gate and is what the sample pre-commit hook runs. Add `-ResultJsonPath` when another script or final readiness checklist needs a machine-readable clean/finding count. The default `-All` mode scans tracked files only.

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
.\scripts\flash-esp32.ps1 -Port COM7 -Clean -EnableEspSr
.\scripts\flash-esp32.ps1 -Port COM7 -Upload -EnableEspSr -UploadSpeed 115200 -UploadMode cdc
.\scripts\flash-esp32.ps1 -Port COM7 -EnableEspSr -EspSrWakeKeyword xiaoqian -EspSrModelsBin .\path\to\srmodels.bin
.\scripts\flash-esp32.ps1 -Port COM7 -Upload -EnableEspSr -ApiHostOverride 192.0.2.101 -ApiPortOverride 8723
.\scripts\flash-esp32.ps1 -Port COM7 -EnableEspSr -ApiHostOverride 192.0.2.101 -ApiPortOverride 8723 -VoiceChatAccessTokenOverride dev-token
```

Compiles the ESP32-S3 firmware with the HomeCue board options (`16MB` flash, `OPI PSRAM`, USB CDC enabled). The first command only builds; the second uploads the latest build to the board. Use `-EnableEspSr` to compile the optional ESP-SR/ES7210 voice route with `-DENABLE_ESP_SR=1`; this still requires the local ESP-SR library/model setup and should be treated as an explicit voice-path validation, not the default demo path. `-UploadMode cdc` enables the Arduino ESP32-S3 1200bps USB CDC upload path when the board needs CDC-style re-enumeration. If `arduino-cli` is not on `PATH`, the script also checks the local portable CLI at `%USERPROFILE%\.codex\tools\arduino-cli\arduino-cli.exe`.

Use `-ApiHostOverride` and `-ApiPortOverride` to patch only the temporary build
copy of `secrets.h`. This is the preferred way to point a proof firmware at an
Ubuntu/LAN backend without editing or committing local secrets.
Use `-VoiceChatAccessTokenOverride` the same way when the backend has
`VOICE_CHAT_ACCESS_TOKEN` set; the script prints only `Voice token: configured`
and does not echo the token value.

`-EnableEspSr` builds from an isolated temp sketch with `build_opt.h`, selects the `esp_sr_16` partition scheme, and requires `srmodels.bin` in the build output so upload can write the model partition.

Use `-EspSrWakeKeyword` and `-EspSrModelsBin` only when you have a matching custom ESP-SR model image. The helper copies the Arduino `ESP_SR` library into a temp sketch-local `libraries` folder, patches its WakeNet filter keyword there, and leaves the global Arduino package untouched. It then refuses to continue if the final `srmodels.bin` does not contain the requested wake keyword, so `-EspSrWakeKeyword xiaoqian` is currently expected to fail with the stock arduino-esp32 3.0.7 model image.

The helper also refuses known unsafe model images by default. `wn9s_nihaoxiaozhi` is blocked because hardware testing showed repeated ESP-SR `LoadProhibited` panics and USB-CDC enumeration loss. Use `-AllowBlockedEspSrModel` only for a deliberate recovery-aware experiment.

```powershell
.\scripts\new-esp32-sr-model-pack.ps1 -Required
.\scripts\new-esp32-sr-model-pack.ps1 -WakeModelName wn9_nihaoxiaozhi -MultiNetModelName mn5q8_en -OutputPath $env:TEMP\homecue-srmodels-nihaoxiaozhi-en.bin -Required
```

Creates a custom `srmodels.bin` from a downloaded ESP-SR component tree. By default it looks for `%TEMP%\esp-sr-2.4.6-component\esp-sr`, packs the known-good `wn9_nihaoxiaozhi + mn5q8_en` combination, and blocks known unsafe model names unless `-AllowBlockedModel` is explicitly supplied.

```powershell
.\scripts\read-esp32-serial.ps1 -Port COM7 -Seconds 8
.\scripts\read-esp32-serial.ps1 -Port COM7 -Seconds 45 -SendCommand "homecue:plan 0","homecue:execute" -SendAfterSeconds 18
.\scripts\read-esp32-serial.ps1 -Port COM7 -Seconds 45 -SendCommand "homecue:reminders" -SendAfterSeconds 5
```

Reads a short 115200-baud serial log from the board after upload. Close Arduino IDE Serial Monitor first so the script can open the port. Use `-SendCommand` to exercise the firmware's serial test route (`homecue:plan 0`, `homecue:execute`, `homecue:reject`) without pressing physical keys. Use `-SkipReset` when you want to capture an already-running interaction window.
`homecue:reminders` polls `/voice-chat/tasks/due-audio`, downloads the returned
WAV reply audio when a task is due, and plays the reminder through the board
speaker.

```powershell
.\scripts\check-esp32-port-state.ps1 -Port COM7 -Required
.\scripts\check-esp32-port-state.ps1 -Port COM7 -ResultJsonPath .\assets\demo\esp32-port-state.json
.\scripts\check-esp32-port-state.ps1 -Port COM7 -ResultJsonPath .\assets\demo\esp32-port-state.json -ResultMarkdownPath .\assets\demo\esp32-port-state.md
.\scripts\check-esp32-port-state.ps1 -Port COM7 -AutoDetectEsp32 -ResultJsonPath .\assets\demo\esp32-port-state.json
.\scripts\check-esp32-port-report-schema.ps1 -PortStateJsonPath .\assets\demo\esp32-port-state.json -PortStateMarkdownPath .\assets\demo\esp32-port-state.md -Required
```

Checks whether the ESP32 serial port is detected, openable, and writable before you spend time on upload or proof capture. The known hung-board state is `state=hung`: COM7 opens but a one-byte write times out. The script also reports matching Windows USB problem devices; `state=usb-error` means Windows sees an ESP32-like or unknown USB node, such as Code 43 device descriptor failure, but no serial COM port. That state usually needs a USB power-cycle, BOOT+RESET ROM download-mode recovery, cable/port change, or device-manager recovery before upload/test commands can succeed. Use `-SkipWriteProbe` only when you want a non-invasive open-only check.
Use `-AutoDetectEsp32` when Windows may re-enumerate the board onto a different COM port after reset; the script scores USB serial / Espressif / ESP32 candidates and deliberately downranks Bluetooth COM ports.
Use `-ResultMarkdownPath` when the current port state needs to be attached to a human recovery note or submission-readiness report. The Markdown report mirrors the JSON state, detected ports, check table, USB problem devices, and next action; it is a diagnostic report, not a replacement for a successful hardware proof.
Run `check-esp32-port-report-schema.ps1` after changing the port report format. It is a read-only contract check over an already generated JSON/Markdown pair and does not open the serial port. The checker verifies the selected/requested port, state, hint, required sections, and check rows stay consistent across both outputs.

```powershell
.\scripts\resume-esp32-speaker-audible-test.ps1 -Port COM7 -AutoDetectEsp32 -MaxWaitSeconds 900 -ApiHostOverride 192.0.2.118 -ApiPortOverride 8723 -Required
.\scripts\resume-esp32-speaker-audible-test.ps1 -Port COM7 -AutoDetectEsp32 -MaxWaitSeconds 0 -SkipUpload -SkipTone -OutputPrefix .\assets\demo\esp32-speaker-audible-recheck-auto-dry
```

Waits for the ESP32 serial port to become writable, then flashes the current
ESP-SR speaker diagnostic firmware and runs
`test-esp32-speaker-tone.ps1 -ToneMode all`. It writes a summary JSON, the last
port-state JSON, and the tone-test log/check files under the chosen
`-OutputPrefix`. Use it after a physical USB reset so the next available ESP32
serial window immediately continues the board-speaker audible-output proof. Even when
the script completes, a human still has to confirm whether the physical speaker
was audible.

By default the flashed diagnostic firmware also enables a boot-time speaker
test (`-BootSpeakerTest` in `flash-esp32.ps1`), so the board plays the same
strong tone immediately after boot before the serial command test runs. Pass
`-NoBootSpeakerTest` to the resume script when you need a quiet diagnostic
build.

The same diagnostic build also enables a tiny HTTP server on the ESP32. Once
the board is on Wi-Fi, trigger the local tone without USB serial:

```powershell
.\scripts\test-esp32-speaker-http-tone.ps1 -BoardBaseUrl http://192.0.2.100 -Seconds 8 -ToneMode all -Required
.\scripts\test-esp32-speaker-http-tone.ps1 -Seconds 8 -ToneMode all
```

If `-BoardBaseUrl` is omitted, the script tries to infer the most recent ESP32
IP from the local API log. The firmware endpoints are `GET /health` and
`GET /speaker-test?seconds=8&mode=all`.

```powershell
.\scripts\test-esp32-speaker-network-due-audio.ps1 -ApiBase http://127.0.0.1:8723 -WaitSeconds 75 -Required
.\scripts\test-esp32-speaker-network-due-audio.ps1 -ApiBase http://127.0.0.1:8734 -WaitSeconds 75 -ResultJsonPath .\assets\demo\esp32-speaker-network-due-audio-8734.json
```

Creates an immediate due-audio reminder and watches the API log for an ESP32
client requesting `/voice-chat/tasks/due-audio` and the generated WAV. This is
a no-serial fallback check: if the board is still alive on Wi-Fi, it can trigger
MiMo TTS playback through the reminder auto-poll path. It cannot see serial
speaker markers, so it is a reachability/acoustic smoke test rather than a
replacement for the serial tone proof. When `-ApiLogPath` is omitted, the script
infers the most likely API log from `-ApiBase`, for example
`assets/demo/api-8734-after-reset-current.out.log` for port `8734`.

```powershell
.\scripts\check-esp32-sr-models.ps1 -RequiredWakeKeyword hiesp -RequiredMultinetKeyword english -Required
.\scripts\check-esp32-sr-models.ps1 -RequiredWakeKeyword xiaoqian -RequiredMultinetKeyword english -ResultJsonPath .\assets\demo\esp32-sr-models-xiaoqian-check.json
```

Inspects the local ESP-SR `srmodels.bin` copied by arduino-esp32. It does not flash hardware; it reads the model image and reports whether expected wake/multinet keywords are present. Use it before trying to switch wake words, because the current arduino-esp32 3.0.7 model image contains `hiesp` plus English MultiNet, but does not contain `xiaoqian`, `nihaoxiaozhi`, or `nihaoxiaoxin`. It also fails required checks when a known blocked model such as `wn9s_nihaoxiaozhi` is present, unless `-AllowBlockedModel` is supplied.

```powershell
.\scripts\test-esp32-sr-audio.ps1 -Port COM7 -Seconds 100 -Required
.\scripts\test-esp32-sr-audio.ps1 -LogPath .\scripts\sample-esp32-sr-audio.log -ExpectedCommandLabel "I'm home" -ExpectedActionCount 5 -ExpectedExecutionCount 3 -Required -ResultJsonPath $env:TEMP\homecue-sr-audio-sample.json
.\scripts\test-esp32-sr-audio.ps1 -LogPath .\scripts\sample-esp32-sr-reject.log -ExpectedCommandLabel "I'm home" -ExpectedActionCount 5 -ExpectedRejectCount 1 -Required -ResultJsonPath $env:TEMP\homecue-sr-audio-reject-sample.json
```

Runs the ESP-SR speaker-loop test: starts Windows TTS on the default audio device, plays wake-word and command phrase variants, captures serial output, saves markers/logs under `assets\demo`, and checks for ESP-SR ready, wake detection, command recognition, and propose-only `/plan` markers. This requires the ESP-SR firmware and model partition to already be flashed. Use `-LogPath` to replay a saved serial log without opening COM7 or playing audio; the sample log verifies the checker contract only and is not a real proof capture.

Pass `-ExpectedCommandLabel "I'm home"` when a proof should fail unless the recognized command label matches the intended fixed phrase. Leave it empty for generic voice-route smoke checks.

Pass `-ExpectedExecutionCount 3` when a proof should also show the confirmed `/execute` path accepted at least three device actions after the voice-triggered proposal. When this is set, the checker also requires the first `[voice] command`, `[/plan] proposed ...`, `[key] CONFIRM` or `[serial] CONFIRM`, and accepted `exec` markers to appear in that order, so a saved proof cannot skip the proposal or human-in-the-loop steps. Leave it at the default `0` when validating only voice-to-plan recognition.

Pass `-ExpectedRejectCount 1` when a proof should show the negative path: voice command, proposal, then `[key] REJECT` or `[serial] REJECT`, with no accepted `exec` marker after the reject marker. This covers the misfire recovery contract and proves a user rejection discards the staged proposal instead of silently running it.

```powershell
.\scripts\test-esp32-speaker-tone.ps1 -Port COM7 -Required
.\scripts\test-esp32-speaker-tone.ps1 -Port COM7 -ToneSeconds 8 -ToneMode all -Required
.\scripts\test-esp32-speaker-tone.ps1 -Port COM7 -ToneSeconds 4 -ToneMode sweep -Required
.\scripts\test-esp32-voice-chat-audio.ps1 -Port COM7 -Required
.\scripts\test-esp32-voice-chat-session-audio.ps1 -Port COM7 -Turns 2 -RecordSeconds 5 -Required
.\scripts\test-voice-chat-ws.ps1 -WsUrl ws://127.0.0.1:8723/voice-chat/ws -Text "Hello XiaoQian" -Required
.\scripts\test-voice-chat-ws.ps1 -WsUrl ws://127.0.0.1:8723/voice-chat/ws -Text "Hello XiaoQian" -UserId home-user -DeviceId readiness-script -Required
.\scripts\test-voice-chat-ws.ps1 -WsUrl ws://127.0.0.1:8723/voice-chat/ws -TurnMode pcm_s16le -AudioText "Hello XiaoQian, test binary PCM audio." -UserId home-user -DeviceId ws-pcm-readiness -Required
.\scripts\test-voice-chat-ws.ps1 -WsUrl ws://127.0.0.1:8723/voice-chat/ws -Text "Hello XiaoQian, stream TTS audio." -UserId home-user -DeviceId ws-tts-stream -ReplyAudio -RequireReplyAudio -Required
.\scripts\test-esp32-reminder-audio.ps1 -Port COM7 -Required
.\scripts\test-esp32-reminder-audio.ps1 -Port COM7 -Seconds 95 -AutoPoll -ExpectedTtsProvider mimo -ExpectedTtsModel mimo-v2.5-tts -ExpectedTtsVoice Mia -Required
.\scripts\test-esp32-reminder-audio.ps1 -Port COM7 -Seconds 110 -AutoPoll -ApiBase http://192.0.2.101:8723 -ExpectedTtsProvider mimo -ExpectedTtsModel mimo-v2.5-tts -ExpectedTtsVoice Mia -Required
.\scripts\test-esp32-voice-chat-ws-audio.ps1 -Port COM7 -Turns 2 -RecordSeconds 5 -UserPhrases "First turn;Second turn" -Required
.\scripts\test-esp32-voice-chat-ws-audio.ps1 -Port COM7 -Turns 2 -RecordSeconds 4 -RequirePcmStream -Required
.\scripts\test-esp32-voice-chat-ws-audio.ps1 -Port COM7 -Turns 2 -RecordSeconds 8 -RequirePcmStream -RequireVadStop -Required
.\scripts\test-esp32-voice-chat-ws-audio.ps1 -Port COM7 -Turns 2 -RecordSeconds 8 -RequirePcmStream -RequireVadStop -RequireBinaryReplyAudio -Required
.\scripts\test-esp32-voice-chat-ws-audio.ps1 -Port COM7 -Turns 2 -RecordSeconds 8 -RequirePcmStream -RequireVadStop -RequireBinaryReplyAudio -ExpectedTtsProvider mimo -ExpectedTtsModel mimo-v2.5-tts -ExpectedTtsVoice Mia -Required
.\scripts\test-esp32-voice-chat-ws-audio.ps1 -Port COM7 -Turns 2 -RecordSeconds 8 -RequirePcmStream -RequireVadStop -RequireBinaryReplyAudio -RequireChunkedReplyAudio -ExpectedTtsProvider mimo -ExpectedTtsModel mimo-v2.5-tts -ExpectedTtsVoice Mia -Required
.\scripts\test-esp32-voice-chat-ws-audio.ps1 -Port COM7 -Turns 2 -RecordSeconds 8 -RequirePcmStream -RequireVadStop -RequireBinaryReplyAudio -RequireChunkedReplyAudio -RequireStreamingReplyAudio -ExpectedTtsProvider mimo -ExpectedTtsModel mimo-v2.5-tts -ExpectedTtsVoice Mia -Required
.\scripts\test-esp32-voice-chat-ws-audio.ps1 -Port COM7 -Turns 2 -RecordSeconds 8 -VoiceName "Microsoft Huihui Desktop" -UserPhrases "Hello XiaoQian, test streaming voice chat.;Please reply in one short sentence." -RequirePcmStream -RequireVadStop -RequireBinaryReplyAudio -RequireChunkedReplyAudio -RequireStreamingReplyAudio -ExpectedTtsProvider mimo -ExpectedTtsModel mimo-v2.5-tts -ExpectedTtsVoice Mia -Required
```

`test-esp32-speaker-tone.ps1` is the isolated board-speaker check. It sends
`homecue:speaker-test N mode` over USB serial, captures the ESP32 log, and
requires ES8311 ready, `TCA9555_EXIO8`/PA enable, PA readback high, local tone
start, complete I2S writes, and no crash markers. `-ToneMode all` runs four
segments (`both`, `left`, `right`, `sweep`); use a single mode to isolate an
I2S slot/channel problem. The serial log still cannot prove acoustic output by
itself; it exists to separate the hardware speaker path from ASR, MiMo, TTS,
WebSocket, and PC-speaker placement.

Runs the ESP32 voice-chat audio loop with the PC speaker acting as the user and
the ESP32 board speaker playing the assistant reply. The single-turn script
drives wake word + `chat mode`; the session script uses the serial test command
`homecue:voice-chat-session` so it can reliably verify multiple user turns with
the same backend `session_id`. The session proof checks two recording prompts,
two WAV uploads, two MiMo replies, two ESP32 speaker playbacks, one reused
session id, advancing `turn_index` values, and no crash markers.

`test-esp32-voice-chat-audio.ps1` also supports `-ExpectedTurns 2` for the
voice-command session path. Add `-ForceCommandWindow` when Windows TTS cannot
reliably trigger the wake word: the script opens the ESP-SR command window over
serial, then still uses the PC speaker to say `chat mode` and the user phrases.
This validates the ESP-SR command-word entry and multi-turn voice-chat behavior
without claiming wake-word reliability.

`test-voice-chat-ws.ps1` checks the backend long-connection protocol for the
next real-time voice step. It performs a WebSocket `hello`, starts a listen
turn, sends a text transcript, waits for `stt`, `llm`, and `listen/ready`
events, checks the `user_id`/`device_id` echo when supplied, and writes a JSON
proof. Use `-TurnMode pcm_s16le` to synthesize a short Windows TTS utterance,
send the raw `pcm_s16le` bytes as WebSocket binary frames, and verify ASR,
MiMo reply, and session readiness without ESP32 hardware. If `-AudioText` is
omitted the script uses `-Text`; add `-RequireRecognizedAudio` when the proof
must fail on ASR `no_match` instead of accepting a recoverable ready turn.
Use `-ReplyAudio -RequireReplyAudio` to require MiMo TTS metadata plus binary
WAV frames over the WebSocket downlink. The default reply-audio transport is
`websocket_binary_stream`, matching the ESP32 streaming speaker path.

`test-esp32-reminder-audio.ps1` creates one due task through
`/voice-chat/tasks`, captures the board log, and requires
`/voice-chat/tasks/due-audio` `status=ready`, `reply_audio: ready`, a WAV
download, board-speaker playback, and no crash markers. By default it sends
`homecue:reminders` to the ESP32 serial route. Add `-AutoPoll` to prove the
firmware's idle background reminder poll without sending any serial command.
Use `-ExpectedTtsProvider`, `-ExpectedTtsModel`, and `-ExpectedTtsVoice` when a
proof must show the exact voice-output provider, model, and voice in serial
logs.

`test-esp32-voice-chat-ws-audio.ps1` checks the ESP32 WebSocket voice-chat path
on real hardware. It sends `homecue:voice-chat-ws` for one turn or
`homecue:voice-chat-ws-session` for multiple turns, plays user speech through
the PC speaker, then requires a WebSocket handshake, binary audio upload, `stt`,
MiMo reply, `listen/ready`, reply-audio URL, ESP32 speaker playback, reused
session id for multi-turn runs, and no crash markers. Both the single-turn and
multi-turn WS serial commands stream raw PCM from the ESP32 mic path. Pass
`-RequirePcmStream` when the proof must show `streamed ... PCM bytes`; pass
`-RequireVadStop` when the proof must show the ESP32 stopped recording early
after trailing silence. Pass
`-RequireBinaryReplyAudio` when the proof must show assistant WAV audio returned
as a WebSocket binary frame instead of an HTTP download. The current protocol
supports text turns, binary WAV frames, binary `pcm_s16le` frames, and binary
WAV reply-audio frames; it declares the remaining Opus streaming gap in the
server hello response.

Use `-VoiceName "Microsoft Huihui Desktop"` when the proof should play Chinese
user turns through the PC speaker. The script defaults to that voice when it is
installed and falls back to the Windows default voice if it is not available.

Use `-ExpectedTtsProvider`, `-ExpectedTtsModel`, and `-ExpectedTtsVoice` when the
proof must identify the assistant voice source in ESP32 serial logs. The current
MiMo TTS hardware proof uses `mimo / mimo-v2.5-tts / Mia`; non-ASCII MiMo voice
names can synthesize audio, but may print as question marks on the board serial
console.

Use `-RequireChunkedReplyAudio` when the proof must show the assistant WAV
returned as multiple WebSocket binary frames, followed by a board-side
`reply audio chunks complete` marker and speaker playback. Use
`-RequireStreamingReplyAudio` when the proof must additionally show
`[speaker] stream start ...` and `[speaker] stream playback done ...`, proving
the ESP32 started I2S output from the first reply-audio frame instead of waiting
for a full WAV replay. With `websocket_binary_stream`, MiMo TTS arrives as
multiple independent WAV segments; the ESP32 parses and plays each segment while
the WebSocket continues receiving later segments.

```powershell
.\scripts\check-esp32-serial-log.ps1 -Port COM7 -Seconds 10 -Required
.\scripts\check-esp32-serial-log.ps1 -Port COM7 -Seconds 45 -SkipReset -RequireInteraction -SaveLogPath .\assets\demo\esp32-level4.log -ResultJsonPath .\assets\demo\esp32-level4-check.json
.\scripts\check-esp32-serial-log.ps1 -Port COM7 -Seconds 60 -SkipReset -RequireInteraction -SendCommand "homecue:plan 0","homecue:execute" -SendAfterSeconds 25 -SaveLogPath .\assets\demo\esp32-level4.log -ResultJsonPath .\assets\demo\esp32-level4-check.json -Required
.\scripts\check-esp32-serial-log.ps1 -Port COM7 -Seconds 90 -SkipReset -RequireInteraction -AutoSerialLevel4 -SerialCommandIndex 0 -ExpectedActionCount 5 -SaveLogPath .\assets\demo\esp32-level4.log -ResultJsonPath .\assets\demo\esp32-level4-check.json -Required
.\scripts\check-esp32-serial-log.ps1 -LogPath .\sample-esp32.log -Required
```

Reads and checks ESP32 serial output for the HomeCue boot banner, button-route mode, Wi-Fi connection, and `/health` gateway probe. Add `-RequireInteraction` when capturing the Level 4 hardware loop so KEY1/BOOT, voice, or serial-test `/plan` and KEY2/serial-test `/execute` markers become required checks. Use `-AutoSerialLevel4` for unattended proof capture: it sends `homecue:plan N`, waits until `[/plan] proposed ...` appears, then sends `homecue:execute`. Use `-SendCommand` for lower-level manual command injection, `-SaveLogPath` to keep a local proof log, `-ResultJsonPath` to save structured OK/WARN check results, or `-LogPath` to verify a saved serial log without opening the port.

Pass `-ExpectedActionCount 5` when you want the structured Level 4 proof to fail unless the captured proposal contains the expected number of actions. Leave it at the default `0` for generic smoke checks.

When the optional ESP-SR build is enabled, the serial check accepts the additive `button-route + ESP-SR voice command route` mode banner and expects the log to either show `[esp-sr] ready` or an explicit `voice route unavailable` fallback. This keeps the proven key/serial demo route auditable while voice integration is still being tuned.

For `-SkipReset -RequireInteraction` captures, boot/Wi-Fi/health markers are treated as optional because the log may intentionally contain only the interaction window. Omit `-SkipReset` when you need a full boot-to-execute proof in one file.
