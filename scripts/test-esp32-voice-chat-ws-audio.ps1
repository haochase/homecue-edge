param(
  [string]$Port = "COM7",
  [int]$Baud = 115200,
  [int]$Seconds = 120,
  [int]$StartAfterSeconds = 10,
  [ValidateRange(1, 5)]
  [int]$Turns = 1,
  [int]$RecordSeconds = 6,
  [int]$Rate = -4,
  [ValidateRange(0, 100)]
  [int]$Volume = 100,
  [string]$VoiceName = "Microsoft Huihui Desktop",
  [string]$UserPhrase = "Hello XiaoQian, confirm WebSocket voice chat from the board speaker.",
  [string[]]$UserPhrases = @(),
  [string]$SaveLogPath = ".\assets\demo\esp32-voice-chat-ws-audio-test.log",
  [string]$MarkerPath = ".\assets\demo\esp32-voice-chat-ws-audio-test-markers.log",
  [string]$ResultJsonPath = ".\assets\demo\esp32-voice-chat-ws-audio-test-check.json",
  [switch]$RequirePcmStream,
  [switch]$RequireVadStop,
  [switch]$RequireBinaryReplyAudio,
  [switch]$RequireChunkedReplyAudio,
  [switch]$RequireStreamingReplyAudio,
  [string]$ExpectedTtsProvider = "",
  [string]$ExpectedTtsModel = "",
  [string]$ExpectedTtsVoice = "",
  [switch]$SkipReset,
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

function Write-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = "",
    [bool]$RequiredCheck = $false
  )

  $Status = if ($Ok) { "OK" } else { "WARN" }
  $DetailSuffix = if ($Detail) { " - $Detail" } else { "" }
  Write-Host ("[{0}] {1}{2}" -f $Status, $Name, $DetailSuffix)

  $script:Checks.Add([pscustomobject]@{
      name = $Name
      status = $Status
      required = [bool]$RequiredCheck
      detail = $Detail
    })

  if ($Required -and $RequiredCheck -and -not $Ok) {
    $script:Failures.Add($Name)
  }
}

New-ParentDirectory -Path $SaveLogPath
New-ParentDirectory -Path $MarkerPath
New-ParentDirectory -Path $ResultJsonPath

Add-Type -AssemblyName System.Speech
$Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$SerialPort = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
$SerialPort.ReadTimeout = 200
$SerialPort.DtrEnable = $false
$SerialPort.RtsEnable = $true
$Chunks = New-Object System.Collections.Generic.List[string]
$Markers = New-Object System.Collections.Generic.List[string]
$Failures = New-Object System.Collections.Generic.List[string]
$Checks = New-Object System.Collections.Generic.List[object]
$UserSentCount = 0
$CommandSent = $false
$SelectedVoiceName = ""

