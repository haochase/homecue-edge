# HomeCue Edge API

FastAPI edge gateway for the HomeCue Edge prototype.

## Local Run

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
uvicorn app.main:app --reload --port 8723
```

## Endpoints

- `GET /health`
- `GET /context`
- `GET /devices`
- `POST /plan`
- `POST /voice-chat`
- `WS /voice-chat/ws`
- `GET /voice-chat/status`
- `GET /esp32/diag/health?base_url=http://<esp32-ip>`
- `POST /esp32/diag/speaker-test`
- `POST /devices/reset`

## Planner Configuration

Create `.env` from `.env.example`.

```text
QWEN_API_KEY=
QWEN_API_BASE=https://dashscope.aliyuncs.com/compatible-mode/v1
QWEN_MODEL=qwen-plus
PLANNER_PROVIDER=auto

# Optional ESP32 reply-audio TTS override.
VOICE_CHAT_TTS_PROVIDER=windows
VOICE_CHAT_TTS_API_KEY=
VOICE_CHAT_TTS_API_BASE=https://dashscope.aliyuncs.com/api/v1
VOICE_CHAT_TTS_MODEL=qwen3-tts-flash
VOICE_CHAT_TTS_VOICE=Cherry
VOICE_CHAT_TTS_LANGUAGE_TYPE=Chinese

# Optional ASR provider for ESP32 WAV/PCM uploads.
VOICE_CHAT_ASR_PROVIDER=auto
VOICE_CHAT_ASR_MODEL=mimo-v2.5-asr
VOICE_CHAT_ASR_LANGUAGE=zh-CN

# Optional SQLite session memory for LAN/Ubuntu deployments.
VOICE_CHAT_MEMORY_DB=

# Optional app-layer token for voice, memory/task, and ESP32 diagnostic routes.
VOICE_CHAT_ACCESS_TOKEN=
```

Planner providers:

- `auto`: use Qwen when an API key exists; otherwise use mock.
- `mock`: deterministic local demo planner.
- `qwen`: require Qwen Cloud.

The API keeps offline fallback separate from planner provider so the demo can always show EdgeAgent reliability.

## Voice API Access Token

`VOICE_CHAT_ACCESS_TOKEN` is empty by default, so local and LAN development
keep the same no-auth behavior. When it is set, the API requires that token for:

```text
POST /voice
POST /voice-chat
WS   /voice-chat/ws
GET  /voice-chat/*
POST /voice-chat/*
PATCH /voice-chat/*
GET  /esp32/diag/*
POST /esp32/diag/*
```

Accepted token formats:

```text
Authorization: Bearer <token>
X-HomeCue-Token: <token>
?access_token=<token>
```

The query-string form exists for constrained ESP32 downloads and browser
WebSocket clients. Browser debug sessions can open the web console with:

```text
http://127.0.0.1:5173?apiBase=http://127.0.0.1:8723&apiToken=<token>
```

ESP32 firmware clients use the same token. Set `VOICE_CHAT_ACCESS_TOKEN` in
`firmware/esp32-audio/secrets.h`, or pass
`-VoiceChatAccessTokenOverride <token>` to `scripts/flash-esp32.ps1` for a
temporary build-only override. The firmware sends `Authorization: Bearer` for
HTTP voice calls, reply-audio downloads, and the WebSocket handshake, and also
adds `access_token` to due-audio polling so returned WAV URLs remain playable.

`GET /health` stays public for local uptime checks. For Cloudflare exposure,
use Cloudflare Access in front of the service and keep this app-layer token
enabled for ESP32/browser clients that call voice memory, task, audio, and
diagnostic routes.

## Qwen Verification

After adding a real API key to `.env`, run from the repository root:

```powershell
.\scripts\verify-qwen.ps1
```

The verifier calls the same `/plan` route used by the demo and confirms the returned routine provider is `qwen`. It writes the result to `assets/demo/qwen-verification/latest.json`, which is ignored by Git because it depends on local credentials and runtime output.

## Voice Chat

