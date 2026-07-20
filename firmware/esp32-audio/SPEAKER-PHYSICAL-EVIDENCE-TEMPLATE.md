# Speaker Physical Evidence Template

Use this file as the checklist and evidence record when closing the speaker
header, cable, speaker unit, and PA-output segment.

Do not increase firmware volume to compensate for a missing physical signal.

## Test Context

- Date:
- Operator:
- Board:
- ESP32 serial port:
- Board IP:
- Firmware build / commit:
- Speaker test volume:
- Speaker test amplitude:
- Speaker position relative to microphone:

## Baseline Software Evidence

- Reminder/TTS log:
- Reminder/TTS result JSON:
- Waveshare-equivalent A/B summary:
- Board `/health` result:

Expected software markers:

- `reply_audio ready`
- `downloaded audio bytes`
- `ES8311 playback ready`
- `PA enabled`
- `playback done`
- `ES8311 muted after playback`
- `PA disabled`

## 1. Speaker Header / Connector

- Speaker connected to board `SPEAKER` output/header:
- Connector fully seated:
- Connector orientation verified against board markings:
- No loose crimp/contact:
- No visible wire break:
- No short between speaker wires while powered off:
- Evidence photo/video path:

Result:

- Pass / Fail / Not measured
- Notes:

## 2. Speaker Cable

- Cable continuity measured end-to-end while powered off:
- Cable remains continuous while gently moved:
- Replacement cable tested:
- Evidence photo/video path:

Result:

- Pass / Fail / Not measured
- Notes:

## 3. Speaker Unit

- Speaker matches board/vendor impedance and power rating:
- Speaker is not open-circuit while powered off:
- Speaker is not short-circuit while powered off:
- Replacement known-good speaker tested:
- Evidence photo/video path:

Result:

- Pass / Fail / Not measured
- Notes:

## 4. PA Output During Playback

Run a bounded playback test while measuring across the two speaker terminals.
Do not short either speaker terminal to GND unless the schematic explicitly says
the output is single-ended.

Recommended command:

```powershell
.\scripts\test-esp32-reminder-audio.ps1 `
  -Port COM7 `
  -Seconds 90 `
  -StartAfterSeconds 3 `
  -SkipReset `
  -ApiBase http://127.0.0.1:8723 `
  -TaskTitle "check door lock" `
  -DueText "now" `
  -ExpectedTtsProvider mimo `
  -ExpectedTtsModel mimo-v2.5-tts `
  -ExpectedTtsVoice Mia `
  -Required
```

Measurement:

- Meter/scope model:
- Measurement point:
- AC voltage or waveform observed during playback:
- Same measurement when idle:
- Evidence photo/video path:

Result:

- AC signal present / No AC signal / Not measured
- Notes:

## 5. Waveshare Official Demo A/B

Safe mapped A/B already available:

```powershell
.\scripts\test-waveshare-speaker-ab.ps1 `
  -Port COM7 `
  -ToneSeconds 1 `
  -Volume 12 `
  -Amplitude 1200 `
  -OutputPrefix .\assets\demo\waveshare-speaker-ab-safe-YYYYMMDD `
  -SkipReset `
  -Required
```

This maps the official Waveshare playback parameters to the bounded HomeCue
diagnostic firmware:

- ES8311 DAC
- EXIO8 PA enable
- 32-bit stereo slots
- `sample32`
- `sample32bclk`

Unbounded official factory binary:

- File:
  `%TEMP%/ESP32-S3-AUDIO-Board-Demo/ESP32-S3-AUDIO-Board-Demo/Firmware/ESP32-S3-AUDIO-Board.bin`
- Flash only after physical checks and with a safe acoustic setup.
- Do not use it as the first A/B path because playback and volume behavior are
  not bounded by HomeCue safety controls.

Result:

- Safe mapped A/B pass / fail:
- Factory binary flashed:
- Factory binary audible:
- Evidence path:

## Decision

Choose one:

- Software path failed: return to firmware/cloud debugging.
- Software path passed, AC signal present, no sound: replace speaker/cable.
- Software path passed, no AC signal: PA/output hardware or board issue.
- Safe A/B passed and no audible output: physical/analog issue remains.
- Official factory demo audible, HomeCue silent: compare firmware I2S/codec/PA
  settings again.
- Official factory demo silent: stop spending time on this board and switch
  hardware.

Final decision:

- Continue current board / Replace cable / Replace speaker / Measure PA output
  again / Flash factory demo / Switch edge hardware

Notes:
