param(
  [string]$Port = "COM7",
  [int]$Baud = 115200,
  [int]$Seconds = 60,
  [int]$StartAfterSeconds = 8,
  [switch]$AutoPoll,
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$UserId = "home-user",
  [string]$TaskTitle = "ESP32 reminder audio test",
  [string]$DueText = "now",
  [string]$ExpectedTtsProvider = "",
  [string]$ExpectedTtsModel = "",
  [string]$ExpectedTtsVoice = "",
  [string]$SaveLogPath = ".\assets\demo\esp32-reminders-due-audio.log",
  [string]$MarkerPath = ".\assets\demo\esp32-reminders-due-audio-markers.log",
  [string]$ResultJsonPath = ".\assets\demo\esp32-reminders-due-audio-check.json",
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

$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]
$Chunks = New-Object System.Collections.Generic.List[string]
$Markers = New-Object System.Collections.Generic.List[string]

$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$TaskBody = @{
  title = $TaskTitle
  due_text = $DueText
  due_at = [double]($Now - 5)
  user_id = $UserId
  device_id = "esp32-reminder-test"
} | ConvertTo-Json -Compress

Write-Host "HomeCue Edge ESP32 reminder audio test"
Write-Host ("API    : {0}" -f $ApiBase)
Write-Host ("Port   : {0}" -f $Port)
Write-Host ("Mode   : {0}" -f ($(if ($AutoPoll) { "auto poll" } else { "serial command" })))
Write-Host ("Task   : {0}" -f $TaskTitle)
Write-Host ("Log    : {0}" -f $SaveLogPath)

try {
  $Created = Invoke-RestMethod -Uri "$ApiBase/voice-chat/tasks" -Method Post -ContentType "application/json; charset=utf-8" -Body $TaskBody
} catch {
  if ($Required) { throw }
  Write-Host ("Could not create due task: {0}" -f $_.Exception.Message) -ForegroundColor Red
  exit 1
}

$Markers.Add(("created task: {0}" -f $Created.task.task_id))
if ($AutoPoll) {
  $Markers.Add("auto poll mode: no serial command")
}

$SerialPort = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
$SerialPort.ReadTimeout = 200
$SerialPort.DtrEnable = $false
$SerialPort.RtsEnable = $true
$CommandSent = $false

