# ESP32 Speaker Playback Current Issues - 2026-06-17

## 2026-06-18 Update

The current closure path is now documented in
`firmware/esp32-audio/SPEAKER-PHYSICAL-CLOSURE-RUNBOOK.md`.

Latest interpretation:

- 2026-06-18 safe reminder baseline passed all required software markers:
  MiMo TTS ready, WAV downloaded, ES8311 playback ready, `path=i2s16`,
  playback done, mute, PA disabled.
- 2026-06-18 board health after playback is safe: PA low, I2S ready, ES8311
  ready, speaker output enabled.
- 2026-06-18 low tone + mic probe passed all required serial checks, but the
  saved RMS change was weak (`88.1` baseline to `92.9` active) and does not
  prove human-audible speaker output.
- Further blind volume increases are unsafe and should not be used.
- The remaining unresolved segment is physical/analog: speaker header, cable,
  speaker unit, PA output signal, then vendor demo A/B or hardware fallback.

New evidence files:

```text
assets/demo/esp32-speaker-physical-closure-reminder-20260618.log
assets/demo/esp32-speaker-physical-closure-reminder-20260618.check.json
assets/demo/esp32-speaker-physical-closure-tone-mic-20260618.log
assets/demo/esp32-speaker-physical-closure-tone-mic-20260618.check.json
assets/demo/waveshare-speaker-ab-safe-20260618-rerun.summary.json
assets/demo/waveshare-speaker-ab-safe-20260618-rerun-official-mclk-sample32.log
assets/demo/waveshare-speaker-ab-safe-20260618-rerun-official-bclk-sample32bclk.log
assets/demo/speaker-physical-evidence-current-20260618.json
assets/demo/waveshare-factory-ab-plan-20260618.json
```

The bounded Waveshare official-parameter A/B is automated in
`scripts/test-waveshare-speaker-ab.ps1`. It does not flash the unbounded
factory binary. It maps the official ES8311/EXIO8/32-bit-slot behavior onto the
safe HomeCue diagnostic firmware.

The current physical evidence record is
`firmware/esp32-audio/SPEAKER-PHYSICAL-EVIDENCE-2026-06-18.md`. It marks the
software boundary as OK and the remaining physical evidence as missing:
speaker cable replacement/rework, known-good speaker replacement, speaker-header
AC measurement, and human audible confirmation.

Hardware fallback has been prepared in
`firmware/esp32-audio/SPEAKER-HARDWARE-FALLBACK-DECISION.md`. Current preferred
branches:

- ESP32-S3-BOX-3 if staying on ESP32/ESP-SR hardware.
- Raspberry Pi + Codec Zero or known-good USB audio if demo reliability and
  future camera/video emotion recognition matter more than ESP32 purity.
- M5Stack Atom Voice as the smallest audio-only fallback.

Factory A/B dry-run is prepared by
`scripts/prepare-waveshare-factory-ab.ps1`. It confirmed the Waveshare factory
binary exists and generated the planned factory flash command plus the HomeCue
firmware recovery command, but did not flash the device.

## Current Status

Board speaker acoustic output is still not reliably verified. The current
firmware proves the software/electrical path up to ES8311/I2S writes and PA
control. A first board-microphone loopback run showed a clear RMS rise during a
low-volume tone, but final repeat runs did not reproduce that rise. Human
listening confirmation or an external acoustic capture is still required.

The current board firmware supports this working path:

```text
Jarvis wake word -> chat mode -> Chinese user question -> MiMo reply ->
MiMo Mia TTS -> WebSocket binary audio stream -> ESP32 ES8311/I2S write path
```

Important correction: earlier "speaker playback" evidence means serial/software
markers only. It does not prove a person heard acoustic output. The current
firmware keeps the PA off at boot and only enables it during explicit bounded
speaker tests or reply playback.

## 2026-06-18 Runtime Speaker Diagnostic

New safe diagnostic firmware was flashed on COM7 with:

```text
Build path: %TEMP%/homecue-edge-esp32-speaker-runtime-diag/build
WakeNet: wn9_jarvis_tts
Wake filter keyword: jarvis
Speaker output: enabled
Boot speaker test: disabled
Diag HTTP server: enabled
API host override: 192.0.2.118:8723
```

The diagnostic command now supports bounded runtime parameters:

```text
homecue:speaker-test <seconds> <both|left|right|sweep|all> <volume<=32> <amplitude<=5000> <buffer|sample|sample32|sample32bclk> [regs] [mic]
```

Two one-second tests passed all serial/software checks:

```text
assets/demo/esp32-speaker-runtime-diag-buffer.log
assets/demo/esp32-speaker-runtime-diag-buffer-check.json
assets/demo/esp32-speaker-runtime-diag-sample.log
assets/demo/esp32-speaker-runtime-diag-sample-check.json
assets/demo/esp32-speaker-runtime-diag-sample-v24-a2600.log
assets/demo/esp32-speaker-runtime-diag-sample-v24-a2600-check.json
```

Key markers:

```text
[serial] SPEAKER TEST -> 1s mode=both volume=18 amplitude=1800 write=buffer
[speaker] PA enabled pin=8
[speaker] PA readback pin=8 state=high input=0xff output=0xff config=0xfe
[speaker-test] ES8311 playback ready rate=16000 mclk=4096000 volume=18
[speaker-test] start rate=16000 channels=2 freq=440Hz volume=18 amplitude=1800 duration=1s pa=on mode=both write=buffer
[speaker-test] done wrote=64000 expected=64000
[speaker-test] ES8311 muted after playback
[speaker] PA disabled pin=8
```

The same markers passed with `write=sample`, which is closer to the Arduino
`ESP_I2S` simple-tone write style.

A bounded one-second step-up test also passed with `write=sample`, `volume=24`,
and `amplitude=2600`. If that test was still inaudible, the remaining issue is
unlikely to be simple low volume.

Intermediate conclusion from the 16-bit tests:

```text
PA control: OK, EXIO8 high during playback and low afterward
ES8311 init/unmute/volume: OK by API return values
I2S write path: OK for buffer and sample write styles
Acoustic output: not yet proven by these 16-bit serial-only tests
```

Do not keep increasing volume blindly. The next useful branches were physical
speaker/header connection, PA/analog output hardware, or a vendor demo A/B test.

Additional vendor reference:

```text
Waveshare Wiki: https://www.waveshare.com/wiki/ESP32-S3-AUDIO-Board
%TEMP%/ESP32-S3-AUDIO-Board-Demo/ESP32-S3-AUDIO-Board-Demo/ESP-IDF/factory_01/main/hardeware_driver/bsp_board.c
%TEMP%/ESP32-S3-AUDIO-Board-Demo/ESP32-S3-AUDIO-Board-Demo/ESP-IDF/factory_01/main/audio_play_driver/audio_driver.c
```

The official Wiki lists the board speaker resources as ES8311, amplifier chip,
and speaker header. Its SPEAKER pinout maps ES8311 to `I2C_SDA=GPIO11`,
`I2C_SCL=GPIO10`, `I2S_MCLK=GPIO12`, `I2S_SCLK=GPIO13`,
`I2S_LRCK=GPIO14`, and `I2S_DSDIN=GPIO16`.

The ESP-IDF vendor path uses `esp_codec_dev`/`esp_audio_simple_player`, a
32-bit stereo I2S slot config, and writes 16-bit PCM promoted into 32-bit slots.
The prebuilt factory firmware in the Waveshare package was not flashed because
its volume/playback behavior is not bounded and the board previously produced
very loud audio. Instead, the safe firmware added `sample32`, which mirrors the
official 32-bit stereo slot behavior while keeping volume and amplitude bounded.

## 2026-06-18 Official-Path A/B And Acoustic Loopback Attempt

Safe A/B firmware was flashed on COM7 with:

```text
Build path: %TEMP%/homecue-edge-esp32-speaker-micprobe/build
WakeNet: wn9_jarvis_tts
Wake filter keyword: jarvis
Speaker output: enabled
Boot speaker test: disabled
Diag HTTP server: enabled
API host override: 192.0.2.118:8723
```

New diagnostic modes:

```text
write=sample32  -> ES8311 32-bit in/out, I2S 32-bit stereo slots, int16 sample << 16
write=sample32bclk -> same 32-bit slots, but ES8311 derives internal MCLK from BCLK/SCLK
regs            -> serial ES8311 register dumps before/active/before-mute/after-mute
mic             -> board microphone acoustic probe, baseline vs active playback
```

Evidence:

```text
assets/demo/esp32-speaker-regdiag-sample-v18-a1800.log
assets/demo/esp32-speaker-regdiag-sample-v18-a1800-check.json
assets/demo/esp32-speaker-idf32-sample-v18-a1800.log
assets/demo/esp32-speaker-idf32-sample-v18-a1800-check.json
assets/demo/esp32-speaker-micprobe-idf32-v18-a1800.log
assets/demo/esp32-speaker-micprobe-idf32-v18-a1800-check.json
assets/demo/esp32-speaker-micprobe-idf32-silence-v18-a0.log
assets/demo/esp32-speaker-micprobe-idf32-silence-v18-a0-check.json
```

