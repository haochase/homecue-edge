/*
 * HomeCue Edge - ESP32-S3-AUDIO-Board firmware (MVP "Concept A")
 * ---------------------------------------------------------------
 * Board : Waveshare ESP32-S3-AUDIO-Board (ESP32-S3R8, 8MB PSRAM / 16MB Flash)
 * Role  : Voice edge terminal + physical human-in-the-loop confirmation.
 *
 * Flow  : wake / button  ->  fixed command word  ->  preset prompt
 *         -> POST /plan (agent_mode=true, execute=false)  [PROPOSE, no device change]
 *         -> RGB shows "ready", PC web panel shows the plan + trace
 *         -> user presses CONFIRM  -> POST /execute  (actually run)
 *           user presses REJECT   -> discard
 *           user presses NEXT     -> cycle to next command word
 *
 * This file is OUR glue layer only. The audio capture + wake/command
 * recognition (ESP-SR WakeNet/MultiNet) and the TCA9555 GPIO-expander
 * driver for the RGB ring + user keys come from the Waveshare vendor
 * "voice recognition" example. Search for "TODO[VENDOR]" below and wire
 * those spots into the vendor example you flashed first (see README.md).
 *
 * ---- Dependencies (Arduino Library Manager) -------------------------------
 *   - ArduinoJson           (v7.x)            -> JSON build/parse
 *   - WiFi, HTTPClient, Wire (bundled with esp32 core)
 *
 * Button-route MVP (default): no ESP-SR / vendor libs. Keys via bare I2C
 * TCA9555 read + BOOT (GPIO0). RGB logs to Serial until vendor driver wired.
 *
 * Serial test route: send commands over the USB serial port to exercise the
 * same /plan -> /execute path without touching the physical keys:
 *   homecue:plan [0|1|2]
 *   homecue:speaker-test [seconds] [both|left|right|sweep]
 *   homecue:voice-chat [seconds]
 *   homecue:voice-chat-ws [seconds]
 *   homecue:voice-chat-session [turns] [seconds]
 *   homecue:voice-chat-ws-session [turns] [seconds]
 *   homecue:voice-chat-reset
 *   homecue:execute
 *   homecue:reject
 *
 * Voice route (optional): ESP-SR + vendor TCA9555 RGB driver - see TODO[VENDOR].
 *
 * ---- Board / IDE setup ----------------------------------------------------
 *   Boards Manager URL : https://espressif.github.io/arduino-esp32/package_esp32_index.json
 *   Board              : "ESP32S3 Dev Module"
 *   PSRAM              : "OPI PSRAM"          (board has 8MB OPI PSRAM)
 *   Flash Size         : "16MB (128Mb)"
 *   Partition Scheme   : a scheme with enough app space for ESP-SR models
 *                        (e.g. "16M Flash (3MB APP/9.9MB FATFS)")
 *   USB CDC On Boot    : Enabled (for Serial over USB-C)
 *
 * ---- Key pins (from Waveshare wiki) ---------------------------------------
 *   ES7210 mic I2S : MCLK=GPIO12, SCLK=GPIO13, LRCK=GPIO14, ASDOUT=GPIO15
 *   ES8311 speaker: same I2S clocks + DOUT=GPIO16
 *   I2C bus        : SDA=GPIO11, SCL=GPIO10   (PCF85063 RTC + TCA9555 expander)
 *   RGB ring (7x), user keys: via TCA9555 expander (see vendor driver)
 */

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClient.h>
#include <HTTPClient.h>
#include <WebServer.h>
#include <Wire.h>
#include <ArduinoJson.h>
#include <math.h>

#include "secrets.h"  // copy secrets.h.example -> secrets.h and fill in (gitignored)

struct MicAcousticStats;

#ifndef VOICE_CHAT_ACCESS_TOKEN
#define VOICE_CHAT_ACCESS_TOKEN ""
#endif

// ---------------------------------------------------------------------------
// Optional voice route: offline ESP-SR command words (DEFAULT OFF)
// ---------------------------------------------------------------------------
// Set to 1 ONLY in an environment that provides the arduino-esp32 "ESP_SR"
// library plus speech models (srmodels.bin flashed via an "ESP SR" partition).
// Left at 0 so the DEFAULT build needs no ESP-SR dependency at all: the CI /
// firmware contract check, a normal compile, and the button + serial fallback
// routes are all unaffected. Enable with -DENABLE_ESP_SR=1 (or flip the value
// here) once the models/library are installed. See README.md section
// "4C. Voice command route (optional, ESP-SR)".
#ifndef ENABLE_ESP_SR
#define ENABLE_ESP_SR 0
#endif

#ifndef HOMECUE_BOOT_SPEAKER_TEST
#define HOMECUE_BOOT_SPEAKER_TEST 0
#endif

#ifndef HOMECUE_BOOT_SPEAKER_TEST_SECONDS
#define HOMECUE_BOOT_SPEAKER_TEST_SECONDS 1
#endif

#ifndef HOMECUE_DIAG_HTTP_SERVER
#define HOMECUE_DIAG_HTTP_SERVER 0
#endif

#ifndef HOMECUE_SPEAKER_OUTPUT_ENABLED
#define HOMECUE_SPEAKER_OUTPUT_ENABLED 0
#endif

#ifndef HOMECUE_SPEAKER_REPLY_AUDIO_BCLK32
#define HOMECUE_SPEAKER_REPLY_AUDIO_BCLK32 0
#endif

#ifndef HOMECUE_WAKE_AUTO_VOICE_CHAT
#define HOMECUE_WAKE_AUTO_VOICE_CHAT 1
#endif

#ifndef HOMECUE_SR_WAKE_KEYWORD
#define HOMECUE_SR_WAKE_KEYWORD "hiesp"
#endif

#if ENABLE_ESP_SR
// These headers ship with the arduino-esp32 3.x ESP-SR library; they are pulled
// in ONLY when the voice route is explicitly enabled so the default build stays
// dependency-free. Header names may differ slightly between core versions.
#include <esp_heap_caps.h>
#include <esp_partition.h>
#include "ESP_I2S.h"
#include "ESP_SR.h"
extern "C" {
#include "es7210.h"
#include "es8311.h"
#include "esp_mn_models.h"
#include "esp_wn_models.h"
#include "model_path.h"
}
#endif

// ---------------------------------------------------------------------------
// Types - MUST be before any function definition (Arduino .ino auto-prototypes)
// ---------------------------------------------------------------------------
enum RgbState { RGB_IDLE, RGB_LISTENING, RGB_THINKING, RGB_READY, RGB_REJECTED, RGB_OFFLINE };
enum UserKey { KEY_NONE, KEY_CONFIRM, KEY_REJECT, KEY_NEXT };

struct CommandWord {
  const char* label;   // human label / what the user says
  const char* prompt;  // preset natural-language prompt sent to /plan
};

// ---------------------------------------------------------------------------
// Button-route MVP - GPIO / TCA9555 (no vendor libraries)
// ---------------------------------------------------------------------------
// I2C: SDA=GPIO11, SCL=GPIO10. TCA9555 @ 0x20. User keys on expander pins 9/10/11
// (active low, inverted in hardware). BOOT = GPIO0 (active low).
static constexpr uint8_t I2C_SDA = 11;
static constexpr uint8_t I2C_SCL = 10;
static constexpr uint8_t TCA9555_ADDR = 0x20;
static constexpr uint8_t PIN_BOOT = 0;
static constexpr uint8_t SPEAKER_PA_CTRL_PIN = 8; // Waveshare demo Audio_PA_EN(): TCA9555_EXIO8
static constexpr uint8_t KEY_PIN_PLAN = 9;    // KEY1 -> trigger /plan
static constexpr uint8_t KEY_PIN_CONFIRM = 10; // KEY2 -> POST /execute
static constexpr uint8_t KEY_PIN_REJECT = 11;  // KEY3 -> discard proposal

static constexpr uint32_t KEY_COOLDOWN_MS = 400;

static bool g_tca9555Ok = false;
static bool g_speakerPaEnabled = false;
static uint32_t g_lastKeyMs = 0;
static String g_serialLine;
static WebServer g_diagServer(80);
static bool g_diagServerStarted = false;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

static const char* VOICE_CHAT_USER_ID = "home-user";
static const char* VOICE_CHAT_DEVICE_ID = "esp32-audio-board";
static const char* VOICE_CHAT_WAKE_ACK_TEXT = "for you sir, always";

// Endpoints on the PC FastAPI gateway. PC_HOST / PC_PORT come from secrets.h.
static String planUrl() { return String("http://") + PC_HOST + ":" + PC_PORT + "/plan"; }
static String executeUrl() { return String("http://") + PC_HOST + ":" + PC_PORT + "/execute"; }
static String healthUrl() { return String("http://") + PC_HOST + ":" + PC_PORT + "/health"; }
static String voiceChatUrl() { return String("http://") + PC_HOST + ":" + PC_PORT + "/voice-chat"; }
static String voiceChatWsPath() { return "/voice-chat/ws"; }
static bool voiceChatAccessTokenConfigured() { return VOICE_CHAT_ACCESS_TOKEN[0] != '\0'; }

static bool isUrlUnreserved(char value) {
  return (value >= 'A' && value <= 'Z') ||
         (value >= 'a' && value <= 'z') ||
         (value >= '0' && value <= '9') ||
         value == '-' || value == '_' || value == '.' || value == '~';
}

static char urlHexDigit(uint8_t value) {
  return value < 10 ? (char)('0' + value) : (char)('A' + value - 10);
}

static String urlEncodeComponent(const char* value) {
  String encoded;
  if (value == nullptr) {
    return encoded;
  }
  for (const char* cursor = value; *cursor != '\0'; cursor++) {
    uint8_t byteValue = (uint8_t)*cursor;
    if (isUrlUnreserved((char)byteValue)) {
      encoded += (char)byteValue;
      continue;
    }
    encoded += '%';
    encoded += urlHexDigit((byteValue >> 4) & 0x0F);
    encoded += urlHexDigit(byteValue & 0x0F);
  }
  return encoded;
}

static String voiceChatAccessTokenQuery(bool hasExistingQuery) {
  if (!voiceChatAccessTokenConfigured()) {
    return "";
  }
  return String(hasExistingQuery ? "&" : "?") + "access_token=" + urlEncodeComponent(VOICE_CHAT_ACCESS_TOKEN);
}

static String voiceChatTtsUrl(const char* text) {
  String url = String("http://") + PC_HOST + ":" + PC_PORT + "/voice-chat/tts?text=" + urlEncodeComponent(text);
  url += voiceChatAccessTokenQuery(true);
  return url;
}

static void addVoiceChatAuthHeader(HTTPClient& http) {
  if (voiceChatAccessTokenConfigured()) {
    http.addHeader("Authorization", String("Bearer ") + VOICE_CHAT_ACCESS_TOKEN);
  }
}

static String voiceChatDueAudioUrl() {
  String url = String("http://") + PC_HOST + ":" + PC_PORT + "/voice-chat/tasks/due-audio?user_id=" + VOICE_CHAT_USER_ID;
  url += voiceChatAccessTokenQuery(true);
  return url;
}

// HTTPClient::setTimeout() takes uint16_t on arduino-esp32 3.x; keep values <= 65535.
// /plan with agent_mode can take 20-60s (MiMo/Qwen); default HTTPClient timeout is too short.
static constexpr uint16_t HTTP_TIMEOUT_PLAN_MS = 60000;
static constexpr uint16_t HTTP_TIMEOUT_EXECUTE_MS = 15000;
static constexpr uint16_t HTTP_TIMEOUT_HEALTH_MS = 10000;
static constexpr uint16_t HTTP_TIMEOUT_VOICE_CHAT_MS = 60000;
static constexpr uint16_t HTTP_TIMEOUT_AUDIO_MS = 30000;
static constexpr uint16_t VOICE_CHAT_WS_CONNECT_TIMEOUT_MS = 15000;
static constexpr uint32_t VOICE_CHAT_WS_TURN_TIMEOUT_MS = 120000;
static constexpr size_t VOICE_CHAT_WS_BINARY_CHUNK_BYTES = 2048;

static constexpr uint8_t VOICE_CHAT_RECORD_SECONDS = 6;
static constexpr uint8_t VOICE_CHAT_MIN_SECONDS = 1;
static constexpr uint8_t VOICE_CHAT_MAX_SECONDS = 8;
static constexpr uint8_t VOICE_CHAT_SESSION_TURNS = 2;
static constexpr uint8_t VOICE_CHAT_MAX_SESSION_TURNS = 5;
static constexpr uint32_t VOICE_CHAT_SAMPLE_RATE = 16000;
static constexpr uint16_t VOICE_CHAT_BITS_PER_SAMPLE = 16;
static constexpr uint16_t VOICE_CHAT_CHANNELS = 2;
static constexpr uint16_t VOICE_CHAT_UPLOAD_CHANNELS = 1;
static constexpr size_t VOICE_CHAT_WAV_HEADER_BYTES = 44;
static constexpr size_t VOICE_CHAT_MAX_REPLY_WAV_BYTES = 512 * 1024;
static constexpr uint16_t VOICE_CHAT_WS_VAD_MIN_RECORD_MS = 1800;
static constexpr uint16_t VOICE_CHAT_WS_VAD_TRAILING_SILENCE_MS = 900;
static constexpr uint16_t VOICE_CHAT_WS_VAD_MIN_SPEECH_MS = 240;
static constexpr uint16_t VOICE_CHAT_WS_VAD_NOISE_PROBE_MS = 320;
static constexpr uint16_t VOICE_CHAT_WS_VAD_MIN_MEAN_ABS = 180;
static constexpr uint16_t VOICE_CHAT_WS_VAD_NOISE_MARGIN = 180;
static constexpr uint8_t VOICE_CHAT_UPLOAD_GAIN_SHIFT = 0;
static constexpr uint32_t REMINDER_AUTO_FIRST_POLL_DELAY_MS = 15000;
static constexpr uint32_t REMINDER_AUTO_POLL_INTERVAL_MS = 60000;
static constexpr uint32_t REMINDER_AUTO_RETRY_INTERVAL_MS = 15000;
static constexpr uint8_t SPEAKER_VOLUME = 12;
static constexpr uint8_t SPEAKER_TEST_VOLUME = 18;
static constexpr uint8_t SPEAKER_TEST_DEFAULT_SECONDS = 1;
static constexpr uint8_t SPEAKER_TEST_MIN_SECONDS = 1;
static constexpr uint8_t SPEAKER_TEST_MAX_SECONDS = 3;
static constexpr uint16_t SPEAKER_TEST_FREQUENCY_HZ = 440;
static constexpr uint16_t SPEAKER_TEST_SWEEP_START_HZ = 440;
static constexpr uint16_t SPEAKER_TEST_SWEEP_END_HZ = 880;
static constexpr int16_t SPEAKER_TEST_AMPLITUDE = 1800;
static constexpr uint8_t SPEAKER_TEST_MAX_VOLUME = 32;
static constexpr int16_t SPEAKER_TEST_MAX_AMPLITUDE = 5000;
static constexpr uint8_t SPEAKER_PLAYBACK_SHIFT = 2;
static constexpr size_t SPEAKER_TEST_FRAMES_PER_CHUNK = 256;

static constexpr uint8_t SPEAKER_TEST_BOTH = 0;
static constexpr uint8_t SPEAKER_TEST_LEFT = 1;
static constexpr uint8_t SPEAKER_TEST_RIGHT = 2;
static constexpr uint8_t SPEAKER_TEST_SWEEP = 3;
static constexpr uint8_t SPEAKER_TEST_ALL = 4;

static constexpr uint8_t SPEAKER_TEST_WRITE_BUFFER = 0;
static constexpr uint8_t SPEAKER_TEST_WRITE_SAMPLE = 1;
static constexpr uint8_t SPEAKER_TEST_WRITE_SAMPLE32 = 2;
static constexpr uint8_t SPEAKER_TEST_WRITE_SAMPLE32_BCLK = 3;

struct MicAcousticStats {
  uint32_t totalBytes;
  uint32_t sampleCount;
  uint32_t zeroCount;
  uint32_t clippedCount;
  int16_t minSample;
  int16_t maxSample;
  int32_t absPeak;
  int64_t sumAbs;
  int64_t sumSquares;
};

#ifndef HOMECUE_BOOT_SPEAKER_TEST_MODE
#define HOMECUE_BOOT_SPEAKER_TEST_MODE SPEAKER_TEST_ALL
#endif

static const char* speakerTestModeName(uint8_t mode) {
  switch (mode) {
    case SPEAKER_TEST_LEFT: return "left";
    case SPEAKER_TEST_RIGHT: return "right";
    case SPEAKER_TEST_SWEEP: return "sweep";
    case SPEAKER_TEST_ALL: return "all";
    case SPEAKER_TEST_BOTH:
    default: return "both";
  }
}

static const char* speakerTestWriteModeName(uint8_t writeMode) {
  switch (writeMode) {
    case SPEAKER_TEST_WRITE_SAMPLE: return "sample";
    case SPEAKER_TEST_WRITE_SAMPLE32: return "sample32";
    case SPEAKER_TEST_WRITE_SAMPLE32_BCLK: return "sample32bclk";
    case SPEAKER_TEST_WRITE_BUFFER:
    default: return "buffer";
  }
}

static bool pollAndPlayDueReminder();
static void scheduleNextReminderPoll(uint32_t delayMs);
static void pollDueReminderIfIdle();

static const char* httpErrorHint(int code) {
  switch (code) {
    case -11: return "read timeout (LLM slow? increase timeout or use mock)";
    case -1:  return "connection refused (is uvicorn running on PC_HOST:PC_PORT?)";
    default:  return "see ESP32 HTTPClient error codes";
  }
}

// Fixed command words -> preset prompts (ASR "Plan 1": reliable, no cloud ASR).
// The vendor MultiNet command id maps to one of these entries.
static const CommandWord COMMAND_WORDS[] = {
  {"I'm home",      "I just got home and feel tired. Make the room comfortable and set a relaxing movie mode."},
  {"Sleep mode",    "I'm going to sleep. Dim everything to a calm night setting and set a gentle wake reminder."},
  {"Movie time",    "Start movie night: warm dim light, cinema projector mode, and quiet ambient audio."},
};
static const int COMMAND_COUNT = sizeof(COMMAND_WORDS) / sizeof(COMMAND_WORDS[0]);
static const int VOICE_CHAT_COMMAND_ID = COMMAND_COUNT;

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------

// Actions proposed by the last /plan call, awaiting human confirmation.
// Stored as a JSON document so we can forward the confirmed subset verbatim.
static JsonDocument g_proposedActions;  // holds an array of {device,command,value}
static bool g_hasProposal = false;
static int g_commandIndex = 0;
static String g_voiceChatSessionId;
static uint8_t* g_replyAudioData = nullptr;
static size_t g_replyAudioSize = 0;
static size_t g_replyAudioCapacity = 0;
static bool g_replyAudioActive = false;
static bool g_replyAudioChunked = false;
static bool g_replyAudioStreamOnly = false;
static int g_replyAudioChunks = 0;
static bool g_replyAudioStreaming = false;
static bool g_replyAudioStreamReady = false;
static bool g_replyAudioStreamFailed = false;
static uint16_t g_replyAudioStreamChannels = 0;
static bool g_replyAudioStreamBclk32 = false;
static uint8_t g_replyAudioStreamPendingByte = 0;
static bool g_replyAudioStreamHasPendingByte = false;
static uint32_t g_nextReminderPollAt = 0;
static uint8_t g_replyAudioHeader[512];
static size_t g_replyAudioHeaderSize = 0;
static size_t g_replyAudioStreamDataWritten = 0;
static size_t g_replyAudioStreamDataExpected = 0;
static size_t g_replyAudioStreamTotalDataWritten = 0;
static int g_replyAudioStreamSegments = 0;

// ---------------------------------------------------------------------------
// TCA9555 minimal driver (button route - no vendor library)
// ---------------------------------------------------------------------------
static bool tca9555Write(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(TCA9555_ADDR);
  Wire.write(reg);
  Wire.write(val);
  return Wire.endTransmission() == 0;
}

static bool tca9555Read(uint8_t reg, uint8_t& val) {
  Wire.beginTransmission(TCA9555_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(TCA9555_ADDR, (uint8_t)1) != 1) return false;
  val = Wire.read();
  return true;
}

static bool tca9555SetPinOutput(uint8_t pin, bool high) {
  uint8_t outputReg = (pin < 8) ? 0x02 : 0x03;
  uint8_t configReg = (pin < 8) ? 0x06 : 0x07;
  uint8_t bit = pin % 8;
  uint8_t output = 0;
  uint8_t config = 0;
  if (!tca9555Read(outputReg, output) || !tca9555Read(configReg, config)) return false;

  if (high) {
    output |= (1 << bit);
  } else {
    output &= ~(1 << bit);
  }
  config &= ~(1 << bit);

  return tca9555Write(outputReg, output) && tca9555Write(configReg, config);
}

static bool initTca9555() {
  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(100000);
  delay(10);
  // Config port 0 + 1 as inputs (1 = input on TCA9555)
  if (!tca9555Write(0x06, 0xFF) || !tca9555Write(0x07, 0xFF)) return false;
  uint8_t probe = 0;
  return tca9555Read(0x01, probe);
}