try {
  $SerialPort.Open()
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

    if (-not $AutoPoll -and -not $CommandSent -and (Get-Date) -ge $CommandAt) {
      $Command = "homecue:reminders"
      $Markers.Add("serial command: $Command")
      Write-Host ("`nserial command: {0}" -f $Command)
      $SerialPort.WriteLine($Command)
      $CommandSent = $true
    }

    $LogSoFar = $Chunks -join ""
    if (($AutoPoll -or $CommandSent) -and $LogSoFar -match "\[/voice-chat/tasks/due-audio\] status=ready" -and
        $LogSoFar -match "\[speaker\] playback done") {
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
}

$Log = $Chunks -join ""
$Markers | Set-Content -LiteralPath $MarkerPath -Encoding UTF8
$Log | Set-Content -LiteralPath $SaveLogPath -Encoding UTF8

$AutoPollCount = [regex]::Matches($Log, "\[reminders\] auto poll").Count
$StatusReadyCount = [regex]::Matches($Log, "\[/voice-chat/tasks/due-audio\] status=ready").Count
$AudioReadyCount = [regex]::Matches($Log, "\[/voice-chat/tasks/due-audio\] reply_audio: ready ").Count
$DownloadCount = [regex]::Matches($Log, "\[speaker\] downloaded \d+ audio bytes").Count
$PlaybackCount = [regex]::Matches($Log, "\[speaker\] playback done").Count
$CrashCount = [regex]::Matches($Log, "Guru Meditation|LoadProhibited|StoreProhibited|panic'ed|rst:0x7").Count
$TtsProviderCount = if ($ExpectedTtsProvider) {
  [regex]::Matches($Log, "\[/voice-chat/tasks/due-audio\] tts provider=$([regex]::Escape($ExpectedTtsProvider))\b").Count
} else {
  0
}
$TtsModelCount = if ($ExpectedTtsModel) {
  [regex]::Matches($Log, "\[/voice-chat/tasks/due-audio\] tts provider=.* model=$([regex]::Escape($ExpectedTtsModel))\b").Count
} else {
  0
}
$TtsVoiceCount = if ($ExpectedTtsVoice) {
  [regex]::Matches($Log, "\[/voice-chat/tasks/due-audio\] tts provider=.* voice=$([regex]::Escape($ExpectedTtsVoice))\b").Count
} else {
  0
}

if ($AutoPoll) {
  Write-Check -Name "auto reminder poll" -Ok ($AutoPollCount -ge 1) -Detail ("saw {0}" -f $AutoPollCount) -RequiredCheck:$true
} else {
  Write-Check -Name "serial reminder command" -Ok $CommandSent -RequiredCheck:$true
}
Write-Check -Name "due audio ready" -Ok ($StatusReadyCount -ge 1) -Detail ("saw {0}" -f $StatusReadyCount) -RequiredCheck:$true
Write-Check -Name "reply audio ready" -Ok ($AudioReadyCount -ge 1) -Detail ("saw {0}" -f $AudioReadyCount) -RequiredCheck:$true
if ($ExpectedTtsProvider) {
  Write-Check -Name "expected TTS provider" -Ok ($TtsProviderCount -ge 1) -Detail ("expected={0} saw {1}" -f $ExpectedTtsProvider, $TtsProviderCount) -RequiredCheck:$true
}
if ($ExpectedTtsModel) {
  Write-Check -Name "expected TTS model" -Ok ($TtsModelCount -ge 1) -Detail ("expected={0} saw {1}" -f $ExpectedTtsModel, $TtsModelCount) -RequiredCheck:$true
}
if ($ExpectedTtsVoice) {
  Write-Check -Name "expected TTS voice" -Ok ($TtsVoiceCount -ge 1) -Detail ("expected={0} saw {1}" -f $ExpectedTtsVoice, $TtsVoiceCount) -RequiredCheck:$true
}
Write-Check -Name "audio download" -Ok ($DownloadCount -ge 1) -Detail ("saw {0}" -f $DownloadCount) -RequiredCheck:$true
Write-Check -Name "speaker playback" -Ok ($PlaybackCount -ge 1) -Detail ("saw {0}" -f $PlaybackCount) -RequiredCheck:$true
Write-Check -Name "no crash" -Ok ($CrashCount -eq 0) -Detail ("saw {0} crash marker(s)" -f $CrashCount) -RequiredCheck:$true

$Result = [pscustomobject]@{
  source = "serial-reminder-audio"
  port = $Port
  baud = $Baud
  seconds = $Seconds
  apiBase = $ApiBase
  taskId = $Created.task.task_id
  taskTitle = $TaskTitle
  userId = $UserId
  autoPoll = [bool]$AutoPoll
  autoPollCount = $AutoPollCount
  commandSent = [bool]$CommandSent
  expectedTtsProvider = $ExpectedTtsProvider
  expectedTtsProviderCount = $TtsProviderCount
  expectedTtsModel = $ExpectedTtsModel
  expectedTtsModelCount = $TtsModelCount
  expectedTtsVoice = $ExpectedTtsVoice
  expectedTtsVoiceCount = $TtsVoiceCount
  dueAudioReadyCount = $StatusReadyCount
  replyAudioReadyCount = $AudioReadyCount
  audioDownloadCount = $DownloadCount
  audioPlaybackCount = $PlaybackCount
  crashCount = $CrashCount
  logPath = (Resolve-Path -LiteralPath $SaveLogPath).Path
  markerPath = (Resolve-Path -LiteralPath $MarkerPath).Path
  checks = $Checks
  failures = $Failures
  requiredMode = [bool]$Required
}

$Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Failures.Count -gt 0) {
  Write-Host ("Reminder audio test failed required checks: {0}" -f ($Failures -join ", ")) -ForegroundColor Red
  exit 1
}

exit 0
