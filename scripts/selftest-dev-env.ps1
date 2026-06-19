param()

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$OutputDir = Join-Path $Root "assets\tmp\dev-env-selftest"
$MissingAdbPath = Join-Path $OutputDir "missing-adb.exe"
$FakeAdbPath = Join-Path $OutputDir "adb.cmd"
$OptionalJson = Join-Path $OutputDir "optional-phone.json"
$RequiredJson = Join-Path $OutputDir "required-phone.json"
$DetectedJson = Join-Path $OutputDir "detected-phone.json"

function Invoke-DevEnv {
  param([string[]]$Arguments)

  $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-dev-env.ps1" @Arguments 2>&1
  return [pscustomobject]@{
    ExitCode = $LASTEXITCODE
    Output = ($Output -join [Environment]::NewLine)
  }
}

function Read-Json {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Expected JSON output was not written: $Path"
  }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Equal {
  param(
    [object]$Actual,
    [object]$Expected,
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw ("{0} Expected '{1}', got '{2}'." -f $Message, $Expected, $Actual)
  }
}

function Get-Check {
  param(
    [object]$Result,
    [string]$Name
  )

  $Check = @($Result.checks | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
  if (-not $Check) {
    throw "Missing dev-env check: $Name"
  }
  return $Check
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Remove-Item -LiteralPath $MissingAdbPath -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $FakeAdbPath -Encoding ASCII -Value @'
@echo off
if "%1"=="devices" (
  echo List of devices attached
  echo 7828be55               device product:venus model:M2011K2C device:venus transport_id:3
  exit /b 0
)
if "%1"=="get-state" (
  echo device
  exit /b 0
)
exit /b 1
'@

$Optional = Invoke-DevEnv @("-AdbPath", $MissingAdbPath, "-ResultJsonPath", $OptionalJson)
Assert-Equal $Optional.ExitCode 0 "Optional-phone preflight should not fail when adb is missing."
$OptionalResult = Read-Json $OptionalJson
Assert-True ($OptionalResult.success -eq $true) "Optional-phone JSON success should remain true."
Assert-True ($OptionalResult.required -eq $false) "Optional-phone JSON required should be false."
Assert-True ($OptionalResult.requirePhone -eq $false) "Optional-phone JSON requirePhone should be false."
$OptionalAdb = Get-Check $OptionalResult "adb.exe"
Assert-True ($OptionalAdb.ok -eq $false) "Optional-phone adb check should record missing adb."
Assert-True ($OptionalAdb.required -eq $false) "Optional-phone adb check should not be required."
Assert-Equal $OptionalAdb.status "WARN" "Optional-phone missing adb should be WARN."
$OptionalDevice = Get-Check $OptionalResult "authorized Android device"
Assert-True ($OptionalDevice.ok -eq $true) "Optional-phone authorized-device check should be skipped as OK."
Assert-True ($OptionalDevice.required -eq $false) "Optional-phone authorized-device check should not be required."
Assert-Equal $OptionalDevice.status "OK" "Optional-phone authorized-device skip should be OK."
Assert-True ($OptionalDevice.detail -match "RequirePhone") "Optional-phone authorized-device detail should explain how to require it."

$Required = Invoke-DevEnv @("-Required", "-RequirePhone", "-AdbPath", $MissingAdbPath, "-ResultJsonPath", $RequiredJson)
Assert-True ($Required.ExitCode -ne 0) "Required-phone preflight should fail when adb is missing."
$RequiredResult = Read-Json $RequiredJson
Assert-True ($RequiredResult.success -eq $false) "Required-phone JSON success should be false."
Assert-True ($RequiredResult.required -eq $true) "Required-phone JSON required should be true."
Assert-True ($RequiredResult.requirePhone -eq $true) "Required-phone JSON requirePhone should be true."
$RequiredAdb = Get-Check $RequiredResult "adb.exe"
Assert-True ($RequiredAdb.ok -eq $false) "Required-phone adb check should record missing adb."
Assert-True ($RequiredAdb.required -eq $true) "Required-phone adb check should be required."
Assert-Equal $RequiredAdb.status "FAIL" "Required-phone missing adb should be FAIL."
$RequiredDevice = Get-Check $RequiredResult "authorized Android device"
Assert-True ($RequiredDevice.ok -eq $false) "Required-phone authorized-device check should record no device."
Assert-True ($RequiredDevice.required -eq $true) "Required-phone authorized-device check should be required."
Assert-Equal $RequiredDevice.status "FAIL" "Required-phone missing authorized device should be FAIL."

$Detected = Invoke-DevEnv @("-Required", "-RequirePhone", "-AdbPath", $FakeAdbPath, "-ResultJsonPath", $DetectedJson)
Assert-Equal $Detected.ExitCode 0 "Required-phone preflight should pass when adb devices -l reports a product-suffixed device."
$DetectedResult = Read-Json $DetectedJson
Assert-True ($DetectedResult.success -eq $true) "Detected-phone JSON success should be true."
$DetectedDevice = Get-Check $DetectedResult "authorized Android device"
Assert-True ($DetectedDevice.ok -eq $true) "Detected-phone authorized-device check should be ok."
Assert-True ($DetectedDevice.detail -match "device product:venus") "Detected-phone detail should preserve adb devices -l output."

Write-Host "dev-env self-test passed."