if ($UserPhrases.Count -eq 0) {
  $UserPhrases = @($UserPhrase)
}
if ($UserPhrases.Count -eq 1 -and $UserPhrases[0] -match ";") {
  $UserPhrases = @($UserPhrases[0] -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
while ($UserPhrases.Count -lt $Turns) {
  $UserPhrases += $UserPhrases[$UserPhrases.Count - 1]
}

try {
  $Synth.SetOutputToDefaultAudioDevice()
  if ($VoiceName) {
    try {
      $Synth.SelectVoice($VoiceName)
    } catch {
      Write-Host ("Voice '{0}' unavailable, using default '{1}'" -f $VoiceName, $Synth.Voice.Name) -ForegroundColor Yellow
    }
  }
  $Synth.Rate = $Rate
  $Synth.Volume = $Volume
  $SelectedVoiceName = $Synth.Voice.Name

  $SerialPort.Open()
  Write-Host "HomeCue Edge ESP32 voice-chat WebSocket audio test"
  Write-Host ("Port   : {0}" -f $Port)
  Write-Host ("Command: {0}" -f ($(if ($Turns -gt 1) { "homecue:voice-chat-ws-session $Turns $RecordSeconds" } else { "homecue:voice-chat-ws $RecordSeconds" })))
  Write-Host ("Turns  : {0}" -f $Turns)
  Write-Host ("User   : {0}" -f ($UserPhrases -join " | "))
  Write-Host ("Voice  : {0}" -f $SelectedVoiceName)
  Write-Host ("Log    : {0}" -f $SaveLogPath)
  Write-Host ""

  if (-not $SkipReset) {
    $SerialPort.RtsEnable = $false
    Start-Sleep -Milliseconds 100
    $SerialPort.RtsEnable = $true
  }

  $Deadline = (Get-Date).AddSeconds($Seconds)
  $CommandAt = (Get-Date).AddSeconds($StartAfterSeconds)

  while ((Get-Date) -lt $Deadline) {
    try {
      $Text = $SerialPort.ReadExisting()
      if ($Text) {
        $Chunks.Add($Text)
        Write-Host $Text -NoNewline
      }
    } catch [TimeoutException] {
    }

    if (-not $CommandSent -and (Get-Date) -ge $CommandAt) {
      $Command = if ($Turns -gt 1) {
        "homecue:voice-chat-ws-session {0} {1}" -f $Turns, $RecordSeconds
      } else {
        "homecue:voice-chat-ws {0}" -f $RecordSeconds
      }
      $Markers.Add("serial command: $Command")
      Write-Host ("`nserial command: {0}" -f $Command)
      $SerialPort.WriteLine($Command)
      $CommandSent = $true
    }

    $LogSoFar = $Chunks -join ""
    $PromptCount = [regex]::Matches($LogSoFar, "\[/voice-chat/ws\] recording \d+s - speak now").Count
    while ($CommandSent -and $PromptCount -gt $UserSentCount -and $UserSentCount -lt $Turns) {
      Start-Sleep -Milliseconds 450
      $Phrase = $UserPhrases[$UserSentCount]
      $Markers.Add(("audio user {0}: {1}" -f ($UserSentCount + 1), $Phrase))
      Write-Host ("`naudio user {0}: {1}" -f ($UserSentCount + 1), $Phrase)
      $Synth.Speak($Phrase)
      $UserSentCount += 1
      $LogSoFar = $Chunks -join ""
      $PromptCount = [regex]::Matches($LogSoFar, "\[/voice-chat/ws\] recording \d+s - speak now").Count
    }

    $LogSoFar = $Chunks -join ""
    $ReadyCount = [regex]::Matches($LogSoFar, "\[/voice-chat/ws\] ready turn=\d+").Count
    $PlaybackCount = [regex]::Matches($LogSoFar, "\[speaker\] playback done").Count
    if ($UserSentCount -ge $Turns -and $ReadyCount -ge $Turns -and $PlaybackCount -ge $Turns) {
      break
    }

    Start-Sleep -Milliseconds 100
  }

  try {
    $Text = $SerialPort.ReadExisting()
    if ($Text) {
      $Chunks.Add($Text)
      Write-Host $Text -NoNewline
    }
  } catch [TimeoutException] {
  }

  Write-Host ""
} finally {
  if ($SerialPort.IsOpen) {
    $SerialPort.DtrEnable = $false
    $SerialPort.RtsEnable = $true
    $SerialPort.Close()
  }
  $Synth.Dispose()
}

$LogText = $Chunks -join ""
Set-Content -LiteralPath $SaveLogPath -Value $LogText -NoNewline -Encoding UTF8
if ($Markers.Count -gt 0) {
  Set-Content -LiteralPath $MarkerPath -Value ($Markers -join [Environment]::NewLine) -Encoding UTF8
} else {
  Set-Content -LiteralPath $MarkerPath -Value "" -NoNewline
}

Write-Host ""
Write-Host "Checking expected WebSocket voice-chat markers..."

$HandshakeMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] connected")
$HelloMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] hello session=")
$UploadMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] (sending \d+ WAV bytes|streamed \d+ PCM bytes)")
$PcmUploadMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] streamed \d+ PCM bytes")
$VadStopMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] VAD stop at \d+ms")
$SttMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] heard:")
$ProviderMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] provider: mimo")
$ReadyMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] ready turn=\d+")
$AudioReadyMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] reply_audio: ready ")
$BinaryReplyAudioMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] binary audio frame \d+ bytes")
$ChunkedReplyReadyMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] reply_audio: ready .*transport=websocket_binary_(chunked|stream)")
$ReplyAudioChunkMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] binary audio (chunk \d+ size=\d+ total=\d+/\d+|stream chunk \d+ size=\d+)")
$ReplyAudioChunkCompleteMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] reply audio (chunks complete chunks=\d+ bytes=\d+|stream complete chunks=\d+)")
$StreamingStartMatches = [regex]::Matches($LogText, "\[speaker\] stream start rate=\d+ channels=\d+ data=\d+")
$StreamingDoneMatches = [regex]::Matches($LogText, "\[speaker\] stream playback done data=\d+/\d+( segments=\d+)?")
$ExpectedTtsProviderMatches = if ($ExpectedTtsProvider) { [regex]::Matches($LogText, "\[/voice-chat/ws\] tts provider=$([regex]::Escape($ExpectedTtsProvider))\b") } else { @() }
$ExpectedTtsModelMatches = if ($ExpectedTtsModel) { [regex]::Matches($LogText, "\[/voice-chat/ws\] tts provider=.* model=$([regex]::Escape($ExpectedTtsModel))\b") } else { @() }
$ExpectedTtsVoiceMatches = if ($ExpectedTtsVoice) { [regex]::Matches($LogText, "\[/voice-chat/ws\] tts provider=.* voice=$([regex]::Escape($ExpectedTtsVoice))") } else { @() }
$PlaybackMatches = [regex]::Matches($LogText, "\[speaker\] playback done")
$CrashMatches = [regex]::Matches($LogText, "Guru Meditation|LoadProhibited|panic|abort\(\)")
$SessionMatches = [regex]::Matches($LogText, "\[voice-session\] id=([A-Za-z0-9_-]+) turn=(\d+)")
$SessionIds = @($SessionMatches | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ })
$UniqueSessionIds = @($SessionIds | Sort-Object -Unique)
$SessionTurns = @($SessionMatches | ForEach-Object { [int]$_.Groups[2].Value })