`POST /voice-chat` is the PC-assisted voice-chat path for the ESP32 terminal. It accepts JSON text for fast testing, or raw WAV bytes for the ESP32 recording upload path. When `speak=true` or `?speak=1` is set, the API plays the reply on the Windows default audio device. When `reply_audio=true` or `?reply_audio=1` is set, it returns a short WAV URL for ESP32 board-speaker playback.

The default ESP32 reply-audio generator is Windows `System.Speech.Synthesis.SpeechSynthesizer`, using the current Windows default voice. The API response includes `reply_audio.provider`, `reply_audio.model`, and `reply_audio.voice` so tests and serial logs can identify the active voice source.

The current MiMo account exposes TTS models in `/models`, including `mimo-v2.5-tts`, `mimo-v2.5-tts-voiceclone`, and `mimo-v2.5-tts-voicedesign`. The working MiMo TTS route is `POST /chat/completions` with an assistant message. Non-streaming requests return base64 WAV audio in `choices[0].message.audio.data`; `stream=true` returns SSE chunks with `choices[].delta.audio.data`, where each delta is an independent WAV segment. To use MiMo for ESP32 reply audio, set:

```text
VOICE_CHAT_TTS_PROVIDER=mimo
VOICE_CHAT_TTS_API_BASE=https://mimo-compatible.example.invalid/v1
VOICE_CHAT_TTS_MODEL=mimo-v2.5-tts
VOICE_CHAT_TTS_VOICE=Mia
VOICE_CHAT_TTS_LANGUAGE_TYPE=Chinese
```

The MiMo endpoint currently accepts these voice names in `audio.voice`: `mimo_default`, `冰糖`, `茉莉`, `苏打`, `白桦`, `Mia`, `Chloe`, `Milo`, and `Dean`.

`Mia` is the current hardware-verified voice because it prints cleanly in ESP32
serial logs. `茉莉` also works in direct backend synthesis, but the board serial
console renders that non-ASCII voice name as question marks.

To try Alibaba Cloud Model Studio / DashScope Qwen-TTS instead, set:

```text
VOICE_CHAT_TTS_PROVIDER=dashscope
VOICE_CHAT_TTS_MODEL=qwen3-tts-flash
VOICE_CHAT_TTS_VOICE=Cherry
VOICE_CHAT_TTS_LANGUAGE_TYPE=Chinese
```

If `VOICE_CHAT_TTS_API_KEY` is empty, `VOICE_CHAT_TTS_PROVIDER=mimo` reuses `MIMO_API_KEY`; set `VOICE_CHAT_TTS_API_BASE` or `MIMO_API_BASE` to your configured OpenAI-compatible TTS endpoint. `VOICE_CHAT_TTS_PROVIDER=dashscope` or `auto` reuses `DASHSCOPE_API_KEY` or `QWEN_API_KEY` when present. The dialogue model and TTS model are selected separately, so MiMo can be both the chat provider and the voice-output provider.

```powershell
.\scripts\test-voice-chat.ps1 -ApiBase http://127.0.0.1:8731 -Text "你好小千，简单介绍一下你能做什么" -Speak -Required
```

Current verified evidence:

```text
assets/demo/voice-chat-mimo-pc-tts-v3.json
assets/demo/esp32-voice-chat-session-audio-test-check.json
assets/demo/esp32-voice-chat-ws-mimo-tts-mia-check.json
assets/demo/esp32-ubuntu-lan-reminders-auto-check.json
```

## ESP32 Speaker Diagnostics

After flashing the ESP32 diagnostic firmware with `-DiagHttpServer`, the board
serves `GET /health` and `GET /speaker-test?seconds=8&mode=all` on its Wi-Fi IP.
The FastAPI gateway exposes browser-friendly proxy routes:

```powershell
GET  /esp32/diag/health?base_url=http://192.0.2.100
POST /esp32/diag/speaker-test
```

Example body:

```json
{"base_url":"http://192.0.2.100","seconds":8,"mode":"all"}
```

