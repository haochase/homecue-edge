# HomeCue Edge Voice System Architecture

Date: 2026-06-17

Related technical document:

- `firmware/esp32-audio/SPEAKER-PHYSICAL-CLOSURE-RUNBOOK.md`

## Goal

Build a XiaoZhi-style voice terminal where an ESP32-S3-AUDIO-Board can hold a
multi-turn spoken conversation with a user. During development, a PC speaker can
stand in for the human user voice, and the ESP32 board speaker must play the
assistant reply.

The target loop is:

```text
user voice -> ESP32 mic -> WebSocket PCM stream -> ASR -> MiMo dialogue
-> MiMo TTS -> WebSocket WAV segments -> ESP32 ES8311 speaker
```

## System Layers

```text
+----------------------------+
| Clients                    |
| - ESP32-S3 audio board     |
| - Browser debug console    |
| - Future mobile clients    |
+-------------+--------------+
              |
              | HTTP + WebSocket
              | shared user_id / device_id
              v
+-------------+--------------+
| Edge API                   |
| - FastAPI gateway          |
| - /voice-chat              |
| - /voice-chat/ws           |
| - memory/task endpoints    |
+------+------+--------------+
       |      |      |
       |      |      +--> TTS provider boundary
       |      |           current: MiMo / mimo-v2.5-tts / Mia
       |      |
       |      +---------> Dialogue provider boundary
       |                  current: MiMo / mimo-v2.5-pro
       |
       +----------------> ASR provider boundary
                          current: Windows zh-CN fallback

+----------------------------+
| Local State                |
| - SQLite voice turns       |
| - Extracted memories       |
| - Open / recurring tasks   |
| - Mood signals             |
| - Generated WAV segments   |
+----------------------------+
```

See `docs/voice-system-case-study.md` for a concise engineering summary of this
architecture and the tradeoffs behind it.

## Device Responsibilities

The ESP32 firmware owns:

- ES7210 microphone capture.
- Local ESP-SR wake / command path when a supported WakeNet model is available.
- USB serial fallback commands for deterministic development tests.
- WebSocket session setup against `/voice-chat/ws`.
- Raw `pcm_s16le` upload in binary WebSocket frames.
- Simple VAD stop on trailing silence.
- ES8311/I2S speaker playback from streamed WAV segments, with the Waveshare
  speaker PA enabled on TCA9555 EXIO8 before output.
- A post-upload WebSocket reply wait window. The current firmware starts this
  timeout after `listen/stop`, so local recording time does not consume the
  LLM/TTS response budget.
- Shared identity labels:
  - `user_id=home-user`
  - `device_id=esp32-audio-board`

The board does not run the dialogue model or TTS model locally.

## Browser Console Responsibilities

The React console now has two roles:

- Operations view: home context, planning, device simulator, trace, and guard
  results.
- Voice debug client: connects to `/voice-chat/ws`, shares the `home-user`
  memory scope, can send text turns, can capture browser microphone PCM, and can
  play returned MiMo TTS WAV segments.

This makes the browser a protocol-compatible test client for the same backend
used by the ESP32.

## Realtime Protocol

The current protocol is `homecue.voice.v1`.

```text
client -> hello
server -> hello(features)
client -> listen/start
client -> binary PCM frames or text partial/final events
client -> listen/stop
server -> stt/final
server -> llm/start
server -> llm/stop
server -> tts/start
server -> tts/audio ready
server -> binary WAV segment frames
server -> tts/audio_done
server -> tts/stop
server -> listen/ready
```

If ASR is available but a turn is not recognized, the server sends
`stt/no_match` followed by `listen/ready`. The ESP32 treats this as a
recoverable turn, so a missed utterance does not tear down the WebSocket session
or fall back to the older HTTP voice path.

Current feature flags:

```text
websocket=true
pcm_s16le=true
stt_partial_events=true
mimo_streaming_tts=true
audio_partial_asr=false
opus_stream=false
full_duplex=false
```

This is not yet true full duplex. The product behavior is still listen, then
think, then speak. However, the transport already supports long-lived sessions,
binary upstream audio frames, and binary downstream audio frames.

## Memory And Task Domain

SQLite stores the shared voice domain state:

- Turns: session history with `user_id` and `device_id`.
- Memories: simple extracted preferences or facts.
- Tasks: open, done, cancelled, daily, and weekly tasks.
- Moods: positive / negative emotional signals.