static bool enableSpeakerPowerAmp() {
#if !HOMECUE_SPEAKER_OUTPUT_ENABLED
  Serial.println("[speaker] PA enable blocked - speaker output disabled");
  g_speakerPaEnabled = false;
  return false;
#endif
  if (!g_tca9555Ok) {
    Serial.println("[speaker] PA enable unavailable - TCA9555 not ready");
    return false;
  }

  if (!tca9555SetPinOutput(SPEAKER_PA_CTRL_PIN, true)) {
    Serial.printf("[speaker] PA enable FAILED pin=%u\n", SPEAKER_PA_CTRL_PIN);
    g_speakerPaEnabled = false;
    return false;
  }

  g_speakerPaEnabled = true;
  Serial.printf("[speaker] PA enabled pin=%u\n", SPEAKER_PA_CTRL_PIN);
  delay(50);
  logSpeakerPowerAmpState("[speaker]");
  return true;
}

static bool disableSpeakerPowerAmp() {
  if (!g_tca9555Ok) {
    g_speakerPaEnabled = false;
    return false;
  }

  if (!tca9555SetPinOutput(SPEAKER_PA_CTRL_PIN, false)) {
    Serial.printf("[speaker] PA disable FAILED pin=%u\n", SPEAKER_PA_CTRL_PIN);
    return false;
  }

  g_speakerPaEnabled = false;
  Serial.printf("[speaker] PA disabled pin=%u\n", SPEAKER_PA_CTRL_PIN);
  delay(20);
  logSpeakerPowerAmpState("[speaker]");
  return true;
}

static bool readSpeakerPowerAmpState(bool& enabled) {
  if (!g_tca9555Ok) {
    return false;
  }

  uint8_t reg = (SPEAKER_PA_CTRL_PIN < 8) ? 0x00 : 0x01;
  uint8_t bit = SPEAKER_PA_CTRL_PIN % 8;
  uint8_t val = 0;
  if (!tca9555Read(reg, val)) {
    return false;
  }

  enabled = (val & (1 << bit)) != 0;
  return true;
}

static bool readSpeakerPowerAmpRegisters(uint8_t& inputReg, uint8_t& outputReg, uint8_t& configReg) {
  if (!g_tca9555Ok) {
    return false;
  }

  inputReg = 0;
  outputReg = 0;
  configReg = 0;
  const uint8_t port = (SPEAKER_PA_CTRL_PIN < 8) ? 0 : 1;
  return tca9555Read(0x00 + port, inputReg) &&
         tca9555Read(0x02 + port, outputReg) &&
         tca9555Read(0x06 + port, configReg);
}

static void logSpeakerPowerAmpState(const char* prefix) {
  bool enabled = false;
  uint8_t inputReg = 0;
  uint8_t outputReg = 0;
  uint8_t configReg = 0;
  if (readSpeakerPowerAmpState(enabled) &&
      readSpeakerPowerAmpRegisters(inputReg, outputReg, configReg)) {
    Serial.printf("%s PA readback pin=%u state=%s input=0x%02x output=0x%02x config=0x%02x\n",
                  prefix,
                  SPEAKER_PA_CTRL_PIN,
                  enabled ? "high" : "low",
                  inputReg,
                  outputReg,
                  configReg);
  } else {
    Serial.printf("%s PA readback unavailable\n", prefix);
  }
}

// Read expander pin (0-15). Returns true when pin is LOW (key pressed).
static bool tca9555PinPressed(uint8_t pin) {
  uint8_t reg = (pin < 8) ? 0x00 : 0x01;
  uint8_t bit = pin % 8;
  uint8_t val = 0;
  if (!tca9555Read(reg, val)) return false;
  return (val & (1 << bit)) == 0;
}

static bool bootPressed() {
  return digitalRead(PIN_BOOT) == LOW;
}

// ---------------------------------------------------------------------------
// RGB ring (TODO[VENDOR]: wire to the example's TCA9555 / WS2812 driver)
// ---------------------------------------------------------------------------
static void setRgbState(RgbState state) {
  // TODO[VENDOR]: drive the 7x RGB ring through the TCA9555 expander using the
  // Waveshare example's LED helper. Until that is wired, mirror state to Serial
  // so the end-to-end flow is still demonstrable.
  switch (state) {
    case RGB_LISTENING: Serial.println("[RGB] LISTENING (blue)"); break;
    case RGB_THINKING:  Serial.println("[RGB] THINKING (breathing)"); break;
    case RGB_READY:     Serial.println("[RGB] READY (green)"); break;
    case RGB_REJECTED:  Serial.println("[RGB] REJECTED (red)"); break;
    case RGB_OFFLINE:   Serial.println("[RGB] OFFLINE (yellow)"); break;
    case RGB_IDLE:
    default:            Serial.println("[RGB] IDLE (dim)"); break;
  }
}

// ---------------------------------------------------------------------------
// User keys - button route: TCA9555 KEY1/2/3 + BOOT fallback
// ---------------------------------------------------------------------------
static UserKey readUserKey() {
  uint32_t now = millis();
  if (now - g_lastKeyMs < KEY_COOLDOWN_MS) return KEY_NONE;

  bool plan = false;
  bool confirm = false;
  bool reject = false;

  if (g_tca9555Ok) {
    plan = tca9555PinPressed(KEY_PIN_PLAN);
    confirm = tca9555PinPressed(KEY_PIN_CONFIRM);
    reject = tca9555PinPressed(KEY_PIN_REJECT);
  } else if (bootPressed()) {
    // BOOT-only fallback: plan when idle, confirm when a proposal is pending.
    if (g_hasProposal) confirm = true;
    else plan = true;
  }

  if (reject) {
    g_lastKeyMs = now;
    return KEY_REJECT;
  }
  if (confirm) {
    g_lastKeyMs = now;
    return KEY_CONFIRM;
  }
  if (plan) {
    g_lastKeyMs = now;
    return KEY_NEXT;  // triggers /plan (cycle command word)
  }
  return KEY_NONE;
}

// ---------------------------------------------------------------------------
// ESP-SR voice command route (optional, compile-gated by ENABLE_ESP_SR)
// ---------------------------------------------------------------------------
// Offline WakeNet wake word + MultiNet fixed command words (no cloud ASR). A
// recognized command id maps 1:1 onto a COMMAND_WORDS index; loop() then drives
// the SAME requestPlan(... execute=false ...) path used by keys/serial. Voice
// therefore only PROPOSES - a physical CONFIRM key (or serial homecue:execute)
// is still required to run anything, so the human-in-the-loop guarantee holds.
#if ENABLE_ESP_SR
// MultiNet command phrases -> COMMAND_WORDS index (the leading id IS the index).
// The third column is the MultiNet (english) phoneme/G2P string generated with
// the esp-sr gen_sr_commands.py tool for the installed arduino-esp32 core. The
// wake word (e.g. "hi esp") comes from the WakeNet model chosen in the ESP-SR
// build / sdkconfig, NOT from this table.
static const sr_cmd_t SR_COMMANDS[] = {
  {0, "I am home",  "i aM hbM"},         // -> COMMAND_WORDS[0] "I'm home"
  {1, "sleep mode", "SLmP MbD"},         // -> COMMAND_WORDS[1] "Sleep mode"
  {2, "movie time", "MoVm TiM"},         // -> COMMAND_WORDS[2] "Movie time"
  {VOICE_CHAT_COMMAND_ID, "chat mode", "paT MbD"},  // -> record + POST /voice-chat
};
static const int SR_COMMAND_COUNT = sizeof(SR_COMMANDS) / sizeof(SR_COMMANDS[0]);

// Set by the ESP-SR task callback, drained by espSrPollCommand() in loop().
static volatile int g_srPendingCommand = -1;
static volatile bool g_srPendingVoiceChat = false;
static volatile bool g_srCommandWindowActive = false;
static I2SClass g_srI2s;
static es7210_dev_handle_t g_es7210 = nullptr;
static es8311_handle_t g_es8311 = nullptr;
static bool g_srI2sReady = false;
static bool g_es7210Ready = false;
static bool g_es8311Ready = false;
static bool g_espSrStarted = false;

static void dumpSpeakerCodecRegisters(const char* prefix) {
  Serial.printf("%s ES8311 register dump begin\n", prefix);
  if (!g_es8311Ready || g_es8311 == nullptr) {
    Serial.printf("%s ES8311 register dump unavailable - codec not ready\n", prefix);
    return;
  }

  int volume = -1;
  esp_err_t err = es8311_voice_volume_get(g_es8311, &volume);
  if (err == ESP_OK) {
    Serial.printf("%s ES8311 volume_get=%d\n", prefix, volume);
  } else {
    Serial.printf("%s ES8311 volume_get FAILED: 0x%x\n", prefix, err);
  }
  logSpeakerPowerAmpState(prefix);
  es8311_register_dump(g_es8311);
  Serial.println();
  Serial.printf("%s ES8311 register dump end\n", prefix);
}

static void muteSpeakerCodecAndPowerAmp(const char* prefix) {
  if (g_es8311Ready && g_es8311 != nullptr) {
    esp_err_t err = es8311_voice_mute(g_es8311, true);
    if (err != ESP_OK) {
      Serial.printf("%s ES8311 mute after playback FAILED: 0x%x\n", prefix, err);
    } else {
      Serial.printf("%s ES8311 muted after playback\n", prefix);
    }
  }
  disableSpeakerPowerAmp();
}

static void onSrEvent(sr_event_t event, int command_id, int phrase_id) {
  (void)phrase_id;
  switch (event) {
    case SR_EVENT_WAKEWORD:
      Serial.println("[esp-sr] wake word detected - preparing voice chat");
      break;
    case SR_EVENT_WAKEWORD_CHANNEL:
#if HOMECUE_WAKE_AUTO_VOICE_CHAT
      Serial.printf("[esp-sr] wake word channel %d verified - auto voice chat\n", command_id);
      g_srPendingVoiceChat = true;
      g_srCommandWindowActive = false;
      ESP_SR.setMode(SR_MODE_WAKEWORD);
#else
      Serial.printf("[esp-sr] wake word channel %d verified - listening for command\n", command_id);
      g_srCommandWindowActive = true;
      ESP_SR.setMode(SR_MODE_COMMAND);
#endif
      break;
    case SR_EVENT_COMMAND:
      if (command_id >= 0 && command_id < COMMAND_COUNT) {
        // Propose only: just stage the index, loop() calls /plan (execute=false).
        g_srPendingCommand = command_id;
      } else if (command_id == VOICE_CHAT_COMMAND_ID) {
        // Chat mode is conversational only: enter a short voice-chat session.
        // It does not execute device actions.
        g_srPendingVoiceChat = true;
      } else {
        Serial.printf("[esp-sr] unmapped command id %d - ignored\n", command_id);
      }
      g_srCommandWindowActive = false;
      ESP_SR.setMode(SR_MODE_WAKEWORD);
      break;
    case SR_EVENT_TIMEOUT:
      Serial.println("[esp-sr] command window timeout - say wake word again");
      g_srCommandWindowActive = false;
      ESP_SR.setMode(SR_MODE_WAKEWORD);
      break;
    default:
      break;
  }
}

static bool initEs7210Codec() {
  if (g_es7210 == nullptr) {
    const es7210_i2c_config_t i2c_config = {
      .i2c_port = I2C_NUM_0,
      .i2c_addr = ES7210_ADDRRES_00,
    };

    esp_err_t err = es7210_new_codec(&i2c_config, &g_es7210);
    if (err != ESP_OK) {
      Serial.printf("[esp-sr] ES7210 create FAILED: 0x%x\n", err);
      return false;
    }
  }

  const es7210_codec_config_t codec_config = {
    .sample_rate_hz = 16000,
    .mclk_ratio = 256,
    .i2s_format = ES7210_I2S_FMT_I2S,
    .bit_width = ES7210_I2S_BITS_16B,
    .mic_bias = ES7210_MIC_BIAS_2V87,
    .mic_gain = ES7210_MIC_GAIN_30DB,
    .flags = {
      .tdm_enable = 0,
    },
  };

  esp_err_t err = es7210_config_codec(g_es7210, &codec_config);
  if (err != ESP_OK) {
    Serial.printf("[esp-sr] ES7210 config FAILED: 0x%x\n", err);
    return false;
  }

  err = es7210_config_volume(g_es7210, 12);
  if (err != ESP_OK) {
    Serial.printf("[esp-sr] ES7210 volume FAILED: 0x%x\n", err);
    return false;
  }

  g_es7210Ready = true;
  Serial.println("[esp-sr] ES7210 codec ready");
  return true;
}

static bool initEs8311Codec() {
  if (g_es8311 == nullptr) {
    g_es8311 = es8311_create(I2C_NUM_0, ES8311_ADDRESS_0);
    if (g_es8311 == nullptr) {
      Serial.println("[speaker] ES8311 create FAILED");
      return false;
    }
  }

  const es8311_clock_config_t clock_config = {
    .mclk_inverted = false,
    .sclk_inverted = false,
    .mclk_from_mclk_pin = true,
    .mclk_frequency = VOICE_CHAT_SAMPLE_RATE * 256,
    .sample_frequency = VOICE_CHAT_SAMPLE_RATE,
  };

  esp_err_t err = es8311_init(g_es8311, &clock_config, ES8311_RESOLUTION_16, ES8311_RESOLUTION_16);
  if (err != ESP_OK) {
    Serial.printf("[speaker] ES8311 init FAILED: 0x%x\n", err);
    return false;
  }

  int volumeSet = 0;
  err = es8311_voice_volume_set(g_es8311, SPEAKER_VOLUME, &volumeSet);
  if (err != ESP_OK) {
    Serial.printf("[speaker] ES8311 volume FAILED: 0x%x\n", err);
    return false;
  }

  err = es8311_microphone_config(g_es8311, false);
  if (err != ESP_OK) {
    Serial.printf("[speaker] ES8311 analog mic path config FAILED: 0x%x\n", err);
    return false;
  }

  err = es8311_voice_mute(g_es8311, true);
  if (err != ESP_OK) {
    Serial.printf("[speaker] ES8311 mute FAILED: 0x%x\n", err);
    return false;
  }

  g_es8311Ready = true;
  Serial.printf("[speaker] ES8311 codec ready volume=%d vendor_mic_config=analog muted=1\n", volumeSet);
  return true;
}

static bool configureSpeakerCodecForPlayback(uint32_t sampleRate, uint8_t volume, const char* prefix) {
#if !HOMECUE_SPEAKER_OUTPUT_ENABLED
  Serial.printf("%s disabled - speaker output disabled\n", prefix);
  return false;
#endif
  if (!g_es8311Ready) {
    Serial.printf("%s ES8311 unavailable\n", prefix);
    return false;
  }

  if (sampleRate < 8000 || sampleRate > 96000) {
    Serial.printf("%s sample rate unsupported: %lu\n", prefix, (unsigned long)sampleRate);
    return false;
  }

  uint32_t mclkFrequency = sampleRate * 256;
  esp_err_t err = es8311_sample_frequency_config(g_es8311, (int)mclkFrequency, (int)sampleRate);
  if (err != ESP_OK) {
    Serial.printf("%s ES8311 sample-rate config FAILED rate=%lu mclk=%lu err=0x%x\n",
                  prefix,
                  (unsigned long)sampleRate,
                  (unsigned long)mclkFrequency,
                  err);
    return false;
  }

  int volumeSet = 0;
  err = es8311_voice_volume_set(g_es8311, volume, &volumeSet);
  if (err != ESP_OK) {
    Serial.printf("%s ES8311 volume FAILED: 0x%x\n", prefix, err);
    return false;
  }

  err = es8311_voice_mute(g_es8311, false);
  if (err != ESP_OK) {
    Serial.printf("%s ES8311 unmute FAILED: 0x%x\n", prefix, err);
    return false;
  }

  Serial.printf("%s ES8311 playback ready rate=%lu mclk=%lu volume=%d\n",
                prefix,
                (unsigned long)sampleRate,
                (unsigned long)mclkFrequency,
                volumeSet);
  return true;
}

static bool configureSpeakerCodecForPlayback32(uint32_t sampleRate,
                                               uint8_t volume,
                                               const char* prefix,
                                               bool clockFromBclk = false) {
#if !HOMECUE_SPEAKER_OUTPUT_ENABLED
  Serial.printf("%s disabled - speaker output disabled\n", prefix);
  return false;
#endif
  if (!g_es8311Ready || g_es8311 == nullptr) {
    Serial.printf("%s ES8311 unavailable\n", prefix);
    return false;
  }
  if (sampleRate < 8000 || sampleRate > 96000) {
    Serial.printf("%s sample rate unsupported: %lu\n", prefix, (unsigned long)sampleRate);
    return false;
  }

  const es8311_clock_config_t clockConfig = {
    .mclk_inverted = false,
    .sclk_inverted = false,
    .mclk_from_mclk_pin = !clockFromBclk,
    .mclk_frequency = (int)sampleRate * 256,
    .sample_frequency = (int)sampleRate,
  };

  esp_err_t err = es8311_init(g_es8311, &clockConfig, ES8311_RESOLUTION_32, ES8311_RESOLUTION_32);
  if (err != ESP_OK) {
    Serial.printf("%s ES8311 32-bit init FAILED: 0x%x\n", prefix, err);
    return false;
  }

  int volumeSet = 0;
  err = es8311_voice_volume_set(g_es8311, volume, &volumeSet);
  if (err != ESP_OK) {
    Serial.printf("%s ES8311 32-bit volume FAILED: 0x%x\n", prefix, err);
    return false;
  }

  err = es8311_microphone_config(g_es8311, false);
  if (err != ESP_OK) {
    Serial.printf("%s ES8311 32-bit mic path config FAILED: 0x%x\n", prefix, err);
    return false;
  }

  err = es8311_voice_mute(g_es8311, false);
  if (err != ESP_OK) {
    Serial.printf("%s ES8311 32-bit unmute FAILED: 0x%x\n", prefix, err);
    return false;
  }

  uint32_t codecClock = clockFromBclk ? sampleRate * 32 * 2 : (uint32_t)clockConfig.mclk_frequency;
  Serial.printf("%s ES8311 playback ready rate=%lu mclk=%lu volume=%d bits=32 clock=%s\n",
                prefix,
                (unsigned long)sampleRate,
                (unsigned long)codecClock,
                volumeSet,
                clockFromBclk ? "bclk" : "mclk");
  return true;
}

static int16_t attenuateSpeakerSample(int16_t sample) {
  return (int16_t)(sample >> SPEAKER_PLAYBACK_SHIFT);
}

static void printStartupMicCaptureStats(uint16_t windowMs = 250) {
  if (!g_srI2sReady) {
    Serial.println("[esp-sr] mic diag unavailable - I2S is not ready");
    return;
  }

  static int16_t samples[512];
  uint32_t deadline = millis() + windowMs;
  uint32_t totalBytes = 0;
  uint32_t sampleCount = 0;
  uint32_t zeroCount = 0;
  uint32_t clippedCount = 0;
  int16_t minSample = 32767;
  int16_t maxSample = -32768;
  int32_t absPeak = 0;
  int64_t sumAbs = 0;
  int64_t sumSquares = 0;
  uint32_t evenCount = 0;
  uint32_t oddCount = 0;
  uint32_t evenZeros = 0;
  uint32_t oddZeros = 0;
  int64_t evenSumSquares = 0;
  int64_t oddSumSquares = 0;

  g_srI2s.setTimeout(120);
  while (millis() < deadline) {
    size_t bytes = g_srI2s.readBytes((char*)samples, sizeof(samples));
    if (bytes == 0) {
      continue;
    }

    totalBytes += bytes;
    size_t count = bytes / sizeof(int16_t);
    for (size_t i = 0; i < count; i++) {
      int16_t sample = samples[i];
      int32_t absValue = sample < 0 ? -(int32_t)sample : sample;
      if (sample < minSample) minSample = sample;
      if (sample > maxSample) maxSample = sample;
      if (absValue > absPeak) absPeak = absValue;
      if (sample == 0) zeroCount++;
      if (sample == 32767 || sample == -32768) clippedCount++;
      sumAbs += absValue;
      sumSquares += (int64_t)sample * (int64_t)sample;
      if ((i % 2) == 0) {
        evenCount++;
        if (sample == 0) evenZeros++;
        evenSumSquares += (int64_t)sample * (int64_t)sample;
      } else {
        oddCount++;
        if (sample == 0) oddZeros++;
        oddSumSquares += (int64_t)sample * (int64_t)sample;
      }
    }
    sampleCount += count;
  }

  if (sampleCount == 0) {
    Serial.println("[esp-sr] mic diag startup bytes=0 samples=0 read=timeout");
    return;
  }

  double meanAbs = (double)sumAbs / (double)sampleCount;
  double rms = sqrt((double)sumSquares / (double)sampleCount);
  double evenRms = evenCount > 0 ? sqrt((double)evenSumSquares / (double)evenCount) : 0.0;
  double oddRms = oddCount > 0 ? sqrt((double)oddSumSquares / (double)oddCount) : 0.0;
  Serial.printf(
      "[esp-sr] mic diag %s bytes=%lu samples=%lu min=%d max=%d abs_peak=%ld mean_abs=%.1f rms=%.1f zeros=%lu clipped=%lu even_rms=%.1f even_zeros=%lu odd_rms=%.1f odd_zeros=%lu\n",
      "startup",
      (unsigned long)totalBytes,
      (unsigned long)sampleCount,
      minSample,
      maxSample,
      (long)absPeak,
      meanAbs,
      rms,
      (unsigned long)zeroCount,
      (unsigned long)clippedCount,
      evenRms,
      (unsigned long)evenZeros,
      oddRms,
      (unsigned long)oddZeros);
}

