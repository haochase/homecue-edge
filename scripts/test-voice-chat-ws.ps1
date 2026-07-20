param(
  [string]$WsUrl = "ws://127.0.0.1:8723/voice-chat/ws",
  [string]$Text = "Hello XiaoQian, confirm WebSocket voice chat.",
  [string]$ApiToken = "",
  [string]$UserId = "",
  [string]$DeviceId = "",
  [ValidateSet("text", "pcm_s16le", "wav")]
  [string]$TurnMode = "text",
  [string]$AudioText = "",
  [string]$VoiceName = "",
  [string]$ResultJsonPath = ".\assets\demo\voice-chat-ws-test.json",
  [ValidateSet("url", "websocket_binary", "websocket_binary_chunked", "websocket_binary_stream")]
  [string]$ReplyAudioTransport = "websocket_binary_stream",
  [switch]$ReplyAudio,
  [switch]$RequireReplyAudio,
  [switch]$RequireRecognizedAudio,
  [switch]$Required
)

$ErrorActionPreference = "Stop"

function New-ParentDirectory {
  param([string]$Path)
  $Parent = Split-Path -Parent $Path
  if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Path $Parent | Out-Null
  }
}

function Resolve-OutputPath {
  param([string]$Path)
  $Parent = Split-Path -Parent $Path
  if ($Parent) {
    return (Join-Path (Resolve-Path -LiteralPath $Parent).Path (Split-Path -Leaf $Path))
  }
  return (Join-Path (Get-Location).Path $Path)
}

New-ParentDirectory -Path $ResultJsonPath
Add-Type -AssemblyName System.Web

function Add-AccessTokenToWsUrl {
  param(
    [string]$Url,
    [string]$Token
  )

  if (-not $Token) {
    return $Url
  }
  $Builder = [System.UriBuilder]::new([Uri]$Url)
  $Pairs = [System.Web.HttpUtility]::ParseQueryString($Builder.Query)
  $Pairs["access_token"] = $Token
  $Builder.Query = $Pairs.ToString()
  return $Builder.Uri.AbsoluteUri
}

$Python = ".\apps\api\.venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $Python)) {
  $Python = "python"
}

$EffectiveWsUrl = Add-AccessTokenToWsUrl -Url $WsUrl -Token $ApiToken

$env:HOMECUE_WS_URL = $EffectiveWsUrl
$env:HOMECUE_WS_TEXT = $Text
$env:HOMECUE_WS_API_TOKEN_PROVIDED = if ($ApiToken) { "1" } else { "0" }
$env:HOMECUE_WS_USER_ID = $UserId
$env:HOMECUE_WS_DEVICE_ID = $DeviceId
$env:HOMECUE_WS_TURN_MODE = $TurnMode
$env:HOMECUE_WS_AUDIO_TEXT = $AudioText
$env:HOMECUE_WS_VOICE_NAME = $VoiceName
$env:HOMECUE_WS_REPLY_AUDIO = if ($ReplyAudio) { "1" } else { "0" }
$env:HOMECUE_WS_REPLY_AUDIO_TRANSPORT = $ReplyAudioTransport
$env:HOMECUE_WS_REQUIRE_REPLY_AUDIO = if ($RequireReplyAudio) { "1" } else { "0" }
$env:HOMECUE_WS_REQUIRE_RECOGNIZED_AUDIO = if ($RequireRecognizedAudio) { "1" } else { "0" }
$OutputResultJsonPath = Resolve-OutputPath -Path $ResultJsonPath
if (Test-Path -LiteralPath $OutputResultJsonPath) {
  Remove-Item -LiteralPath $OutputResultJsonPath -Force
}
$env:HOMECUE_WS_RESULT_JSON = $OutputResultJsonPath
$env:PYTHONIOENCODING = "utf-8"

$Script = @'
import asyncio
import json
import math
import os
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

try:
    import websockets
except Exception as error:
    print(json.dumps({"status": "failed", "error": f"websockets import failed: {error}"}))
    sys.exit(2)


async def receive_json(websocket, timeout=60):
    message = await asyncio.wait_for(websocket.recv(), timeout=timeout)
    if isinstance(message, bytes):
        return {"type": "binary", "bytes": len(message)}
    return json.loads(message)


