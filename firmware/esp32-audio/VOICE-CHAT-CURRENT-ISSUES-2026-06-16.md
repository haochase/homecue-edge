# ESP32 Voice Chat Current Issues - 2026-06-16

## Summary

The realistic WebSocket voice-chat path has now been proven on real hardware
with PC speaker input and ESP32 board-speaker output:

```text
PC speaker plays Chinese user utterance
-> ESP32 records and streams PCM over one WebSocket session
-> backend runs ASR + MiMo chat
-> backend streams MiMo TTS audio segments over the same WebSocket
-> ESP32 plays the segments through the ES8311/I2S board speaker
```

## 2026-06-17 speaker-first recheck at 14:20

The board speaker remains the active blocker. This pass focused only on proving
whether the current machine can drive the board far enough to run the audible
speaker diagnostic.

Current USB state:

```text
assets/demo/esp32-speaker-focus-port-state-now.json
assets/demo/esp32-speaker-audible-now-usb-error-port-state.json
assets/demo/esp32-speaker-audible-now-usb-error-summary.json

state=usb-error
finalPortState=usb-error
requestedPort=COM7
detectedPorts=COM3,COM4,COM5,COM6
COM3-COM6 are Bluetooth serial ports
usbProblemDevices[0].name=Unknown USB Device (Device Descriptor Request Failed)
usbProblemDevices[0].configManagerErrorCode=43
uploadExitCode=null
toneExitCode=null
```

## 2026-06-17 Ubuntu deploy verification helper update

Deployment-side progress while ESP32 USB remains blocked:

```text
scripts/deploy-api-ubuntu.ps1
- Added token-aware post-restart verification.
- Default verify target: http://127.0.0.1:<port> from the Ubuntu host.
- Checks /health and /voice-chat/status.
- If VOICE_CHAT_ACCESS_TOKEN is present in the uploaded env, the verifier uses
  it as Authorization: Bearer without printing the token value.
- Added -VerifyResultJsonPath, -VerifyBaseUrl, -VerifyAccessToken, and
  -SkipVerify.
```

Current Ubuntu LAN reachability probe:

```text
assets/demo/ubuntu-lan-health-probe-now.json

ssh edge-host "echo ok"
-> Connection closed by 192.0.2.101 port 22

Test-NetConnection 192.0.2.101 -Port 22
-> TcpTestSucceeded=true

Test-NetConnection 192.0.2.101 -Port 8723
-> TcpTestSucceeded=true

GET http://192.0.2.101:8723/health
-> Remote end closed connection without response
```

Interpretation:

```text
The deploy/verify script can now produce a runtime proof when the Ubuntu host is
healthy, but this pass did not re-deploy or revalidate the remote service
because the current endpoint accepts TCP and then closes the SSH/API connection.
```

Windows device recovery attempts:

```text
pnputil /scan-devices
-> Access is denied

pnputil /restart-device USB\VID_0000&PID_0002\6&1266488A&0&2
-> Access is denied
```

Current firmware/software status:

```text
scripts/check-firmware-flow.ps1 -Required
-> passed

scripts/flash-esp32.ps1 -Clean -EnableEspSr -BootSpeakerTest
  -BootSpeakerTestSeconds 8 -BootSpeakerTestMode all -DiagHttpServer
  -BuildPath %TEMP%/homecue-edge-esp32-speaker-focus-compile-latest
-> compile passed
-> sketch size 1,474,261 bytes / 46%
```

Current network bypass checks:

```text
assets/demo/esp32-speaker-lan-tone-candidate-a.json
assets/demo/esp32-speaker-lan-tone-candidate-b.json
assets/demo/esp32-speaker-lan-tone-candidate-c.json
assets/demo/esp32-speaker-lan-tone-candidate-d.json
assets/demo/esp32-speaker-lan-port-scan-now.json

The tested LAN candidate hosts did not answer the diagnostic
/health + /speaker-test path with a usable speaker-tone response.
```

Conclusion:

```text
No software-controlled path currently reaches the ESP32: USB is a Windows
descriptor failure with no COM port, and the tested Wi-Fi diagnostic endpoints
do not answer. The latest boot-tone diagnostic firmware is compiled and ready,
but it has not been uploaded in this pass.

When the board re-enumerates as an Espressif/USB serial COM port, run:

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\resume-esp32-speaker-audible-test.ps1 `
  -Port COM7 `
  -AutoDetectEsp32 `
  -MaxWaitSeconds 900 `
  -ApiHostOverride 192.0.2.118 `
  -ApiPortOverride 8723 `
  -OutputPrefix .\assets\demo\esp32-speaker-audible-recheck-auto `
  -Required
```

The target phrase `你好小千` is still not available as a board-local wake word because the current ESP-SR model assets do not contain a `xiaoqian` WakeNet model. MiMo is sufficient as the dialogue model after ASR, but it cannot replace local wake-word detection.

The backend and ESP32 firmware now expose a long-lived WebSocket session route:

```text
WS /voice-chat/ws
hello -> listen/start -> partial/final text or binary WAV -> listen/stop
-> stt partial/final -> llm/start -> llm/stop -> optional tts events -> listen/ready
```

This moves the system closer to the open-source XiaoZhi flow, where a device
opens a WebSocket audio channel, sends a JSON `hello`, then exchanges JSON state
events and binary audio frames. The current HomeCue route still advertises
`opus_stream=false`: ESP32 can keep one WebSocket open across multiple turns,
stream raw PCM S16LE chunks while recording, and play MiMo TTS segments while
they arrive. The JSON protocol now accepts partial/final transcript events, but
real audio-derived ASR still runs after listen/stop. It is not yet continuous
Opus frame streaming or full-duplex speak/listen.

Latest single-turn PCM/VAD hardware proof, 2026-06-17:

```text
serial homecue:voice-chat-ws 8
-> PC speaker uses Microsoft Huihui Desktop to play one Chinese user turn
-> ESP32 opens /voice-chat/ws and sends pcm_s16le binary frames
-> VAD stops recording at 3072ms after trailing silence
-> ESP32 streamed 196608 PCM bytes, not a complete WAV upload
-> backend runs ASR + MiMo chat
-> backend streams MiMo TTS as 7 independent WAV segments
-> ESP32 plays all 7 segments through ES8311/I2S and logs playback done
```

Evidence:

```text
assets/demo/esp32-local-lan-pcm-single-voice-chat.log
assets/demo/esp32-local-lan-pcm-single-voice-chat-markers.log
assets/demo/esp32-local-lan-pcm-single-voice-chat-check.json
assets/demo/esp32-local-lan-pcm-single-boot-health.log
assets/demo/esp32-local-lan-pcm-single-boot-health.json
```

Required checks all passed:

```text
[OK] ws PCM stream - saw 1/1
[OK] VAD early stop - saw 1/1
[OK] ws stt - saw 1/1
[OK] mimo provider - saw 1/1
[OK] expected TTS provider - expected=mimo saw 1/1
[OK] expected TTS model - expected=mimo-v2.5-tts saw 1/1
[OK] expected TTS voice - expected=Mia saw 1/1
[OK] streaming reply audio done - saw 1/1
[OK] audio playback - saw 1/1
[OK] no crash - saw 0 crash marker(s)
```

Firmware change made during this proof: `homecue:voice-chat-ws` now uses the
same PCM/VAD WebSocket turn path as `homecue:voice-chat-ws-session`, instead of
recording a full WAV first and then uploading it. This makes the single-turn
serial command a closer proxy for the intended realtime voice-chat UX.

Latest local SQLite memory/task runtime proof, 2026-06-17:

```text
local API: http://192.0.2.118:8723
VOICE_CHAT_MEMORY_DB=runtime/voice-chat.sqlite
HOMECUE_VOICE_CHAT_AUDIO_DIR=runtime/audio
status: memory.sqlite_enabled=true
```

API proof:

```text
assets/demo/local-api-sqlite-memory-tasks-proof.json
```

This proof wrote two turns under the same session id and `user_id=home-user`
from two device labels (`browser-console` and `esp32-board`). It also verified
that the SQLite layer returns session history, extracted memory notes, extracted
open tasks, and extracted mood rows. The PowerShell request path encoded Chinese
text imperfectly in that artifact, but the persisted structure, user/device
labels, turn indexes, and task/mood rows were present.

Hardware reminder proof against the same local SQLite runtime:

```text
assets/demo/esp32-local-sqlite-reminders-auto.log
assets/demo/esp32-local-sqlite-reminders-auto-markers.log
assets/demo/esp32-local-sqlite-reminders-auto-check.json
```

Required checks all passed:

```text
[OK] auto reminder poll - saw 1
[OK] due audio ready - saw 1
[OK] reply audio ready - saw 1
[OK] expected TTS provider - expected=mimo saw 1
[OK] expected TTS model - expected=mimo-v2.5-tts saw 1
[OK] expected TTS voice - expected=Mia saw 1
[OK] audio download - saw 1
[OK] speaker playback - saw 1
[OK] no crash - saw 0 crash marker(s)
```

This proves the local LAN runtime can now support shared voice-chat state and
board-spoken scheduled reminders without the Ubuntu host. Ubuntu deployment
should still use the same env shape, with the SQLite DB and generated audio
directory placed under the remote service data directory.

Latest ESP32 identity persistence proof, 2026-06-17:

Firmware now sends these labels in the WebSocket `hello` and `listen/start`
events:

```text
user_id=home-user
device_id=esp32-audio-board
```

Hardware proof:

```text
assets/demo/esp32-local-lan-identity-pcm-voice-chat.log
assets/demo/esp32-local-lan-identity-pcm-voice-chat-markers.log
assets/demo/esp32-local-lan-identity-pcm-voice-chat-check.json
assets/demo/local-api-sqlite-esp32-identity-session-proof.json
```

The ESP32 proof passed the same PCM/VAD + MiMo/Mia + board-speaker checks, then
the API session lookup for the returned `session_id` showed:

```text
turn_index=1
user_id=home-user
device_id=esp32-audio-board
```

This closes the first practical shared-memory gap for board-originated speech:
voice turns from the physical ESP32 are now stored under the same household user
and a stable device label, so browser and board sessions can share history,
tasks, moods, and future memory retrieval by `user_id`.

Latest MiMo streaming TTS hardware proof, 2026-06-16:

```text
serial homecue:voice-chat-ws-session 2 8
-> PC speaker uses Microsoft Huihui Desktop to play two Chinese user turns
-> ESP32 opens one /voice-chat/ws connection and keeps one session_id
-> turn 1 streams 196608 PCM bytes with VAD early stop at 3072ms
-> backend returns MiMo chat reply and MiMo TTS provider/model/voice metadata
-> MiMo TTS is streamed as 8 independent WAV segments over WebSocket binary frames
-> ESP32 plays all 8 segments through ES8311/I2S and logs playback done
-> turn 2 streams 446464 PCM bytes with VAD early stop at 6976ms
-> backend returns the same session_id with turn=2
-> MiMo TTS is streamed as another 8 independent WAV segments
-> ESP32 plays reply 2 through the board speaker
```

Evidence:

```text
assets/demo/esp32-voice-chat-ws-mimo-stream-rxfix.log
assets/demo/esp32-voice-chat-ws-mimo-stream-rxfix-markers.log
assets/demo/esp32-voice-chat-ws-mimo-stream-rxfix-check.json
```

Required checks all passed:

```text
[OK] ws PCM stream - saw 2/2
[OK] VAD early stop - saw 2/2
[OK] ws stt - saw 2/2
[OK] mimo provider - saw 2/2
[OK] reply audio ready - saw 2/2
[OK] binary reply audio - saw 16/2
[OK] streaming reply audio start - saw 16/2
[OK] streaming reply audio done - saw 2/2
[OK] expected TTS provider - expected=mimo saw 2/2
[OK] expected TTS model - expected=mimo-v2.5-tts saw 2/2
[OK] expected TTS voice - expected=Mia saw 2/2
[OK] audio playback - saw 2/2
[OK] session turns advance - turns=1,2
[OK] no crash - saw 0 crash marker(s)
```

Firmware fix made during this proof: after board-speaker playback, the shared
I2S device is explicitly restored to the mic RX mode (`16 kHz`, `16-bit`,
`stereo`) before the next recording. Without that restore, turn 2 could upload
weak audio after a TTS playback round.

Latest backend memory progress, 2026-06-16:

```text
VOICE_CHAT_MEMORY_DB=<sqlite path>
-> /voice-chat persists completed turns with session_id, turn_index, user_id, device_id
-> /voice-chat/ws accepts user_id/device_id in hello and listen/start
-> same session_id can restore recent context after API in-memory session cache is cleared
-> GET /voice-chat/sessions lists persisted sessions
-> GET /voice-chat/sessions/<session_id> returns persisted turns
-> GET /voice-chat/memories lists extracted long-term notes/preferences
-> GET/POST/PATCH /voice-chat/tasks manages shared voice-created tasks
-> GET /voice-chat/tasks/due returns open tasks whose due_at has arrived
-> GET /voice-chat/tasks/due-audio claims one due task and returns playable reminder WAV metadata
-> GET /voice-chat/moods lists simple extracted mood events
-> ESP32 serial `homecue:reminders` polls due-audio and plays the reminder through the board speaker
-> ESP32 idle loop now auto-polls due-audio and can speak due reminders without a serial command
-> daily/weekly recurring voice tasks now reschedule to the next due_at when reminded
-> GET /voice-chat/status reports active provider/model, TTS provider/model/voice, SQLite memory, and realtime flags without secrets
-> scripts/deploy-api-ubuntu.ps1 deploys apps/api to an Ubuntu LAN host as a user-level systemd service
```

This is now enough for LAN/Ubuntu deployments to keep episodic conversation
history outside the API process and for ESP32/browser clients to share one
conversation by reusing `session_id`. The first extraction layer is rule-based:
phrases like `记住`, `我喜欢`, and `提醒我` create memories/tasks, and common
emotion words create mood events. Tasks now store `due_text`, `recurrence`, and
a computable `due_at` for common phrases such as `10分钟后`, `今晚`, `明天`,
`下周`, `每天`, and `每周`; daily/weekly due tasks reschedule themselves to the
next occurrence when marked reminded. It is not yet a full LLM-summarized
long-term profile, push notification system, or cross-device task executor.

Ubuntu LAN service proof:

```text
server: edge-host
url: http://192.0.2.101:8723
service: homecue-edge-api.service
state: active + enabled
chat: provider=mimo model=mimo-v2.5-pro
tts: provider=mimo model=mimo-v2.5-tts voice=Mia configured=true
memory: sqlite_enabled=true
realtime: websocket=true pcm_s16le=true mimo_streaming_tts=true opus_stream=false full_duplex=false

