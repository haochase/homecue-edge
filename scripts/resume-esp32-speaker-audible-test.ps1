param(
  [string]$Port = "COM7",
  [int]$Baud = 115200,
  [int]$MaxWaitSeconds = 900,
  [int]$PollSeconds = 5,
  [string]$ApiHostOverride = "192.0.2.118",
  [string]$ApiPortOverride = "8723",
  [string]$BuildPath = "",
  [ValidateSet("921600", "115200", "256000", "230400", "512000")]
  [string]$UploadSpeed = "115200",
  [ValidateSet("default", "cdc")]
  [string]$UploadMode = "cdc",
  [ValidateRange(1, 10)]
  [int]$ToneSeconds = 8,
  [ValidateSet("all", "both", "left", "right", "sweep")]
  [string]$ToneMode = "all",
  [switch]$NoBootSpeakerTest,
  [switch]$NoDiagHttpServer,
  [int]$CaptureSeconds = 25,
  [string]$OutputPrefix = ".\assets\demo\esp32-speaker-audible-recheck-auto",
  [switch]$AutoDetectEsp32,
  [switch]$SkipUpload,
  [switch]$SkipTone,
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

function Invoke-ChildScript {
  param(
    [string]$ScriptPath,
    [string[]]$Arguments
  )

  $PowerShellExe = Join-Path $PSHOME "powershell.exe"
  & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
  return $LASTEXITCODE
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

$StartedAt = Get-Date
$StatePath = "$OutputPrefix-port-state.json"
$SummaryPath = "$OutputPrefix-summary.json"
$ToneLogPath = "$OutputPrefix-tone.log"
$ToneResultPath = "$OutputPrefix-tone-check.json"
$RequestedPort = $Port
if (-not $BuildPath) {
  $BuildPath = Join-Path $env:TEMP "homecue-edge-esp32-speaker-audible-auto-build"
}

New-ParentDirectory -Path $StatePath
New-ParentDirectory -Path $SummaryPath
New-ParentDirectory -Path $ToneLogPath
New-ParentDirectory -Path $ToneResultPath

$CheckScript = Join-Path $PSScriptRoot "check-esp32-port-state.ps1"
$FlashScript = Join-Path $PSScriptRoot "flash-esp32.ps1"
$ToneScript = Join-Path $PSScriptRoot "test-esp32-speaker-tone.ps1"
$FinalState = $null
$FinalStateName = "unknown"
$TimedOut = $false
$UploadExitCode = $null
$ToneExitCode = $null
$Status = "waiting"

Write-Host "HomeCue Edge ESP32 speaker audible-test resume"
Write-Host ("Port       : {0}" -f $Port)
Write-Host ("Auto detect: {0}" -f $(if ($AutoDetectEsp32) { "enabled" } else { "disabled" }))
Write-Host ("Max wait   : {0}s" -f $MaxWaitSeconds)
Write-Host ("Poll       : {0}s" -f $PollSeconds)
Write-Host ("Build path : {0}" -f $BuildPath)
Write-Host ("Boot tone  : {0}" -f $(if ($NoBootSpeakerTest) { "disabled" } else { "$ToneSeconds s / $ToneMode" }))
Write-Host ("HTTP diag  : {0}" -f $(if ($NoDiagHttpServer) { "disabled" } else { "enabled" }))
Write-Host ("Output     : {0}" -f $OutputPrefix)
Write-Host ""

do {
  $CheckArgs = @(
    "-Port", $Port,
    "-Baud", ([string]$Baud),
    "-ResultJsonPath", $StatePath
  )
  if ($AutoDetectEsp32) {
    $CheckArgs += "-AutoDetectEsp32"
  }
  [void](Invoke-ChildScript -ScriptPath $CheckScript -Arguments $CheckArgs)
  $FinalState = Read-JsonFile -Path $StatePath
  if ($FinalState -and $FinalState.state) {
    $FinalStateName = [string]$FinalState.state
  }
  if ($FinalState -and $FinalState.port) {
    $Port = [string]$FinalState.port
  }

  if ($FinalStateName -eq "writable") {
    $Status = "port-writable"
    break
  }

  $ElapsedSeconds = [int]((Get-Date) - $StartedAt).TotalSeconds
  if ($MaxWaitSeconds -le 0 -or $ElapsedSeconds -ge $MaxWaitSeconds) {
    $TimedOut = $true
    $Status = "timed-out"
    break
  }

  $RemainingSeconds = $MaxWaitSeconds - $ElapsedSeconds
  Write-Host ("Waiting for {0}: current state={1}, remaining={2}s" -f $Port, $FinalStateName, $RemainingSeconds)
  Start-Sleep -Seconds $PollSeconds
} while ($true)

if (-not $TimedOut -and -not $SkipUpload) {
  $FlashArgs = @(
    "-Port", $Port,
    "-Upload",
    "-Clean",
    "-EnableEspSr",
    "-BuildPath", $BuildPath,
    "-UploadSpeed", $UploadSpeed,
    "-UploadMode", $UploadMode
  )
  if ($ApiHostOverride) {
    $FlashArgs += @("-ApiHostOverride", $ApiHostOverride)
  }
  if ($ApiPortOverride) {
    $FlashArgs += @("-ApiPortOverride", $ApiPortOverride)
  }
  if (-not $NoBootSpeakerTest) {
    $FlashArgs += @(
      "-BootSpeakerTest",
      "-BootSpeakerTestSeconds", ([string]$ToneSeconds),
      "-BootSpeakerTestMode", $ToneMode
    )
  }
  if (-not $NoDiagHttpServer) {
    $FlashArgs += "-DiagHttpServer"
  }

  $UploadExitCode = Invoke-ChildScript -ScriptPath $FlashScript -Arguments $FlashArgs
  if ($UploadExitCode -ne 0) {
    $Status = "upload-failed"
  } else {
    $Status = "uploaded"
  }
}

if (-not $TimedOut -and $Status -ne "upload-failed" -and -not $SkipTone) {
  $ToneArgs = @(
    "-Port", $Port,
    "-Seconds", ([string]$CaptureSeconds),
    "-ToneSeconds", ([string]$ToneSeconds),
    "-ToneMode", $ToneMode,
    "-SaveLogPath", $ToneLogPath,
    "-ResultJsonPath", $ToneResultPath
  )
  if ($Required) {
    $ToneArgs += "-Required"
  }

  $ToneExitCode = Invoke-ChildScript -ScriptPath $ToneScript -Arguments $ToneArgs
  if ($ToneExitCode -ne 0) {
    $Status = "tone-failed"
  } else {
    $Status = "tone-complete"
  }
}

if ($SkipUpload -and -not $TimedOut -and -not $SkipTone -and $Status -eq "port-writable") {
  $Status = "tone-complete"
}

$Summary = @{
  startedAt = $StartedAt.ToString("o")
  finishedAt = (Get-Date).ToString("o")
  requestedPort = $RequestedPort
  port = $Port
  baud = $Baud
  status = $Status
  timedOut = [bool]$TimedOut
  finalPortState = $FinalStateName
  maxWaitSeconds = $MaxWaitSeconds
  pollSeconds = $PollSeconds
  apiHostOverride = $ApiHostOverride
  apiPortOverride = $ApiPortOverride
  buildPath = $BuildPath
  uploadSpeed = $UploadSpeed
  uploadMode = $UploadMode
  bootSpeakerTest = -not [bool]$NoBootSpeakerTest
  diagHttpServer = -not [bool]$NoDiagHttpServer
  skipUpload = [bool]$SkipUpload
  uploadExitCode = $UploadExitCode
  skipTone = [bool]$SkipTone
  toneExitCode = $ToneExitCode
  toneMode = $ToneMode
  toneSeconds = $ToneSeconds
  captureSeconds = $CaptureSeconds
  statePath = $StatePath
  toneLogPath = $ToneLogPath
  toneResultPath = $ToneResultPath
  humanAudibleConfirmationRequired = $true
}
$Summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8

Write-Host ""
Write-Host ("Status : {0}" -f $Status)
Write-Host ("Summary: {0}" -f (Resolve-Path -LiteralPath $SummaryPath).Path)
if (Test-Path -LiteralPath $ToneResultPath) {
  Write-Host ("Tone   : {0}" -f (Resolve-Path -LiteralPath $ToneResultPath).Path)
}

if ($Required -and ($TimedOut -or $Status -eq "upload-failed" -or $Status -eq "tone-failed")) {
  exit 1
}

exit 0