The reply builder now injects same-user long-term context into new MiMo turns,
so the memory layer is not just archival storage.

For local LAN development, the API now defaults to
`runtime/voice-chat.sqlite` when `VOICE_CHAT_MEMORY_DB` is not explicitly set.
Ubuntu and production-like deployments should still set an absolute
`VOICE_CHAT_MEMORY_DB` path through their service environment.

ESP32 reminders use:

```text
GET /voice-chat/tasks/due-audio?user_id=home-user
```

The response uses the same `reply_audio` shape as normal voice chat, allowing
the board to play reminders through the same ES8311 speaker path.

## Deployment Shape

Current local development shape:

```text
Windows API: 0.0.0.0:8723
ESP32 LAN target: http://<pc-lan-ip>:8723
Web console: http://127.0.0.1:5173
SQLite DB: runtime/voice-chat.sqlite
Audio dir: runtime/audio
```

Planned LAN server shape:

```text
Ubuntu host: 0.0.0.0:8723
systemd service: homecue-edge-api
SQLite DB: service data directory
Audio dir: service data directory
ESP32 target: http://<ubuntu-lan-ip>:8723
post-deploy check: /health + token-aware /voice-chat/status
```

Planned public access shape:

```text
Cloudflare tunnel + Cloudflare Access
-> Ubuntu API/Web entrypoint
-> HomeCue app-layer voice token
-> same LAN service contract
```

The Cloudflare tunnel should be added after LAN behavior is stable. The app
already has an optional `VOICE_CHAT_ACCESS_TOKEN` boundary for `/voice`,
`/voice-chat*`, and `/esp32/diag*`; keep `/health` public for uptime checks and
use Cloudflare Access for browser/mobile user authentication. The Ubuntu deploy
script now verifies `/health` and `/voice-chat/status` after restart, using the
deployed voice token when configured and without printing the token value.

## Verified Evidence

ESP32 single-turn PCM/VAD, MiMo dialogue, MiMo TTS, and board speaker:

```text
assets/demo/esp32-local-lan-pcm-single-voice-chat-check.json
```

Latest PA-enabled realistic PC-speaker-to-board-speaker WebSocket proof:

```text
assets/demo/esp32-pa8-realtime-voice-chat-timeout-fix-check.json
```

Voice-command-triggered WebSocket chat with ASR no-match recovery:

```text
assets/demo/esp32-voice-trigger-ws-chat-no-match-recovery-check.json
```

Default SQLite memory plus MiMo WebSocket/TTS backend proof:

```text
assets/demo/voice-chat-ws-default-sqlite-memory-check.json
```

ESP32 shared identity persistence:

```text
assets/demo/esp32-local-lan-identity-pcm-voice-chat-check.json
assets/demo/local-api-sqlite-esp32-identity-session-proof.json
```

ESP32 reminder audio through board speaker:

```text
assets/demo/esp32-local-sqlite-reminders-auto-check.json
```

MiMo TTS voice switching through the ES8311/I2S speaker path:

```text
assets/demo/esp32-local-lan-mimo-tts-chloe-check.json
```

Isolated PA-enabled local speaker tone test:

```text
assets/demo/esp32-speaker-tone-pa8-full-test-check.json
assets/demo/esp32-speaker-tone-after-ws-fix-check.json
```

Local voice-system readiness proof, 2026-06-17:

```text
assets/demo/voice-system-readiness-check.json
assets/demo/voice-system-readiness-ws-check.json
assets/demo/voice-system-readiness-ws-pcm-check.json
assets/demo/voice-system-readiness-ws-tts-stream-check.json
```

This local non-hardware proof verifies the current API can run MiMo dialogue
with `mimo-v2.5-pro`, MiMo TTS with `mimo-v2.5-tts / Mia`, Windows ASR
availability, SQLite-backed memory/task/mood extraction, WebSocket
`user_id=home-user` and `device_id=readiness-script` echo, a generated
Windows-TTS `pcm_s16le` binary audio turn, a MiMo TTS WebSocket binary-stream
downlink, and due-task audio generation. The latest PCM proof sent 171520 audio
bytes in 90 WebSocket binary frames; the TTS stream proof requires MiMo/Mia WAV
bytes in WebSocket downlink binary frames. The exact TTS byte/frame counts vary
with reply text and are recorded in the JSON artifact. It is a backend/runtime
readiness proof only; it does not prove ESP32 speaker acoustic output.