deploy command:
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy-api-ubuntu.ps1 -Remote edge-host -RemoteDir '~/homecue-edge-api' -Port 8723 -PipIndexUrl https://pypi.tuna.tsinghua.edu.cn/simple

ESP32 flash command:
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 -Port COM7 -Upload -EnableEspSr -ApiHostOverride 192.0.2.101 -ApiPortOverride 8723 -BuildPath $env:TEMP\homecue-edge-esp32-build-ubuntu-lan

ESP32 proof command:
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-esp32-reminder-audio.ps1 -Port COM7 -Seconds 110 -AutoPoll -ApiBase http://192.0.2.101:8723 -TaskTitle 'ESP32 Ubuntu LAN auto reminder proof' -DueText 'now' -ExpectedTtsProvider mimo -ExpectedTtsModel mimo-v2.5-tts -ExpectedTtsVoice Mia -Required

result:
-> ESP32 IP 192.0.2.106 reached Ubuntu /health and /voice-chat/tasks/due-audio
-> /voice-chat/tasks/due-audio status=ready
-> reply audio ready
-> TTS provider/model/voice = mimo / mimo-v2.5-tts / Mia
-> ESP32 downloaded 437804-byte WAV from the Ubuntu service
-> ES8311 board speaker played 24000 Hz mono WAV and logged playback done
```

Software proof:

```text
apps/api/.venv/Scripts/python.exe -m pytest tests
-> 48 passed
npm run build
-> web build passed
Playwright headless browser against http://127.0.0.1:5173?apiBase=http://127.0.0.1:8723
-> Shared state panel visible
-> browser-created task appears in the Tasks column
ESP32 serial reminder proof:
-> created one due task for user_id=home-user
-> flashed ESP32 firmware with homecue:reminders
-> scripts/test-esp32-reminder-audio.ps1 -Port COM7 -Required
-> /voice-chat/tasks/due-audio status=ready
-> ESP32 downloaded 376364-byte WAV
-> ES8311 board speaker logged playback done
ESP32 automatic reminder proof:
-> created one due task for user_id=home-user
-> flashed ESP32 firmware with idle reminder auto-poll
-> scripts/test-esp32-reminder-audio.ps1 -Port COM7 -Seconds 95 -AutoPoll -ExpectedTtsProvider mimo -ExpectedTtsModel mimo-v2.5-tts -ExpectedTtsVoice Mia -Required
-> no serial reminder command was sent
-> /voice-chat/tasks/due-audio status=ready
-> TTS provider/model/voice = mimo / mimo-v2.5-tts / Mia
-> ESP32 downloaded 322604-byte WAV
-> ES8311 board speaker logged playback done
```

Evidence:

```text
assets/demo/esp32-reminders-due-audio.log
assets/demo/esp32-reminders-due-audio-markers.log
assets/demo/esp32-reminders-due-audio-check.json
assets/demo/esp32-reminders-auto-due-audio.log
assets/demo/esp32-reminders-auto-due-audio-markers.log
assets/demo/esp32-reminders-auto-due-audio-check.json
assets/demo/esp32-ubuntu-lan-reminders-auto.log
assets/demo/esp32-ubuntu-lan-reminders-auto-markers.log
assets/demo/esp32-ubuntu-lan-reminders-auto-check.json
```

Update, 2026-06-17:

```text
-> /voice-chat/ws hello now advertises stt_partial=true and stt_final=true
-> listen/partial sends immediate server stt partial events
-> listen/final stores the final transcript and sends a server stt final acknowledgement
-> legacy listen/text still works and emits final stt on listen/stop
-> VOICE_CHAT_ASR_PROVIDER config now selects auto/windows/faster_whisper/disabled
-> GET /voice-chat/status now reports ASR provider, effective provider, model, language, and availability flags
-> voice task schema now includes recurrence
-> POST/PATCH /voice-chat/tasks accepts recurrence
-> supported recurrence values: daily, weekly, or empty one-shot
-> due_text/title phrases such as 每天, 每日, 每周, 每星期 infer recurrence
-> mark_reminded=true keeps one-shot tasks consumed but reschedules recurring tasks to their next due_at
-> web shared-state task cards display the recurrence label
```

Runtime proof:

```text
ASR provider config:
VOICE_CHAT_ASR_PROVIDER=auto
-> Windows host status can report effective_provider=windows when faster-whisper is absent
-> Ubuntu host status will report effective_provider=faster_whisper only after faster-whisper is installed
-> VOICE_CHAT_ASR_PROVIDER=disabled returns HTTP 501 for /voice audio uploads
-> VOICE_CHAT_ASR_PROVIDER=faster_whisper requires faster-whisper and otherwise returns HTTP 501

local temp API on 127.0.0.1:8737
scripts/test-voice-chat-ws.ps1 -WsUrl ws://127.0.0.1:8737/voice-chat/ws -Text "Hello XiaoQian partial transcript proof" -Required
-> hello features include stt_partial=true and stt_final=true
-> listen/partial produced stt/state=partial
-> listen/final produced stt/state=final
-> listen/stop still produced final stt, llm reply, and listen/ready
-> assets/demo/voice-chat-ws-partial-proof.json

local temp API on 127.0.0.1:8736
POST /voice-chat/tasks recurrence=daily due_at=1700000000
GET /voice-chat/tasks/due?mark_reminded=true&now=1700000001
-> returned task recurrence=daily
-> returned task due_at=1700086400
-> returned task reminded_at=1700000001
GET /voice-chat/tasks/due?now=1700000001
-> empty
GET /voice-chat/tasks/due?now=1700086401
-> same daily task due again
```

Software proof:

```text
apps/api/.venv/Scripts/python.exe -m pytest tests
-> 51 passed
npm run build
-> web build passed
python -m compileall apps/api/app
-> passed
git diff --check
-> passed for touched API/web/docs files
```

Ubuntu deploy status on 2026-06-17:

```text
ssh edge-host / 192.0.2.101:22
-> connection refused
http://192.0.2.101:8723/voice-chat/status
-> unreachable
```

The daily/weekly recurrence implementation is verified locally but has not yet
been deployed to the Ubuntu LAN service because the host was unreachable during
this run. Re-run the existing deploy command when the host is back:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy-api-ubuntu.ps1 -Remote edge-host -RemoteDir '~/homecue-edge-api' -Port 8723 -PipIndexUrl https://pypi.tuna.tsinghua.edu.cn/simple
```

Latest WebSocket hardware proof, 2026-06-16:

```text
serial homecue:voice-chat-ws-session 2 5
-> ESP32 opens one /voice-chat/ws connection
-> server returns one hello/session_id
-> ESP32 records user turn 1 and sends binary WAV frames
-> server returns stt, MiMo reply, reply_audio URL, listen/ready turn=1
-> ESP32 board speaker plays reply 1
-> ESP32 records user turn 2 over the same WebSocket session
-> server returns the same session_id with turn=2
-> ESP32 board speaker plays reply 2
```

