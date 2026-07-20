# Jarvis Half-Duplex Voice Chat Status - 2026-06-18

## Result

The requested Jarvis flow is implemented and verified:

```text
Jarvis wake word
-> board replies "for you sir, always"
-> board automatically enters voice chat
-> user asks a Chinese question
-> ESP32 uploads mono PCM over WebSocket
-> MiMo ASR transcribes the turn
-> MiMo chat replies
-> MiMo TTS streams WAV audio
-> ESP32 writes the reply to the ES8311/I2S speaker path
```

The implemented conversation mode is half-duplex. The board records one user
turn, detects trailing silence with VAD, uploads the turn, waits for the MiMo
reply and TTS playback, then returns to ready state.

Important correction after the speaker-first follow-up: the Jarvis/MiMo/TTS/I2S
software path is verified, but board speaker acoustic output is still not
reliably verified. A first board-microphone loopback run showed a tone-related
RMS rise, but repeat runs did not reproduce it.

## Current Runtime

```text
Board port: COM7
Board IP: 192.0.2.107
API host used by firmware: 192.0.2.118:8723
Wake model: wakenet9 Jarvis / wn9_jarvis_tts
Command model: MultiNet English mn5q8_en
Chat model: mimo-v2.5-pro
ASR: MiMo ASR through mimo-v2.5-asr
TTS: mimo-v2.5-tts
TTS voice: Mia
Speaker volume: 12 for reply playback
Speaker test: runtime bounded, default volume=18 amplitude=1800 max volume=32 max amplitude=5000
Speaker A/B: sample32 mode mirrors the Waveshare ESP-IDF 32-bit stereo slot path
Boot speaker test: disabled
Default voice-chat session turns: 2
```

`/voice-chat/status` currently reports:

```text
provider=mimo
model=mimo-v2.5-pro
tts.provider=mimo
tts.model=mimo-v2.5-tts
tts.voice=Mia
asr.provider=auto
asr.effective_provider=mimo
realtime.websocket=true
realtime.pcm_s16le=true
realtime.full_duplex=false
```

The board health after the passing run:

```text
status=ok
speaker_output_enabled=true
speaker_pa_enabled=false
speaker_pa_readback=low
i2s_ready=true
es8311_ready=true
esp_sr_started=true
```

## Passing Software-Path Hardware Test

Command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-esp32-voice-chat-audio.ps1 `
  -Port COM7 `
  -Seconds 210 `
  -StartAfterSeconds 5 `
  -WakePhrase "Jarvis" `
  -AutoChat `
  -UserPhrases "你好，请用一句话介绍你自己。;你刚才说你叫什么名字？" `
  -ExpectedTurns 2 `
  -ExpectedReplyTurns 2 `
  -RequireWebSocket `
  -RequireNoFallback `
  -Volume 35 `
  -ExpectedTtsProvider mimo `
  -ExpectedTtsModel mimo-v2.5-tts `
  -ExpectedTtsVoice Mia `
  -SaveLogPath .\assets\demo\esp32-jarvis-halfduplex-mimo-asr-2turn.log `
  -MarkerPath .\assets\demo\esp32-jarvis-halfduplex-mimo-asr-2turn-markers.log `
  -ResultJsonPath .\assets\demo\esp32-jarvis-halfduplex-mimo-asr-2turn-check.json `
  -Required