Initial loopback result:

```text
Tone test:    volume=18 amplitude=1800 write=sample32 mic=yes
Baseline mic: mean_abs=85.1 rms=106.1 abs_peak=379
Active mic:   mean_abs=173.3 rms=486.5 abs_peak=4304

Silent ctrl:  volume=18 amplitude=0 write=sample32 mic=yes
Baseline mic: mean_abs=65.1 rms=82.0 abs_peak=270
Active mic:   mean_abs=32.8 rms=59.4 abs_peak=441
```

Final repeat runs after the safety-path firmware was uploaded:

```text
assets/demo/esp32-speaker-final-micprobe-idf32-v18-a1800.log
assets/demo/esp32-speaker-final-micprobe-idf32-v18-a1800-check.json
assets/demo/esp32-speaker-final-micprobe-idf32-v24-a2600.log
assets/demo/esp32-speaker-final-micprobe-idf32-v24-a2600-check.json

Final v18/a1800: baseline rms=94.4 active rms=78.4 abs_peak 385 -> 1104
Final v24/a2600: baseline rms=85.4 active rms=58.8 abs_peak 304 -> 427
```

The final repeat runs still prove PA enable, ES8311 32-bit playback
configuration, and complete I2S writes. They do not prove stable acoustic output
through the board microphone, because RMS did not rise during active playback.

Current conclusion:

```text
PA control: OK, EXIO8 high during playback and low afterward
ES8311 16-bit path: OK by register/API/write evidence
ES8311 32-bit official-style path: OK by register/API/write evidence
I2S write path: OK for buffer, sample, and sample32 write styles
Acoustic output: NOT reliably verified; requires human listening or external recording
Safety state: OK, no boot playback, ES8311 muted and PA low after tests
```

## 2026-06-18 BCLK Official-Path A/B

The current safe diagnostic firmware was rebuilt and flashed from:

```text
Build path: %TEMP%/homecue-edge-esp32-speaker-bclk-ab/build
WakeNet: wn9_jarvis_tts
Wake filter keyword: jarvis
Speaker output: enabled
Boot speaker test: disabled
Diag HTTP server: enabled
API host override: 192.0.2.118:8723
Board IP: 192.0.2.107
```

This pass covered the remaining Waveshare ESP-IDF codec-clock difference:

```text
sample32     -> ES8311 MCLK pin mode, REG01=3f, 32-bit slots
sample32bclk -> ES8311 BCLK/SCLK-derived internal MCLK, REG01=bf, REG02=10, 32-bit slots
```

Evidence:

```text
assets/demo/esp32-speaker-bclk-ab-mclk-sample32-v18-a1800.log
assets/demo/esp32-speaker-bclk-ab-mclk-sample32-v18-a1800-check.json
assets/demo/esp32-speaker-bclk-ab-bclk-sample32-v18-a1800.log
assets/demo/esp32-speaker-bclk-ab-bclk-sample32-v18-a1800-check.json
assets/demo/esp32-speaker-bclk-ab-network-sample32bclk-v18-a1800.json
assets/demo/esp32-speaker-bclk-ab-bclk-micprobe-v18-a1800.log
assets/demo/esp32-speaker-bclk-ab-bclk-micprobe-v18-a1800-check.json
assets/demo/esp32-speaker-bclk-ab-bclk-micprobe-v32-a5000.log
assets/demo/esp32-speaker-bclk-ab-bclk-micprobe-v32-a5000-check.json
```

Both `sample32` and `sample32bclk` passed the serial/software checks:

```text
PA readback: high during playback, low after mute
ES8311 playback config: OK
I2S TX format: accepted
I2S bytes written: 128000/128000 for a one-second 16 kHz stereo 32-bit-slot tone
No crash/reset markers
```

The HTTP diagnostic path also returned `ok=true` for
`/speaker-test?seconds=1&mode=both&volume=18&amplitude=1800&write=sample32bclk`,
and reported `speaker_pa_readback=low` afterward.

The microphone acoustic probe still did not prove external sound:

```text
BCLK v18/a1800: baseline rms=99.5 active rms=56.5 abs_peak 328 -> 399
BCLK v32/a5000: baseline rms=90.2 active rms=60.1 abs_peak 376 -> 327
```

Because the active RMS stayed below baseline even at the firmware's bounded max
diagnostic level (`volume=32`, `amplitude=5000`, one second), the remaining
blocker is now outside the proven digital path:

```text
Proven OK: ESP32 I2S pins, ES8311 register/API config, MCLK and BCLK clock modes,
           16-bit and 32-bit slot writes, TCA9555 EXIO8 PA control
Not proven: PA analog output after EXIO8, speaker connector/header continuity,
            physical speaker/cable/module, acoustic output into air
```

