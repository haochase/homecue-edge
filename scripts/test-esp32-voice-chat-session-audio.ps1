param(
  [string]$Port = "COM7",
  [int]$Baud = 115200,
  [ValidateRange(1, 5)]
  [int]$Turns = 2,
  [ValidateRange(1, 8)]
  [int]$RecordSeconds = 5,
  [int]$Seconds = 220,
  [int]$Rate = -4,
  [ValidateRange(0, 100)]
  [int]$Volume = 100,
  [ValidateRange(0, 5000)]
  [int]$UserAfterRecordPromptMs = 500,
  [string[]]$UserPhrases = @(),
  [string]$SaveLogPath = ".\assets\demo\esp32-voice-chat-session-audio-test.log",
  [string]$MarkerPath = ".\assets\demo\esp32-voice-chat-session-audio-test-markers.log",
  [string]$ResultJsonPath = ".\assets\demo\esp32-voice-chat-session-audio-test-check.json",
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

function New-ChineseText {
  param([int[]]$CodePoints)
  return -join ($CodePoints | ForEach-Object { [char]$_ })
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

if ($UserPhrases.Count -eq 0) {
  $UserPhrases = @(
    (New-ChineseText @(0x4F60, 0x597D, 0x5C0F, 0x5343, 0xFF0C, 0x8BF7, 0x4ECB, 0x7ECD, 0x4E00, 0x4E0B, 0x4F60, 0x81EA, 0x5DF1)),
    (New-ChineseText @(0x4F60, 0x521A, 0x624D, 0x8BF4, 0x4F60, 0x53EB, 0x4EC0, 0x4E48, 0x540D, 0x5B57))
  )
}

while ($UserPhrases.Count -lt $Turns) {
  $UserPhrases += $UserPhrases[$UserPhrases.Count - 1]
}

New-ParentDirectory -Path $SaveLogPath
New-ParentDirectory -Path $MarkerPath
New-ParentDirectory -Path $ResultJsonPath

$Failures = New-Object System.Collections.Generic.List[string]
$Checks = New-Object System.Collections.Generic.List[object]
$Chunks = New-Object System.Collections.Generic.List[string]
$Markers = New-Object System.Collections.Generic.List[string]

Add-Type -AssemblyName System.Speech
$Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$SerialPort = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
$SerialPort.ReadTimeout = 200
$SerialPort.NewLine = "`n"
$SerialPort.DtrEnable = $false
$SerialPort.RtsEnable = $true

try {
  $Synth.SetOutputToDefaultAudioDevice()
  $Synth.Rate = $Rate
  $Synth.Volume = $Volume

  $SerialPort.Open()
  Write-Host "HomeCue Edge ESP32 voice-chat session audio test"
  Write-Host ("Port   : {0}" -f $Port)
  Write-Host ("Mode   : serial-triggered {0}-turn voice chat session" -f $Turns)
  Write-Host ("Record : {0}s per turn" -f $RecordSeconds)
  Write-Host ("Log    : {0}" -f $SaveLogPath)
  Write-Host ""

  if (-not $SkipReset) {
    $SerialPort.RtsEnable = $false
    Start-Sleep -Milliseconds 100
    $SerialPort.RtsEnable = $true
  }

  $Ready = $false
  $CommandSent = $false
  $UserSentCount = 0
  $Deadline = (Get-Date).AddSeconds($Seconds)

  while ((Get-Date) -lt $Deadline) {
    try {
      $Text = $SerialPort.ReadExisting()
      if ($Text) {
        $Chunks.Add($Text)
        Write-Host $Text -NoNewline
      }
    } catch [TimeoutException] {
    }

    $LogSoFar = $Chunks -join ""
    if (-not $Ready -and $LogSoFar -match "\[esp-sr\] ready") {
      $Ready = $true
    }

    if ($Ready -and -not $CommandSent) {
      $ResetCommand = "homecue:voice-chat-reset"
      $SessionCommand = "homecue:voice-chat-session {0} {1}" -f $Turns, $RecordSeconds
      $Markers.Add("serial command: $ResetCommand")
      $Markers.Add("serial command: $SessionCommand")
      Write-Host ("`nserial command: {0}" -f $ResetCommand)
      $SerialPort.WriteLine($ResetCommand)
      Start-Sleep -Milliseconds 250
      Write-Host ("serial command: {0}" -f $SessionCommand)
      $SerialPort.WriteLine($SessionCommand)
      $CommandSent = $true
    }

    $LogSoFar = $Chunks -join ""
    $PromptCount = [regex]::Matches($LogSoFar, "\[/voice-chat\] recording \d+s - speak now").Count
    while ($PromptCount -gt $UserSentCount -and $UserSentCount -lt $Turns) {
      Start-Sleep -Milliseconds $UserAfterRecordPromptMs
      $Phrase = $UserPhrases[$UserSentCount]
      $Marker = "audio user {0}: {1}" -f ($UserSentCount + 1), $Phrase
      $Markers.Add($Marker)
      Write-Host ("`n{0}" -f $Marker)
      $Synth.Speak($Phrase)
      $UserSentCount += 1
      $LogSoFar = $Chunks -join ""
      $PromptCount = [regex]::Matches($LogSoFar, "\[/voice-chat\] recording \d+s - speak now").Count
    }

    $LogSoFar = $Chunks -join ""
    $PlaybackCount = [regex]::Matches($LogSoFar, "\[speaker\] playback done").Count
    if ($CommandSent -and $UserSentCount -ge $Turns -and $PlaybackCount -ge $Turns) {
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
Write-Host "Checking expected voice-chat session markers..."

$PromptCount = [regex]::Matches($LogText, "\[/voice-chat\] recording \d+s - speak now").Count
$UploadCount = [regex]::Matches($LogText, "\[/voice-chat\] uploading \d+ bytes").Count
$MimoCount = [regex]::Matches($LogText, "\[/voice-chat\] provider: mimo").Count
$ReplyAudioCount = [regex]::Matches($LogText, "\[/voice-chat\] reply_audio: ready ").Count
$AudioDownloadCount = [regex]::Matches($LogText, "\[speaker\] downloaded \d+ audio bytes").Count
$AudioPlaybackCount = [regex]::Matches($LogText, "\[speaker\] playback done").Count
$CrashCount = [regex]::Matches($LogText, "Guru Meditation|LoadProhibited|panic|abort\(\)").Count
$SessionMatches = [regex]::Matches($LogText, "\[voice-session\] id=([A-Za-z0-9_-]+) turn=(\d+)")
$SessionIds = @($SessionMatches | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ })
$UniqueSessionIds = @($SessionIds | Sort-Object -Unique)
$SessionTurns = @($SessionMatches | ForEach-Object { [int]$_.Groups[2].Value })

Write-Check "ESP-SR mode" ($LogText -match "\[mode\] button-route \+ ESP-SR voice command route") "firmware is running the voice route" $true
Write-Check "ES7210 ready" ($LogText -match "\[esp-sr\] ES7210 codec ready") "dual-mic ADC initialized" $true
Write-Check "ES8311 ready" ($LogText -match "\[speaker\] ES8311 codec ready") "board speaker codec initialized" $true
Write-Check "ESP-SR ready" ($LogText -match "\[esp-sr\] ready") "WakeNet/MultiNet initialized" $true
Write-Check "session command trigger" ($LogText -match "\[serial\] VOICE CHAT SESSION") "serial route entered continuous chat" $true
Write-Check "recording prompts" ($PromptCount -ge $Turns) ("saw {0}/{1}" -f $PromptCount, $Turns) $true
Write-Check "audio user turns" ($UserSentCount -ge $Turns) ("played {0}/{1} user phrase(s)" -f $UserSentCount, $Turns) $true
Write-Check "voice uploads" ($UploadCount -ge $Turns) ("saw {0}/{1}" -f $UploadCount, $Turns) $true
Write-Check "mimo provider" ($MimoCount -ge $Turns) ("saw {0}/{1}" -f $MimoCount, $Turns) $true
Write-Check "reply audio ready" ($ReplyAudioCount -ge $Turns) ("saw {0}/{1}" -f $ReplyAudioCount, $Turns) $true
Write-Check "audio downloaded" ($AudioDownloadCount -ge $Turns) ("saw {0}/{1}" -f $AudioDownloadCount, $Turns) $true
Write-Check "audio playback" ($AudioPlaybackCount -ge $Turns) ("saw {0}/{1}" -f $AudioPlaybackCount, $Turns) $true
Write-Check "single session id" ($UniqueSessionIds.Count -eq 1 -and $SessionIds.Count -ge $Turns) ("unique ids={0}" -f $UniqueSessionIds.Count) $true
Write-Check "session turns advance" (($SessionTurns -contains 1) -and ($SessionTurns -contains $Turns)) ("turns={0}" -f ($SessionTurns -join ",")) $true
Write-Check "no crash" ($CrashCount -eq 0) ("saw {0} crash marker(s)" -f $CrashCount) $true

$Result = @{
  source = "serial-session-audio"
  port = $Port
  baud = $Baud
  turns = $Turns
  recordSeconds = $RecordSeconds
  userPhrases = [string[]]$UserPhrases
  promptCount = $PromptCount
  uploadCount = $UploadCount
  mimoCount = $MimoCount
  replyAudioCount = $ReplyAudioCount
  audioDownloadCount = $AudioDownloadCount
  audioPlaybackCount = $AudioPlaybackCount
  sessionIds = [string[]]$SessionIds
  sessionTurns = [int[]]$SessionTurns
  crashCount = $CrashCount
  logPath = (Resolve-Path -LiteralPath $SaveLogPath).Path
  markerPath = (Resolve-Path -LiteralPath $MarkerPath).Path
  requiredMode = [bool]$Required
  failures = [string[]]$Failures.ToArray()
  checks = [object[]]$Checks.ToArray()
}
$Result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "ESP32 voice-chat session audio test failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "ESP32 voice-chat session audio test complete."
exit 0