Evidence:

```text
assets/demo/esp32-voice-chat-ws-session-audio-test.log
assets/demo/esp32-voice-chat-ws-session-audio-test-markers.log
assets/demo/esp32-voice-chat-ws-session-audio-test-check.json
```

Latest required PCM-stream hardware proof, 2026-06-16:

```text
serial homecue:voice-chat-ws-session 2 4
-> ESP32 opens one /voice-chat/ws connection
-> turn 1 streams 256000 PCM bytes while recording
-> backend wraps PCM as WAV for ASR, returns MiMo reply + reply_audio
-> ESP32 board speaker plays reply 1
-> turn 2 streams another 256000 PCM bytes on the same session/socket
-> backend returns the same session_id with turn=2
-> ESP32 board speaker plays reply 2
```

Evidence:

```text
assets/demo/esp32-voice-chat-ws-pcm-required.log
assets/demo/esp32-voice-chat-ws-pcm-required-markers.log
assets/demo/esp32-voice-chat-ws-pcm-required-check.json
```

The required checker now includes:

```text
[OK] ws PCM stream - saw 2/2
```

Latest VAD early-stop hardware proof, 2026-06-16:

```text
serial homecue:voice-chat-ws-session 2 8
-> turn 1 VAD stop at 5504ms instead of recording the full 8000ms
-> turn 2 VAD stop at 4608ms instead of recording the full 8000ms
-> both turns stream PCM, get ASR + MiMo replies, download reply_audio, and play through the ESP32 speaker
```

Evidence:

```text
assets/demo/esp32-voice-chat-ws-pcm-vad-required.log
assets/demo/esp32-voice-chat-ws-pcm-vad-required-markers.log
assets/demo/esp32-voice-chat-ws-pcm-vad-required-check.json
```

The required checker now includes both:

```text
[OK] ws PCM stream - saw 2/2
[OK] VAD early stop - saw 2/2
```

This improves turn latency, but it is still not the final XiaoZhi-style
realtime target. Remaining gaps:

```text
1. No Opus encode/decode yet; the ESP32 sends raw PCM S16LE.
2. Audio-derived ASR still runs after each listen/stop; only JSON partial/final transcript events are supported.
3. The device is half-duplex: it listens, then thinks/speaks, rather than listening while speaking.
4. Board-local wake still uses the available nihaoxiaozhi/hiesp ESP-SR models; `你好小千` needs a real xiaoqian WakeNet/custom model.
```

Latest binary reply-audio downlink proof, 2026-06-16:

```text
serial homecue:voice-chat-ws-session 2 8
-> ESP32 requests reply_audio_transport=websocket_binary in hello
-> turn 1 streams PCM upstream and receives 147086-byte WAV as a WebSocket binary frame
-> ESP32 board speaker plays reply 1 directly from that binary frame
-> turn 2 streams PCM upstream and receives 145806-byte WAV as a WebSocket binary frame
-> ESP32 board speaker plays reply 2 directly from that binary frame
```

Evidence:

```text
assets/demo/esp32-voice-chat-ws-binary-downlink.log
assets/demo/esp32-voice-chat-ws-binary-downlink-markers.log
assets/demo/esp32-voice-chat-ws-binary-downlink-check.json
```

The required checker now includes:

```text
[OK] ws PCM stream - saw 2/2
[OK] VAD early stop - saw 2/2
[OK] binary reply audio - saw 2/2
```

This removes the extra HTTP reply-audio download from the WebSocket hardware
path. It still sends complete WAV reply audio after TTS finishes; streaming TTS
chunks are not implemented yet.

Latest chunked binary reply-audio proof, 2026-06-16:

```text
serial homecue:voice-chat-ws-session 2 8
-> ESP32 requests reply_audio_transport=websocket_binary_chunked in hello
-> turn 1 streams PCM upstream, then receives a 138284-byte MiMo TTS WAV as 9 WebSocket binary frames
-> ESP32 aggregates the 9 chunks, then plays reply 1 through the board speaker
-> turn 2 streams PCM upstream, then receives a 130604-byte MiMo TTS WAV as 8 WebSocket binary frames
-> ESP32 aggregates the 8 chunks, then plays reply 2 through the board speaker
```

Evidence:

```text
assets/demo/esp32-voice-chat-ws-chunked-mimo-tts.log
assets/demo/esp32-voice-chat-ws-chunked-mimo-tts-markers.log
assets/demo/esp32-voice-chat-ws-chunked-mimo-tts-check.json
```

The required checker now includes:

```text
[OK] ws PCM stream - saw 2/2
[OK] VAD early stop - saw 2/2
[OK] chunked reply audio ready - saw 2/2
[OK] chunked reply audio frames - saw 17
[OK] chunked reply audio complete - saw 2/2
[OK] expected TTS provider - expected=mimo saw 2/2
[OK] expected TTS model - expected=mimo-v2.5-tts saw 2/2
[OK] expected TTS voice - expected=Mia saw 2/2
[OK] audio playback - saw 2/2
```

This is closer to XiaoZhi-style binary audio framing because reply audio now
travels as multiple WebSocket frames. It is now superseded by the streaming
speaker proof below.

Latest streaming speaker proof, 2026-06-16:

```text
serial homecue:voice-chat-ws-session 2 8
-> ESP32 requests reply_audio_transport=websocket_binary_chunked in hello
-> turn 1 receives a 192044-byte MiMo TTS WAV as 12 WebSocket binary frames
-> ESP32 parses the WAV header from chunk 1 and starts I2S output before the remaining chunks arrive
-> turn 2 receives a 99884-byte MiMo TTS WAV as 7 WebSocket binary frames
-> ESP32 again starts I2S output from chunk 1 and completes playback after audio_done
```

Evidence:

```text
assets/demo/esp32-voice-chat-ws-streaming-mimo-tts.log
assets/demo/esp32-voice-chat-ws-streaming-mimo-tts-markers.log
assets/demo/esp32-voice-chat-ws-streaming-mimo-tts-check.json
```

The required checker now includes:

```text
[OK] ws PCM stream - saw 2/2
[OK] VAD early stop - saw 2/2
[OK] chunked reply audio frames - saw 19
[OK] streaming reply audio start - saw 2/2
[OK] streaming reply audio done - saw 2/2
[OK] expected TTS provider - expected=mimo saw 2/2
[OK] expected TTS model - expected=mimo-v2.5-tts saw 2/2
[OK] expected TTS voice - expected=Mia saw 2/2
[OK] audio playback - saw 2/2
[OK] no crash - saw 0 crash marker(s)
```

This proves board-side streaming playback from chunked WebSocket WAV frames.
It is now superseded by the MiMo streaming TTS proof above, where the backend
uses MiMo SSE `delta.audio.data` events and starts forwarding independent WAV
segments without waiting for one complete generated WAV file.

Local Opus feasibility check on 2026-06-16 found no ready-to-use Arduino sketch
Opus encoder/decoder in the current workspace or installed ESP32 Arduino
package. The installed ESP32 Arduino libraries include audio front-end and audio
processor static libraries, but no obvious `libopus`/Opus headers. Do not claim
Opus support until a known-good codec library is added and verified on ESP32-S3.

## Current TTS Provider and Voice

The ESP32 board speaker now has a proven MiMo voice-output path. The board does
not run TTS locally; it receives a WAV generated by the backend and plays it
through the ES8311/I2S speaker path.

Current local runtime TTS after the 2026-06-16 MiMo test:

```text
provider = mimo
model    = mimo-v2.5-tts
voice    = Mia
format   = WAV, 24 kHz, 16-bit, mono in the latest hardware proof
```

MiMo is also the dialogue model:

```text
active_provider = mimo
chat_model      = mimo-v2.5-pro
chat_base_host  = configured MiMo chat endpoint host
```

The current MiMo account exposes these model ids from `/models`:

```text
mimo-v2-tts
mimo-v2.5-tts
mimo-v2.5-tts-voiceclone
mimo-v2.5-tts-voicedesign
```

The OpenAI-style `POST /audio/speech` probe still returns HTTP 404 on this MiMo
base URL. The working MiMo TTS route is:

```text
POST /chat/completions
model = mimo-v2.5-tts
messages = [{"role":"assistant","content":"text to speak"}]
audio.voice = Mia
```

For non-streaming requests, the response returns base64 WAV audio at
`choices[0].message.audio.data`. For streaming requests, `stream=true` returns
`text/event-stream` chunks with `choices[].delta.audio.data`. Each audio delta
is an independent WAV segment, not a byte range from one long WAV. The backend
therefore decodes and forwards each segment as a separate WebSocket binary
frame with `transport=websocket_binary_stream`.

Accepted MiMo voice names observed from the current endpoint:

```text
mimo_default
冰糖
茉莉
苏打
白桦
Mia
Chloe
Milo
Dean
```

`茉莉` was also proven by direct backend synthesis, but ESP32 serial logs show
non-ASCII voice names as `??????`. The hardware-required proof therefore uses
`Mia` so the serial checker can verify the exact voice name.

Latest MiMo TTS hardware proof, 2026-06-16:

```text
serial homecue:voice-chat-ws-session 2 8
-> ESP32 streams PCM upstream with VAD early stop
-> backend uses MiMo chat model mimo-v2.5-pro
-> backend uses MiMo TTS model mimo-v2.5-tts voice=Mia
-> ESP32 receives 230444-byte and 169004-byte WAV files as WebSocket binary frames
-> ESP32 board speaker plays both replies
```

Evidence:

```text
assets/demo/esp32-voice-chat-ws-mimo-tts-mia.log
assets/demo/esp32-voice-chat-ws-mimo-tts-mia-markers.log
assets/demo/esp32-voice-chat-ws-mimo-tts-mia-check.json
```

Required checks all passed:

```text
[OK] ws PCM stream - saw 2/2
[OK] VAD early stop - saw 2/2
[OK] binary reply audio - saw 2/2
[OK] expected TTS provider - expected=mimo saw 2/2
[OK] expected TTS model - expected=mimo-v2.5-tts saw 2/2
[OK] expected TTS voice - expected=Mia saw 2/2
[OK] audio playback - saw 2/2
[OK] no crash - saw 0 crash marker(s)
```

Historical note: the first board-speaker proofs used Windows
`System.Speech.Synthesis.SpeechSynthesizer` with `voice=default`. That path is
still a fallback when `VOICE_CHAT_TTS_PROVIDER=windows`, but it is no longer the
best current proof for the ESP32 speaker.