Speaker acoustic output re-check, 2026-06-17:

```text
firmware command: homecue:speaker-test <seconds> [all|both|left|right|sweep]
script command:   scripts/test-esp32-speaker-tone.ps1 -ToneMode all -Required
resume command:   scripts/resume-esp32-speaker-audible-test.ps1 -AutoDetectEsp32 -Required
http command:     scripts/test-esp32-speaker-http-tone.ps1 -BoardBaseUrl http://<esp32-ip> -ToneMode all -Required
web command:      Web console -> Realtime voice -> ESP32 speaker -> Health / Tone
no-serial probe:  scripts/test-esp32-speaker-network-due-audio.ps1 -WaitSeconds 75
current tracker:  firmware/esp32-audio/SPEAKER-PLAYBACK-CURRENT-ISSUES-2026-06-17.md
```

The current diagnostic firmware writes all speaker output as explicit stereo
I2S slot data, duplicates mono MiMo WAV samples into both channels, and logs
`TCA9555_EXIO8` PA readback before playback. The older tone and voice-chat logs
prove ES8311/I2S writes and PA-enable attempts; they still do not prove that a
person heard acoustic output from the physical speaker.

The speaker path was compared against the official Waveshare demo package on
2026-06-17. The firmware now matches the demo's speaker I2S pins
(`BCLK=13`, `LRCK=14`, `DOUT=16`, `MCLK=12`), PA route
(`TCA9555_EXIO8` high), PA settle delay, and ES8311 analog path call
(`es8311_microphone_config(..., false)`). The board HTTP diagnostics now also
report the PA input/output/config registers so a Wi-Fi test can distinguish a
PA control problem from an I2S/codec or physical speaker problem.

The latest firmware hardening starts the shared I2S/MCLK bus before codec init
and no longer lets a missing ESP-SR model partition block ES8311 speaker
initialization. `homecue:speaker-test` can therefore validate the speaker path
once the board is reachable even if WakeNet/MultiNet is not ready.

The speaker diagnostic build can now enable `HOMECUE_BOOT_SPEAKER_TEST`, which
plays a strong all-mode tone during boot before the serial command test. This
removes the serial command timing variable once upload is possible. The current
diagnostic build also enables a board-side HTTP server with `/health` and
`/speaker-test?seconds=8&mode=all`, so Wi-Fi can trigger a local tone after the
diagnostic firmware is installed. The FastAPI gateway exposes a constrained
local/private-network proxy at `/esp32/diag/health` and
`/esp32/diag/speaker-test`, and the browser voice console now has an ESP32
speaker panel with Health/Tone controls. The current network due-audio bypass
probe created a due reminder and waited 75 seconds, but the API log did not
receive new ESP32 due-audio or WAV requests, so the board was not reachable
through the reminder auto-poll path either.

Latest speaker-first reachability evidence on 2026-06-17:

```text
assets/demo/esp32-port-state-speaker-focus-after-pnp.json
state=usb-error
USB problem node=Unknown USB Device / Code 43 / CM_PROB_FAILED_POST_START
detectedPorts=COM3,COM4,COM5,COM6

assets/demo/esp32-speaker-lan-tone-speaker-focus.json
boardBaseUrl=http://<board-lan-ip>
healthOk=false
toneOk=false

assets/demo/esp32-speaker-lan-tone-candidate-a-speaker-focus.json
assets/demo/esp32-speaker-lan-tone-candidate-b-speaker-focus.json
healthOk=false
toneOk=false

assets/demo/esp32-speaker-network-due-audio-8734-speaker-focus.json
apiBase=http://127.0.0.1:8734
dueAudioRequestCount=0
audioWavRequestCount=0
```

This means the current blocker is board reachability, not MiMo TTS generation:
the board cannot be flashed over USB, cannot be driven through serial
`homecue:speaker-test`, did not answer the tested HTTP diagnostic endpoints, and
did not pull due-audio from the current API.

The latest speaker hardening also reconfigures ES8311 to the actual playback
sample rate before normal WAV playback, speaker-test tones, and WebSocket
streaming WAV segments. This keeps 16 kHz test tones and 24 kHz MiMo TTS
segments aligned between codec and I2S TX.

Latest UI proof for the browser speaker diagnostic panel:

```text
assets/demo/web-esp32-speaker-diag-panel-check.json
assets/demo/web-esp32-speaker-diag-panel-desktop.png
assets/demo/web-esp32-speaker-diag-panel-mobile.png
```

Hardware note: this Waveshare audio path is ES8311 codec plus power amplifier
plus a speaker output connector. If no real speaker is connected to the board
speaker output, the software path can log PA high and I2S writes while no
acoustic output is heard.

Speaker acoustic output re-check, 2026-06-18:

```text
firmware command: homecue:speaker-test <seconds> <mode> <volume<=32> <amplitude<=5000> <buffer|sample|sample32|sample32bclk> [regs] [mic]
build path:       %TEMP%/homecue-edge-esp32-speaker-runtime-diag/build
evidence:         assets/demo/esp32-speaker-runtime-diag-buffer-check.json
evidence:         assets/demo/esp32-speaker-runtime-diag-sample-check.json
evidence:         assets/demo/esp32-speaker-idf32-sample-v18-a1800-check.json
evidence:         assets/demo/esp32-speaker-micprobe-idf32-v18-a1800-check.json
evidence:         assets/demo/esp32-speaker-micprobe-idf32-silence-v18-a0-check.json
evidence:         assets/demo/esp32-speaker-final-micprobe-idf32-v18-a1800-check.json
evidence:         assets/demo/esp32-speaker-final-micprobe-idf32-v24-a2600-check.json
evidence:         assets/demo/esp32-speaker-bclk-ab-mclk-sample32-v18-a1800-check.json
evidence:         assets/demo/esp32-speaker-bclk-ab-bclk-sample32-v18-a1800-check.json
evidence:         assets/demo/esp32-speaker-bclk-ab-network-sample32bclk-v18-a1800.json
evidence:         assets/demo/esp32-speaker-bclk-ab-bclk-micprobe-v32-a5000-check.json
```

Both `write=buffer` and `write=sample` passed serial/software checks with
`volume=18`, `amplitude=1800`, `mode=both`, and a one-second duration. The board
reported PA readback high during playback, ES8311 playback ready, complete I2S
writes, ES8311 muted after playback, and PA disabled afterward.

The follow-up `write=sample32` path mirrors the critical Waveshare ESP-IDF
playback behavior: ES8311 32-bit in/out, 32-bit stereo I2S slots, and 16-bit
samples shifted into 32-bit words. Its register dump changed ES8311 REG09/REG0A
from `0c` to `10`, and the one-second test wrote `128000/128000` bytes.

The follow-up `write=sample32bclk` path also mirrors the ESP-IDF codec clock
option where ES8311 derives internal MCLK from BCLK/SCLK. Its active register
dump changed ES8311 REG01 to `bf` and REG02 to `10`, wrote `128000/128000`
bytes, and returned `ok=true` through the HTTP diagnostic route. This closes the
remaining known software difference between the safe diagnostic firmware and the
official playback path, without flashing the unbounded factory/demo firmware.

The board microphone loopback was attempted:

```text
Initial tone active RMS: 486.5 vs baseline RMS: 106.1
Initial silent active RMS: 59.4 vs baseline RMS: 82.0
Final v18/a1800 active RMS: 78.4 vs baseline RMS: 94.4
Final v24/a2600 active RMS: 58.8 vs baseline RMS: 85.4
BCLK v18/a1800 active RMS: 56.5 vs baseline RMS: 99.5
BCLK v32/a5000 active RMS: 60.1 vs baseline RMS: 90.2
```

Because the final repeat runs and the BCLK runs did not reproduce the RMS rise,
the microphone loopback is not a stable proof of acoustic output. The remaining
speaker blocker is now the analog/physical side: PA output after EXIO8, speaker
connector/header continuity, or the physical speaker/cable/module.

Browser console WebSocket voice panel:

```text
assets/demo/web-voice-console-realtime-panel.png
assets/demo/voice-console-runtime-stack.png
```

Headless browser verification on 2026-06-17 loaded:

```text
http://127.0.0.1:5173?apiBase=http://127.0.0.1:8723
http://127.0.0.1:5173?apiBase=http://127.0.0.1:8734
```

The rendered runtime stack panel reported dialogue `mimo / mimo-v2.5-pro`, TTS
`mimo-v2.5-tts / Mia`, ASR `windows`, memory `sqlite`, transport
`websocket / pcm_s16le`, and stream mode `tts stream`.
The latest current-code Web proof is:

```text
assets/demo/web-voice-console-8734-dedup-final-check.json
assets/demo/web-voice-console-8734-dedup-final.png
```

Optional app-layer auth proof:

```text
VOICE_CHAT_ACCESS_TOKEN=<token>
Authorization: Bearer <token>
X-HomeCue-Token: <token>
?access_token=<token>
```

When configured, the token protects `/voice`, `/voice-chat*`, the WebSocket
`/voice-chat/ws`, generated `/voice-chat/audio/*.wav` downloads, and
`/esp32/diag*`. The browser debug console can pass it as `?apiToken=<token>`;
the WebSocket URL then uses `access_token` because browser WebSocket clients
cannot set arbitrary authorization headers.

The ESP32 firmware can use the same boundary by setting
`VOICE_CHAT_ACCESS_TOKEN` in `secrets.h` or passing
`-VoiceChatAccessTokenOverride <token>` to `scripts/flash-esp32.ps1`. Device
HTTP calls and reply-audio downloads send `Authorization: Bearer`, the
WebSocket handshake sends the same header, and due-audio polling also carries
`access_token` so protected generated WAV URLs continue to play.

## Current Gaps

- Target wake phrase `你好小千` still requires a real `xiaoqian` WakeNet or
  custom wake model; MiMo cannot replace local wake detection.
- Audio-derived partial ASR is not implemented; final ASR still runs after
  `listen/stop`.
- Opus frame streaming is not implemented.
- Full duplex interruption / barge-in is not implemented.
- VAD and Windows ASR reliability still need tuning for short second-turn
  utterances. The protocol now recovers from `stt/no_match`, but a full
  two-recognized-turn hardware proof is still pending.
- The current product-grade trigger is not yet `你好小千`. The available local
  route is the stock ESP-SR wake model plus English `chat mode`, or a forced
  command window during development.
- Serial logs can prove PA enable, PA readback, MiMo TTS bytes, and I2S writes.
  Board-microphone acoustic loopback was attempted but not stable enough to be
  final proof; human listening or external recording is still required.
- Current hardware access is paused because Windows is not enumerating an ESP32
  COM port. The latest port check only found Bluetooth COM3-COM6 and reported
  `state=usb-error` because Windows sees `Unknown USB Device` Code 43 /
  `CM_PROB_FAILED_POST_START`. `pnputil /scan-devices` and
  `pnputil /restart-device` were also denied, so software-side USB recovery did
  not restore COM7.
- A no-serial due-audio probe on 2026-06-17 against the current-code API
  `127.0.0.1:8734` also saw no ESP32 `/due-audio` or WAV requests after
  creating an immediate reminder, so Wi-Fi control is not currently a working
  bypass for speaker testing.
- The latest speaker-first follow-up built the new official-demo-aligned
  diagnostic firmware, but it still could not be uploaded because COM7 was
  unavailable; direct HTTP tone probes against board LAN candidates also failed.
- Ubuntu LAN deployment is designed and scripted but must be revalidated against
  current runtime state. The deploy script now performs token-aware post-restart
  verification, but the current `192.0.2.101` probe accepts TCP then closes
  SSH and `/health` without a usable response.
- Cloudflare tunnel is intentionally deferred until the LAN service is stable;
  the app-layer voice token is implemented, but Cloudflare Access policy and
  deployment validation are still pending.

## Next Development Steps

1. Restore ESP32 USB CDC enumeration, or otherwise regain board Wi-Fi HTTP
   reachability, so the current speaker diagnostic firmware can actually run on
   hardware.
2. Run `resume-esp32-speaker-audible-test.ps1 -AutoDetectEsp32 -Required` to
   flash the latest speaker diagnostic firmware and run the boot plus all-mode
   tone proof.
3. Confirm that a real speaker is connected to the board speaker output, then
   listen for the boot tone and the serial all-mode tone.
4. Revalidate `/health` and run a fresh ESP32 WebSocket PCM/VAD voice-chat test
   against the current API.
5. Keep improving browser voice debugging so the same protocol can be tested
   without reflashing hardware.
6. Re-deploy the API to Ubuntu LAN and verify `/voice-chat/status`,
   `/voice-chat/ws`, and `/voice-chat/tasks/due-audio` from the ESP32.
7. Deploy with `VOICE_CHAT_ACCESS_TOKEN` plus Cloudflare Access before enabling
   any public tunnel.