The local ESP-IDF toolchain (`idf.py`) was not present, so the official
`mp3_play_03` demo could not be compiled locally without installing ESP-IDF and
dependencies. The prebuilt Waveshare firmware and complete Arduino LVGL/audio
demo were not flashed because their playback/volume behavior is not bounded and
the board previously produced a loud squeal/chiptune sequence. The current safe
firmware instead mirrors the relevant official playback parameters while keeping
boot silent and PA off after every test.

## Firmware Currently On Board

```text
WakeNet: wn9_jarvis_tts
Wake filter keyword: jarvis
MultiNet: mn5q8_en / english
Port: COM7
Board IP: 192.0.2.107
Speaker output: enabled
Boot speaker test: disabled
Normal speaker volume: 12
Speaker test volume: runtime bounded, default 18, max 32
Speaker test amplitude: runtime bounded, default 1800, max 5000
PCM digital attenuation: 1/4
```

Startup remains quiet:

```text
[speaker] PA disabled pin=8
[speaker] PA readback pin=8 state=low
[speaker] ES8311 codec ready volume=12 vendor_mic_config=analog muted=1
[diag-http] ready http://192.0.2.107/ speaker_output=enabled
```

Health after the voice-chat test:

```json
{
  "speaker_output_enabled": true,
  "speaker_pa_enabled": false,
  "speaker_pa_readback": "low",
  "i2s_ready": true,
  "es8311_ready": true,
  "esp_sr_started": true
}
```

Evidence:

```text
assets/demo/esp32-low-volume-boot-serial.log
assets/demo/esp32-low-volume-http-health.json
assets/demo/esp32-low-volume-speaker-tone.log
assets/demo/esp32-low-volume-speaker-tone-check.json
assets/demo/esp32-low-volume-jarvis-voice-chat-retry.log
assets/demo/esp32-low-volume-jarvis-voice-chat-retry-markers.log
assets/demo/esp32-low-volume-jarvis-voice-chat-retry-check.json
assets/demo/esp32-low-volume-after-voice-chat-http-health.json
assets/demo/esp32-low-volume-after-voice-chat-port-state.json
```

## 2026-06-18 Door-Lock Reminder BCLK32 Repair

The "检查门锁" reminder path was reproduced before the repair. The API generated
MiMo TTS and the ESP32 downloaded and played the WAV successfully, but the
normal reply-audio path was still using the older 16-bit/MCLK output route:

```text
[/voice-chat/tasks/due-audio] reply_audio: ready /voice-chat/audio/160923e836a149259fc3710df50e5907.wav
[/voice-chat/tasks/due-audio] tts provider=mimo model=mimo-v2.5-tts voice=Mia
[speaker] downloaded 161324 audio bytes
[speaker] ES8311 playback ready rate=24000 mclk=6144000 volume=12
[speaker] playing 161324 WAV bytes rate=24000 channels=1 data=161280
[speaker] playback done
```

Firmware was updated so normal `reply_audio` playback and WebSocket streaming
TTS both use the official-demo-aligned 32-bit slot / BCLK-derived ES8311 path by
default, guarded by `HOMECUE_SPEAKER_REPLY_AUDIO_BCLK32=1`. Startup remains
quiet and PA still returns low after playback.

Passing repair proof:

```text
[/voice-chat/tasks/due-audio] status=ready task=????????????
[/voice-chat/tasks/due-audio] reply_audio: ready /voice-chat/audio/44a9036189b3449da2dfb35dcb8df6a9.wav
[/voice-chat/tasks/due-audio] tts provider=mimo model=mimo-v2.5-tts voice=Mia
[speaker] downloaded 161324 audio bytes
[speaker] PA enabled pin=8
[speaker] ES8311 playback ready rate=24000 mclk=1536000 volume=12 bits=32 clock=bclk
[speaker] playing 161324 WAV bytes rate=24000 channels=1 data=161280 path=bclk32
[speaker] playback done
[speaker] ES8311 muted after playback
[speaker] PA disabled pin=8
```

Post-playback health:

```json
{
  "speaker_output_enabled": true,
  "speaker_pa_enabled": false,
  "speaker_pa_readback": "low",
  "i2s_ready": true,
  "es8311_ready": true,
  "esp_sr_started": true
}
```

Evidence:

```text
assets/demo/esp32-speaker-reply-bclk32-boot.log
assets/demo/esp32-reminders-check-door-lock-repro.log
assets/demo/esp32-reminders-check-door-lock-repro-check.json
assets/demo/esp32-reminders-check-door-lock-bclk32.log
assets/demo/esp32-reminders-check-door-lock-bclk32-check.json
```

