# ESP32 Speaker Physical Closure Runbook

This runbook closes the current "software markers pass, no audible sound" gap
without continuing blind volume increases.

## Goal

Prove one of these outcomes:

- The onboard speaker path produces audible MiMo TTS at a safe low volume.
- The problem is isolated to the physical/analog path after the codec/PA enable.
- The current ESP32 board is not a reliable demo target and should be replaced.

## Current Safe Software Baseline

Use the legacy reminder path as the baseline because it previously produced the
known check-door-lock prompt and now still reaches the playback markers.

Expected firmware/runtime settings:

- `HOMECUE_SPEAKER_REPLY_AUDIO_BCLK32=0`
- `SPEAKER_VOLUME=12`
- `SPEAKER_PLAYBACK_SHIFT=2`
- Boot speaker prompt disabled.
- PA disabled by default and disabled again immediately after playback.
- ES8311 muted after playback.

Expected log markers:

- `reply_audio ready`
- `downloaded audio bytes`
- `ES8311 playback ready rate=24000`
- `playing ... path=i2s16`
- `playback done`
- `PA disabled`

The current evidence says the digital/TTS path can reach these markers. If the
speaker is still silent at this point, do not keep raising volume. Move to the
physical checks below.

## 2026-06-18 Closure Attempt

Status: software/digital path closed; physical/acoustic path not closed by
serial evidence alone.

Observed state before playback:

- API `/health`: OK, active provider `mimo`, model `mimo-v2.5-pro`.
- API `/voice-chat/status`: TTS provider `mimo`, model `mimo-v2.5-tts`,
  voice `Mia`, SQLite memory enabled, WebSocket enabled.
- ESP32 USB serial: COM7 online.
- ESP32 HTTP `/health` at `192.0.2.107`: `speaker_output_enabled=true`,
  `speaker_pa_enabled=false`, `speaker_pa_readback=low`, `i2s_ready=true`,
  `es8311_ready=true`, `esp_sr_started=true`.

Safe reminder baseline evidence:

- Log: `assets/demo/esp32-speaker-physical-closure-reminder-20260618.log`
- Result: `assets/demo/esp32-speaker-physical-closure-reminder-20260618.check.json`
- Markers: `due audio ready`, `reply audio ready`, TTS provider/model/voice
  matched `mimo` / `mimo-v2.5-tts` / `Mia`.
- Audio bytes downloaded: `161324`.
- Playback markers: PA high, ES8311 ready at `24000` Hz with
  `mclk=6144000`, `volume=12`, `path=i2s16`, playback done, ES8311 muted,
  PA low.
- Crash markers: none.

Safe low tone + mic probe evidence:

- Log: `assets/demo/esp32-speaker-physical-closure-tone-mic-20260618.log`
- Result: `assets/demo/esp32-speaker-physical-closure-tone-mic-20260618.check.json`
- Command: `homecue:speaker-test 1 both 12 1200 buffer mic`
- Required checks passed: PA enable/readback, tone start, I2S writes, no short
  write, no crash, output enabled.
- Saved mic probe RMS changed from `88.1` baseline to `92.9` active. This is
  not strong enough to prove human-audible acoustic output.

Current classification:

- Software/TTS/download/I2S/codec/PA-control path is closed at the marker level.
- Human-audible speaker output is still not proven.
- Remaining closure is physical/analog: speaker header, cable, speaker unit,
  PA output signal, then bounded vendor demo A/B or hardware fallback.
- Do not keep increasing firmware/software volume until the physical checks
  below are completed.

Waveshare official-parameter A/B evidence:

- Script: `scripts/test-waveshare-speaker-ab.ps1`
- Summary: `assets/demo/waveshare-speaker-ab-safe-20260618-rerun.summary.json`
- MCLK log:
  `assets/demo/waveshare-speaker-ab-safe-20260618-rerun-official-mclk-sample32.log`
- BCLK log:
  `assets/demo/waveshare-speaker-ab-safe-20260618-rerun-official-bclk-sample32bclk.log`
- Both bounded official-equivalent paths passed required serial checks at
  `volume=12`, `amplitude=1200`, `ToneSeconds=1`.
- Human-audible output is still not proven by serial evidence.

Physical evidence template:

- `firmware/esp32-audio/SPEAKER-PHYSICAL-EVIDENCE-TEMPLATE.md`
- Current record:
  `firmware/esp32-audio/SPEAKER-PHYSICAL-EVIDENCE-2026-06-18.md`
- Current collector output:
  `assets/demo/speaker-physical-evidence-current-20260618.json`

Evidence collector:

```powershell
.\scripts\collect-speaker-physical-evidence.ps1 `
  -BoardBaseUrl http://192.0.2.107 `
  -ResultJsonPath .\assets\demo\speaker-physical-evidence-current-20260618.json `
  -Required
```

Physical-result decision recorder:

```powershell
.\scripts\record-speaker-physical-check.ps1 `
  -SpeakerHeaderConnector pass `
  -SpeakerCable pass `
  -KnownGoodSpeaker pass `
  -SpeakerHeaderAcSignal absent `
  -WaveshareFactoryDemo not_run `
  -HumanAudible no `
  -MeasurementNotes "AC not observed at speaker header during bounded playback" `
  -ResultJsonPath .\assets\demo\speaker-physical-check-decision.json
```

Hardware fallback decision:

- `firmware/esp32-audio/SPEAKER-HARDWARE-FALLBACK-DECISION.md`

Factory A/B preparation:

```powershell
.\scripts\prepare-waveshare-factory-ab.ps1 `
  -Port COM7 `
  -ResultJsonPath .\assets\demo\waveshare-factory-ab-plan.json `
  -Required
```

The factory script is dry-run by default. Do not pass `-FlashFactory` until the
speaker cable, known-good speaker, and speaker-header AC measurement justify the
factory A/B branch.

## Safe Test Command

Run this only when the speaker is connected and placed away from the microphone
to avoid feedback. Keep the volume setting at the safe baseline above.

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
  -SaveLogPath .\assets\demo\esp32-reminders-check-door-lock-legacy-mclk-retry.log `
  -MarkerPath .\assets\demo\esp32-reminders-check-door-lock-legacy-mclk-retry.check.json `
  -ResultJsonPath .\assets\demo\esp32-reminders-check-door-lock-legacy-mclk-retry.result.json `
  -Required
```

If the user-facing reminder must be Chinese, use the same command with
`-TaskTitle` set to the Chinese reminder text from the demo script.

## Physical / Analog Closure Steps

### 1. Header and Cable

- Confirm the actual speaker is connected to the board's speaker output/header,
  not to an unrelated GPIO/I2S/debug header.
- Reseat the speaker connector and inspect the wire crimp/contact points.
- Check that the speaker wires are not shorted together.
- If a second known-good speaker/cable is available, test it at the same low
  volume baseline before changing firmware again.

### 2. Speaker Unit

- Check the speaker unit against the board vendor's rated impedance/power.
- If using a multimeter, verify the speaker is not open-circuit. Do not measure
  resistance while playback is active.
- If the speaker is a module with its own amplifier, verify it is powered and
  that the board output type matches the module input type.

### 3. PA Output Signal

During the safe reminder playback window:

- Measure AC voltage across the speaker terminals if a multimeter is available.
- If an oscilloscope or USB audio probe is available, capture the speaker output
  only during the 1-3 second playback window.
- Do not short either speaker terminal to ground unless the board schematic
  explicitly says the output is single-ended.

Interpretation:

- Logs pass, AC signal present, no sound: speaker/cable/mechanical output issue.
- Logs pass, no AC signal: PA output, codec-to-PA, mute, or board hardware issue.
- Logs fail before playback: software or cloud/TTS regression, not a physical
  speaker diagnosis.

### 4. Vendor Demo A/B

Use a vendor audio playback demo only after the physical connection has been
checked and the speaker is placed away from the microphone.

Safety rules:

- Start at the lowest available volume.
- Prefer a short bounded WAV/tone over music loops.
- Stop the test immediately if feedback or very loud output appears.
- Save the vendor demo log and firmware build settings under `assets/demo/`.

If the vendor demo is audible but HomeCue is silent, return to firmware I2S,
codec, PA and PCM-format comparison. If both are silent, treat it as physical
hardware failure or wrong speaker connection.

## Decision Tree

1. Safe HomeCue reminder markers do not appear:
   - Fix the software path before touching hardware.
2. Markers appear and audible TTS is heard:
   - Speaker closure is complete.
3. Markers appear, no audible TTS, and PA output has signal:
   - Replace/reseat speaker and cable.
4. Markers appear, no audible TTS, and PA output has no signal:
   - Treat the current board audio output path as suspect.
5. No measurement equipment is available and repeated safe baseline tests remain
   silent:
   - Stop debugging software volume.
   - Switch to a demo edge device with verified microphone and speaker demos.

## Hardware Fallback Criteria

The replacement edge device must have:

- Official, reproducible microphone capture demo.
- Official, reproducible speaker playback demo.
- Clear speaker wiring or built-in speaker.
- Enough compute/connectivity for wake/VAD capture plus WebSocket streaming.
- A path to add camera/video emotion recognition if required by the final demo.

Acceptable fallback classes:

- ESP32-S3 voice kit with integrated mic and speaker and working vendor demos.
- Raspberry Pi class device with USB microphone and USB or 3.5 mm speaker.
- Android edge device running a local capture/playback client.

## Exit Evidence

Save final evidence under `assets/demo/`:

- HomeCue reminder log.
- Marker JSON.
- Firmware build options or exact environment overrides.
- Photo or short video of the physical speaker connection.
- Optional PA-output measurement photo/video.
- If fallback hardware is selected, vendor demo proof and replacement rationale.