DashScope/Qwen-TTS remains optional. The current available key still returns
HTTP 401 `InvalidApiKey` for the DashScope TTS endpoint, so it has not been
validated on the real ESP32 speaker.

## Proven Working Path

Working entry point:

```text
你好小智 -> chat mode -> Chinese user question
```

Evidence:

```text
assets/demo/esp32-sr-models-nihaoxiaozhi-en-check.json
assets/demo/esp32-voice-chat-audio-test-nihaoxiaozhi-v1.log
assets/demo/esp32-voice-chat-audio-test-nihaoxiaozhi-v1-check.json
```

Key serial markers from the passing test:

```text
[esp-sr] model check wake=nihaoxiaozhi command=english
[esp-sr] wake word detected - say a command word
[esp-sr] wake word channel 2 verified - listening for command
[voice] chat mode
[/voice-chat] recording 6s - speak now
[/voice-chat] provider: mimo
[/voice-chat] reply_audio: ready /voice-chat/audio/...
[speaker] downloaded ... audio bytes
[speaker] playback done
```

Important caveat: in the passing run, Windows TTS had to play `你好小智` 12 times before WakeNet accepted it. That means this is usable as a development path, but not yet product-grade wake reliability.

## Proven Multi-turn Session Path

Latest hardware proof, 2026-06-16:

```text
PC speaker plays user phrase 1
-> ESP32 records and uploads WAV
-> /voice-chat returns session_id + turn_index=1
-> ESP32 downloads reply WAV and plays it on the board speaker
-> PC speaker plays user phrase 2
-> ESP32 reuses the same session_id
-> /voice-chat returns turn_index=2
-> ESP32 downloads and plays the second reply
```

Evidence:

```text
assets/demo/esp32-voice-chat-session-audio-test.log
assets/demo/esp32-voice-chat-session-audio-test-markers.log
assets/demo/esp32-voice-chat-session-audio-test-check.json
```

Key serial markers:

```text
[serial] VOICE CHAT SESSION -> 2 turn(s), 5s each
[voice-session] id=7b201a8bb662464daf6b57923321765b turn=1
[/voice-chat] provider: mimo
[speaker] playback done
[voice-session] id=7b201a8bb662464daf6b57923321765b turn=2
[/voice-chat] provider: mimo
[speaker] playback done
```

This proves conversation continuity at the HTTP/WAV turn level. Prefer the
newer WebSocket proof above when evaluating progress toward realtime voice.

## Voice Command Session Entry

Latest firmware change: the ESP-SR `chat mode` command now starts the default
two-turn voice-chat session instead of only one upload/reply turn.

Passing hardware proof, 2026-06-16:

```text
serial homecue:voice-command-window
-> PC speaker says "chat mode"
-> ESP-SR command recognition enters [voice] chat mode
-> ESP32 records two user turns
-> backend returns the same session_id with turn_index 1 and 2
-> ESP32 board speaker plays both replies
```

Evidence:

```text
assets/demo/esp32-voice-chat-audio-test-forced-command-window-session-v2.log
assets/demo/esp32-voice-chat-audio-test-forced-command-window-session-v2-markers.log
assets/demo/esp32-voice-chat-audio-test-forced-command-window-session-v2-check.json
```

The fully wake-driven PC-speaker test is still unreliable with Windows TTS:

```text
assets/demo/esp32-voice-chat-audio-test-nihaoxiaozhi-voice-session.log
assets/demo/esp32-voice-chat-audio-test-nihaoxiaozhi-voice-session-check.json
```

That run played `ni hao xiao zhi` 53 times and did not trigger WakeNet. This is
evidence that the current TTS wake-word path needs real-human wake testing,
speaker placement changes, gain/sensitivity tuning, or a better wake model
before it can be called product-grade.

## Model Matrix

| Model package | Wake keyword | Result | Notes |
| --- | --- | --- | --- |
| stock Arduino `srmodels.bin` | `hiesp` | Pass | Stable default path: `Hi E S P -> chat mode`. |
| `wn9_nihaoxiaozhi + mn5q8_en` | `nihaoxiaozhi` | Pass | Full voice-chat chain passed with PC speaker and ESP32 board speaker. |
| `wn9_nihaoxiaozhi_tts + mn5q8_en` | `nihaoxiaozhi` | Fail | Booted, but 36 TTS wake attempts did not trigger WakeNet. |
| `wn9s_nihaoxiaozhi + mn5q8_en` | `nihaoxiaozhi` | Fail / unsafe | ESP-SR initialization repeatedly panicked with `LoadProhibited`; USB-CDC then stopped enumerating normally. |
| any current asset | `xiaoqian` | Not available | Official ESP-SR 2.4.6 component and Arduino stock model do not contain `xiaoqian`. |

Generated model checks:

```text
assets/demo/esp32-sr-models-nihaoxiaozhi-en-check.json
assets/demo/esp32-sr-models-nihaoxiaozhi-tts-en-check.json
assets/demo/esp32-sr-models-nihaoxiaozhi-s-en-check.json
```

Negative target-wake check:

```text
assets/demo/esp32-voice-chat-audio-test-xiaoqian-against-nihaoxiaozhi-v2.log
assets/demo/esp32-voice-chat-audio-test-xiaoqian-against-nihaoxiaozhi-v2-check.json
```

Result: `你好小千` played 15 times against the `nihaoxiaozhi` model and did not trigger WakeNet.

## Current Blocking State

After flashing and testing `wn9s_nihaoxiaozhi`, the board entered a repeated crash loop:

```text
Guru Meditation Error: Core  1 panic'ed (LoadProhibited)
Backtrace: 0x42059774:0x3fcebd20 ...
```

Windows then stopped exposing a usable serial port:

```text
[System.IO.Ports.SerialPort]::GetPortNames() -> no COM7
arduino-cli board list -> No boards found
```

PnP state shows stale or failed USB nodes:

```text
USB 串行设备 (COM7) -> Unknown
USB JTAG/serial debug unit -> Unknown
USB Composite Device VID_303A PID_1001 -> Unknown / not connected
未知 USB 设备(设备描述符请求失败) -> Error, Code 43
```

Software recovery attempts already tried:

```text
pnputil /restart-device USB\VID_303A&PID_1001...
pnputil /remove-device USB\VID_0000&PID_0002...
pnputil /scan-devices
Disable-PnpDevice / Enable-PnpDevice on ESP32 and Code 43 nodes
```

Result: all failed with either `The device is not connected`, `Access is denied`, or `常规故障`. With the current non-admin shell and no physical USB reset, COM7 cannot be recovered.

Latest recheck at 2026-06-16 09:09: `check-proof-readiness.ps1` and
`check-esp32-port-state.ps1` can see COM7 again and the one-byte write probe
passes. The immediate USB/CDC blocker is therefore cleared for the current
session:

```text
state=writable
ports=COM3,COM4,COM5,COM6,COM7
```

Do not keep treating the Code 43 / missing COM7 state above as current unless a
new probe reproduces it. The board has since been restored with the known-good
`wn9_nihaoxiaozhi + mn5q8_en` model image, flashed successfully over COM7, and
validated with a fresh two-turn voice-chat session proof.

## Validation Re-run After Documentation

These checks were re-run after the firmware wake-keyword parameterization and model experiments:

```text
scripts/check-firmware-flow.ps1 -Required
-> passed

apps/api pytest
-> 28 passed

scripts/scan-secrets.ps1 -All
-> clean

default firmware compile
-> passed

ESP-SR firmware compile with nihaoxiaozhi model override
-> passed

ESP-SR upload with nihaoxiaozhi model override
-> passed

scripts/test-esp32-voice-chat-session-audio.ps1 -Port COM7 -Turns 2 -RecordSeconds 5 -Required
-> passed
```

Model content rechecks:

```text
assets/demo/esp32-sr-models-nihaoxiaozhi-en-recheck.json
assets/demo/esp32-sr-models-nihaoxiaozhi-tts-recheck.json
assets/demo/esp32-sr-models-nihaoxiaozhi-s-recheck.json
```

Hardware upload/retest is no longer blocked in the current session.

## Recovery Procedure Once Physical State Can Change

Preferred recovery target: restore the known-good `wn9_nihaoxiaozhi + mn5q8_en` build, or the stock `hiesp` build.

Known-good Chinese wake restore command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 `
  -Port COM7 `
  -EnableEspSr `
  -EspSrWakeKeyword nihaoxiaozhi `
  -EspSrModelsBin (Join-Path $env:TEMP 'homecue-srmodels-nihaoxiaozhi-en.bin') `
  -BuildPath (Join-Path $env:TEMP 'homecue-edge-esp32-sr-build-nihaoxiaozhi') `
  -Upload `
  -UploadSpeed 115200 `
  -UploadMode cdc
```

If COM7 does not appear, put the board into ROM download mode:

```text
1. Hold BOOT.
2. While holding BOOT, tap RESET or replug USB.
3. Release BOOT.
4. Re-run the restore command above.
```

Fallback stable English wake restore command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 `
  -Port COM7 `
  -EnableEspSr `
  -Upload `
  -UploadSpeed 115200 `
  -UploadMode cdc
```

## Code Changes Made During This Investigation

The firmware now supports a build-time wake keyword:

```cpp
#ifndef HOMECUE_SR_WAKE_KEYWORD
#define HOMECUE_SR_WAKE_KEYWORD "hiesp"
#endif
```

`scripts/flash-esp32.ps1` now writes the matching macro into temporary `build_opt.h` and patches only a temporary sketch-local copy of Arduino `ESP_SR` when `-EspSrWakeKeyword` is not `hiesp`. The global Arduino package is not modified.

The model tooling now blocks the known unsafe `wn9s_nihaoxiaozhi` model by default:

```text
scripts/check-esp32-sr-models.ps1
scripts/flash-esp32.ps1
scripts/new-esp32-sr-model-pack.ps1
```

Use the override switches only for deliberate recovery-aware experiments:

```text
-AllowBlockedModel
-AllowBlockedEspSrModel
```

Example build command for a custom wake model:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 `
  -Port COM7 `
  -EnableEspSr `
  -EspSrWakeKeyword nihaoxiaozhi `
  -EspSrModelsBin (Join-Path $env:TEMP 'homecue-srmodels-nihaoxiaozhi-en.bin')
```

## Product Decision

Use MiMo for dialogue. Do not use MiMo for wake detection.

For the next development iteration, the best available practical route is:

```text
你好小智 -> chat mode -> ASR + MiMo + TTS -> ESP32 speaker
```

For the requested product phrase:

```text
你好小千
```

we still need a real `xiaoqian` WakeNet/custom wake model and a rebuilt `srmodels.bin`. Without that model, the ESP32 cannot reliably wake locally on `你好小千`.
## 2026-06-17 Local LAN board-speaker TTS voice check

- Backend under test: local Windows API on `0.0.0.0:8723`, reachable by the ESP32 at `http://192.0.2.118:8723`.
- Board under test: ESP32 on `COM7`, WiFi IP `192.0.2.100`, `/health` returned HTTP 200 after flashing with `-ApiHostOverride 192.0.2.118 -ApiPortOverride 8723`.
- `/voice-chat/status` reported chat provider `mimo`, chat model `mimo-v2.5-pro`, TTS provider `mimo`, TTS model `mimo-v2.5-tts`, TTS voice `Mia`, ASR effective provider `windows`.
- Hardware voice-chat WebSocket proof:
  - log: `assets/demo/esp32-local-lan-tts-voice-check.log`
  - markers: `assets/demo/esp32-local-lan-tts-voice-check-markers.log`
  - result: `assets/demo/esp32-local-lan-tts-voice-check.json`
- Board serial evidence:
  - `[/voice-chat/ws] provider: mimo`
  - `[/voice-chat/ws] tts provider=mimo model=mimo-v2.5-tts voice=Mia`
  - `[speaker] stream playback done data=153600/0 segments=10`
  - `[speaker] playback done`
- Result: board speaker output is currently using MiMo TTS, model `mimo-v2.5-tts`, voice `Mia`. The ES8311 speaker path played 10 streamed binary audio chunks successfully.
- Limitation of this specific run: the command used the WAV-send WebSocket route, so required checks for `ws PCM stream` and `VAD early stop` were WARN. This does not block the TTS/speaker conclusion, but true PCM/VAD realtime capture still needs a dedicated passing run.

## 2026-06-17 MiMo TTS voice selection check

Answer to the current speaker voice question:

```text
current default runtime voice = Mia
current runtime TTS provider  = mimo
current runtime TTS model     = mimo-v2.5-tts
current dialogue model        = mimo-v2.5-pro
board playback path           = MiMo WAV segments -> WebSocket binary stream -> ESP32 ES8311/I2S speaker
```

The ESP32 board does not run the TTS model locally. The local API calls MiMo TTS,
streams the generated WAV segments to the board over `/voice-chat/ws`, and the
board writes those segments to the ES8311 speaker path. The selected voice is
therefore controlled on the API side by `VOICE_CHAT_TTS_VOICE`; firmware does
not need a reflashing just to change voice.

Current service status after restoring the normal runtime:

```json
{
  "provider": "mimo",
  "model": "mimo-v2.5-pro",
  "tts": {
    "provider": "mimo",
    "model": "mimo-v2.5-tts",
    "voice": "Mia",
    "configured": true
  }
}
```

Available ASCII voice names observed from the current MiMo endpoint include:

```text
mimo_default
Mia
Chloe
Milo
Dean
```

Some non-ASCII MiMo voice names were also accepted by backend probes, but ESP32
serial output renders those names as question marks. Hardware-required checks
therefore prefer ASCII voice names.

Temporary alternate-voice hardware test:

```text
runtime override: VOICE_CHAT_TTS_VOICE=Chloe
serial command:   homecue:voice-chat-ws 8
user audio:       PC speaker played "你好小千，现在测试 Chloe 音色，请用一句话回应我。"
```

Evidence:

```text
assets/demo/esp32-local-lan-mimo-tts-chloe.log
assets/demo/esp32-local-lan-mimo-tts-chloe-markers.log
assets/demo/esp32-local-lan-mimo-tts-chloe-check.json
```

Required hardware checks passed:

```text
[OK] ws PCM stream - saw 1/1
[OK] VAD early stop - saw 1/1
[OK] expected TTS provider - expected=mimo saw 1/1
[OK] expected TTS model - expected=mimo-v2.5-tts saw 1/1
[OK] expected TTS voice - expected=Chloe saw 1/1
[OK] streaming reply audio done - saw 1/1
[OK] audio playback - saw 1/1
[OK] no crash - saw 0 crash marker(s)
```

Board serial proof from the Chloe run:

```text
[/voice-chat/ws] tts provider=mimo model=mimo-v2.5-tts voice=Chloe
[/voice-chat/ws] binary audio stream chunk 8 size=30764
[speaker] stream playback done data=130560/0 segments=8
[speaker] playback done
```

Result: MiMo TTS voice switching works with the real ESP32 speaker path. The
runtime was restored afterward to the normal `Mia` voice.

Important correction after the board-speaker investigation below: the old
voice-chat logs prove that the firmware parsed MiMo WAV frames and completed
I2S writes. They did not, by themselves, prove acoustic output from the physical
speaker. Real speaker audibility must be confirmed by listening during a local
tone or voice reply.

## 2026-06-17 Board speaker PA enable and local tone test

Problem reported by the user:

```text
The ESP32 serial logs showed [speaker] playback done, but no sound had ever
been heard from the board speaker.
```

Root-cause finding:

```text
The firmware initialized ES8311 and wrote samples to I2S, but it did not
explicitly enable the external speaker power amplifier. The Waveshare official
demo enables the PA with Audio_PA_EN() -> Set_EXIO(TCA9555_EXIO8, true).
```

Firmware change:

```text
firmware/esp32-audio/esp32-audio.ino

- Added SPEAKER_PA_CTRL_PIN = 8.
- Added enableSpeakerPowerAmp(), using the existing TCA9555 driver to set
  EXIO8 as output high.
- Enables the PA during setup and before normal WAV/streaming speaker playback.
- Added homecue:speaker-test [seconds], a local 880 Hz stereo test tone that
  bypasses ASR, MiMo, TTS, WebSocket, and PC-speaker placement.
```

Automation change:

```text
scripts/test-esp32-speaker-tone.ps1
```

The script sends `homecue:speaker-test N`, captures serial output, and requires:

```text
audio route ready
speaker PA enabled
speaker test started with pa=on
I2S sample writes completed
no short write
no panic/reset after command
```

Build and flash proof:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 `
  -Port COM7 -Upload -EnableEspSr `
  -ApiHostOverride 192.0.2.118 -ApiPortOverride 8723 `
  -BuildPath $env:TEMP\homecue-edge-esp32-build-speaker-pa
```

Result:

```text
compile: passed
upload : passed
board  : COM7, WiFi IP 192.0.2.100
```

Final isolated tone proof:

```text
log:    assets/demo/esp32-speaker-tone-pa8-full-test.log
result: assets/demo/esp32-speaker-tone-pa8-full-test-check.json
```

Key serial markers:

```text
[speaker] PA enabled pin=8
> serial homecue:speaker-test 4
[serial] SPEAKER TEST -> 4s
[speaker-test] start rate=16000 channels=2 freq=880Hz volume=100 duration=4s pa=on
[speaker-test] done wrote=256000 expected=256000
[speaker-test] mic RX restored
```

Required checks passed:

```text
[OK] audio route ready
[OK] speaker PA enabled
[OK] speaker test started
[OK] speaker test wrote samples
[OK] no short write
[OK] TX configured
[OK] speaker test available
[OK] speaker test did not fail
[OK] no crash markers
```

Additional listening-window run:

```text
log:    assets/demo/esp32-speaker-tone-pa8-listen-10s.log
result: assets/demo/esp32-speaker-tone-pa8-listen-10s-check.json

[speaker-test] start rate=16000 channels=2 freq=880Hz volume=100 duration=10s pa=on
[speaker-test] done wrote=640000 expected=640000
```

Post WebSocket-fix speaker regression:

```text
log:    assets/demo/esp32-speaker-tone-after-ws-fix.log
result: assets/demo/esp32-speaker-tone-after-ws-fix-check.json

[speaker-test] start rate=16000 channels=2 freq=880Hz volume=100 duration=5s pa=on
[speaker-test] done wrote=320000 expected=320000
[speaker-test] mic RX restored
```

Remaining manual confirmation:

```text
Serial can prove PA enable, ES8311/I2S setup, generated samples, complete I2S
writes, and no crash. It still cannot prove acoustic output. The user must
confirm whether the 5-second 880 Hz tone was audible from the physical speaker.
```

If the tone was still not audible, the next focused suspects are:

```text
speaker connector/cable or physical speaker module
PA polarity or board revision mismatch
I2S slot format/channel mapping
ES8311 DAC output path / mute state beyond the current voice-volume API
```

## 2026-06-17 Realistic WebSocket voice chat speaker proof

Problem found after the PA fix:

```text
The local speaker tone path passed, but the realistic voice-chat test still
stopped after:

[/voice-chat/ws] llm start
[serial] VOICE CHAT WS failed
```

Root-cause finding:

```text
VOICE_CHAT_WS_TURN_TIMEOUT_MS was 65 seconds and each turn deadline started
before board recording began. In the realistic chain, 8 seconds of board
recording plus Windows ASR plus MiMo LLM/TTS could consume the whole response
window before the ESP32 received llm/stop and TTS audio.
```

Firmware change:

```text
firmware/esp32-audio/esp32-audio.ino

- Increased VOICE_CHAT_WS_TURN_TIMEOUT_MS from 65000 to 120000.
- Moved the turn response deadline to after listen/stop is sent, so recording
  and audio upload no longer consume reply wait time.
- Added a frame-wait timeout diagnostic with ready / has_reply / wait_audio
  state.
```

Build and flash proof:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 `
  -Port COM7 -Upload -EnableEspSr `
  -ApiHostOverride 192.0.2.118 -ApiPortOverride 8723 `
  -BuildPath $env:TEMP\homecue-edge-esp32-build-ws-timeout
```

Result:

```text
compile: passed
upload : passed
```

Realistic speaker-interaction proof:

```text
log:     assets/demo/esp32-pa8-realtime-voice-chat-timeout-fix.log
markers: assets/demo/esp32-pa8-realtime-voice-chat-timeout-fix-markers.log
result:  assets/demo/esp32-pa8-realtime-voice-chat-timeout-fix-check.json
```

Scenario:

```text
PC speaker acted as the human user and played:
你好小千，请通过开发板喇叭用一句话回答我，现在测试真实语音聊天。

ESP32 microphone captured the audio, sent PCM over WebSocket, received a MiMo
reply, received MiMo TTS binary audio chunks, and played them through the
board speaker path.
```

Key serial markers:

```text
[/voice-chat/ws] streamed 512000 PCM bytes (8000ms, speech)
[/voice-chat/ws] provider: mimo
[/voice-chat/ws] tts provider=mimo model=mimo-v2.5-tts voice=Mia
[/voice-chat/ws] reply audio stream ready
[/voice-chat/ws] binary audio stream chunk 11 size=30764
[/voice-chat/ws] reply audio stream complete chunks=11
[speaker] stream playback done data=176640/0 segments=11
[speaker] playback done
[/voice-chat/ws] ready turn=1
```

Required checks passed:

```text
[OK] ws PCM stream - saw 1/1
[OK] ws stt - saw 1/1
[OK] mimo provider - saw 1/1
[OK] reply audio ready - saw 1/1
[OK] binary reply audio - saw 11/1
[OK] chunked reply audio complete - saw 1/1
[OK] streaming reply audio done - saw 1/1
[OK] expected TTS provider - expected=mimo saw 1/1
[OK] expected TTS model - expected=mimo-v2.5-tts saw 1/1
[OK] expected TTS voice - expected=Mia saw 1/1
[OK] audio playback - saw 1/1
[OK] no crash - saw 0 crash marker(s)
```

Remaining tuning item:

```text
VAD early stop did not trigger in this run: the board streamed the full 8s.
This no longer blocks speaker playback or MiMo voice-chat proof, but the VAD
thresholds should be tuned for the actual speaker distance and room noise.
```

## 2026-06-17 Voice-triggered WebSocket chat and ASR no-match recovery

Goal:

```text
Move from serial-only chat triggering toward a XiaoZhi-style board interaction:
ESP-SR command phrase -> WebSocket voice-chat session -> MiMo reply -> MiMo TTS
-> ESP32 board speaker.
```

Confirmed boundary:

```text
The target wake phrase "ni hao xiao qian" still needs a real xiaoqian WakeNet
or custom wake model. The current verified local wake stack is hiesp +
English MultiNet. MiMo is sufficient after ASR for dialogue and TTS; it cannot
replace local wake-word detection.
```

Firmware changes:

```text
firmware/esp32-audio/esp32-audio.ino

- VAD now requires a short continuous speech candidate window before treating
  a turn as speech.
- The earliest WebSocket VAD stop was raised from 1200ms to 2500ms.
- WebSocket stt/no_match events are logged as "no speech detected" and treated
  as a recoverable ready turn instead of a transport failure.
```

API changes:

```text
apps/api/app/voice_chat.py
apps/api/app/voice_chat_ws.py

- ASR provider unavailable still returns 501.
- ASR provider available but no speech recognized now returns 422.
- /voice-chat/ws maps 422 to:
  stt/no_match
  listen/ready
  and keeps the WebSocket session alive.
```

Test coverage:

```text
apps/api/tests/test_api.py

4 focused tests passed:
- /voice returns 422 when ASR hears no speech.
- /voice can still use Windows Speech ASR.
- /voice-chat/ws accepts binary PCM.
- /voice-chat/ws keeps the session ready after ASR no-match.
```

Automation update:

```text
scripts/test-esp32-voice-chat-audio.ps1

- Can validate the current WebSocket voice-chat route, not only the older HTTP
  /voice-chat route.
- Adds ExpectedReplyTurns so no-match recovery tests and full-reply tests have
  separate pass criteria.
- Adds RequireNoFallback to prove recoverable ASR misses do not fall back to
  HTTP.
- Tolerates ESP32-S3 USB CDC read interruptions during reset.
```

Hardware evidence:

```text
log:    assets/demo/esp32-voice-trigger-ws-chat-no-match-recovery.log
result: assets/demo/esp32-voice-trigger-ws-chat-no-match-recovery-check.json
```

Important serial markers:

```text
[serial] VOICE COMMAND WINDOW
[esp-sr] forced command window - say a command word
[voice] chat mode
[/voice-chat/ws] hello session=89d257f8e28f4e5a81df2336463e57f3
[voice-session/ws] turn 1/2
[/voice-chat/ws] provider: mimo
[/voice-chat/ws] tts provider=mimo model=mimo-v2.5-tts voice=Mia
[speaker] stream playback done data=168960/0 segments=11
[speaker] playback done
[voice-session/ws] turn 2/2
[/voice-chat/ws] no speech detected: Voice transcription did not detect speech.
[/voice-chat/ws] ready turn=0
```

What this proves:

```text
The "chat mode" command can trigger the WebSocket voice-chat session.
At least one voice-triggered turn completed MiMo dialogue, MiMo TTS, and board
speaker playback.
If a later turn is not recognized by ASR, the WebSocket session now recovers
without HTTP fallback or crash.
```

Current external hardware state:

```text
After the latest reset, Windows stopped publishing the ESP32 USB CDC COM7 port.
PnP still shows stale VID_303A/PID_1001 interface instances, but pnputil reports
them as not connected and the serial port list only contains Bluetooth COM
ports. The code/API fixes above are compiled and flashed, but the final
"two recognized turns, two MiMo replies" hardware proof is paused until COM7
re-enumerates.
```

Follow-up API hardening:

```text
apps/api/app/config.py now defaults VOICE_CHAT_MEMORY_DB to
runtime/voice-chat.sqlite when the variable is unset. This prevents local API
restarts from silently dropping back to in-process memory.
```

Backend verification:

```text
result: assets/demo/voice-chat-ws-default-sqlite-memory-check.json

/voice-chat/status:
- provider=mimo
- tts.provider=mimo
- tts.model=mimo-v2.5-tts
- tts.voice=Mia
- memory.sqlite_enabled=true
- asr.effective_provider=windows
- realtime.websocket=true

The WebSocket text turn returned provider=mimo, turn=1, and reply_audio was
requested successfully.
```

## 2026-06-17 Browser voice-console architecture update

The React console is now also a protocol-compatible voice debug client for the
same `/voice-chat/ws` route used by the ESP32.

Implemented browser-side capabilities:

```text
Connect -> /voice-chat/ws hello
Send turn -> JSON text turn over the same session protocol
Start mic -> browser microphone PCM upload as pcm_s16le binary frames
Stop -> listen/stop and final ASR/LLM/TTS turn completion
TTS playback -> queue returned MiMo WAV WebSocket binary frames in Web Audio
Shared state -> uses user_id=home-user and device_id=web-console/web-mic
```

Verification:

```text
npm run build
npm run lint
Playwright page check against http://127.0.0.1:5173
```

Observed browser proof:

```text
voice status = connected
reply = 你好，我在这里呢。有什么可以帮你的吗？
audio state = reply audio complete
tts transport = websocket_binary_stream
binary TTS frames observed in the page event log
```

Evidence:

```text
assets/demo/web-voice-console-realtime-panel.png
assets/demo/voice-console-runtime-stack.png
```

Runtime-stack panel update:

```text
GET /voice-chat/status -> rendered in the React voice console
dialogue = mimo / mimo-v2.5-pro
tts      = mimo / mimo-v2.5-tts / Mia
asr      = windows, configured as auto / zh-CN
memory   = sqlite enabled
transport= websocket / pcm_s16le
stream   = tts stream, partial stt, half duplex
```

Headless Playwright verification loaded
`http://127.0.0.1:5173?apiBase=http://127.0.0.1:8723`, waited for
`.runtime-stack`, found all expected provider/model/voice/runtime labels, and
reported no page errors.

Notes:

```text
The automated browser proof intentionally did not accept microphone permission.
The UI and code path for microphone PCM upload are present, but real microphone
permission must be granted by the user in the browser at runtime.
```

New architecture documentation:

```text
docs/voice-system-architecture.md
```

A separate private project-notes document was written outside the public repo so
the repository can keep its public technical-only content rule.

## 2026-06-17 Local voice-system readiness proof

The local backend/runtime path now has a single readiness script that does not
need ESP32 hardware:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-voice-system-readiness.ps1 `
  -ApiBase http://127.0.0.1:8723 `
  -ResultJsonPath .\assets\demo\voice-system-readiness-check.json `
  -WsResultJsonPath .\assets\demo\voice-system-readiness-ws-check.json `
  -PcmWsResultJsonPath .\assets\demo\voice-system-readiness-ws-pcm-check.json `
  -TtsWsResultJsonPath .\assets\demo\voice-system-readiness-ws-tts-stream-check.json `
  -Required
```

Evidence:

```text
assets/demo/voice-system-readiness-check.json
assets/demo/voice-system-readiness-ws-check.json
assets/demo/voice-system-readiness-ws-pcm-check.json
assets/demo/voice-system-readiness-ws-tts-stream-check.json
```

Checks covered by the latest passing run:

```text
-> /health reachable, provider=mimo
-> /voice-chat/status reports dialogue=mimo/mimo-v2.5-pro
-> TTS provider/model/voice = mimo / mimo-v2.5-tts / Mia
-> ASR effective provider = windows
-> memory.sqlite_enabled = true
-> realtime websocket=true, pcm_s16le=true
-> declared gaps: full_duplex=false, opus_stream=false
-> POST /voice-chat text turn returns provider=mimo, turn=1
-> /voice-chat/ws hello/listen flow returns provider=mimo, turn=1
-> WebSocket echoes user_id=home-user and device_id=readiness-script
-> /voice-chat/ws accepts Windows-TTS generated pcm_s16le binary frames
-> latest PCM proof sent 171520 bytes in 90 frames
-> ASR recognized the PCM turn and MiMo returned turn=1
-> /voice-chat/ws streams MiMo TTS reply audio over the WebSocket downlink
-> latest TTS stream proof returned mimo/mimo-v2.5-tts/Mia
-> latest TTS stream proof returned non-empty WebSocket binary audio frames
-> memory extraction returns rows
-> task extraction returns rows
-> mood extraction returns rows
-> /voice-chat/tasks/due-audio returns ready MiMo TTS audio metadata
```

This proves the current local service stack is ready for voice-chat backend
testing and MiMo TTS generation. It intentionally does not prove ESP32 speaker
acoustic output; the physical speaker still needs the COM7 resume test below.

## 2026-06-17 Board speaker audible-output re-check

User report:

```text
The board speaker has not been audibly heard, despite earlier serial logs that
showed PA enable, I2S writes, streaming playback done, and playback done.
```

Important correction:

```text
Older artifacts such as esp32-speaker-tone-after-ws-fix-check.json and
esp32-pa8-realtime-voice-chat-timeout-fix-check.json prove the firmware reached
the ES8311/I2S write path. They do not prove acoustic output from the physical
speaker. Treat them as electrical/software-path evidence only.
```

Current firmware hardening:

```text
firmware/esp32-audio/esp32-audio.ino

- homecue:speaker-test now accepts:
  homecue:speaker-test <seconds> [all|both|left|right|sweep]
- The default mode is all:
  both-channel tone -> left-slot tone -> right-slot tone -> sweep.
- The test logs TCA9555_EXIO8 PA readback as high before playback.
- Speaker TX now explicitly configures I2S_STD_SLOT_BOTH.
- Mono WAV reply audio is duplicated into stereo frames before I2S writes.
- WebSocket streaming MiMo TTS chunks use the same mono-to-stereo write path.
- configureTX failures are now logged instead of ignored.
- Shared I2S/MCLK startup now runs before ES7210/ES8311 codec init.
- ES8311 speaker init is no longer blocked by a missing ESP-SR model partition.
- speaker-test and voice recording pause ESP-SR only when the ESP-SR task
  actually started, so audio diagnostics can run even when WakeNet/MultiNet is
  unavailable.