Write-Check "ESP-SR mode" ($LogText -match "\[mode\] button-route \+ ESP-SR voice command route") "firmware is running the voice route" $true
Write-Check "ES7210 ready" ($LogText -match "\[esp-sr\] ES7210 codec ready") "dual-mic ADC initialized" $true
Write-Check "ES8311 ready" ($LogText -match "\[speaker\] ES8311 codec ready") "board speaker codec initialized" $true
Write-Check "serial WS command" ($CommandSent -and ($LogText -match "\[serial\] VOICE CHAT WS")) "serial command entered WS route" $true
Write-Check "recording prompts" ($PromptCount -ge $Turns) ("saw {0}/{1}" -f $PromptCount, $Turns) $true
Write-Check "audio user turns" ($UserSentCount -ge $Turns) ("played {0}/{1}" -f $UserSentCount, $Turns) $true
Write-Check "ws handshake" ($HandshakeMatches.Count -ge 1) ("saw {0}" -f $HandshakeMatches.Count) $true
Write-Check "ws hello" ($HelloMatches.Count -ge 1) ("saw {0}" -f $HelloMatches.Count) $true
Write-Check "ws audio upload" ($UploadMatches.Count -ge $Turns) ("saw {0}/{1}" -f $UploadMatches.Count, $Turns) $true
Write-Check "ws PCM stream" (-not $RequirePcmStream -or $PcmUploadMatches.Count -ge $Turns) ("saw {0}/{1}" -f $PcmUploadMatches.Count, $Turns) ([bool]$RequirePcmStream)
Write-Check "VAD early stop" (-not $RequireVadStop -or $VadStopMatches.Count -ge $Turns) ("saw {0}/{1}" -f $VadStopMatches.Count, $Turns) ([bool]$RequireVadStop)
Write-Check "ws stt" ($SttMatches.Count -ge $Turns) ("saw {0}/{1}" -f $SttMatches.Count, $Turns) $true
Write-Check "mimo provider" ($ProviderMatches.Count -ge $Turns) ("saw {0}/{1}" -f $ProviderMatches.Count, $Turns) $true
Write-Check "ws ready" ($ReadyMatches.Count -ge $Turns) ("saw {0}/{1}" -f $ReadyMatches.Count, $Turns) $true
Write-Check "reply audio ready" ($AudioReadyMatches.Count -ge $Turns) ("saw {0}/{1}" -f $AudioReadyMatches.Count, $Turns) $true
Write-Check "binary reply audio" (-not $RequireBinaryReplyAudio -or $BinaryReplyAudioMatches.Count -ge $Turns) ("saw {0}/{1}" -f $BinaryReplyAudioMatches.Count, $Turns) ([bool]$RequireBinaryReplyAudio)
Write-Check "chunked reply audio ready" (-not $RequireChunkedReplyAudio -or $ChunkedReplyReadyMatches.Count -ge $Turns) ("saw {0}/{1}" -f $ChunkedReplyReadyMatches.Count, $Turns) ([bool]$RequireChunkedReplyAudio)
Write-Check "chunked reply audio frames" (-not $RequireChunkedReplyAudio -or $ReplyAudioChunkMatches.Count -gt $Turns) ("saw {0}" -f $ReplyAudioChunkMatches.Count) ([bool]$RequireChunkedReplyAudio)
Write-Check "chunked reply audio complete" (-not $RequireChunkedReplyAudio -or $ReplyAudioChunkCompleteMatches.Count -ge $Turns) ("saw {0}/{1}" -f $ReplyAudioChunkCompleteMatches.Count, $Turns) ([bool]$RequireChunkedReplyAudio)
Write-Check "streaming reply audio start" (-not $RequireStreamingReplyAudio -or $StreamingStartMatches.Count -ge $Turns) ("saw {0}/{1}" -f $StreamingStartMatches.Count, $Turns) ([bool]$RequireStreamingReplyAudio)
Write-Check "streaming reply audio done" (-not $RequireStreamingReplyAudio -or $StreamingDoneMatches.Count -ge $Turns) ("saw {0}/{1}" -f $StreamingDoneMatches.Count, $Turns) ([bool]$RequireStreamingReplyAudio)
Write-Check "expected TTS provider" (-not $ExpectedTtsProvider -or $ExpectedTtsProviderMatches.Count -ge $Turns) ("expected={0} saw {1}/{2}" -f $ExpectedTtsProvider, $ExpectedTtsProviderMatches.Count, $Turns) ([bool]$ExpectedTtsProvider)
Write-Check "expected TTS model" (-not $ExpectedTtsModel -or $ExpectedTtsModelMatches.Count -ge $Turns) ("expected={0} saw {1}/{2}" -f $ExpectedTtsModel, $ExpectedTtsModelMatches.Count, $Turns) ([bool]$ExpectedTtsModel)
Write-Check "expected TTS voice" (-not $ExpectedTtsVoice -or $ExpectedTtsVoiceMatches.Count -ge $Turns) ("expected={0} saw {1}/{2}" -f $ExpectedTtsVoice, $ExpectedTtsVoiceMatches.Count, $Turns) ([bool]$ExpectedTtsVoice)
Write-Check "audio playback" ($PlaybackMatches.Count -ge $Turns) ("saw {0}/{1}" -f $PlaybackMatches.Count, $Turns) $true
Write-Check "single session id" ($Turns -eq 1 -or ($UniqueSessionIds.Count -eq 1 -and $SessionIds.Count -ge $Turns)) ("unique ids={0}" -f $UniqueSessionIds.Count) $true
Write-Check "session turns advance" ($Turns -eq 1 -or (($SessionTurns -contains 1) -and ($SessionTurns -contains $Turns))) ("turns={0}" -f ($SessionTurns -join ",")) $true
Write-Check "no crash" ($CrashMatches.Count -eq 0) ("saw {0} crash marker(s)" -f $CrashMatches.Count) $true