## Passing Software-Path Speaker Test

Command:

```powershell
scripts/test-esp32-speaker-tone.ps1 `
  -Port COM7 `
  -Seconds 12 `
  -StartAfterSeconds 2 `
  -ToneSeconds 1 `
  -ToneMode both
```

Result:

```text
[speaker-test] ES8311 playback ready rate=16000 mclk=4096000 volume=5
[speaker-test] start rate=16000 channels=2 freq=440Hz volume=5 duration=1s pa=on mode=both
[speaker-test] done wrote=64000 expected=64000
[speaker-test] ES8311 muted after playback
[speaker] PA disabled pin=8
[speaker] PA readback pin=8 state=low
```

## Passing Jarvis Voice Chat Software-Path Test

Command:

```powershell
scripts/test-esp32-voice-chat-audio.ps1 `
  -Port COM7 `
  -WakePhrase "Jarvis" `
  -ChatCommandPhrase "chat mode" `
  -UserPhrase "你好，请用一句话介绍你自己。" `
  -RequireWebSocket `
  -RequireBinaryReplyAudio `
  -RequireStreamingReplyAudio `
  -RequireNoFallback `
  -ExpectedTtsProvider mimo `
  -ExpectedTtsModel mimo-v2.5-tts `
  -ExpectedTtsVoice Mia `
  -CommandAfterWakeMs 0
```

Key result markers:

```text
[esp-sr] wake word channel 2 verified - listening for command
audio command: chat mode
[voice] chat mode
[/voice-chat/ws] recording 6s - speak now
[/voice-chat/ws] streamed 384000 PCM bytes (6000ms, speech)
[/voice-chat/ws] provider: mimo
[/voice-chat/ws] tts provider=mimo model=mimo-v2.5-tts voice=Mia
[/voice-chat/ws] binary audio frame ... bytes
[speaker] stream ES8311 playback ready rate=24000 mclk=6144000 volume=12
[speaker] stream playback done data=414720/0 segments=13
[speaker] playback done
[speaker] stream ES8311 muted after playback
[speaker] PA disabled pin=8
[speaker] PA readback pin=8 state=low
```

The scripted checks all passed:

```text
voice chat trigger: OK
recording prompts: OK
voice uploads: OK
websocket route: OK
mimo provider: OK
binary reply audio: OK
streaming reply audio done: OK
expected TTS provider/model/voice: OK
audio playback: OK
no crash: OK
```

## Safety Changes In Firmware

`firmware/esp32-audio/esp32-audio.ino` now keeps the speaker path conservative:

```text
HOMECUE_SPEAKER_OUTPUT_ENABLED defaults to 0
setup() disables the PA instead of enabling it
ES8311 initializes muted
-EnableSpeakerOutput is required to compile a playback-enabled build
-BootSpeakerTest also requires -EnableSpeakerOutput
normal WAV playback applies digital attenuation
WebSocket streaming playback applies digital attenuation
speaker-test uses volume 5 and amplitude 500
all playback paths mute ES8311 and disable PA after playback
```

The currently flashed low-volume build was compiled with:

```text
-EnableEspSr
-EnableSpeakerOutput
-EspSrWakeKeyword jarvis
-EspSrModelsBin %TEMP%/homecue-edge-esp32-jarvis/srmodels-wn9_jarvis_tts-mn5q8_en.bin
-DiagHttpServer
-ApiHostOverride 192.0.2.118
-ApiPortOverride 8723
```

No boot speaker test was enabled.

## Cache And Build Layout

Jarvis model cache:

```text
%TEMP%/homecue-edge-esp32-jarvis/
  srmodels-wn9_jarvis_tts-mn5q8_en.bin
  silent-build/
```

Low-volume speaker-enabled build:

```text
%TEMP%/homecue-edge-esp32-jarvis-low-volume/
  build/
```

## Remaining Work

This is now a functional one-turn voice-chat demo, not yet a polished smart
speaker experience.

Remaining product work:

```text
1. Improve Jarvis wake reliability. The first run needed many wake attempts;
   the retry passed on the first wake.
2. Remove the need to say "chat mode" after Jarvis, or make the command window
   longer/more forgiving.
3. Improve ASR text display/encoding in serial logs; Chinese was recognized and
   processed, but serial output showed question marks.
4. Tune volume in real listening conditions. Current settings are intentionally
   quiet and safe.
5. Add barge-in/full-duplex and echo handling if the board speaker and mic are
   used simultaneously in longer conversations.
```