```

Automation update:

```text
scripts/test-esp32-speaker-tone.ps1

- Adds -ToneMode all|both|left|right|sweep.
- Requires PA readback high.
- In all mode, expects four speaker-test start/done segments.
```

Software verification completed:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 `
  -Clean -BuildPath $env:TEMP\homecue-edge-esp32-speaker-diag-default-build
-> passed

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 `
  -Clean -EnableEspSr -BuildPath $env:TEMP\homecue-edge-esp32-speaker-diag-sr-build
-> passed

scripts/check-firmware-flow.ps1 -Required
-> passed

scripts/test-esp32-speaker-tone.ps1
-> PowerShell syntax check passed

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 `
  -Clean -BuildPath $env:TEMP\homecue-edge-esp32-speaker-default-build `
  -UploadSpeed 115200 -UploadMode cdc
-> passed

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 `
  -Clean -EnableEspSr `
  -BuildPath $env:TEMP\homecue-edge-esp32-speaker-audio-order-build `
  -UploadSpeed 115200 -UploadMode cdc
-> passed

PowerShell parser check for speaker/flash/port helper scripts
-> passed
```

Hardware status:

```text
COM7 is not currently enumerated. serial.tools.list_ports only reports
Bluetooth COM ports, so the updated speaker diagnostic firmware has not yet
been uploaded or acoustically checked in this run.

Port-state evidence:
assets/demo/esp32-port-state-speaker-recheck.json
assets/demo/esp32-port-state-speaker-final-check.json
state=missing
detectedPorts=COM3,COM4,COM5,COM6
openError=The port 'COM7' does not exist.

PnP still shows a present unknown USB device with descriptor request failure:
USB\VID_0000&PID_0002\6&1266488A&0&2
```

Continuation check on the resumed goal turn:

```text
assets/demo/esp32-port-state-continuation-check.json
state=missing
detectedPorts=COM3,COM4,COM5,COM6
```

Final current-state check on 2026-06-17 11:24:

```text
assets/demo/esp32-port-state-speaker-final-current.json
state=missing
detectedPorts=COM3,COM4,COM5,COM6

assets/demo/esp32-speaker-audible-final-current-summary.json
status=timed-out
finalPortState=missing
uploadExitCode=null
toneExitCode=null
```

This confirms the resume automation did not reach upload or tone playback in
the current Windows USB state.

Follow-up current-state check on 2026-06-17 11:58:

```text
assets/demo/esp32-speaker-audible-fix-summary.json
status=timed-out
finalPortState=missing
uploadExitCode=null
toneExitCode=null

assets/demo/esp32-speaker-audible-fix-port-state.json
state=missing
detectedPorts=COM3,COM4,COM5,COM6
openError=The port 'COM7' does not exist.

Windows PnP still reports:
USB\VID_0000&PID_0002\6&1266488A&0&2
FriendlyName=Unknown USB Device (Device Descriptor Request Failed)
```

This follow-up confirms the firmware fix has been compiled but not uploaded to
the board, because Windows still does not enumerate the ESP32 serial device.

Auto-detect follow-up on 2026-06-17 12:05:

```text
assets/demo/esp32-port-state-after-reset-autodetect.json
autoDetectEsp32=true
state=missing
requestedPort=COM7
port=COM7
detectedPorts=COM3,COM4,COM5,COM6
portCandidates=COM3..COM6 score=-80 reason=bluetooth

assets/demo/esp32-speaker-audible-autodetect-dry-summary.json
status=timed-out
finalPortState=missing
requestedPort=COM7
port=COM7
```

This confirms the new auto-detect path does not mistake Bluetooth serial ports
for the ESP32. When the board reappears as an Espressif/USB-serial COM port,
the same resume script can continue even if the COM number is no longer COM7.

Additional speaker-first probe on 2026-06-17:

```text
Current local API:
GET /voice-chat/status
provider=mimo
model=mimo-v2.5-pro
tts.provider=mimo
tts.model=mimo-v2.5-tts
tts.voice=Mia

Current Windows serial enumeration:
serial.tools.list_ports
COM3, COM4, COM5, COM6 only; all are Bluetooth serial ports.

Network due-audio bypass probe:
assets/demo/esp32-speaker-network-due-audio-probe.json
created a due task for user_id=home-user
waited 75s
local-api-8723.out.log bytes did not change
new ESP32 due-audio requests=0
new ESP32 WAV audio requests=0
```

This means the current board is not reachable over USB serial and did not
appear to be polling the local API over Wi-Fi during the no-serial due-audio
probe. The speaker cannot be re-tested acoustically from software until at
least one control path returns.

Hardware interpretation risk:

```text
The Waveshare ESP32-S3-AUDIO-Board route is ES8311 codec + power amplifier +
speaker connector. Treat "board speaker" as "the speaker connected to the
board speaker output." If no real speaker is connected to the SPK/speaker
header, serial logs can show ES8311 ready, PA high, I2S writes, and playback
done while the room stays silent.
```

Firmware/test update after this probe:

```text
firmware/esp32-audio/esp32-audio.ino
- Added HOMECUE_BOOT_SPEAKER_TEST compile-time switch.
- When enabled with ENABLE_ESP_SR=1, setup() runs a boot-time speaker test
  before Wi-Fi/health and reminder polling.

scripts/flash-esp32.ps1
- Added -BootSpeakerTest, -BootSpeakerTestSeconds, and -BootSpeakerTestMode.
- Added -DiagHttpServer for a tiny board-side diagnostic HTTP server.

scripts/resume-esp32-speaker-audible-test.ps1
- Defaults to flashing the boot speaker-test diagnostic build, then still runs
  the serial all-mode speaker tone test.
- Pass -NoBootSpeakerTest for a quiet diagnostic build.
- The diagnostic build also enables board-side HTTP `/health` and
  `/speaker-test?seconds=8&mode=all` unless `-NoDiagHttpServer` is passed.

scripts/test-esp32-speaker-http-tone.ps1
- Added a direct Wi-Fi trigger for the diagnostic firmware. It calls board
  `/health`, then board `/speaker-test`, so USB serial is not required once the
  diagnostic firmware has been flashed and the board is on Wi-Fi.

scripts/test-esp32-speaker-network-due-audio.ps1
- Added a no-serial probe that creates an immediate due-audio reminder and
  watches the API log for ESP32 due-audio and WAV requests.
```

Automation added:

```text
scripts/resume-esp32-speaker-audible-test.ps1
```

This script waits for `COM7` or an auto-detected ESP32 serial port to become
writable, then flashes the current ESP-SR speaker diagnostic firmware and runs
the all-mode speaker tone check. The diagnostic firmware also plays a boot-time
speaker test unless `-NoBootSpeakerTest` is passed.
It also starts a board-side HTTP diagnostic server unless `-NoDiagHttpServer`
is passed, giving a no-USB trigger after the diagnostic firmware is installed.
It writes a summary JSON plus the latest port-state and tone-test artifacts
under an `-OutputPrefix`. Dry-run evidence in the current missing-port state:

```text
assets/demo/esp32-speaker-audible-recheck-auto-dry-summary.json
assets/demo/esp32-speaker-audible-recheck-auto-dry-port-state.json
assets/demo/esp32-speaker-audible-fix-summary.json
assets/demo/esp32-speaker-audible-fix-port-state.json
assets/demo/esp32-speaker-audible-autodetect-dry-summary.json
assets/demo/esp32-speaker-audible-autodetect-dry-port-state.json
status=timed-out
finalPortState=missing
```

One-shot resume command when COM7 may reappear:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\resume-esp32-speaker-audible-test.ps1 `
  -Port COM7 `
  -AutoDetectEsp32 `
  -MaxWaitSeconds 900 `
  -ApiHostOverride 192.0.2.118 `
  -ApiPortOverride 8723 `
  -OutputPrefix .\assets\demo\esp32-speaker-audible-recheck-auto `
  -Required
```

Manual command sequence when COM7 reappears:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-esp32.ps1 `
  -Port COM7 `
  -Upload `
  -EnableEspSr `
  -ApiHostOverride 192.0.2.118 `
  -ApiPortOverride 8723 `
  -BuildPath $env:TEMP\homecue-edge-esp32-speaker-diag-sr-build `
  -UploadSpeed 115200 `
  -UploadMode cdc

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-esp32-speaker-tone.ps1 `
  -Port COM7 `
  -Seconds 25 `
  -ToneSeconds 8 `
  -ToneMode all `
  -SaveLogPath .\assets\demo\esp32-speaker-audible-recheck-all.log `
  -ResultJsonPath .\assets\demo\esp32-speaker-audible-recheck-all-check.json `
  -Required
```

How to interpret the next run:

```text
If PA readback is low or missing:
  focus on TCA9555 EXIO8 / PA enable / board revision.

If PA readback is high, four segments write completely, but nothing is audible:
  focus on physical speaker/connector, PA polarity, ES8311 analog output path,
  or board-level hardware.

If only left or only right is audible:
  focus on I2S slot/channel mapping.

If sweep is audible but normal MiMo voice is not:
  focus on WAV sample-rate/channel handling or streaming TTS chunk handling.
```

## 2026-06-17 speaker-first follow-up: official demo comparison

User priority:

```text
First make the board speaker play audibly. The user has not heard output from
the board speaker yet, so speaker playback must be treated as unproven even if
older logs show ES8311/I2S writes and playback done.
```

Official Waveshare demo comparison:

```text
Source checked:
https://www.waveshare.com/wiki/ESP32-S3-AUDIO-Board

Downloaded demo package:
https://files.waveshare.com/wiki/ESP32-S3-AUDIO-Board/ESP32-S3-AUDIO-Board-Demo.zip

Relevant files in the demo:
Arduino/examples/LVGL_Arduino/Audio_ES8311.cpp
Arduino/examples/LVGL_Arduino/I2S_Driver.h
Arduino/examples/LVGL_Arduino/TCA9555PWR.cpp
```

Confirmed board route from the official files:

```text
ES8311 speaker I2S:
  BCLK/SCLK = GPIO13
  LRCK/LCLK = GPIO14
  DOUT      = GPIO16
  MCLK      = GPIO12

Speaker PA:
  Audio_PA_EN() -> Set_EXIO(TCA9555_EXIO8, true)
  then delay 50 ms

ES8311 codec init:
  es8311_init(...)
  es8311_voice_volume_set(...)
  es8311_microphone_config(es_handle, false)
