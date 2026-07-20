# Speaker Physical Evidence - 2026-06-18

This record tracks the physical speaker-chain closure objective:

1. Replace or re-crimp/resolder the speaker cable.
2. Replace the speaker with a same-spec known-good unit.
3. Measure AC output across the speaker header during playback.
4. If there is no speaker-header output, run Waveshare official demo A/B.
5. If the official demo is also silent, stop spending time on this board and
   switch to an edge device with verified microphone and speaker demos.

## Test Context

- Date: 2026-06-18
- Operator: Codex for software-side checks; physical handling still required
- Board: Waveshare ESP32-S3-AUDIO-Board
- ESP32 serial port: COM7
- Board IP: `192.0.2.107`
- Speaker test volume: `12`
- Speaker test amplitude: `1200`
- Safety policy: no boot auto-play, no blind volume increase, PA off when idle

## Current Board Health

Latest observed board `/health`:

```json
{
  "status": "ok",
  "device": "esp32-audio-board",
  "wifi_ip": "192.0.2.107",
  "esp_sr_enabled": true,
  "speaker_output_enabled": true,
  "speaker_pa_enabled": false,
  "speaker_pa_readback": "low",
  "i2s_ready": true,
  "es8311_ready": true,
  "esp_sr_started": true
}
```

Interpretation:

- Board is online.
- Speaker output feature is enabled.
- PA is low/off when idle.
- I2S and ES8311 are ready.

## Baseline Software Evidence

Reminder/TTS evidence:

- `assets/demo/esp32-check-door-lock-reproduce-20260618.log`
- `assets/demo/esp32-check-door-lock-reproduce-20260618.check.json`
- `assets/demo/esp32-speaker-physical-closure-reminder-20260618.log`
- `assets/demo/esp32-speaker-physical-closure-reminder-20260618.check.json`

Observed markers:

- MiMo TTS ready: `mimo / mimo-v2.5-tts / Mia`
- WAV downloaded
- PA enabled and readback high during playback
- ES8311 ready
- I2S writes complete
- Playback done
- ES8311 muted after playback
- PA disabled and readback low after playback
- No crash markers

Conclusion:

- Software/TTS/download/I2S/ES8311/PA-control path is closed at marker level.
- Human-audible output is not proven by software logs.

## Waveshare Official-Parameter A/B

Safe mapped A/B script:

- `scripts/test-waveshare-speaker-ab.ps1`

Summary:

- `assets/demo/waveshare-speaker-ab-safe-20260618-rerun.summary.json`

Cases:

- `official-mclk-sample32`: pass
- `official-bclk-sample32bclk`: pass

Mapping:

- PA: EXIO8 / GPIO_PWR_CTRL
- DAC: ES8311
- I2S: standard stereo
- `sample32`: 16-bit sample shifted into 32-bit slots
- `sample32bclk`: same 32-bit slots with ES8311 BCLK-derived internal clock

Conclusion:

- Bounded Waveshare official-equivalent playback parameters pass.
- This does not prove human-audible output.
- The unbounded Waveshare factory binary was not flashed because playback and
  volume behavior are not controlled by HomeCue safety logic.

## Physical Checks

### 1. Speaker Header / Connector

- Speaker connected to board `SPEAKER` output/header: Not measured
- Connector fully seated: Not measured
- Connector orientation verified against board markings: Not measured
- No loose crimp/contact: Not measured
- No visible wire break: Not measured
- No short between speaker wires while powered off: Not measured
- Evidence photo/video path: Missing

Result:

- Not measured

### 2. Speaker Cable

- Cable continuity measured end-to-end while powered off: Not measured
- Cable remains continuous while gently moved: Not measured
- Replacement cable tested: Not measured
- Re-crimp/resolder performed: Not measured
- Evidence photo/video path: Missing

Result:

- Not measured

### 3. Speaker Unit

- Speaker matches board/vendor impedance and power rating: Not measured
- Speaker is not open-circuit while powered off: Not measured
- Speaker is not short-circuit while powered off: Not measured
- Replacement same-spec known-good speaker tested: Not measured
- Evidence photo/video path: Missing

Result:

- Not measured

### 4. PA Output During Playback

- Meter/scope model: Missing
- Measurement point: Missing
- AC voltage or waveform across speaker terminals during playback: Not measured
- Same measurement when idle: Not measured
- Evidence photo/video path: Missing

Result:

- Not measured

## Decision Gate

Current decision:

- Do not continue firmware volume changes.
- Do not claim speaker closure complete.
- Perform physical checks in this order:
  1. Replace/reseat/re-crimp the speaker cable.
  2. Test a same-spec known-good speaker.
  3. Measure AC voltage/waveform across the speaker header during bounded
     playback.
  4. If no header output is measured, optionally flash the Waveshare factory
     binary only under controlled acoustic conditions.
  5. If the factory binary is also silent, switch to another edge device with
     verified microphone and speaker demos.

Prepared fallback decision:

- `firmware/esp32-audio/SPEAKER-HARDWARE-FALLBACK-DECISION.md`

Prepared factory A/B dry-run:

- `scripts/prepare-waveshare-factory-ab.ps1`
- Planned output: `assets/demo/waveshare-factory-ab-plan-20260618.json`
- Factory binary exists: yes
- Factory binary length: `6534958` bytes
- Factory flash command is prepared but not executed.
- HomeCue recovery command is prepared.

Decision recorder:

- `scripts/record-speaker-physical-check.ps1`

Example states:

```powershell
# Current state: physical checks still missing.
.\scripts\record-speaker-physical-check.ps1 `
  -ResultJsonPath .\assets\demo\speaker-physical-check-current.json

# Speaker header AC output is absent; next action should be factory demo A/B.
.\scripts\record-speaker-physical-check.ps1 `
  -SpeakerHeaderConnector pass `
  -SpeakerCable pass `
  -KnownGoodSpeaker pass `
  -SpeakerHeaderAcSignal absent `
  -HumanAudible no `
  -ResultJsonPath .\assets\demo\speaker-physical-check-no-ac.json

# Factory demo is also silent; next action should be hardware switch.
.\scripts\record-speaker-physical-check.ps1 `
  -SpeakerHeaderConnector pass `
  -SpeakerCable pass `
  -KnownGoodSpeaker pass `
  -SpeakerHeaderAcSignal absent `
  -WaveshareFactoryDemo silent `
  -HumanAudible no `
  -ResultJsonPath .\assets\demo\speaker-physical-check-switch-hardware.json
```

Completion status:

- Incomplete. The physical requirements need human handling and measurement
  evidence.