$Result = @{
  source = "serial-websocket-audio"
  port = $Port
  baud = $Baud
  seconds = $Seconds
  turns = $Turns
  recordSeconds = $RecordSeconds
  userPhrase = $UserPhrases[0]
  userPhrases = [string[]]$UserPhrases
  voiceName = $SelectedVoiceName
  commandSent = [bool]$CommandSent
  userSentCount = $UserSentCount
  wsHandshakeCount = $HandshakeMatches.Count
  wsHelloCount = $HelloMatches.Count
  wsUploadCount = $UploadMatches.Count
  wsPcmUploadCount = $PcmUploadMatches.Count
  vadStopCount = $VadStopMatches.Count
  wsSttCount = $SttMatches.Count
  mimoProviderCount = $ProviderMatches.Count
  wsReadyCount = $ReadyMatches.Count
  replyAudioReadyCount = $AudioReadyMatches.Count
  binaryReplyAudioCount = $BinaryReplyAudioMatches.Count
  chunkedReplyAudioReadyCount = $ChunkedReplyReadyMatches.Count
  replyAudioChunkCount = $ReplyAudioChunkMatches.Count
  replyAudioChunkCompleteCount = $ReplyAudioChunkCompleteMatches.Count
  streamingReplyAudioStartCount = $StreamingStartMatches.Count
  streamingReplyAudioDoneCount = $StreamingDoneMatches.Count
  expectedTtsProvider = $ExpectedTtsProvider
  expectedTtsProviderCount = $ExpectedTtsProviderMatches.Count
  expectedTtsModel = $ExpectedTtsModel
  expectedTtsModelCount = $ExpectedTtsModelMatches.Count
  expectedTtsVoice = $ExpectedTtsVoice
  expectedTtsVoiceCount = $ExpectedTtsVoiceMatches.Count
  audioPlaybackCount = $PlaybackMatches.Count
  sessionIds = [string[]]$SessionIds
  sessionTurns = [int[]]$SessionTurns
  crashCount = $CrashMatches.Count
  logPath = (Resolve-Path -LiteralPath $SaveLogPath).Path
  markerPath = (Resolve-Path -LiteralPath $MarkerPath).Path
  requiredMode = [bool]$Required
  failures = [string[]]$Failures.ToArray()
  checks = [object[]]$Checks.ToArray()
}
$Result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "ESP32 WebSocket voice-chat audio test failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "ESP32 WebSocket voice-chat audio test complete."
exit 0
