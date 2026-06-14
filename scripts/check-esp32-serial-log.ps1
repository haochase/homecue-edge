param(
  [string]$Port = "COM7",
  [int]$Baud = 115200,
  [int]$Seconds = 10,
  [string]$LogPath = "",
  [string]$SaveLogPath = "",
  [string]$ResultJsonPath = "",
  [string[]]$SendCommand = @(),
  [int]$SendAfterSeconds = 2,
  [switch]$AutoSerialLevel4,
  [ValidateRange(0, 2)]
  [int]$SerialCommandIndex = 0,
  [switch]$SkipReset,
  [switch]$RequireInteraction,
  [switch]$Required
)

$ErrorActionPreference = "Stop"

function Read-SerialLog {
  param(
    [string]$Name,
    [int]$Rate,
    [int]$DurationSeconds,
    [string[]]$Commands,
    [int]$CommandDelaySeconds,
    [bool]$AutoLevel4,
    [int]$AutoPlanIndex,
    [bool]$NoReset
  )

  $SerialPort = New-Object System.IO.Ports.SerialPort $Name, $Rate, "None", 8, "One"
  $SerialPort.ReadTimeout = 500
  # DTR held high can leave ESP32-S3 USB CDC boards silent after reset.
  $SerialPort.DtrEnable = $false
  $SerialPort.RtsEnable = $true
  $Chunks = New-Object System.Collections.Generic.List[string]

  try {
    $SerialPort.Open()
    Write-Host ("Reading {0} at {1} baud for {2}s..." -f $Name, $Rate, $DurationSeconds)

    if (-not $NoReset) {
      $SerialPort.RtsEnable = $false
      Start-Sleep -Milliseconds 100
      $SerialPort.RtsEnable = $true
    }

    $Deadline = (Get-Date).AddSeconds($DurationSeconds)
    $CommandIndex = 0
    $NextCommandAt = (Get-Date).AddSeconds($CommandDelaySeconds)
    $AutoPlanSent = $false
    $AutoExecuteSent = $false
    while ((Get-Date) -lt $Deadline) {
      try {
        $Text = $SerialPort.ReadExisting()
        if ($Text) {
          $Chunks.Add($Text)
          Write-Host $Text -NoNewline
        }
      } catch [TimeoutException] {
      }

      if ($AutoLevel4 -and -not $AutoPlanSent -and (Get-Date) -ge $NextCommandAt) {
        $Command = "homecue:plan $AutoPlanIndex"
        $Marker = "`n> serial $Command`n"
        $Chunks.Add($Marker)
        Write-Host $Marker -NoNewline
        $SerialPort.WriteLine($Command)
        $AutoPlanSent = $true
      }

      if ($AutoLevel4 -and $AutoPlanSent -and -not $AutoExecuteSent -and (($Chunks -join "") -match "\[/plan\] proposed \d+ action\(s\)")) {
        $Command = "homecue:execute"
        $Marker = "`n> serial $Command`n"
        $Chunks.Add($Marker)
        Write-Host $Marker -NoNewline
        $SerialPort.WriteLine($Command)
        $AutoExecuteSent = $true
      }

      if (-not $AutoLevel4 -and $CommandIndex -lt $Commands.Count -and (Get-Date) -ge $NextCommandAt) {
        $Command = $Commands[$CommandIndex]
        $Marker = "`n> serial $Command`n"
        $Chunks.Add($Marker)
        Write-Host $Marker -NoNewline
        $SerialPort.WriteLine($Command)
        $CommandIndex += 1
        $NextCommandAt = (Get-Date).AddSeconds($CommandDelaySeconds)
      }

      Start-Sleep -Milliseconds 100
    }
    Write-Host ""
  } finally {
    if ($SerialPort.IsOpen) {
      $SerialPort.Close()
    }
  }

  return ($Chunks -join "")
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

$Failures = New-Object System.Collections.Generic.List[string]
$Checks = New-Object System.Collections.Generic.List[object]

Write-Host "HomeCue Edge ESP32 serial log check"
Write-Host ""

if ($LogPath) {
  if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "Log file not found: $LogPath"
  }
  $LogText = Get-Content -Raw -LiteralPath $LogPath
  Write-Host ("Log    : {0}" -f (Resolve-Path -LiteralPath $LogPath).Path)
} else {
  $LogText = Read-SerialLog -Name $Port -Rate $Baud -DurationSeconds $Seconds -Commands $SendCommand -CommandDelaySeconds $SendAfterSeconds -AutoLevel4:$AutoSerialLevel4 -AutoPlanIndex $SerialCommandIndex -NoReset:$SkipReset
}