The web console uses these routes for the ESP32 speaker panel. The response can
prove board reachability and firmware-reported ES8311/PA state, but acoustic
output still needs local listening confirmation. The proxy only accepts
localhost, `.local`, and private/link-local IP targets.

`GET /voice-chat/status` reports the active chat provider/model, TTS
provider/model/voice, SQLite memory availability, and realtime protocol flags
without exposing API keys. The current Ubuntu LAN proof returned:

```json
{
  "provider": "mimo",
  "model": "mimo-v2.5-pro",
  "tts": {
    "provider": "mimo",
    "model": "mimo-v2.5-tts",
    "voice": "Mia",
    "configured": true
  },
  "memory": {
    "sqlite_enabled": true
  },
  "asr": {
    "provider": "auto",
    "effective_provider": "mimo",
    "model": "mimo-v2.5-asr",
    "language": "zh-CN",
    "mimo_available": true,
    "faster_whisper_available": false,
    "windows_available": true
  },
  "realtime": {
    "websocket": true,
    "pcm_s16le": true,
    "stt_partial_events": true,
    "audio_partial_asr": false,
    "mimo_streaming_tts": true,
    "opus_stream": false,
    "full_duplex": false
  }
}
```

The endpoint returns `session_id` and `turn_index`. Send the same `session_id`
on the next JSON body or WAV query string to keep short conversation context:

```text
POST /voice-chat?reply_audio=1&session_id=<id>
Content-Type: audio/wav
```

When `VOICE_CHAT_MEMORY_DB` is set, `/voice-chat` and `/voice-chat/ws` persist
each completed turn to SQLite. This keeps recent context available after an API
restart and lets browser, ESP32, and future mobile clients share a conversation
by sending the same `session_id`. Clients may also send `user_id` and
`device_id` in the JSON body, query string, WebSocket `hello`, or
`listen/start`; these labels are stored with every turn for later multi-device
memory and task sharing.

```text
VOICE_CHAT_MEMORY_DB=/opt/homecue-edge/data/voice-chat.sqlite
```

Memory inspection endpoints:

```text
GET /voice-chat/sessions?limit=20
GET /voice-chat/sessions/<session_id>?limit=50
GET /voice-chat/memories?user_id=default&limit=20
GET /voice-chat/tasks?user_id=default&status=open&limit=20
GET /voice-chat/tasks/due?user_id=default&mark_reminded=true
GET /voice-chat/tasks/due-audio?user_id=default
GET /voice-chat/moods?user_id=default&limit=20
POST /voice-chat/tasks
PATCH /voice-chat/tasks/<task_id>
```

The first memory layer also extracts simple long-term notes, open tasks, and
mood events from completed voice turns. The extraction is intentionally
rule-based for now: phrases such as `记住...`, `我喜欢...`, `提醒我...`, and
emotion words like `焦虑` or `开心` are persisted immediately without adding a
new model dependency. Task rows keep `due_text`, `recurrence`, and a computable
`due_at` timestamp for common phrases such as `10分钟后`, `今晚`, `明天`,
`下周`, `每天`, and `每周`. `GET /voice-chat/tasks/due` returns open due tasks
and can mark them as reminded, giving ESP32/browser clients a polling endpoint
for spoken reminders. Daily and weekly recurring tasks are automatically moved
to their next due time when marked reminded, so the ESP32 idle poll can speak the
next occurrence later instead of consuming the task permanently.
`GET /voice-chat/tasks/due-audio` claims one due task, synthesizes a short
`提醒：...` WAV with the configured TTS provider, and returns the same
`reply_audio` payload shape used by voice chat so ESP32 can download and play it
through the board speaker. The ESP32 firmware can poll this endpoint while idle;
the 2026-06-16 hardware proof used `VOICE_CHAT_TTS_PROVIDER=mimo`,
`VOICE_CHAT_TTS_MODEL=mimo-v2.5-tts`, and `VOICE_CHAT_TTS_VOICE=Mia`.
This gives the Ubuntu/LAN service a concrete shared state layer; richer LLM
summarization, push notification delivery, and cross-device task execution are
still future work.