```

Result:

```text
ESP32 voice-chat audio test complete.
failures=[]
wakeAckCount=1
recordingPromptCount=2
voiceUploadCount=2
websocketMarkerCount=59
noMatchCount=0
mimoProviderCount=2
replyAudioReadyCount=2
binaryReplyAudioCount=15
streamingReplyAudioDoneCount=2
audioPlaybackCount=3
sessionTurns=[1,2]
crashCount=0
```

This result proves serial markers, WebSocket transport, MiMo ASR/TTS, reply
audio reception, PA control, and I2S write completion. It does not prove stable
human-audible speaker output.

Key serial markers:

```text
[voice] wake auto chat
[voice] wake ack: for you sir, always
[/voice-chat/tts] tts provider=mimo model=mimo-v2.5-tts voice=Mia
[voice-session/ws] turn 1/2
[/voice-chat/ws] streamed 94208 PCM bytes mono
[/voice-chat/ws] provider: mimo
[voice-session] id=f70316be9bd94a1bb3e912c0b743e99a turn=1
[/voice-chat/ws] reply_audio: ready  transport=websocket_binary_stream
[voice-session/ws] turn 2/2
[/voice-chat/ws] streamed 164864 PCM bytes mono
[/voice-chat/ws] provider: mimo
[voice-session] id=f70316be9bd94a1bb3e912c0b743e99a turn=2
[/voice-chat/ws] reply_audio done transport=websocket_binary_stream chunks=9
[speaker] PA disabled pin=8
[/voice-chat/ws] ready turn=2
```

Evidence files:

```text
assets/demo/esp32-jarvis-halfduplex-mimo-asr-2turn.log
assets/demo/esp32-jarvis-halfduplex-mimo-asr-2turn-markers.log
assets/demo/esp32-jarvis-halfduplex-mimo-asr-2turn-check.json
assets/demo/asr-debug/asr-input-1781755102549.wav
assets/demo/asr-debug/asr-prepared-1781755102549.wav
assets/demo/asr-debug/asr-input-1781755115681.wav
assets/demo/asr-debug/asr-prepared-1781755115681.wav
assets/demo/api-jarvis-halfduplex-mimo-asr.err.log
```

## Code Changes

Firmware:

```text
firmware/esp32-audio/esp32-audio.ino
```

- `HOMECUE_WAKE_AUTO_VOICE_CHAT` defaults to enabled.
- Wake word detection queues automatic voice chat.
- The wake acknowledgement text is `for you sir, always`.
- The board downloads the wake acknowledgement from
  `/voice-chat/tts`.
- The board writes acknowledgement/reply audio to the ES8311/I2S speaker path;
  physical acoustic output still requires human listening or external recording.
- The board records mono `pcm_s16le` over WebSocket.
- VAD uses a short noise probe, minimum speech duration, and trailing silence
  to stop the current user turn.
- Speaker-path writes remain low volume and disable the PA after playback.

Backend:

```text
apps/api/app/config.py
apps/api/app/main.py
apps/api/app/voice_chat.py
apps/api/app/voice_chat_ws.py
```

- Added `/voice-chat/tts` for wake acknowledgement TTS.
- Added WAV normalization/trimming before ASR.
- Added MiMo ASR through the OpenAI-compatible `/chat/completions` gateway using
  `mimo-v2.5-asr`.
- `VOICE_CHAT_ASR_PROVIDER=auto` now prefers MiMo ASR when the active provider
  key is configured, then falls back to local ASR options.
- WebSocket half-duplex voice chat returns MiMo reply audio through streaming
  WAV frames.

Tests and docs:

```text
apps/api/tests/test_api.py
apps/api/.env.example
apps/api/README.md
scripts/test-esp32-voice-chat-audio.ps1
```

- Added coverage for ASR WAV preparation.
- Added coverage for MiMo ASR request shape.
- Added coverage for `auto` ASR preferring MiMo.
- Updated ASR configuration examples.
- Updated the hardware test script to support wake-triggered auto chat.

## Speaker Acoustic Follow-Up

After the no-sound report, the firmware added:

```text
homecue:speaker-regs
homecue:speaker-test ... <buffer|sample|sample32|sample32bclk> [regs] [mic]
```

The `sample32` path mirrors the critical Waveshare ESP-IDF playback behavior:
32-bit stereo I2S slots and 16-bit tone samples shifted into 32-bit words.
The `sample32bclk` path additionally mirrors the ESP-IDF codec clock option that
derives ES8311 internal MCLK from BCLK/SCLK instead of the MCLK pin.

Speaker-focused evidence:

```text
assets/demo/esp32-speaker-micprobe-idf32-v18-a1800-check.json
assets/demo/esp32-speaker-micprobe-idf32-silence-v18-a0-check.json
assets/demo/esp32-speaker-final-micprobe-idf32-v18-a1800-check.json
assets/demo/esp32-speaker-final-micprobe-idf32-v24-a2600-check.json
assets/demo/esp32-speaker-bclk-ab-mclk-sample32-v18-a1800-check.json
assets/demo/esp32-speaker-bclk-ab-bclk-sample32-v18-a1800-check.json
assets/demo/esp32-speaker-bclk-ab-network-sample32bclk-v18-a1800.json
assets/demo/esp32-speaker-bclk-ab-bclk-micprobe-v32-a5000-check.json
```

Result summary:

```text
Initial tone active RMS: 486.5 vs baseline RMS: 106.1
Initial silent active RMS: 59.4 vs baseline RMS: 82.0
Final v18/a1800 active RMS: 78.4 vs baseline RMS: 94.4
Final v24/a2600 active RMS: 58.8 vs baseline RMS: 85.4
BCLK v18/a1800 active RMS: 56.5 vs baseline RMS: 99.5
BCLK v32/a5000 active RMS: 60.1 vs baseline RMS: 90.2
```

This makes the current speaker conclusion:

```text
ES8311/I2S/PA digital/control path: verified, including MCLK and BCLK codec modes
Low-volume acoustic output: not reliably verified
Remaining blocker: PA analog output, speaker connector/header, or physical speaker/cable/module
```

## Verification

Backend target tests:

```text
7 passed
```

Covered tests:

```text
test_voice_chat_status_reports_runtime_without_secrets
test_voice_chat_can_use_mimo_asr
test_voice_chat_auto_asr_prefers_mimo
test_prepare_wav_for_asr_trims_and_limits_peak
test_voice_chat_websocket_accepts_binary_pcm
test_voice_chat_tts_returns_reply_audio
test_voice_chat_websocket_keeps_session_ready_when_asr_no_match
```

Syntax and whitespace checks:

```text
python -m py_compile: passed
git diff --check: passed
PowerShell parser check for scripts/test-esp32-voice-chat-audio.ps1: passed
```

## Notes

- Serial output still renders Chinese text as question marks in some logs. The
  actual ASR and chat flow works; this is a serial display encoding issue, not a
  functional blocker.
- The current implementation is intentionally half-duplex. Full-duplex,
  barge-in, echo cancellation, and audio-derived partial ASR remain future work.
- The speaker path is deliberately conservative after the previous high-volume
  incident: no boot speaker test, low volume, muted codec after playback, PA off
  after playback.
