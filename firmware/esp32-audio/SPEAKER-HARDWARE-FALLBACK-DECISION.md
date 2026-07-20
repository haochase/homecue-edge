# Speaker Hardware Fallback Decision

This document is the decision path if the current Waveshare
ESP32-S3-AUDIO-Board remains silent after physical speaker checks.

## Current Gate

Do not switch hardware until these physical checks have evidence:

1. Speaker cable replaced, re-crimped, or re-soldered.
2. Same-spec known-good speaker tested.
3. AC output measured across the speaker header during bounded playback.
4. If there is no speaker-header output, Waveshare official demo A/B is run
   under controlled acoustic conditions.

Switch hardware when:

- HomeCue software playback markers pass.
- The bounded Waveshare official-equivalent A/B passes.
- Speaker cable and speaker unit are known-good.
- Speaker header has no measurable playback signal, or the unbounded Waveshare
  factory demo is also silent.

Record that decision with:

```powershell
.\scripts\record-speaker-physical-check.ps1 `
  -SpeakerHeaderConnector pass `
  -SpeakerCable pass `
  -KnownGoodSpeaker pass `
  -SpeakerHeaderAcSignal absent `
  -WaveshareFactoryDemo silent `
  -HumanAudible no `
  -ResultJsonPath .\assets\demo\speaker-physical-check-switch-hardware.json
```

## Candidate Matrix

| Candidate | Why it fits | Demo confidence | Main risk | Recommendation |
| --- | --- | --- | --- | --- |
| Espressif ESP32-S3-BOX-3 | ESP32-S3 voice/HMI devkit with LCD, microphones, speaker, buttons, sensors, ESP-BOX/ESP-SR/RainMaker/Matter ecosystem and official demo links. | High for voice hardware. | Procurement and porting time; no camera in the base product description. | P0 replacement if staying ESP32/SR-first. |
| Espressif ESP32-S3-Korvo-2 | ESP32-S3 multimedia board with two-microphone array, LCD, camera, TF and speaker listed in Espressif devkit matrix. | High for audio/video edge prototype. | May be older or harder to obtain quickly. | P1 if video emotion recognition becomes required on the same edge device. |
| Espressif ESP32-S31-Function-Coreboard-1 | Newer Espressif board with onboard mic plus speaker interface and out-of-box AI voice interaction evaluation. | Medium-high, but newer stack. | Porting risk and availability. | P1/P2 evaluation target. |
| M5Stack Atom Voice | Compact ESP32-based smart speaker with integrated microphone and speaker, record/play examples, Bluetooth speaker firmware and Arduino/ESP-IDF paths. | Medium-high for simple audio I/O. | ESP32-PICO-D4, 4 MB flash, less headroom than ESP32-S3; no camera. | Fast low-cost audio fallback if HomeCue cloud does most work. |
| Raspberry Pi + Codec Zero | Linux edge device with Codec Zero bi-directional I2S audio, built-in MEMS microphone, mono speaker driver and documented speaker/mic setup; easy camera/video path. | High for product demo reliability. | Not microcontroller firmware; changes edge-device story. | Best fallback when demo reliability matters more than ESP32 purity. |

## Recommended Branches

### Branch A: Stay ESP32

Use ESP32-S3-BOX-3 first.

Reasons:

- Keeps ESP32 / ESP-SR / wake-word story close to current firmware.
- Has integrated microphones and speaker.
- Official product page links user guide and demo code.
- Better fit for a physical EdgeAgent voice terminal than continuing to debug a
  suspect speaker header indefinitely.

First validation on the new device:

1. Flash official demo.
2. Confirm speaker output by ear.
3. Confirm microphone capture.
4. Confirm wake word or button-triggered voice flow.
5. Port HomeCue WebSocket PCM upload and TTS playback.

### Branch B: Prioritize Product Demo Reliability

Use Raspberry Pi + Codec Zero or Raspberry Pi + known-good USB microphone and
USB/active speaker.

Reasons:

- ALSA/Pulse/PipeWire tooling gives direct audio input/output tests.
- Python client can reuse the existing FastAPI/WebSocket protocol quickly.
- Camera/video emotion recognition is easier to add.
- Speaker replacement is a commodity USB/audio problem, not a board-specific PA
  debugging problem.

First validation:

```bash
arecord -l
aplay -l
speaker-test -t sine -f 440 -c 1
arecord -d 3 /tmp/mic.wav
aplay /tmp/mic.wav
```

Then run a Python edge client:

```text
Jarvis/button trigger -> record PCM -> /voice-chat/ws -> receive reply_audio -> aplay
```

### Branch C: Smallest Audio Fallback

Use M5Stack Atom Voice.

Reasons:

- Integrated mic and speaker in a compact package.
- Official docs provide Record & Play and Bluetooth speaker examples.
- Suitable if the cloud keeps ASR/dialogue/TTS and the device only streams audio
  and plays replies.

Risk:

- More limited RAM/flash than ESP32-S3 boards.
- Wake word and buffering may need simplification.

## Factory Demo Policy

The current Waveshare package contains a prebuilt factory binary:

```text
%TEMP%/ESP32-S3-AUDIO-Board-Demo/ESP32-S3-AUDIO-Board-Demo/Firmware/ESP32-S3-AUDIO-Board.bin
```

Only flash it after:

- Speaker cable and speaker unit are physically verified.
- Speaker header AC output is missing or inconclusive.
- The board is placed in a safe acoustic setup.
- A recovery path to HomeCue firmware is ready.

Do not use factory flashing as a substitute for checking the speaker header and
speaker unit.

Prepare the factory A/B plan without flashing:

```powershell
.\scripts\prepare-waveshare-factory-ab.ps1 `
  -Port COM7 `
  -ResultJsonPath .\assets\demo\waveshare-factory-ab-plan.json `
  -Required
```

This script defaults to dry-run and prints both the factory flash command and
the HomeCue recovery command. Use `-FlashFactory` only after the physical checks
justify factory A/B.

## Source Links

- Espressif ESP32-S3-BOX devkit page:
  https://www.espressif.com/en/products/devkits/esp32-s3-box
- M5Stack Atom Voice docs:
  https://docs.m5stack.com/en/atom/atomecho
- Raspberry Pi Audio / Codec Zero docs:
  https://www.raspberrypi.com/documentation/accessories/audio.html
