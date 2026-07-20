# Voice System Case Study

Date: 2026-06-17

## One-Minute Pitch

HomeCue Edge is a privacy-aware smart-home edge agent that I extended into a
XiaoZhi-style voice terminal. The target experience is: a user speaks to an
ESP32-S3 audio board, the board streams microphone PCM to a FastAPI gateway over
WebSocket, the gateway runs ASR, MiMo dialogue, MiMo TTS, and the board plays
the answer through its ES8311 speaker path.

The design keeps the embedded device small and deterministic. ESP32 owns audio
capture, wake/command routing, VAD, transport, and speaker playback. The gateway
owns model providers, memory, tasks, mood extraction, and deployment concerns.

## Architecture Talking Points

```text
ESP32 / browser client
  -> WebSocket protocol: homecue.voice.v1
  -> upstream: pcm_s16le binary frames or text turns
  -> gateway: ASR -> MiMo dialogue -> MiMo TTS
  -> downstream: binary WAV segments
  -> ESP32: ES8311/I2S speaker playback

Shared state:
  SQLite turns, memories, tasks, moods, generated WAVs

Deployment path:
  Windows local dev -> Ubuntu LAN service -> Cloudflare tunnel with auth
```

## Engineering Decisions

- Split local wake/transport from cloud dialogue: MiMo is not used for wake word
  detection because wake detection must happen locally before network audio is
  sent.
- Use WebSocket before full duplex: the protocol already supports long-lived
  sessions and binary audio frames, while the product behavior remains
  listen-then-think-then-speak until interruption and Opus streaming are ready.
- Store user/device identity on every turn: this lets ESP32, browser, and future
  mobile clients share memory and tasks through `user_id` and `device_id`.
- Keep reminders on the same audio path as chat replies: due-task audio returns
  the same `reply_audio` shape used by voice chat, so the board has one speaker
  download/playback contract.
- Build a browser protocol client: when hardware is blocked, the browser console
  can still verify provider status, WebSocket protocol behavior, memory, tasks,
  and TTS downlink.
- Add exposure controls before public access: voice, memory/task, generated
  audio, WebSocket, and ESP32 diagnostic routes support an optional app token,
  with Cloudflare Access planned as the outer user-auth layer.

## What Is Verified

- API runtime reports MiMo dialogue `mimo-v2.5-pro`, MiMo TTS
  `mimo-v2.5-tts / Mia`, Windows ASR fallback, SQLite memory, WebSocket,
  `pcm_s16le`, and streaming TTS.
- Readiness proof covers text voice chat, WebSocket protocol, generated
  Windows-TTS `pcm_s16le` upload, MiMo TTS binary downlink, memory extraction,
  task extraction, mood extraction, and due-audio generation.
- Web console proof shows the Realtime Voice panel, runtime stack, ESP32 speaker
  diagnostic controls, and de-duplicated memory/task/mood cards.
- Firmware compile proof covers the current speaker diagnostic build with
  `ENABLE_ESP_SR`, boot speaker test, and board HTTP diagnostic server.
- API tests cover the optional voice access token for HTTP routes, WebSocket
  handshakes, reply-audio URLs, and environment configuration.
- The Ubuntu deploy helper now performs a token-aware post-restart runtime check
  of `/health` and `/voice-chat/status` without printing the voice token.

Important artifacts:

```text
assets/demo/voice-system-readiness-check.json
assets/demo/voice-system-readiness-ws-pcm-check.json
assets/demo/voice-system-readiness-ws-tts-stream-check.json
assets/demo/web-voice-console-8734-dedup-final-check.json
assets/demo/esp32-port-state-speaker-focus-after-pnp.json
docs/voice-system-architecture.md
firmware/esp32-audio/VOICE-CHAT-CURRENT-ISSUES-2026-06-16.md
```

## Hard Problems And Fixes

- Speaker path ambiguity: serial logs can prove ES8311 init, PA enable, and I2S
  writes, but cannot prove acoustic output. I added strong all-mode tone tests,
  boot-time speaker tests, PA register diagnostics, and HTTP `/speaker-test`.
- Provider separation: dialogue and TTS are independently configurable, so MiMo
  can be the dialogue model and the voice-output model while keeping metadata
  visible in `/voice-chat/status` and ESP32 logs.
- Duplicate memory noise: repeated readiness tests polluted memory/task/mood
  views. The API now updates matching memories/tasks and de-duplicates list
  output for product display while preserving raw history.
- Hardware dependency: when ESP32 USB entered Code 43, I continued progress by
  validating the browser/WebSocket/API path, documenting the blocker, and
  making the next firmware boot play a strong tone as soon as the board is
  reachable again.

## Current Limits

- The target `xiaoqian` wake phrase still needs a real WakeNet/custom wake model.
  MiMo cannot replace local wake detection.
- Full duplex interruption and Opus frame streaming are not implemented yet.
- Audio-derived partial ASR is declared as a gap; final ASR still happens after
  listen stop.
- Physical board-speaker audibility is currently blocked by hardware
  reachability: Windows sees the board as Unknown USB Device Code 43, no ESP32
  COM port is writable, and tested Wi-Fi diagnostic endpoints did not answer.
- Ubuntu LAN revalidation is pending because the current `192.0.2.101`
  endpoint accepts TCP on SSH/API ports but closes SSH and `/health` connections
  before a usable response.

## Engineering Narrative

I would describe this as an end-to-end systems project rather than a model demo.
The core work was defining the boundary between embedded firmware, real-time
transport, cloud-compatible model providers, and durable user state. I kept each
layer independently testable: browser for protocol and runtime, scripts for
readiness and evidence, firmware serial/HTTP routes for hardware diagnostics,
and SQLite endpoints for memory/task inspection.

The most important tradeoff was choosing a half-duplex but production-shaped
WebSocket protocol first. It is honest about gaps like barge-in and Opus, but it
already supports the hard parts that affect architecture: session identity,
binary upstream audio, binary downstream TTS, provider metadata, and recoverable
ASR no-match turns.

## Follow-Up Roadmap

1. Recover ESP32 USB/Wi-Fi reachability and run the boot speaker tone proof.
2. Re-run the realistic PC-speaker-to-board-speaker WebSocket voice test.
3. Revalidate the access-token path on Ubuntu LAN and then put Cloudflare
   Access in front of the tunnel.
4. Replace rule-based memory extraction with LLM summarization once the storage
   and privacy contracts are stable.
5. Add Opus streaming and interruption handling after the half-duplex loop is
   solid.