static bool espSrModelsReady() {
  const esp_partition_t* model_partition = esp_partition_find_first(
      ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_SPIFFS, "model");
  if (model_partition == nullptr) {
    Serial.println("[esp-sr] model partition missing - flash srmodels.bin");
    return false;
  }

  srmodel_list_t* models = esp_srmodel_init("model");
  if (models == nullptr) {
    Serial.println("[esp-sr] model list unavailable - flash srmodels.bin");
    return false;
  }

  Serial.printf("[esp-sr] model check wake=%s command=english\n", HOMECUE_SR_WAKE_KEYWORD);
  char* wake_model = esp_srmodel_filter(models, ESP_WN_PREFIX, HOMECUE_SR_WAKE_KEYWORD);
  char* command_model = esp_srmodel_filter(models, ESP_MN_PREFIX, ESP_MN_ENGLISH);
  bool ready = wake_model != nullptr && command_model != nullptr;
  if (!ready) {
    Serial.println("[esp-sr] required WakeNet/MultiNet models missing - flash srmodels.bin");
  }
  esp_srmodel_deinit(models);
  return ready;
}

static bool initSharedAudioI2S() {
  if (g_srI2sReady) {
    return true;
  }
  // Shared audio I2S pins from the vendor BSP: MCLK=12, BCLK=13, WS=14,
  // mic DIN=15, speaker DOUT=16.
  g_srI2s.setPins(/*BCLK*/ 13, /*WS*/ 14, /*DOUT*/ 16, /*DIN*/ 15, /*MCLK*/ 12);
  if (!g_srI2s.begin(I2S_MODE_STD, 16000, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO)) {
    Serial.printf("[audio] I2S init FAILED last_error=%d - keeping keys/serial fallback\n", g_srI2s.lastError());
    return false;
  }
  g_srI2sReady = true;
  Serial.println("[audio] I2S ready rate=16000 channels=2 mclk=12 bclk=13 ws=14 din=15 dout=16");
  return true;
}

// Bring up the shared audio bus and codecs before checking speech models. The
// speaker-test path should remain usable even when WakeNet/MultiNet models are
// missing or ESP-SR itself cannot start.
static bool espSrBegin() {
  if (!initSharedAudioI2S()) {
    return false;
  }

  if (!initEs7210Codec()) {
    Serial.println("[esp-sr] mic codec unavailable - voice route disabled");
  }

  if (!initEs8311Codec()) {
    Serial.println("[speaker] board speaker route unavailable - voice chat upload still works");
  }

  if (g_es7210Ready) {
    printStartupMicCaptureStats();
  }

  if (!g_es7210Ready) {
    return false;
  }

  if (!espSrModelsReady()) {
    Serial.println("[esp-sr] models unavailable - audio serial routes stay enabled");
    return false;
  }

  ESP_SR.onEvent(onSrEvent);
  if (!ESP_SR.begin(g_srI2s, SR_COMMANDS, SR_COMMAND_COUNT, SR_CHANNELS_STEREO, SR_MODE_WAKEWORD)) {
    Serial.println("[esp-sr] model init FAILED - keeping keys/serial fallback");
    return false;
  }
  g_espSrStarted = true;
  Serial.println("[esp-sr] ready - say the wake word, then a command word");
  return true;
}

static bool pauseEspSrIfRunning() {
  if (!g_espSrStarted) {
    return false;
  }
  return ESP_SR.pause();
}

static void resumeEspSrIfPaused(bool wasPaused) {
  if (wasPaused && g_espSrStarted) {
    ESP_SR.resume();
  }
}

// Drain the latest staged command-word index (set by the ESP-SR task callback).
// Returns a COMMAND_WORDS index, or -1 when nothing was recognized this tick.
static int espSrPollCommand() {
  int cmd = g_srPendingCommand;
  if (cmd >= 0) {
    g_srPendingCommand = -1;
    return cmd;
  }
  return -1;
}

static bool espSrPollVoiceChat() {
  bool pending = g_srPendingVoiceChat;
  if (pending) {
    g_srPendingVoiceChat = false;
  }
  return pending;
}

static void espSrForceCommandWindow() {
  if (!g_espSrStarted) {
    Serial.println("[esp-sr] command window unavailable - ESP-SR not started");
    return;
  }
  Serial.println("[esp-sr] forced command window - say a command word");
  g_srCommandWindowActive = true;
  ESP_SR.setMode(SR_MODE_COMMAND);
}
#endif  // ENABLE_ESP_SR

// ---------------------------------------------------------------------------
// Voice trigger (TODO[VENDOR]: ESP-SR WakeNet wake + MultiNet command id)
// ---------------------------------------------------------------------------
// Return a command-word index [0..COMMAND_COUNT-1] when the recognizer fires,
// or -1 when nothing was recognized this loop iteration. This is the single
// boundary between the (optional) voice route and the always-on button route.
static int pollVoiceCommand() {
#if ENABLE_ESP_SR
  // Voice enabled: ESP-SR runs in its own task and posts results via onSrEvent();
  // espSrPollCommand() returns the staged index. Still propose-only (see loop()).
  return espSrPollCommand();
#else
  // Button-route MVP: voice disabled, zero ESP-SR dependency. Enable the ESP-SR
  // route by building with -DENABLE_ESP_SR=1 (see README 4C), or wire the
  // Waveshare vendor WakeNet/MultiNet recognizer here and map its command id to
  // a COMMAND_WORDS index. TODO[VENDOR]
  return -1;
#endif
}

static bool pollVoiceChatRequest() {
#if ENABLE_ESP_SR
  return espSrPollVoiceChat();
#else
  return false;
#endif
}

// ---------------------------------------------------------------------------
// WiFi + health probe
// ---------------------------------------------------------------------------
static bool connectWifi(uint32_t timeoutMs = 15000) {
  if (WiFi.status() == WL_CONNECTED) return true;

  Serial.printf("[WiFi] connecting to %s ...\n", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && (millis() - start) < timeoutMs) {
    delay(300);
    Serial.print('.');
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("[WiFi] connected, IP = ");
    Serial.println(WiFi.localIP());
    return true;
  }

  Serial.println("[WiFi] connection FAILED");
  setRgbState(RGB_OFFLINE);
  return false;
}

static bool checkHealth() {
  if (!connectWifi()) return false;

  HTTPClient http;
  http.begin(healthUrl());
  http.setTimeout(HTTP_TIMEOUT_HEALTH_MS);
  int code = http.GET();
  if (code != 200) {
    Serial.printf("[/health] HTTP %d - %s\n", code, httpErrorHint(code));
  } else {
    Serial.printf("[/health] HTTP %d\n", code);
  }
  http.end();
  return code == 200;
}

#if ENABLE_ESP_SR
static void writeLe16(uint8_t* dst, uint16_t value) {
  dst[0] = (uint8_t)(value & 0xFF);
  dst[1] = (uint8_t)((value >> 8) & 0xFF);
}

static void writeLe32(uint8_t* dst, uint32_t value) {
  dst[0] = (uint8_t)(value & 0xFF);
  dst[1] = (uint8_t)((value >> 8) & 0xFF);
  dst[2] = (uint8_t)((value >> 16) & 0xFF);
  dst[3] = (uint8_t)((value >> 24) & 0xFF);
}

static uint16_t readLe16(const uint8_t* src) {
  return (uint16_t)src[0] | ((uint16_t)src[1] << 8);
}

static uint32_t readLe32(const uint8_t* src) {
  return (uint32_t)src[0] | ((uint32_t)src[1] << 8) | ((uint32_t)src[2] << 16) | ((uint32_t)src[3] << 24);
}

static void writeVoiceChatWavHeader(uint8_t* wav, size_t dataBytes) {
  const uint16_t blockAlign = VOICE_CHAT_CHANNELS * (VOICE_CHAT_BITS_PER_SAMPLE / 8);
  const uint32_t byteRate = VOICE_CHAT_SAMPLE_RATE * blockAlign;

  memcpy(wav + 0, "RIFF", 4);
  writeLe32(wav + 4, (uint32_t)(36 + dataBytes));
  memcpy(wav + 8, "WAVE", 4);
  memcpy(wav + 12, "fmt ", 4);
  writeLe32(wav + 16, 16);
  writeLe16(wav + 20, 1);  // PCM
  writeLe16(wav + 22, VOICE_CHAT_CHANNELS);
  writeLe32(wav + 24, VOICE_CHAT_SAMPLE_RATE);
  writeLe32(wav + 28, byteRate);
  writeLe16(wav + 32, blockAlign);
  writeLe16(wav + 34, VOICE_CHAT_BITS_PER_SAMPLE);
  memcpy(wav + 36, "data", 4);
  writeLe32(wav + 40, (uint32_t)dataBytes);
}

static uint8_t* allocateVoiceChatBuffer(size_t bytes) {
  uint8_t* buffer = (uint8_t*)heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (buffer != nullptr) {
    Serial.printf("[/voice-chat] allocated %u bytes in PSRAM\n", (unsigned)bytes);
    return buffer;
  }

  buffer = (uint8_t*)malloc(bytes);
  if (buffer != nullptr) {
    Serial.printf("[/voice-chat] allocated %u bytes in internal heap\n", (unsigned)bytes);
  }
  return buffer;
}

static String absoluteApiUrl(const char* path) {
  String raw = String(path ? path : "");
  if (raw.startsWith("http://") || raw.startsWith("https://")) {
    return raw;
  }
  if (!raw.startsWith("/")) {
    raw = "/" + raw;
  }
  return String("http://") + PC_HOST + ":" + PC_PORT + raw;
}

static bool downloadReplyAudio(const char* path, uint8_t** outBytes, size_t* outSize) {
  *outBytes = nullptr;
  *outSize = 0;
  if (path == nullptr || path[0] == '\0') {
    Serial.println("[speaker] reply audio URL missing");
    return false;
  }

  HTTPClient http;
  String url = absoluteApiUrl(path);
  http.begin(url);
  addVoiceChatAuthHeader(http);
  http.setTimeout(HTTP_TIMEOUT_AUDIO_MS);
  int code = http.GET();
  if (code != 200) {
    Serial.printf("[speaker] audio HTTP %d - %s\n", code, httpErrorHint(code));
    http.end();
    return false;
  }

  int contentLength = http.getSize();
  if (contentLength <= 0 || contentLength > (int)VOICE_CHAT_MAX_REPLY_WAV_BYTES) {
    Serial.printf("[speaker] audio size invalid: %d\n", contentLength);
    http.end();
    return false;
  }

  uint8_t* audio = allocateVoiceChatBuffer((size_t)contentLength);
  if (audio == nullptr) {
    Serial.printf("[speaker] failed to allocate %d audio bytes\n", contentLength);
    http.end();
    return false;
  }

  NetworkClient* stream = http.getStreamPtr();
  size_t total = 0;
  uint32_t deadline = millis() + HTTP_TIMEOUT_AUDIO_MS;
  while (total < (size_t)contentLength && millis() < deadline) {
    int available = stream->available();
    if (available <= 0) {
      delay(10);
      continue;
    }
    size_t remaining = (size_t)contentLength - total;
    size_t toRead = available > (int)remaining ? remaining : (size_t)available;
    int got = stream->readBytes((char*)(audio + total), toRead);
    if (got <= 0) {
      break;
    }
    total += (size_t)got;
  }
  http.end();

  if (total != (size_t)contentLength) {
    Serial.printf("[speaker] short audio download: got=%u expected=%d\n",
                  (unsigned)total, contentLength);
    free(audio);
    return false;
  }

  *outBytes = audio;
  *outSize = total;
  Serial.printf("[speaker] downloaded %u audio bytes\n", (unsigned)total);
  return true;
}

static bool configureVoiceChatMicRx();

static bool playReplyAudio(uint8_t* wav, size_t wavSize) {
#if !HOMECUE_SPEAKER_OUTPUT_ENABLED
  Serial.println("[speaker] playback skipped - speaker output disabled");
  return false;
#endif
  bool playbackStarted = false;
  bool ok = false;
  if (!g_srI2sReady || !g_es8311Ready) {
    Serial.println("[speaker] unavailable - I2S or ES8311 not ready");
    return false;
  }
  if (wav == nullptr || wavSize <= VOICE_CHAT_WAV_HEADER_BYTES) {
    Serial.println("[speaker] empty WAV");
    return false;
  }

  if (memcmp(wav, "RIFF", 4) != 0 || memcmp(wav + 8, "WAVE", 4) != 0) {
    Serial.println("[speaker] invalid WAV header");
    return false;
  }

  uint16_t audioFormat = 0;
  uint16_t channels = 0;
  uint32_t sampleRate = 0;
  uint16_t bitsPerSample = 0;
  uint8_t* data = nullptr;
  size_t dataSize = 0;
  size_t expectedWrite = 0;
  size_t written = 0;
  int16_t stereo[SPEAKER_TEST_FRAMES_PER_CHUNK * 2];
  bool bclk32Playback = HOMECUE_SPEAKER_REPLY_AUDIO_BCLK32 == 1;

  size_t pos = 12;
  while (pos + 8 <= wavSize) {
    uint8_t* chunk = wav + pos;
    uint32_t chunkSize = readLe32(chunk + 4);
    size_t chunkData = pos + 8;
    if (chunkData + chunkSize > wavSize) {
      Serial.println("[speaker] WAV chunk exceeds buffer");
      return false;
    }

    if (memcmp(chunk, "fmt ", 4) == 0 && chunkSize >= 16) {
      audioFormat = readLe16(wav + chunkData + 0);
      channels = readLe16(wav + chunkData + 2);
      sampleRate = readLe32(wav + chunkData + 4);
      bitsPerSample = readLe16(wav + chunkData + 14);
    } else if (memcmp(chunk, "data", 4) == 0) {
      data = wav + chunkData;
      dataSize = chunkSize;
      break;
    }

    pos = chunkData + chunkSize + (chunkSize & 1);
  }

  if (audioFormat != 1 || data == nullptr || dataSize == 0 || bitsPerSample != 16 ||
      (channels != 1 && channels != 2)) {
    Serial.printf("[speaker] unsupported WAV fmt=%u channels=%u rate=%lu bits=%u data=%u\n",
                  audioFormat, channels, (unsigned long)sampleRate, bitsPerSample, (unsigned)dataSize);
    return false;
  }

  if (!g_speakerPaEnabled && !enableSpeakerPowerAmp()) {
    Serial.println("[speaker] PA enable failed before playback");
    return false;
  }
  logSpeakerPowerAmpState("[speaker]");

  if (bclk32Playback) {
    if (!configureSpeakerCodecForPlayback32(sampleRate, SPEAKER_VOLUME, "[speaker]", true)) {
      return false;
    }
  } else {
    if (!configureSpeakerCodecForPlayback(sampleRate, SPEAKER_VOLUME, "[speaker]")) {
      return false;
    }
  }
  playbackStarted = true;

  Serial.printf("[speaker] playing %u WAV bytes rate=%lu channels=%u data=%u path=%s\n",
                (unsigned)wavSize,
                (unsigned long)sampleRate,
                channels,
                (unsigned)dataSize,
                bclk32Playback ? "bclk32" : "i2s16");
  setRgbState(RGB_READY);
  g_srI2s.setTimeout(2000);
  i2s_data_bit_width_t bitWidth = bclk32Playback ? I2S_DATA_BIT_WIDTH_32BIT : I2S_DATA_BIT_WIDTH_16BIT;
  if (!g_srI2s.configureTX(sampleRate, bitWidth, I2S_SLOT_MODE_STEREO, I2S_STD_SLOT_BOTH)) {
    Serial.printf("[speaker] configureTX FAILED last_error=%d\n", g_srI2s.lastError());
    goto cleanup;
  }

  if (channels == 1) {
    expectedWrite = dataSize * 2 * (bclk32Playback ? sizeof(int32_t) : sizeof(int16_t)) / sizeof(int16_t);
    size_t posBytes = 0;
    while (posBytes < dataSize) {
      size_t remainingSamples = (dataSize - posBytes) / sizeof(int16_t);
      size_t framesThisChunk = remainingSamples < SPEAKER_TEST_FRAMES_PER_CHUNK ?
        remainingSamples : SPEAKER_TEST_FRAMES_PER_CHUNK;
      int16_t* mono = (int16_t*)(data + posBytes);
      for (size_t i = 0; i < framesThisChunk; i++) {
        int16_t sample = attenuateSpeakerSample(mono[i]);
        stereo[i * 2] = sample;
        stereo[i * 2 + 1] = sample;
      }
      size_t bytesToWrite = framesThisChunk * 2 * (bclk32Playback ? sizeof(int32_t) : sizeof(int16_t));
      size_t chunkWritten = bclk32Playback ?
        writeSpeakerPcm16StereoAs32(stereo, framesThisChunk * 2) :
        g_srI2s.write((uint8_t*)stereo, bytesToWrite);
      written += chunkWritten;
      if (chunkWritten != bytesToWrite) {
        Serial.printf("[speaker] short playback write: wrote=%u expected=%u last_error=%d\n",
                      (unsigned)chunkWritten, (unsigned)bytesToWrite, g_srI2s.lastError());
        goto cleanup;
      }
      posBytes += framesThisChunk * sizeof(int16_t);
    }
  } else {
    expectedWrite = dataSize * (bclk32Playback ? sizeof(int32_t) : sizeof(int16_t)) / sizeof(int16_t);
    size_t posBytes = 0;
    while (posBytes < dataSize) {
      size_t remainingFrames = (dataSize - posBytes) / (2 * sizeof(int16_t));
      size_t framesThisChunk = remainingFrames < SPEAKER_TEST_FRAMES_PER_CHUNK ?
        remainingFrames : SPEAKER_TEST_FRAMES_PER_CHUNK;
      const int16_t* source = (const int16_t*)(data + posBytes);
      for (size_t i = 0; i < framesThisChunk * 2; i++) {
        stereo[i] = attenuateSpeakerSample(source[i]);
      }
      size_t bytesToWrite = framesThisChunk * 2 * (bclk32Playback ? sizeof(int32_t) : sizeof(int16_t));
      size_t chunkWritten = bclk32Playback ?
        writeSpeakerPcm16StereoAs32(stereo, framesThisChunk * 2) :
        g_srI2s.write((uint8_t*)stereo, bytesToWrite);
      written += chunkWritten;
      if (chunkWritten != bytesToWrite) {
        Serial.printf("[speaker] short playback write: wrote=%u expected=%u last_error=%d\n",
                      (unsigned)chunkWritten, (unsigned)bytesToWrite, g_srI2s.lastError());
        goto cleanup;
      }
      posBytes += framesThisChunk * 2 * sizeof(int16_t);
    }
  }

  if (written != expectedWrite) {
    Serial.printf("[speaker] playback byte mismatch: wrote=%u expected=%u\n",
                  (unsigned)written, (unsigned)expectedWrite);
    goto cleanup;
  }
  Serial.println("[speaker] playback done");
  ok = true;

cleanup:
  if (playbackStarted) {
    muteSpeakerCodecAndPowerAmp("[speaker]");
    if (bclk32Playback && initEs8311Codec()) {
      Serial.println("[speaker] ES8311 restored to 16-bit playback config");
    }
    configureVoiceChatMicRx();
  }
  return ok;
}

static bool configureVoiceChatMicRx() {
  if (!g_srI2sReady) {
    return false;
  }
  if (!g_srI2s.configureRX(VOICE_CHAT_SAMPLE_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO)) {
    Serial.printf("[esp-sr] mic RX restore failed last_error=%d\n", g_srI2s.lastError());
    return false;
  }
  return true;
}

static void resetMicAcousticStats(MicAcousticStats& stats) {
  stats.totalBytes = 0;
  stats.sampleCount = 0;
  stats.zeroCount = 0;
  stats.clippedCount = 0;
  stats.minSample = 32767;
  stats.maxSample = -32768;
  stats.absPeak = 0;
  stats.sumAbs = 0;
  stats.sumSquares = 0;
}

static void updateMicAcousticStats(MicAcousticStats& stats, const int16_t* samples, size_t sampleCount) {
  for (size_t i = 0; i < sampleCount; i++) {
    int16_t sample = samples[i];
    int32_t absValue = sample < 0 ? -(int32_t)sample : sample;
    if (sample < stats.minSample) stats.minSample = sample;
    if (sample > stats.maxSample) stats.maxSample = sample;
    if (absValue > stats.absPeak) stats.absPeak = absValue;
    if (sample == 0) stats.zeroCount++;
    if (sample == 32767 || sample == -32768) stats.clippedCount++;
    stats.sumAbs += absValue;
    stats.sumSquares += (int64_t)sample * (int64_t)sample;
  }
  stats.sampleCount += sampleCount;
  stats.totalBytes += sampleCount * sizeof(int16_t);
}

static size_t readMicAcousticChunk(MicAcousticStats& stats) {
  static int16_t samples[256];
  size_t bytes = g_srI2s.readBytes((char*)samples, sizeof(samples));
  if (bytes == 0) {
    return 0;
  }
  updateMicAcousticStats(stats, samples, bytes / sizeof(int16_t));
  return bytes;
}

static void logMicAcousticStats(const char* prefix, const MicAcousticStats& stats) {
  if (stats.sampleCount == 0) {
    Serial.printf("%s mic bytes=0 samples=0 read=timeout\n", prefix);
    return;
  }
  double meanAbs = (double)stats.sumAbs / (double)stats.sampleCount;
  double rms = sqrt((double)stats.sumSquares / (double)stats.sampleCount);
  Serial.printf("%s mic bytes=%lu samples=%lu min=%d max=%d abs_peak=%ld mean_abs=%.1f rms=%.1f zeros=%lu clipped=%lu\n",
                prefix,
                (unsigned long)stats.totalBytes,
                (unsigned long)stats.sampleCount,
                stats.minSample,
                stats.maxSample,
                (long)stats.absPeak,
                meanAbs,
                rms,
                (unsigned long)stats.zeroCount,
                (unsigned long)stats.clippedCount);
}

static bool captureMicAcousticWindow(uint16_t windowMs, MicAcousticStats& stats) {
  if (!configureVoiceChatMicRx()) {
    return false;
  }
  resetMicAcousticStats(stats);
  g_srI2s.setTimeout(80);
  uint32_t deadline = millis() + windowMs;
  while (millis() < deadline) {
    readMicAcousticChunk(stats);
  }
  return stats.sampleCount > 0;
}