```

Firmware changes made from that comparison:

```text
firmware/esp32-audio/esp32-audio.ino
- Kept the same official I2S pins and PA EXIO8 route.
- Added the official-style ES8311 analog mic path config:
  es8311_microphone_config(g_es8311, false)
- Added a 50 ms PA settle delay after setting EXIO8 high.
- Expanded PA diagnostics to log/read:
  input register, output register, and config register
- Added the same PA register details to board HTTP `/health` and
  `/speaker-test` JSON.
```

Build verification after the change:

```text
scripts/check-firmware-flow.ps1 -Required
  passed

scripts/flash-esp32.ps1 -Clean ...
  default firmware compile passed
  build path: %TEMP%/homecue-edge-esp32-speaker-pa-vendor-default-build

scripts/flash-esp32.ps1 -Clean -EnableEspSr -BootSpeakerTest -DiagHttpServer ...
  diagnostic ESP-SR firmware compile passed
  build path: %TEMP%/homecue-edge-esp32-speaker-pa-vendor-sr-build
```

Current reachability result:

```text
assets/demo/esp32-port-state-speaker-pa-vendor-autodetect.json
state=missing
requestedPort=COM7
detectedPorts=COM3,COM4,COM5,COM6
all detected ports are Bluetooth serial ports

assets/demo/<speaker web tone diagnostic check>.json
boardBaseUrl=http://<board-lan-ip>
healthOk=false
toneOk=false
error=unable to connect to remote server
```

Reset follow-up on 2026-06-17:

```text
assets/demo/esp32-port-state-after-reset-usb-error.json
assets/demo/esp32-port-state-speaker-focus-after-pnp.json
state=usb-error
requestedPort=COM7
detectedPorts=COM3,COM4,COM5,COM6
usbProblemDevices[0].name=Unknown USB Device (Device Descriptor Request Failed)
usbProblemDevices[0].configManagerErrorCode=43
PnP problem=CM_PROB_FAILED_POST_START

scripts/resume-esp32-speaker-audible-test.ps1
OutputPrefix=assets/demo/esp32-speaker-after-reset-auto
status=timed-out
finalPortState=missing before the USB-error classifier was added
```

Software-side USB recovery was attempted again during the speaker-first pass:

```text
pnputil /scan-devices
result=Access is denied

pnputil /restart-device USB\VID_0000&PID_0002\6&1266488A&0&2
result=Access is denied
```

No-USB bypasses were also checked:

```text
assets/demo/esp32-speaker-lan-tone-speaker-focus.json
boardBaseUrl=http://<board-lan-ip>
healthOk=false
toneOk=false

assets/demo/esp32-speaker-lan-tone-candidate-a-speaker-focus.json
boardBaseUrl=http://<board-lan-ip-candidate-a>
healthOk=false
toneOk=false

assets/demo/esp32-speaker-lan-tone-candidate-b-speaker-focus.json
boardBaseUrl=http://<board-lan-ip-candidate-b>
healthOk=false
toneOk=false

assets/demo/esp32-speaker-network-due-audio-8734-speaker-focus.json
apiBase=http://127.0.0.1:8734
dueAudioRequestCount=0
audioWavRequestCount=0
```

Interpretation: at this moment the board cannot be driven by USB serial, direct
board HTTP diagnostics, or due-audio auto-poll. The remaining blocker is board
reachability before acoustic speaker validation can continue.

`check-esp32-port-state.ps1` now distinguishes three different failure shapes:

```text
missing   -> no likely ESP32 serial or USB node
usb-error -> Windows sees a matching USB problem node, but no COM port
hung      -> COM port opens, but one-byte write times out
```

Current conclusion:

```text
The next speaker diagnostic firmware is ready, but it has not been uploaded to
the board because Windows does not currently enumerate the ESP32 serial port.
The board also is not reachable at the tested Wi-Fi diagnostic URL, so HTTP is
not a current bypass. Old logs prove that `192.0.2.100`, `192.0.2.106`,
and `192.0.2.110` have all previously appeared as ESP32 addresses, but none
of those addresses answered the current `/health` + `/speaker-test` probes.

Once the board reappears, the expected first audible proof is:
1. Flash diagnostic firmware with -EnableEspSr -BootSpeakerTest -DiagHttpServer.
2. Listen for the boot-time all-mode speaker tone.
3. If no tone is heard, inspect the new PA register diagnostics:
   speaker_pa_readback, speaker_pa_input_reg, speaker_pa_output_reg,
   speaker_pa_config_reg.
4. If PA is high and I2S writes complete but nothing is audible, treat the
   remaining suspects as physical speaker/header connection, PA polarity/board
   revision, or ES8311 analog output hardware.
```

## 2026-06-17 software-side progress while USB is blocked

Because the board is still not writable after reset, work continued on the
software side of the XiaoZhi-like voice system.

Current API/runtime proof:

```text
Temporary current-code API:
http://127.0.0.1:8734

GET /health
planner_provider=mimo
active_provider=mimo
model=mimo-v2.5-pro

GET /voice-chat/status
tts.provider=mimo
tts.model=mimo-v2.5-tts
tts.voice=Mia
asr.effective_provider=windows
memory.sqlite_enabled=true
realtime.websocket=true
realtime.pcm_s16le=true
realtime.mimo_streaming_tts=true
```

Backend improvement:

```text
apps/api/app/voice_chat.py
- Automatic memory extraction now updates an existing identical memory instead
  of inserting another duplicate row.
- Automatic task extraction now updates an existing matching open task instead
  of inserting another duplicate row.
- Memory, task, and mood listing APIs over-fetch recent rows, collapse duplicate
  display items, then apply the requested limit.
- Raw history remains in SQLite; the de-duplication is for product display and
  assistant context.
```

Verification:

```text
apps/api/.venv/Scripts/python.exe -m pytest tests/test_api.py -q
60 passed, 1 warning

Direct API counts on current-code API:
memories=2
tasks=7
moods=2

Browser/Web proof:
assets/demo/web-voice-console-8734-dedup-final-check.json
assets/demo/web-voice-console-8734-dedup-final.png

The page still shows Realtime voice, MiMo dialogue `mimo-v2.5-pro`, MiMo TTS
`mimo-v2.5-tts / Mia`, WebSocket `pcm_s16le`, and ESP32 speaker Health/Tone.
The voice memory panel now shows de-duplicated memory/task/mood cards instead
of repeated readiness-test rows.
```

## 2026-06-17 speaker-first current pass

User priority:

```text
First make the board-side speaker output audible. The user still has not heard
sound from the ESP32 speaker path, so do not treat prior serial "playback done"
markers as acoustic proof.
```

What is verified in software now:

```text
scripts/check-firmware-flow.ps1 -Required
-> passed

scripts/flash-esp32.ps1 -Clean -EnableEspSr -BootSpeakerTest
  -BootSpeakerTestSeconds 8 -BootSpeakerTestMode all -DiagHttpServer
  -BuildPath %TEMP%/homecue-edge-esp32-speaker-focus-compile-now
-> compile passed
-> sketch size 1,474,261 bytes / 46%
```

The compiled diagnostic firmware contains:

```text
homecue:speaker-test <seconds> [all|both|left|right|sweep]
HOMECUE_BOOT_SPEAKER_TEST boot-time all-mode tone
HTTP /health and /speaker-test?seconds=8&mode=all
ES8311 init before speaker playback
TCA9555 EXIO8 PA enable with 50 ms settle delay
PA input/output/config register diagnostics
I2S pins aligned with the Waveshare demo:
  MCLK=12, BCLK/SCLK=13, LRCK=14, speaker DOUT/DSDIN=16
mono WAV duplicated to stereo before I2S TX
```

Current reachability evidence from this pass:

```text
assets/demo/esp32-speaker-focus-port-state-usb-error-now.json
state=usb-error
requestedPort=COM7
detectedPorts=COM3,COM4,COM5,COM6
usbProblemDevices[0].name=Unknown USB Device (Device Descriptor Request Failed)
usbProblemDevices[0].configManagerErrorCode=43

pnputil /enum-devices /problem
USB\VID_0000&PID_0002\6&1266488a&0&2
Problem Code: 43 (0x2B) [CM_PROB_FAILED_POST_START]

pnputil /scan-devices
-> Access is denied

pnputil /restart-device USB\VID_0000&PID_0002\6&1266488A&0&2
-> Access is denied
```

Network bypass checks in this pass:

```text
PC LAN API health:
http://192.0.2.118:8723/health
-> status=ok, provider=mimo, model=mimo-v2.5-pro

Board HTTP tone candidates:
assets/demo/esp32-speaker-lan-tone-candidate-current.json
boardBaseUrl=http://<board-lan-ip-current>
healthOk=false
toneOk=false

assets/demo/esp32-speaker-lan-tone-candidate-alt.json
boardBaseUrl=http://<board-lan-ip-alt>
healthOk=false
toneOk=false
```

Hardware interpretation:

```text
The Waveshare ESP32-S3-AUDIO-Board exposes an ES8311 speaker path through a
Speaker header. Treat "board speaker" as the speaker connected to that header,
not as proof that a self-contained loudspeaker is already present. If no speaker
is connected to the header, the firmware can correctly log PA high and I2S
writes while the user hears nothing.
```

Current conclusion:

```text
The board speaker path is ready to test in firmware, but the test cannot be run
right now because the board is not controllable. Windows currently sees only a
USB descriptor-failure device and no ESP32 COM port, and the tested Wi-Fi
diagnostic URLs do not answer.

The next meaningful action after USB/Wi-Fi reachability returns is:

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\resume-esp32-speaker-audible-test.ps1 `
  -Port COM7 `
  -AutoDetectEsp32 `
  -MaxWaitSeconds 900 `
  -ApiHostOverride 192.0.2.118 `
  -ApiPortOverride 8723 `
  -OutputPrefix .\assets\demo\esp32-speaker-audible-recheck-auto `
  -Required

Expected acoustic behavior after flashing:
1. The boot speaker test should play an 8-second all-mode tone.
2. The serial all-mode tone should then play both, left, right, and sweep
   segments.
3. If PA readback is high and I2S writes complete but there is still no sound,
   focus on the physical speaker/header connection, PA polarity/board revision,
   or ES8311 analog output hardware.
```

Detailed speaker-only tracker:

```text
firmware/esp32-audio/SPEAKER-PLAYBACK-CURRENT-ISSUES-2026-06-17.md
```

Additional firmware hardening from the latest speaker pass:

```text
esp32-audio.ino now reconfigures ES8311 playback sample rate before normal WAV
playback, boot/serial speaker-test tones, and WebSocket streaming MiMo TTS WAV
segments. This reduces the risk of MiMo 24 kHz TTS being sent over I2S at a
different rate than the codec's prior boot-time 16 kHz configuration.
```
