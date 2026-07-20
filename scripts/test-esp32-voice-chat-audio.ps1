param(
  [string]$Port = "COM7",
  [int]$Baud = 115200,
  [int]$Seconds = 160,
  [int]$StartAfterSeconds = 12,
  [int]$Rate = -4,
  [ValidateRange(0, 100)]
  [int]$Volume = 100,
  [string]$WakePhrase = "Hi E S P",
  [string]$ChatCommandPhrase = "chat mode",
  [switch]$AutoChat,
  [string]$UserPhrase = "",
  [string[]]$UserPhrases = @(),
  [ValidateRange(1, 5)]
  [int]$ExpectedTurns = 1,
  [ValidateRange(0, 5)]
  [int]$ExpectedReplyTurns = 0,
  [switch]$RequireWebSocket,
  [switch]$RequireBinaryReplyAudio,
  [switch]$RequireStreamingReplyAudio,
  [switch]$RequireNoFallback,
  [string]$ExpectedTtsProvider = "",
  [string]$ExpectedTtsModel = "",
  [string]$ExpectedTtsVoice = "",
  [ValidateRange(1, 30)]
  [int]$WakeRetrySeconds = 5,
  [ValidateRange(0, 5000)]
  [int]$CommandAfterWakeMs = 500,
  [ValidateRange(0, 5000)]
  [int]$UserAfterRecordPromptMs = 400,
  [string]$SaveLogPath = ".\assets\demo\esp32-voice-chat-audio-test.log",
  [string]$MarkerPath = ".\assets\demo\esp32-voice-chat-audio-test-markers.log",
  [string]$ResultJsonPath = ".\assets\demo\esp32-voice-chat-audio-test-check.json",
  [string]$LogPath = "",
  [switch]$ForceCommandWindow,
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

function Get-LastMatchIndex {
  param(
    [string]$Text,
    [string]$Pattern
  )
  $Matches = [regex]::Matches($Text, $Pattern)
  if ($Matches.Count -eq 0) {
    return -1
  }
  return $Matches[$Matches.Count - 1].Index
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

function New-ChineseText {
  param([int[]]$CodePoints)
  return -join ($CodePoints | ForEach-Object { [char]$_ })
}

function Read-SerialText {
  param([System.IO.Ports.SerialPort]$SerialPort)

  if (-not $SerialPort.IsOpen) {
    Start-Sleep -Milliseconds 250
    $SerialPort.Open()
  }

  try {
    return $SerialPort.ReadExisting()
  } catch [TimeoutException] {
    return ""
  } catch [InvalidOperationException] {
    Start-Sleep -Milliseconds 250
    if (-not $SerialPort.IsOpen) {
      $SerialPort.Open()
    }
    return ""
  }
}

New-ParentDirectory -Path $SaveLogPath
New-ParentDirectory -Path $MarkerPath
New-ParentDirectory -Path $ResultJsonPath

if ($UserPhrases.Count -eq 0) {
  if ($UserPhrase) {
    $UserPhrases = @($UserPhrase)
  } else {
    $UserPhrases = @(
      (New-ChineseText @(
          0x4F60, 0x597D, 0x5C0F, 0x5343, 0xFF0C, 0x4ECA, 0x5929, 0x665A,
          0x4E0A, 0x9002, 0x5408, 0x770B, 0x4EC0, 0x4E48, 0x7535, 0x5F71
        )),
      (New-ChineseText @(
          0x4F60, 0x521A, 0x624D, 0x8BF4, 0x4F60, 0x53EB, 0x4EC0, 0x4E48,
          0x540D, 0x5B57
        ))
    )
  }
}
if ($UserPhrases.Count -eq 1 -and $UserPhrases[0] -match ";") {
  $UserPhrases = @($UserPhrases[0] -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

while ($UserPhrases.Count -lt $ExpectedTurns) {
  $UserPhrases += $UserPhrases[$UserPhrases.Count - 1]
}
if ($ExpectedReplyTurns -eq 0) {
  $ExpectedReplyTurns = $ExpectedTurns
}

$Failures = New-Object System.Collections.Generic.List[string]
$Checks = New-Object System.Collections.Generic.List[object]
$LogSource = "serial-event-driven"
$AutoChatMode = [bool]$AutoChat -or [string]::IsNullOrWhiteSpace($ChatCommandPhrase)
$VoiceChatTriggerPattern = "\[voice\] (chat mode|wake auto chat)"
$WakeCommandWindowPattern = "wake word channel \d+ verified - listening for command"
$WakeAutoChatPattern = "wake word channel \d+ verified - auto voice chat"

if ($LogPath) {
  if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "Log path not found: $LogPath"
  }

  $LogSource = "saved-log"
  $LogText = Get-Content -LiteralPath $LogPath -Raw
  $UserSentCount = [regex]::Matches($LogText, "audio user( \d+)?:").Count
  if ($UserSentCount -eq 0 -and (Test-Path -LiteralPath $MarkerPath)) {
    $UserSentCount = [regex]::Matches((Get-Content -LiteralPath $MarkerPath -Raw), "audio user( \d+)?:").Count
  }
  Set-Content -LiteralPath $MarkerPath -Value "" -NoNewline

  Write-Host "HomeCue Edge ESP32 voice-chat audio test"
  Write-Host ("Source : {0}" -f (Resolve-Path -LiteralPath $LogPath).Path)
  Write-Host ("Mode   : saved-log replay")
  Write-Host ""
} else {
  Add-Type -AssemblyName System.Speech
  $Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $SerialPort = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
  $SerialPort.ReadTimeout = 200
  $SerialPort.DtrEnable = $false
  $SerialPort.RtsEnable = $true
  $Chunks = New-Object System.Collections.Generic.List[string]
  $Markers = New-Object System.Collections.Generic.List[string]
  $UserSentCount = 0
  $ImmediateCommandDueAt = $null

  try {
    $Synth.SetOutputToDefaultAudioDevice()
    $Synth.Rate = $Rate
    $Synth.Volume = $Volume

    $SerialPort.Open()
    Write-Host "HomeCue Edge ESP32 voice-chat audio test"
    Write-Host ("Port   : {0}" -f $Port)
    Write-Host "Mode   : event-driven voice chat"
    Write-Host ("Wake   : {0}" -f $WakePhrase)
    Write-Host ("Command: {0}" -f $(if ($AutoChatMode) { "<auto after wake>" } else { $ChatCommandPhrase }))
    Write-Host ("Turns  : {0}" -f $ExpectedTurns)
    Write-Host ("Force  : {0}" -f ([bool]$ForceCommandWindow))
    Write-Host ("User   : {0}" -f ($UserPhrases -join " | "))
    Write-Host ("Log    : {0}" -f $SaveLogPath)
    Write-Host ""

    if (-not $SkipReset) {
      $SerialPort.RtsEnable = $false
      Start-Sleep -Milliseconds 100
      $SerialPort.RtsEnable = $true
    }

    $Ready = $false
    $CommandSent = $false
    $ForceWindowSent = $false
    $WakeAttempts = 0
    $NextWakeAt = (Get-Date).AddSeconds($StartAfterSeconds)
    $Deadline = (Get-Date).AddSeconds($Seconds)

    while ((Get-Date) -lt $Deadline) {
      $Text = Read-SerialText -SerialPort $SerialPort
      if ($Text) {
        $Chunks.Add($Text)
        Write-Host $Text -NoNewline
        if (-not $CommandSent -and
            (-not $AutoChatMode) -and
            ($Text -match $WakeCommandWindowPattern -or
             $Text -match "\[esp-sr\] forced command window - say a command word")) {
          $ImmediateCommandDueAt = (Get-Date).AddMilliseconds($CommandAfterWakeMs)
        }
      }

      $LogSoFar = $Chunks -join ""
      if (-not $Ready -and $LogSoFar -match "\[esp-sr\] ready") {
        $Ready = $true
        $NextWakeAt = (Get-Date).AddSeconds(3)
      }

      if ($Ready -and $ForceCommandWindow -and -not $ForceWindowSent) {
        $Marker = "serial command: homecue:voice-command-window"
        $Markers.Add($Marker)
        Write-Host ("`n{0}" -f $Marker)
        $SerialPort.WriteLine("homecue:voice-command-window")
        $ForceWindowSent = $true
      }

      if ($AutoChatMode -and -not $CommandSent -and $LogSoFar -match $VoiceChatTriggerPattern) {
        $CommandSent = $true
      }

      $LastWakeChannelIndex = Get-LastMatchIndex -Text $LogSoFar -Pattern $WakeCommandWindowPattern
      $LastForcedWindowIndex = Get-LastMatchIndex -Text $LogSoFar -Pattern "\[esp-sr\] forced command window - say a command word"
      $LastTimeoutIndex = Get-LastMatchIndex -Text $LogSoFar -Pattern "\[esp-sr\] command window timeout"
      $LastCommandWindowIndex = [Math]::Max($LastWakeChannelIndex, $LastForcedWindowIndex)
      $CommandWindowOpen = $LastCommandWindowIndex -ge 0 -and $LastCommandWindowIndex -gt $LastTimeoutIndex

      if (-not $AutoChatMode -and $CommandSent -and -not ($LogSoFar -match $VoiceChatTriggerPattern) -and $LastTimeoutIndex -gt $LastCommandWindowIndex) {
        $CommandSent = $false
        $NextWakeAt = (Get-Date).AddSeconds(1)
      }

      if ($ForceCommandWindow -and $ForceWindowSent -and -not $CommandSent -and
          -not ($LogSoFar -match $VoiceChatTriggerPattern) -and $LastTimeoutIndex -gt $LastForcedWindowIndex) {
        $ForceWindowSent = $false
      }

      if ($Ready -and -not $ForceCommandWindow -and -not $CommandWindowOpen -and -not $CommandSent -and (Get-Date) -ge $NextWakeAt -and $Synth.State -ne "Speaking") {
        $WakeAttempts += 1
        $Marker = "audio wake {0}: {1}" -f $WakeAttempts, $WakePhrase
        $Markers.Add($Marker)
        Write-Host ("`n{0}" -f $Marker)
        $Synth.SpeakAsync($WakePhrase) | Out-Null
        $NextWakeAt = (Get-Date).AddSeconds($WakeRetrySeconds)
      }

      $ImmediateCommandDue = $ImmediateCommandDueAt -ne $null -and (Get-Date) -ge $ImmediateCommandDueAt
      if (-not $AutoChatMode -and ($CommandWindowOpen -or $ImmediateCommandDue) -and -not $CommandSent) {
        if ($Synth.State -eq "Speaking") {
          $Synth.SpeakAsyncCancelAll()
        }
        if (-not $ImmediateCommandDue) {
          Start-Sleep -Milliseconds $CommandAfterWakeMs
        }
        $Marker = "audio command: {0}" -f $ChatCommandPhrase
        $Markers.Add($Marker)
        Write-Host ("`n{0}" -f $Marker)
        $Synth.Speak($ChatCommandPhrase)
        $CommandSent = $true
        $ImmediateCommandDueAt = $null
      }

      $LogSoFar = $Chunks -join ""
      $PromptCount = [regex]::Matches($LogSoFar, "\[/voice-chat(?:/ws)?\] recording \d+s - speak now").Count
      while ($CommandSent -and $PromptCount -gt $UserSentCount -and $UserSentCount -lt $ExpectedTurns) {
        Start-Sleep -Milliseconds $UserAfterRecordPromptMs
        $Phrase = $UserPhrases[$UserSentCount]
        $Marker = "audio user {0}: {1}" -f ($UserSentCount + 1), $Phrase
        $Markers.Add($Marker)
        Write-Host ("`n{0}" -f $Marker)
        $Synth.Speak($Phrase)
        $UserSentCount += 1
        $LogSoFar = $Chunks -join ""
        $PromptCount = [regex]::Matches($LogSoFar, "\[/voice-chat(?:/ws)?\] recording \d+s - speak now").Count
      }

      $LogSoFar = $Chunks -join ""
      $PlaybackCount = [regex]::Matches($LogSoFar, "\[speaker\] playback done").Count
      $ReadyTurnCount = [regex]::Matches($LogSoFar, "\[/voice-chat/ws\] ready turn=").Count
      if ($UserSentCount -ge $ExpectedTurns -and $PlaybackCount -ge $ExpectedReplyTurns -and $ReadyTurnCount -ge $ExpectedReplyTurns) {
        break
      }

      Start-Sleep -Milliseconds 100
    }

    $Text = Read-SerialText -SerialPort $SerialPort
    if ($Text) {
      $Chunks.Add($Text)
      Write-Host $Text -NoNewline
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
}

Write-Host ""
Write-Host "Checking expected voice-chat markers..."

$HttpAudioDownloadMatches = [regex]::Matches($LogText, "\[speaker\] downloaded \d+ audio bytes")
$WsBinaryReplyAudioMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] binary audio frame \d+ bytes")
$WsStreamingDoneMatches = [regex]::Matches($LogText, "\[speaker\] stream playback done data=\d+/\d+( segments=\d+)?")
$AudioTransferCount = $HttpAudioDownloadMatches.Count + $WsBinaryReplyAudioMatches.Count
$AudioPlaybackMatches = [regex]::Matches($LogText, "\[speaker\] playback done")
$RecordingPromptMatches = [regex]::Matches($LogText, "\[/voice-chat(?:/ws)?\] recording \d+s - speak now")
$HttpVoiceUploadMatches = [regex]::Matches($LogText, "\[/voice-chat\] uploading \d+ bytes")
$WsVoiceUploadMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] (sending \d+ WAV bytes|streamed \d+ PCM bytes)")
$VoiceUploadCount = $HttpVoiceUploadMatches.Count + $WsVoiceUploadMatches.Count
$MimoProviderMatches = [regex]::Matches($LogText, "\[/voice-chat(?:/ws)?\] provider: mimo")
$ReplyAudioReadyMatches = [regex]::Matches($LogText, "\[/voice-chat(?:/ws)?\] reply_audio: ready ")
$WsRouteMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\]")
$NoMatchMatches = [regex]::Matches($LogText, "\[/voice-chat/ws\] no speech detected:")
$FallbackMatches = [regex]::Matches($LogText, "\[voice\] WS session failed - falling back to HTTP voice chat")
$ExpectedTtsProviderMatches = if ($ExpectedTtsProvider) { [regex]::Matches($LogText, "\[/voice-chat/ws\] tts provider=$([regex]::Escape($ExpectedTtsProvider))\b") } else { @() }
$ExpectedTtsModelMatches = if ($ExpectedTtsModel) { [regex]::Matches($LogText, "\[/voice-chat/ws\] tts provider=.* model=$([regex]::Escape($ExpectedTtsModel))\b") } else { @() }
$ExpectedTtsVoiceMatches = if ($ExpectedTtsVoice) { [regex]::Matches($LogText, "\[/voice-chat/ws\] tts provider=.* voice=$([regex]::Escape($ExpectedTtsVoice))") } else { @() }
$CrashMatches = [regex]::Matches($LogText, "Guru Meditation|LoadProhibited|panic|abort\(\)")
$VoiceChatModeMatches = [regex]::Matches($LogText, $VoiceChatTriggerPattern)
$SerialVoiceChatMatches = [regex]::Matches($LogText, "\[serial\] VOICE CHAT")
$ForcedCommandWindowMatches = [regex]::Matches($LogText, "\[serial\] VOICE COMMAND WINDOW|\[esp-sr\] forced command window")
$WakeAckMatches = [regex]::Matches($LogText, "\[voice\] wake ack: for you sir, always")
$WakeAckTtsMatches = [regex]::Matches($LogText, "\[/voice-chat/tts\] reply_audio: ready ")
$TriggerCount = $VoiceChatModeMatches.Count + $SerialVoiceChatMatches.Count
$SessionMatches = [regex]::Matches($LogText, "\[voice-session\] id=([A-Za-z0-9_-]+) turn=(\d+)")
$SessionIds = @($SessionMatches | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ })
$UniqueSessionIds = @($SessionIds | Sort-Object -Unique)
$SessionTurns = @($SessionMatches | ForEach-Object { [int]$_.Groups[2].Value })

Write-Check "ESP-SR mode" ($LogText -match "\[mode\] button-route \+ ESP-SR voice command route") "firmware is running the voice route" $true
Write-Check "ES7210 ready" ($LogText -match "\[esp-sr\] ES7210 codec ready") "dual-mic ADC initialized" $true
Write-Check "ES8311 ready" ($LogText -match "\[speaker\] ES8311 codec ready") "board speaker codec initialized" $true
Write-Check "ESP-SR ready" ($LogText -match "\[esp-sr\] ready") "WakeNet/MultiNet initialized" $true
Write-Check "wake word detected" ($ForceCommandWindow -or $LogText -match "\[esp-sr\] wake word detected" -or $LogText -match "\[esp-sr\] wake word channel") "wake phrase reached ESP-SR" $true
Write-Check "forced command window" (-not $ForceCommandWindow -or $ForcedCommandWindowMatches.Count -gt 0) "serial opened ESP-SR command mode" $true
Write-Check "voice chat trigger" ($TriggerCount -gt 0) "chat mode entered the conversational route" $true
Write-Check "wake auto ack" (-not $AutoChatMode -or $WakeAckMatches.Count -gt 0) ("saw {0} wake ack marker(s)" -f $WakeAckMatches.Count) ([bool]$AutoChatMode)
Write-Check "wake ack TTS" (-not $AutoChatMode -or $WakeAckTtsMatches.Count -gt 0) ("saw {0} wake ack audio marker(s)" -f $WakeAckTtsMatches.Count) ([bool]$AutoChatMode)
Write-Check "recording prompts" ($RecordingPromptMatches.Count -ge $ExpectedTurns) ("saw {0}/{1}" -f $RecordingPromptMatches.Count, $ExpectedTurns) $true
Write-Check "audio user turns" ($UserSentCount -ge $ExpectedTurns) ("played {0}/{1} user phrase(s)" -f $UserSentCount, $ExpectedTurns) $true
Write-Check "voice uploads" ($VoiceUploadCount -ge $ExpectedTurns) ("saw {0}/{1}" -f $VoiceUploadCount, $ExpectedTurns) $true
Write-Check "websocket route" (-not $RequireWebSocket -or $WsRouteMatches.Count -gt 0) ("saw {0} ws marker(s)" -f $WsRouteMatches.Count) ([bool]$RequireWebSocket)
Write-Check "asr no-match recovery" ($NoMatchMatches.Count -eq 0 -or $LogText -match "\[/voice-chat/ws\] ready turn=0") ("no_match={0}" -f $NoMatchMatches.Count) $true
Write-Check "no HTTP fallback" (-not $RequireNoFallback -or $FallbackMatches.Count -eq 0) ("fallbacks={0}" -f $FallbackMatches.Count) ([bool]$RequireNoFallback)
Write-Check "mimo provider" ($MimoProviderMatches.Count -ge $ExpectedReplyTurns) ("saw {0}/{1}" -f $MimoProviderMatches.Count, $ExpectedReplyTurns) $true
Write-Check "reply audio ready" ($ReplyAudioReadyMatches.Count -ge $ExpectedReplyTurns) ("saw {0}/{1}" -f $ReplyAudioReadyMatches.Count, $ExpectedReplyTurns) $true
Write-Check "reply audio transfer" ($AudioTransferCount -ge $ExpectedReplyTurns) ("http_downloads={0}, ws_binary_frames={1}" -f $HttpAudioDownloadMatches.Count, $WsBinaryReplyAudioMatches.Count) $true
Write-Check "binary reply audio" (-not $RequireBinaryReplyAudio -or $WsBinaryReplyAudioMatches.Count -ge $ExpectedReplyTurns) ("saw {0}/{1}" -f $WsBinaryReplyAudioMatches.Count, $ExpectedReplyTurns) ([bool]$RequireBinaryReplyAudio)
Write-Check "streaming reply audio done" (-not $RequireStreamingReplyAudio -or $WsStreamingDoneMatches.Count -ge $ExpectedReplyTurns) ("saw {0}/{1}" -f $WsStreamingDoneMatches.Count, $ExpectedReplyTurns) ([bool]$RequireStreamingReplyAudio)
Write-Check "expected TTS provider" (-not $ExpectedTtsProvider -or $ExpectedTtsProviderMatches.Count -ge $ExpectedReplyTurns) ("expected={0} saw {1}/{2}" -f $ExpectedTtsProvider, $ExpectedTtsProviderMatches.Count, $ExpectedReplyTurns) ([bool]$ExpectedTtsProvider)
Write-Check "expected TTS model" (-not $ExpectedTtsModel -or $ExpectedTtsModelMatches.Count -ge $ExpectedReplyTurns) ("expected={0} saw {1}/{2}" -f $ExpectedTtsModel, $ExpectedTtsModelMatches.Count, $ExpectedReplyTurns) ([bool]$ExpectedTtsModel)
Write-Check "expected TTS voice" (-not $ExpectedTtsVoice -or $ExpectedTtsVoiceMatches.Count -ge $ExpectedReplyTurns) ("expected={0} saw {1}/{2}" -f $ExpectedTtsVoice, $ExpectedTtsVoiceMatches.Count, $ExpectedReplyTurns) ([bool]$ExpectedTtsVoice)
Write-Check "audio playback" ($AudioPlaybackMatches.Count -ge $ExpectedReplyTurns) ("saw {0}/{1}" -f $AudioPlaybackMatches.Count, $ExpectedReplyTurns) $true
Write-Check "single session id" ($ExpectedReplyTurns -le 1 -or ($UniqueSessionIds.Count -eq 1 -and $SessionIds.Count -ge $ExpectedReplyTurns)) ("unique ids={0}" -f $UniqueSessionIds.Count) $true
Write-Check "session turns advance" ($ExpectedReplyTurns -le 1 -or (($SessionTurns -contains 1) -and ($SessionTurns -contains $ExpectedReplyTurns))) ("turns={0}" -f ($SessionTurns -join ",")) $true
Write-Check "no crash" ($CrashMatches.Count -eq 0) ("saw {0} crash marker(s)" -f $CrashMatches.Count) $true

$ResolvedLogPath = if ($LogPath) { (Resolve-Path -LiteralPath $LogPath).Path } else { (Resolve-Path -LiteralPath $SaveLogPath).Path }
$Result = @{
  source = $LogSource
  port = $Port
  baud = $Baud
  seconds = $Seconds
  wakePhrase = $WakePhrase
  chatCommandPhrase = $ChatCommandPhrase
  forceCommandWindow = [bool]$ForceCommandWindow
  expectedTurns = $ExpectedTurns
  expectedReplyTurns = $ExpectedReplyTurns
  userPhrase = $UserPhrases[0]
  userPhrases = [string[]]$UserPhrases
  triggerCount = $TriggerCount
  recordingPromptCount = $RecordingPromptMatches.Count
  voiceUploadCount = $VoiceUploadCount
  websocketMarkerCount = $WsRouteMatches.Count
  noMatchCount = $NoMatchMatches.Count
  fallbackCount = $FallbackMatches.Count
  wakeAckCount = $WakeAckMatches.Count
  wakeAckTtsCount = $WakeAckTtsMatches.Count
  mimoProviderCount = $MimoProviderMatches.Count
  replyAudioReadyCount = $ReplyAudioReadyMatches.Count
  httpAudioDownloadCount = $HttpAudioDownloadMatches.Count
  binaryReplyAudioCount = $WsBinaryReplyAudioMatches.Count
  streamingReplyAudioDoneCount = $WsStreamingDoneMatches.Count
  expectedTtsProvider = $ExpectedTtsProvider
  expectedTtsProviderCount = $ExpectedTtsProviderMatches.Count
  expectedTtsModel = $ExpectedTtsModel
  expectedTtsModelCount = $ExpectedTtsModelMatches.Count
  expectedTtsVoice = $ExpectedTtsVoice
  expectedTtsVoiceCount = $ExpectedTtsVoiceMatches.Count
  audioPlaybackCount = $AudioPlaybackMatches.Count
  sessionIds = [string[]]$SessionIds
  sessionTurns = [int[]]$SessionTurns
  crashCount = $CrashMatches.Count
  logPath = $ResolvedLogPath
  markerPath = if (Test-Path -LiteralPath $MarkerPath) { (Resolve-Path -LiteralPath $MarkerPath).Path } else { $MarkerPath }
  requiredMode = [bool]$Required
  failures = [string[]]$Failures.ToArray()
  checks = [object[]]$Checks.ToArray()
}
$Result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "ESP32 voice-chat audio test failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "ESP32 voice-chat audio test complete."
exit 0