static bool playVoiceChatWakeAck() {
#if !HOMECUE_SPEAKER_OUTPUT_ENABLED
  Serial.println("[voice] wake ack skipped - speaker output disabled");
  return false;
#else
  if (!connectWifi()) return false;

  Serial.printf("[voice] wake ack: %s\n", VOICE_CHAT_WAKE_ACK_TEXT);
  setRgbState(RGB_THINKING);
  HTTPClient http;
  String url = voiceChatTtsUrl(VOICE_CHAT_WAKE_ACK_TEXT);
  http.begin(url);
  addVoiceChatAuthHeader(http);
  http.setTimeout(HTTP_TIMEOUT_AUDIO_MS);
  int code = http.GET();
  if (code != 200) {
    Serial.printf("[/voice-chat/tts] HTTP %d - %s\n", code, httpErrorHint(code));
    String body = http.getString();
    if (body.length() > 0) {
      Serial.print("[/voice-chat/tts] error body: ");
      Serial.println(body);
    }
    http.end();
    return false;
  }

  String body = http.getString();
  http.end();
  JsonDocument resp;
  DeserializationError err = deserializeJson(resp, body);
  if (err) {
    Serial.printf("[/voice-chat/tts] JSON parse error: %s\n", err.c_str());
    return false;
  }

  const char* replyAudioStatus = resp["reply_audio"]["status"] | "unknown";
  const char* replyAudioUrl = resp["reply_audio"]["url"] | "";
  const char* replyAudioProvider = resp["reply_audio"]["provider"] | "";
  const char* replyAudioModel = resp["reply_audio"]["model"] | "";
  const char* replyAudioVoice = resp["reply_audio"]["voice"] | "";
  Serial.printf("[/voice-chat/tts] reply_audio: %s %s\n", replyAudioStatus, replyAudioUrl);
  if (replyAudioProvider[0] != '\0') {
    Serial.printf("[/voice-chat/tts] tts provider=%s model=%s voice=%s\n",
                  replyAudioProvider, replyAudioModel, replyAudioVoice);
  }
  if (strcmp(replyAudioStatus, "ready") != 0 || replyAudioUrl[0] == '\0') {
    Serial.println("[/voice-chat/tts] no playable wake ack audio");
    return false;
  }

  bool played = false;
  bool srPaused = pauseEspSrIfRunning();
  uint8_t* audio = nullptr;
  size_t audioSize = 0;
  if (downloadReplyAudio(replyAudioUrl, &audio, &audioSize)) {
    played = playReplyAudio(audio, audioSize);
    free(audio);
  }
  resumeEspSrIfPaused(srPaused);
  setRgbState(played ? RGB_READY : RGB_IDLE);
  return played;
#endif
}

static bool writeSpeakerToneSample(int16_t left, int16_t right) {
  return g_srI2s.write((uint8_t*)&right, sizeof(right)) == sizeof(right) &&
         g_srI2s.write((uint8_t*)&left, sizeof(left)) == sizeof(left);
}

static bool writeSpeakerToneSample32(int16_t left, int16_t right) {
  int32_t right32 = ((int32_t)right) << 16;
  int32_t left32 = ((int32_t)left) << 16;
  return g_srI2s.write((uint8_t*)&right32, sizeof(right32)) == sizeof(right32) &&
         g_srI2s.write((uint8_t*)&left32, sizeof(left32)) == sizeof(left32);
}

static size_t writeSpeakerPcm16StereoAs32(const int16_t* samples, size_t stereoSampleCount) {
  int32_t expanded[SPEAKER_TEST_FRAMES_PER_CHUNK * 2];
  size_t sampleCursor = 0;
  size_t written = 0;

  while (sampleCursor < stereoSampleCount) {
    size_t samplesThisChunk = stereoSampleCount - sampleCursor;
    if (samplesThisChunk > SPEAKER_TEST_FRAMES_PER_CHUNK * 2) {
      samplesThisChunk = SPEAKER_TEST_FRAMES_PER_CHUNK * 2;
    }
    for (size_t i = 0; i < samplesThisChunk; i++) {
      expanded[i] = ((int32_t)samples[sampleCursor + i]) << 16;
    }
    size_t bytesToWrite = samplesThisChunk * sizeof(int32_t);
    size_t chunkWritten = g_srI2s.write((uint8_t*)expanded, bytesToWrite);
    written += chunkWritten;
    if (chunkWritten != bytesToWrite) {
      break;
    }
    sampleCursor += samplesThisChunk;
  }

  return written;
}

static bool playSpeakerTestToneSegment(uint8_t seconds,
                                       uint8_t mode,
                                       uint8_t requestedVolume,
                                       int16_t requestedAmplitude,
                                       uint8_t writeMode,
                                       bool dumpRegisters,
                                       bool micProbe) {
#if !HOMECUE_SPEAKER_OUTPUT_ENABLED
  Serial.println("[speaker-test] disabled - speaker output disabled");
  return false;
#endif
  seconds = constrain(seconds, SPEAKER_TEST_MIN_SECONDS, SPEAKER_TEST_MAX_SECONDS);
  if (!g_srI2sReady || !g_es8311Ready) {
    Serial.println("[speaker-test] unavailable - I2S or ES8311 not ready");
    return false;
  }

  if (!g_speakerPaEnabled && !enableSpeakerPowerAmp()) {
    Serial.println("[speaker-test] PA enable failed");
    return false;
  }
  logSpeakerPowerAmpState("[speaker-test]");

  uint8_t volume = constrain(requestedVolume, (uint8_t)0, SPEAKER_TEST_MAX_VOLUME);
  int16_t amplitude = constrain(requestedAmplitude, (int16_t)0, SPEAKER_TEST_MAX_AMPLITUDE);
  MicAcousticStats micBaseline;
  MicAcousticStats micActive;
  resetMicAcousticStats(micBaseline);
  resetMicAcousticStats(micActive);
  if (micProbe) {
    Serial.println("[speaker-test] mic probe baseline capture");
    captureMicAcousticWindow(300, micBaseline);
    logMicAcousticStats("[speaker-test] mic baseline", micBaseline);
  }
  if (dumpRegisters) {
    dumpSpeakerCodecRegisters("[speaker-test] before-playback");
  }

  bool sampleWrite = writeMode == SPEAKER_TEST_WRITE_SAMPLE;
  bool sample32Write = writeMode == SPEAKER_TEST_WRITE_SAMPLE32 ||
                       writeMode == SPEAKER_TEST_WRITE_SAMPLE32_BCLK;
  bool sample32Bclk = writeMode == SPEAKER_TEST_WRITE_SAMPLE32_BCLK;
  if (sample32Write) {
    if (!configureSpeakerCodecForPlayback32(VOICE_CHAT_SAMPLE_RATE,
                                            volume,
                                            "[speaker-test]",
                                            sample32Bclk)) {
      muteSpeakerCodecAndPowerAmp("[speaker-test]");
      return false;
    }
  } else if (!configureSpeakerCodecForPlayback(VOICE_CHAT_SAMPLE_RATE, volume, "[speaker-test]")) {
    muteSpeakerCodecAndPowerAmp("[speaker-test]");
    return false;
  }
  if (dumpRegisters) {
    dumpSpeakerCodecRegisters("[speaker-test] active");
  }

  bool srPaused = pauseEspSrIfRunning();
  delay(150);
  setRgbState(RGB_READY);
  g_srI2s.setTimeout(2000);
  i2s_data_bit_width_t bitWidth = sample32Write ? I2S_DATA_BIT_WIDTH_32BIT : I2S_DATA_BIT_WIDTH_16BIT;
  if (!g_srI2s.configureTX(VOICE_CHAT_SAMPLE_RATE, bitWidth, I2S_SLOT_MODE_STEREO, I2S_STD_SLOT_BOTH)) {
    Serial.printf("[speaker-test] configureTX FAILED last_error=%d\n", g_srI2s.lastError());
    muteSpeakerCodecAndPowerAmp("[speaker-test]");
    configureVoiceChatMicRx();
    resumeEspSrIfPaused(srPaused);
    return false;
  }
  if (micProbe) {
    configureVoiceChatMicRx();
    g_srI2s.setTimeout(30);
  }

  const uint32_t totalFrames = (uint32_t)VOICE_CHAT_SAMPLE_RATE * seconds;
  uint32_t halfPeriodFrames = VOICE_CHAT_SAMPLE_RATE / (SPEAKER_TEST_FREQUENCY_HZ * 2);
  if (halfPeriodFrames == 0) {
    halfPeriodFrames = 1;
  }
  uint32_t frameIndex = 0;
  size_t totalWritten = 0;
  int16_t samples[SPEAKER_TEST_FRAMES_PER_CHUNK * 2];

  Serial.printf("[speaker-test] start rate=%lu channels=2 freq=%uHz volume=%d amplitude=%d duration=%us pa=%s mode=%s write=%s\n",
                (unsigned long)VOICE_CHAT_SAMPLE_RATE,
                SPEAKER_TEST_FREQUENCY_HZ,
                volume,
                amplitude,
                seconds,
                g_speakerPaEnabled ? "on" : "off",
                speakerTestModeName(mode),
                speakerTestWriteModeName(writeMode));

  while (frameIndex < totalFrames) {
    size_t remainingFrames = totalFrames - frameIndex;
    size_t framesThisChunk = remainingFrames < SPEAKER_TEST_FRAMES_PER_CHUNK ?
      remainingFrames : SPEAKER_TEST_FRAMES_PER_CHUNK;
    for (size_t i = 0; i < framesThisChunk; i++) {
      uint32_t currentHalfPeriodFrames = halfPeriodFrames;
      if (mode == SPEAKER_TEST_SWEEP) {
        uint32_t numerator = (frameIndex + i) * (uint32_t)(SPEAKER_TEST_SWEEP_END_HZ - SPEAKER_TEST_SWEEP_START_HZ);
        uint16_t frequency = SPEAKER_TEST_SWEEP_START_HZ + (numerator / totalFrames);
        currentHalfPeriodFrames = VOICE_CHAT_SAMPLE_RATE / ((uint32_t)frequency * 2);
        if (currentHalfPeriodFrames == 0) {
          currentHalfPeriodFrames = 1;
        }
      }
      uint32_t phaseFrame = (frameIndex + i) / currentHalfPeriodFrames;
      int16_t sample = (phaseFrame % 2 == 0) ? amplitude : -amplitude;
      samples[i * 2] = (mode == SPEAKER_TEST_RIGHT) ? 0 : sample;
      samples[i * 2 + 1] = (mode == SPEAKER_TEST_LEFT) ? 0 : sample;
    }

    size_t bytesToWrite = framesThisChunk * 2 * (sample32Write ? sizeof(int32_t) : sizeof(int16_t));
    size_t written = 0;
    if (sampleWrite || sample32Write) {
      bool writeOk = true;
      for (size_t i = 0; i < framesThisChunk; i++) {
        bool sampleOk = sample32Write ?
          writeSpeakerToneSample32(samples[i * 2], samples[i * 2 + 1]) :
          writeSpeakerToneSample(samples[i * 2], samples[i * 2 + 1]);
        if (!sampleOk) {
          writeOk = false;
          break;
        }
        written += 2 * (sample32Write ? sizeof(int32_t) : sizeof(int16_t));
      }
      if (!writeOk) {
        Serial.printf("[speaker-test] sample write failed last_error=%d total=%u\n",
                      g_srI2s.lastError(),
                      (unsigned)(totalWritten + written));
      }
    } else {
      written = g_srI2s.write((uint8_t*)samples, bytesToWrite);
    }
    totalWritten += written;
    if (written != bytesToWrite) {
      Serial.printf("[speaker-test] short write: wrote=%u expected=%u last_error=%d total=%u\n",
                    (unsigned)written, (unsigned)bytesToWrite, g_srI2s.lastError(),
                    (unsigned)totalWritten);
      muteSpeakerCodecAndPowerAmp("[speaker-test]");
      configureVoiceChatMicRx();
      resumeEspSrIfPaused(srPaused);
      return false;
    }
    frameIndex += framesThisChunk;
    if (micProbe) {
      readMicAcousticChunk(micActive);
    }
  }

  Serial.printf("[speaker-test] done wrote=%u expected=%u\n",
                (unsigned)totalWritten,
                (unsigned)(totalFrames * 2 * (sample32Write ? sizeof(int32_t) : sizeof(int16_t))));
  if (micProbe) {
    logMicAcousticStats("[speaker-test] mic active", micActive);
  }
  if (dumpRegisters) {
    dumpSpeakerCodecRegisters("[speaker-test] before-mute");
  }
  muteSpeakerCodecAndPowerAmp("[speaker-test]");
  if (dumpRegisters) {
    dumpSpeakerCodecRegisters("[speaker-test] after-mute");
  }
  if (sample32Write && initEs8311Codec()) {
    Serial.println("[speaker-test] ES8311 restored to 16-bit playback config");
  }
  if (configureVoiceChatMicRx()) {
    Serial.println("[speaker-test] mic RX restored");
  }
  resumeEspSrIfPaused(srPaused);
  return true;
}

static bool playSpeakerTestTone(uint8_t seconds,
                                uint8_t mode,
                                uint8_t volume = SPEAKER_TEST_VOLUME,
                                int16_t amplitude = SPEAKER_TEST_AMPLITUDE,
                                uint8_t writeMode = SPEAKER_TEST_WRITE_BUFFER,
                                bool dumpRegisters = false,
                                bool micProbe = false) {
  if (mode != SPEAKER_TEST_ALL) {
    return playSpeakerTestToneSegment(seconds, mode, volume, amplitude, writeMode, dumpRegisters, micProbe);
  }

  uint8_t segmentSeconds = seconds / 4;
  if (segmentSeconds < 1) {
    segmentSeconds = 1;
  }
  bool ok = true;
  ok = playSpeakerTestToneSegment(segmentSeconds, SPEAKER_TEST_BOTH, volume, amplitude, writeMode, dumpRegisters, micProbe) && ok;
  delay(250);
  ok = playSpeakerTestToneSegment(segmentSeconds, SPEAKER_TEST_LEFT, volume, amplitude, writeMode, dumpRegisters, micProbe) && ok;
  delay(250);
  ok = playSpeakerTestToneSegment(segmentSeconds, SPEAKER_TEST_RIGHT, volume, amplitude, writeMode, dumpRegisters, micProbe) && ok;
  delay(250);
  ok = playSpeakerTestToneSegment(segmentSeconds, SPEAKER_TEST_SWEEP, volume, amplitude, writeMode, dumpRegisters, micProbe) && ok;
  return ok;
}

static void resetReplyAudioStream() {
  g_replyAudioStreaming = false;
  g_replyAudioStreamReady = false;
  g_replyAudioStreamFailed = false;
  g_replyAudioStreamChannels = 0;
  g_replyAudioStreamBclk32 = false;
  g_replyAudioStreamPendingByte = 0;
  g_replyAudioStreamHasPendingByte = false;
  g_replyAudioHeaderSize = 0;
  g_replyAudioStreamDataWritten = 0;
  g_replyAudioStreamDataExpected = 0;
  g_replyAudioStreamTotalDataWritten = 0;
  g_replyAudioStreamSegments = 0;
}

static void resetReplyAudioStreamSegment() {
  g_replyAudioStreamReady = false;
  g_replyAudioStreamChannels = 0;
  g_replyAudioHeaderSize = 0;
  g_replyAudioStreamDataWritten = 0;
  g_replyAudioStreamDataExpected = 0;
}

static void finishReplyAudioStreamSegment() {
  if (!g_replyAudioStreamReady || g_replyAudioStreamDataExpected == 0 ||
      g_replyAudioStreamDataWritten < g_replyAudioStreamDataExpected) {
    return;
  }
  g_replyAudioStreamSegments += 1;
  Serial.printf("[speaker] stream segment done data=%u/%u segments=%d\n",
                (unsigned)g_replyAudioStreamDataWritten,
                (unsigned)g_replyAudioStreamDataExpected,
                g_replyAudioStreamSegments);
  resetReplyAudioStreamSegment();
}

static bool parseReplyAudioStreamHeader(size_t& dataOffset) {
  dataOffset = 0;
  if (g_replyAudioHeaderSize < 44) {
    return false;
  }
  if (memcmp(g_replyAudioHeader, "RIFF", 4) != 0 || memcmp(g_replyAudioHeader + 8, "WAVE", 4) != 0) {
    Serial.println("[speaker] stream invalid WAV header");
    g_replyAudioStreamFailed = true;
    return false;
  }

  uint16_t audioFormat = 0;
  uint16_t channels = 0;
  uint32_t sampleRate = 0;
  uint16_t bitsPerSample = 0;
  size_t pos = 12;
  while (pos + 8 <= g_replyAudioHeaderSize) {
    uint8_t* chunk = g_replyAudioHeader + pos;
    uint32_t chunkSize = readLe32(chunk + 4);
    size_t chunkData = pos + 8;
    if (memcmp(chunk, "fmt ", 4) == 0 && chunkSize >= 16) {
      if (chunkData + 16 > g_replyAudioHeaderSize) {
        return false;
      }
      audioFormat = readLe16(g_replyAudioHeader + chunkData + 0);
      channels = readLe16(g_replyAudioHeader + chunkData + 2);
      sampleRate = readLe32(g_replyAudioHeader + chunkData + 4);
      bitsPerSample = readLe16(g_replyAudioHeader + chunkData + 14);
    } else if (memcmp(chunk, "data", 4) == 0) {
      if (audioFormat != 1 || bitsPerSample != 16 || (channels != 1 && channels != 2) || chunkSize == 0) {
        Serial.printf("[speaker] stream unsupported WAV fmt=%u channels=%u rate=%lu bits=%u data=%lu\n",
                      audioFormat,
                      channels,
                      (unsigned long)sampleRate,
                      bitsPerSample,
                      (unsigned long)chunkSize);
        g_replyAudioStreamFailed = true;
        return false;
      }
      dataOffset = chunkData;
      g_replyAudioStreamDataExpected = chunkSize;
      g_replyAudioStreamChannels = channels;
      g_replyAudioStreamBclk32 = HOMECUE_SPEAKER_REPLY_AUDIO_BCLK32 == 1;
      g_replyAudioStreamPendingByte = 0;
      g_replyAudioStreamHasPendingByte = false;
      if (!g_speakerPaEnabled && !enableSpeakerPowerAmp()) {
        Serial.println("[speaker] stream PA enable failed");
        g_replyAudioStreamFailed = true;
        return false;
      }
      logSpeakerPowerAmpState("[speaker]");
      if (g_replyAudioStreamBclk32) {
        if (!configureSpeakerCodecForPlayback32(sampleRate, SPEAKER_VOLUME, "[speaker] stream", true)) {
          g_replyAudioStreamFailed = true;
          return false;
        }
      } else {
        if (!configureSpeakerCodecForPlayback(sampleRate, SPEAKER_VOLUME, "[speaker] stream")) {
          g_replyAudioStreamFailed = true;
          return false;
        }
      }
      g_srI2s.setTimeout(2000);
      i2s_data_bit_width_t bitWidth = g_replyAudioStreamBclk32 ?
        I2S_DATA_BIT_WIDTH_32BIT : I2S_DATA_BIT_WIDTH_16BIT;
      if (!g_srI2s.configureTX(sampleRate, bitWidth, I2S_SLOT_MODE_STEREO, I2S_STD_SLOT_BOTH)) {
        Serial.printf("[speaker] stream configureTX FAILED last_error=%d\n", g_srI2s.lastError());
        g_replyAudioStreamFailed = true;
        return false;
      }
      setRgbState(RGB_READY);
      Serial.printf("[speaker] stream start rate=%lu channels=%u data=%lu pa=%s path=%s\n",
                    (unsigned long)sampleRate,
                    channels,
                    (unsigned long)chunkSize,
                    g_speakerPaEnabled ? "on" : "off",
                    g_replyAudioStreamBclk32 ? "bclk32" : "i2s16");
      g_replyAudioStreamReady = true;
      return true;
    }

    size_t nextPos = chunkData + chunkSize + (chunkSize & 1);
    if (nextPos <= pos || nextPos > sizeof(g_replyAudioHeader)) {
      Serial.println("[speaker] stream WAV header too large");
      g_replyAudioStreamFailed = true;
      return false;
    }
    if (nextPos > g_replyAudioHeaderSize) {
      return false;
    }
    pos = nextPos;
  }
  return false;
}

