param(
  [string]$Port = "COM7",
  [int]$Baud = 115200,
  [int]$Seconds = 100,
  [int]$StartAfterSeconds = 12,
  [int]$PauseSeconds = 4,
  [int]$Rate = -4,
  [ValidateRange(0, 100)]
  [int]$Volume = 100,
  [string[]]$Phrases = @(
    "Hi Espressif",
    "I am home",
    "Hi E S P",
    "I am home",
    "Hey E S P",
    "I am home",
    "Hi Esp",
    "movie time",
    "Hi Espressif",
    "sleep mode"
  ),
  [string]$SaveLogPath = ".\assets\demo\esp32-sr-audio-test.log",
  [string]$MarkerPath = ".\assets\demo\esp32-sr-audio-test-markers.log",
  [string]$ResultJsonPath = ".\assets\demo\esp32-sr-audio-test-check.json",
  [string]$LogPath = "",
  [string]$ExpectedCommandLabel = "",
  [ValidateRange(0, 100)]
  [int]$ExpectedActionCount = 0,
  [ValidateRange(0, 100)]
  [int]$ExpectedExecutionCount = 0,
  [ValidateRange(0, 100)]
  [int]$ExpectedRejectCount = 0,
  [switch]$EventDriven,
  [string]$WakePhrase = "Hi E S P",
  [string]$CommandPhrase = "I am home",
  [ValidateRange(1, 30)]
  [int]$WakeRetrySeconds = 5,
  [ValidateRange(0, 5000)]
  [int]$CommandAfterWakeMs = 500,
  [switch]$AutoConfirm,
  [switch]$SkipReset,
  [switch]$Required
)

$ErrorActionPreference = "Stop"

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

$Failures = New-Object System.Collections.Generic.List[string]
$Checks = New-Object System.Collections.Generic.List[object]
$NormalizedPhrases = @()
foreach ($Phrase in $Phrases) {
  foreach ($Part in ($Phrase -split ",")) {
    $Trimmed = $Part.Trim()
    if ($Trimmed) {
      $NormalizedPhrases += $Trimmed
    }
  }
}
if ($NormalizedPhrases.Count -eq 0) {
  throw "No audio phrases were provided."
}
$Phrases = [string[]]$NormalizedPhrases

New-ParentDirectory -Path $SaveLogPath
New-ParentDirectory -Path $MarkerPath
New-ParentDirectory -Path $ResultJsonPath

$TtsJob = $null
$LogSource = "serial"

