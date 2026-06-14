param(
  [string]$ExpectedPort = "",
  [switch]$Required
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$FirmwareDir = Join-Path $Root "firmware\esp32-audio"
$SketchPath = Join-Path $FirmwareDir "esp32-audio.ino"
$SecretsExamplePath = Join-Path $FirmwareDir "secrets.h.example"
$SecretsPath = Join-Path $FirmwareDir "secrets.h"
$DefaultToolPath = Join-Path $env:USERPROFILE ".codex\tools\arduino-cli\arduino-cli.exe"

$Failures = New-Object System.Collections.Generic.List[string]

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
  if ($Required -and $RequiredCheck -and -not $Ok) {
    $Failures.Add($Name)
  }
}

Write-Host "HomeCue Edge firmware environment check"
Write-Host ("Repo: {0}" -f $Root)
Write-Host ""

$ArduinoCliPath = ""
$ArduinoCli = Get-Command "arduino-cli" -ErrorAction SilentlyContinue
if ($ArduinoCli) {
  $ArduinoCliPath = $ArduinoCli.Source
} elseif (Test-Path -LiteralPath $DefaultToolPath) {
  $ArduinoCliPath = $DefaultToolPath
}

if ($ArduinoCliPath) {
  $VersionOutput = (& $ArduinoCliPath version 2>$null) -join " "
  Write-Check "arduino-cli" $true $VersionOutput $true

  $CoreOutput = (& $ArduinoCliPath core list 2>$null) -join "`n"
  $HasEsp32Core = $CoreOutput -match "esp32:esp32"
  Write-Check "esp32 board core" $HasEsp32Core $(if ($HasEsp32Core) { "esp32:esp32 installed" } else { "not listed by arduino-cli core list" }) $false
} else {
  Write-Check "arduino-cli" $false "not found in PATH or default tool path; Arduino IDE can still be used manually" $true
}

Write-Check "firmware sketch" (Test-Path -LiteralPath $SketchPath) $SketchPath $true
Write-Check "secrets template" (Test-Path -LiteralPath $SecretsExamplePath) $SecretsExamplePath $true
Write-Check "local secrets file" (Test-Path -LiteralPath $SecretsPath) "presence only; contents are not read" $false

$LibraryRoot = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Arduino\libraries"
Write-Check "Arduino library folder" (Test-Path -LiteralPath $LibraryRoot) $LibraryRoot $false

if (Test-Path -LiteralPath $LibraryRoot) {
  $ExpectedLibraries = @("ArduinoJson", "es7210", "es8311", "TCA9555")
  foreach ($LibraryName in $ExpectedLibraries) {
    $Matches = @(Get-ChildItem -LiteralPath $LibraryRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "*$LibraryName*" })
    Write-Check "library $LibraryName" ($Matches.Count -gt 0) $(if ($Matches.Count -gt 0) { ($Matches.Name -join ", ") } else { "not found" }) $false
  }
}

$Ports = @()
try {
  $Ports = @(Get-CimInstance Win32_SerialPort -ErrorAction Stop |
    Select-Object -Property DeviceID, Caption)
} catch {
  try {
    $Ports = @([System.IO.Ports.SerialPort]::GetPortNames() |
      ForEach-Object { [pscustomobject]@{ DeviceID = $_; Caption = $_ } })
  } catch {
    $Ports = @()
  }
}

if ($Ports.Count -gt 0) {
  Write-Check "serial ports" $true (($Ports | ForEach-Object { "{0} ({1})" -f $_.DeviceID, $_.Caption }) -join "; ") $false
} else {
  Write-Check "serial ports" $false "none detected" $false
}

if ($ExpectedPort) {
  $ExpectedPortFound = @($Ports | Where-Object { $_.DeviceID -ieq $ExpectedPort }).Count -gt 0
  Write-Check "expected port $ExpectedPort" $ExpectedPortFound $(if ($ExpectedPortFound) { "detected" } else { "not detected" }) $false
}

Write-Host ""
if ($Required -and $Failures.Count -gt 0) {
  Write-Host "Firmware environment check failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "Firmware environment check complete."
exit 0