if ($SaveLogPath) {
  $SaveDir = Split-Path -Parent $SaveLogPath
  if ($SaveDir -and -not (Test-Path -LiteralPath $SaveDir)) {
    New-Item -ItemType Directory -Path $SaveDir | Out-Null
  }
  Set-Content -LiteralPath $SaveLogPath -Value $LogText -NoNewline
  Write-Host ("Saved  : {0}" -f (Resolve-Path -LiteralPath $SaveLogPath).Path)
}

Write-Host ""
Write-Host "Checking expected firmware markers..."

$InteractionRequired = [bool]$RequireInteraction

Write-Check "boot banner" ($LogText -match "\[HomeCue Edge\].*firmware booting") "HomeCue firmware started" $true
Write-Check "button-route mode" ($LogText -match "\[mode\] button-route MVP") "current firmware keeps ESP-SR optional" $true
Write-Check "TCA9555 key expander" ($LogText -match "\[keys\] TCA9555 OK") "KEY1/KEY2/KEY3 route detected" $false
Write-Check "BOOT fallback" ($LogText -match "BOOT=plan-fallback") "fallback route documented by firmware" $true
Write-Check "WiFi connected" ($LogText -match "\[WiFi\] connected, IP =") "board joined local network" $true
Write-Check "gateway health" ($LogText -match "\[/health\] HTTP 200") "PC gateway reachable on configured host/port" $true
Write-Check "plan trigger" ($LogText -match "\[key\] NEXT ->" -or $LogText -match "\[voice\] command:" -or $LogText -match "\[serial\] PLAN ->") "requires KEY1/BOOT, voice, or serial test trigger during capture" $InteractionRequired
Write-Check "plan proposal" ($LogText -match "\[/plan\] proposed \d+ action\(s\)") "requires plan trigger during capture" $InteractionRequired
Write-Check "confirm trigger" ($LogText -match "\[key\] CONFIRM" -or $LogText -match "\[serial\] CONFIRM") "requires KEY2/confirm or serial test trigger during capture" $InteractionRequired
Write-Check "execute confirmation" ($LogText -match "exec .+ -> accepted") "requires confirm trigger during capture" $InteractionRequired

Write-Host ""
if ($ResultJsonPath) {
  $ResultDir = Split-Path -Parent $ResultJsonPath
  if ($ResultDir -and -not (Test-Path -LiteralPath $ResultDir)) {
    New-Item -ItemType Directory -Path $ResultDir | Out-Null
  }

  $ResultPort = $Port
  $ResultBaud = $Baud
  $ResultSource = "serial"
  $ResultSeconds = $Seconds
  if ($LogPath) {
    $ResultPort = ""
    $ResultBaud = ""
    $ResultSource = (Resolve-Path -LiteralPath $LogPath).Path
    $ResultSeconds = ""
  }

  $Result = @{
    port = $ResultPort
    baud = $ResultBaud
    source = $ResultSource
    seconds = $ResultSeconds
    requireInteraction = [bool]$RequireInteraction
    requiredMode = [bool]$Required
    failures = [string[]]$Failures.ToArray()
    checks = [object[]]$Checks.ToArray()
  }

  $Result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
  Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
}

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "ESP32 serial log check failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "ESP32 serial log check complete."
exit 0