static bool writeReplyAudioStreamData(const uint8_t* data, size_t size) {
  if (size == 0) {
    return true;
  }
  if (!g_replyAudioStreamReady || data == nullptr) {
    return false;
  }

  if (g_replyAudioStreamChannels == 1) {
    int16_t stereo[SPEAKER_TEST_FRAMES_PER_CHUNK * 2];
    size_t pos = 0;

    if (g_replyAudioStreamHasPendingByte) {
      if (g_replyAudioStreamDataExpected > 0 && g_replyAudioStreamDataWritten >= g_replyAudioStreamDataExpected) {
        return true;
      }
      uint8_t sampleBytes[2] = {g_replyAudioStreamPendingByte, data[0]};
      int16_t sample = attenuateSpeakerSample((int16_t)readLe16(sampleBytes));
      stereo[0] = sample;
      stereo[1] = sample;
      size_t bytesToWrite = 2 * (g_replyAudioStreamBclk32 ? sizeof(int32_t) : sizeof(int16_t));
      size_t written = g_replyAudioStreamBclk32 ?
        writeSpeakerPcm16StereoAs32(stereo, 2) :
        g_srI2s.write((uint8_t*)stereo, bytesToWrite);
      if (written != bytesToWrite) {
        Serial.printf("[speaker] short stream write: wrote=%u expected=%u last_error=%d\n",
                      (unsigned)written,
                      (unsigned)bytesToWrite,
                      g_srI2s.lastError());
        g_replyAudioStreamFailed = true;
        return false;
      }
      g_replyAudioStreamDataWritten += 2;
      g_replyAudioStreamTotalDataWritten += written;
      g_replyAudioStreamHasPendingByte = false;
      pos = 1;
    }

    while (pos + 1 < size) {
      size_t allowedSourceBytes = size - pos;
      if (g_replyAudioStreamDataExpected > 0) {
        size_t left = g_replyAudioStreamDataExpected - g_replyAudioStreamDataWritten;
        if (allowedSourceBytes > left) {
          allowedSourceBytes = left;
        }
      }
      if (allowedSourceBytes < sizeof(int16_t)) {
        break;
      }
      size_t remainingSamples = allowedSourceBytes / sizeof(int16_t);
      size_t framesThisChunk = remainingSamples < SPEAKER_TEST_FRAMES_PER_CHUNK ?
        remainingSamples : SPEAKER_TEST_FRAMES_PER_CHUNK;
      const int16_t* mono = (const int16_t*)(data + pos);
      for (size_t i = 0; i < framesThisChunk; i++) {
        int16_t sample = attenuateSpeakerSample(mono[i]);
        stereo[i * 2] = sample;
        stereo[i * 2 + 1] = sample;
      }
      size_t bytesToWrite = framesThisChunk * 2 * (g_replyAudioStreamBclk32 ? sizeof(int32_t) : sizeof(int16_t));
      size_t written = g_replyAudioStreamBclk32 ?
        writeSpeakerPcm16StereoAs32(stereo, framesThisChunk * 2) :
        g_srI2s.write((uint8_t*)stereo, bytesToWrite);
      if (written != bytesToWrite) {
        Serial.printf("[speaker] short stream write: wrote=%u expected=%u last_error=%d\n",
                      (unsigned)written,
                      (unsigned)bytesToWrite,
                      g_srI2s.lastError());
        g_replyAudioStreamFailed = true;
        return false;
      }
      size_t sourceBytes = framesThisChunk * sizeof(int16_t);
      g_replyAudioStreamDataWritten += sourceBytes;
      g_replyAudioStreamTotalDataWritten += written;
      pos += sourceBytes;
      finishReplyAudioStreamSegment();
      if (!g_replyAudioStreamReady && pos < size) {
        Serial.printf("[speaker] stream ignored trailing bytes=%u\n", (unsigned)(size - pos));
        break;
      }
    }

    if (g_replyAudioStreamReady) {
      finishReplyAudioStreamSegment();
    }
    if (g_replyAudioStreamReady && pos < size &&
        (g_replyAudioStreamDataExpected == 0 || g_replyAudioStreamDataWritten < g_replyAudioStreamDataExpected)) {
      g_replyAudioStreamPendingByte = data[pos];
      g_replyAudioStreamHasPendingByte = true;
    }
    return true;
  }

  size_t remaining = size;
  const uint8_t* cursor = data;
  while (remaining > 0) {
    size_t allowed = remaining;
    if (g_replyAudioStreamDataExpected > 0) {
      size_t left = g_replyAudioStreamDataExpected - g_replyAudioStreamDataWritten;
      if (allowed > left) {
        allowed = left;
      }
    }
    if (allowed == 0) {
      break;
    }
    int16_t attenuated[SPEAKER_TEST_FRAMES_PER_CHUNK * 2];
    size_t framesThisChunk = allowed / (2 * sizeof(int16_t));
    if (framesThisChunk > SPEAKER_TEST_FRAMES_PER_CHUNK) {
      framesThisChunk = SPEAKER_TEST_FRAMES_PER_CHUNK;
    }
    if (framesThisChunk == 0) {
      break;
    }
    size_t sourceBytes = framesThisChunk * 2 * sizeof(int16_t);
    size_t bytesToWrite = framesThisChunk * 2 * (g_replyAudioStreamBclk32 ? sizeof(int32_t) : sizeof(int16_t));
    const int16_t* source = (const int16_t*)cursor;
    for (size_t i = 0; i < framesThisChunk * 2; i++) {
      attenuated[i] = attenuateSpeakerSample(source[i]);
    }
    size_t written = g_replyAudioStreamBclk32 ?
      writeSpeakerPcm16StereoAs32(attenuated, framesThisChunk * 2) :
      g_srI2s.write((uint8_t*)attenuated, bytesToWrite);
    if (written != bytesToWrite) {
      Serial.printf("[speaker] short stream write: wrote=%u expected=%u last_error=%d\n",
                    (unsigned)written,
                    (unsigned)bytesToWrite,
                    g_srI2s.lastError());
      g_replyAudioStreamFailed = true;
      return false;
    }
    g_replyAudioStreamDataWritten += sourceBytes;
    g_replyAudioStreamTotalDataWritten += written;
    cursor += sourceBytes;
    remaining -= sourceBytes;
    finishReplyAudioStreamSegment();
    if (!g_replyAudioStreamReady && remaining > 0) {
      Serial.printf("[speaker] stream ignored trailing bytes=%u\n", (unsigned)remaining);
      break;
    }
  }
  return true;
}

static bool feedReplyAudioStream(uint8_t* chunk, size_t chunkSize) {
  if (!g_replyAudioStreaming || g_replyAudioStreamFailed || chunk == nullptr || chunkSize == 0) {
    return false;
  }

  if (!g_replyAudioStreamReady) {
    size_t copyBytes = chunkSize;
    if (g_replyAudioHeaderSize + copyBytes > sizeof(g_replyAudioHeader)) {
      copyBytes = sizeof(g_replyAudioHeader) - g_replyAudioHeaderSize;
    }
    memcpy(g_replyAudioHeader + g_replyAudioHeaderSize, chunk, copyBytes);
    g_replyAudioHeaderSize += copyBytes;

    size_t dataOffset = 0;
    if (!parseReplyAudioStreamHeader(dataOffset)) {
      return !g_replyAudioStreamFailed;
    }
    if (g_replyAudioHeaderSize > dataOffset) {
      if (!writeReplyAudioStreamData(g_replyAudioHeader + dataOffset, g_replyAudioHeaderSize - dataOffset)) {
        return false;
      }
    }
    if (chunkSize > copyBytes) {
      return writeReplyAudioStreamData(chunk + copyBytes, chunkSize - copyBytes);
    }
    return true;
  }

  return writeReplyAudioStreamData(chunk, chunkSize);
}

static void cleanupReplyAudioStreamPlayback() {
  bool restoreBclk32 = g_replyAudioStreamBclk32;
  muteSpeakerCodecAndPowerAmp("[speaker] stream");
  if (restoreBclk32 && initEs8311Codec()) {
    Serial.println("[speaker] stream ES8311 restored to 16-bit playback config");
  }
  configureVoiceChatMicRx();
}

static bool finishReplyAudioStream() {
  if (!g_replyAudioStreaming || g_replyAudioStreamFailed) {
    cleanupReplyAudioStreamPlayback();
    resetReplyAudioStream();
    return false;
  }
  if (g_replyAudioStreamReady) {
    if (g_replyAudioStreamDataExpected > 0 && g_replyAudioStreamDataWritten < g_replyAudioStreamDataExpected) {
      Serial.printf("[speaker] stream incomplete data=%u/%u\n",
                    (unsigned)g_replyAudioStreamDataWritten,
                    (unsigned)g_replyAudioStreamDataExpected);
      cleanupReplyAudioStreamPlayback();
      resetReplyAudioStream();
      return false;
    }
    finishReplyAudioStreamSegment();
  }
  bool ok = g_replyAudioStreamSegments > 0 || g_replyAudioStreamTotalDataWritten > 0;
  Serial.printf("[speaker] stream playback done data=%u/%u segments=%d\n",
                (unsigned)g_replyAudioStreamTotalDataWritten,
                0,
                g_replyAudioStreamSegments);
  if (ok) {
    Serial.println("[speaker] playback done");
  }
  cleanupReplyAudioStreamPlayback();
  resetReplyAudioStream();
  return ok;
}

static void drainVoiceChatMic(uint16_t windowMs) {
  uint8_t scratch[1024];
  uint32_t until = millis() + windowMs;
  configureVoiceChatMicRx();
  g_srI2s.setTimeout(50);
  while (millis() < until) {
    g_srI2s.readBytes((char*)scratch, sizeof(scratch));
  }
}

static uint8_t* recordVoiceChatWav(uint8_t seconds, size_t* outSize) {
  *outSize = 0;
  if (!g_srI2sReady) {
    Serial.println("[/voice-chat] mic unavailable - I2S is not ready");
    return nullptr;
  }
  if (!configureVoiceChatMicRx()) {
    return nullptr;
  }

  seconds = constrain(seconds, VOICE_CHAT_MIN_SECONDS, VOICE_CHAT_MAX_SECONDS);
  const size_t bytesPerSecond =
      (VOICE_CHAT_SAMPLE_RATE * VOICE_CHAT_CHANNELS * VOICE_CHAT_BITS_PER_SAMPLE) / 8;
  const size_t expectedDataBytes = bytesPerSecond * seconds;
  const size_t totalBytes = VOICE_CHAT_WAV_HEADER_BYTES + expectedDataBytes;
  uint8_t* wav = allocateVoiceChatBuffer(totalBytes);
  if (wav == nullptr) {
    Serial.printf("[/voice-chat] failed to allocate %u bytes\n", (unsigned)totalBytes);
    return nullptr;
  }

  writeVoiceChatWavHeader(wav, expectedDataBytes);
  g_srI2s.setTimeout(900);

  size_t recorded = 0;
  while (recorded < expectedDataBytes) {
    const size_t remaining = expectedDataBytes - recorded;
    const size_t chunk = remaining > 4096 ? 4096 : remaining;
    size_t got = g_srI2s.readBytes((char*)(wav + VOICE_CHAT_WAV_HEADER_BYTES + recorded), chunk);
    if (got != chunk) {
      Serial.printf("[/voice-chat] short mic read: got=%u expected=%u last_error=%d\n",
                    (unsigned)got, (unsigned)chunk, g_srI2s.lastError());
      break;
    }
    recorded += got;
  }

  if (recorded == 0) {
    free(wav);
    return nullptr;
  }

  if (recorded != expectedDataBytes) {
    writeVoiceChatWavHeader(wav, recorded);
  }

  *outSize = VOICE_CHAT_WAV_HEADER_BYTES + recorded;
  Serial.printf("[/voice-chat] recorded %u audio bytes (%u total WAV bytes)\n",
                (unsigned)recorded, (unsigned)*outSize);
  return wav;
}

static bool requestVoiceChat(uint8_t* wav, size_t wavSize, String* sessionId) {
  if (!connectWifi()) return false;

  setRgbState(RGB_THINKING);

  HTTPClient http;
  String url = voiceChatUrl() + "?reply_audio=1";
  if (sessionId != nullptr && sessionId->length() > 0) {
    url += "&session_id=";
    url += *sessionId;
  }
  http.begin(url);
  http.addHeader("Content-Type", "audio/wav");
  addVoiceChatAuthHeader(http);
  http.setTimeout(HTTP_TIMEOUT_VOICE_CHAT_MS);
  Serial.printf("[/voice-chat] uploading %u bytes...\n", (unsigned)wavSize);
  int code = http.POST(wav, wavSize);

  if (code != 200) {
    Serial.printf("[/voice-chat] HTTP %d - %s\n", code, httpErrorHint(code));
    String body = http.getString();
    if (body.length() > 0) {
      Serial.print("[/voice-chat] error body: ");
      Serial.println(body);
    }
    http.end();
    setRgbState(RGB_OFFLINE);
    return false;
  }

  JsonDocument resp;
  DeserializationError err = deserializeJson(resp, http.getStream());
  http.end();
  if (err) {
    Serial.printf("[/voice-chat] JSON parse error: %s\n", err.c_str());
    return false;
  }

  const char* heard = resp["text"] | "";
  const char* reply = resp["reply"] | "";
  const char* provider = resp["provider"] | "";
  const char* returnedSessionId = resp["session_id"] | "";
  int turnIndex = resp["turn_index"] | 0;
  const char* tts = resp["tts"]["status"] | "unknown";
  const char* replyAudioStatus = resp["reply_audio"]["status"] | "unknown";
  const char* replyAudioUrl = resp["reply_audio"]["url"] | "";
  if (sessionId != nullptr && returnedSessionId[0] != '\0') {
    *sessionId = returnedSessionId;
  }
  Serial.printf("[/voice-chat] provider: %s\n", provider);
  Serial.printf("[voice-session] id=%s turn=%d\n", returnedSessionId, turnIndex);
  Serial.print("[/voice-chat] heard: ");
  Serial.println(heard);
  Serial.print("[/voice-chat] reply: ");
  Serial.println(reply);
  Serial.printf("[/voice-chat] tts: %s\n", tts);
  Serial.printf("[/voice-chat] reply_audio: %s %s\n", replyAudioStatus, replyAudioUrl);

  bool played = false;
  if (strcmp(replyAudioStatus, "ready") == 0 && replyAudioUrl[0] != '\0') {
    uint8_t* audio = nullptr;
    size_t audioSize = 0;
    if (downloadReplyAudio(replyAudioUrl, &audio, &audioSize)) {
      played = playReplyAudio(audio, audioSize);
      free(audio);
    }
  }

  setRgbState(reply[0] != '\0' ? RGB_READY : RGB_IDLE);
  return reply[0] != '\0' && (played || replyAudioUrl[0] == '\0');
}

static bool pollAndPlayDueReminder() {
  if (!connectWifi()) return false;

  setRgbState(RGB_THINKING);
  HTTPClient http;
  String url = voiceChatDueAudioUrl();
  http.begin(url);
  addVoiceChatAuthHeader(http);
  http.setTimeout(HTTP_TIMEOUT_VOICE_CHAT_MS);
  Serial.println("[/voice-chat/tasks/due-audio] polling");
  int code = http.GET();
  if (code != 200) {
    Serial.printf("[/voice-chat/tasks/due-audio] HTTP %d - %s\n", code, httpErrorHint(code));
    http.end();
    setRgbState(RGB_OFFLINE);
    return false;
  }

  JsonDocument resp;
  DeserializationError err = deserializeJson(resp, http.getStream());
  http.end();
  if (err) {
    Serial.printf("[/voice-chat/tasks/due-audio] JSON parse error: %s\n", err.c_str());
    return false;
  }

  const char* status = resp["status"] | "unknown";
  const char* text = resp["text"] | "";
  const char* taskTitle = resp["task"]["title"] | "";
  const char* replyAudioStatus = resp["reply_audio"]["status"] | "unknown";
  const char* replyAudioUrl = resp["reply_audio"]["url"] | "";
  const char* replyAudioProvider = resp["reply_audio"]["provider"] | "";
  const char* replyAudioModel = resp["reply_audio"]["model"] | "";
  const char* replyAudioVoice = resp["reply_audio"]["voice"] | "";
  Serial.printf("[/voice-chat/tasks/due-audio] status=%s task=%s\n", status, taskTitle);
  if (text[0] != '\0') {
    Serial.print("[/voice-chat/tasks/due-audio] text: ");
    Serial.println(text);
  }
  Serial.printf("[/voice-chat/tasks/due-audio] reply_audio: %s %s\n", replyAudioStatus, replyAudioUrl);
  if (replyAudioProvider[0] != '\0' || replyAudioModel[0] != '\0' || replyAudioVoice[0] != '\0') {
    Serial.printf("[/voice-chat/tasks/due-audio] tts provider=%s model=%s voice=%s\n",
                  replyAudioProvider, replyAudioModel, replyAudioVoice);
  }

  if (strcmp(status, "empty") == 0) {
    setRgbState(RGB_READY);
    return true;
  }

  if (strcmp(replyAudioStatus, "ready") != 0 || replyAudioUrl[0] == '\0') {
    Serial.println("[/voice-chat/tasks/due-audio] no playable reminder audio");
    setRgbState(RGB_REJECTED);
    return false;
  }

  uint8_t* audio = nullptr;
  size_t audioSize = 0;
  bool played = false;
  if (downloadReplyAudio(replyAudioUrl, &audio, &audioSize)) {
    played = playReplyAudio(audio, audioSize);
    free(audio);
  }
  setRgbState(played ? RGB_READY : RGB_REJECTED);
  return played;
}

static bool reminderAutoPollIsIdle() {
  if (g_hasProposal) {
    return false;
  }
#if ENABLE_ESP_SR
  if (g_srPendingVoiceChat || g_srPendingCommand >= 0 || g_srCommandWindowActive) {
    return false;
  }
#endif
  return true;
}

static void scheduleNextReminderPoll(uint32_t delayMs) {
  g_nextReminderPollAt = millis() + delayMs;
}

static void pollDueReminderIfIdle() {
  uint32_t now = millis();
  if (g_nextReminderPollAt == 0) {
    g_nextReminderPollAt = now + REMINDER_AUTO_FIRST_POLL_DELAY_MS;
    return;
  }

  if ((int32_t)(now - g_nextReminderPollAt) < 0) {
    return;
  }

  if (!reminderAutoPollIsIdle()) {
    g_nextReminderPollAt = now + REMINDER_AUTO_RETRY_INTERVAL_MS;
    return;
  }

  Serial.println("[reminders] auto poll");
  bool ok = pollAndPlayDueReminder();
  scheduleNextReminderPoll(ok ? REMINDER_AUTO_POLL_INTERVAL_MS : REMINDER_AUTO_RETRY_INTERVAL_MS);
}

static bool readWsHttpLine(WiFiClient& client, String& line, uint32_t timeoutMs) {
  line = "";
  uint32_t deadline = millis() + timeoutMs;
  while (millis() < deadline) {
    while (client.available() > 0) {
      char ch = (char)client.read();
      if (ch == '\r') {
        continue;
      }
      if (ch == '\n') {
        return true;
      }
      line += ch;
      if (line.length() > 512) {
        return false;
      }
    }
    delay(5);
  }
  return false;
}

static bool connectVoiceChatWs(WiFiClient& client) {
  if (!connectWifi()) return false;

  Serial.printf("[/voice-chat/ws] connecting to %s:%s\n", PC_HOST, PC_PORT);
  client.setTimeout(VOICE_CHAT_WS_CONNECT_TIMEOUT_MS);
  if (!client.connect(PC_HOST, atoi(PC_PORT))) {
    Serial.println("[/voice-chat/ws] TCP connect failed");
    return false;
  }

  String key = "dGhlIHNhbXBsZSBub25jZQ==";
  client.print("GET ");
  client.print(voiceChatWsPath());
  client.print(" HTTP/1.1\r\nHost: ");
  client.print(PC_HOST);
  client.print(":");
  client.print(PC_PORT);
  if (voiceChatAccessTokenConfigured()) {
    client.print("\r\nAuthorization: Bearer ");
    client.print(VOICE_CHAT_ACCESS_TOKEN);
  }
  client.print("\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ");
  client.print(key);
  client.print("\r\n\r\n");

  String line;
  if (!readWsHttpLine(client, line, VOICE_CHAT_WS_CONNECT_TIMEOUT_MS) ||
      !line.startsWith("HTTP/1.1 101")) {
    Serial.print("[/voice-chat/ws] handshake failed: ");
    Serial.println(line);
    client.stop();
    return false;
  }

  while (readWsHttpLine(client, line, VOICE_CHAT_WS_CONNECT_TIMEOUT_MS)) {
    if (line.length() == 0) {
      Serial.println("[/voice-chat/ws] connected");
      return true;
    }
  }

  Serial.println("[/voice-chat/ws] handshake header timeout");
  client.stop();
  return false;
}

static bool writeWsFrame(WiFiClient& client, uint8_t opcode, const uint8_t* payload, size_t payloadSize) {
  if (!client.connected()) return false;

  uint8_t header[14];
  size_t headerSize = 0;
  header[headerSize++] = 0x80 | (opcode & 0x0F);
  if (payloadSize <= 125) {
    header[headerSize++] = 0x80 | (uint8_t)payloadSize;
  } else if (payloadSize <= 65535) {
    header[headerSize++] = 0x80 | 126;
    header[headerSize++] = (uint8_t)((payloadSize >> 8) & 0xFF);
    header[headerSize++] = (uint8_t)(payloadSize & 0xFF);
  } else {
    header[headerSize++] = 0x80 | 127;
    uint64_t longSize = (uint64_t)payloadSize;
    for (int shift = 56; shift >= 0; shift -= 8) {
      header[headerSize++] = (uint8_t)((longSize >> shift) & 0xFF);
    }
  }

  uint8_t mask[4] = {
      (uint8_t)esp_random(),
      (uint8_t)(esp_random() >> 8),
      (uint8_t)(esp_random() >> 16),
      (uint8_t)(esp_random() >> 24),
  };
  memcpy(header + headerSize, mask, sizeof(mask));
  headerSize += sizeof(mask);

  if (client.write(header, headerSize) != headerSize) {
    return false;
  }

  uint8_t scratch[256];
  size_t sent = 0;
  while (sent < payloadSize) {
    size_t chunk = payloadSize - sent;
    if (chunk > sizeof(scratch)) {
      chunk = sizeof(scratch);
    }
    for (size_t i = 0; i < chunk; i++) {
      scratch[i] = payload[sent + i] ^ mask[(sent + i) & 3];
    }
    if (client.write(scratch, chunk) != chunk) {
      return false;
    }
    sent += chunk;
  }
  return true;
}

static bool sendWsText(WiFiClient& client, const String& payload) {
  return writeWsFrame(client, 0x1, (const uint8_t*)payload.c_str(), payload.length());
}