if ($LogPath) {
  if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "Log path not found: $LogPath"
  }

  $LogSource = "saved-log"
  $LogText = Get-Content -LiteralPath $LogPath -Raw
  Set-Content -LiteralPath $MarkerPath -Value "" -NoNewline

  Write-Host "HomeCue Edge ESP-SR audio test"
  Write-Host ("Source : {0}" -f (Resolve-Path -LiteralPath $LogPath).Path)
  Write-Host ("Mode   : saved-log replay")
  Write-Host ""
} elseif ($EventDriven) {
  Add-Type -AssemblyName System.Speech
  $Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $SerialPort = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
  $SerialPort.ReadTimeout = 200
  # DTR held high can leave ESP32-S3 USB CDC boards silent after reset.
  $SerialPort.DtrEnable = $false
  $SerialPort.RtsEnable = $true
  $Chunks = New-Object System.Collections.Generic.List[string]
  $Markers = New-Object System.Collections.Generic.List[string]

  try {
    $Synth.SetOutputToDefaultAudioDevice()
    $Synth.Rate = $Rate
    $Synth.Volume = $Volume

    $SerialPort.Open()
    Write-Host "HomeCue Edge ESP-SR audio test"
    Write-Host ("Port   : {0}" -f $Port)
    Write-Host ("Mode   : event-driven")
    Write-Host ("Wake   : {0}" -f $WakePhrase)
    Write-Host ("Command: {0}" -f $CommandPhrase)
    Write-Host ("Log    : {0}" -f $SaveLogPath)
    Write-Host ""

    if (-not $SkipReset) {
      $SerialPort.RtsEnable = $false
      Start-Sleep -Milliseconds 100
      $SerialPort.RtsEnable = $true
    }

    $Ready = $false
    $WakeVerified = $false
    $CommandSent = $false
    $ConfirmSent = $false
    $WakeAttempts = 0
    $NextWakeAt = (Get-Date).AddSeconds($StartAfterSeconds)
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
        $NextWakeAt = (Get-Date).AddSeconds(3)
      }

      $LastWakeChannelIndex = Get-LastMatchIndex -Text $LogSoFar -Pattern "wake word channel \d+ verified - listening for command"
      $LastTimeoutIndex = Get-LastMatchIndex -Text $LogSoFar -Pattern "\[esp-sr\] command window timeout"
      $CommandWindowOpen = $LastWakeChannelIndex -ge 0 -and $LastWakeChannelIndex -gt $LastTimeoutIndex
      $WakeVerified = $CommandWindowOpen

      if ($CommandSent -and -not ($LogSoFar -match "\[voice\] command:") -and $LastTimeoutIndex -gt $LastWakeChannelIndex) {
        $CommandSent = $false
        $NextWakeAt = (Get-Date).AddSeconds(1)
      }

      if ($Ready -and -not $CommandWindowOpen -and -not $CommandSent -and (Get-Date) -ge $NextWakeAt -and $Synth.State -ne "Speaking") {
        $WakeAttempts += 1
        $Marker = "audio wake {0}: {1}" -f $WakeAttempts, $WakePhrase
        $Markers.Add($Marker)
        Write-Host ("`n{0}" -f $Marker)
        $Synth.SpeakAsync($WakePhrase) | Out-Null
        $NextWakeAt = (Get-Date).AddSeconds($WakeRetrySeconds)
      }

      if ($CommandWindowOpen -and -not $CommandSent) {
        if ($Synth.State -eq "Speaking") {
          $Synth.SpeakAsyncCancelAll()
        }
        Start-Sleep -Milliseconds $CommandAfterWakeMs
        $Marker = "audio command: {0}" -f $CommandPhrase
        $Markers.Add($Marker)
        Write-Host ("`n{0}" -f $Marker)
        $Synth.Speak($CommandPhrase)
        $CommandSent = $true
      }

      $LogSoFar = $Chunks -join ""
      if ($AutoConfirm -and -not $ConfirmSent -and $LogSoFar -match "\[/plan\] proposed \d+ action\(s\)") {
        $Marker = "serial: homecue:execute"
        $Markers.Add($Marker)
        Write-Host ("`n> {0}" -f $Marker)
        Start-Sleep -Seconds 1
        $SerialPort.WriteLine("homecue:execute")
        $ConfirmSent = $true
      }

      $ExecutionAcceptedCountSoFar = [regex]::Matches($LogSoFar, "exec .+ -> accepted").Count
      $PlanSatisfied = $LogSoFar -match "\[/plan\] proposed \d+ action\(s\)"
      $ExecutionSatisfied = $ExpectedExecutionCount -le 0 -or $ExecutionAcceptedCountSoFar -ge $ExpectedExecutionCount
      if ($PlanSatisfied -and (-not $AutoConfirm -or ($ConfirmSent -and $ExecutionSatisfied))) {
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

  $LogSource = "serial-event-driven"
  $LogText = $Chunks -join ""
  Set-Content -LiteralPath $SaveLogPath -Value $LogText -NoNewline -Encoding UTF8
  if ($Markers.Count -gt 0) {
    Set-Content -LiteralPath $MarkerPath -Value ($Markers -join [Environment]::NewLine) -Encoding UTF8
  } else {
    Set-Content -LiteralPath $MarkerPath -Value "" -NoNewline
  }
} else {
  $TtsJob = Start-Job -ScriptBlock {
    param($DelaySeconds, $SpeechRate, $SpeechVolume, $SpeechPhrases, $SpeechPauseSeconds)
    Start-Sleep -Seconds $DelaySeconds
    Add-Type -AssemblyName System.Speech
    $Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
      $Synth.SetOutputToDefaultAudioDevice()
      $Synth.Rate = $SpeechRate
      $Synth.Volume = $SpeechVolume
      foreach ($Phrase in $SpeechPhrases) {
        Write-Output ("audio: " + $Phrase)
        $Synth.Speak($Phrase)
        Start-Sleep -Seconds $SpeechPauseSeconds
      }
    } finally {
      $Synth.Dispose()
    }
  } -ArgumentList $StartAfterSeconds, $Rate, $Volume, $Phrases, $PauseSeconds

  try {
    $SerialArgs = @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", ".\scripts\read-esp32-serial.ps1",
      "-Port", $Port,
      "-Baud", $Baud,
      "-Seconds", $Seconds
    )
    if ($SkipReset) {
      $SerialArgs += "-SkipReset"
    }

    Write-Host "HomeCue Edge ESP-SR audio test"
    Write-Host ("Port   : {0}" -f $Port)
    Write-Host ("Audio  : {0} phrase(s), starts after {1}s" -f $Phrases.Count, $StartAfterSeconds)
    Write-Host ("Log    : {0}" -f $SaveLogPath)
    Write-Host ""

    $LogText = & powershell @SerialArgs | Tee-Object -FilePath $SaveLogPath | Out-String
    Wait-Job $TtsJob -Timeout 5 | Out-Null
    if ($TtsJob.State -eq "Running") {
      Stop-Job $TtsJob
    }
    $Markers = Receive-Job $TtsJob
    if ($Markers) {
      $Markers | Tee-Object -FilePath $MarkerPath | Out-Null
    } else {
      Set-Content -LiteralPath $MarkerPath -Value "" -NoNewline
    }
  } finally {
    if ($TtsJob) {
      Remove-Job $TtsJob -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host ""
Write-Host "Checking expected ESP-SR markers..."

$ExpectedCommandLabelOk = -not $ExpectedCommandLabel -or $LogText -match ('\[voice\] command:\s*{0}' -f [regex]::Escape($ExpectedCommandLabel))
$ExpectedActionCountOk = $ExpectedActionCount -le 0 -or $LogText -match ("\[/plan\] proposed {0} action\(s\)" -f $ExpectedActionCount)
$VoiceCommandMatches = [regex]::Matches($LogText, "\[voice\] command:")
$PlanProposalMatches = [regex]::Matches($LogText, "\[/plan\] proposed \d+ action\(s\)")
$ExecutionMatches = [regex]::Matches($LogText, "exec .+ -> accepted")
$ExecutionAcceptedCount = $ExecutionMatches.Count
$ExpectedExecutionCountOk = $ExpectedExecutionCount -le 0 -or $ExecutionAcceptedCount -ge $ExpectedExecutionCount
$ConfirmMatches = [regex]::Matches($LogText, "(\[key\]\s+CONFIRM|\[serial\]\s+CONFIRM)")
$RejectMatches = [regex]::Matches($LogText, "(\[key\]\s+REJECT|\[serial\]\s+REJECT)")
$VoiceCommandCount = $VoiceCommandMatches.Count
$PlanProposalCount = $PlanProposalMatches.Count
$ConfirmCount = $ConfirmMatches.Count
$RejectCount = $RejectMatches.Count
$FirstVoiceCommandIndex = if ($VoiceCommandCount -gt 0) { $VoiceCommandMatches[0].Index } else { -1 }
$FirstPlanProposalIndex = if ($PlanProposalCount -gt 0) { $PlanProposalMatches[0].Index } else { -1 }
$FirstConfirmIndex = if ($ConfirmCount -gt 0) { $ConfirmMatches[0].Index } else { -1 }
$FirstRejectIndex = if ($RejectCount -gt 0) { $RejectMatches[0].Index } else { -1 }
$FirstExecutionIndex = if ($ExecutionAcceptedCount -gt 0) { $ExecutionMatches[0].Index } else { -1 }
$ConfirmBeforeExecutionOk = $ExpectedExecutionCount -le 0 -or (
  $ConfirmCount -gt 0 -and
  $FirstExecutionIndex -ge 0 -and
  $FirstConfirmIndex -ge 0 -and
  $FirstConfirmIndex -lt $FirstExecutionIndex
)
$VoiceProposalConfirmExecuteOrderOk = $ExpectedExecutionCount -le 0 -or (
  $FirstVoiceCommandIndex -ge 0 -and
  $FirstPlanProposalIndex -ge 0 -and
  $FirstConfirmIndex -ge 0 -and
  $FirstExecutionIndex -ge 0 -and
  $FirstVoiceCommandIndex -lt $FirstPlanProposalIndex -and
  $FirstPlanProposalIndex -lt $FirstConfirmIndex -and
  $FirstConfirmIndex -lt $FirstExecutionIndex
)
$ExpectedRejectCountOk = $ExpectedRejectCount -le 0 -or $RejectCount -ge $ExpectedRejectCount
$VoiceProposalRejectOrderOk = $ExpectedRejectCount -le 0 -or (
  $FirstVoiceCommandIndex -ge 0 -and
  $FirstPlanProposalIndex -ge 0 -and
  $FirstRejectIndex -ge 0 -and
  $FirstVoiceCommandIndex -lt $FirstPlanProposalIndex -and
  $FirstPlanProposalIndex -lt $FirstRejectIndex
)
$RejectBlocksExecutionOk = $ExpectedRejectCount -le 0 -or (
  $FirstRejectIndex -ge 0 -and
  ($ExecutionAcceptedCount -eq 0 -or $ExecutionMatches[$ExecutionAcceptedCount - 1].Index -lt $FirstRejectIndex)
)

Write-Check "ESP-SR mode" ($LogText -match "\[mode\] button-route \+ ESP-SR voice command route") "firmware is running the voice route" $true
Write-Check "ES7210 ready" ($LogText -match "\[esp-sr\] ES7210 codec ready") "dual-mic ADC initialized" $true
Write-Check "ESP-SR ready" ($LogText -match "\[esp-sr\] ready") "WakeNet/MultiNet initialized" $true
Write-Check "wake word detected" ($LogText -match "\[esp-sr\] wake word detected" -or $LogText -match "\[esp-sr\] wake word channel") "wake phrase reached ESP-SR" $true
Write-Check "voice command" ($LogText -match "\[voice\] command:" -or $LogText -match "\[esp-sr\] unmapped command id") "command phrase produced a recognizer event" $true
Write-Check "expected command label" $ExpectedCommandLabelOk ("expected voice command label '{0}'; pass empty string to skip" -f $ExpectedCommandLabel) ([bool]$ExpectedCommandLabel)
Write-Check "plan proposal" ($LogText -match "\[/plan\] proposed \d+ action\(s\)") "recognized command reached propose-only /plan" $true
Write-Check "expected action count" $ExpectedActionCountOk ("expected {0} proposed action(s); pass 0 to skip" -f $ExpectedActionCount) ($ExpectedActionCount -gt 0)
Write-Check "confirm execution count" $ExpectedExecutionCountOk ("expected at least {0} accepted exec line(s), saw {1}; pass 0 to skip" -f $ExpectedExecutionCount, $ExecutionAcceptedCount) ($ExpectedExecutionCount -gt 0)
Write-Check "confirm before execution" $ConfirmBeforeExecutionOk ("expected a CONFIRM marker before first accepted exec when execution count is required; saw {0} confirm marker(s)" -f $ConfirmCount) ($ExpectedExecutionCount -gt 0)
Write-Check "voice proposal confirm execute order" $VoiceProposalConfirmExecuteOrderOk "expected first voice command, proposal, CONFIRM, and accepted exec markers in order when execution count is required" ($ExpectedExecutionCount -gt 0)
Write-Check "reject count" $ExpectedRejectCountOk ("expected at least {0} REJECT marker(s), saw {1}; pass 0 to skip" -f $ExpectedRejectCount, $RejectCount) ($ExpectedRejectCount -gt 0)
Write-Check "voice proposal reject order" $VoiceProposalRejectOrderOk "expected first voice command, proposal, and REJECT markers in order when reject count is required" ($ExpectedRejectCount -gt 0)
Write-Check "reject blocks execution" $RejectBlocksExecutionOk "expected no accepted exec marker after the first REJECT marker when reject count is required" ($ExpectedRejectCount -gt 0)

$ResolvedLogPath = if ($LogPath) { (Resolve-Path -LiteralPath $LogPath).Path } else { (Resolve-Path -LiteralPath $SaveLogPath).Path }
$Result = @{
  source = $LogSource
  port = $Port
  baud = $Baud
  seconds = $Seconds
  expectedCommandLabel = $ExpectedCommandLabel
  expectedActionCount = $ExpectedActionCount
  expectedExecutionCount = $ExpectedExecutionCount
  expectedRejectCount = $ExpectedRejectCount
  voiceCommandCount = $VoiceCommandCount
  planProposalCount = $PlanProposalCount
  executionAcceptedCount = $ExecutionAcceptedCount
  confirmCount = $ConfirmCount
  rejectCount = $RejectCount
  confirmBeforeExecution = $ConfirmBeforeExecutionOk
  voiceProposalConfirmExecuteOrder = $VoiceProposalConfirmExecuteOrderOk
  voiceProposalRejectOrder = $VoiceProposalRejectOrderOk
  rejectBlocksExecution = $RejectBlocksExecutionOk
  phrases = if ($EventDriven) { [string[]]@($WakePhrase, $CommandPhrase) } else { [string[]]$Phrases }
  eventDriven = [bool]$EventDriven
  autoConfirm = [bool]$AutoConfirm
  logPath = $ResolvedLogPath
  markerPath = (Resolve-Path -LiteralPath $MarkerPath).Path
  requiredMode = [bool]$Required
  failures = [string[]]$Failures.ToArray()
  checks = [object[]]$Checks.ToArray()
}
$Result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "ESP-SR audio test failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "ESP-SR audio test complete."
exit 0
