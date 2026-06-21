param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$OutputDir = "",
  [string]$ReportPath = "",
  [string]$SummaryPath = "",
  [string]$BrowserEvidenceResultJsonPath = "",
  [string]$Esp32SerialRecheckResultJsonPath = "",
  [string]$ResultJsonPath = "",
  [string]$AdbPath = "",
  [switch]$SkipPreflight,
  [switch]$SelfTest,
  [switch]$DryRun,
  [int]$StartupTimeoutSeconds = 60,
  [int]$StepTimeoutSeconds = 240,
  [int]$BrowserWrapperSharedStateLockTimeoutSeconds = 1200,
  [string]$Esp32Port = "COM7",
  [int]$Esp32Baud = 115200,
  [int]$Esp32SerialSeconds = 45,
  [int]$Esp32SerialCommandIndex = 0,
  [switch]$Esp32SkipReset,
  [double]$MaxAgeMinutes = 0
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$LatestResultJsonPath = Join-Path $Root "assets\tmp\device-loop-check-latest.json"

if ($PSBoundParameters.ContainsKey("ResultJsonPath")) {
  throw "check-device-loop-latest.ps1 always writes assets/tmp/device-loop-check-latest.json; omit -ResultJsonPath."
}

if ($DryRun) {
  throw "Use check-device-loop.ps1 -DryRun to inspect the plan without overwriting latest result evidence."
}

if ($PSBoundParameters.ContainsKey("MaxAgeMinutes") -and $MaxAgeMinutes -le 0) {
  throw "-MaxAgeMinutes must be a positive number when provided."
}

$Arguments = @{
  AppUrl = $AppUrl
  ApiBase = $ApiBase
  StartupTimeoutSeconds = $StartupTimeoutSeconds
  StepTimeoutSeconds = $StepTimeoutSeconds
  BrowserWrapperSharedStateLockTimeoutSeconds = $BrowserWrapperSharedStateLockTimeoutSeconds
  Esp32Port = $Esp32Port
  Esp32Baud = $Esp32Baud
  Esp32SerialSeconds = $Esp32SerialSeconds
  Esp32SerialCommandIndex = $Esp32SerialCommandIndex
  ResultJsonPath = $LatestResultJsonPath
}
if ($OutputDir) {
  $Arguments.OutputDir = $OutputDir
}
if ($ReportPath) {
  $Arguments.ReportPath = $ReportPath
}
if ($SummaryPath) {
  $Arguments.SummaryPath = $SummaryPath
}
if ($BrowserEvidenceResultJsonPath) {
  $Arguments.BrowserEvidenceResultJsonPath = $BrowserEvidenceResultJsonPath
}
if ($Esp32SerialRecheckResultJsonPath) {
  $Arguments.Esp32SerialRecheckResultJsonPath = $Esp32SerialRecheckResultJsonPath
}
if ($AdbPath) {
  $Arguments.AdbPath = $AdbPath
}
if ($SkipPreflight) {
  $Arguments.SkipPreflight = $true
}
if ($SelfTest) {
  $Arguments.SelfTest = $true
}
if ($Esp32SkipReset) {
  $Arguments.Esp32SkipReset = $true
}
if ($PSBoundParameters.ContainsKey("MaxAgeMinutes")) {
  $Arguments.MaxAgeMinutes = $MaxAgeMinutes
}

& "$PSScriptRoot\check-device-loop.ps1" @Arguments
exit $LASTEXITCODE