## Ubuntu LAN Deployment

From the repository root:

```powershell
.\scripts\deploy-api-ubuntu.ps1 -Remote edge-host -RemoteDir '~/homecue-edge-api' -Port 8723 -PipIndexUrl https://pypi.tuna.tsinghua.edu.cn/simple
```

The deploy script packages this API app, copies it over SSH, installs/reuses a
remote `.venv`, uploads `.env` with mode `600`, and installs a user-level
systemd service named `homecue-edge-api`. It rewrites the deployed env so
conversation memory and generated WAV files stay on the Ubuntu host:

```text
VOICE_CHAT_MEMORY_DB=/home/edgeuser/homecue-edge-api/data/voice-chat.sqlite
HOMECUE_VOICE_CHAT_AUDIO_DIR=/home/edgeuser/homecue-edge-api/data
```

After restart, the deploy script verifies `/health` and `/voice-chat/status`
from the Ubuntu host. If the deployed env contains `VOICE_CHAT_ACCESS_TOKEN`,
the verifier uses it as a bearer token without printing it. Add
`-VerifyResultJsonPath .\assets\demo\ubuntu-api-verify.json` to keep the runtime
summary, or `-VerifyBaseUrl http://192.0.2.101:8723` when you want the check
to go through the LAN address or a future tunnel endpoint.

The 2026-06-16 proof has the service active and enabled on
`edge-host`, listening on `http://192.0.2.101:8723`. Windows and the
ESP32 both reached `/health`; the ESP32 then auto-polled
`/voice-chat/tasks/due-audio` and played a MiMo `mimo-v2.5-tts` / `Mia`
reminder through the board speaker.

`WS /voice-chat/ws` is the long-lived voice-session protocol used by the browser
debug panel and the ESP32 firmware's `homecue:voice-chat-ws` routes. It follows
the XiaoZhi-style message sequence:

```text
client -> {"type":"hello","version":1,"transport":"websocket"}
server -> {"type":"hello","transport":"websocket","session_id":"...","features":{"stt_partial":true}}
client -> {"type":"listen","state":"start"}
client -> {"type":"listen","state":"partial","text":"..."}
server -> {"type":"stt","state":"partial","text":"..."}
client -> {"type":"listen","state":"final","text":"..."}
server -> {"type":"stt","state":"final","text":"..."}
client -> {"type":"listen","state":"stop"}
server -> {"type":"llm","state":"start"}
server -> {"type":"llm","state":"stop","text":"...","turn_index":1}
server -> {"type":"listen","state":"ready"}
```

Optional identity fields for shared memory:

```text
client -> {"type":"hello","user_id":"home-user","device_id":"esp32-kitchen"}
client -> {"type":"listen","state":"start","session_id":"...","device_id":"browser-console"}
```

The current WebSocket implementation supports JSON text turns, JSON
partial/final transcript events, binary WAV frames, binary `pcm_s16le` frames,
optional single-frame binary WAV reply audio, optional chunked binary WAV reply audio via
`reply_audio_transport=websocket_binary_chunked`, and MiMo streaming TTS via
`reply_audio_transport=websocket_binary_stream`. The ESP32 can keep one socket
open across multiple turns, stream raw PCM chunks while recording, stop a turn
early after trailing silence, receive MiMo TTS as multiple independent WAV
segments, parse each WAV segment, and write audio to I2S as the binary frames
arrive. It intentionally advertises `opus_stream=false`; full ESP32 Opus frame
streaming, audio-derived partial ASR, and full-duplex speak/listen remain
realtime-audio gaps.

```powershell
.\scripts\test-voice-chat-ws.ps1 -WsUrl ws://127.0.0.1:8723/voice-chat/ws -Text "Hello XiaoQian" -Required
```

## Tests

```powershell
.\.venv\Scripts\python -m pytest
```

The current tests cover health/provider reporting, mock planning, weak-network
mode, offline fallback, voice-chat status, voice-chat memory/task endpoints
including daily recurring reminders, WebSocket partial/final transcript
protocol behavior, and device reset behavior.