static bool sendWsBinaryChunks(WiFiClient& client, const uint8_t* payload, size_t payloadSize) {
  size_t sent = 0;
  while (sent < payloadSize) {
    size_t chunk = payloadSize - sent;
    if (chunk > VOICE_CHAT_WS_BINARY_CHUNK_BYTES) {
      chunk = VOICE_CHAT_WS_BINARY_CHUNK_BYTES;
    }
    if (!writeWsFrame(client, 0x2, payload + sent, chunk)) {
      return false;
    }
    sent += chunk;
  }
  return true;
}

static bool sendVoiceChatWsPcmRecording(WiFiClient& client, uint8_t seconds) {
  seconds = constrain(seconds, VOICE_CHAT_MIN_SECONDS, VOICE_CHAT_MAX_SECONDS);
  if (!configureVoiceChatMicRx()) {
    return false;
  }
  const size_t i2sBytesPerSecond =
      (VOICE_CHAT_SAMPLE_RATE * VOICE_CHAT_CHANNELS * VOICE_CHAT_BITS_PER_SAMPLE) / 8;
  const size_t uploadBytesPerSecond =
      (VOICE_CHAT_SAMPLE_RATE * VOICE_CHAT_UPLOAD_CHANNELS * VOICE_CHAT_BITS_PER_SAMPLE) / 8;
  const size_t expectedI2sBytes = i2sBytesPerSecond * seconds;
  static uint8_t i2sChunk[VOICE_CHAT_WS_BINARY_CHUNK_BYTES];
  static int16_t monoChunk[VOICE_CHAT_WS_BINARY_CHUNK_BYTES / (VOICE_CHAT_CHANNELS * sizeof(int16_t))];

  g_srI2s.setTimeout(900);
  size_t readTotal = 0;
  size_t sent = 0;
  bool speechSeen = false;
  uint32_t candidateSpeechMs = 0;
  uint32_t quietAfterSpeechMs = 0;
  uint32_t noiseMeanAbs = 0;
  uint32_t speechThreshold = VOICE_CHAT_WS_VAD_MIN_MEAN_ABS;
  uint32_t maxMeanAbs = 0;
  while (readTotal < expectedI2sBytes) {
    size_t toRead = expectedI2sBytes - readTotal;
    if (toRead > sizeof(i2sChunk)) {
      toRead = sizeof(i2sChunk);
    }
    toRead -= toRead % (VOICE_CHAT_CHANNELS * sizeof(int16_t));
    if (toRead == 0) {
      break;
    }
    size_t got = g_srI2s.readBytes((char*)i2sChunk, toRead);
    if (got != toRead) {
      Serial.printf("[/voice-chat/ws] short mic stream: got=%u expected=%u last_error=%d\n",
                    (unsigned)got, (unsigned)toRead, g_srI2s.lastError());
      if (got == 0) {
        return false;
      }
    }
    got -= got % (VOICE_CHAT_CHANNELS * sizeof(int16_t));
    if (got == 0) {
      continue;
    }

    const int16_t* stereo = (const int16_t*)i2sChunk;
    const size_t stereoFrames = got / (VOICE_CHAT_CHANNELS * sizeof(int16_t));
    int64_t sumAbs = 0;
    for (size_t i = 0; i < stereoFrames; i++) {
      int32_t left = stereo[i * 2];
      int32_t right = stereo[i * 2 + 1];
      int32_t mixed = abs(left) >= abs(right) ? left : right;
      mixed <<= VOICE_CHAT_UPLOAD_GAIN_SHIFT;
      if (mixed > 32767) mixed = 32767;
      if (mixed < -32768) mixed = -32768;
      monoChunk[i] = (int16_t)mixed;
      sumAbs += mixed < 0 ? -mixed : mixed;
    }

    size_t uploadBytes = stereoFrames * sizeof(int16_t);
    if (!writeWsFrame(client, 0x2, (const uint8_t*)monoChunk, uploadBytes)) {
      return false;
    }
    readTotal += got;
    sent += uploadBytes;

    const uint32_t chunkMs = (uint32_t)((got * 1000UL) / i2sBytesPerSecond);
    const uint32_t meanAbs = stereoFrames > 0 ? (uint32_t)(sumAbs / stereoFrames) : 0;
    const uint32_t elapsedMs = (uint32_t)((readTotal * 1000UL) / i2sBytesPerSecond);
    if (meanAbs > maxMeanAbs) {
      maxMeanAbs = meanAbs;
    }
    if (elapsedMs <= VOICE_CHAT_WS_VAD_NOISE_PROBE_MS) {
      noiseMeanAbs = noiseMeanAbs == 0 ? meanAbs : ((noiseMeanAbs * 3) + meanAbs) / 4;
      uint32_t dynamicThreshold = noiseMeanAbs + VOICE_CHAT_WS_VAD_NOISE_MARGIN;
      speechThreshold = dynamicThreshold > VOICE_CHAT_WS_VAD_MIN_MEAN_ABS ?
          dynamicThreshold : VOICE_CHAT_WS_VAD_MIN_MEAN_ABS;
      continue;
    }

    if (meanAbs >= speechThreshold) {
      candidateSpeechMs += chunkMs;
      if (candidateSpeechMs >= VOICE_CHAT_WS_VAD_MIN_SPEECH_MS) {
        speechSeen = true;
      }
      quietAfterSpeechMs = 0;
    } else if (speechSeen) {
      quietAfterSpeechMs += chunkMs;
    } else {
      candidateSpeechMs = 0;
    }

    if (speechSeen &&
        elapsedMs >= VOICE_CHAT_WS_VAD_MIN_RECORD_MS &&
        quietAfterSpeechMs >= VOICE_CHAT_WS_VAD_TRAILING_SILENCE_MS) {
      Serial.printf("[/voice-chat/ws] VAD stop at %lums mean_abs=%lu threshold=%lu quiet=%lums\n",
                    (unsigned long)elapsedMs,
                    (unsigned long)meanAbs,
                    (unsigned long)speechThreshold,
                    (unsigned long)quietAfterSpeechMs);
      break;
    }
  }

  Serial.printf("[/voice-chat/ws] streamed %u PCM bytes mono (%lums%s noise=%lu threshold=%lu peak_mean=%lu)\n",
                (unsigned)sent,
                (unsigned long)((sent * 1000UL) / uploadBytesPerSecond),
                speechSeen ? ", speech" : "",
                (unsigned long)noiseMeanAbs,
                (unsigned long)speechThreshold,
                (unsigned long)maxMeanAbs);
  return sent > 0;
}

static bool readWsByte(WiFiClient& client, uint8_t& out, uint32_t deadline) {
  while (millis() < deadline) {
    if (client.available() > 0) {
      int value = client.read();
      if (value >= 0) {
        out = (uint8_t)value;
        return true;
      }
    }
    delay(5);
  }
  return false;
}

static bool readWsPayload(WiFiClient& client, uint8_t* dst, size_t size, uint32_t deadline) {
  size_t got = 0;
  while (got < size && millis() < deadline) {
    int available = client.available();
    if (available <= 0) {
      delay(5);
      continue;
    }
    size_t chunk = size - got;
    if (chunk > (size_t)available) {
      chunk = (size_t)available;
    }
    int read = client.read(dst + got, chunk);
    if (read > 0) {
      got += (size_t)read;
    }
  }
  return got == size;
}

static bool readWsFrame(WiFiClient& client, uint8_t& opcodeOut, String* textOut, uint8_t** binaryOut, size_t* binarySizeOut, uint32_t timeoutMs) {
  if (textOut != nullptr) {
    *textOut = "";
  }
  if (binaryOut != nullptr) {
    *binaryOut = nullptr;
  }
  if (binarySizeOut != nullptr) {
    *binarySizeOut = 0;
  }
  opcodeOut = 0;

  uint32_t deadline = millis() + timeoutMs;
  while (millis() < deadline) {
    uint8_t b0 = 0;
    uint8_t b1 = 0;
    if (!readWsByte(client, b0, deadline) || !readWsByte(client, b1, deadline)) {
      return false;
    }

    uint8_t opcode = b0 & 0x0F;
    bool masked = (b1 & 0x80) != 0;
    uint64_t length = b1 & 0x7F;
    if (length == 126) {
      uint8_t ext[2];
      if (!readWsPayload(client, ext, sizeof(ext), deadline)) return false;
      length = ((uint16_t)ext[0] << 8) | ext[1];
    } else if (length == 127) {
      uint8_t ext[8];
      if (!readWsPayload(client, ext, sizeof(ext), deadline)) return false;
      length = 0;
      for (uint8_t i = 0; i < 8; i++) {
        length = (length << 8) | ext[i];
      }
    }

    uint8_t mask[4] = {0, 0, 0, 0};
    if (masked && !readWsPayload(client, mask, sizeof(mask), deadline)) {
      return false;
    }

    if (opcode == 0x2) {
      if (length == 0 || length > VOICE_CHAT_MAX_REPLY_WAV_BYTES) {
        Serial.printf("[/voice-chat/ws] binary frame size invalid: %u\n", (unsigned)length);
        return false;
      }
      uint8_t* binary = allocateVoiceChatBuffer((size_t)length);
      if (binary == nullptr) {
        Serial.printf("[/voice-chat/ws] failed to allocate %u binary bytes\n", (unsigned)length);
        return false;
      }
      size_t got = 0;
      while (got < (size_t)length) {
        size_t chunk = (size_t)length - got;
        if (chunk > 1024) {
          chunk = 1024;
        }
        if (!readWsPayload(client, binary + got, chunk, deadline)) {
          free(binary);
          return false;
        }
        if (masked) {
          for (size_t i = 0; i < chunk; i++) {
            binary[got + i] ^= mask[(got + i) & 3];
          }
        }
        got += chunk;
      }
      opcodeOut = opcode;
      if (binaryOut != nullptr) {
        *binaryOut = binary;
      } else {
        free(binary);
      }
      if (binarySizeOut != nullptr) {
        *binarySizeOut = (size_t)length;
      }
      return true;
    }

    if (length > 4096) {
      Serial.printf("[/voice-chat/ws] frame too large: %u\n", (unsigned)length);
      return false;
    }

    uint8_t payload[256];
    size_t remaining = (size_t)length;
    size_t offset = 0;
    while (remaining > 0) {
      size_t chunk = remaining > sizeof(payload) ? sizeof(payload) : remaining;
      if (!readWsPayload(client, payload, chunk, deadline)) {
        return false;
      }
      for (size_t i = 0; i < chunk; i++) {
        char ch = (char)(payload[i] ^ (masked ? mask[(offset + i) & 3] : 0));
        if (opcode == 0x1 && textOut != nullptr) {
          *textOut += ch;
        }
      }
      offset += chunk;
      remaining -= chunk;
    }

    if (opcode == 0x1) {
      opcodeOut = opcode;
      return true;
    }
    if (opcode == 0x8) {
      Serial.println("[/voice-chat/ws] server closed");
      return false;
    }
    if (opcode == 0x9) {
      writeWsFrame(client, 0xA, nullptr, 0);
    }
  }
  return false;
}

static bool readWsTextFrame(WiFiClient& client, String& out, uint32_t timeoutMs) {
  uint8_t opcode = 0;
  return readWsFrame(client, opcode, &out, nullptr, nullptr, timeoutMs) && opcode == 0x1;
}

static void resetReplyAudioBuffer() {
  if (g_replyAudioData != nullptr) {
    free(g_replyAudioData);
  }
  resetReplyAudioStream();
  g_replyAudioData = nullptr;
  g_replyAudioSize = 0;
  g_replyAudioCapacity = 0;
  g_replyAudioActive = false;
  g_replyAudioChunked = false;
  g_replyAudioStreamOnly = false;
  g_replyAudioChunks = 0;
}

static bool beginReplyAudioBuffer(size_t expectedBytes, bool chunked) {
  resetReplyAudioBuffer();
  if (expectedBytes == 0 || expectedBytes > VOICE_CHAT_MAX_REPLY_WAV_BYTES) {
    Serial.printf("[/voice-chat/ws] reply audio size invalid: %u\n", (unsigned)expectedBytes);
    return false;
  }
  g_replyAudioData = allocateVoiceChatBuffer(expectedBytes);
  if (g_replyAudioData == nullptr) {
    Serial.printf("[/voice-chat/ws] failed to allocate %u reply audio bytes\n", (unsigned)expectedBytes);
    return false;
  }
  g_replyAudioCapacity = expectedBytes;
  g_replyAudioActive = true;
  g_replyAudioChunked = chunked;
  g_replyAudioChunks = 0;
  if (chunked) {
    resetReplyAudioStream();
    g_replyAudioStreaming = true;
  }
  Serial.printf("[/voice-chat/ws] reply audio buffer ready bytes=%u chunked=%s\n",
                (unsigned)expectedBytes,
                chunked ? "yes" : "no");
  return true;
}

static bool beginReplyAudioStreamOnly() {
  resetReplyAudioBuffer();
  resetReplyAudioStream();
  g_replyAudioActive = true;
  g_replyAudioChunked = true;
  g_replyAudioStreamOnly = true;
  g_replyAudioStreaming = true;
  g_replyAudioChunks = 0;
  Serial.println("[/voice-chat/ws] reply audio stream ready");
  return true;
}

static bool appendReplyAudioChunk(uint8_t* chunk, size_t chunkSize) {
  if (!g_replyAudioActive || chunk == nullptr || chunkSize == 0) {
    return false;
  }
  if (g_replyAudioStreamOnly) {
    g_replyAudioChunks += 1;
    feedReplyAudioStream(chunk, chunkSize);
    Serial.printf("[/voice-chat/ws] binary audio stream chunk %d size=%u\n",
                  g_replyAudioChunks,
                  (unsigned)chunkSize);
    return true;
  }
  if (g_replyAudioData == nullptr) {
    return false;
  }
  if (g_replyAudioSize + chunkSize > g_replyAudioCapacity) {
    Serial.printf("[/voice-chat/ws] reply audio overflow: have=%u chunk=%u capacity=%u\n",
                  (unsigned)g_replyAudioSize,
                  (unsigned)chunkSize,
                  (unsigned)g_replyAudioCapacity);
    return false;
  }
  memcpy(g_replyAudioData + g_replyAudioSize, chunk, chunkSize);
  g_replyAudioSize += chunkSize;
  g_replyAudioChunks += 1;
  if (g_replyAudioStreaming) {
    feedReplyAudioStream(chunk, chunkSize);
  }
  Serial.printf("[/voice-chat/ws] binary audio chunk %d size=%u total=%u/%u\n",
                g_replyAudioChunks,
                (unsigned)chunkSize,
                (unsigned)g_replyAudioSize,
                (unsigned)g_replyAudioCapacity);
  return true;
}

static bool finishReplyAudioBuffer() {
  if (!g_replyAudioActive) {
    return false;
  }
  if (g_replyAudioStreamOnly) {
    Serial.printf("[/voice-chat/ws] reply audio stream complete chunks=%d\n", g_replyAudioChunks);
    bool streamed = finishReplyAudioStream();
    resetReplyAudioBuffer();
    return streamed;
  }
  if (g_replyAudioData == nullptr) {
    return false;
  }
  Serial.printf("[/voice-chat/ws] reply audio chunks complete chunks=%d bytes=%u\n",
                g_replyAudioChunks,
                (unsigned)g_replyAudioSize);
  bool streamed = finishReplyAudioStream();
  bool ok = g_replyAudioSize == g_replyAudioCapacity &&
            (streamed || playReplyAudio(g_replyAudioData, g_replyAudioSize));
  resetReplyAudioBuffer();
  return ok;
}

static void logVoiceChatWsEvent(
    JsonDocument& event, String* sessionId, bool* ready, bool* hasReply, bool* waitBinaryAudio, bool* noMatch) {
  const char* type = event["type"] | "";
  const char* state = event["state"] | "";
  const char* returnedSessionId = event["session_id"] | "";
  if (sessionId != nullptr && returnedSessionId[0] != '\0') {
    *sessionId = returnedSessionId;
  }

  if (strcmp(type, "hello") == 0) {
    Serial.printf("[/voice-chat/ws] hello session=%s\n", returnedSessionId);
    return;
  }
  if (strcmp(type, "stt") == 0) {
    if (strcmp(state, "no_match") == 0) {
      const char* detail = event["detail"] | "";
      Serial.printf("[/voice-chat/ws] no speech detected: %s\n", detail);
      if (noMatch != nullptr) {
        *noMatch = true;
      }
      return;
    }
    const char* text = event["text"] | "";
    Serial.print("[/voice-chat/ws] heard: ");
    Serial.println(text);
    return;
  }
  if (strcmp(type, "llm") == 0) {
    if (strcmp(state, "start") == 0) {
      Serial.println("[/voice-chat/ws] llm start");
    } else if (strcmp(state, "stop") == 0) {
      const char* reply = event["text"] | "";
      const char* provider = event["provider"] | "";
      int turnIndex = event["turn_index"] | 0;
      Serial.printf("[/voice-chat/ws] provider: %s\n", provider);
      Serial.printf("[voice-session] id=%s turn=%d\n", returnedSessionId, turnIndex);
      Serial.print("[/voice-chat/ws] reply: ");
      Serial.println(reply);
      if (hasReply != nullptr && reply[0] != '\0') {
        *hasReply = true;
      }
    }
    return;
  }
  if (strcmp(type, "tts") == 0 && strcmp(state, "audio") == 0) {
    const char* status = event["status"] | "unknown";
    const char* url = event["url"] | "";
    const char* transport = event["transport"] | "url";
    const char* provider = event["provider"] | "";
    const char* model = event["model"] | "";
    const char* voice = event["voice"] | "";
    int bytes = event["bytes"] | 0;
    Serial.printf("[/voice-chat/ws] reply_audio: %s %s transport=%s bytes=%d\n", status, url, transport, bytes);
    if (provider[0] != '\0' || model[0] != '\0' || voice[0] != '\0') {
      Serial.printf("[/voice-chat/ws] tts provider=%s model=%s voice=%s\n", provider, model, voice);
    }
    if (strcmp(status, "ready") == 0 && strcmp(transport, "websocket_binary_stream") == 0) {
      beginReplyAudioStreamOnly();
      if (waitBinaryAudio != nullptr) {
        *waitBinaryAudio = true;
      }
    } else if (strcmp(status, "ready") == 0 &&
               (strcmp(transport, "websocket_binary") == 0 || strcmp(transport, "websocket_binary_chunked") == 0)) {
      beginReplyAudioBuffer((size_t)bytes, strcmp(transport, "websocket_binary_chunked") == 0);
      if (waitBinaryAudio != nullptr) {
        *waitBinaryAudio = true;
      }
    } else if (strcmp(status, "ready") == 0 && url[0] != '\0') {
      uint8_t* audio = nullptr;
      size_t audioSize = 0;
      if (downloadReplyAudio(url, &audio, &audioSize)) {
        playReplyAudio(audio, audioSize);
        free(audio);
      }
    }
    return;
  }
  if (strcmp(type, "tts") == 0 && strcmp(state, "audio_done") == 0) {
    const char* transport = event["transport"] | "";
    int chunkCount = event["chunk_count"] | 0;
    if (strcmp(transport, "websocket_binary_chunked") == 0 ||
        strcmp(transport, "websocket_binary_stream") == 0) {
      Serial.printf("[/voice-chat/ws] reply_audio done transport=%s chunks=%d\n", transport, chunkCount);
      finishReplyAudioBuffer();
      if (waitBinaryAudio != nullptr) {
        *waitBinaryAudio = false;
      }
    }
    return;
  }
  if (strcmp(type, "listen") == 0 && strcmp(state, "ready") == 0) {
    int turnIndex = event["turn_index"] | 0;
    Serial.printf("[/voice-chat/ws] ready turn=%d\n", turnIndex);
    if (ready != nullptr) {
      *ready = true;
    }
    return;
  }
  if (strcmp(type, "error") == 0) {
    const char* detail = event["detail"] | "";
    Serial.print("[/voice-chat/ws] error: ");
    Serial.println(detail);
  }
}

static bool beginVoiceChatWsSession(WiFiClient& client, String* sessionId) {
  JsonDocument hello;
  hello["type"] = "hello";
  hello["version"] = 1;
  hello["transport"] = "websocket";
  hello["reply_audio"] = true;
  hello["reply_audio_transport"] = "websocket_binary_stream";
  hello["user_id"] = VOICE_CHAT_USER_ID;
  hello["device_id"] = VOICE_CHAT_DEVICE_ID;
  if (sessionId != nullptr && sessionId->length() > 0) {
    hello["session_id"] = *sessionId;
  }
  JsonObject audioParams = hello["audio_params"].to<JsonObject>();
  audioParams["format"] = "pcm_s16le";
  audioParams["sample_rate"] = VOICE_CHAT_SAMPLE_RATE;
  audioParams["channels"] = VOICE_CHAT_UPLOAD_CHANNELS;
  audioParams["frame_duration"] = 60;

  String payload;
  serializeJson(hello, payload);
  if (!sendWsText(client, payload)) {
    client.stop();
    return false;
  }

  bool helloOk = false;
  uint32_t deadline = millis() + VOICE_CHAT_WS_TURN_TIMEOUT_MS;
  while (millis() < deadline) {
    String frame;
    if (!readWsTextFrame(client, frame, 10000)) {
      break;
    }
    JsonDocument event;
    if (deserializeJson(event, frame)) {
      continue;
    }
    logVoiceChatWsEvent(event, sessionId, nullptr, nullptr, nullptr, nullptr);
    const char* type = event["type"] | "";
    if (strcmp(type, "hello") == 0) {
      helloOk = true;
      break;
    }
  }

  if (!helloOk) {
    Serial.println("[/voice-chat/ws] hello timeout");
    return false;
  }
  return true;
}

