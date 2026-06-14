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
 * Voice route (optional): ESP-SR + vendor TCA9555 RGB driver — see TODO[VENDOR].
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
 *   I2C bus        : SDA=GPIO11, SCL=GPIO10   (PCF85063 RTC + TCA9555 expander)
 *   RGB ring (7x), user keys: via TCA9555 expander (see vendor driver)
 */

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <Wire.h>
#include <ArduinoJson.h>

#include "secrets.h"  // copy secrets.h.example -> secrets.h and fill in (gitignored)

// ---------------------------------------------------------------------------
// Types — MUST be before any function definition (Arduino .ino auto-prototypes)
// ---------------------------------------------------------------------------
enum RgbState { RGB_IDLE, RGB_LISTENING, RGB_THINKING, RGB_READY, RGB_REJECTED, RGB_OFFLINE };
enum UserKey { KEY_NONE, KEY_CONFIRM, KEY_REJECT, KEY_NEXT };

struct CommandWord {
  const char* label;   // human label / what the user says
  const char* prompt;  // preset natural-language prompt sent to /plan
};

// ---------------------------------------------------------------------------
// Button-route MVP — GPIO / TCA9555 (no vendor libraries)
// ---------------------------------------------------------------------------
// I2C: SDA=GPIO11, SCL=GPIO10. TCA9555 @ 0x20. User keys on expander pins 9/10/11
// (active low, inverted in hardware). BOOT = GPIO0 (active low).
static constexpr uint8_t I2C_SDA = 11;
static constexpr uint8_t I2C_SCL = 10;
static constexpr uint8_t TCA9555_ADDR = 0x20;
static constexpr uint8_t PIN_BOOT = 0;
static constexpr uint8_t KEY_PIN_PLAN = 9;    // KEY1 -> trigger /plan
static constexpr uint8_t KEY_PIN_CONFIRM = 10; // KEY2 -> POST /execute
static constexpr uint8_t KEY_PIN_REJECT = 11;  // KEY3 -> discard proposal

static constexpr uint32_t KEY_COOLDOWN_MS = 400;

static bool g_tca9555Ok = false;
static uint32_t g_lastKeyMs = 0;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// Endpoints on the PC FastAPI gateway. PC_HOST / PC_PORT come from secrets.h.
static String planUrl() { return String("http://") + PC_HOST + ":" + PC_PORT + "/plan"; }
static String executeUrl() { return String("http://") + PC_HOST + ":" + PC_PORT + "/execute"; }
static String healthUrl() { return String("http://") + PC_HOST + ":" + PC_PORT + "/health"; }

// /plan with agent_mode can take 20–60s (MiMo/Qwen); default HTTPClient timeout is too short.
static constexpr uint32_t HTTP_TIMEOUT_PLAN_MS = 120000;
static constexpr uint32_t HTTP_TIMEOUT_EXECUTE_MS = 15000;
static constexpr uint32_t HTTP_TIMEOUT_HEALTH_MS = 10000;

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

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------

// Actions proposed by the last /plan call, awaiting human confirmation.
// Stored as a JSON document so we can forward the confirmed subset verbatim.
static JsonDocument g_proposedActions;  // holds an array of {device,command,value}
static bool g_hasProposal = false;
static int g_commandIndex = 0;

// ---------------------------------------------------------------------------
// TCA9555 minimal driver (button route — no vendor library)
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

static bool initTca9555() {
  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(100000);
  delay(10);
  // Config port 0 + 1 as inputs (1 = input on TCA9555)
  if (!tca9555Write(0x06, 0xFF) || !tca9555Write(0x07, 0xFF)) return false;
  uint8_t probe = 0;
  return tca9555Read(0x01, probe);
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
// User keys — button route: TCA9555 KEY1/2/3 + BOOT fallback
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
// Voice trigger (TODO[VENDOR]: ESP-SR WakeNet wake + MultiNet command id)
// ---------------------------------------------------------------------------
// Return a command-word index [0..COMMAND_COUNT-1] when the vendor recognizer
// fires, or -1 when nothing was recognized this loop iteration.
static int pollVoiceCommand() {
  // TODO[VENDOR]: feed ES7210 dual-mic I2S frames into WakeNet/MultiNet from the
  // example and translate the recognized command id into our COMMAND_WORDS index.
  return -1;
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
    Serial.printf("[/health] HTTP %d — %s\n", code, httpErrorHint(code));
  } else {
    Serial.printf("[/health] HTTP %d\n", code);
  }
  http.end();
  return code == 200;
}

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
    Serial.printf("[/plan] HTTP %d — %s\n", code, httpErrorHint(code));
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
    Serial.printf("[/execute] HTTP %d — %s\n", code, httpErrorHint(code));
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
// Arduino entry points
// ---------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("\n[HomeCue Edge] ESP32-S3-AUDIO-Board firmware booting...");
  Serial.println("[mode] button-route MVP (no ESP-SR; voice disabled)");

  pinMode(PIN_BOOT, INPUT_PULLUP);

  g_tca9555Ok = initTca9555();
  Serial.printf("[keys] TCA9555 %s — KEY1=plan KEY2=confirm KEY3=reject BOOT=plan-fallback\n",
                g_tca9555Ok ? "OK" : "not detected (BOOT only)");

  // TODO[VENDOR]: RGB ring (GPIO38 WS2812 or TCA9555), ES7210 I2S, ESP-SR voice.

  setRgbState(RGB_IDLE);
  if (connectWifi()) {
    checkHealth();
  }
}

void loop() {
  // 1) Voice trigger (or fall back to the NEXT key cycling command words).
  int cmd = pollVoiceCommand();
  if (cmd >= 0 && cmd < COMMAND_COUNT) {
    g_commandIndex = cmd;
    setRgbState(RGB_LISTENING);
    Serial.printf("[voice] command: %s\n", COMMAND_WORDS[g_commandIndex].label);
    requestPlan(COMMAND_WORDS[g_commandIndex].prompt);
  }

  // 2) Physical human-in-the-loop keys.
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

  delay(20);
}