def synthesize_wav(text, voice_name=""):
    if not text.strip() or os.name != "nt":
        return b""

    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
        wav_path = tmp.name
    env = os.environ.copy()
    env["HOMECUE_WS_AUDIO_TTS_TEXT"] = text
    env["HOMECUE_WS_AUDIO_TTS_WAV"] = wav_path
    env["HOMECUE_WS_AUDIO_TTS_VOICE"] = voice_name
    script = (
        "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
        "Add-Type -AssemblyName System.Speech; "
        "$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo("
        "16000, "
        "[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, "
        "[System.Speech.AudioFormat.AudioChannel]::Mono"
        "); "
        "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
        "try { "
        "if ($env:HOMECUE_WS_AUDIO_TTS_VOICE) { "
        "try { $s.SelectVoice($env:HOMECUE_WS_AUDIO_TTS_VOICE) } catch {} "
        "} "
        "$s.SetOutputToWaveFile($env:HOMECUE_WS_AUDIO_TTS_WAV, $fmt); "
        "$s.Speak($env:HOMECUE_WS_AUDIO_TTS_TEXT) "
        "} finally { $s.Dispose() }"
    )
    try:
        subprocess.run(
            ["powershell", "-NoProfile", "-Command", script],
            check=True,
            env=env,
            timeout=60,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        return Path(wav_path).read_bytes()
    except (OSError, subprocess.SubprocessError):
        return b""
    finally:
        try:
            Path(wav_path).unlink(missing_ok=True)
        except OSError:
            pass


def extract_wav_info(wav_bytes):
    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
        tmp.write(wav_bytes)
        wav_path = tmp.name
    try:
        with wave.open(wav_path, "rb") as wav:
            channels = wav.getnchannels()
            sample_rate = wav.getframerate()
            sample_width = wav.getsampwidth()
            frames = wav.readframes(wav.getnframes())
        return {
            "channels": channels,
            "sampleRate": sample_rate,
            "sampleWidth": sample_width,
            "pcm": frames,
        }
    finally:
        try:
            Path(wav_path).unlink(missing_ok=True)
        except OSError:
            pass


def make_fallback_pcm(sample_rate=16000, seconds=2):
    sample_count = sample_rate * seconds
    samples = bytearray()
    for index in range(sample_count):
        # A soft 440 Hz tone is enough to prove binary PCM framing when TTS is unavailable.
        value = int(6000 * math.sin(2 * math.pi * 440 * index / sample_rate))
        samples.extend(struct.pack("<h", value))
    return bytes(samples)


def prepare_audio_turn(turn_mode, audio_text, voice_name):
    if turn_mode == "text":
        return {
            "format": "wav",
            "sample_rate": 16000,
            "channels": 1,
            "payload": b"",
            "source": "none",
            "wavBytes": 0,
        }

    audio_text = audio_text.strip()
    wav_bytes = synthesize_wav(audio_text, voice_name) if audio_text else b""
    if turn_mode == "wav":
        if not wav_bytes:
            raise RuntimeError("WAV turn mode requires Windows TTS audio generation.")
        info = extract_wav_info(wav_bytes)
        return {
            "format": "wav",
            "sample_rate": info["sampleRate"],
            "channels": info["channels"],
            "payload": wav_bytes,
            "source": "windows_tts",
            "wavBytes": len(wav_bytes),
        }

    if wav_bytes:
        info = extract_wav_info(wav_bytes)
        if info["sampleWidth"] != 2:
            raise RuntimeError(f"Expected 16-bit WAV, got sample width {info['sampleWidth']}.")
        return {
            "format": "pcm_s16le",
            "sample_rate": info["sampleRate"],
            "channels": info["channels"],
            "payload": info["pcm"],
            "source": "windows_tts",
            "wavBytes": len(wav_bytes),
        }

    return {
        "format": "pcm_s16le",
        "sample_rate": 16000,
        "channels": 1,
        "payload": make_fallback_pcm(),
        "source": "fallback_tone",
        "wavBytes": 0,
    }


async def main():
    url = os.environ["HOMECUE_WS_URL"]
    text = os.environ["HOMECUE_WS_TEXT"]
    user_id = os.environ.get("HOMECUE_WS_USER_ID", "")
    device_id = os.environ.get("HOMECUE_WS_DEVICE_ID", "")
    turn_mode = os.environ.get("HOMECUE_WS_TURN_MODE", "text")
    audio_text = os.environ.get("HOMECUE_WS_AUDIO_TEXT", "") or text
    voice_name = os.environ.get("HOMECUE_WS_VOICE_NAME", "")
    reply_audio = os.environ.get("HOMECUE_WS_REPLY_AUDIO") == "1"
    reply_audio_transport = os.environ.get("HOMECUE_WS_REPLY_AUDIO_TRANSPORT", "websocket_binary_stream")
    require_reply_audio = os.environ.get("HOMECUE_WS_REQUIRE_REPLY_AUDIO") == "1"
    require_recognized_audio = os.environ.get("HOMECUE_WS_REQUIRE_RECOGNIZED_AUDIO") == "1"
    result_json_path = os.environ.get("HOMECUE_WS_RESULT_JSON", "")
    api_token_provided = os.environ.get("HOMECUE_WS_API_TOKEN_PROVIDED") == "1"
    events = []
    audio_turn = prepare_audio_turn(turn_mode, audio_text, voice_name)
    binary_frame_count = 0

    async with websockets.connect(url, open_timeout=10, close_timeout=5) as websocket:
        await websocket.send(
            json.dumps(
                {
                    "type": "hello",
                    "version": 1,
                    "transport": "websocket",
                    "user_id": user_id,
                    "device_id": device_id,
                    "reply_audio": reply_audio,
                    "reply_audio_transport": reply_audio_transport,
                    "audio_params": {
                        "format": audio_turn["format"],
                        "sample_rate": audio_turn["sample_rate"],
                        "channels": audio_turn["channels"],
                        "frame_duration": 60,
                    },
                },
                ensure_ascii=False,
            )
        )
        events.append(await receive_json(websocket, timeout=10))

        await websocket.send(
            json.dumps(
                {
                    "type": "listen",
                    "state": "start",
                    "user_id": user_id,
                    "device_id": device_id,
                    "audio_params": {
                        "format": audio_turn["format"],
                        "sample_rate": audio_turn["sample_rate"],
                        "channels": audio_turn["channels"],
                        "frame_duration": 60,
                    },
                },
                ensure_ascii=False,
            )
        )
        events.append(await receive_json(websocket, timeout=10))

        if turn_mode == "text":
            partial_text = text[: max(1, len(text) // 2)]
            await websocket.send(
                json.dumps({"type": "listen", "state": "partial", "text": partial_text}, ensure_ascii=False)
            )
            events.append(await receive_json(websocket, timeout=10))

            await websocket.send(json.dumps({"type": "listen", "state": "final", "text": text}, ensure_ascii=False))
            events.append(await receive_json(websocket, timeout=10))
        else:
            payload = audio_turn["payload"]
            chunk_size = int(audio_turn["sample_rate"]) * int(audio_turn["channels"]) * 2 * 60 // 1000
            chunk_size = max(640, chunk_size)
            for offset in range(0, len(payload), chunk_size):
                await websocket.send(payload[offset : offset + chunk_size])
                binary_frame_count += 1
        await websocket.send(json.dumps({"type": "listen", "state": "stop"}))

        while True:
            event = await receive_json(websocket)
            events.append(event)
            if event.get("type") == "listen" and event.get("state") == "ready":
                break

    hello = next((event for event in events if event.get("type") == "hello"), {})
    partial_stt = next((event for event in events if event.get("type") == "stt" and event.get("state") == "partial"), {})
    final_stt = next(
        (
            event
            for event in reversed(events)
            if event.get("type") == "stt" and event.get("state") in {None, "final"}
        ),
        {},
    )
    no_match = next((event for event in events if event.get("type") == "stt" and event.get("state") == "no_match"), {})
    llm = next((event for event in events if event.get("type") == "llm" and event.get("state") == "stop"), {})
    tts_audio = next((event for event in events if event.get("type") == "tts" and event.get("state") == "audio"), {})
    tts_audio_done = next(
        (event for event in events if event.get("type") == "tts" and event.get("state") == "audio_done"),
        {},
    )
    ready = next((event for event in events if event.get("type") == "listen" and event.get("state") == "ready"), {})
    errors = [event for event in events if event.get("type") == "error"]
    downlink_binary_events = [event for event in events if event.get("type") == "binary"]
    downlink_binary_bytes = sum(int(event.get("bytes") or 0) for event in downlink_binary_events)
    session_id = hello.get("session_id") or ready.get("session_id") or ""

    checks = [
        {"name": "hello", "ok": hello.get("transport") == "websocket" and bool(session_id)},
        {"name": "user_id_echo", "ok": not user_id or hello.get("user_id") == user_id},
        {"name": "device_id_echo", "ok": not device_id or hello.get("device_id") == device_id},
        {"name": "feature_binary_wav", "ok": hello.get("features", {}).get("binary_wav") is True},
        {"name": "feature_binary_pcm_s16le", "ok": hello.get("features", {}).get("binary_pcm_s16le") is True},
        {"name": "feature_stt_partial", "ok": hello.get("features", {}).get("stt_partial") is True},
        {"name": "feature_opus_gap_declared", "ok": hello.get("features", {}).get("opus_stream") is False},
        {"name": "audio_sent", "ok": turn_mode == "text" or (len(audio_turn["payload"]) > 0 and binary_frame_count > 0)},
        {"name": "stt_partial", "ok": turn_mode != "text" or bool(partial_stt.get("text"))},
        {
            "name": "stt_final",
            "ok": (final_stt.get("text") == text if turn_mode == "text" else bool(final_stt.get("text")) or bool(no_match)),
        },
        {"name": "audio_no_match_recoverable", "ok": turn_mode == "text" or bool(final_stt.get("text")) or bool(no_match)},
        {
            "name": "recognized_audio_required",
            "ok": not require_recognized_audio or bool(final_stt.get("text")),
        },
        {"name": "llm_reply", "ok": bool(llm.get("text")) or bool(no_match)},
        {
            "name": "reply_audio",
            "ok": (
                not require_reply_audio
                or (
                    bool(tts_audio)
                    and bool(tts_audio_done)
                    and downlink_binary_bytes > 0
                    and tts_audio.get("provider") == "mimo"
                )
            ),
        },
        {"name": "ready", "ok": ready.get("turn_index") in {0, 1} and ready.get("session_id") == session_id},
        {"name": "no_errors", "ok": not errors},
    ]

    status = "passed" if all(check["ok"] for check in checks) else "failed"
    result = {
        "status": status,
        "url": url.split("?")[0],
        "apiTokenProvided": api_token_provided,
        "text": text,
        "turnMode": turn_mode,
        "audioText": audio_text,
        "audioSource": audio_turn["source"],
        "audioFormat": audio_turn["format"],
        "audioSampleRate": audio_turn["sample_rate"],
        "audioChannels": audio_turn["channels"],
        "binaryAudioBytes": len(audio_turn["payload"]),
        "binaryFrameCount": binary_frame_count,
        "audioResult": "recognized" if final_stt.get("text") else ("no_match" if no_match else "not_audio"),
        "userId": user_id,
        "deviceId": device_id,
        "replyAudioRequested": reply_audio,
        "replyAudioTransportRequested": reply_audio_transport,
        "replyAudioProvider": tts_audio.get("provider", ""),
        "replyAudioModel": tts_audio.get("model", ""),
        "replyAudioVoice": tts_audio.get("voice", ""),
        "replyAudioTransport": tts_audio.get("transport", ""),
        "replyAudioDoneTransport": tts_audio_done.get("transport", ""),
        "replyAudioBytes": tts_audio_done.get("bytes", 0),
        "replyAudioChunkCount": tts_audio_done.get("chunk_count", 0),
        "downlinkBinaryFrameCount": len(downlink_binary_events),
        "downlinkBinaryBytes": downlink_binary_bytes,
        "sessionId": session_id,
        "reply": llm.get("text", ""),
        "provider": llm.get("provider", ""),
        "turnIndex": ready.get("turn_index", 0),
        "checks": checks,
        "events": events,
    }
    if result_json_path:
        with open(result_json_path, "w", encoding="utf-8") as output:
            output.write(json.dumps(result, ensure_ascii=True, indent=2))
    print(
        json.dumps(
            {
                "status": status,
                "path": result_json_path,
                "provider": result["provider"],
                "sessionId": session_id,
                "turnIndex": result["turnIndex"],
            },
            ensure_ascii=True,
        )
    )
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except Exception as error:
        print(json.dumps({"status": "failed", "error": str(error)}))
        raise SystemExit(1)
'@

Write-Host "HomeCue Edge voice-chat WebSocket test"
Write-Host ("WS     : {0}" -f $WsUrl)
Write-Host ("Text   : {0}" -f $Text)

$Output = $Script | & $Python -
$ExitCode = $LASTEXITCODE

try {
  if (Test-Path -LiteralPath $ResultJsonPath) {
    $Result = Get-Content -Raw -LiteralPath $ResultJsonPath | ConvertFrom-Json
  } else {
    $Result = $Output | ConvertFrom-Json
  }
} catch {
  $Result = @{
    status = "failed"
    url = $WsUrl
    text = $Text
    error = $Output
  }
  $ExitCode = 1
}

if (-not (Test-Path -LiteralPath $ResultJsonPath)) {
  $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
}
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Result.status -eq "passed") {
  Write-Host ("Provider: {0}" -f $Result.provider)
  Write-Host ("Reply   : {0}" -f $Result.reply)
  Write-Host ("Session : {0} turn={1}" -f $Result.sessionId, $Result.turnIndex)
  exit 0
}

Write-Host ("WebSocket voice-chat test failed: {0}" -f $Result.error) -ForegroundColor Red
if ($Required -or $ExitCode -ne 0) {
  exit 1
}
exit 0