static bool sendVoiceChatWsTurn(WiFiClient& client, uint8_t* wav, size_t wavSize, String* sessionId) {
  String payload;

  JsonDocument start;
  start["type"] = "listen";
  start["state"] = "start";
  if (sessionId != nullptr && sessionId->length() > 0) {
    start["session_id"] = *sessionId;
  }
  start["user_id"] = VOICE_CHAT_USER_ID;
  start["device_id"] = VOICE_CHAT_DEVICE_ID;
  payload = "";
  serializeJson(start, payload);
  if (!sendWsText(client, payload)) {
    return false;
  }

  Serial.printf("[/voice-chat/ws] sending %u WAV bytes\n", (unsigned)wavSize);
  if (!sendWsBinaryChunks(client, wav, wavSize)) {
    Serial.println("[/voice-chat/ws] audio send failed");
    return false;
  }

  JsonDocument stop;
  stop["type"] = "listen";
  stop["state"] = "stop";
  payload = "";
  serializeJson(stop, payload);
  if (!sendWsText(client, payload)) {
    return false;
  }

  uint32_t deadline = millis() + VOICE_CHAT_WS_TURN_TIMEOUT_MS;
  bool ready = false;
  bool hasReply = false;
  bool waitBinaryAudio = false;
  bool noMatch = false;
  while (!ready && millis() < deadline) {
    uint8_t opcode = 0;
    String frame;
    uint8_t* binary = nullptr;
    size_t binarySize = 0;
    if (!readWsFrame(client, opcode, &frame, &binary, &binarySize, VOICE_CHAT_WS_TURN_TIMEOUT_MS)) {
      Serial.printf("[/voice-chat/ws] frame wait timeout ready=%s has_reply=%s wait_audio=%s\n",
                    ready ? "yes" : "no",
                    hasReply ? "yes" : "no",
                    waitBinaryAudio ? "yes" : "no");
      break;
    }
    if (opcode == 0x2) {
      Serial.printf("[/voice-chat/ws] binary audio frame %u bytes\n", (unsigned)binarySize);
      if (waitBinaryAudio && binary != nullptr && binarySize > 0) {
        if (g_replyAudioActive) {
          appendReplyAudioChunk(binary, binarySize);
          if (!g_replyAudioChunked && !g_replyAudioStreamOnly && g_replyAudioSize == g_replyAudioCapacity) {
            finishReplyAudioBuffer();
            waitBinaryAudio = false;
          }
        } else {
          playReplyAudio(binary, binarySize);
          waitBinaryAudio = false;
        }
      }
      free(binary);
      continue;
    }
    JsonDocument event;
    DeserializationError err = deserializeJson(event, frame);
    if (err) {
      Serial.printf("[/voice-chat/ws] JSON parse error: %s\n", err.c_str());
      continue;
    }
    logVoiceChatWsEvent(event, sessionId, &ready, &hasReply, &waitBinaryAudio, &noMatch);
  }

  resetReplyAudioBuffer();
  setRgbState(hasReply ? RGB_READY : RGB_IDLE);
  return ready && (hasReply || noMatch);
}

static bool sendVoiceChatWsPcmTurn(WiFiClient& client, uint8_t seconds, String* sessionId) {
  String payload;

  JsonDocument start;
  start["type"] = "listen";
  start["state"] = "start";
  if (sessionId != nullptr && sessionId->length() > 0) {
    start["session_id"] = *sessionId;
  }
  start["user_id"] = VOICE_CHAT_USER_ID;
  start["device_id"] = VOICE_CHAT_DEVICE_ID;
  JsonObject audioParams = start["audio_params"].to<JsonObject>();
  audioParams["format"] = "pcm_s16le";
  audioParams["sample_rate"] = VOICE_CHAT_SAMPLE_RATE;
  audioParams["channels"] = VOICE_CHAT_UPLOAD_CHANNELS;
  audioParams["frame_duration"] = 60;

  serializeJson(start, payload);
  if (!sendWsText(client, payload)) {
    return false;
  }

  if (!sendVoiceChatWsPcmRecording(client, seconds)) {
    Serial.println("[/voice-chat/ws] PCM stream failed");
    return false;
  }

  JsonDocument stop;
  stop["type"] = "listen";
  stop["state"] = "stop";
  payload = "";
  serializeJson(stop, payload);
  if (!sendWsText(client, payload)) {
    return false;
  }

  uint32_t deadline = millis() + VOICE_CHAT_WS_TURN_TIMEOUT_MS;
  bool ready = false;
  bool hasReply = false;
  bool waitBinaryAudio = false;
  bool noMatch = false;
  while (!ready && millis() < deadline) {
    uint8_t opcode = 0;
    String frame;
    uint8_t* binary = nullptr;
    size_t binarySize = 0;
    if (!readWsFrame(client, opcode, &frame, &binary, &binarySize, VOICE_CHAT_WS_TURN_TIMEOUT_MS)) {
      Serial.printf("[/voice-chat/ws] frame wait timeout ready=%s has_reply=%s wait_audio=%s\n",
                    ready ? "yes" : "no",
                    hasReply ? "yes" : "no",
                    waitBinaryAudio ? "yes" : "no");
      break;
    }
    if (opcode == 0x2) {
      Serial.printf("[/voice-chat/ws] binary audio frame %u bytes\n", (unsigned)binarySize);
      if (waitBinaryAudio && binary != nullptr && binarySize > 0) {
        if (g_replyAudioActive) {
          appendReplyAudioChunk(binary, binarySize);
          if (!g_replyAudioChunked && !g_replyAudioStreamOnly && g_replyAudioSize == g_replyAudioCapacity) {
            finishReplyAudioBuffer();
            waitBinaryAudio = false;
          }
        } else {
          playReplyAudio(binary, binarySize);
          waitBinaryAudio = false;
        }
      }
      free(binary);
      continue;
    }
    JsonDocument event;
    DeserializationError err = deserializeJson(event, frame);
    if (err) {
      Serial.printf("[/voice-chat/ws] JSON parse error: %s\n", err.c_str());
      continue;
    }
    logVoiceChatWsEvent(event, sessionId, &ready, &hasReply, &waitBinaryAudio, &noMatch);
  }

  resetReplyAudioBuffer();
  setRgbState(hasReply ? RGB_READY : RGB_IDLE);
  return ready && (hasReply || noMatch);
}

static bool requestVoiceChatWs(uint8_t* wav, size_t wavSize, String* sessionId) {
  WiFiClient client;
  bool ok = false;
  if (connectVoiceChatWs(client) && beginVoiceChatWsSession(client, sessionId)) {
    ok = sendVoiceChatWsTurn(client, wav, wavSize, sessionId);
  }
  writeWsFrame(client, 0x8, nullptr, 0);
  client.stop();
  return ok;
}

static bool recordAndPostVoiceChat(uint8_t seconds, String* sessionId = nullptr) {
  seconds = constrain(seconds, VOICE_CHAT_MIN_SECONDS, VOICE_CHAT_MAX_SECONDS);
  if (!g_srI2sReady) {
    Serial.println("[/voice-chat] mic unavailable - I2S is not ready");
    setRgbState(RGB_OFFLINE);
    return false;
  }

  Serial.printf("[/voice-chat] recording %us - speak now\n", seconds);
  setRgbState(RGB_LISTENING);

  bool srPaused = pauseEspSrIfRunning();
  delay(150);
  drainVoiceChatMic(250);

  size_t wavSize = 0;
  uint8_t* wav = recordVoiceChatWav(seconds, &wavSize);

  if (wav == nullptr || wavSize == 0) {
    Serial.println("[/voice-chat] recording failed");
    resumeEspSrIfPaused(srPaused);
    setRgbState(RGB_OFFLINE);
    return false;
  }

  bool ok = requestVoiceChat(wav, wavSize, sessionId);
  free(wav);
  resumeEspSrIfPaused(srPaused);
  return ok;
}

static bool recordAndPostVoiceChatWs(uint8_t seconds, String* sessionId = nullptr) {
  seconds = constrain(seconds, VOICE_CHAT_MIN_SECONDS, VOICE_CHAT_MAX_SECONDS);
  if (!g_srI2sReady) {
    Serial.println("[/voice-chat/ws] mic unavailable - I2S is not ready");
    setRgbState(RGB_OFFLINE);
    return false;
  }

  Serial.printf("[/voice-chat/ws] recording %us - speak now\n", seconds);
  setRgbState(RGB_LISTENING);

  bool srPaused = pauseEspSrIfRunning();
  delay(150);
  drainVoiceChatMic(250);

  WiFiClient client;
  setRgbState(RGB_THINKING);
  bool ok = false;
  if (connectVoiceChatWs(client) && beginVoiceChatWsSession(client, sessionId)) {
    ok = sendVoiceChatWsPcmTurn(client, seconds, sessionId);
  }
  writeWsFrame(client, 0x8, nullptr, 0);
  client.stop();
  resumeEspSrIfPaused(srPaused);
  return ok;
}

static bool recordAndPostVoiceChatSession(uint8_t turns, uint8_t seconds) {
  turns = constrain(turns, 1, VOICE_CHAT_MAX_SESSION_TURNS);
  seconds = constrain(seconds, VOICE_CHAT_MIN_SECONDS, VOICE_CHAT_MAX_SECONDS);

  bool allOk = true;
  for (uint8_t turn = 0; turn < turns; turn++) {
    Serial.printf("[voice-session] turn %u/%u\n", (unsigned)(turn + 1), (unsigned)turns);
    if (!recordAndPostVoiceChat(seconds, &g_voiceChatSessionId)) {
      allOk = false;
      break;
    }
    delay(500);
  }
  return allOk;
}

static bool recordAndPostVoiceChatWsSession(uint8_t turns, uint8_t seconds) {
  turns = constrain(turns, 1, VOICE_CHAT_MAX_SESSION_TURNS);
  seconds = constrain(seconds, VOICE_CHAT_MIN_SECONDS, VOICE_CHAT_MAX_SECONDS);

  if (!g_srI2sReady) {
    Serial.println("[/voice-chat/ws] mic unavailable - I2S is not ready");
    setRgbState(RGB_OFFLINE);
    return false;
  }

  WiFiClient client;
  if (!connectVoiceChatWs(client) || !beginVoiceChatWsSession(client, &g_voiceChatSessionId)) {
    client.stop();
    return false;
  }

  bool srPaused = pauseEspSrIfRunning();
  bool allOk = true;
  for (uint8_t turn = 0; turn < turns; turn++) {
    Serial.printf("[voice-session/ws] turn %u/%u\n", (unsigned)(turn + 1), (unsigned)turns);

    Serial.printf("[/voice-chat/ws] recording %us - speak now\n", seconds);
    setRgbState(RGB_LISTENING);
    delay(150);
    drainVoiceChatMic(250);

    setRgbState(RGB_THINKING);
    if (!sendVoiceChatWsPcmTurn(client, seconds, &g_voiceChatSessionId)) {
      allOk = false;
      break;
    }
    delay(500);
  }

  resumeEspSrIfPaused(srPaused);
  writeWsFrame(client, 0x8, nullptr, 0);
  client.stop();
  return allOk;
}
#else
static bool recordAndPostVoiceChat(uint8_t seconds, String* sessionId = nullptr) {
  (void)seconds;
  (void)sessionId;
  Serial.println("[/voice-chat] unavailable - rebuild with ENABLE_ESP_SR=1");
  return false;
}

static bool recordAndPostVoiceChatWs(uint8_t seconds, String* sessionId = nullptr) {
  (void)seconds;
  (void)sessionId;
  Serial.println("[/voice-chat/ws] unavailable - rebuild with ENABLE_ESP_SR=1");
  return false;
}

static bool recordAndPostVoiceChatSession(uint8_t turns, uint8_t seconds) {
  (void)turns;
  (void)seconds;
  Serial.println("[/voice-chat] unavailable - rebuild with ENABLE_ESP_SR=1");
  return false;
}

static bool recordAndPostVoiceChatWsSession(uint8_t turns, uint8_t seconds) {
  (void)turns;
  (void)seconds;
  Serial.println("[/voice-chat/ws] unavailable - rebuild with ENABLE_ESP_SR=1");
  return false;
}

static bool playVoiceChatWakeAck() {
  Serial.println("[voice] wake ack unavailable - rebuild with ENABLE_ESP_SR=1");
  return false;
}

static bool playSpeakerTestTone(uint8_t seconds, uint8_t mode = SPEAKER_TEST_ALL) {
  (void)seconds;
  (void)mode;
  Serial.println("[speaker-test] unavailable - rebuild with ENABLE_ESP_SR=1");
  return false;
}

static bool pollAndPlayDueReminder() {
  Serial.println("[/voice-chat/tasks/due-audio] unavailable - rebuild with ENABLE_ESP_SR=1");
  return false;
}

static void scheduleNextReminderPoll(uint32_t delayMs) {
  (void)delayMs;
}

static void pollDueReminderIfIdle() {
}
#endif  // ENABLE_ESP_SR

// ---------------------------------------------------------------------------
// POST /plan  (propose only: execute=false, agent_mode=true)
// ---------------------------------------------------------------------------
static bool requestPlan(const char* prompt) {
  if (!connectWifi()) return false;

  setRgbState(RGB_THINKING);

  JsonDocument body;
  body["prompt"] = prompt;
  body["network_mode"] = "online";
  body["agent_mode"] = true;
  body["execute"] = false;  // human-in-the-loop: propose first, never auto-run

  String payload;
  serializeJson(body, payload);

  HTTPClient http;
  http.begin(planUrl());
  http.addHeader("Content-Type", "application/json");
  http.setTimeout(HTTP_TIMEOUT_PLAN_MS);
  Serial.println("[/plan] requesting (may take up to 60s)...");
  int code = http.POST(payload);

  if (code != 200) {
    Serial.printf("[/plan] HTTP %d - %s\n", code, httpErrorHint(code));
    http.end();
    setRgbState(RGB_OFFLINE);
    return false;
  }

  // Parse only the fields we need on-device; the full plan + trace are shown
  // on the PC web panel (the board has no screen).
  JsonDocument resp;
  DeserializationError err = deserializeJson(resp, http.getStream());
  http.end();
  if (err) {
    Serial.printf("[/plan] JSON parse error: %s\n", err.c_str());
    return false;
  }

  // Cache the proposed actions for the /execute confirmation step.
  g_proposedActions.clear();
  JsonArray out = g_proposedActions.to<JsonArray>();
  JsonArray actions = resp["routine"]["actions"].as<JsonArray>();
  for (JsonObject a : actions) {
    JsonObject dst = out.add<JsonObject>();
    dst["device"] = a["device"];
    dst["command"] = a["command"];
    dst["value"] = a["value"];
  }
  g_hasProposal = out.size() > 0;

  Serial.printf("[/plan] proposed %d action(s) - awaiting confirmation\n", (int)out.size());
  // Log the read-only guard pre-check so a rejected action is visible on serial.
  JsonArray precheck = resp["precheck"].as<JsonArray>();
  for (JsonObject p : precheck) {
    Serial.printf("  precheck %s.%s -> %s (%s)\n",
                  (const char*)p["device"], (const char*)p["command"],
                  p["accepted"] ? "accepted" : "REJECTED",
                  (const char*)p["reason"]);
  }

  setRgbState(g_hasProposal ? RGB_READY : RGB_IDLE);
  return g_hasProposal;
}

// ---------------------------------------------------------------------------
// POST /execute  (run the human-confirmed subset)
// ---------------------------------------------------------------------------
static bool confirmAndExecute() {
  if (!g_hasProposal) return false;
  if (!connectWifi()) return false;

  JsonDocument body;
  body["actions"] = g_proposedActions.as<JsonArray>();

  String payload;
  serializeJson(body, payload);

  HTTPClient http;
  http.begin(executeUrl());
  http.addHeader("Content-Type", "application/json");
  http.setTimeout(HTTP_TIMEOUT_EXECUTE_MS);
  int code = http.POST(payload);

  if (code != 200) {
    Serial.printf("[/execute] HTTP %d - %s\n", code, httpErrorHint(code));
    http.end();
    setRgbState(RGB_OFFLINE);
    return false;
  }

  JsonDocument resp;
  DeserializationError err = deserializeJson(resp, http.getStream());
  http.end();
  if (err) {
    Serial.printf("[/execute] JSON parse error: %s\n", err.c_str());
    return false;
  }

  bool anyRejected = false;
  JsonArray execution = resp["execution"].as<JsonArray>();
  for (JsonObject e : execution) {
    bool accepted = e["accepted"];
    anyRejected = anyRejected || !accepted;
    Serial.printf("  exec %s.%s -> %s\n",
                  (const char*)e["device"], (const char*)e["command"],
                  accepted ? "accepted" : "REJECTED by edge guard");
  }

  g_hasProposal = false;
  g_proposedActions.clear();

  // If the edge guard blocked any action, flash red to surface the boundary.
  setRgbState(anyRejected ? RGB_REJECTED : RGB_READY);
  return !anyRejected;
}

// ---------------------------------------------------------------------------
// Serial test trigger - lets automation exercise the hardware HTTP path
// ---------------------------------------------------------------------------
static void printSerialTestHelp() {
  Serial.println("[serial] test commands: homecue:plan [0|1|2], homecue:speaker-regs, homecue:speaker-test [seconds] [all|both|left|right|sweep] [volume<=32] [amplitude<=5000] [buffer|sample|sample32|sample32bclk] [regs] [mic], homecue:voice-chat [seconds], homecue:voice-chat-ws [seconds], homecue:voice-chat-session [turns] [seconds], homecue:voice-chat-ws-session [turns] [seconds], homecue:reminders, homecue:voice-chat-reset, homecue:execute, homecue:reject, homecue:health, homecue:voice-command-window");
}

static bool parseSerialCommandIndex(String value, int& outIndex) {
  value.trim();
  if (value.length() != 1) return false;

  char digit = value.charAt(0);
  if (digit < '0' || digit > '9') return false;

  int parsed = digit - '0';
  if (parsed < 0 || parsed >= COMMAND_COUNT) return false;

  outIndex = parsed;
  return true;
}

static bool parseSpeakerTestMode(String value, uint8_t& outMode) {
  value.trim();
  value.toLowerCase();
  if (value.length() == 0 || value == "all") {
    outMode = SPEAKER_TEST_ALL;
    return true;
  }
  if (value == "both" || value == "stereo") {
    outMode = SPEAKER_TEST_BOTH;
    return true;
  }
  if (value == "left" || value == "l") {
    outMode = SPEAKER_TEST_LEFT;
    return true;
  }
  if (value == "right" || value == "r") {
    outMode = SPEAKER_TEST_RIGHT;
    return true;
  }
  if (value == "sweep") {
    outMode = SPEAKER_TEST_SWEEP;
    return true;
  }
  return false;
}

static bool parseSpeakerTestWriteMode(String value, uint8_t& outWriteMode) {
  value.trim();
  value.toLowerCase();
  if (value.length() == 0 || value == "buffer") {
    outWriteMode = SPEAKER_TEST_WRITE_BUFFER;
    return true;
  }
  if (value == "sample") {
    outWriteMode = SPEAKER_TEST_WRITE_SAMPLE;
    return true;
  }
  if (value == "sample32" || value == "idf32" || value == "official32") {
    outWriteMode = SPEAKER_TEST_WRITE_SAMPLE32;
    return true;
  }
  if (value == "sample32bclk" || value == "idf32bclk" || value == "official32bclk" || value == "bclk32") {
    outWriteMode = SPEAKER_TEST_WRITE_SAMPLE32_BCLK;
    return true;
  }
  return false;
}

static String nextToken(String& text) {
  text.trim();
  if (text.length() == 0) {
    return "";
  }
  int splitAt = text.indexOf(' ');
  if (splitAt < 0) {
    String token = text;
    text = "";
    token.trim();
    return token;
  }

  String token = text.substring(0, splitAt);
  text = text.substring(splitAt + 1);
  token.trim();
  return token;
}

static void handleSerialTestLine(String line) {
  line.trim();
  if (line.length() == 0) return;

  if (line == "homecue:help") {
    printSerialTestHelp();
    return;
  }

  if (line == "homecue:health") {
    Serial.println("[serial] HEALTH");
    checkHealth();
    return;
  }

  if (line == "homecue:reminders") {
    Serial.println("[serial] REMINDERS");
    scheduleNextReminderPoll(REMINDER_AUTO_POLL_INTERVAL_MS);
    if (!pollAndPlayDueReminder()) {
      Serial.println("[serial] REMINDERS failed");
    }
    return;
  }

  if (line == "homecue:voice-command-window") {
#if ENABLE_ESP_SR
    Serial.println("[serial] VOICE COMMAND WINDOW");
    espSrForceCommandWindow();
#else
    Serial.println("[serial] VOICE COMMAND WINDOW unavailable - rebuild with ENABLE_ESP_SR=1");
#endif
    return;
  }

  if (line == "homecue:voice-chat-reset") {
    g_voiceChatSessionId = "";
    Serial.println("[serial] VOICE CHAT SESSION reset");
    return;
  }

  if (line == "homecue:speaker-regs") {
#if ENABLE_ESP_SR
    Serial.println("[serial] SPEAKER REGS");
    dumpSpeakerCodecRegisters("[serial]");
#else
    Serial.println("[serial] SPEAKER REGS unavailable - rebuild with ENABLE_ESP_SR=1");
#endif
    return;
  }

  if (line.startsWith("homecue:speaker-test")) {
#if ENABLE_ESP_SR
    String requested = line.substring(strlen("homecue:speaker-test"));
    requested.trim();
    int seconds = SPEAKER_TEST_DEFAULT_SECONDS;
    uint8_t mode = SPEAKER_TEST_ALL;
    uint8_t volume = SPEAKER_TEST_VOLUME;
    int16_t amplitude = SPEAKER_TEST_AMPLITUDE;
    uint8_t writeMode = SPEAKER_TEST_WRITE_BUFFER;
    bool dumpRegisters = false;
    bool micProbe = false;
    if (requested.length() > 0) {
      String secondsText = nextToken(requested);
      String modeText = nextToken(requested);
      secondsText.trim();
      modeText.trim();
      seconds = secondsText.toInt();
      if (seconds < SPEAKER_TEST_MIN_SECONDS || seconds > SPEAKER_TEST_MAX_SECONDS) {
        Serial.printf("[serial] speaker-test seconds must be %u..%u\n",
                      SPEAKER_TEST_MIN_SECONDS, SPEAKER_TEST_MAX_SECONDS);
        printSerialTestHelp();
        return;
      }
      if (!parseSpeakerTestMode(modeText, mode)) {
        Serial.printf("[serial] speaker-test mode invalid: %s\n", modeText.c_str());
        printSerialTestHelp();
        return;
      }
      String volumeText = nextToken(requested);
      if (volumeText.length() > 0) {
        int parsedVolume = volumeText.toInt();
        if (parsedVolume < 0 || parsedVolume > SPEAKER_TEST_MAX_VOLUME) {
          Serial.printf("[serial] speaker-test volume must be 0..%u\n", SPEAKER_TEST_MAX_VOLUME);
          printSerialTestHelp();
          return;
        }
        volume = (uint8_t)parsedVolume;
      }
      String amplitudeText = nextToken(requested);
      if (amplitudeText.length() > 0) {
        int parsedAmplitude = amplitudeText.toInt();
        if (parsedAmplitude < 0 || parsedAmplitude > SPEAKER_TEST_MAX_AMPLITUDE) {
          Serial.printf("[serial] speaker-test amplitude must be 0..%d\n", SPEAKER_TEST_MAX_AMPLITUDE);
          printSerialTestHelp();
          return;
        }
        amplitude = (int16_t)parsedAmplitude;
      }
      String writeText = nextToken(requested);
      if (writeText.length() > 0) {
        if (!parseSpeakerTestWriteMode(writeText, writeMode)) {
          Serial.printf("[serial] speaker-test write mode invalid: %s\n", writeText.c_str());
          printSerialTestHelp();
          return;
        }
      }
      while (requested.length() > 0) {
        String diagText = nextToken(requested);
        diagText.toLowerCase();
        if (diagText == "regs" || diagText == "registers") {
          dumpRegisters = true;
        } else if (diagText == "mic" || diagText == "acoustic") {
          micProbe = true;
        } else {
          Serial.printf("[serial] speaker-test diag option invalid: %s\n", diagText.c_str());
          printSerialTestHelp();
          return;
        }
      }
    }

    Serial.printf("[serial] SPEAKER TEST -> %ds mode=%s volume=%u amplitude=%d write=%s regs=%s mic=%s\n",
                  seconds,
                  speakerTestModeName(mode),
                  volume,
                  amplitude,
                  speakerTestWriteModeName(writeMode),
                  dumpRegisters ? "yes" : "no",
                  micProbe ? "yes" : "no");
    if (!playSpeakerTestTone((uint8_t)seconds, mode, volume, amplitude, writeMode, dumpRegisters, micProbe)) {
      Serial.println("[serial] SPEAKER TEST failed");
    }
#else
    Serial.println("[serial] SPEAKER TEST unavailable - rebuild with ENABLE_ESP_SR=1");
#endif
    return;
  }

  if (line.startsWith("homecue:voice-chat-ws-session")) {
#if ENABLE_ESP_SR
    String requested = line.substring(strlen("homecue:voice-chat-ws-session"));
    requested.trim();
    int turns = VOICE_CHAT_SESSION_TURNS;
    int seconds = VOICE_CHAT_RECORD_SECONDS;
    if (requested.length() > 0) {
      int space = requested.indexOf(' ');
      String turnText = space >= 0 ? requested.substring(0, space) : requested;
      turnText.trim();
      turns = turnText.toInt();
      if (space >= 0) {
        String secondText = requested.substring(space + 1);
        secondText.trim();
        if (secondText.length() > 0) {
          seconds = secondText.toInt();
        }
      }
      if (turns < 1 || turns > VOICE_CHAT_MAX_SESSION_TURNS) {
        Serial.printf("[serial] voice-chat-ws-session turns must be 1..%u\n", VOICE_CHAT_MAX_SESSION_TURNS);
        printSerialTestHelp();
        return;
      }
      if (seconds < VOICE_CHAT_MIN_SECONDS || seconds > VOICE_CHAT_MAX_SECONDS) {
        Serial.printf("[serial] voice-chat-ws-session seconds must be %u..%u\n",
                      VOICE_CHAT_MIN_SECONDS, VOICE_CHAT_MAX_SECONDS);
        printSerialTestHelp();
        return;
      }
    }

    Serial.printf("[serial] VOICE CHAT WS SESSION -> %d turn(s), %ds each\n", turns, seconds);
    if (!recordAndPostVoiceChatWsSession((uint8_t)turns, (uint8_t)seconds)) {
      Serial.println("[serial] VOICE CHAT WS SESSION failed");
    }
#else
    Serial.println("[serial] VOICE CHAT WS SESSION unavailable - rebuild with ENABLE_ESP_SR=1");
#endif
    return;
  }

  if (line.startsWith("homecue:voice-chat-ws")) {
#if ENABLE_ESP_SR
    String requested = line.substring(strlen("homecue:voice-chat-ws"));
    requested.trim();
    int seconds = VOICE_CHAT_RECORD_SECONDS;
    if (requested.length() > 0) {
      seconds = requested.toInt();
      if (seconds < VOICE_CHAT_MIN_SECONDS || seconds > VOICE_CHAT_MAX_SECONDS) {
        Serial.printf("[serial] voice-chat-ws seconds must be %u..%u\n",
                      VOICE_CHAT_MIN_SECONDS, VOICE_CHAT_MAX_SECONDS);
        printSerialTestHelp();
        return;
      }
    }

    Serial.printf("[serial] VOICE CHAT WS -> %ds\n", seconds);
    if (!recordAndPostVoiceChatWs((uint8_t)seconds, &g_voiceChatSessionId)) {
      Serial.println("[serial] VOICE CHAT WS failed");
    }
#else
    Serial.println("[serial] VOICE CHAT WS unavailable - rebuild with ENABLE_ESP_SR=1");
#endif
    return;
  }

  if (line.startsWith("homecue:voice-chat-session")) {
#if ENABLE_ESP_SR
    String requested = line.substring(strlen("homecue:voice-chat-session"));
    requested.trim();
    int turns = VOICE_CHAT_SESSION_TURNS;
    int seconds = VOICE_CHAT_RECORD_SECONDS;
    if (requested.length() > 0) {
      int space = requested.indexOf(' ');
      String turnText = space >= 0 ? requested.substring(0, space) : requested;
      turnText.trim();
      turns = turnText.toInt();
      if (space >= 0) {
        String secondText = requested.substring(space + 1);
        secondText.trim();
        if (secondText.length() > 0) {
          seconds = secondText.toInt();
        }
      }
      if (turns < 1 || turns > VOICE_CHAT_MAX_SESSION_TURNS) {
        Serial.printf("[serial] voice-chat-session turns must be 1..%u\n", VOICE_CHAT_MAX_SESSION_TURNS);
        printSerialTestHelp();
        return;
      }
      if (seconds < VOICE_CHAT_MIN_SECONDS || seconds > VOICE_CHAT_MAX_SECONDS) {
        Serial.printf("[serial] voice-chat-session seconds must be %u..%u\n",
                      VOICE_CHAT_MIN_SECONDS, VOICE_CHAT_MAX_SECONDS);
        printSerialTestHelp();
        return;
      }
    }

    Serial.printf("[serial] VOICE CHAT SESSION -> %d turn(s), %ds each\n", turns, seconds);
    recordAndPostVoiceChatSession((uint8_t)turns, (uint8_t)seconds);
#else
    Serial.println("[serial] VOICE CHAT SESSION unavailable - rebuild with ENABLE_ESP_SR=1");
#endif
    return;
  }

  if (line.startsWith("homecue:voice-chat")) {
#if ENABLE_ESP_SR
    String requested = line.substring(strlen("homecue:voice-chat"));
    requested.trim();
    int seconds = VOICE_CHAT_RECORD_SECONDS;
    if (requested.length() > 0) {
      seconds = requested.toInt();
      if (seconds < VOICE_CHAT_MIN_SECONDS || seconds > VOICE_CHAT_MAX_SECONDS) {
        Serial.printf("[serial] voice-chat seconds must be %u..%u\n",
                      VOICE_CHAT_MIN_SECONDS, VOICE_CHAT_MAX_SECONDS);
        printSerialTestHelp();
        return;
      }
    }

    Serial.printf("[serial] VOICE CHAT -> %ds\n", seconds);
    recordAndPostVoiceChat((uint8_t)seconds, &g_voiceChatSessionId);
#else
    Serial.println("[serial] VOICE CHAT unavailable - rebuild with ENABLE_ESP_SR=1");
#endif
    return;
  }

  if (line.startsWith("homecue:plan")) {
    String requested = line.substring(strlen("homecue:plan"));
    requested.trim();

    if (requested.length() > 0) {
      int requestedIndex = 0;
      if (!parseSerialCommandIndex(requested, requestedIndex)) {
        Serial.printf("[serial] unknown command index: %s\n", requested.c_str());
        printSerialTestHelp();
        return;
      }
      g_commandIndex = requestedIndex;
    }

    Serial.printf("[serial] PLAN -> %s\n", COMMAND_WORDS[g_commandIndex].label);
    setRgbState(RGB_LISTENING);
    requestPlan(COMMAND_WORDS[g_commandIndex].prompt);
    return;
  }

  if (line == "homecue:next") {
    g_commandIndex = (g_commandIndex + 1) % COMMAND_COUNT;
    Serial.printf("[serial] NEXT -> %s\n", COMMAND_WORDS[g_commandIndex].label);
    return;
  }

  if (line == "homecue:execute" || line == "homecue:confirm") {
    Serial.println("[serial] CONFIRM");
    confirmAndExecute();
    return;
  }

  if (line == "homecue:reject") {
    Serial.println("[serial] REJECT - discarding proposal");
    g_hasProposal = false;
    g_proposedActions.clear();
    setRgbState(RGB_REJECTED);
    return;
  }

  Serial.printf("[serial] ignored command: %s\n", line.c_str());
  printSerialTestHelp();
}

static void pollSerialTestCommand() {
  while (Serial.available() > 0) {
    char ch = (char)Serial.read();
    if (ch == '\r') {
      continue;
    }
    if (ch == '\n') {
      handleSerialTestLine(g_serialLine);
      g_serialLine = "";
      continue;
    }

    if (g_serialLine.length() >= 96) {
      Serial.println("[serial] command too long; clearing buffer");
      g_serialLine = "";
      continue;
    }

    g_serialLine += ch;
  }
}

static void runBootSpeakerTestIfConfigured() {
#if HOMECUE_BOOT_SPEAKER_TEST
#if ENABLE_ESP_SR
  uint8_t seconds = constrain(HOMECUE_BOOT_SPEAKER_TEST_SECONDS,
                              SPEAKER_TEST_MIN_SECONDS,
                              SPEAKER_TEST_MAX_SECONDS);
  uint8_t mode = HOMECUE_BOOT_SPEAKER_TEST_MODE;
  if (mode > SPEAKER_TEST_ALL) {
    Serial.printf("[speaker-test] boot auto-test mode invalid=%u, using all\n", mode);
    mode = SPEAKER_TEST_ALL;
  }
  Serial.printf("[speaker-test] boot auto-test enabled seconds=%u mode=%s\n",
                seconds, speakerTestModeName(mode));
  if (!playSpeakerTestTone(seconds, mode)) {
    Serial.println("[speaker-test] boot auto-test failed");
  }
#else
  Serial.println("[speaker-test] boot auto-test unavailable - rebuild with ENABLE_ESP_SR=1");
#endif
#endif
}

static void addDiagSpeakerPowerAmpStatus(JsonDocument& body) {
  bool enabled = false;
  uint8_t inputReg = 0;
  uint8_t outputReg = 0;
  uint8_t configReg = 0;
  body["speaker_output_enabled"] = HOMECUE_SPEAKER_OUTPUT_ENABLED == 1;
  body["speaker_pa_enabled"] = g_speakerPaEnabled;
  if (readSpeakerPowerAmpState(enabled) &&
      readSpeakerPowerAmpRegisters(inputReg, outputReg, configReg)) {
    body["speaker_pa_readback"] = enabled ? "high" : "low";
    body["speaker_pa_input_reg"] = inputReg;
    body["speaker_pa_output_reg"] = outputReg;
    body["speaker_pa_config_reg"] = configReg;
  } else {
    body["speaker_pa_readback"] = "unavailable";
  }
}

static void handleDiagHttpHealth() {
  JsonDocument body;
  body["status"] = "ok";
  body["device"] = "esp32-audio-board";
  body["wifi_ip"] = WiFi.localIP().toString();
  body["esp_sr_enabled"] = ENABLE_ESP_SR == 1;
  addDiagSpeakerPowerAmpStatus(body);
#if ENABLE_ESP_SR
  body["i2s_ready"] = g_srI2sReady;
  body["es8311_ready"] = g_es8311Ready;
  body["esp_sr_started"] = g_espSrStarted;
#else
  body["i2s_ready"] = false;
  body["es8311_ready"] = false;
  body["esp_sr_started"] = false;
#endif

  String payload;
  serializeJson(body, payload);
  g_diagServer.send(200, "application/json", payload);
}

static uint8_t parseDiagSpeakerMode(String value) {
  uint8_t mode = SPEAKER_TEST_ALL;
  if (parseSpeakerTestMode(value, mode)) {
    return mode;
  }
  return SPEAKER_TEST_ALL;
}

static void handleDiagHttpSpeakerTest() {
#if ENABLE_ESP_SR
  uint8_t seconds = SPEAKER_TEST_DEFAULT_SECONDS;
  if (g_diagServer.hasArg("seconds")) {
    seconds = constrain(g_diagServer.arg("seconds").toInt(),
                        SPEAKER_TEST_MIN_SECONDS,
                        SPEAKER_TEST_MAX_SECONDS);
  }
  uint8_t mode = parseDiagSpeakerMode(g_diagServer.arg("mode"));
  uint8_t volume = SPEAKER_TEST_VOLUME;
  int16_t amplitude = SPEAKER_TEST_AMPLITUDE;
  uint8_t writeMode = SPEAKER_TEST_WRITE_BUFFER;
  bool dumpRegisters = false;
  bool micProbe = false;
  if (g_diagServer.hasArg("volume")) {
    volume = constrain(g_diagServer.arg("volume").toInt(), 0, SPEAKER_TEST_MAX_VOLUME);
  }
  if (g_diagServer.hasArg("amplitude")) {
    amplitude = constrain(g_diagServer.arg("amplitude").toInt(), 0, SPEAKER_TEST_MAX_AMPLITUDE);
  }
  String writeText = g_diagServer.arg("write");
  parseSpeakerTestWriteMode(writeText, writeMode);
  if (g_diagServer.hasArg("regs")) {
    String regs = g_diagServer.arg("regs");
    regs.toLowerCase();
    dumpRegisters = regs == "1" || regs == "true" || regs == "yes";
  }
  if (g_diagServer.hasArg("mic")) {
    String mic = g_diagServer.arg("mic");
    mic.toLowerCase();
    micProbe = mic == "1" || mic == "true" || mic == "yes";
  }
  Serial.printf("[diag-http] speaker-test -> %us mode=%s volume=%u amplitude=%d write=%s regs=%s mic=%s\n",
                seconds,
                speakerTestModeName(mode),
                volume,
                amplitude,
                speakerTestWriteModeName(writeMode),
                dumpRegisters ? "yes" : "no",
                micProbe ? "yes" : "no");
  bool ok = playSpeakerTestTone(seconds, mode, volume, amplitude, writeMode, dumpRegisters, micProbe);

  JsonDocument body;
  body["ok"] = ok;
  body["seconds"] = seconds;
  body["mode"] = speakerTestModeName(mode);
  body["volume"] = volume;
  body["amplitude"] = amplitude;
  body["write"] = speakerTestWriteModeName(writeMode);
  body["register_dump_to_serial"] = dumpRegisters;
  body["mic_probe_to_serial"] = micProbe;
  addDiagSpeakerPowerAmpStatus(body);
  body["human_audible_confirmation_required"] = true;
  body["speaker_output_enabled"] = HOMECUE_SPEAKER_OUTPUT_ENABLED == 1;
  String payload;
  serializeJson(body, payload);
  g_diagServer.send(ok ? 200 : 500, "application/json", payload);
#else
  g_diagServer.send(501, "application/json",
                    "{\"ok\":false,\"error\":\"rebuild with ENABLE_ESP_SR=1\"}");
#endif
}

static void startDiagHttpServerIfConfigured() {
#if HOMECUE_DIAG_HTTP_SERVER
  if (g_diagServerStarted || WiFi.status() != WL_CONNECTED) {
    return;
  }
  g_diagServer.on("/health", HTTP_GET, handleDiagHttpHealth);
  g_diagServer.on("/speaker-test", HTTP_GET, handleDiagHttpSpeakerTest);
  g_diagServer.onNotFound([]() {
    g_diagServer.send(404, "application/json", "{\"ok\":false,\"error\":\"not found\"}");
  });
  g_diagServer.begin();
  g_diagServerStarted = true;
  Serial.printf("[diag-http] ready http://%s/ speaker_output=%s speaker-test=/speaker-test?seconds=1&mode=both\n",
                WiFi.localIP().toString().c_str(),
                HOMECUE_SPEAKER_OUTPUT_ENABLED ? "enabled" : "disabled");
#endif
}

static void pollDiagHttpServer() {
#if HOMECUE_DIAG_HTTP_SERVER
  if (g_diagServerStarted) {
    g_diagServer.handleClient();
  }
#endif
}

// ---------------------------------------------------------------------------
// Arduino entry points
// ---------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("\n[HomeCue Edge] ESP32-S3-AUDIO-Board firmware booting...");
#if ENABLE_ESP_SR
  // Keep the "button-route" marker so the permanent key/serial fallback contract
  // (and the serial-log check) still holds; voice is additive, not a swap.
  Serial.println("[mode] button-route + ESP-SR voice command route (propose only)");
#else
  Serial.println("[mode] button-route MVP (no ESP-SR; voice disabled)");
#endif
  printSerialTestHelp();

  pinMode(PIN_BOOT, INPUT_PULLUP);

  g_tca9555Ok = initTca9555();
  Serial.printf("[keys] TCA9555 %s - KEY1=plan KEY2=confirm KEY3=reject BOOT=plan-fallback\n",
                g_tca9555Ok ? "OK" : "not detected (BOOT only)");
  if (g_tca9555Ok) {
    disableSpeakerPowerAmp();
  }

  // TODO[VENDOR]: RGB ring (GPIO38 WS2812 or TCA9555), ES7210 I2S, ESP-SR voice.

#if ENABLE_ESP_SR
  if (!espSrBegin()) {
    Serial.println("[esp-sr] voice route unavailable - use KEY1/BOOT or serial commands");
  }
#endif

  runBootSpeakerTestIfConfigured();

  setRgbState(RGB_IDLE);
  scheduleNextReminderPoll(REMINDER_AUTO_FIRST_POLL_DELAY_MS);
  if (connectWifi()) {
    checkHealth();
    startDiagHttpServerIfConfigured();
  }
}

void loop() {
  pollDiagHttpServer();

  // 0) Automation test trigger over USB serial.
  pollSerialTestCommand();

  // 1) Conversational voice chat trigger. This path never executes devices.
  if (pollVoiceChatRequest()) {
    Serial.println("[voice] wake auto chat");
    playVoiceChatWakeAck();
    if (!recordAndPostVoiceChatWsSession(VOICE_CHAT_SESSION_TURNS, VOICE_CHAT_RECORD_SECONDS)) {
      Serial.println("[voice] WS session failed - falling back to HTTP voice chat");
      recordAndPostVoiceChatSession(VOICE_CHAT_SESSION_TURNS, VOICE_CHAT_RECORD_SECONDS);
    }
  }

  // 2) Voice trigger (or fall back to the NEXT key cycling command words).
  int cmd = pollVoiceCommand();
  if (cmd >= 0 && cmd < COMMAND_COUNT) {
    g_commandIndex = cmd;
    setRgbState(RGB_LISTENING);
    Serial.printf("[voice] command: %s\n", COMMAND_WORDS[g_commandIndex].label);
    requestPlan(COMMAND_WORDS[g_commandIndex].prompt);
  }

  // 3) Physical human-in-the-loop keys.
  switch (readUserKey()) {
    case KEY_CONFIRM:
      Serial.println("[key] CONFIRM");
      confirmAndExecute();
      break;
    case KEY_REJECT:
      Serial.println("[key] REJECT - discarding proposal");
      g_hasProposal = false;
      g_proposedActions.clear();
      setRgbState(RGB_REJECTED);
      break;
    case KEY_NEXT:
      g_commandIndex = (g_commandIndex + 1) % COMMAND_COUNT;
      Serial.printf("[key] NEXT -> %s\n", COMMAND_WORDS[g_commandIndex].label);
      setRgbState(RGB_LISTENING);
      requestPlan(COMMAND_WORDS[g_commandIndex].prompt);
      break;
    case KEY_NONE:
    default:
      break;
  }

  // 4) Device-style background behavior: pull due reminders when idle.
  pollDueReminderIfIdle();

  delay(20);
}
